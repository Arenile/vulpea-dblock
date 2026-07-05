;;; test-render.el --- Tests for vulpea-dblock-render -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:

;; Unit tests for query execution, formatting, result signatures, and
;; the diff-write.  Database queries are stubbed with `cl-letf'.

;;; Code:

(require 'test-helper)

(defun vulpea-dblock-test--notes ()
  "Three fixture notes: two tagged paper (one DONE), one project TODO."
  (list
   (vulpea-dblock-test-note
    :id "id-a" :title "Alpha" :tags '("paper") :todo "TODO"
    :priority ?A :modified-at 100 :path "/notes/a.org"
    :links '((:type "id" :dest "id-c")))
   (vulpea-dblock-test-note
    :id "id-b" :title "Beta" :tags '("paper" "book") :todo "DONE"
    :modified-at 200 :path "/notes/b.org")
   (vulpea-dblock-test-note
    :id "id-c" :title "Gamma" :tags '("project") :todo "TODO"
    :modified-at 300 :path "/notes/c.org")))

(defmacro vulpea-dblock-test-with-db (&rest body)
  "Run BODY with all vulpea db queries answered from the fixture notes."
  (declare (indent 0))
  `(let ((notes (vulpea-dblock-test--notes)))
     (cl-letf (((symbol-function 'vulpea-db-query)
                (lambda (&optional pred)
                  (if pred (seq-filter pred notes) notes)))
               ((symbol-function 'vulpea-db-query-by-tags-every)
                (lambda (tags)
                  (seq-filter
                   (lambda (n) (cl-every (lambda (tag) (member tag (vulpea-note-tags n)))
                                         tags))
                   notes)))
               ((symbol-function 'vulpea-db-query-by-tags-some)
                (lambda (tags)
                  (seq-filter
                   (lambda (n) (cl-some (lambda (tag) (member tag (vulpea-note-tags n)))
                                        tags))
                   notes)))
               ((symbol-function 'vulpea-db-query-by-links-some)
                (lambda (ids _type)
                  (seq-filter
                   (lambda (n) (seq-intersection
                                ids (vulpea-dblock--note-link-dests n)))
                   notes)))
               ((symbol-function 'vulpea-db-query-by-ids)
                (lambda (ids)
                  (seq-filter (lambda (n) (member (vulpea-note-id n) ids))
                              notes)))
               ((symbol-function 'vulpea-db-get-by-id)
                (lambda (id)
                  (seq-find (lambda (n) (equal (vulpea-note-id n) id))
                            notes))))
       ,@body)))

;;; Query

(ert-deftest vulpea-dblock-test-query-tags-every ()
  (vulpea-dblock-test-with-db
    (let ((result (vulpea-dblock--run-query
                   (vulpea-dblock--normalize-params '(:tags (paper))))))
      (should (equal (mapcar #'vulpea-note-id result) '("id-a" "id-b"))))))

(ert-deftest vulpea-dblock-test-query-exclude-done-and-todo ()
  (vulpea-dblock-test-with-db
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             '(:tags (paper) :exclude-done t))))
                   '("id-a")))
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params '(:todo "DONE"))))
                   '("id-b")))
    ;; :todo t = any todo state; all fixtures have one.
    (should (= (length (vulpea-dblock--run-query
                        (vulpea-dblock--normalize-params '(:todo t))))
               3))))

(ert-deftest vulpea-dblock-test-query-sort-mtime-reverse-limit ()
  (vulpea-dblock-test-with-db
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             '(:sort mtime :reverse t :limit 2))))
                   '("id-c" "id-b")))))

(ert-deftest vulpea-dblock-test-query-backlinks-to ()
  (vulpea-dblock-test-with-db
    ;; id-a links to id-c, so backlinks-to id-c yields id-a.
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             '(:backlinks-to "id-c"))))
                   '("id-a")))))

(ert-deftest vulpea-dblock-test-query-links-from ()
  (vulpea-dblock-test-with-db
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             '(:links-from "id-a"))))
                   '("id-c")))))

(ert-deftest vulpea-dblock-test-query-self-resolution ()
  (vulpea-dblock-test-with-db
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             '(:backlinks-to self))
                            "id-c"))
                   '("id-a")))
    ;; Unresolvable self -> empty, not an error.
    (should-not (vulpea-dblock--run-query
                 (vulpea-dblock--normalize-params '(:backlinks-to self))
                 nil))))

(ert-deftest vulpea-dblock-test-query-filter-fn ()
  (vulpea-dblock-test-with-db
    (should (equal (mapcar #'vulpea-note-id
                           (vulpea-dblock--run-query
                            (vulpea-dblock--normalize-params
                             `(:filter ,(lambda (n)
                                          (equal (vulpea-note-title n) "Beta"))))))
                   '("id-b")))))

;;; Result signature

(ert-deftest vulpea-dblock-test-result-sig ()
  (let* ((notes (vulpea-dblock-test--notes))
         (sig (vulpea-dblock--result-sig notes)))
    (should (equal sig
                   '(("id-a" "Alpha" "TODO" ?A 100)
                     ("id-b" "Beta" "DONE" nil 200)
                     ("id-c" "Gamma" "TODO" nil 300))))
    ;; An mtime bump alone changes the signature...
    (setf (vulpea-note-modified-at (car notes)) 101)
    (should-not (equal (vulpea-dblock--result-sig notes) sig))
    ;; ...and so does a retitle even at identical mtime (vulpea's
    ;; mtime has one-second granularity, so mtime alone is not enough).
    (setf (vulpea-note-modified-at (car notes)) 100)
    (setf (vulpea-note-title (car notes)) "Alpha Prime")
    (should-not (equal (vulpea-dblock--result-sig notes) sig))))

;;; Rendering

(ert-deftest vulpea-dblock-test-render-default-format ()
  (let ((notes (list (car (vulpea-dblock-test--notes))))
        (params (vulpea-dblock--normalize-params nil)))
    (should (equal (vulpea-dblock--render-string notes params)
                   "- [[id:id-a][Alpha]]"))
    (should (equal (vulpea-dblock--body-string notes params)
                   "- [[id:id-a][Alpha]]\n"))))

(ert-deftest vulpea-dblock-test-render-format-spec ()
  (let ((notes (list (car (vulpea-dblock-test--notes)))))
    (should (equal (vulpea-dblock--render-string
                    notes (vulpea-dblock--normalize-params
                           '(:format "%o [#%p] %t (%i)")))
                   "TODO [#A] Alpha (id-a)"))))

(ert-deftest vulpea-dblock-test-render-format-fn ()
  (let ((notes (vulpea-dblock-test--notes)))
    (should (equal (vulpea-dblock--render-string
                    notes (vulpea-dblock--normalize-params
                           `(:format ,(lambda (n) (vulpea-note-title n)))))
                   "Alpha\nBeta\nGamma"))))

(ert-deftest vulpea-dblock-test-render-empty ()
  (should (equal (vulpea-dblock--body-string
                  nil (vulpea-dblock--normalize-params nil))
                 "/none/\n"))
  (should (equal (vulpea-dblock--body-string
                  nil (vulpea-dblock--normalize-params '(:empty "-")))
                 "-\n")))

(ert-deftest vulpea-dblock-test-render-legacy-byte-identical ()
  "Legacy rendering must match the old init.el writer byte for byte."
  (let ((notes (vulpea-dblock-test--notes))
        (params (vulpea-dblock--normalize-params nil 'legacy)))
    (should (equal (vulpea-dblock--render-string notes params)
                   (concat "- [#A] TODO [[id:id-a][Alpha]]\n"
                           "- DONE [[id:id-b][Beta]]\n"
                           "- TODO [[id:id-c][Gamma]]\n")))
    (should (equal (vulpea-dblock--render-string
                    nil (vulpea-dblock--normalize-params nil 'legacy))
                   "No matching nodes found.\n"))))

(ert-deftest vulpea-dblock-test-render-legacy-custom-format ()
  (let ((params (vulpea-dblock--normalize-params
                 `(:format ,(lambda (title id _todo _prio)
                              (format "* %s <%s>\n" title id)))
                 'legacy)))
    (should (equal (vulpea-dblock--render-string
                    (list (car (vulpea-dblock-test--notes))) params)
                   "* Alpha <id-a>\n"))))

;;; Process (verify / diff-write)

(defmacro vulpea-dblock-test--with-block-sub (content &rest body)
  "Set up an org buffer with CONTENT, scan it, bind `sub', run BODY."
  (declare (indent 1))
  `(vulpea-dblock-test-with-clean-registry
     (vulpea-dblock-test-with-org-buffer ,content
       (vulpea-dblock-test-with-db
         (let ((sub (car (vulpea-dblock--scan-buffer))))
           ,@body)))))

(ert-deftest vulpea-dblock-test-process-updates-stale-block ()
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\n"
    (should (eq (vulpea-dblock--process-sub sub) 'updated))
    (should (equal (buffer-string)
                   "#+BEGIN: vulpea :tags (paper) :exclude-done t\n- [[id:id-a][Alpha]]\n#+END:\n"))
    (should-not (vulpea-dblock--sub-dirty sub))
    (should (equal (vulpea-dblock--sub-result-sig sub)
                   '(("id-a" "Alpha" "TODO" ?A 100))))
    (should (equal (vulpea-dblock--sub-last-paths sub) '("/notes/a.org")))
    (should (= (length (gethash "/notes/a.org" vulpea-dblock--index-paths)) 1))))

(ert-deftest vulpea-dblock-test-process-verified-skips-render ()
  "Unchanged result signature: no render, no buffer touch, even if stale."
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\n"
    (setf (vulpea-dblock--sub-result-sig sub)
          '(("id-a" "Alpha" "TODO" ?A 100)))
    (should (eq (vulpea-dblock--process-sub sub) 'verified))
    ;; Body untouched: signature matching short-circuits before render.
    (should (string-match-p "stale" (buffer-string)))
    (should-not (buffer-modified-p))))

(ert-deftest vulpea-dblock-test-process-unchanged-never-dirties ()
  "Byte-identical output must not modify the buffer (refresh-on-open)."
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper) :exclude-done t\n- [[id:id-a][Alpha]]\n#+END:\n"
    ;; Fresh sub: sig is nil, so it renders, but bytes match.
    (should (eq (vulpea-dblock--process-sub sub) 'unchanged))
    (should-not (buffer-modified-p))
    (should (equal (vulpea-dblock--sub-result-sig sub)
                   '(("id-a" "Alpha" "TODO" ?A 100))))
    ;; Second pass is a pure verification.
    (setf (vulpea-dblock--sub-dirty sub) t)
    (should (eq (vulpea-dblock--process-sub sub) 'verified))))

(ert-deftest vulpea-dblock-test-process-preserves-user-modified-flag ()
  "A buffer with unsaved user edits stays modified after a render."
  (vulpea-dblock-test--with-block-sub
      "user edit\n#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\n"
    (set-buffer-modified-p t)
    (should (eq (vulpea-dblock--process-sub sub) 'updated))
    (should (buffer-modified-p))))

(ert-deftest vulpea-dblock-test-process-widens-narrowed-buffer ()
  (vulpea-dblock-test--with-block-sub
      "before\n\n#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\nafter\n"
    ;; Narrow to a region excluding the block entirely.
    (narrow-to-region (point-min) (1+ (length "before")))
    (should (eq (vulpea-dblock--process-sub sub) 'updated))
    ;; Narrowing restored.
    (should (= (point-max) (1+ (length "before"))))
    (widen)
    (should (string-match-p (regexp-quote "- [[id:id-a][Alpha]]")
                            (buffer-string)))))

(ert-deftest vulpea-dblock-test-process-preserves-point-inside-block ()
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\ntail\n"
    (search-backward "tail")
    (let ((pos (point)))
      (should (eq (vulpea-dblock--process-sub sub) 'updated))
      (should (looking-at "tail"))
      ;; Body grew, so point moved with the text after the block.
      (should (>= (point) pos)))))

(ert-deftest vulpea-dblock-test-process-broken-marker ()
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
    (erase-buffer)
    (insert "the block is gone\n")
    (should (eq (vulpea-dblock--process-sub sub) 'broken))
    (should (vulpea-dblock--sub-broken sub))))

(ert-deftest vulpea-dblock-test-process-dead-buffer ()
  (vulpea-dblock-test-with-clean-registry
    (let (sub)
      (vulpea-dblock-test-with-org-buffer
          "#+BEGIN: vulpea :tags (paper)\nx\n#+END:\n"
        (setq sub (car (vulpea-dblock--scan-buffer))))
      ;; Temp buffer is dead now.
      (should (eq (vulpea-dblock--process-sub sub) 'dead))
      (should-not (vulpea-dblock--registered-p sub)))))

(ert-deftest vulpea-dblock-test-process-empty-body-block ()
  "A block with no body lines at all gets its content inserted."
  (vulpea-dblock-test--with-block-sub
      "#+BEGIN: vulpea :tags (paper) :exclude-done t\n#+END:\n"
    (should (eq (vulpea-dblock--process-sub sub) 'updated))
    (should (equal (buffer-string)
                   "#+BEGIN: vulpea :tags (paper) :exclude-done t\n- [[id:id-a][Alpha]]\n#+END:\n"))))

;;; Org writer path consistency

(ert-deftest vulpea-dblock-test-org-writer-matches-diff-model ()
  "org-update-dblock output must equal our body model (S + newline)."
  (vulpea-dblock-test-with-db
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (org-mode))
      (insert "#+BEGIN: vulpea :tags (paper) :exclude-done t\nstale\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (should (equal (buffer-string)
                     "#+BEGIN: vulpea :tags (paper) :exclude-done t\n- [[id:id-a][Alpha]]\n#+END:\n")))))

(ert-deftest vulpea-dblock-test-org-writer-node-list-legacy ()
  (vulpea-dblock-test-with-db
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (org-mode))
      (insert "#+BEGIN: node-list :tag \"paper\" :exclude-done t\nstale\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (should (equal (buffer-string)
                     (concat "#+BEGIN: node-list :tag \"paper\" :exclude-done t\n"
                             "- [#A] TODO [[id:id-a][Alpha]]\n"
                             "\n#+END:\n"))))))

(provide 'test-render)
;;; test-render.el ends here
