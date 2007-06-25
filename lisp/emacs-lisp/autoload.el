;; autoload.el --- maintain autoloads in loaddefs.el

;; Copyright (C) 1991, 1992, 1993, 1994, 1995, 1996, 1997, 2001, 2002, 2003,
;;   2004, 2005, 2006, 2007 Free Software Foundation, Inc.

;; Author: Roland McGrath <roland@gnu.org>
;; Keywords: maint

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This code helps GNU Emacs maintainers keep the loaddefs.el file up to
;; date.  It interprets magic cookies of the form ";;;###autoload" in
;; lisp source files in various useful ways.  To learn more, read the
;; source; if you're going to use this, you'd better be able to.

;;; Code:

(require 'lisp-mode)			;for `doc-string-elt' properties.
(require 'help-fns)			;for help-add-fundoc-usage.
(eval-when-compile (require 'cl))

(defvar generated-autoload-file "loaddefs.el"
   "*File \\[update-file-autoloads] puts autoloads into.
A `.el' file can set this in its local variables section to make its
autoloads go somewhere else.  The autoload file is assumed to contain a
trailer starting with a FormFeed character.")
(put 'generated-autoload-file 'safe-local-variable 'stringp)

;; This feels like it should be a defconst, but MH-E sets it to
;; ";;;###mh-autoload" for the autoloads that are to go into mh-loaddefs.el.
(defvar generate-autoload-cookie ";;;###autoload"
  "Magic comment indicating the following form should be autoloaded.
Used by \\[update-file-autoloads].  This string should be
meaningless to Lisp (e.g., a comment).

This string is used:

\;;;###autoload
\(defun function-to-be-autoloaded () ...)

If this string appears alone on a line, the following form will be
read and an autoload made for it.  If there is further text on the line,
that text will be copied verbatim to `generated-autoload-file'.")

(defconst generate-autoload-section-header "\f\n;;;### "
  "String that marks the form at the start of a new file's autoload section.")

(defconst generate-autoload-section-trailer "\n;;;***\n"
  "String which indicates the end of the section of autoloads for a file.")

(defconst generate-autoload-section-continuation ";;;;;; "
  "String to add on each continuation of the section header form.")

(defun make-autoload (form file)
  "Turn FORM into an autoload or defvar for source file FILE.
Returns nil if FORM is not a special autoload form (i.e. a function definition
or macro definition or a defcustom)."
  (let ((car (car-safe form)) expand)
    (cond
     ;; For complex cases, try again on the macro-expansion.
     ((and (memq car '(easy-mmode-define-global-mode define-global-minor-mode
		       define-globalized-minor-mode
		       easy-mmode-define-minor-mode define-minor-mode))
	   (setq expand (let ((load-file-name file)) (macroexpand form)))
	   (eq (car expand) 'progn)
	   (memq :autoload-end expand))
      (let ((end (memq :autoload-end expand)))
	;; Cut-off anything after the :autoload-end marker.
	(setcdr end nil)
	(cons 'progn
	      (mapcar (lambda (form) (make-autoload form file))
		      (cdr expand)))))

     ;; For special function-like operators, use the `autoload' function.
     ((memq car '(defun define-skeleton defmacro define-derived-mode
                   define-compilation-mode define-generic-mode
		   easy-mmode-define-global-mode define-global-minor-mode
		   define-globalized-minor-mode
		   easy-mmode-define-minor-mode define-minor-mode
		   defun* defmacro*))
      (let* ((macrop (memq car '(defmacro defmacro*)))
	     (name (nth 1 form))
	     (args (case car
		    ((defun defmacro defun* defmacro*) (nth 2 form))
		    ((define-skeleton) '(&optional str arg))
		    ((define-generic-mode define-derived-mode
                       define-compilation-mode) nil)
		    (t)))
	     (body (nthcdr (get car 'doc-string-elt) form))
	     (doc (if (stringp (car body)) (pop body))))
	(when (listp args)
	  ;; Add the usage form at the end where describe-function-1
	  ;; can recover it.
	  (setq doc (help-add-fundoc-usage doc args)))
	;; `define-generic-mode' quotes the name, so take care of that
	(list 'autoload (if (listp name) name (list 'quote name)) file doc
	      (or (and (memq car '(define-skeleton define-derived-mode
				    define-generic-mode
				    easy-mmode-define-global-mode
				    define-global-minor-mode
				    define-globalized-minor-mode
				    easy-mmode-define-minor-mode
				    define-minor-mode)) t)
		  (eq (car-safe (car body)) 'interactive))
	      (if macrop (list 'quote 'macro) nil))))

     ;; Convert defcustom to less space-consuming data.
     ((eq car 'defcustom)
      (let ((varname (car-safe (cdr-safe form)))
	    (init (car-safe (cdr-safe (cdr-safe form))))
	    (doc (car-safe (cdr-safe (cdr-safe (cdr-safe form)))))
	    ;; (rest (cdr-safe (cdr-safe (cdr-safe (cdr-safe form)))))
	    )
	`(progn
	   (defvar ,varname ,init ,doc)
	   (custom-autoload ',varname ,file
                            ,(condition-case nil
                                 (null (cadr (memq :set form)))
                               (error nil))))))

     ((eq car 'defgroup)
      ;; In Emacs this is normally handled separately by cus-dep.el, but for
      ;; third party packages, it can be convenient to explicitly autoload
      ;; a group.
      (let ((groupname (nth 1 form)))
        `(let ((loads (get ',groupname 'custom-loads)))
           (if (member ',file loads) nil
             (put ',groupname 'custom-loads (cons ',file loads))))))

     ;; nil here indicates that this is not a special autoload form.
     (t nil))))

;; Forms which have doc-strings which should be printed specially.
;; A doc-string-elt property of ELT says that (nth ELT FORM) is
;; the doc-string in FORM.
;; Those properties are now set in lisp-mode.el.

(defun autoload-generated-file ()
  (expand-file-name generated-autoload-file
                    (expand-file-name "lisp"
                                      source-directory)))

(defun autoload-trim-file-name (file)
  ;; Returns a relative file path for FILE
  ;; starting from the directory that loaddefs.el is in.
  ;; That is normally a directory in load-path,
  ;; which means Emacs will be able to find FILE when it looks.
  ;; Any extra directory names here would prevent finding the file.
  (setq file (expand-file-name file))
  (file-relative-name file
		      (file-name-directory generated-autoload-file)))

(defun autoload-read-section-header ()
  "Read a section header form.
Since continuation lines have been marked as comments,
we must copy the text of the form and remove those comment
markers before we call `read'."
  (save-match-data
    (let ((beginning (point))
	  string)
      (forward-line 1)
      (while (looking-at generate-autoload-section-continuation)
	(forward-line 1))
      (setq string (buffer-substring beginning (point)))
      (with-current-buffer (get-buffer-create " *autoload*")
	(erase-buffer)
	(insert string)
	(goto-char (point-min))
	(while (search-forward generate-autoload-section-continuation nil t)
	  (replace-match " "))
	(goto-char (point-min))
	(read (current-buffer))))))

(defvar autoload-print-form-outbuf nil
  "Buffer which gets the output of `autoload-print-form'.")

(defun autoload-print-form (form)
  "Print FORM such that `make-docfile' will find the docstrings.
The variable `autoload-print-form-outbuf' specifies the buffer to
put the output in."
  (cond
   ;; If the form is a sequence, recurse.
   ((eq (car form) 'progn) (mapcar 'autoload-print-form (cdr form)))
   ;; Symbols at the toplevel are meaningless.
   ((symbolp form) nil)
   (t
    (let ((doc-string-elt (get (car-safe form) 'doc-string-elt))
	  (outbuf autoload-print-form-outbuf))
      (if (and doc-string-elt (stringp (nth doc-string-elt form)))
	  ;; We need to hack the printing because the
	  ;; doc-string must be printed specially for
	  ;; make-docfile (sigh).
	  (let* ((p (nthcdr (1- doc-string-elt) form))
		 (elt (cdr p)))
	    (setcdr p nil)
	    (princ "\n(" outbuf)
	    (let ((print-escape-newlines t)
		  (print-escape-nonascii t))
	      (dolist (elt form)
		(prin1 elt outbuf)
		(princ " " outbuf)))
	    (princ "\"\\\n" outbuf)
	    (let ((begin (with-current-buffer outbuf (point))))
	      (princ (substring (prin1-to-string (car elt)) 1)
		     outbuf)
	      ;; Insert a backslash before each ( that
	      ;; appears at the beginning of a line in
	      ;; the doc string.
	      (with-current-buffer outbuf
		(save-excursion
		  (while (re-search-backward "\n[[(]" begin t)
		    (forward-char 1)
		    (insert "\\"))))
	      (if (null (cdr elt))
		  (princ ")" outbuf)
		(princ " " outbuf)
		(princ (substring (prin1-to-string (cdr elt)) 1)
		       outbuf))
	      (terpri outbuf)))
	(let ((print-escape-newlines t)
	      (print-escape-nonascii t))
	  (print form outbuf)))))))

(defun autoload-ensure-default-file (file)
  "Make sure that the autoload file FILE exists and if not create it."
  (unless (file-exists-p file)
    (write-region
     (concat ";;; " (file-name-nondirectory file)
	     " --- automatically extracted autoloads\n"
	     ";;\n"
	     ";;; Code:\n\n"
	     "\n;; Local Variables:\n"
	     ";; version-control: never\n"
	     ";; no-byte-compile: t\n"
	     ";; no-update-autoloads: t\n"
	     ";; End:\n"
	     ";;; " (file-name-nondirectory file)
	     " ends here\n")
     nil file))
  file)

(defun autoload-insert-section-header (outbuf autoloads load-name file time)
  "Insert the section-header line,
which lists the file name and which functions are in it, etc."
  (insert generate-autoload-section-header)
  (prin1 (list 'autoloads autoloads load-name
	       (if (stringp file) (autoload-trim-file-name file) file)
	       time)
	 outbuf)
  (terpri outbuf)
  ;; Break that line at spaces, to avoid very long lines.
  ;; Make each sub-line into a comment.
  (with-current-buffer outbuf
    (save-excursion
      (forward-line -1)
      (while (not (eolp))
	(move-to-column 64)
	(skip-chars-forward "^ \n")
	(or (eolp)
	    (insert "\n" generate-autoload-section-continuation))))))

(defun autoload-find-file (file)
  "Fetch file and put it in a temp buffer.  Return the buffer."
  ;; It is faster to avoid visiting the file.
  (setq file (expand-file-name file))
  (with-current-buffer (get-buffer-create " *autoload-file*")
    (kill-all-local-variables)
    (erase-buffer)
    (setq buffer-undo-list t
          buffer-read-only nil)
    (emacs-lisp-mode)
    (setq default-directory (file-name-directory file))
    (insert-file-contents file nil)
    (let ((enable-local-variables :safe))
      (hack-local-variables))
    (current-buffer)))

(defvar no-update-autoloads nil
  "File local variable to prevent scanning this file for autoload cookies.")

(defun autoload-file-load-name (file)
  (let ((name (file-name-nondirectory file)))
    (if (string-match "\\.elc?\\(\\.\\|\\'\\)" name)
        (substring name 0 (match-beginning 0))
      name)))

(defun generate-file-autoloads (file)
  "Insert at point a loaddefs autoload section for FILE.
Autoloads are generated for defuns and defmacros in FILE
marked by `generate-autoload-cookie' (which see).
If FILE is being visited in a buffer, the contents of the buffer
are used.
Return non-nil in the case where no autoloads were added at point."
  (interactive "fGenerate autoloads for file: ")
  (autoload-generate-file-autoloads file (current-buffer)))

(defun autoload-generate-file-autoloads (file outbuf)
  "Insert an autoload section for FILE in the appropriate buffer.
Autoloads are generated for defuns and defmacros in FILE
marked by `generate-autoload-cookie' (which see).
If FILE is being visited in a buffer, the contents of the buffer are used.
OUTBUF is the buffer in which the autoload statements will be inserted.
Return non-nil in the case where no autoloads were added in the buffer."
  (let ((autoloads-done '())
	(load-name (autoload-file-load-name file))
	(print-length nil)
	(print-readably t)		; This does something in Lucid Emacs.
	(float-output-format nil)
	(visited (get-file-buffer file))
        (absfile (expand-file-name file))
        relfile
        ;; nil until we found a cookie.
        output-start)

    (with-current-buffer (or visited
                             ;; It is faster to avoid visiting the file.
                             (autoload-find-file file))
      ;; Obey the no-update-autoloads file local variable.
      (unless no-update-autoloads
        (message "Generating autoloads for %s..." file)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (while (not (eobp))
              (skip-chars-forward " \t\n\f")
              (cond
               ((looking-at (regexp-quote generate-autoload-cookie))
                ;; If not done yet, figure out where to insert this text.
                (unless output-start
                  (with-current-buffer outbuf
                    (setq relfile (file-relative-name absfile))
                    (setq output-start (point)))
                  ;; (message "file=%S, relfile=%S, dest=%S"
                  ;;          file relfile (autoload-generated-file))
                  )
                (search-forward generate-autoload-cookie)
                (skip-chars-forward " \t")
                (if (eolp)
                    (condition-case err
                        ;; Read the next form and make an autoload.
                        (let* ((form (prog1 (read (current-buffer))
                                       (or (bolp) (forward-line 1))))
                               (autoload (make-autoload form load-name)))
                          (if autoload
                              (push (nth 1 form) autoloads-done)
                            (setq autoload form))
                          (let ((autoload-print-form-outbuf outbuf))
                            (autoload-print-form autoload)))
                      (error
                       (message "Error in %s: %S" file err)))

                  ;; Copy the rest of the line to the output.
                  (princ (buffer-substring
                          (progn
                            ;; Back up over whitespace, to preserve it.
                            (skip-chars-backward " \f\t")
                            (if (= (char-after (1+ (point))) ? )
                                ;; Eat one space.
                                (forward-char 1))
                            (point))
                          (progn (forward-line 1) (point)))
                         outbuf)))
               ((looking-at ";")
                ;; Don't read the comment.
                (forward-line 1))
               (t
                (forward-sexp 1)
                (forward-line 1))))))

        (when output-start
          (with-current-buffer outbuf
            (save-excursion
              ;; Insert the section-header line which lists the file name
              ;; and which functions are in it, etc.
              (goto-char output-start)
              (autoload-insert-section-header
               outbuf autoloads-done load-name relfile
               (nth 5 (file-attributes relfile)))
              (insert ";;; Generated autoloads from " relfile "\n"))
            (insert generate-autoload-section-trailer)))
        (message "Generating autoloads for %s...done" file))
      (or visited
          ;; We created this buffer, so we should kill it.
          (kill-buffer (current-buffer))))
    (not output-start)))

(defvar autoload-modified-buffers nil)

(defun autoload-save-buffers ()
  (while autoload-modified-buffers
    (with-current-buffer (pop autoload-modified-buffers)
      (save-buffer))))

;;;###autoload
(defun update-file-autoloads (file &optional save-after)
  "Update the autoloads for FILE in `generated-autoload-file'
\(which FILE might bind in its local variables).
If SAVE-AFTER is non-nil (which is always, when called interactively),
save the buffer too.

Return FILE if there was no autoload cookie in it, else nil."
  (interactive "fUpdate autoloads for file: \np")
  (let ((existing-buffer (get-file-buffer file))
        (no-autoloads nil))
    (with-temp-buffer
      ;; Let's presume the file is not visited, so we call
      ;; autoload-find-destination from a dummy buffer, except if the file
      ;; is visited, in which case we use that buffer instead.
      (if existing-buffer (set-buffer existing-buffer))

      (if (catch 'up-to-date
            (with-current-buffer (autoload-find-destination file)
              (setq no-autoloads (generate-file-autoloads file))
              t))
          (if save-after (autoload-save-buffers))
        (if (interactive-p)
            (message "Autoload section for %s is up to date." file))))
    ;; If we caught `up-to-date', it means there are autoload entries, since
    ;; otherwise we wouldn't have detected their up-to-dateness.
    (if no-autoloads file)))

(defun autoload-find-destination (file)
  "Find the destination point of the current buffer's autoloads.
FILE is the file name of the current buffer.
Returns a buffer whose point is placed at the requested location.
Throws `up-to-date' if the file's autoloads are uptodate, otherwise
removes any prior now out-of-date autoload entries.
The current buffer only matters if it is visiting a file or if it has a buffer-local
value for some variables such as `generated-autoload-file', so it's OK
to call it from a dummy buffer if FILE is not currently visited."
  ;; (message "autoload-find-destination %S" file)
  (let ((load-name (autoload-file-load-name file))
        (existing-buffer (if buffer-file-name (current-buffer)))
	(found nil))
    (with-current-buffer
        ;; We must read/write the file without any code conversion,
        ;; but still decode EOLs.
        (let ((coding-system-for-read 'raw-text))
          (find-file-noselect
           (autoload-ensure-default-file (autoload-generated-file))))
      ;; This is to make generated-autoload-file have Unix EOLs, so
      ;; that it is portable to all platforms.
      (setq buffer-file-coding-system 'raw-text-unix)
      (or (> (buffer-size) 0)
	  (error "Autoloads file %s does not exist" buffer-file-name))
      (or (file-writable-p buffer-file-name)
	  (error "Autoloads file %s is not writable" buffer-file-name))
      (widen)
      (goto-char (point-min))
      ;; Look for the section for LOAD-NAME.
      (while (and (not found)
                  (search-forward generate-autoload-section-header nil t))
        (let ((form (autoload-read-section-header)))
          (cond ((string= (nth 2 form) load-name)
                 ;; We found the section for this file.
                 ;; Check if it is up to date.
                 (let ((begin (match-beginning 0))
                       (last-time (nth 4 form))
                       (file-time (nth 5 (file-attributes file))))
                   (if (and (or (null existing-buffer)
				    (not (buffer-modified-p existing-buffer)))
				(listp last-time) (= (length last-time) 2)
				(not (time-less-p last-time file-time)))
                       (throw 'up-to-date nil)
                     (autoload-remove-section begin)
                     (setq found t))))
                ((string< load-name (nth 2 form))
                 ;; We've come to a section alphabetically later than
                 ;; LOAD-NAME.  We assume the file is in order and so
                 ;; there must be no section for LOAD-NAME.  We will
                 ;; insert one before the section here.
                 (goto-char (match-beginning 0))
                 (setq found t)))))
      (or found
          (progn
            ;; No later sections in the file.  Put before the last page.
            (goto-char (point-max))
            (search-backward "\f" nil t)))
      (unless (memq (current-buffer) autoload-modified-buffers)
        (push (current-buffer) autoload-modified-buffers))
      (current-buffer))))

(defun autoload-remove-section (begin)
  (goto-char begin)
  (search-forward generate-autoload-section-trailer)
  (delete-region begin (point)))

;;;###autoload
(defun update-directory-autoloads (&rest dirs)
  "\
Update loaddefs.el with all the current autoloads from DIRS, and no old ones.
This uses `update-file-autoloads' (which see) to do its work.
In an interactive call, you must give one argument, the name
of a single directory.  In a call from Lisp, you can supply multiple
directories as separate arguments, but this usage is discouraged.

The function does NOT recursively descend into subdirectories of the
directory or directories specified."
  (interactive "DUpdate autoloads from directory: ")
  (let* ((files-re (let ((tmp nil))
		     (dolist (suf (get-load-suffixes)
				  (concat "^[^=.].*" (regexp-opt tmp t) "\\'"))
		       (unless (string-match "\\.elc" suf) (push suf tmp)))))
	 (files (apply 'nconc
		       (mapcar (lambda (dir)
				 (directory-files (expand-file-name dir)
						  t files-re))
			       dirs)))
	 (this-time (current-time))
	 (no-autoloads nil)		;files with no autoload cookies.
	 (autoloads-file (autoload-generated-file))
	 (top-dir (file-name-directory autoloads-file)))

    (with-current-buffer
	(find-file-noselect (autoload-ensure-default-file autoloads-file))
      (save-excursion

	;; Canonicalize file names and remove the autoload file itself.
	(setq files (delete (autoload-trim-file-name buffer-file-name)
			    (mapcar 'autoload-trim-file-name files)))

	(goto-char (point-min))
	(while (search-forward generate-autoload-section-header nil t)
	  (let* ((form (autoload-read-section-header))
		 (file (nth 3 form)))
	    (cond ((and (consp file) (stringp (car file)))
		   ;; This is a list of files that have no autoload cookies.
		   ;; There shouldn't be more than one such entry.
		   ;; Remove the obsolete section.
		   (autoload-remove-section (match-beginning 0))
		   (let ((last-time (nth 4 form)))
		     (dolist (file file)
		       (let ((file-time (nth 5 (file-attributes file))))
			 (when (and file-time
				    (not (time-less-p last-time file-time)))
			   ;; file unchanged
			   (push file no-autoloads)
			   (setq files (delete file files)))))))
		  ((not (stringp file)))
		  ((not (file-exists-p (expand-file-name file top-dir)))
		   ;; Remove the obsolete section.
		   (autoload-remove-section (match-beginning 0)))
		  ((equal (nth 4 form) (nth 5 (file-attributes file)))
		   ;; File hasn't changed.
		   nil)
		  (t
		   (update-file-autoloads file)))
	    (setq files (delete file files)))))
      ;; Elements remaining in FILES have no existing autoload sections yet.
      (setq no-autoloads
	    (append no-autoloads
		    (delq nil (mapcar 'update-file-autoloads files))))
      (when no-autoloads
	;; Sort them for better readability.
	(setq no-autoloads (sort no-autoloads 'string<))
	;; Add the `no-autoloads' section.
	(goto-char (point-max))
	(search-backward "\f" nil t)
	(autoload-insert-section-header
	 (current-buffer) nil nil no-autoloads this-time)
	(insert generate-autoload-section-trailer))

      (save-buffer))))

(define-obsolete-function-alias 'update-autoloads-from-directories
    'update-directory-autoloads "22.1")

;;;###autoload
(defun batch-update-autoloads ()
  "Update loaddefs.el autoloads in batch mode.
Calls `update-directory-autoloads' on the command line arguments."
  (apply 'update-directory-autoloads command-line-args-left)
  (setq command-line-args-left nil))

(provide 'autoload)

;; arch-tag: 00244766-98f4-4767-bf42-8a22103441c6
;;; autoload.el ends here
