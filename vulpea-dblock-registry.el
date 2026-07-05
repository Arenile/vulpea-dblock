;;; vulpea-dblock-registry.el --- Subscription registry for vulpea-dblock -*- lexical-binding: t; -*-

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

;; Subscription registry and change matching for vulpea-dblock.
;;
;; Each dynamic block instance open in a buffer is represented by a
;; `vulpea-dblock--sub' struct.  Subs are kept in a central table plus
;; secondary indices used to compute the affected set of a database
;; change event cheaply:
;;
;;   tag       -> subs whose candidate query depends on that tag
;;   target id -> subs with a :backlinks-to / :links-from dependency
;;   path      -> subs whose last rendered result included a note from
;;                that file (catches "note left the result set" and
;;                member-note edits that no other index can see)
;;   globals   -> subs with no indexable dependency (:todo-only,
;;                :filter, plain queries); dirtied by every event
;;
;; Matching over-approximates by design: marking a sub dirty only
;; schedules a cheap re-verification (candidate query + result
;; signature compare), never an unconditional re-render, so false
;; positives cost almost nothing.
;;
;; This file also owns the params DSL: parsing block headers,
;; normalizing new-style (`vulpea') and legacy (`node-list') params
;; into one canonical plist, and computing dependency keys.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'org)
(require 'org-macs)
(require 'vulpea)

(defgroup vulpea-dblock nil
  "Declarative vulpea dynamic blocks with reactive, incremental refresh."
  :group 'vulpea
  :prefix "vulpea-dblock-")

(defconst vulpea-dblock-block-names '("vulpea" "node-list")
  "Dynamic block names owned by vulpea-dblock.")

;;; Subscription struct

(cl-defstruct (vulpea-dblock--sub
               (:constructor vulpea-dblock--sub-create)
               (:copier nil))
  "One dynamic block instance subscribed to database changes."
  id              ; gensym, stable identity for display/debugging
  buffer          ; buffer containing the block
  marker          ; marker at bol of the #+BEGIN line
  name            ; block name string: "vulpea" or "node-list"
  raw-params      ; plist as read from the header (for equality checks)
  params          ; normalized plist, see `vulpea-dblock--normalize-params'
  dep-keys        ; (:tags TAGS :targets IDS :global BOOL)
  result-sig      ; last query result signature: list of (id . mtime)
  last-paths      ; file paths of notes in the last result set
  dirty           ; non-nil when a change event may have affected us
  broken          ; non-nil when marker no longer points at our header
  queued          ; non-nil while sitting in the scheduler queue
  last-query-ms   ; duration of last candidate query (for the report)
  last-render-ms) ; duration of last render+write (for the report)

;;; Registry state

(defvar vulpea-dblock--subs (make-hash-table :test 'eq)
  "All registered subs: sub -> t.")

(defvar vulpea-dblock--index-tags (make-hash-table :test 'equal)
  "Tag string -> list of subs depending on that tag.")

(defvar vulpea-dblock--index-targets (make-hash-table :test 'equal)
  "Note id -> list of subs with a link dependency on that note.")

(defvar vulpea-dblock--index-paths (make-hash-table :test 'equal)
  "File path -> list of subs whose last result included a note from it.")

(defvar vulpea-dblock--global-subs nil
  "Subs with no indexable dependency; affected by every event.")

(defvar-local vulpea-dblock--buffer-subs nil
  "Subs registered for the current buffer, for O(1) cleanup.")

(defun vulpea-dblock--registered-p (sub)
  "Return non-nil if SUB is currently registered."
  (gethash sub vulpea-dblock--subs))

(defun vulpea-dblock--all-subs ()
  "Return a list of all registered subs."
  (hash-table-keys vulpea-dblock--subs))

;;; Params DSL

(defun vulpea-dblock--unquote (x)
  "Strip a quote wrapper from X, if any."
  (if (eq (car-safe x) 'quote) (cadr x) x))

(defun vulpea-dblock--stringify (x)
  "Return X as a string (symbols and numbers get printed)."
  (if (stringp x) x (format "%s" x)))

(defun vulpea-dblock--listify (x)
  "Return X as a list; nil stays nil, an atom becomes a singleton."
  (cond ((null x) nil)
        ((listp x) x)
        (t (list x))))

(defun vulpea-dblock--normalize-target (x)
  "Normalize a :backlinks-to / :links-from value X.
Returns nil, the symbol `self', or a string (id, title, or alias)."
  (let ((x (vulpea-dblock--unquote x)))
    (cond ((null x) nil)
          ((eq x 'self) 'self)
          (t (vulpea-dblock--stringify x)))))

(defun vulpea-dblock--normalize-params (raw &optional legacy)
  "Normalize RAW block header params into a canonical plist.

RAW is the plist read from a #+BEGIN header.  LEGACY non-nil means the
block is a `node-list' block: legacy defaults apply and a :format
function uses the old (TITLE ID TODO PRIORITY) calling convention.

Legacy keys (:tag, :tags-match, :order-by, :empty-message, :todo-only)
are accepted for both block types; new-style keys win when both are
present."
  (let* ((tag (plist-get raw :tag))
         (tags (vulpea-dblock--listify (vulpea-dblock--unquote (plist-get raw :tags))))
         (tags-any (vulpea-dblock--listify (vulpea-dblock--unquote (plist-get raw :tags-any))))
         (tags-match (vulpea-dblock--unquote (plist-get raw :tags-match)))
         (todo (vulpea-dblock--unquote (plist-get raw :todo)))
         all any)
    ;; Legacy :tags with :tags-match 'or means "any"; default is "all".
    (if (and tags (eq tags-match 'or))
        (setq any tags)
      (setq all tags))
    (when tag (push tag all))
    (setq any (append any tags-any))
    (list
     :legacy (and legacy t)
     :tags (mapcar #'vulpea-dblock--stringify all)
     :tags-any (mapcar #'vulpea-dblock--stringify any)
     :backlinks-to (vulpea-dblock--normalize-target (plist-get raw :backlinks-to))
     :links-from (vulpea-dblock--normalize-target (plist-get raw :links-from))
     ;; :todo t means "any todo state", i.e. :todo-only.
     :todo (cond ((null todo) nil)
                 ((eq todo t) nil)
                 ((listp todo) (mapcar #'vulpea-dblock--stringify todo))
                 (t (list (vulpea-dblock--stringify todo))))
     :todo-only (and (or (eq todo t) (plist-get raw :todo-only)) t)
     :exclude-done (and (plist-get raw :exclude-done) t)
     :priority (when-let* ((p (plist-get raw :priority)))
                 (vulpea-dblock--stringify p))
     :file (plist-get raw :file)
     :filter (vulpea-dblock--unquote (plist-get raw :filter))
     :sort (or (vulpea-dblock--unquote (plist-get raw :sort))
               (vulpea-dblock--unquote (plist-get raw :order-by))
               'title)
     :reverse (and (plist-get raw :reverse) t)
     :limit (plist-get raw :limit)
     :format (vulpea-dblock--unquote (plist-get raw :format))
     :empty (or (plist-get raw :empty)
                (plist-get raw :empty-message)
                (if legacy "No matching nodes found.\n" "/none/")))))

;;; Dependency keys

(defun vulpea-dblock--self-id-at (marker)
  "Return the ID owning the block at MARKER: nearest heading or file ID."
  (when (and (markerp marker) (marker-buffer marker))
    (ignore-errors
      (org-with-point-at marker
        (org-entry-get nil "ID" t)))))

(defun vulpea-dblock--resolve-id (target)
  "Resolve TARGET (note id, title, or alias) to a note id, or nil.
Returns nil when the database is unavailable or nothing matches."
  (ignore-errors
    (cond
     ((vulpea-db-get-by-id target) target)
     (t (when-let* ((note (car (vulpea-db-query
                                (lambda (n)
                                  (or (string-equal (vulpea-note-title n) target)
                                      (member target (vulpea-note-aliases n))))))))
          (vulpea-note-id note))))))

(defun vulpea-dblock--dep-keys-for (params marker)
  "Compute dependency keys for normalized PARAMS of a block at MARKER.

Returns (:tags TAGS :targets IDS :global BOOL).  A sub is global when
it has no indexable dependency, or when a link target could not be
resolved (over-approximating keeps verification correct)."
  (let ((tags (seq-uniq (append (plist-get params :tags)
                                (plist-get params :tags-any))))
        (unresolved nil)
        (targets nil))
    (dolist (key '(:backlinks-to :links-from))
      (when-let* ((tgt (plist-get params key)))
        (let ((id (if (eq tgt 'self)
                      (vulpea-dblock--self-id-at marker)
                    (vulpea-dblock--resolve-id tgt))))
          (if id (push id targets) (setq unresolved t)))))
    (list :tags tags
          :targets (seq-uniq targets)
          :global (or unresolved (and (null tags) (null targets))))))

;;; Index maintenance

(defun vulpea-dblock--index-put (table key sub)
  "Add SUB under KEY in index TABLE."
  (puthash key (cons sub (gethash key table)) table))

(defun vulpea-dblock--index-del (table key sub)
  "Remove SUB from KEY in index TABLE."
  (let ((rest (delq sub (gethash key table))))
    (if rest (puthash key rest table) (remhash key table))))

(defun vulpea-dblock--index-add-sub (sub)
  "Insert SUB into the dependency indices per its dep-keys."
  (let ((deps (vulpea-dblock--sub-dep-keys sub)))
    (dolist (tag (plist-get deps :tags))
      (vulpea-dblock--index-put vulpea-dblock--index-tags tag sub))
    (dolist (id (plist-get deps :targets))
      (vulpea-dblock--index-put vulpea-dblock--index-targets id sub))
    (when (plist-get deps :global)
      (push sub vulpea-dblock--global-subs))))

(defun vulpea-dblock--index-remove-sub (sub)
  "Remove SUB from all dependency indices."
  (let ((deps (vulpea-dblock--sub-dep-keys sub)))
    (dolist (tag (plist-get deps :tags))
      (vulpea-dblock--index-del vulpea-dblock--index-tags tag sub))
    (dolist (id (plist-get deps :targets))
      (vulpea-dblock--index-del vulpea-dblock--index-targets id sub))
    (setq vulpea-dblock--global-subs
          (delq sub vulpea-dblock--global-subs))))

(defun vulpea-dblock--set-sub-paths (sub paths)
  "Record PATHS as the file set of SUB's last result, updating the index."
  (dolist (path (vulpea-dblock--sub-last-paths sub))
    (vulpea-dblock--index-del vulpea-dblock--index-paths path sub))
  (setf (vulpea-dblock--sub-last-paths sub) paths)
  (dolist (path paths)
    (vulpea-dblock--index-put vulpea-dblock--index-paths path sub)))

;;; Register / unregister

(defun vulpea-dblock--register (pos name raw-params)
  "Register a new sub for the block NAME with RAW-PARAMS at POS.
POS is the bol of the #+BEGIN line in the current buffer.
The new sub starts dirty.  Returns the sub."
  (let* ((marker (copy-marker pos))
         (params (vulpea-dblock--normalize-params
                  raw-params (string= name "node-list")))
         (sub (vulpea-dblock--sub-create
               :id (gensym "vulpea-dblock-sub-")
               :buffer (current-buffer)
               :marker marker
               :name name
               :raw-params raw-params
               :params params
               :dep-keys (vulpea-dblock--dep-keys-for params marker)
               :dirty t)))
    (puthash sub t vulpea-dblock--subs)
    (vulpea-dblock--index-add-sub sub)
    (push sub vulpea-dblock--buffer-subs)
    sub))

(defun vulpea-dblock--sub-refresh-params (sub name raw-params)
  "Update SUB after its header changed to NAME with RAW-PARAMS.
Recomputes normalized params and dep-keys, resets the result
signature and marks SUB dirty."
  (vulpea-dblock--index-remove-sub sub)
  (let ((params (vulpea-dblock--normalize-params
                 raw-params (string= name "node-list"))))
    (setf (vulpea-dblock--sub-name sub) name
          (vulpea-dblock--sub-raw-params sub) raw-params
          (vulpea-dblock--sub-params sub) params
          (vulpea-dblock--sub-dep-keys sub)
          (vulpea-dblock--dep-keys-for params (vulpea-dblock--sub-marker sub))
          (vulpea-dblock--sub-result-sig sub) nil
          (vulpea-dblock--sub-broken sub) nil
          (vulpea-dblock--sub-dirty sub) t))
  (vulpea-dblock--index-add-sub sub)
  sub)

(defun vulpea-dblock--unregister (sub)
  "Remove SUB from the registry, all indices, and free its marker."
  (when (vulpea-dblock--registered-p sub)
    (remhash sub vulpea-dblock--subs)
    (vulpea-dblock--index-remove-sub sub)
    (dolist (path (vulpea-dblock--sub-last-paths sub))
      (vulpea-dblock--index-del vulpea-dblock--index-paths path sub))
    (setf (vulpea-dblock--sub-last-paths sub) nil)
    (let ((buf (vulpea-dblock--sub-buffer sub)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq vulpea-dblock--buffer-subs
                (delq sub vulpea-dblock--buffer-subs)))))
    (when (markerp (vulpea-dblock--sub-marker sub))
      (set-marker (vulpea-dblock--sub-marker sub) nil))))

(defun vulpea-dblock--forget-buffer ()
  "Unregister all subs of the current buffer (for `kill-buffer-hook')."
  (dolist (sub (copy-sequence vulpea-dblock--buffer-subs))
    (vulpea-dblock--unregister sub)))

(defun vulpea-dblock--registry-clear ()
  "Drop every sub, free markers, and reset all indices."
  (maphash (lambda (sub _)
             (when (markerp (vulpea-dblock--sub-marker sub))
               (set-marker (vulpea-dblock--sub-marker sub) nil)))
           vulpea-dblock--subs)
  (clrhash vulpea-dblock--subs)
  (clrhash vulpea-dblock--index-tags)
  (clrhash vulpea-dblock--index-targets)
  (clrhash vulpea-dblock--index-paths)
  (setq vulpea-dblock--global-subs nil)
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'vulpea-dblock--buffer-subs buf)
      (with-current-buffer buf
        (kill-local-variable 'vulpea-dblock--buffer-subs)))))

;;; Change matching

(defun vulpea-dblock--match-event (event)
  "Return the subs possibly affected by EVENT.
EVENT is a plist (:path PATH :tags TAGS :ids IDS :dests IDS) built by
the publisher from the old+new state of one file."
  (let ((acc (copy-sequence vulpea-dblock--global-subs)))
    (dolist (tag (plist-get event :tags))
      (setq acc (append (gethash tag vulpea-dblock--index-tags) acc)))
    (dolist (id (append (plist-get event :ids) (plist-get event :dests)))
      (setq acc (append (gethash id vulpea-dblock--index-targets) acc)))
    (when-let* ((path (plist-get event :path)))
      (setq acc (append (gethash path vulpea-dblock--index-paths) acc)))
    (seq-uniq acc #'eq)))

;;; Buffer scanning

(defun vulpea-dblock--buffer-eligible-p (&optional buffer)
  "Return non-nil if BUFFER should have its blocks registered.
Only file-visiting org buffers under `vulpea-db-sync-directories'
qualify; capture and other non-file buffers never do."
  (with-current-buffer (or buffer (current-buffer))
    (and buffer-file-name
         (derived-mode-p 'org-mode)
         (or (not (boundp 'vulpea-db-sync-directories))
             (null vulpea-db-sync-directories)
             (seq-some (lambda (dir)
                         (file-in-directory-p buffer-file-name
                                              (expand-file-name dir)))
                       vulpea-db-sync-directories)))))

(defun vulpea-dblock--parse-header-at-point ()
  "Parse the dblock header on the current line, point at bol.
Returns (NAME . RAW-PARAMS) when the line is a #+BEGIN header for one
of `vulpea-dblock-block-names', else nil.  Malformed params yield nil
params rather than an error."
  (when (looking-at org-dblock-start-re)
    (let ((name (match-string-no-properties 1))
          (pstr (match-string-no-properties 3)))
      (when (member name vulpea-dblock-block-names)
        (cons name
              (when (and pstr (not (string-blank-p pstr)))
                (condition-case nil
                    (car (read-from-string (concat "(" pstr ")")))
                  (error nil))))))))

(defun vulpea-dblock--marker-bol (sub)
  "Return the bol position of SUB's marker, or nil."
  (let ((marker (vulpea-dblock--sub-marker sub)))
    (when (and (markerp marker) (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (save-excursion (goto-char marker) (pos-bol))))))

(defun vulpea-dblock--scan-buffer (&optional buffer)
  "Synchronize subscriptions with the blocks present in BUFFER.

Adds subs for new blocks, refreshes subs whose params changed,
unregisters subs whose blocks vanished.  Returns the list of subs
that are new or changed (all dirty), which the caller should hand
to the scheduler."
  (with-current-buffer (or buffer (current-buffer))
    (when (vulpea-dblock--buffer-eligible-p)
      (let ((found nil))
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward org-dblock-start-re nil t)
           (forward-line 0)
           (when-let* ((header (vulpea-dblock--parse-header-at-point)))
             (push (list (point) (car header) (cdr header)) found))
           (forward-line 1)))
        (setq found (nreverse found))
        (let ((stale (copy-sequence vulpea-dblock--buffer-subs))
              (changed nil))
          (pcase-dolist (`(,pos ,name ,raw) found)
            (let ((sub (seq-find
                        (lambda (s)
                          (eql (vulpea-dblock--marker-bol s) pos))
                        stale)))
              (cond
               ((and sub
                     (equal (vulpea-dblock--sub-name sub) name)
                     (equal (vulpea-dblock--sub-raw-params sub) raw))
                (setq stale (delq sub stale))
                (setf (vulpea-dblock--sub-broken sub) nil))
               (sub
                (setq stale (delq sub stale))
                (push (vulpea-dblock--sub-refresh-params sub name raw)
                      changed))
               (t
                (push (vulpea-dblock--register pos name raw) changed)))))
          (dolist (sub stale)
            (vulpea-dblock--unregister sub))
          (nreverse changed))))))

(provide 'vulpea-dblock-registry)
;;; vulpea-dblock-registry.el ends here
