;;; test-scheduler.el --- Tests for vulpea-dblock-scheduler -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:

;; Tests for the dirty queue, budgeted resumable ticks, storm
;; collapsing, and visible-first ordering.  The tick function is
;; driven directly; no real idle timers.

;;; Code:

(require 'test-helper)

(defun vulpea-dblock-test--fake-sub (&optional buffer)
  "Register a minimal sub bound to BUFFER (default current buffer)."
  (let ((sub (vulpea-dblock--sub-create
              :id (gensym "test-sub-")
              :buffer (or buffer (current-buffer))
              :marker nil
              :name "vulpea"
              :params (vulpea-dblock--normalize-params nil)
              :dep-keys '(:tags nil :targets nil :global t)
              :dirty nil)))
    (puthash sub t vulpea-dblock--subs)
    (push sub vulpea-dblock--global-subs)
    sub))

(ert-deftest vulpea-dblock-test-enqueue-dedup ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let ((sub (vulpea-dblock-test--fake-sub)))
        (vulpea-dblock--enqueue sub)
        (vulpea-dblock--enqueue sub)
        (should (= (length vulpea-dblock--queue) 1))
        (should (vulpea-dblock--sub-dirty sub))
        (should (vulpea-dblock--sub-queued sub))))))

(ert-deftest vulpea-dblock-test-publish-matches-and-arms-timer ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let ((sub (vulpea-dblock-test--fake-sub)))
        (vulpea-dblock--publish '(:path "/x.org" :tags nil :ids nil :dests nil))
        (should (memq sub vulpea-dblock--queue))
        (should (timerp vulpea-dblock--debounce-timer))
        ;; Re-publish only re-arms; queued work is never cancelled.
        (vulpea-dblock--publish '(:path "/y.org" :tags nil :ids nil :dests nil))
        (should (= (length vulpea-dblock--queue) 1))))))

(ert-deftest vulpea-dblock-test-storm-marks-all-dirty ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      ;; One global sub and one tag-indexed sub that no event matches.
      (let ((global (vulpea-dblock-test--fake-sub))
            (tagged (vulpea-dblock--sub-create
                     :id (gensym) :buffer (current-buffer) :name "vulpea"
                     :params (vulpea-dblock--normalize-params '(:tags (never)))
                     :dep-keys '(:tags ("never") :targets nil :global nil))))
        (puthash tagged t vulpea-dblock--subs)
        (vulpea-dblock--index-add-sub tagged)
        (let ((vulpea-dblock-storm-threshold 5))
          (dotimes (i 6)
            (vulpea-dblock--publish
             (list :path (format "/f%d.org" i) :tags nil :ids nil :dests nil)))
          (should vulpea-dblock--storm)
          ;; Past the threshold everything is queued, tagged sub included.
          (should (memq tagged vulpea-dblock--queue))
          (should (memq global vulpea-dblock--queue))
          ;; Further storm events add no per-event work.
          (let ((len (length vulpea-dblock--queue)))
            (vulpea-dblock--publish '(:path "/g.org" :tags ("never") :ids nil :dests nil))
            (should (= (length vulpea-dblock--queue) len))))))))

(ert-deftest vulpea-dblock-test-tick-budget-keeps-remainder-queued ()
  "Interrupted work stays in the queue; nothing restarts from scratch."
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let ((processed nil))
        (dotimes (_ 5) (vulpea-dblock--enqueue (vulpea-dblock-test--fake-sub)))
        (cl-letf (((symbol-function 'vulpea-dblock--process-sub)
                   (lambda (sub &optional _force)
                     (push sub processed)
                     (sleep-for 0.02)
                     'verified))
                  ;; Timers don't run in batch; stub arming.
                  ((symbol-function 'vulpea-dblock--arm-tick) #'ignore))
          (let ((vulpea-dblock-tick-budget 0.03))
            (vulpea-dblock--tick))
          ;; Budget of 30ms with 20ms subs: at most 2 processed.
          (should (<= (length processed) 2))
          (should (>= (length vulpea-dblock--queue) 3))
          ;; The remainder drains without reprocessing finished subs.
          (let ((first-pass (length processed)))
            (let ((vulpea-dblock-tick-budget 10))
              (vulpea-dblock--tick))
            (should (= (length processed) 5))
            (should (= (length (seq-uniq processed)) 5))
            (should (> (length processed) first-pass)))
          (should-not vulpea-dblock--queue))))))

(ert-deftest vulpea-dblock-test-dequeue-prefers-visible ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let* ((hidden (vulpea-dblock-test--fake-sub))
             (visible (vulpea-dblock-test--fake-sub)))
        (vulpea-dblock--enqueue hidden)
        (vulpea-dblock--enqueue visible)
        (cl-letf (((symbol-function 'vulpea-dblock--sub-visible-p)
                   (lambda (sub) (eq sub visible))))
          (should (eq (vulpea-dblock--dequeue) visible))
          (should (eq (vulpea-dblock--dequeue) hidden)))))))

(ert-deftest vulpea-dblock-test-drain-drops-dead-buffer-subs ()
  (vulpea-dblock-test-with-clean-registry
    (let (sub)
      (with-temp-buffer
        (setq sub (vulpea-dblock-test--fake-sub))
        (vulpea-dblock--enqueue sub))
      ;; Buffer is dead; drain must unregister without erroring.
      (vulpea-dblock--drain)
      (should-not (vulpea-dblock--registered-p sub))
      (should-not vulpea-dblock--queue))))

(ert-deftest vulpea-dblock-test-drain-handles-broken-via-rescan ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer
        "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
      (let ((sub (car (vulpea-dblock--scan-buffer))))
        (vulpea-dblock--enqueue sub)
        ;; Invalidate the block under the sub's feet.
        (erase-buffer)
        (insert "nothing here\n")
        (vulpea-dblock--drain)
        (should-not (vulpea-dblock--registered-p sub))
        (should-not vulpea-dblock--buffer-subs)
        (should-not vulpea-dblock--queue)))))

(ert-deftest vulpea-dblock-test-unregistered-subs-skipped ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let ((sub (vulpea-dblock-test--fake-sub))
            (calls 0))
        (vulpea-dblock--enqueue sub)
        (vulpea-dblock--unregister sub)
        (cl-letf (((symbol-function 'vulpea-dblock--process-sub)
                   (lambda (&rest _) (cl-incf calls) 'verified)))
          (vulpea-dblock--drain))
        (should (= calls 0))))))

(ert-deftest vulpea-dblock-test-shutdown-clears-state ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (let ((sub (vulpea-dblock-test--fake-sub)))
        (vulpea-dblock--publish '(:path "/x.org" :tags nil :ids nil :dests nil))
        (should vulpea-dblock--queue)
        (vulpea-dblock--shutdown)
        (should-not vulpea-dblock--queue)
        (should-not vulpea-dblock--debounce-timer)
        (should-not (vulpea-dblock--sub-queued sub))))))

(provide 'test-scheduler)
;;; test-scheduler.el ends here
