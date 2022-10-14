;;; river-mode.el --- Emacs mode for River configuration language

;; TODO: add license.

;; Author: Jack Baldry <jack.baldry@grafana.com>
;; Version: 1.0
;; Package-Requires:
;; Keywords: river, grafana, agent, flow
;; URL: https://github.com/jdbaldry/river-mode

;;; Commentary:

;;; Code:
(defvar river-mode-hook nil "Hook executed when river-mode is run.")

;; TODO: consider using `make-sparse-keymap` instead.
(defvar river-mode-map (make-keymap) "Keymap for River major mode.")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rvr\\'" . river-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.river\\'" . river-mode))

(defconst river-identifier-regexp "[A-Za-z_][0-9A-Za-z_]*")

(defconst river-block-header-regexp (concat "^\\(\\(" river-identifier-regexp "\\)\\(\\.\\(" river-identifier-regexp "\\)\\)*\\) "))

(defconst river-constant (regexp-opt '("true" "false" "null")))
(defconst river-float "NOTDONE")
(defconst river-int "NOTDONE")
;; TODO: This erroneously highlights TODO identifiers.
(defconst river-todo (regexp-opt '("TODO" "FIXME" "XXX" "BUG" "NOTE") "\\<\\(?:"))

;; TODO: introduce levels of font lock
;; https://www.gnu.org/software/emacs/manual/html_node/elisp/Levels-of-Font-Lock.html
(defconst river-font-lock-keywords
  (let (
        )
    (list
     `(,river-block-header-regexp . (1 font-lock-variable-name-face t))
     `(,river-constant . font-lock-constant-face)
     `(,river-todo . (0 font-lock-warning-face t))))
  "Syntax highlighting for 'river-mode'.")

(defvar river-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; From: https://www.emacswiki.org/emacs/ModeTutorial
    ;; > 1) That the character '/' is the start of a two-character comment sequence ('1'),
    ;; > that it may also be the second character of a two-character comment-start sequence ('2'),
    ;; > that it is the end of a two-character comment-start sequence ('4'),
    ;; > and that comment sequences that have this character as the second character in the sequence
    ;; > is a “b-style” comment ('b').
    ;; > It’s a rule that comments that begin with a “b-style” sequence must end with either the same
    ;; > or some other “b-style” sequence.
    ;; > 2) That the character '*' is the second character of a two-character comment-start sequence ('2')
    ;; > and that it is the start of a two-character comment-end sequence ('3').
    ;; > 3) That the character '\n' (which is the newline character) ends a “b-style” comment.
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?* ". 23" st)
    (modify-syntax-entry ?\n "> b" st)
    st)
  "Syntax table for 'river-mode'.")

(define-derived-mode river-mode prog-mode "River"
  "Major mode for editing River configuration language files." ()
  (kill-all-local-variables)
  (set-syntax-table river-mode-syntax-table)
  (use-local-map river-mode-map)
  (set (make-local-variable 'font-lock-defaults) '(river-font-lock-keywords))
  (setq major-mode 'river-mode)
  (setq mode-name "River")
  (setq indent-tabs-mode t)
  (run-hooks 'river-mode-hook))

;; Taken from https://github.com/dominikh/go-mode.el/blob/08aa90d52f0e7d2ad02f961b554e13329672d7cb/go-mode.el#L1852-L1894
;; Adjusted to avoid relying on cl-libs or other go-mode internal functions.
(defun river--apply-rcs-patch (patch-buffer)
  "Apply an RCS-formatted diff from PATCH-BUFFER to the current buffer."
  (let ((target-buffer (current-buffer))
        ;; Relative offset between buffer line numbers and line numbers
        ;; in patch.
        ;;
        ;; Line numbers in the patch are based on the source file, so
        ;; we have to keep an offset when making changes to the
        ;; buffer.
        ;;
        ;; Appending lines decrements the offset (possibly making it
        ;; negative), deleting lines increments it. This order
        ;; simplifies the forward-line invocations.
        (line-offset 0)
        (column (current-column)))
    (save-excursion
      (with-current-buffer patch-buffer
        (goto-char (point-min))
        (while (not (eobp))
          (unless (looking-at "^\\([ad]\\)\\([0-9]+\\) \\([0-9]+\\)")
            (error "Invalid rcs patch or internal error in go--apply-rcs-patch"))
          (forward-line)
          (let ((action (match-string 1))
                (from (string-to-number (match-string 2)))
                (len  (string-to-number (match-string 3))))
            (cond
             ((equal action "a")
              (let ((start (point)))
                (forward-line len)
                (let ((text (buffer-substring start (point))))
                  (with-current-buffer target-buffer
                    (setq line-offset (- line-offset len))
                    (goto-char (point-min))
                    (forward-line (- from len line-offset))
                    (insert text)))))
             ((equal action "d")
              (with-current-buffer target-buffer
                (goto-char (point-min))
                (forward-line (1- (- from line-offset)))
                (setq line-offset (+ line-offset len))
                (dotimes (_ len)
                  (delete-region (point) (save-excursion (move-end-of-line 1) (point)))
                  (delete-char 1))))
             (t
              (error "Invalid rcs patch or internal error in go--apply-rcs-patch")))))))
    (move-to-column column)))

(defun river-format()
  "Format buffer with 'flow agent fmt'.
Formatting requires the 'agent' binary in the PATH."
  (interactive)
  (let ((tmpfile (make-nearby-temp-file
                  "agent-fmt"
                  nil
                  (or (concat "." (file-name-extension (buffer-file-name))) ".rvr")))
        (patchbuf (get-buffer-create "*agent fmt patch*"))
        (errbuf (get-buffer-create "*agent fmt errors*"))
        (coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (unwind-protect
        (save-restriction
          (widen)
          (with-current-buffer errbuf (setq buffer-read-only nil) (erase-buffer))

          (write-region nil nil tmpfile)

          (message "Calling 'agent fmt'")
          (if (zerop (with-environment-variables
                         (("EXPERIMENTAL_ENABLE_FLOW" "true"))
                       (apply #'process-file "agent" nil errbuf nil `("fmt" "-w" ,(file-local-name tmpfile)))))
              (progn
                (if (zerop (let ((local-copy (file-local-copy tmpfile)))
                             (unwind-protect
                                 (call-process-region (point-min) (point-max) "diff" nil patchbuf nil "-n" "-" (or (or local-copy tmpfile)))
                               (when local-copy (delete-file local-copy)))))
                    (message "Buffer is already formatted")
                  (river--apply-rcs-patch patchbuf)
                  (message "Applied 'agent fmt'"))
                (kill-buffer errbuf))
            (message "Could not apply 'agent fmt'")
            (let ((filename (buffer-file-name)))
              (with-current-buffer errbuf
                (goto-char (point-min))
                (insert "'agent fmt' errors:\n")
                (while (search-forward-regexp
                        (concat "^\\(" (regexp-quote (file-local-name tmpfile))
                                "\\):")
                        nil t)
                  (replace-match (file-name-nondirectory filename) t t nil 1))
                (compilation-mode)
                (display-buffer errbuf)))))
      (kill-buffer patchbuf)
      (delete-file tmpfile))))


(defun river-format-before-save ()
  "Add this to .emacs to run formatting on the current buffer when saving:
\(add-hook 'before-save-hook 'river-format-before-save)."
  (interactive)
  (when (eq major-mode 'river-mode) (river-format)))

(provide 'river-mode)
;;; river-mode.el ends here