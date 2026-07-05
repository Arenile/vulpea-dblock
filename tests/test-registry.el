;;; test-registry.el --- Tests for vulpea-dblock-registry -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for params normalization, dependency keys, event
;; matching, and buffer scanning.  No database required: db lookups
;; are stubbed with `cl-letf'.

;;; Code:

(require 'test-helper)

;;; Params normalization

(ert-deftest vulpea-dblock-test-normalize-new-style ()
  (let ((p (vulpea-dblock--normalize-params
            '(:tags (paper toread) :todo t :sort mtime :reverse t :limit 20))))
    (should (equal (plist-get p :tags) '("paper" "toread")))
    (should-not (plist-get p :tags-any))
    (should-not (plist-get p :todo))          ; :todo t means todo-only
    (should (plist-get p :todo-only))
    (should (eq (plist-get p :sort) 'mtime))
    (should (plist-get p :reverse))
    (should (= (plist-get p :limit) 20))
    (should (equal (plist-get p :empty) "/none/"))
    (should-not (plist-get p :legacy))))

(ert-deftest vulpea-dblock-test-normalize-defaults ()
  (let ((p (vulpea-dblock--normalize-params nil)))
    (should (eq (plist-get p :sort) 'title))
    (should (equal (plist-get p :empty) "/none/"))
    (should-not (plist-get p :reverse))))

(ert-deftest vulpea-dblock-test-normalize-tags-any-and-atom ()
  (let ((p (vulpea-dblock--normalize-params '(:tags-any (a b) :tags c))))
    (should (equal (plist-get p :tags) '("c")))
    (should (equal (plist-get p :tags-any) '("a" "b")))))

(ert-deftest vulpea-dblock-test-normalize-legacy ()
  (let ((p (vulpea-dblock--normalize-params
            '(:tag "paper" :tags-match or :tags ("book" "article")
              :order-by priority :empty-message "nothing" :todo "TODO")
            'legacy)))
    (should (plist-get p :legacy))
    ;; :tags-match or routes :tags into :tags-any; :tag stays an ALL tag.
    (should (equal (plist-get p :tags) '("paper")))
    (should (equal (plist-get p :tags-any) '("book" "article")))
    (should (eq (plist-get p :sort) 'priority))
    (should (equal (plist-get p :empty) "nothing"))
    (should (equal (plist-get p :todo) '("TODO")))))

(ert-deftest vulpea-dblock-test-normalize-legacy-defaults ()
  (let ((p (vulpea-dblock--normalize-params nil 'legacy)))
    (should (equal (plist-get p :empty) "No matching nodes found.\n"))))

(ert-deftest vulpea-dblock-test-normalize-unquote ()
  (let ((p (vulpea-dblock--normalize-params
            '(:filter 'my-filter :sort 'mtime :backlinks-to 'self))))
    (should (eq (plist-get p :filter) 'my-filter))
    (should (eq (plist-get p :sort) 'mtime))
    (should (eq (plist-get p :backlinks-to) 'self))))

(ert-deftest vulpea-dblock-test-normalize-todo-list ()
  (let ((p (vulpea-dblock--normalize-params '(:todo ("TODO" "NEXT")))))
    (should (equal (plist-get p :todo) '("TODO" "NEXT")))))

;;; Dependency keys

(ert-deftest vulpea-dblock-test-dep-keys-tags ()
  (let* ((p (vulpea-dblock--normalize-params '(:tags (a) :tags-any (b))))
         (deps (vulpea-dblock--dep-keys-for p nil)))
    (should (equal (sort (copy-sequence (plist-get deps :tags)) #'string<)
                   '("a" "b")))
    (should-not (plist-get deps :targets))
    (should-not (plist-get deps :global))))

(ert-deftest vulpea-dblock-test-dep-keys-target-resolved ()
  (cl-letf (((symbol-function 'vulpea-dblock--resolve-id)
             (lambda (target) (when (equal target "id-1") "id-1"))))
    (let* ((p (vulpea-dblock--normalize-params '(:backlinks-to "id-1")))
           (deps (vulpea-dblock--dep-keys-for p nil)))
      (should (equal (plist-get deps :targets) '("id-1")))
      (should-not (plist-get deps :global)))))

(ert-deftest vulpea-dblock-test-dep-keys-unresolved-target-is-global ()
  (cl-letf (((symbol-function 'vulpea-dblock--resolve-id)
             (lambda (_) nil)))
    (let* ((p (vulpea-dblock--normalize-params '(:backlinks-to "missing")))
           (deps (vulpea-dblock--dep-keys-for p nil)))
      (should (plist-get deps :global)))))

(ert-deftest vulpea-dblock-test-dep-keys-global-when-unindexable ()
  (let* ((p (vulpea-dblock--normalize-params '(:todo t)))
         (deps (vulpea-dblock--dep-keys-for p nil)))
    (should (plist-get deps :global))))

;;; Registration, matching, scanning

(defconst vulpea-dblock-test--two-blocks
  "* Heading
#+BEGIN: vulpea :tags (paper)
old
#+END:

#+BEGIN: vulpea :tags (paper)
old
#+END:

#+BEGIN: vulpea :todo t
old
#+END:
")

(ert-deftest vulpea-dblock-test-scan-registers-blocks ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer vulpea-dblock-test--two-blocks
      (let ((changed (vulpea-dblock--scan-buffer)))
        ;; Two identical blocks -> two distinct subs, plus the global one.
        (should (= (length changed) 3))
        (should (= (length vulpea-dblock--buffer-subs) 3))
        (should (cl-every #'vulpea-dblock--sub-dirty changed))
        (should (= (length vulpea-dblock--global-subs) 1))
        (should (= (length (gethash "paper" vulpea-dblock--index-tags)) 2))
        ;; Re-scan without edits: nothing new, nothing lost.
        (should-not (vulpea-dblock--scan-buffer))
        (should (= (length vulpea-dblock--buffer-subs) 3))))))

(ert-deftest vulpea-dblock-test-scan-param-change-marks-dirty ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer
        "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
      (let ((sub (car (vulpea-dblock--scan-buffer))))
        (setf (vulpea-dblock--sub-dirty sub) nil
              (vulpea-dblock--sub-result-sig sub) '(("id" . 1)))
        ;; Edit the params in place.
        (goto-char (point-min))
        (search-forward "(paper)")
        (replace-match "(book)")
        (let ((changed (vulpea-dblock--scan-buffer)))
          (should (equal changed (list sub)))
          (should (vulpea-dblock--sub-dirty sub))
          (should-not (vulpea-dblock--sub-result-sig sub))
          (should (equal (plist-get (vulpea-dblock--sub-params sub) :tags)
                         '("book")))
          (should-not (gethash "paper" vulpea-dblock--index-tags))
          (should (= (length (gethash "book" vulpea-dblock--index-tags)) 1)))))))

(ert-deftest vulpea-dblock-test-scan-removed-block-unregisters ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer
        "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
      (let ((sub (car (vulpea-dblock--scan-buffer))))
        (erase-buffer)
        (insert "no blocks here\n")
        (vulpea-dblock--scan-buffer)
        (should-not (vulpea-dblock--registered-p sub))
        (should-not vulpea-dblock--buffer-subs)
        (should (hash-table-empty-p vulpea-dblock--index-tags))))))

(ert-deftest vulpea-dblock-test-non-file-buffer-never-registered ()
  (vulpea-dblock-test-with-clean-registry
    (with-temp-buffer
      (insert "#+BEGIN: vulpea :tags (paper)\n#+END:\n")
      (let ((org-inhibit-startup t))
        (org-mode))
      ;; No buffer-file-name, e.g. a capture buffer.
      (should-not (vulpea-dblock--scan-buffer))
      (should (hash-table-empty-p vulpea-dblock--subs)))))

(ert-deftest vulpea-dblock-test-match-event ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer vulpea-dblock-test--two-blocks
      (cl-letf (((symbol-function 'vulpea-dblock--resolve-id)
                 (lambda (target) target)))
        (vulpea-dblock--scan-buffer))
      (let ((global (car vulpea-dblock--global-subs))
            (tagged (gethash "paper" vulpea-dblock--index-tags)))
        ;; Tag event: both paper subs plus the global one.
        (let ((hit (vulpea-dblock--match-event
                    '(:path "/x.org" :tags ("paper") :ids ("i") :dests nil))))
          (should (= (length hit) 3))
          (should (memq global hit))
          (dolist (s tagged) (should (memq s hit))))
        ;; Unrelated event: only the global sub.
        (should (equal (vulpea-dblock--match-event
                        '(:path "/x.org" :tags ("other") :ids nil :dests nil))
                       (list global)))
        ;; Path index: sub whose last result included the changed file.
        (vulpea-dblock--set-sub-paths (car tagged) '("/notes/a.org"))
        (let ((hit (vulpea-dblock--match-event
                    '(:path "/notes/a.org" :tags nil :ids nil :dests nil))))
          (should (memq (car tagged) hit)))))))

(ert-deftest vulpea-dblock-test-match-event-target-index ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer
        "#+BEGIN: vulpea :backlinks-to \"target-1\"\nx\n#+END:\n"
      (cl-letf (((symbol-function 'vulpea-dblock--resolve-id)
                 (lambda (target) target)))
        (vulpea-dblock--scan-buffer))
      (let ((sub (car vulpea-dblock--buffer-subs)))
        ;; A note that links to target-1 changed -> dests carry target-1.
        (should (memq sub (vulpea-dblock--match-event
                           '(:path "/y.org" :tags nil :ids ("other")
                             :dests ("target-1")))))
        ;; The target note itself changed.
        (should (memq sub (vulpea-dblock--match-event
                           '(:path "/t.org" :tags nil :ids ("target-1")
                             :dests nil))))
        (should-not (memq sub (vulpea-dblock--match-event
                               '(:path "/z.org" :tags nil :ids ("other")
                                 :dests nil))))))))

(ert-deftest vulpea-dblock-test-forget-buffer ()
  (vulpea-dblock-test-with-clean-registry
    (vulpea-dblock-test-with-org-buffer
        "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
      (vulpea-dblock--scan-buffer)
      (should (= (hash-table-count vulpea-dblock--subs) 1))
      (vulpea-dblock--forget-buffer)
      (should (hash-table-empty-p vulpea-dblock--subs))
      (should-not vulpea-dblock--buffer-subs))))

(ert-deftest vulpea-dblock-test-scan-fixture-file ()
  (vulpea-dblock-test-with-clean-registry
    (let ((vulpea-db-sync-directories (list vulpea-dblock-test-fixtures-dir))
          (buf (find-file-noselect
                (expand-file-name "sample.org" vulpea-dblock-test-fixtures-dir))))
      (unwind-protect
          (with-current-buffer buf
            (let ((changed (vulpea-dblock--scan-buffer)))
              (should (= (length changed) 2))
              (should (member "node-list"
                              (mapcar #'vulpea-dblock--sub-name changed)))))
        (kill-buffer buf)))))

(provide 'test-registry)
;;; test-registry.el ends here
