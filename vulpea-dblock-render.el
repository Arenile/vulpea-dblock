;;; vulpea-dblock-render.el --- Query and render pipeline for vulpea-dblock -*- lexical-binding: t; -*-

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

;; Query execution, formatting, and the diff-write for vulpea-dblock.
;;
;; The pipeline for one sub is:
;;
;;   1. Re-locate the block via its marker; header must still parse to
;;      the same name+params, otherwise the sub is broken.
;;   2. Run the query: indexed candidate selection first
;;      (tags/backlinks), post-filters, sort, limit.
;;   3. Compare the result signature (ordered (id . mtime) pairs)
;;      against the last one.  Unchanged -> done, no rendering.
;;   4. Render to a string, byte-compare against the current block
;;      body.  Identical -> done, buffer untouched.
;;   5. Otherwise replace the body in one edit, preserving point and
;;      the modified flag when nothing actually changed.
;;
;; The invariant tying this to org's own writer path: the block body
;; region (between the #+BEGIN line and the #+END line) always equals
;; the string a writer would insert, plus one final newline.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'format-spec)
(require 'org)
(require 'org-macs)
(require 'vulpea)
(require 'vulpea-dblock-registry)

(defcustom vulpea-dblock-default-format "- [[id:%i][%t]]"
  "Default line format for `vulpea' blocks.
Supported specs: %i id, %t title, %o todo state, %p priority,
%% a literal percent sign."
  :type 'string
  :group 'vulpea-dblock)

;;; Note helpers

(defun vulpea-dblock--priority-string (priority)
  "Normalize PRIORITY (character, string, or nil) to a string or nil."
  (cond ((null priority) nil)
        ((characterp priority) (char-to-string priority))
        ((stringp priority) priority)
        (t (format "%s" priority))))

(defun vulpea-dblock--link-dest (link)
  "Return the destination id of LINK when it is an id link, else nil.
Handles both link shapes vulpea has used: plists with :type/:dest
and (TYPE . DEST) cons cells."
  (cond
   ((and (consp link) (keywordp (car link)))
    (when (equal (plist-get link :type) "id")
      (plist-get link :dest)))
   ((consp link)
    (when (equal (car link) "id")
      (cdr link)))))

(defun vulpea-dblock--note-link-dests (note)
  "Return the list of note ids that NOTE links to via id links."
  (delete-dups (delq nil (mapcar #'vulpea-dblock--link-dest
                                 (vulpea-note-links note)))))

;;; Query

(defun vulpea-dblock--target-id (target self-id)
  "Resolve TARGET from normalized params to a note id, or nil.
SELF-ID substitutes for the symbol `self'."
  (cond ((eq target 'self) self-id)
        ((stringp target) (vulpea-dblock--resolve-id target))))

(defun vulpea-dblock--sort-key (note sort)
  "Return the sort key of NOTE for the SORT spec."
  (pcase sort
    ('title (or (vulpea-note-title note) ""))
    ('mtime (or (vulpea-note-modified-at note) 0))
    ('todo (or (vulpea-note-todo note) ""))
    ('priority (or (vulpea-dblock--priority-string
                    (vulpea-note-priority note))
                   ""))
    ((pred functionp) (funcall sort note))
    (_ (or (vulpea-note-title note) ""))))

(defun vulpea-dblock--key-less-p (a b)
  "Compare sort keys A and B: numerically when both numbers, else as strings."
  (if (and (numberp a) (numberp b))
      (< a b)
    (string-lessp (if (stringp a) a (format "%s" a))
                  (if (stringp b) b (format "%s" b)))))

(defun vulpea-dblock--run-query (params &optional self-id)
  "Run the query described by normalized PARAMS and return notes.

Candidate selection uses vulpea's indexed queries when a :tags,
:tags-any, :backlinks-to or :links-from param is present, falling
back to a full `vulpea-db-query' otherwise.  All other constraints
are applied as post-filters, then sort, reverse and limit.

SELF-ID resolves the symbol `self' in link params.  An unresolvable
link target yields an empty result rather than an error."
  (let* ((tags (plist-get params :tags))
         (tags-any (plist-get params :tags-any))
         (bl (plist-get params :backlinks-to))
         (lf (plist-get params :links-from))
         (bl-id (and bl (vulpea-dblock--target-id bl self-id)))
         (lf-id (and lf (vulpea-dblock--target-id lf self-id)))
         (used nil)
         (notes
          (cond
           (tags
            (setq used :tags)
            (vulpea-db-query-by-tags-every tags))
           (tags-any
            (setq used :tags-any)
            (vulpea-db-query-by-tags-some tags-any))
           (bl
            (setq used :backlinks-to)
            (when bl-id
              (vulpea-db-query-by-links-some (list bl-id) "id")))
           (lf
            (setq used :links-from)
            (when-let* ((target (and lf-id (vulpea-db-get-by-id lf-id))))
              (vulpea-db-query-by-ids
               (vulpea-dblock--note-link-dests target))))
           (t (vulpea-db-query)))))
    ;; Post-filters for constraints not used for candidate selection.
    (when (and tags-any (not (eq used :tags-any)))
      (setq notes (seq-filter
                   (lambda (n)
                     (seq-some (lambda (tag) (member tag (vulpea-note-tags n)))
                               tags-any))
                   notes)))
    (when (and bl (not (eq used :backlinks-to)))
      (setq notes (and bl-id
                       (seq-filter
                        (lambda (n)
                          (member bl-id (vulpea-dblock--note-link-dests n)))
                        notes))))
    (when (and lf (not (eq used :links-from)))
      (let ((dests (when-let* ((target (and lf-id (vulpea-db-get-by-id lf-id))))
                     (vulpea-dblock--note-link-dests target))))
        (setq notes (seq-filter
                     (lambda (n) (member (vulpea-note-id n) dests))
                     notes))))
    (when-let* ((todos (plist-get params :todo)))
      (setq notes (seq-filter
                   (lambda (n) (member (vulpea-note-todo n) todos))
                   notes)))
    (when (plist-get params :todo-only)
      (setq notes (seq-filter #'vulpea-note-todo notes)))
    (when (plist-get params :exclude-done)
      (setq notes (seq-remove
                   (lambda (n) (equal (vulpea-note-todo n) "DONE"))
                   notes)))
    (when-let* ((priority (plist-get params :priority)))
      (setq notes (seq-filter
                   (lambda (n)
                     (equal (vulpea-dblock--priority-string
                             (vulpea-note-priority n))
                            priority))
                   notes)))
    (when-let* ((file (plist-get params :file)))
      (setq notes (seq-filter
                   (lambda (n)
                     (string-match-p (regexp-quote file)
                                     (vulpea-note-path n)))
                   notes)))
    (when-let* ((filter (plist-get params :filter)))
      (when (functionp filter)
        (setq notes (seq-filter filter notes))))
    ;; Sort, reverse, limit.
    (let ((sort (plist-get params :sort)))
      (setq notes (sort (copy-sequence notes)
                        (lambda (a b)
                          (vulpea-dblock--key-less-p
                           (vulpea-dblock--sort-key a sort)
                           (vulpea-dblock--sort-key b sort))))))
    (when (plist-get params :reverse)
      (setq notes (nreverse notes)))
    (when-let* ((limit (plist-get params :limit)))
      (setq notes (seq-take notes limit)))
    notes))

;;; Result signature

(defun vulpea-dblock--result-sig (notes)
  "Return the result signature of the ordered NOTES list.

Includes, per note, every field the default formats render (id,
title, todo, priority) plus the note's mtime as a catch-all for
custom :format functions.  Title/todo/priority are carried
explicitly because vulpea stores mtime at one-second granularity:
a retitle in the same second as the previous sync would otherwise
produce an identical signature and skip the re-render."
  (mapcar (lambda (n)
            (list (vulpea-note-id n)
                  (vulpea-note-title n)
                  (vulpea-note-todo n)
                  (vulpea-note-priority n)
                  (vulpea-note-modified-at n)))
          notes))

;;; Rendering

(defun vulpea-dblock--legacy-format-note (title id todo priority)
  "Default `node-list' line formatter, byte-identical to the old writer."
  (format "- %s%s[[id:%s][%s]]\n"
          (if priority (format "[#%s] " priority) "")
          (if todo (format "%s " todo) "")
          id title))

(defun vulpea-dblock--format-note (note fmt)
  "Render one NOTE to a line using FMT (a spec string or a function).
A function is called with the note and must return the line."
  (cond
   ((and fmt (functionp fmt))
    (funcall fmt note))
   ((stringp fmt)
    (format-spec fmt
                 `((?i . ,(vulpea-note-id note))
                   (?t . ,(or (vulpea-note-title note) ""))
                   (?o . ,(or (vulpea-note-todo note) ""))
                   (?p . ,(or (vulpea-dblock--priority-string
                               (vulpea-note-priority note))
                              "")))
                 'ignore))
   (t (vulpea-dblock--format-note note vulpea-dblock-default-format))))

(defun vulpea-dblock--render-string (notes params)
  "Render NOTES per PARAMS to the string a block writer would insert.
No trailing newline is guaranteed; the block body region equals this
string plus one final newline (see `vulpea-dblock--body-string')."
  (cond
   ((null notes)
    (plist-get params :empty))
   ((plist-get params :legacy)
    ;; Legacy formatters are called as (FN TITLE ID TODO PRIORITY) and
    ;; return newline-terminated strings, exactly like the old writer.
    (let ((fmt (let ((f (plist-get params :format)))
                 (if (and f (functionp f))
                     f
                   #'vulpea-dblock--legacy-format-note))))
      (mapconcat (lambda (n)
                   (funcall fmt
                            (vulpea-note-title n)
                            (vulpea-note-id n)
                            (vulpea-note-todo n)
                            (vulpea-dblock--priority-string
                             (vulpea-note-priority n))))
                 notes "")))
   (t
    (let ((fmt (or (plist-get params :format) vulpea-dblock-default-format)))
      (mapconcat (lambda (n)
                   (string-remove-suffix
                    "\n" (vulpea-dblock--format-note n fmt)))
                 notes "\n")))))

(defun vulpea-dblock--body-string (notes params)
  "Return the exact block body text for NOTES rendered per PARAMS."
  (concat (vulpea-dblock--render-string notes params) "\n"))

;;; Locate and process

(defun vulpea-dblock--locate (sub)
  "Locate SUB's block in the current (widened) buffer.
Returns (HEADER-BOL BODY-BEG BODY-END), or nil when the marker no
longer points at a matching header (the sub is then broken)."
  (let ((marker (vulpea-dblock--sub-marker sub)))
    (when (and (markerp marker)
               (eq (marker-buffer marker) (current-buffer)))
      (save-excursion
        (goto-char marker)
        (forward-line 0)
        (let ((header-bol (point))
              (header (vulpea-dblock--parse-header-at-point)))
          (when (and header
                     (equal (car header) (vulpea-dblock--sub-name sub))
                     (equal (cdr header) (vulpea-dblock--sub-raw-params sub)))
            (let ((body-beg (min (1+ (pos-eol)) (point-max))))
              (goto-char body-beg)
              (when (re-search-forward org-dblock-end-re nil t)
                (list header-bol body-beg
                      (max body-beg (match-beginning 0)))))))))))

(defun vulpea-dblock--sub-needs-self-p (sub)
  "Return non-nil when SUB's params reference the symbol `self'."
  (let ((params (vulpea-dblock--sub-params sub)))
    (or (eq (plist-get params :backlinks-to) 'self)
        (eq (plist-get params :links-from) 'self))))

(defun vulpea-dblock--process-sub (sub &optional force)
  "Verify and, when needed, re-render SUB's block.

Returns one of:
  dead      - buffer is gone; SUB was unregistered
  broken    - marker no longer points at the block; caller must rescan
  verified  - result signature unchanged; nothing rendered
  unchanged - re-rendered but byte-identical; buffer untouched
  updated   - block body replaced

FORCE skips the signature shortcut (used by the manual refresh
commands); the byte-compare still prevents no-op buffer edits.
Clears the dirty flag except for dead/broken outcomes."
  (let ((buf (vulpea-dblock--sub-buffer sub)))
    (if (not (buffer-live-p buf))
        (progn (vulpea-dblock--unregister sub) 'dead)
      (with-current-buffer buf
        (org-with-wide-buffer
         (let ((loc (vulpea-dblock--locate sub)))
           (if (null loc)
               (progn (setf (vulpea-dblock--sub-broken sub) t) 'broken)
             (pcase-let ((`(,_header-bol ,body-beg ,body-end) loc))
               (let* ((params (vulpea-dblock--sub-params sub))
                      (self-id (when (vulpea-dblock--sub-needs-self-p sub)
                                 (vulpea-dblock--self-id-at
                                  (vulpea-dblock--sub-marker sub))))
                      (t0 (float-time))
                      (notes (vulpea-dblock--run-query params self-id))
                      (sig (vulpea-dblock--result-sig notes)))
                 (setf (vulpea-dblock--sub-last-query-ms sub)
                       (* 1000 (- (float-time) t0)))
                 (if (and (not force)
                          (equal sig (vulpea-dblock--sub-result-sig sub)))
                     (progn
                       (setf (vulpea-dblock--sub-dirty sub) nil)
                       'verified)
                   (let* ((t1 (float-time))
                          (body (vulpea-dblock--body-string notes params))
                          (current (buffer-substring-no-properties
                                    body-beg body-end))
                          (outcome
                           (if (string= body current)
                               'unchanged
                             (let ((was-modified (buffer-modified-p))
                                   (hash (buffer-hash)))
                               (save-excursion
                                 (replace-region-contents
                                  body-beg body-end (lambda () body)))
                               ;; Belt and braces: the byte-compare above
                               ;; should make a no-op write impossible.
                               (when (and (not was-modified)
                                          (equal hash (buffer-hash)))
                                 (restore-buffer-modified-p nil))
                               'updated))))
                     (setf (vulpea-dblock--sub-result-sig sub) sig
                           (vulpea-dblock--sub-dirty sub) nil
                           (vulpea-dblock--sub-last-render-ms sub)
                           (* 1000 (- (float-time) t1)))
                     (when (vulpea-dblock--registered-p sub)
                       (vulpea-dblock--set-sub-paths
                        sub
                        (seq-uniq (mapcar #'vulpea-note-path notes))))
                     outcome)))))))))))

(provide 'vulpea-dblock-render)
;;; vulpea-dblock-render.el ends here
