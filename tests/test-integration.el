;;; test-integration.el --- End-to-end tests with a real vulpea db -*- lexical-binding: t; -*-

;;; Commentary:

;; Integration tests: temp directory, real vulpea database in a temp
;; file, fixture notes written programmatically, buffers opened with
;; `find-file-noselect', scheduler driven by calling the drain
;; function directly (never real idle timers).
;;
;; Skipped wholesale when the vulpea database backend is unavailable
;; in the test environment.

;;; Code:

(require 'test-helper)
(require 'vulpea-db)

(defun vulpea-dblock-test--db-available-p ()
  "Return non-nil when a scratch vulpea database can be opened."
  (let* ((dir (make-temp-file "vulpea-dblock-probe" t))
         (vulpea-db-location (expand-file-name "probe.db" dir)))
    (unwind-protect
        (and (ignore-errors (vulpea-db) t)
             (progn (vulpea-db-close) t))
      (ignore-errors (vulpea-db-close))
      (delete-directory dir t))))

(defmacro vulpea-dblock-test-with-db-env (&rest body)
  "Run BODY with a scratch vulpea db and sync directory, binding `dir'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "vulpea-dblock-it" t))
          (vulpea-db-location (expand-file-name "vulpea.db" dir))
          (vulpea-db-sync-directories (list dir))
          (org-id-locations-file (expand-file-name "org-ids" dir))
          (org-id-locations nil)
          (org-inhibit-startup t))
     (vulpea-db-close)
     (unwind-protect
         (vulpea-dblock-test-with-clean-registry
           ,@body)
       (when (bound-and-true-p vulpea-dblock-mode)
         (vulpea-dblock-mode -1))
       (vulpea-db-close)
       (delete-directory dir t))))

(cl-defun vulpea-dblock-test--write-note (dir id title &key tags body (sync t))
  "Write a file-level note file and (by default) sync it into the db."
  (let ((file (expand-file-name (concat id ".org") dir)))
    (with-temp-file file
      (insert ":PROPERTIES:\n:ID:       " id "\n:END:\n"
              "#+title: " title "\n")
      (when tags
        (insert "#+filetags: :" (string-join tags ":") ":\n"))
      (insert "\n" (or body "")))
    (when sync
      (vulpea-db-update-file file))
    file))

(defun vulpea-dblock-test--block-body (buf header)
  "Return the body text of the block whose header line contains HEADER."
  (with-current-buffer buf
    (org-with-wide-buffer
     (goto-char (point-min))
     (search-forward header)
     (forward-line 1)
     (let ((beg (point)))
       (re-search-forward org-dblock-end-re)
       (buffer-substring-no-properties beg (match-beginning 0))))))

(ert-deftest vulpea-dblock-integration-end-to-end ()
  "Open -> render, targeted invalidation, retitle, deletion."
  (skip-unless (vulpea-dblock-test--db-available-p))
  (vulpea-dblock-test-with-db-env
    (vulpea-dblock-test--write-note dir "id-a" "Alpha" :tags '("paper"))
    (vulpea-dblock-test--write-note dir "id-b" "Beta" :tags '("paper")
                                    :body "Links to [[id:id-a][Alpha]].\n")
    (vulpea-dblock-test--write-note dir "id-c" "Gamma" :tags '("project"))
    (let* ((index (expand-file-name "index.org" dir))
           (_ (with-temp-file index
                (insert "#+title: Index\n\n"
                        "#+BEGIN: vulpea :tags (paper)\n#+END:\n\n"
                        "#+BEGIN: vulpea :backlinks-to \"id-a\"\n#+END:\n")))
           buf)
      (vulpea-dblock-mode 1)
      (setq buf (find-file-noselect index))
      (unwind-protect
          (progn
            ;; Refresh-on-open: opening registered and queued the blocks.
            (should (= (length (buffer-local-value 'vulpea-dblock--buffer-subs buf)) 2))
            (vulpea-dblock--drain)
            (should (equal (vulpea-dblock-test--block-body buf ":tags (paper)")
                           "- [[id:id-a][Alpha]]\n- [[id:id-b][Beta]]\n"))
            (should (equal (vulpea-dblock-test--block-body buf ":backlinks-to")
                           "- [[id:id-b][Beta]]\n"))
            (with-current-buffer buf (basic-save-buffer))
            (vulpea-dblock--drain)

            ;; Unrelated change: the paper blocks are not even enqueued.
            (vulpea-dblock-test--write-note dir "id-c" "Gamma"
                                            :tags '("project")
                                            :body "edited\n")
            (should-not vulpea-dblock--queue)
            (should-not (buffer-modified-p buf))

            ;; Targeted change: tag id-c as paper -> only tag sub re-renders.
            (vulpea-dblock-test--write-note dir "id-c" "Gamma"
                                            :tags '("project" "paper"))
            (should (= (length vulpea-dblock--queue) 1))
            (vulpea-dblock--drain)
            (should (equal (vulpea-dblock-test--block-body buf ":tags (paper)")
                           "- [[id:id-a][Alpha]]\n- [[id:id-b][Beta]]\n- [[id:id-c][Gamma]]\n"))

            ;; Retitle: link descriptions must update even though the id
            ;; set is unchanged (mtime feeds the result signature).
            (with-current-buffer buf (basic-save-buffer))
            (vulpea-dblock-test--write-note dir "id-a" "Alpha Prime"
                                            :tags '("paper"))
            (should vulpea-dblock--queue)
            (vulpea-dblock--drain)
            (should (string-match-p
                     (regexp-quote "[[id:id-a][Alpha Prime]]")
                     (vulpea-dblock-test--block-body buf ":tags (paper)")))

            ;; Deletion: event with empty :new state.
            (let ((file-b (expand-file-name "id-b.org" dir)))
              (delete-file file-b)
              (vulpea-db--delete-file-notes file-b))
            (should vulpea-dblock--queue)
            (vulpea-dblock--drain)
            (should (equal (vulpea-dblock-test--block-body buf ":backlinks-to")
                           "/none/\n"))
            (should-not (string-match-p
                         "id-b"
                         (vulpea-dblock-test--block-body buf ":tags (paper)"))))
        (kill-buffer buf)))))

(ert-deftest vulpea-dblock-integration-self-reference ()
  "A `self' block in a note whose own file just changed."
  (skip-unless (vulpea-dblock-test--db-available-p))
  (vulpea-dblock-test-with-db-env
    (let ((target (vulpea-dblock-test--write-note
                   dir "id-self" "Hub"
                   :body "#+BEGIN: vulpea :backlinks-to self\n#+END:\n")))
      (vulpea-dblock-test--write-note dir "id-x" "Spoke"
                                      :body "See [[id:id-self][Hub]].\n")
      (vulpea-dblock-mode 1)
      (let ((buf (find-file-noselect target)))
        (unwind-protect
            (progn
              (vulpea-dblock--drain)
              (should (equal (vulpea-dblock-test--block-body buf ":backlinks-to self")
                             "- [[id:id-x][Spoke]]\n"))
              ;; The hub's own file changes (rendering changed it above;
              ;; simulate the save-triggered ingestion).
              (with-current-buffer buf (basic-save-buffer))
              (vulpea-db-update-file target)
              (vulpea-dblock--drain)
              (should (equal (vulpea-dblock-test--block-body buf ":backlinks-to self")
                             "- [[id:id-x][Spoke]]\n"))
              (should-not (buffer-modified-p buf)))
          (kill-buffer buf))))))

(ert-deftest vulpea-dblock-integration-node-list-alias ()
  "Legacy node-list blocks render through the alias, byte-identically."
  (skip-unless (vulpea-dblock-test--db-available-p))
  (vulpea-dblock-test-with-db-env
    (vulpea-dblock-test--write-note dir "id-a" "Alpha" :tags '("paper"))
    (let ((index (expand-file-name "legacy.org" dir)))
      (with-temp-file index
        (insert "#+BEGIN: node-list :tag \"paper\"\n#+END:\n"))
      (vulpea-dblock-mode 1)
      (let ((buf (find-file-noselect index)))
        (unwind-protect
            (progn
              (vulpea-dblock--drain)
              ;; Old writer format: bullet, trailing newline per line,
              ;; plus the blank line org's writer path always produced.
              (should (equal (vulpea-dblock-test--block-body buf "node-list")
                             "- [[id:id-a][Alpha]]\n\n")))
          (kill-buffer buf))))))

(ert-deftest vulpea-dblock-integration-migrate-buffer ()
  (skip-unless (vulpea-dblock-test--db-available-p))
  (vulpea-dblock-test-with-db-env
    (vulpea-dblock-test--write-note dir "id-a" "Alpha" :tags '("paper"))
    (let ((index (expand-file-name "migrate.org" dir)))
      (with-temp-file index
        (insert "#+BEGIN: node-list :tag \"paper\" :order-by title :limit 5\n#+END:\n"))
      (vulpea-dblock-mode 1)
      (let ((buf (find-file-noselect index)))
        (unwind-protect
            (with-current-buffer buf
              (vulpea-dblock-migrate-buffer)
              (goto-char (point-min))
              (should (looking-at-p
                       (regexp-quote
                        "#+BEGIN: vulpea :tags (\"paper\") :limit 5 :sort title")))
              ;; The migrated block still works.
              (vulpea-dblock--drain)
              (should (equal (vulpea-dblock-test--block-body buf "vulpea")
                             "- [[id:id-a][Alpha]]\n")))
          (kill-buffer buf))))))

(ert-deftest vulpea-dblock-integration-perf-smoke ()
  "200 notes, 20 blocks: one update touches only the matched subset."
  (skip-unless (vulpea-dblock-test--db-available-p))
  (vulpea-dblock-test-with-db-env
    ;; 20 tags x 10 notes; one block per tag.
    (dotimes (i 200)
      (vulpea-dblock-test--write-note
       dir (format "id-%03d" i) (format "Note %03d" i)
       :tags (list (format "t%02d" (mod i 20)))))
    (let ((index (expand-file-name "dash.org" dir)))
      (with-temp-file index
        (dotimes (tag 20)
          (insert (format "#+BEGIN: vulpea :tags (t%02d)\n#+END:\n\n" tag))))
      (vulpea-dblock-mode 1)
      (let ((buf (find-file-noselect index))
            (orig-process (symbol-function 'vulpea-dblock--process-sub))
            (processed 0)
            (edits 0))
        (unwind-protect
            (progn
              (should (= (length (buffer-local-value
                                  'vulpea-dblock--buffer-subs buf))
                         20))
              (vulpea-dblock--drain)
              (with-current-buffer buf (basic-save-buffer))
              (vulpea-dblock--drain)
              ;; Retitle one note; count verifications and buffer edits.
              (cl-letf (((symbol-function 'vulpea-dblock--process-sub)
                         (lambda (sub &optional force)
                           (cl-incf processed)
                           (let ((outcome (funcall orig-process sub force)))
                             (when (eq outcome 'updated) (cl-incf edits))
                             outcome))))
                (vulpea-dblock-test--write-note
                 dir "id-007" "Note 007 renamed"
                 :tags (list (format "t%02d" (mod 7 20))))
                (vulpea-dblock--drain))
              ;; Only the single block depending on t07 may be touched
              ;; (dep index + path index point at the same sub).
              (should (<= processed 2))
              (should (<= edits 1))
              (should (string-match-p
                       (regexp-quote "Note 007 renamed")
                       (vulpea-dblock-test--block-body buf ":tags (t07)"))))
          (kill-buffer buf))))))

(provide 'test-integration)
;;; test-integration.el ends here
