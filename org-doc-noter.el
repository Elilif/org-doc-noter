;;; org-doc-noter.el -*- lexical-binding: t; -*-

;; Author: Eli Qian <eli.q.qian@gmail.com>
;; Url: https://github.com/Elilif/org-doc-noter

;; Version: 0.1
;; Package-Requires: ((emacs "28.2"))
;; Keywords: org-mode, annotator
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Yet another synchronized document annotator.
;;
;; This package is inspired by weirdNox's https://github.com/weirdNox/org-noter
;; and the main improvements are as follows:
;; 1. Support hightlighting notes in the current page
;; 2. Support info mode and eww mode(WIP)
;; 3. Better performance
;;
;; The main drawback of this package is that many details are not well done, and
;; it is not as comprehensive as org-noter.
;;
;;
;; Usage:
;; This package uses the same key bindings and property settings as org-ntoer.
;; You can call `org-doc-noter' in either a note file(org-mode) or a document
;; buffer(pdf-view-mode, doc-view-mode, Info-mode, nov-mode).


;;; Code:

(require 'cl-lib)
(require 'outline)
(require 'info)
(require 'org)
(require 'org-element)

(declare-function doc-view-goto-page "doc-view")
(declare-function doc-view-fit-width-to-window "doc-view")
(declare-function image-mode-window-get "image-mode")
(declare-function pdf-view-goto-page "ext:pdf-view")
(declare-function pdf-view-fit-width-to-window "ext:pdf-view")
(declare-function pdf-view-mode "ext:pdf-view")
(declare-function nov-goto-document "ext:nov")
(defvar nov-documents-index)
(defvar org-doc-noter-doc-mode)


;;;; customizations

(defgroup org-doc-noter nil
  "Highlight and annotate documents using Org mode."
  :group 'org)

(defcustom org-doc-noter-property-doc-file "NOTER_DOCUMENT"
  "Name of the property that specifies the document."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-property-note-location "NOTER_PAGE"
  "Name of the property that specifies the location of the current note."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-property-note-remark "NOTER_REMARK"
  "Name of the property that specifies the remark location of the
current note."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-property-note-remark-hash "NOTER_REMARK_HASH"
  "Name of the property that specifies the hash of remark."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-property-split-fraction "NOTER_SPLIT_FRACTION"
  "Name of the property that specifies the fraction of the frame
that the document window will occupy when split."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-notes-dir (expand-file-name "org-doc-noter/"
                                                     user-emacs-directory)
  "Default directory where notes are stored."
  :group 'org-doc-noter
  :type 'directory)

(defcustom org-doc-noter-info-buffer-name "*info-doc*"
  "Default buffer name for Info document mode."
  :group 'org-doc-noter
  :type 'string)

(defcustom org-doc-noter-note-name-functions
  '((Info-mode . org-doc-noter-note-name-info)
    (pdf-view-mode . org-doc-noter-note-name-default)
    (doc-view-mode . org-doc-noter-note-name-default)
    (nov-mode . org-doc-noter-note-name-default))
  "Alist of (MODE . FUNCTION) pairs parsed by `org-doc-noter-get-note-info'.

MODE should be a symbol indicating current document buffer's
major mode. FUNCTION should be a function that takes one
argument(a document file path) and returns the note file."
  :group 'org-doc-noter
  :type '(alist :key-type symbol :value-type function))

(defcustom org-doc-noter-doc-split-fraction 0.5
  "Fraction of the frame that the document window will occupy when split.

This value should be a number between 0 and 1."
  :group 'org-doc-noter
  :type '(number :tag "Horizontal fraction"))

(defcustom org-doc-noter-highlight-selected-text t
  "When non-nil, append selected text to existing note."
  :group 'org-doc-noter
  :type 'boolean)

(defcustom org-doc-noter-insert-selected-text t
  "When nont-nil, highlight the selected text in the doucment buffer.

Notice that this option does not work in `pdf-view-mode' or
`doc-view-mode'."
  :group 'org-doc-noter
  :type 'boolean)

(defface org-doc-noter-midline
  '((t (:underline (:color "purple" :style line
                           :position 3))))
  "Face used to indicate that there is no note in the current
doc window."
  :group 'org-doc-noter)

(defface org-doc-noter-highlight
  '((t (:foreground "purple")))
  "Face used to highlight notes in the current doc window."
  :group 'org-doc-noter)

(defface org-doc-noter-remarks
  '((t (:background "pink")))
  "Face used to highlight text in the document."
  :group 'org-doc-noter)

;;;; utilities

(defvar-local org-doc-noter-session nil
  "org-doc-noter session for current buffer.")
(put 'org-doc-noter-session 'permanent-local t)

(defvar-local org-doc-noter-highlights nil)
(put 'org-doc-noter-highlights 'permanent-local t)

(defvar-local org-doc-noter-remarks nil)
(put 'org-doc-noter-remarks 'permanent-local t)

(defvar-local org-doc-noter--window-start nil)
(defvar-local org-doc-noter--window-end nil)

(defvar org-doc-noter-sessions nil
  "List of org-doc-noter sessions.")


(cl-defstruct (org-doc-noter-session (:constructor org-doc-noter-session-create)
                                     (:copier nil))
  "Struct to hold org-doc-noter information."
  id               ;; unique id for org-doc-noter session
  doc-buffer       ;; the document buffer
  doc-path         ;; the document file path
  doc-mode         ;; the major mode of the document buffer
  note-buffer      ;; the note buffer
  note-ast         ;; the structure returned by `org-element-parse-buffer'
  prev-notes       ;; notes before the current doc window
  current-notes    ;; notes in the current doc window
  after-notes      ;; notes after the current doc window
  level            ;; the level of the root note entry
  doc-loc          ;; the location of the document
  split-fraction   ;; the fraction of the frame that the document window will occupy when split.
  modified-tick)   ;; the tick counter of the note buffer,see `buffer-modified-tick' for details.

(defmacro org-doc-noter-with-note-buffer (&rest body)
  "Execute the forms in BODY with note buffer temporarily current."
  (declare (indent defun) (debug t))
  `(when org-doc-noter-session
     (let ((note-buffer (org-doc-noter-session-note-buffer org-doc-noter-session)))
       (if-let ((window (get-buffer-window note-buffer)))
           (with-selected-window (get-buffer-window note-buffer)
             (with-current-buffer note-buffer
               ,@body))
         (with-current-buffer note-buffer
           ,@body)))))

(defmacro org-doc-noter-with-doc-buffer (&rest body)
  "Execute the forms in BODY with document buffer temporarily current."
  (declare (indent defun) (debug t))
  `(when org-doc-noter-session
     (let ((doc-buffer (org-doc-noter-session-doc-buffer org-doc-noter-session)))
       (if-let ((window (get-buffer-window doc-buffer)))
           (with-selected-window (get-buffer-window doc-buffer)
             (with-current-buffer doc-buffer
               ,@body))
         (with-current-buffer doc-buffer
           ,@body)))))

(defmacro org-doc-noter--get-prop (prop)
  "Return the symbol of PROP, which will be parsed by
`org-element-property'."
  (let ((sym (intern (concat "org-doc-noter-property-" prop))))
    `(intern (concat ":" ,sym))))

(defsubst org-doc-noter--parse-property (prop)
  "Read one Lisp expression which is represented as text by PROP."
  (when (and prop (not (string-empty-p prop)))
    (read prop)))

(defsubst org-doc-noter--get-doc-file ()
  "Return the name of file current buffer is visiting."
  (if (eq major-mode 'Info-mode)
      (if (Info-virtual-file-p Info-current-file)
          (user-error "Info file is virtual!")
        Info-current-file)
    (buffer-file-name)))

(defsubst org-doc-noter--parse-loc (location)
  "Return the cdr of LOCATION if it is a cons cell, or else itself."
  (or (cdr-safe location) location))

(defun org-doc-noter-note-name-default (doc-path)
  "Return the note file path for DOC-PATH."
  (let ((note-file (file-name-concat org-doc-noter-notes-dir
                                     (file-name-with-extension
                                      (file-name-base doc-path)
                                      ".org"))))
    (unless (file-exists-p note-file)
      (make-empty-file note-file))
    note-file))

(defun org-doc-noter-note-name-info (_doc-path)
  "Return the info note file path for DOC-PATH."
  (let ((note-file (file-name-concat
                    org-doc-noter-notes-dir
                    (file-name-with-extension "info" ".org"))))
    (unless (file-exists-p note-file)
      (make-empty-file note-file))
    note-file))

(defun org-doc-noter-location= (loc1 loc2)
  "Return t if LOC1 and LOC1 are equal.

LOC1 and LOC2 shoud be a cons ((LOCATION . POINT)) or a
number (LOCATION)."
  (pcase (org-doc-noter-session-doc-mode org-doc-noter-session)
    ;; (PAGE . PAGE) or PAGE
    ;;
    ;; In `pdf-view-mode' or `doc-view-mode', LOC1 and LOC1 are equal if they
    ;; are both in the same page.
    ((or 'pdf-view-mode 'doc-view-mode)
     (= (org-doc-noter--parse-loc loc1)
        (org-doc-noter--parse-loc loc2)))
    ;; (INDEX . POINT)
    ;;
    ;; In `nov-mode', LOC1 and LOC1 are equal if they are both in the
    ;; currently rendered document and both in the current window.
    ('nov-mode
     (let ((loc1p (org-doc-noter--parse-loc loc1))
           (loc2p (org-doc-noter--parse-loc loc2))
           (ws (window-start))
           (we (window-end nil t)))
       (and (= (car loc1) (car loc2))
            (>= loc1p ws) (<= loc1p we)
            (>= loc2p ws) (<= loc2p we))))
    ;; (INFO NODE . POINT)
    ;;
    ;; In `Info-mode', LOC1 and LOC1 are equal if they are both in the
    ;; same info node and both in the current window.
    ('Info-mode
     (let ((loc1p (org-doc-noter--parse-loc loc1))
           (loc2p (org-doc-noter--parse-loc loc2))
           (ws (window-start))
           (we (window-end nil t)))
       (and (string= (car loc1) (car loc2))
            (>= loc1p ws) (<= loc1p we)
            (>= loc2p ws) (<= loc2p we))))))

(defun org-doc-noter-location< (loc1 loc2)
  "Return t if LOC1 is before LOC1."
  (pcase (org-doc-noter-session-doc-mode org-doc-noter-session)
    ((or 'pdf-view-mode 'doc-view-mode)
     (< (org-doc-noter--parse-loc loc1)
        (org-doc-noter--parse-loc loc2)))
    ('nov-mode
     (or (< (car loc1) (car loc2))
         (and (= (car loc1) (car loc2))
              (< (cdr loc1) (cdr loc2)))))
    ('Info-mode
     (< (cdr loc1) (cdr loc2)))))

(defun org-doc-noter-location> (loc1 loc2)
  "Return t if LOC1 is after LOC1."
  (pcase (org-doc-noter-session-doc-mode org-doc-noter-session)
    ((or 'pdf-view-mode 'doc-view-mode)
     (> (org-doc-noter--parse-loc loc1)
        (org-doc-noter--parse-loc loc2)))
    ('nov-mode
     (or (> (car loc1) (car loc2))
         (and (= (car loc1) (car loc2))
              (> (cdr loc1) (cdr loc2)))))
    ('Info-mode
     (> (cdr loc1) (cdr loc2)))))

(defun org-doc-noter--parse-ast ()
  "Parse the ast in `org-doc-noter-session'.

Set prev-notes, current-notes and after notes in
`org-doc-noter-session' according to the current position."
  (org-doc-noter-with-doc-buffer
    (let ((current-loc (org-doc-noter-session-doc-loc org-doc-noter-session))
          (ast (org-element-contents (org-doc-noter-session-note-ast
                                      org-doc-noter-session)))
          previous current after)
      (org-element-map ast 'headline
        (lambda (hl)
          (when (= (+ (org-doc-noter-session-level org-doc-noter-session) 1)
                   (org-element-property :level hl))
            (when-let ((loc (org-doc-noter--parse-property
                             (org-element-property
                              (org-doc-noter--get-prop "note-location") hl))))
              (cond
               ((org-doc-noter-location= loc current-loc) (push hl current))
               ((org-doc-noter-location< loc current-loc) (push hl previous))
               ((org-doc-noter-location> loc current-loc) (push hl after)))))))
      (setf (org-doc-noter-session-prev-notes org-doc-noter-session) previous
            (org-doc-noter-session-current-notes org-doc-noter-session) (reverse current)
            (org-doc-noter-session-after-notes org-doc-noter-session) (reverse after)))))

(defun org-doc-noter-update-note-ast ()
  "Update ast in `org-doc-noter-session' if the note buffer is modified."
  (org-doc-noter-with-note-buffer
    (let ((tick (buffer-modified-tick)))
      (unless (eq (org-doc-noter-session-modified-tick org-doc-noter-session)
                  tick)
        (setf (org-doc-noter-session-note-ast org-doc-noter-session)
              (car (org-element-contents (org-element-parse-buffer))))
        (setf (org-doc-noter-session-modified-tick org-doc-noter-session)
              tick))))
  (org-doc-noter--parse-ast))

(defun org-doc-noter--get-doc-location ()
  "Return the current location info of the doc buffer."
  (pcase major-mode
    ((or 'pdf-view-mode 'doc-view-mode)
     (let ((loc (image-mode-window-get 'page)))
       (cons loc loc)))
    ('Info-mode
     (cons Info-current-node (point)))
    ('nov-mode
     (cons nov-documents-index (point)))))

(defun org-doc-noter-make-indirect-buffer (buffer name &optional file-path)
  "Create and return an new \"indirect\" buffer for BUFFER, named NAME.

If BUFFER is a Info buffer and FILE-PATH is supplied, create a
new buffer instead."
  (let* ((base-buffer (or (buffer-base-buffer buffer) buffer))
         (result (cond
                  ;; reuse `*info-doc*' buffer if call `org-doc-noter' in that
                  ;; buffer
                  ((and (eq (buffer-local-value 'major-mode buffer) 'Info-mode)
                        org-doc-noter-doc-mode)
                   (current-buffer))
                  ((eq (buffer-local-value 'major-mode base-buffer) 'Info-mode)
                   (let ((info-buffer (generate-new-buffer org-doc-noter-info-buffer-name)))
                     (with-current-buffer info-buffer
                       (info-setup file-path info-buffer))
                     info-buffer))
                  (t
                   (make-indirect-buffer
                    base-buffer
                    (generate-new-buffer-name
                     (concat name "-" (buffer-name base-buffer)))
                    t t)))))
    (with-current-buffer result
      (pcase major-mode
        ('pdf-view-mode
         (pdf-view-mode)
         (setq buffer-file-name file-path))))
    result))

(defun org-doc-noter-get-doc-info ()
  "Return the document info.

The result is a vector: [BUFFER FILE MODE LOCATION]."
  (cond
   ((eq major-mode 'org-mode)
    (when (org-before-first-heading-p)
      (user-error "You must be inside a heading!"))
    (let* ((file-path (org-entry-get nil org-doc-noter-property-doc-file t))
           (doc-buffer (org-doc-noter-make-indirect-buffer
                        (if (member (file-name-directory file-path)
                                    Info-directory-list)
                            (let ((info-buffer (get-buffer-create "*info*")))
                              (with-current-buffer info-buffer
                                (Info-mode)
                                info-buffer))
                          (find-file-noselect file-path))
                        "Doc" file-path))
           (doc-loc (org-doc-noter--parse-property
                     (org-entry-get nil org-doc-noter-property-note-location t))))
      (vector doc-buffer
              file-path
              (buffer-local-value 'major-mode doc-buffer)
              doc-loc)))
   (t
    (vector (org-doc-noter-make-indirect-buffer
             (current-buffer) "Doc" (org-doc-noter--get-doc-file))
            (org-doc-noter--get-doc-file)
            major-mode
            (org-doc-noter--get-doc-location)))))

(defun org-doc-noter-get-note-info ()
  "return the note info.

The result is a vector: [BUFFER AST MOD-TICK]:
BUFFER is the note buffer.
AST is the structure returned by `org-element-parse-buffer'.
MOD-TICK is BUFFER's tick counter returned by `buffer-modified-tick'."
  (cond
   ((eq major-mode'org-mode)
    (vector (org-doc-noter-make-indirect-buffer
             (current-buffer) "Notes")
            (org-element-parse-buffer)
            (buffer-modified-tick)))
   (t
    (let* ((doc-file (org-doc-noter--get-doc-file))
           (note-file (funcall (alist-get major-mode
                                          org-doc-noter-note-name-functions)
                               doc-file))
           (buffer (find-file-noselect note-file))
           ast modified-tick)
      (with-current-buffer buffer
        (org-doc-noter--note-init doc-file)
        (setq ast (org-element-parse-buffer)
              modified-tick (buffer-modified-tick)))
      (vector (org-doc-noter-make-indirect-buffer
               buffer "Notes")
              ast
              modified-tick)))))

(defun org-doc-noter--create-session ()
  "Setup org-doc-noter session."
  (let* ((id (md5 (format "%s%s%s" (random) (float-time) (recent-keys))))
         (doc-info (org-doc-noter-get-doc-info)) ;; [BUFFER FILE MODE LOCATION]
         (note-info (org-doc-noter-get-note-info)) ;; [BUFFER AST MOD-TICK]
         (doc-buffer (aref doc-info 0))
         (doc-file (aref doc-info 1))
         (doc-mode (aref doc-info 2))
         (note-buffer (aref note-info 0))
         (note-ast (org-element-map (aref note-info 1) 'headline
                     (lambda (hl)
                       (when (string= (org-element-property
                                       (org-doc-noter--get-prop "doc-file") hl)
                                      doc-file)
                         hl))
                     nil t 'headline)))

    (with-current-buffer note-buffer
      (org-narrow-to-subtree note-ast))

    (org-doc-noter-session-create
     :id id
     :doc-buffer doc-buffer
     :doc-path doc-file
     :doc-mode doc-mode
     :note-buffer note-buffer
     :note-ast note-ast
     :level (org-element-property :level note-ast)
     :doc-loc (if (eq major-mode 'org-mode)
                  (org-doc-noter--parse-property
                   (or (org-entry-get nil org-doc-noter-property-note-location)
                       (org-element-property
                        (org-doc-noter--get-prop "note-location") note-ast)))
                (aref doc-info 3))
     :split-fraction (or (org-doc-noter--parse-property
                          (org-element-property
                           (org-doc-noter--get-prop "split-fraction") note-ast))
                         org-doc-noter-doc-split-fraction)
     :modified-tick (aref note-info 2))))

(defun org-doc-noter--setup-windows (session)
  "Setup window configurations for SESSION."
  (let* ((doc-buffer (org-doc-noter-session-doc-buffer session))
         (doc-window (selected-window))
         (note-buffer (org-doc-noter-session-note-buffer session)))
    (delete-other-windows)
    (set-window-buffer doc-window doc-buffer)
    (set-window-dedicated-p doc-window t)

    (set-window-buffer (split-window-right
                        (ceiling (* (org-doc-noter-session-split-fraction session)
                                    (window-total-width))))
                       note-buffer)

    (with-current-buffer doc-buffer
      (setq org-doc-noter-session session))

    (with-current-buffer note-buffer
      (setq org-doc-noter-session session))))

(defun org-doc-noter--note-init (doc-path)
  "Initialize the note buffer accroding to DOC-info."
  (let* ((doc-name (file-name-base doc-path))
         (note-finder (lambda ()
                        (goto-char (point-min))
                        (re-search-forward
                         (org-re-property
                          org-doc-noter-property-doc-file
                          t nil doc-path)
                         nil t))))
    (unless (funcall note-finder)
      (goto-char (point-max))
      (insert "\n")
      (insert (concat "* " doc-name "\n"))
      (org-entry-put nil org-doc-noter-property-doc-file doc-path))))

(defun org-doc-noter-adjust-headline-level ()
  (let* ((root-level (org-doc-noter-session-level org-doc-noter-session))
         (current-level (org-current-level))
         (diff (- (1+ root-level) current-level))
         (changer (if (> diff 0) 'org-do-demote 'org-do-promote)))
    (dotimes (_ (abs diff)) (funcall changer))))

;;;; highlights

(defun org-doc-noter-remark-make (beg end)
  (deactivate-mark)
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'face 'org-doc-noter-remarks)
    (push ov org-doc-noter-remarks)
    (prin1-to-string (cons beg end))))

(defun org-doc-noter--note-overlays-clean ()
  "Remove all highlights."
  (org-doc-noter-with-note-buffer
    (dolist (ov org-doc-noter-highlights)
      (delete-overlay ov))
    (setq org-doc-noter-highlights nil))
  (org-doc-noter-with-doc-buffer
    (dolist (ov org-doc-noter-remarks)
      (delete-overlay ov))
    (setq org-doc-noter-remarks nil)))

(defun org-doc-noter--note-highlight (headline face)
  (let* ((beg (org-element-property :begin headline))
         (end (org-element-property :contents-begin headline))
         (ov (make-overlay (1+ beg) (1- end))))
    (overlay-put ov 'face face)
    (push ov org-doc-noter-highlights)))

(defun org-doc-noter-note-highlight ()
  (org-doc-noter-update-note-ast)
  (org-doc-noter-with-note-buffer
    (let* ((current-headlines (org-doc-noter-session-current-notes
                               org-doc-noter-session))
           (prev-headline (or (car (org-doc-noter-session-prev-notes
                                    org-doc-noter-session))
                              (org-doc-noter-session-note-ast
                               org-doc-noter-session))))
      (org-doc-noter--note-overlays-clean)
      (if current-headlines
          (dolist (note current-headlines)
            (org-doc-noter--note-highlight note 'org-doc-noter-highlight))
        (org-doc-noter--note-highlight prev-headline 'org-doc-noter-midline))

      (org-element-map current-headlines 'headline
        (lambda (hl)
          (when-let ((remark (org-doc-noter--parse-property
                              (org-element-property
                               (org-doc-noter--get-prop "note-remark")
                               hl))))
            (org-doc-noter-with-doc-buffer
              (let* ((beg (car remark))
                     (end (cdr remark))
                     (ov (make-overlay beg end))
                     (hash (org-element-property
                            (org-doc-noter--get-prop "note-remark-hash")
                            hl))
                     (new-hash (sha1 (buffer-substring-no-properties beg end))))
                (when (or (not hash)
                          (string= hash new-hash))
                  (overlay-put ov 'face  'org-doc-noter-remarks)
                  (push ov org-doc-noter-remarks)))))))
      (when (org-at-heading-p)
        (goto-char (org-element-property :begin (if current-headlines
                                                    (car current-headlines)
                                                  prev-headline)))
        (recenter)))))

;;;; location change handler
(defvar org-doc-noter-pdf-handler-hook nil
  "Hook run after the pdf buffer's location is changed.")
(defvar org-doc-noter-info-handler-hook nil
  "Hook run after the Info buffer's location is changed.")
(defvar org-doc-noter-nov-handler-hook nil
  "Hook run after the vov buffer's location is changed.")


(defun org-doc-noter-doc-locate (location)
  "Goto LOCATION in curtain mode."
  (when location
    (cond
     ((not (listp location)) (pdf-view-goto-page location))
     (t
      (pcase major-mode
        ('pdf-view-mode (pdf-view-goto-page (cdr location)))
        ('doc-view-mode (doc-view-goto-page (cdr location)))
        ('nov-mode
         (nov-goto-document (car location))
         (goto-char (cdr location))
         (recenter))
        ('Info-mode
         (Info-goto-node (car location))
         (goto-char (cdr location))
         (recenter))))))
  (unless org-doc-noter--window-end
    (setq org-doc-noter--window-end (window-end nil t)
          org-doc-noter--window-start (window-start)))
  (org-doc-noter--handler))

(defsubst org-doc-noter--set-window-info ()
  (setq org-doc-noter--window-end (window-end nil t)
        org-doc-noter--window-start (window-start)))

(defun org-doc-noter-pdf-handler ()
  (setf (org-doc-noter-session-doc-loc org-doc-noter-session)
        (org-doc-noter--get-doc-location))
  (org-doc-noter-note-highlight)

  (run-hooks 'org-doc-noter-pdf-handler-hook))

(defun org-doc-noter-info-handler ()
  (when (and (not (Info-virtual-file-p Info-current-file))
             (string= Info-current-file
                      (org-doc-noter-session-doc-path org-doc-noter-session)))
    (setf (org-doc-noter-session-doc-loc org-doc-noter-session)
          (org-doc-noter--get-doc-location)))
  (when-let* ((current-info Info-current-file)
              (orig-info (org-doc-noter-session-doc-path org-doc-noter-session)))
    (unless (or (Info-virtual-file-p current-info)
                (string= current-info orig-info))
      (org-doc-noter-kill-session t)
      (org-doc-noter)))
  (when (or (< (window-start) org-doc-noter--window-start)
            (> (window-end nil t) org-doc-noter--window-end))
    (org-doc-noter--set-window-info)
    (org-doc-noter-note-highlight)

    (run-hooks 'org-doc-noter-info-handler-hook)))

(defun org-doc-noter-nov-handler ()
  (setf (org-doc-noter-session-doc-loc org-doc-noter-session)
        (org-doc-noter--get-doc-location))
  (when (or (< (window-start) org-doc-noter--window-start)
            (> (window-end nil t) org-doc-noter--window-end))
    (org-doc-noter--set-window-info)
    (org-doc-noter-note-highlight)

    (run-hooks 'org-doc-noter-nov-handler-hook)))

(defun org-doc-noter--handler (&rest _args)
  (when org-doc-noter-doc-mode
    (pcase major-mode
      ((or 'pdf-view-mode 'doc-view-mode)
       (org-doc-noter-pdf-handler))
      ('Info-mode
       (org-doc-noter-info-handler))
      ('nov-mode
       (org-doc-noter-nov-handler)))))

;;;; doc-mode and note-mode setup

(defun org-doc-noter--save-place ()
  "Save the last visited location for this document."
  (when-let ((ast (org-doc-noter-session-note-ast org-doc-noter-session))
             (loc (org-doc-noter-session-doc-loc org-doc-noter-session)))
    (org-doc-noter-with-note-buffer
      (let ((root-pos (org-element-property :begin ast)))
        (org-entry-put root-pos org-doc-noter-property-note-location
                       (prin1-to-string loc))))))

(defun org-doc-noter-doc-mode-setup ()
  "Setup the document buffer."
  (let* ((loc (org-doc-noter-session-doc-loc org-doc-noter-session)))
    (org-doc-noter-doc-locate loc)
    (org-doc-noter-update-note-ast)
    (pcase major-mode
      ('pdf-view-mode
       (pdf-view-fit-width-to-window)
       (add-hook 'pdf-view-after-change-page-hook
                 #'org-doc-noter--handler nil t))
      ('doc-view-mode
       (doc-view-fit-width-to-window)
       (advice-add 'doc-view-goto-page :after
                   #'org-doc-noter--handler))
      ('Info-mode
       (add-hook 'post-command-hook
                 #'org-doc-noter--handler nil t))
      ('nov-mode
       (add-hook 'post-command-hook
                 #'org-doc-noter--handler nil t)))))

(defun org-doc-noter-doc-mode-clean ()
  (when (memq org-doc-noter-session org-doc-noter-sessions)
    (setq org-doc-noter-sessions (delq org-doc-noter-session org-doc-noter-sessions)))
  (setq org-doc-noter-session nil)
  (pcase major-mode
    ('pdf-view-mode
     (remove-hook 'pdf-view-after-change-page-hook
                  #'org-doc-noter--handler t))
    ('doc-view-mode
     (advice-remove 'doc-view-goto-page
                    #'org-doc-noter--handler))
    ('Info-mode
     (remove-hook 'post-command-hook
                  #'org-doc-noter--handler t))
    ('nov-mode
     (remove-hook 'post-command-hook
                  #'org-doc-noter--handler t))))

;;;###autoload
(define-minor-mode org-doc-noter-doc-mode
  "Minor mode for the document buffer."
  :global nil
  :keymap
  (let ((map (make-sparse-keymap)))
    (keymap-set map "q" #'org-doc-noter-kill-session)
    (keymap-set map "i" #'org-doc-noter-insert-note)
    (keymap-set map "C-M-." #'org-doc-noter-sync-current-page)
    (keymap-set map "C-M-p" #'org-doc-noter-sync-prev-page)
    (keymap-set map "C-M-n" #'org-doc-noter-sync-next-page)
    map)
  (if org-doc-noter-doc-mode
      (org-doc-noter-doc-mode-setup)
    (org-doc-noter-doc-mode-clean)))

(defun org-doc-noter-notes-mode-setup ()
  "Setup the note buffer."
  (org-cycle-hide-drawers 'all)
  (org-cycle-content (1+ (org-doc-noter-session-level
                          org-doc-noter-session)))
  (org-doc-noter-note-highlight))

;;;###autoload
(define-minor-mode org-doc-noter-notes-mode
  "Minor mode for the notes buffer."
  :global nil
  :keymap
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-M-." #'org-doc-noter-sync-current-page)
    (keymap-set map "C-M-p" #'org-doc-noter-sync-prev-page)
    (keymap-set map "C-M-n" #'org-doc-noter-sync-next-page)
    map)
  (if org-doc-noter-notes-mode
      (org-doc-noter-notes-mode-setup)))

;;;; interactive functions
(defvar org-doc-noter-insert-heading-hook nil
  "Hook run after inserting a new heading.

Each function takes one argument: prefix arg in raw form.")

;;;###autoload
(defun org-doc-noter-kill-session (&optional keep-doc-buffer)
  "Kill an `org-doc-noter' session."
  (interactive)
  (when org-doc-noter-session
    (let ((note-buffer (org-doc-noter-session-note-buffer org-doc-noter-session)))
      (when (memq org-doc-noter-session org-doc-noter-sessions)
        (setq org-doc-noter-sessions (delq org-doc-noter-session org-doc-noter-sessions)))
      (org-doc-noter--save-place)
      (org-doc-noter--note-overlays-clean)
      (kill-buffer note-buffer)
      (org-doc-noter-with-doc-buffer
        (delete-other-windows)
        (set-window-dedicated-p (selected-window) nil)
        (setq org-doc-noter-session nil)
        (unless keep-doc-buffer
          (org-doc-noter-doc-mode -1)
          (kill-buffer))))))

;;;###autoload
(defun org-doc-noter-insert-note (&optional arg)
  "Insert note associated with the current location.

See `org-doc-noter-highlight-selected-text' and
`org-doc-noter-insert-selected-text' for details."
  (interactive "P")
  (org-doc-noter-update-note-ast)
  (let* ((current-notes (org-doc-noter-session-current-notes
                         org-doc-noter-session))
         (prev-note (or (car (org-doc-noter-session-prev-notes
                              org-doc-noter-session))
                        (org-doc-noter-session-note-ast
                         org-doc-noter-session)))
         (loc (org-doc-noter-session-doc-loc org-doc-noter-session))
         (pos 0)
         (append? nil)
         (collection (org-element-map current-notes 'headline
                       (lambda (hl)
                         (let ((end (org-element-property :end hl)))
                           (setq pos (max pos end))
                           (cons (org-element-property :raw-value hl)
                                 end)))))
         (heading (completing-read "Note: " collection))
         remark-prop selected-text)

    (when (region-active-p)
      (let* ((beg (region-beginning))
             (end (region-end)))
        (setq remark-prop (org-doc-noter-remark-make beg end))
        (setq selected-text (buffer-substring-no-properties beg end))))

    (select-window (get-buffer-window (org-doc-noter-session-note-buffer
                                       org-doc-noter-session)))
    (cond
     (current-notes
      (when-let ((end (cdr-safe (assoc-string heading collection))))
        (setq append? t
              pos end)))
     (prev-note
      (setq pos (if (org-element-property
                     (org-doc-noter--get-prop "doc-file") prev-note)
                    (org-element-map prev-note 'section
                      (lambda (section) (org-element-property :end section))
                      nil t)
                  (org-element-property :end prev-note)))))

    (goto-char pos)
    (if append?
        (progn
          (unless (bolp) (insert "\n"))
          (org-N-empty-lines-before-current 2)
          (forward-line -1)
          (org-fold-show-set-visibility 'minimal))
      (org-insert-heading nil t)
      (insert heading)

      (org-end-of-subtree)
      (unless (bolp) (insert "\n"))

      (org-doc-noter-adjust-headline-level)
      (org-entry-put nil org-doc-noter-property-note-location
                     (prin1-to-string loc)))

    (when (and org-doc-noter-highlight-selected-text
               remark-prop)
      (org-entry-put nil org-doc-noter-property-note-remark remark-prop)
      (org-entry-put nil org-doc-noter-property-note-remark-hash (sha1 selected-text)))

    (when (and org-doc-noter-insert-selected-text
               selected-text)
      (save-excursion
        (insert "\n#+BEGIN_QUOTE\n" selected-text "\n#+END_QUOTE")))

    (run-hook-with-args 'org-doc-noter-insert-heading-hook arg)

    (outline-show-entry)
    (org-cycle-hide-drawers 'all))
  (save-excursion
    (org-doc-noter-update-note-ast)
    (org-doc-noter-note-highlight)))

;;;###autoload
(defun org-doc-noter-sync-current-page ()
  "Go the location of the selected note, in relation to where the point is.

As such, it will only work when the notes window exists."
  (interactive)
  (cond
   (org-doc-noter-notes-mode
    (when-let ((loc (org-doc-noter--parse-property
                     (org-entry-get nil org-doc-noter-property-note-location))))
      (save-excursion
        (org-doc-noter-with-doc-buffer
          (org-doc-noter-doc-locate loc)))))
   (org-doc-noter-doc-mode
    (when-let ((note (or (car-safe
                          (org-doc-noter-session-current-notes org-doc-noter-session))
                         (car-safe
                          (org-doc-noter-session-prev-notes org-doc-noter-session))
                         (org-doc-noter-session-note-ast org-doc-noter-session)))
               (loc (org-element-property :begin note)))
      (org-doc-noter-with-note-buffer
        (goto-char loc)
        (recenter))))))

;;;###autoload
(defun org-doc-noter-sync-prev-page ()
  "Show previous page that has notes."
  (interactive)
  (if-let* ((prev-note (car-safe (org-doc-noter-session-prev-notes
                                  org-doc-noter-session)))
            (loc (org-doc-noter--parse-property
                  (org-element-property
                   (org-doc-noter--get-prop "note-location") prev-note))))
      (org-doc-noter-with-doc-buffer
        (org-doc-noter-doc-locate loc))
    (user-error "There are no more previous pages with notes!")))

;;;###autoload
(defun org-doc-noter-sync-next-page ()
  "Show next page that has notes."
  (interactive)
  (if-let* ((next-note (car-safe (org-doc-noter-session-after-notes
                                  org-doc-noter-session)))
            (loc (org-doc-noter--parse-property
                  (org-element-property
                   (org-doc-noter--get-prop "note-location") next-note))))
      (org-doc-noter-with-doc-buffer
        (org-doc-noter-doc-locate loc))
    (user-error "There are no more following pages with notes!")))

;;;###autoload
(defun org-doc-noter ()
  "Start a org-doc-noter session.

There are two modes of operation.  You may create the session from:
- The Org notes file
- The document to be annotated (PDF, EPUB, ...)

- Creating the session from notes file
--------------------------------------
This will open a session for taking your notes, with indirect
buffers to the document and the notes side by side.

You only need to run this command inside a heading (which will
hold the notes for this document).

- Creating the session from the document
----------------------------------------
If there is already a note for the current document, open the
existing note. Otherwise create an org file with the
same name as the document in `org-doc-noter-notes-dir`."
  (interactive)
  (when org-doc-noter-session
    (org-doc-noter-kill-session))
  (let* ((session (org-doc-noter--create-session))
         (doc-buffer (org-doc-noter-session-doc-buffer session))
         (note-buffer (org-doc-noter-session-note-buffer session)))
    (push session org-doc-noter-sessions)

    (org-doc-noter--setup-windows session)

    (with-current-buffer doc-buffer
      (org-doc-noter-doc-mode 1))

    (with-current-buffer note-buffer
      (org-doc-noter-notes-mode 1))))


;;;; provide
(provide 'org-doc-noter)
;;; org-doc-noter.el ends here.
