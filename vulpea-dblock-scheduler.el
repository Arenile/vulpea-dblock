;;; vulpea-dblock-scheduler.el --- Dirty queue and idle-time draining -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivris Raymond

;; This file is part of vulpea-dblock.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Scheduler for vulpea-dblock: one FIFO-with-dedup dirty queue drained
;; in small, resumable, idle-time slices.
;;
;; Design points (the fixes for the old init.el machinery):
;;
;; - Publishing a change never cancels queued work, it only delays the
;;   next slice (debounce).
;; - A tick processes subs until the time budget elapses or keyboard
;;   input arrives; whatever is still queued STAYS queued and resumes
;;   on the next idle slice.  No pass ever restarts from scratch.
;; - The atomic unit is one sub (one candidate query, at most one
;;   buffer edit); budget checks happen between subs.
;; - Subs whose buffer is currently displayed drain first.
;; - Event storms (full db scans) collapse into a single mark-all-dirty
;;   pass once `vulpea-dblock-storm-threshold' events pile up within
;;   one debounce window; the publisher also stops capturing old/new
;;   file state while the storm flag is up.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'vulpea-dblock-registry)
(require 'vulpea-dblock-render)

(defcustom vulpea-dblock-idle-delay 0.5
  "Idle seconds between a database change and the first work slice.
Purely a debounce: a burst of ingested files produces one drain."
  :type 'number
  :group 'vulpea-dblock)

(defcustom vulpea-dblock-tick-budget 0.05
  "Maximum seconds of work per scheduler slice."
  :type 'number
  :group 'vulpea-dblock)

(defcustom vulpea-dblock-tick-gap 0.1
  "Idle seconds between successive scheduler slices."
  :type 'number
  :group 'vulpea-dblock)

(defcustom vulpea-dblock-storm-threshold 100
  "Publish events per debounce window that trigger mark-all-dirty.
Past this many events (e.g. during `vulpea-db-sync-full-scan') the
scheduler stops matching individual events and just re-verifies
every block once."
  :type 'natnum
  :group 'vulpea-dblock)

(defvar vulpea-dblock--queue nil
  "FIFO of dirty subs awaiting verification; each sub appears at most once.")

(defvar vulpea-dblock--debounce-timer nil
  "Pending idle timer for the first slice after a publish.")

(defvar vulpea-dblock--tick-timer nil
  "Pending idle timer for the next slice of an interrupted drain.")

(defvar vulpea-dblock--event-count 0
  "Publish events seen in the current debounce window.")

(defvar vulpea-dblock--storm nil
  "Non-nil while collapsing an event storm into one mark-all pass.
The publisher checks this to skip per-file old/new state capture.")

;;; Queue

(defun vulpea-dblock--enqueue (sub)
  "Mark SUB dirty and append it to the queue unless already queued."
  (unless (vulpea-dblock--sub-queued sub)
    (setf (vulpea-dblock--sub-queued sub) t
          (vulpea-dblock--sub-dirty sub) t)
    (setq vulpea-dblock--queue
          (nconc vulpea-dblock--queue (list sub)))))

(defun vulpea-dblock--sub-visible-p (sub)
  "Return non-nil when SUB's buffer is displayed in some window."
  (let ((buf (vulpea-dblock--sub-buffer sub)))
    (and (buffer-live-p buf)
         (get-buffer-window buf t))))

(defun vulpea-dblock--dequeue ()
  "Pop the next sub, preferring subs whose buffer is displayed."
  (let ((sub (or (seq-find #'vulpea-dblock--sub-visible-p
                           vulpea-dblock--queue)
                 (car vulpea-dblock--queue))))
    (when sub
      (setq vulpea-dblock--queue (delq sub vulpea-dblock--queue))
      (setf (vulpea-dblock--sub-queued sub) nil))
    sub))

;;; Publishing

(defun vulpea-dblock--mark-all-dirty ()
  "Enqueue every registered sub."
  (dolist (sub (vulpea-dblock--all-subs))
    (vulpea-dblock--enqueue sub)))

(defun vulpea-dblock--publish (event)
  "Mark subs affected by EVENT dirty and (re)arm the debounce timer.
Never cancels queued work.  Past `vulpea-dblock-storm-threshold'
events in one debounce window, flips to storm mode and marks
everything dirty once."
  (cl-incf vulpea-dblock--event-count)
  (cond
   (vulpea-dblock--storm nil)
   ((> vulpea-dblock--event-count vulpea-dblock-storm-threshold)
    (setq vulpea-dblock--storm t)
    (vulpea-dblock--mark-all-dirty))
   (t
    (dolist (sub (vulpea-dblock--match-event event))
      (vulpea-dblock--enqueue sub))))
  (vulpea-dblock--schedule))

(defun vulpea-dblock--schedule ()
  "(Re)arm the debounce timer for the next drain."
  (when (timerp vulpea-dblock--debounce-timer)
    (cancel-timer vulpea-dblock--debounce-timer))
  (setq vulpea-dblock--debounce-timer
        (run-with-idle-timer vulpea-dblock-idle-delay nil
                             #'vulpea-dblock--on-debounce)))

(defun vulpea-dblock--on-debounce ()
  "Debounce timer callback: reset the event window and start draining."
  (setq vulpea-dblock--debounce-timer nil
        vulpea-dblock--event-count 0
        vulpea-dblock--storm nil)
  (vulpea-dblock--tick))

;;; Draining

(defun vulpea-dblock--process-one (sub force)
  "Process SUB, routing a broken outcome to a buffer rescan.
Errors are demoted to messages so one bad block cannot wedge the
queue.  Returns the outcome symbol."
  (condition-case err
      (let ((outcome (vulpea-dblock--process-sub sub force)))
        (when (eq outcome 'broken)
          (vulpea-dblock--handle-broken sub))
        outcome)
    (error
     (message "vulpea-dblock: error refreshing block in %s: %s"
              (vulpea-dblock--sub-buffer sub)
              (error-message-string err))
     'error)))

(defun vulpea-dblock--handle-broken (sub)
  "Drop broken SUB and rescan its buffer to pick up the current blocks."
  (let ((buf (vulpea-dblock--sub-buffer sub)))
    (vulpea-dblock--unregister sub)
    (when (buffer-live-p buf)
      (dolist (s (vulpea-dblock--scan-buffer buf))
        (vulpea-dblock--enqueue s)))))

(defun vulpea-dblock--tick ()
  "Process queued subs until the budget elapses or input arrives.
Interrupted work stays in the queue and resumes on the next idle
slice; nothing is ever restarted from scratch."
  (setq vulpea-dblock--tick-timer nil)
  (let ((deadline (+ (float-time) vulpea-dblock-tick-budget)))
    (while (and vulpea-dblock--queue
                (not (input-pending-p))
                (< (float-time) deadline))
      (let ((sub (vulpea-dblock--dequeue)))
        (when (and sub (vulpea-dblock--registered-p sub))
          (vulpea-dblock--process-one sub nil)))))
  (when vulpea-dblock--queue
    (vulpea-dblock--arm-tick)))

(defun vulpea-dblock--arm-tick ()
  "Arm the idle timer for the next slice.
When Emacs is already idle, the timer must be set relative to the
current idle time or it would not fire until the *next* idle period."
  (when (timerp vulpea-dblock--tick-timer)
    (cancel-timer vulpea-dblock--tick-timer))
  (let* ((idle (current-idle-time))
         (delay (if idle
                    (time-add idle vulpea-dblock-tick-gap)
                  vulpea-dblock-tick-gap)))
    (setq vulpea-dblock--tick-timer
          (run-with-idle-timer delay nil #'vulpea-dblock--tick))))

(defun vulpea-dblock--drain (&optional force)
  "Synchronously process the whole queue, ignoring budget and input.
With FORCE, skip the result-signature shortcut for every sub."
  (when (timerp vulpea-dblock--debounce-timer)
    (cancel-timer vulpea-dblock--debounce-timer))
  (when (timerp vulpea-dblock--tick-timer)
    (cancel-timer vulpea-dblock--tick-timer))
  (setq vulpea-dblock--debounce-timer nil
        vulpea-dblock--tick-timer nil
        vulpea-dblock--event-count 0
        vulpea-dblock--storm nil)
  (while vulpea-dblock--queue
    (let ((sub (vulpea-dblock--dequeue)))
      (when (and sub (vulpea-dblock--registered-p sub))
        (vulpea-dblock--process-one sub force)))))

(defun vulpea-dblock--shutdown ()
  "Cancel timers and drop all queued work (for mode disable/kill-emacs)."
  (when (timerp vulpea-dblock--debounce-timer)
    (cancel-timer vulpea-dblock--debounce-timer))
  (when (timerp vulpea-dblock--tick-timer)
    (cancel-timer vulpea-dblock--tick-timer))
  (setq vulpea-dblock--debounce-timer nil
        vulpea-dblock--tick-timer nil
        vulpea-dblock--event-count 0
        vulpea-dblock--storm nil)
  (dolist (sub vulpea-dblock--queue)
    (setf (vulpea-dblock--sub-queued sub) nil))
  (setq vulpea-dblock--queue nil))

(provide 'vulpea-dblock-scheduler)
;;; vulpea-dblock-scheduler.el ends here
