;;; test-helper.el --- Shared setup for vulpea-dblock tests -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:

;; Loaded before every test file.  Locates vulpea (and its
;; dependencies) through package.el from the user's package dir, then
;; loads vulpea-dblock from the repository root.
;;
;; Run the suite with `make test' from the repository root.

;;; Code:

(require 'package)
(package-initialize)

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'vulpea)

(add-to-list 'load-path
             (expand-file-name
              ".." (file-name-directory (or load-file-name
                                            buffer-file-name))))
(require 'vulpea-dblock)

(defconst vulpea-dblock-test-fixtures-dir
  (expand-file-name
   "fixtures" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding static org fixtures.")

(defun vulpea-dblock-test-note (&rest args)
  "Build a `vulpea-note' fixture; ARGS as for `make-vulpea-note'.
Defaults: level 0, a path derived from the id, mtime 1000."
  (let ((note (apply #'make-vulpea-note args)))
    (unless (vulpea-note-path note)
      (setf (vulpea-note-path note)
            (format "/notes/%s.org" (vulpea-note-id note))))
    (unless (vulpea-note-level note)
      (setf (vulpea-note-level note) 0))
    (unless (vulpea-note-modified-at note)
      (setf (vulpea-note-modified-at note) 1000))
    note))

(defmacro vulpea-dblock-test-with-clean-registry (&rest body)
  "Run BODY with an empty registry/scheduler, restoring state afterwards."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (vulpea-dblock--shutdown)
         (vulpea-dblock--registry-clear)
         ,@body)
     (vulpea-dblock--shutdown)
     (vulpea-dblock--registry-clear)))

(defmacro vulpea-dblock-test-with-org-buffer (content &rest body)
  "Run BODY in a temp org-mode buffer containing CONTENT.
The buffer pretends to visit a file so it is registry-eligible;
`vulpea-db-sync-directories' is bound to nil to disable the
directory restriction."
  (declare (indent 1))
  `(let ((vulpea-db-sync-directories nil))
     (with-temp-buffer
       (insert ,content)
       (let ((org-inhibit-startup t))
         (org-mode))
       (setq buffer-file-name "/tmp/vulpea-dblock-test.org")
       (set-buffer-modified-p nil)
       (unwind-protect
           (progn ,@body)
         (setq buffer-file-name nil)))))

(provide 'test-helper)
;;; test-helper.el ends here
