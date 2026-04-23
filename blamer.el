;;; blamer.el --- Chunked git-blame overlays with popup details -*- lexical-binding: t; -*-

;; Copyright (C) 2026 fvi-att

;; Author: fvi-att
;; Maintainer: fvi-att
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, vc, git
;; URL: https://github.com/fvi-att/blamer-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; blamer.el displays `git blame' information inline between the
;; display-line-numbers gutter and the source text.  Consecutive lines
;; sharing the same commit are grouped into a chunk; only the first line
;; of each chunk shows the blame prefix, the rest receive a blank
;; spacer of the same width so the source code stays aligned.
;;
;; The inline prefix is intentionally small (just date + commit summary)
;; and a per-commit background color identifies chunk boundaries at a
;; glance.  When point enters a blamed line, a child-frame popup (or
;; echo area on TTY) shows the full commit detail: author, full
;; timestamp, 12-char hash and summary.
;;
;; Usage:
;;
;;   (require 'blamer)
;;   (global-blamer-mode 1)   ; auto-enable in file buffers inside a git tree
;;
;;   M-x blamer-mode          ; toggle in a single buffer
;;
;; See README.md for installation recipes, customization and screenshots.

;;; Code:

(require 'subr-x)
(require 'color)

(defgroup blamer nil
  "Show git blame info grouped by chunk."
  :group 'tools
  :prefix "blamer-")

(defcustom blamer-author-max-length 5
  "Maximum display width of the author column."
  :type 'integer
  :group 'blamer)

(defcustom blamer-comment-max-length 10
  "Maximum display width of the commit summary column."
  :type 'integer
  :group 'blamer)

(defcustom blamer-hash-length 6
  "Number of characters of the commit hash to show."
  :type 'integer
  :group 'blamer)

(defcustom blamer-date-format "%y-%m-%d"
  "`format-time-string' spec used for the blame date column."
  :type 'string
  :group 'blamer)

(defcustom blamer-uncommitted-label "Uncommitted"
  "Author label used for lines not yet committed."
  :type 'string
  :group 'blamer)

(defcustom blamer-uncommitted-summary "(not yet committed)"
  "Summary shown for lines not yet committed."
  :type 'string
  :group 'blamer)

(defcustom blamer-separator " │ "
  "String used to separate the blame prefix from the source line."
  :type 'string
  :group 'blamer)

(defcustom blamer-idle-delay 0.3
  "Idle seconds before refreshing blame after a save."
  :type 'number
  :group 'blamer)

(defcustom blamer-popup-delay 0.5
  "Idle seconds after point settles before showing the commit popup."
  :type 'number
  :group 'blamer)

(defcustom blamer-popup-enabled t
  "Non-nil to show a detail popup when point is on a blamed line."
  :type 'boolean
  :group 'blamer)

(defcustom blamer-popup-detail-date-format "%Y-%m-%d %H:%M"
  "Date format used inside the detail popup."
  :type 'string
  :group 'blamer)

(defcustom blamer-popup-max-width 70
  "Maximum inner width of the commit detail popup in columns."
  :type 'integer
  :group 'blamer)

(defcustom blamer-background-saturation 0.32
  "Saturation (0.0-1.0) of per-commit background colors."
  :type 'number
  :group 'blamer)

(defcustom blamer-background-lightness 0.22
  "Lightness (0.0-1.0) of per-commit background colors.
Use a small value for dark themes and a larger one (around 0.85) for
light themes."
  :type 'number
  :group 'blamer)

(defface blamer-face
  '((t :inherit shadow :height 0.6))
  "Base face used by all blamer columns."
  :group 'blamer)

(defface blamer-author-face
  '((t :inherit blamer-face :weight bold))
  "Face used for the author column."
  :group 'blamer)

(defface blamer-date-face
  '((t :inherit blamer-face))
  "Face used for the commit date column."
  :group 'blamer)

(defface blamer-comment-face
  '((t :inherit blamer-face :slant italic))
  "Face used for the commit summary column."
  :group 'blamer)

(defface blamer-hash-face
  '((t :inherit blamer-face))
  "Face used for the commit hash column."
  :group 'blamer)

(defface blamer-separator-face
  '((t :inherit blamer-face))
  "Face used for the column separator."
  :group 'blamer)

(defvar blamer-mode)

(defvar-local blamer--overlays nil
  "List of overlays created by `blamer-mode' in the current buffer.")

(defvar-local blamer--refresh-timer nil
  "Pending idle timer for `blamer--refresh'.")

(defconst blamer--zero-hash (make-string 40 ?0)
  "Pseudo hash git uses for uncommitted lines.")

(defun blamer--commit-background (hash)
  "Return a stable hex color for HASH, or nil for uncommitted lines."
  (unless (equal hash blamer--zero-hash)
    (let* ((seed (string-to-number (substring hash 0 6) 16))
           (hue (/ (float (mod seed 360)) 360.0))
           (rgb (color-hsl-to-rgb hue
                                  blamer-background-saturation
                                  blamer-background-lightness)))
      (apply #'color-rgb-to-hex (append rgb '(2))))))

(defun blamer--inside-worktree-p ()
  "Return non-nil when the current buffer's file is inside a git worktree."
  (and buffer-file-name
       (file-exists-p buffer-file-name)
       (let ((default-directory (file-name-directory
                                 (file-truename buffer-file-name))))
         (eq 0 (call-process "git" nil nil nil
                             "rev-parse" "--is-inside-work-tree")))))

(defun blamer--truncate (str width)
  "Truncate STR to WIDTH display columns, adding an ellipsis when cut."
  (let ((str (or str "")))
    (if (<= (string-width str) width)
        str
      (truncate-string-to-width str width 0 nil "…"))))

(defun blamer--pad (str width)
  "Pad STR with trailing spaces to WIDTH display columns."
  (let ((w (string-width str)))
    (if (>= w width)
        str
      (concat str (make-string (- width w) ?\s)))))

(defun blamer--date-width ()
  "Return the fixed display width of a formatted blame date."
  (string-width (format-time-string blamer-date-format 0)))

(defun blamer--prefix-width ()
  "Return the total display width of a rendered blame prefix."
  (+ (blamer--date-width) 1
     blamer-comment-max-length
     (string-width blamer-separator)))

(defun blamer--format (commit)
  "Render COMMIT plist as a compact inline prefix: DATE + SUMMARY."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (equal hash blamer--zero-hash))
         (time (plist-get commit :author-time))
         (summary (if uncommitted
                      blamer-uncommitted-summary
                    (or (plist-get commit :summary) "")))
         (date-str (if (and time (not uncommitted))
                       (format-time-string blamer-date-format time)
                     (make-string (blamer--date-width) ?\s)))
         (comment-str (blamer--pad
                       (blamer--truncate summary blamer-comment-max-length)
                       blamer-comment-max-length)))
    (concat
     (propertize date-str 'face 'blamer-date-face)
     " "
     (propertize comment-str 'face 'blamer-comment-face)
     (propertize blamer-separator 'face 'blamer-separator-face))))

(defun blamer--format-detail (commit)
  "Return a multi-line human-readable COMMIT summary for the popup."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (equal hash blamer--zero-hash))
         (author (if uncommitted
                     blamer-uncommitted-label
                   (or (plist-get commit :author) "?")))
         (time (plist-get commit :author-time))
         (summary (if uncommitted
                      blamer-uncommitted-summary
                    (or (plist-get commit :summary) "")))
         (date-str (if (and time (not uncommitted))
                       (format-time-string blamer-popup-detail-date-format time)
                     "-"))
         (short (substring hash 0 (min 12 (length hash)))))
    (concat
     (propertize "Author: " 'face 'bold) author "\n"
     (propertize "Date:   " 'face 'bold) date-str "\n"
     (propertize "Commit: " 'face 'bold) short "\n"
     (propertize (make-string (min blamer-popup-max-width 40) ?─)
                 'face 'shadow) "\n"
     summary)))

(defun blamer--empty-prefix ()
  "Return a blank spacer with the same display width as a blame prefix."
  (propertize (make-string (blamer--prefix-width) ?\s)
              'face 'blamer-face))

(defun blamer--parse-porcelain ()
  "Parse `git blame --porcelain' output in the current temp buffer.
Return a list of (LINENO . COMMIT-PLIST) pairs sorted by LINENO."
  (goto-char (point-min))
  (let ((commits (make-hash-table :test 'equal))
        (entries nil))
    (while (not (eobp))
      (unless (looking-at
               "^\\([0-9a-f]\\{40\\}\\) [0-9]+ \\([0-9]+\\)\\(?: [0-9]+\\)?$")
        (error "blamer: unexpected porcelain line: %s"
               (buffer-substring-no-properties
                (point) (line-end-position))))
      (let* ((hash (match-string 1))
             (result-line (string-to-number (match-string 2)))
             (commit (or (gethash hash commits) (list :hash hash))))
        (forward-line 1)
        (while (and (not (eobp))
                    (not (looking-at "^\t")))
          (cond
           ((looking-at "^author \\(.*\\)$")
            (setq commit (plist-put commit :author (match-string 1))))
           ((looking-at "^author-time \\([0-9]+\\)$")
            (setq commit (plist-put commit :author-time
                                    (string-to-number (match-string 1)))))
           ((looking-at "^summary \\(.*\\)$")
            (setq commit (plist-put commit :summary (match-string 1)))))
          (forward-line 1))
        (puthash hash commit commits)
        (push (cons result-line commit) entries)
        ;; Move past the \t source content line.
        (forward-line 1)))
    (nreverse entries)))

(defun blamer--clear ()
  "Remove all blamer overlays from the current buffer.
Scan the whole buffer so stale overlays left behind by reloads or
duplicate mode activations are also removed."
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'blamer)
        (delete-overlay ov))))
  (setq blamer--overlays nil))

(defun blamer--add-overlay (lineno string commit)
  "Attach STRING as a `before-string' overlay at line LINENO.
COMMIT is stored on the overlay so the detail popup can look it up,
and also attached to STRING as `help-echo' text for mouse tooltips."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- lineno))
    (let ((ov (make-overlay (line-beginning-position)
                            (line-beginning-position)
                            nil t nil))
          (detail (blamer--format-detail commit)))
      (put-text-property 0 (length string) 'help-echo detail string)
      (overlay-put ov 'before-string string)
      (overlay-put ov 'blamer t)
      (overlay-put ov 'blamer-commit commit)
      (overlay-put ov 'help-echo detail)
      (push ov blamer--overlays))))

(defun blamer--render (entries)
  "Create overlays for ENTRIES, a list of (LINENO . COMMIT-PLIST)."
  (let ((prev-hash nil))
    (dolist (entry entries)
      (let* ((lineno (car entry))
             (commit (cdr entry))
             (hash (plist-get commit :hash))
             (bg (blamer--commit-background hash))
             (text (if (equal hash prev-hash)
                       (blamer--empty-prefix)
                     (blamer--format commit))))
        (when bg
          (add-face-text-property 0 (length text)
                                  `(:background ,bg)
                                  nil text))
        (blamer--add-overlay lineno text commit)
        (setq prev-hash hash)))))

(defun blamer--run-blame (file)
  "Run `git blame --porcelain' on FILE and return parsed entries or nil."
  (let ((default-directory (file-name-directory (file-truename file))))
    (with-temp-buffer
      (let ((status (call-process "git" nil (list (current-buffer) nil) nil
                                  "--no-pager" "blame" "--porcelain" "--"
                                  (file-name-nondirectory file))))
        (when (eq status 0)
          (condition-case err
              (blamer--parse-porcelain)
            (error
             (message "blamer: parse failed: %s" (error-message-string err))
             nil)))))))

(defun blamer--refresh ()
  "Refresh blame overlays in the current buffer."
  (blamer--clear)
  (when (and buffer-file-name
             (file-exists-p buffer-file-name)
             (blamer--inside-worktree-p))
    (when-let ((entries (blamer--run-blame buffer-file-name)))
      (blamer--render entries))))

(defun blamer--schedule-refresh (&rest _)
  "Schedule a blame refresh after `blamer-idle-delay' seconds."
  (when (timerp blamer--refresh-timer)
    (cancel-timer blamer--refresh-timer))
  (let ((buffer (current-buffer)))
    (setq blamer--refresh-timer
          (run-with-idle-timer
           blamer-idle-delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when blamer-mode
                   (blamer--refresh)))))))))


;;; Detail popup --------------------------------------------------------------

(defvar blamer--popup-frame nil
  "Child frame reused to render the commit detail popup.")

(defvar blamer--popup-buffer-name " *blamer-popup*"
  "Buffer rendered inside the popup frame.")

(defvar blamer--popup-timer nil
  "Idle timer that brings up the popup after point settles.")

(defvar blamer--popup-visible-commit nil
  "Commit plist currently shown in the popup, or nil when hidden.")

(defun blamer--commit-at-point ()
  "Return the commit plist attached to any blamer overlay on the current line."
  (let ((bol (line-beginning-position)))
    (seq-some (lambda (o) (overlay-get o 'blamer-commit))
              (overlays-in bol (1+ bol)))))

(defun blamer--popup-hide ()
  "Hide the detail popup, if any."
  (when (and blamer--popup-frame (frame-live-p blamer--popup-frame)
             (frame-visible-p blamer--popup-frame))
    (make-frame-invisible blamer--popup-frame))
  (setq blamer--popup-visible-commit nil))

(defun blamer--popup-ensure-frame (parent)
  "Create the popup child frame parented under PARENT if missing."
  (unless (and blamer--popup-frame (frame-live-p blamer--popup-frame))
    (let ((buf (get-buffer-create blamer--popup-buffer-name))
          (bg (or (face-attribute 'tooltip :background nil t)
                  (face-attribute 'default :background nil t)))
          (fg (or (face-attribute 'tooltip :foreground nil t)
                  (face-attribute 'default :foreground nil t))))
      (with-current-buffer buf
        (setq-local mode-line-format nil)
        (setq-local header-line-format nil)
        (setq-local cursor-type nil)
        (setq-local show-trailing-whitespace nil)
        (setq-local display-line-numbers nil)
        (setq-local truncate-lines nil))
      (setq blamer--popup-frame
            (make-frame
             `((parent-frame . ,parent)
               (no-focus-on-map . t)
               (no-accept-focus . t)
               (minibuffer . nil)
               (min-width . 20) (min-height . 4)
               (width . ,blamer-popup-max-width) (height . 7)
               (left-fringe . 6) (right-fringe . 6)
               (internal-border-width . 2)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (tool-bar-lines . 0)
               (menu-bar-lines . 0)
               (tab-bar-lines . 0)
               (line-spacing . 0)
               (visibility . nil)
               (undecorated . t)
               (unsplittable . t)
               (no-other-frame . t)
               (desktop-dont-save . t)
               (background-color . ,bg)
               (foreground-color . ,fg))))
      (let ((win (frame-selected-window blamer--popup-frame)))
        (set-window-buffer win buf)
        (set-window-dedicated-p win t)
        (set-window-parameter win 'mode-line-format 'none))))
  blamer--popup-frame)

(defun blamer--popup-show (commit)
  "Display the detail for COMMIT next to point."
  (if (not (display-graphic-p))
      (let ((message-log-max nil))
        (message "%s" (blamer--format-detail commit)))
    (let* ((parent (window-frame))
           (frame (blamer--popup-ensure-frame parent))
           (detail (blamer--format-detail commit)))
      (with-current-buffer (get-buffer-create blamer--popup-buffer-name)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert detail)
          (goto-char (point-min))))
      (let* ((posn (posn-at-point))
             (xy (and posn (posn-x-y posn)))
             (edges (window-inside-pixel-edges))
             (line-h (default-line-height))
             (x (and xy (+ (nth 0 edges) (or (car xy) 0))))
             (y (and xy (+ (nth 1 edges) (or (cdr xy) 0) line-h))))
        (when (and x y)
          (set-frame-position frame (max 0 x) (max 0 y))))
      (unless (frame-visible-p frame)
        (make-frame-visible frame))
      (setq blamer--popup-visible-commit commit))))

(defun blamer--popup-update ()
  "Show or update the popup for the commit at point."
  (when (and blamer-popup-enabled (bound-and-true-p blamer-mode))
    (let ((commit (blamer--commit-at-point)))
      (cond
       ((null commit) (blamer--popup-hide))
       ((eq commit blamer--popup-visible-commit) nil)
       (t (blamer--popup-show commit))))))

(defun blamer--post-command ()
  "Trigger or hide the blame popup based on the current point context."
  (when (timerp blamer--popup-timer)
    (cancel-timer blamer--popup-timer)
    (setq blamer--popup-timer nil))
  (cond
   ((and blamer-popup-enabled
         (bound-and-true-p blamer-mode)
         (blamer--commit-at-point))
    (setq blamer--popup-timer
          (run-with-idle-timer blamer-popup-delay nil
                               #'blamer--popup-update)))
   (t (blamer--popup-hide))))

(defvar blamer--post-command-installed nil
  "Non-nil once `blamer--post-command' has been added to the global hook.")

(defun blamer--install-post-command ()
  "Install the global post-command hook lazily."
  (unless blamer--post-command-installed
    (add-hook 'post-command-hook #'blamer--post-command)
    (setq blamer--post-command-installed t)))

;;;###autoload
(define-minor-mode blamer-mode
  "Show git blame information for the current file grouped by chunks."
  :lighter " Blame"
  :group 'blamer
  (cond
   (blamer-mode
    (add-hook 'after-save-hook #'blamer--schedule-refresh nil t)
    (add-hook 'after-revert-hook #'blamer--schedule-refresh nil t)
    (blamer--install-post-command)
    (blamer--refresh))
   (t
    (remove-hook 'after-save-hook #'blamer--schedule-refresh t)
    (remove-hook 'after-revert-hook #'blamer--schedule-refresh t)
    (when (timerp blamer--refresh-timer)
      (cancel-timer blamer--refresh-timer)
      (setq blamer--refresh-timer nil))
    (blamer--popup-hide)
    (blamer--clear))))

;;;###autoload
(defun blamer-show-commit-at-point ()
  "Show the commit detail popup for the blame chunk at point."
  (interactive)
  (let ((commit (blamer--commit-at-point)))
    (if commit
        (blamer--popup-show commit)
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamer-copy-commit-hash-at-point ()
  "Copy the full commit hash of the blame chunk at point to the kill ring."
  (interactive)
  (let ((commit (blamer--commit-at-point)))
    (if commit
        (let ((hash (plist-get commit :hash)))
          (kill-new hash)
          (message "Copied %s" hash))
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamer-refresh ()
  "Recompute git blame overlays for the current buffer."
  (interactive)
  (if blamer-mode
      (blamer--refresh)
    (user-error "blamer-mode is not enabled in this buffer")))

(defun blamer--maybe-enable ()
  "Turn on `blamer-mode' when the buffer visits a file inside a git worktree."
  (when (and buffer-file-name
             (not (minibufferp))
             (blamer--inside-worktree-p))
    (blamer-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-blamer-mode
  blamer-mode blamer--maybe-enable
  :group 'blamer)

(provide 'blamer)

;;; blamer.el ends here
