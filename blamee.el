;;; blamee.el --- Chunked git-blame overlays with popup details -*- lexical-binding: t; -*-

;; Copyright (C) 2026 fvi-att

;; Author: fvi-att <jshimizujp@gmail.com>
;; Maintainer: fvi-att <jshimizujp@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, vc, git
;; URL: https://github.com/fvi-att/blamee
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
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
;; blamee.el displays `git blame' information inline between the
;; display-line-numbers gutter and the source text.  Consecutive lines
;; sharing the same commit are grouped into a chunk; only the first line
;; of each chunk shows the blame prefix, the rest receive a blank
;; spacer of the same width so the source code stays aligned.
;;
;; The inline prefix defaults to a small date + author layout,
;; but its visible columns can be customized.  A per-commit background
;; color identifies chunk boundaries at a glance.  When point enters a
;; blamed line, a child-frame popup (or echo area on TTY) shows the
;; full commit detail: author, full timestamp, 12-char hash and
;; summary.
;;
;; Usage:
;;
;;   (require 'blamee)
;;   (global-blamee-mode 1)   ; auto-enable in file buffers inside a git tree
;;
;;   M-x blamee-mode          ; toggle in a single buffer
;;
;; See README.md for installation recipes, customization and screenshots.

;;; Code:

(require 'subr-x)
(require 'color)

(defun blamee--refresh-active-buffers ()
  "Refresh all live buffers with `blamee-mode' enabled."
  (when (fboundp 'blamee--refresh)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (bound-and-true-p blamee-mode)
          (blamee--refresh))))))

(defun blamee--set-and-refresh (symbol value)
  "Set SYMBOL to VALUE, then refresh active blamee buffers."
  (set-default symbol value)
  (blamee--refresh-active-buffers))

(defgroup blamee nil
  "Show git blame info grouped by chunk."
  :group 'tools
  :prefix "blamee-")

(defcustom blamee-hash-length 6
  "Maximum number of characters of the inline commit hash to show."
  :type 'integer
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-date-format "%y-%m-%d"
  "`format-time-string' spec used for the blame date column."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-inline-columns '(date author)
  "Ordered list of columns shown in the inline blame prefix.
Supported column symbols are `author', `date', `summary' and `hash'."
  :type '(repeat
          (choice (const :tag "Author" author)
                  (const :tag "Date" date)
                  (const :tag "Summary" summary)
                  (const :tag "Hash" hash)))
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-uncommitted-label "Uncommitted"
  "Author label used for lines not yet committed."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-uncommitted-summary "(not yet committed)"
  "Summary shown for lines not yet committed."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-separator " │"
  "String used to separate the blame prefix from the source line."
  :type 'string
  :set #'blamee--set-and-refresh
  :group 'blamee)

(defcustom blamee-idle-delay 0.3
  "Idle seconds before refreshing blame after a save."
  :type 'number
  :group 'blamee)

(defcustom blamee-popup-delay 0.5
  "Idle seconds after point settles before showing the commit popup."
  :type 'number
  :group 'blamee)

(defcustom blamee-popup-enabled t
  "Non-nil to show a detail popup when point is on a blamed line."
  :type 'boolean
  :group 'blamee)

(defcustom blamee-popup-detail-date-format "%Y-%m-%d %H:%M"
  "Date format used inside the detail popup."
  :type 'string
  :group 'blamee)

(defcustom blamee-popup-max-width 70
  "Maximum inner width of the commit detail popup in columns."
  :type 'integer
  :group 'blamee)

(defcustom blamee-background-saturation 0.32
  "Saturation (0.0-1.0) of per-commit background colors."
  :type 'number
  :group 'blamee)

(defcustom blamee-background-lightness 0.22
  "Lightness (0.0-1.0) of per-commit background colors.
Use a small value for dark themes and a larger one (around 0.85) for
light themes."
  :type 'number
  :group 'blamee)

(defface blamee-face
  '((t :inherit shadow :height 0.6))
  "Base face used by all blamee columns."
  :group 'blamee)

(defface blamee-author-face
  '((t :inherit blamee-face :weight bold))
  "Face used for the author column."
  :group 'blamee)

(defface blamee-date-face
  '((t :inherit blamee-face))
  "Face used for the commit date column."
  :group 'blamee)

(defface blamee-comment-face
  '((t :inherit blamee-face :slant italic))
  "Face used for the commit summary column."
  :group 'blamee)

(defface blamee-hash-face
  '((t :inherit blamee-face))
  "Face used for the commit hash column."
  :group 'blamee)

(defface blamee-separator-face
  '((t :inherit blamee-face))
  "Face used for the column separator."
  :group 'blamee)

(defvar blamee-mode)

(defvar-local blamee--overlays nil
  "List of overlays created by `blamee-mode' in the current buffer.")

(defvar-local blamee--refresh-timer nil
  "Pending idle timer for `blamee--refresh'.")

(defvar-local blamee--layout-cache nil
  "Cached visible-layout signature for the current buffer.")

(defvar-local blamee--saved-buffer-read-only nil
  "Value of `buffer-read-only' before enabling `blamee-mode'.")

(defvar-local blamee--read-only-workaround-active nil
  "Non-nil when `blamee-mode' has made the buffer read-only.")

(put 'blamee--saved-buffer-read-only 'permanent-local t)
(put 'blamee--read-only-workaround-active 'permanent-local t)

(defconst blamee--zero-hash (make-string 40 ?0)
  "Pseudo hash git uses for uncommitted lines.")

(defun blamee--uncommitted-p (commit)
  "Return non-nil when COMMIT represents an uncommitted line."
  (equal (plist-get commit :hash) blamee--zero-hash))

(defun blamee--commit-background (hash)
  "Return a stable hex color for HASH, or nil for uncommitted lines."
  (unless (equal hash blamee--zero-hash)
    (let* ((seed (string-to-number (substring hash 0 6) 16))
           (hue (/ (float (mod seed 360)) 360.0))
           (rgb (color-hsl-to-rgb hue
                                  blamee-background-saturation
                                  blamee-background-lightness)))
      (apply #'color-rgb-to-hex (append rgb '(2))))))

(defun blamee--inside-worktree-p ()
  "Return non-nil when the current buffer's file is inside a git worktree."
  (and buffer-file-name
       (file-exists-p buffer-file-name)
       (let ((default-directory (file-name-directory
                                 (file-truename buffer-file-name))))
         (eq 0 (call-process "git" nil nil nil
                             "rev-parse" "--is-inside-work-tree")))))

(defun blamee--pad (str width)
  "Pad STR with trailing spaces to WIDTH display columns."
  (let ((w (string-width str)))
    (if (>= w width)
        str
      (concat str (make-string (- width w) ?\s)))))

(defun blamee--date-width ()
  "Return the fixed display width of a formatted blame date."
  (string-width (format-time-string blamee-date-format 0)))

(defun blamee--format-inline-column (column commit)
  "Render inline COLUMN for COMMIT at full natural width."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (blamee--uncommitted-p commit))
         (time (plist-get commit :author-time)))
    (pcase column
      ('author
       (propertize
        (if uncommitted
            blamee-uncommitted-label
          (or (plist-get commit :author) ""))
        'face 'blamee-author-face))
      ('date
       (if (and time (not uncommitted))
           (propertize
            (format-time-string blamee-date-format time)
            'face 'blamee-date-face)
         ""))
      ('summary
       (propertize
        (if uncommitted
            blamee-uncommitted-summary
          (or (plist-get commit :summary) ""))
        'face 'blamee-comment-face))
      ('hash
       (if uncommitted
           ""
         (propertize
          (substring hash 0 (min blamee-hash-length (length hash)))
          'face 'blamee-hash-face)))
      (_ ""))))

(defun blamee--inline-columns (commit)
  "Return the configured inline columns for COMMIT."
  (mapcar (lambda (column)
            (cons column (blamee--format-inline-column column commit)))
          blamee-inline-columns))

(defun blamee--inline-widths (columns)
  "Return the actual display widths for rendered COLUMNS alist."
  (mapcar (lambda (column)
            (cons column (string-width (or (alist-get column columns) ""))))
          blamee-inline-columns))

(defun blamee--column-widths-for (overlays)
  "Return max display widths per configured column across OVERLAYS."
  (let ((widths (mapcar (lambda (column) (cons column 0))
                        blamee-inline-columns)))
    (dolist (ov overlays widths)
      (dolist (entry (overlay-get ov 'blamee-column-widths))
        (let ((col (car entry)))
          (when (assq col widths)
            (setf (alist-get col widths 0 nil #'eq)
                  (max (cdr entry)
                       (alist-get col widths 0 nil #'eq)))))))))

(defun blamee--format-prefix (columns widths &optional blank)
  "Render inline prefix from COLUMNS aligned to WIDTHS.
When BLANK is non-nil, render only spacing with the same total width.
The literal separator string is rendered on every line so prefix and
spacer rows have identical pixel width regardless of font fallbacks
for the separator's glyph."
  (let ((parts nil))
    (dolist (column blamee-inline-columns)
      (let ((target-width (alist-get column widths 0 nil #'eq)))
        (when (> target-width 0)
          (push (if blank
                    (make-string target-width ?\s)
                  (blamee--pad (or (alist-get column columns) "")
                               target-width))
                parts))))
    (setq parts (nreverse parts))
    (if parts
        (concat (string-join parts " ")
                (propertize blamee-separator
                            'face 'blamee-separator-face)
                " ")
      "")))

(defun blamee--format-detail (commit)
  "Return a multi-line human-readable COMMIT summary for the popup."
  (let* ((hash (plist-get commit :hash))
         (uncommitted (blamee--uncommitted-p commit))
         (author (if uncommitted
                     blamee-uncommitted-label
                   (or (plist-get commit :author) "?")))
         (time (plist-get commit :author-time))
         (summary (if uncommitted
                      blamee-uncommitted-summary
                    (or (plist-get commit :summary) "")))
         (date-str (if (and time (not uncommitted))
                       (format-time-string blamee-popup-detail-date-format time)
                     "-"))
         (short (substring hash 0 (min 12 (length hash)))))
    (concat
     (propertize "Author: " 'face 'bold) author "\n"
     (propertize "Date:   " 'face 'bold) date-str "\n"
     (propertize "Commit: " 'face 'bold) short "\n"
     (propertize (make-string (min blamee-popup-max-width 40) ?─)
                 'face 'shadow) "\n"
     summary)))

(defun blamee--visible-overlays (window)
  "Return blamee overlays visible in WINDOW."
  (seq-filter
   (lambda (ov) (overlay-get ov 'blamee))
   (overlays-in (window-start window)
                (or (window-end window t)
                    (point-max)))))

(defun blamee--set-overlay-string (overlay widths)
  "Apply aligned before-string to OVERLAY using visible WIDTHS."
  (let* ((columns (overlay-get overlay 'blamee-columns))
         (detail (overlay-get overlay 'help-echo))
         (bg (overlay-get overlay 'blamee-background))
         (string (blamee--format-prefix
                  columns widths
                  (not (overlay-get overlay 'blamee-show-prefix)))))
    (when (> (length string) 0)
      (let ((face-end (max 0 (1- (length string)))))
        (add-face-text-property 0 face-end 'blamee-face t string)
        (put-text-property 0 (length string) 'help-echo detail string)
        (when bg
          (add-face-text-property 0 face-end
                                  `(:background ,bg)
                                  nil string))))
    (overlay-put overlay 'before-string string)))

(defun blamee--update-visible-layout (&optional window)
  "Align visible blamee prefixes for WINDOW.
When WINDOW is nil, use the selected window if it shows the current buffer."
  (let ((window (or window
                    (and (eq (window-buffer (selected-window))
                             (current-buffer))
                         (selected-window)))))
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (let* ((overlays (blamee--visible-overlays window))
             (widths (blamee--column-widths-for overlays))
             (signature (list window blamee-inline-columns widths)))
        (unless (equal signature blamee--layout-cache)
          (dolist (overlay overlays)
            (blamee--set-overlay-string overlay widths))
          (setq blamee--layout-cache signature))))))

(defun blamee--parse-porcelain ()
  "Parse `git blame --porcelain' output in the current temp buffer.
Return a list of (LINENO . COMMIT-PLIST) pairs sorted by LINENO."
  (goto-char (point-min))
  (let ((commits (make-hash-table :test 'equal))
        (entries nil))
    (while (not (eobp))
      (unless (looking-at
               "^\\([0-9a-f]\\{40\\}\\) [0-9]+ \\([0-9]+\\)\\(?: [0-9]+\\)?$")
        (error "Blamee: unexpected porcelain line: %s"
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

(defun blamee--clear ()
  "Remove all blamee overlays from the current buffer.
Scan the whole buffer so stale overlays left behind by reloads or
duplicate mode activations are also removed."
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'blamee)
        (delete-overlay ov))))
  (setq blamee--overlays nil
        blamee--layout-cache nil))

(defun blamee--add-overlay (lineno commit show-prefix columns)
  "Attach a blamee overlay at line LINENO for COMMIT.
SHOW-PREFIX is non-nil when this line starts a visible blame chunk.
COLUMNS is the rendered inline column alist for COMMIT."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- lineno))
    (let ((ov (make-overlay (line-beginning-position)
                            (line-beginning-position)
                            nil t nil))
          (detail (blamee--format-detail commit))
          (bg (blamee--commit-background (plist-get commit :hash))))
      (overlay-put ov 'before-string "")
      (overlay-put ov 'blamee t)
      (overlay-put ov 'blamee-commit commit)
      (overlay-put ov 'blamee-columns columns)
      (overlay-put ov 'blamee-column-widths (blamee--inline-widths columns))
      (overlay-put ov 'blamee-show-prefix show-prefix)
      (overlay-put ov 'blamee-background bg)
      (overlay-put ov 'help-echo detail)
      (push ov blamee--overlays))))

(defun blamee--render (entries)
  "Create overlays for ENTRIES, a list of (LINENO . COMMIT-PLIST)."
  (let ((prev-hash nil))
    (dolist (entry entries)
      (let* ((lineno (car entry))
             (commit (cdr entry))
             (hash (plist-get commit :hash))
             (columns (blamee--inline-columns commit))
             (show-prefix (not (equal hash prev-hash))))
        (blamee--add-overlay lineno commit show-prefix columns)
        (setq prev-hash hash)))))

(defun blamee--run-blame (file)
  "Run `git blame --porcelain' on FILE and return parsed entries or nil."
  (let ((default-directory (file-name-directory (file-truename file))))
    (with-temp-buffer
      (let ((status (call-process "git" nil (list (current-buffer) nil) nil
                                  "--no-pager" "blame" "--porcelain" "--"
                                  (file-name-nondirectory file))))
        (when (eq status 0)
          (condition-case err
              (blamee--parse-porcelain)
            (error
             (message "blamee: parse failed: %s" (error-message-string err))
             nil)))))))

(defun blamee--refresh ()
  "Refresh blame overlays in the current buffer."
  (blamee--clear)
  (when (and buffer-file-name
             (file-exists-p buffer-file-name)
             (blamee--inside-worktree-p))
    (when-let ((entries (blamee--run-blame buffer-file-name)))
      (blamee--render entries)
      (blamee--update-visible-layout))))

(defun blamee--schedule-refresh (&rest _)
  "Schedule a blame refresh after `blamee-idle-delay' seconds."
  (when (timerp blamee--refresh-timer)
    (cancel-timer blamee--refresh-timer))
  (let ((buffer (current-buffer)))
    (setq blamee--refresh-timer
          (run-with-idle-timer
           blamee-idle-delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when blamee-mode
                   (blamee--refresh)))))))))


;;; Detail popup --------------------------------------------------------------

(defvar blamee--popup-frame nil
  "Child frame reused to render the commit detail popup.")

(defvar blamee--popup-buffer-name " *blamee-popup*"
  "Buffer rendered inside the popup frame.")

(defvar blamee--popup-timer nil
  "Idle timer that brings up the popup after point settles.")

(defvar blamee--popup-visible-commit nil
  "Commit plist currently shown in the popup, or nil when hidden.")

(defun blamee--commit-at-point ()
  "Return the commit plist attached to any blamee overlay on the current line."
  (let ((bol (line-beginning-position)))
    (seq-some (lambda (o) (overlay-get o 'blamee-commit))
              (overlays-in bol (1+ bol)))))

(defun blamee--popup-hide ()
  "Hide the detail popup, if any."
  (when (and blamee--popup-frame (frame-live-p blamee--popup-frame)
             (frame-visible-p blamee--popup-frame))
    (make-frame-invisible blamee--popup-frame))
  (setq blamee--popup-visible-commit nil))

(defun blamee--popup-ensure-frame (parent)
  "Create the popup child frame parented under PARENT if missing."
  (unless (and blamee--popup-frame (frame-live-p blamee--popup-frame))
    (let ((buf (get-buffer-create blamee--popup-buffer-name))
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
      (setq blamee--popup-frame
            (make-frame
             `((parent-frame . ,parent)
               (no-focus-on-map . t)
               (no-accept-focus . t)
               (minibuffer . nil)
               (min-width . 20) (min-height . 4)
               (width . ,blamee-popup-max-width) (height . 7)
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
      (let ((win (frame-selected-window blamee--popup-frame)))
        (set-window-buffer win buf)
        (set-window-dedicated-p win t)
        (set-window-parameter win 'mode-line-format 'none))))
  blamee--popup-frame)

(defun blamee--popup-show (commit)
  "Display the detail for COMMIT next to point."
  (if (not (display-graphic-p))
      (let ((message-log-max nil))
        (message "%s" (blamee--format-detail commit)))
    (let* ((parent (window-frame))
           (frame (blamee--popup-ensure-frame parent))
           (detail (blamee--format-detail commit)))
      (with-current-buffer (get-buffer-create blamee--popup-buffer-name)
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
      (setq blamee--popup-visible-commit commit))))

(defun blamee--popup-update ()
  "Show or update the popup for the commit at point."
  (when (and blamee-popup-enabled (bound-and-true-p blamee-mode))
    (let ((commit (blamee--commit-at-point)))
      (cond
       ((null commit) (blamee--popup-hide))
       ((eq commit blamee--popup-visible-commit) nil)
       (t (blamee--popup-show commit))))))

(defun blamee--post-command ()
  "Trigger or hide the blame popup based on the current point context."
  (when (and (bound-and-true-p blamee-mode)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (blamee--update-visible-layout (selected-window)))
  (when (timerp blamee--popup-timer)
    (cancel-timer blamee--popup-timer)
    (setq blamee--popup-timer nil))
  (cond
   ((and blamee-popup-enabled
         (bound-and-true-p blamee-mode)
         (blamee--commit-at-point))
    (setq blamee--popup-timer
          (run-with-idle-timer blamee-popup-delay nil
                               #'blamee--popup-update)))
   (t (blamee--popup-hide))))

(defvar blamee--post-command-installed nil
  "Non-nil once `blamee--post-command' has been added to the global hook.")

(defvar blamee--window-scroll-installed nil
  "Non-nil once the global window-scroll hook has been installed.")

(defun blamee--install-post-command ()
  "Install the global post-command hook lazily."
  (unless blamee--post-command-installed
    (add-hook 'post-command-hook #'blamee--post-command)
    (setq blamee--post-command-installed t)))

(defun blamee--window-scroll (window _display-start)
  "Re-align visible blamee overlays in WINDOW after scrolling."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (bound-and-true-p blamee-mode)
        (setq blamee--layout-cache nil)
        (blamee--update-visible-layout window)))))

(defun blamee--install-window-scroll ()
  "Install the global window-scroll hook lazily."
  (unless blamee--window-scroll-installed
    (add-hook 'window-scroll-functions #'blamee--window-scroll)
    (setq blamee--window-scroll-installed t)))

(defun blamee--enable-read-only-workaround ()
  "Make the current buffer read-only while `blamee-mode' is active."
  (unless blamee--read-only-workaround-active
    (add-hook 'change-major-mode-hook
              #'blamee--disable-read-only-workaround nil t)
    (setq blamee--saved-buffer-read-only buffer-read-only
          blamee--read-only-workaround-active t
          buffer-read-only t)))

(defun blamee--disable-read-only-workaround ()
  "Restore `buffer-read-only' after `blamee-mode' is disabled."
  (when blamee--read-only-workaround-active
    (remove-hook 'change-major-mode-hook
                 #'blamee--disable-read-only-workaround t)
    (setq buffer-read-only blamee--saved-buffer-read-only
          blamee--saved-buffer-read-only nil
          blamee--read-only-workaround-active nil)))

;;;###autoload
(define-minor-mode blamee-mode
  "Show git blame information for the current file grouped by chunks."
  :lighter " Blame"
  :group 'blamee
  (cond
   (blamee-mode
    (add-hook 'after-save-hook #'blamee--schedule-refresh nil t)
    (add-hook 'after-revert-hook #'blamee--schedule-refresh nil t)
    (blamee--install-post-command)
    (blamee--install-window-scroll)
    (blamee--enable-read-only-workaround)
    (blamee--refresh))
   (t
    (remove-hook 'after-save-hook #'blamee--schedule-refresh t)
    (remove-hook 'after-revert-hook #'blamee--schedule-refresh t)
    (blamee--disable-read-only-workaround)
    (when (timerp blamee--refresh-timer)
      (cancel-timer blamee--refresh-timer)
      (setq blamee--refresh-timer nil))
    (blamee--popup-hide)
    (blamee--clear))))

;;;###autoload
(defun blamee-show-commit-at-point ()
  "Show the commit detail popup for the blame chunk at point."
  (interactive)
  (let ((commit (blamee--commit-at-point)))
    (if commit
        (blamee--popup-show commit)
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamee-copy-commit-hash-at-point ()
  "Copy the full commit hash of the blame chunk at point to the kill ring."
  (interactive)
  (let ((commit (blamee--commit-at-point)))
    (if commit
        (let ((hash (plist-get commit :hash)))
          (kill-new hash)
          (message "Copied %s" hash))
      (user-error "No blame information on this line"))))

;;;###autoload
(defun blamee-refresh ()
  "Recompute git blame overlays for the current buffer."
  (interactive)
  (if blamee-mode
      (blamee--refresh)
    (user-error "Blamee-mode is not enabled in this buffer")))

(defun blamee--maybe-enable ()
  "Turn on `blamee-mode' when the buffer visits a file inside a git worktree."
  (when (and buffer-file-name
             (not (minibufferp))
             (blamee--inside-worktree-p))
    (blamee-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-blamee-mode
  blamee-mode blamee--maybe-enable
  :group 'blamee)

(provide 'blamee)

;;; blamee.el ends here
