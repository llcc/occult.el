;;; occult.el --- Collapse and reveal buffer regions -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: March 25, 2026
;; Version: 0.1.0
;; Keywords: convenience
;; Homepage: https://github.com/agzam/occult.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Occult (from Latin occultus - "hidden, secret") lets you collapse any
;; buffer region into a single-line summary using overlays.  The hidden text
;; remains fully present in the buffer - accessible to `buffer-string',
;; `buffer-substring-no-properties', org-export, copy/kill, and LLM context
;; extraction tools.
;;
;; Usage:
;;   Select a region and call `occult-toggle' to collapse it.
;;   Call `occult-toggle' with point on a collapsed fold to expand it.
;;   Call `occult-reveal-all' to expand all folds in the buffer.
;;
;;; Code:

(require 'cl-lib)

;; Silence byte-compiler about evil functions
(declare-function evil-ex-search-forward "evil-ex" ())
(declare-function evil-ex-search-backward "evil-ex" ())
(declare-function evil-ex-search-next "evil-ex" ())
(declare-function evil-ex-search-previous "evil-ex" ())

;;; Customization

(defgroup occult nil
  "Collapse and reveal buffer regions."
  :group 'convenience
  :prefix "occult-")

(defcustom occult-indicator "📎 "
  "Prefix string displayed before the summary text of a fold."
  :type 'string)

(defcustom occult-ellipsis "..."
  "Suffix string appended to truncated fold summaries."
  :type 'string)

(defcustom occult-summary-max-length 80
  "Maximum number of characters from the first line to display in a fold."
  :type 'integer)

(defcustom occult-auto-reveal nil
  "How to automatically reveal folds when point enters them.

nil       - folds stay collapsed until explicitly toggled
`echo'    - show fold content in echo area when point is on a fold
`expand'  - temporarily expand when point enters, re-collapse on exit

Note: isearch integration is always active regardless of this setting."
  :type '(choice (const :tag "No auto-reveal" nil)
                 (const :tag "Show in echo area" echo)
                 (const :tag "Temporarily expand" expand)))

(defcustom occult-lighter " Occ"
  "Mode-line lighter shown when occult folds exist in the buffer."
  :type 'string)

;;; Faces

(defface occult-summary
  '((t :inherit shadow :slant italic))
  "Face for the summary text of a collapsed region.")

(defface occult-indicator
  '((t :inherit font-lock-constant-face))
  "Face for the indicator glyph prefixing a fold summary.")

;;; Internal variables

(defvar-local occult--saved-overlays nil
  "Saved overlay state for `revert-buffer' persistence.
List of (BEG END CONTENT-HASH) tuples.")

(defvar-local occult--auto-reveal-ov nil
  "Overlay currently auto-revealed by cursor proximity or evil search.")

;;; Overlay keymap

(defvar occult-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'occult-toggle)
    (define-key map [mouse-1] #'occult-toggle)
    map)
  "Keymap active on occult fold overlays.")

;;; Internal helpers

(defun occult--overlays-in (beg end)
  "Return all occult overlays overlapping BEG..END."
  (cl-remove-if-not
   (lambda (ov) (overlay-get ov 'occult))
   (overlays-in beg end)))

(defun occult--overlay-at-point ()
  "Return the occult overlay at point, or nil."
  (cl-find-if
   (lambda (ov) (overlay-get ov 'occult))
   (overlays-at (point))))

(defun occult--visible-end (beg end)
  "Return the position where visible text ends for a fold at BEG..END.
Capped at the end of the first line or `occult-summary-max-length'
characters from BEG, whichever comes first."
  (save-excursion
    (goto-char beg)
    (min (line-end-position) end (+ beg occult-summary-max-length))))

(defun occult--content-hash (beg end)
  "Compute a SHA-256 hash of buffer text between BEG and END."
  (secure-hash 'sha256 (buffer-substring-no-properties beg end)))

;;; Overlay lifecycle

(define-fringe-bitmap 'occult-fold-bitmap
  [0 24 60 126 60 24 0 0])

(defun occult--create-overlay (beg end)
  "Create an occult fold spanning BEG to END.
The first line (up to `occult-summary-max-length' chars) stays visible
and navigable.  The remainder is hidden via a body overlay.
Returns the parent overlay."
  (let* ((split (occult--visible-end beg end))
         (body-text (buffer-substring-no-properties split end))
         (indicator (propertize occult-indicator 'face 'occult-indicator))
         (ellipsis (concat (propertize occult-ellipsis 'face 'occult-summary)
                           (if (string-match-p "\n" body-text) "\n" "")))
         (parent (make-overlay beg end nil t nil))
         (body (make-overlay split end nil t nil)))
    ;; Parent overlay - spans the whole fold, provides keymap and ID
    (overlay-put parent 'occult t)
    (overlay-put parent 'occult-body body)
    (overlay-put parent 'face 'occult-summary)
    (overlay-put parent 'invisible 'occult)
    (overlay-put
     parent
     'before-string
     (propertize " "
                 'display
                 `(left-fringe occult-fold-bitmap)
                 'keymap occult-overlay-map
                 'mouse-face 'highlight))
    (overlay-put parent 'keymap occult-overlay-map)
    (overlay-put parent 'help-echo "Press TAB to expand")
    (overlay-put parent 'evaporate t)
    (overlay-put parent 'modification-hooks (list #'occult--modification-hook))
    ;; Body overlay - hides everything after the visible portion
    (overlay-put body 'occult-parent parent)
    (overlay-put body 'invisible 'occult)
    ;; (overlay-put body 'before-string ellipsis)
    (overlay-put body 'evaporate t)
    (overlay-put body 'isearch-open-invisible #'occult--isearch-reveal)
    (overlay-put body 'isearch-open-invisible-temporary
                 #'occult--isearch-reveal-temporary)
    (occult--ensure-mode)
    parent))

(defun occult--delete-fold (ov)
  "Delete fold OV and its associated body overlay."
  (when (and ov (overlay-buffer ov))
    (when-let ((body (overlay-get ov 'occult-body)))
      (when (overlay-buffer body)
        (delete-overlay body)))
    (delete-overlay ov)))

(defun occult--remove-overlay (ov)
  "Delete fold OV and clean up mode if no folds remain."
  (occult--delete-fold ov)
  (occult--maybe-disable-mode))

;;; isearch integration

(defun occult--isearch-reveal (body-ov)
  "Permanently reveal fold when isearch exits inside BODY-OV."
  (let ((parent (overlay-get body-ov 'occult-parent)))
    (when parent (occult--remove-overlay parent))))

(defun occult--isearch-reveal-temporary (body-ov hide-p)
  "Toggle body overlay BODY-OV visibility during isearch.
When HIDE-P is non-nil, re-hide.  Otherwise, reveal."
  (if hide-p
      (let* ((parent (overlay-get body-ov 'occult-parent))
             (split (overlay-start body-ov))
             (end (if parent (overlay-end parent) (overlay-end body-ov)))
             (body-text (buffer-substring-no-properties split end))
             (trailing (if (string-match-p "\n" body-text) "\n" "")))
        (overlay-put body-ov 'invisible 'occult)
        (overlay-put body-ov 'before-string
                     (concat (propertize occult-ellipsis 'face 'occult-summary)
                             trailing)))
    (overlay-put body-ov 'invisible nil)
    (overlay-put body-ov 'before-string nil)))

;;; Modification hook

(defun occult--modification-hook (ov after-p &rest _args)
  "Delete fold OV and its body when text is modified.
Only acts on the after-modification call (AFTER-P non-nil)."
  (when (and after-p (overlay-buffer ov))
    (occult--delete-fold ov)))

;;; Revert-buffer persistence

(defun occult--save-overlays ()
  "Snapshot all occult overlays before `revert-buffer'.
Stores position and content hash for later restoration."
  (setq occult--saved-overlays
        (mapcar (lambda (ov)
                  (list (overlay-start ov)
                        (overlay-end ov)
                        (occult--content-hash
                         (overlay-start ov) (overlay-end ov))))
                (occult--overlays-in (point-min) (point-max)))))

(defun occult--restore-overlays ()
  "Restore occult overlays after `revert-buffer'.
Only restores folds whose content hash still matches."
  (when occult--saved-overlays
    (dolist (entry occult--saved-overlays)
      (let ((beg (nth 0 entry))
            (end (nth 1 entry))
            (hash (nth 2 entry)))
        (when (and (<= end (point-max))
                   (string= hash (occult--content-hash beg end)))
          (occult--create-overlay beg end))))
    (setq occult--saved-overlays nil)))

;;; Auto-reveal and evil search support

(defun occult--re-hide-auto-revealed ()
  "Re-hide a previously auto-revealed overlay if point has left it."
  (when-let* ((parent occult--auto-reveal-ov)
              (live (overlay-buffer parent))
              (outside (or (< (point) (overlay-start parent))
                           (<= (overlay-end parent) (point)))))
    (when-let ((body (overlay-get parent 'occult-body)))
      (when (overlay-buffer body)
        (let* ((body-text (buffer-substring-no-properties
                           (overlay-start body) (overlay-end body)))
               (trailing (if (string-match-p "\n" body-text) "\n" "")))
          (overlay-put body 'invisible 'occult)
          (overlay-put body 'before-string
                       (concat (propertize occult-ellipsis 'face 'occult-summary)
                               trailing)))))
    (setq occult--auto-reveal-ov nil)))

(defun occult--auto-reveal-at-point ()
  "Temporarily reveal or describe the fold at point.
Behavior depends on `occult-auto-reveal'."
  (when-let ((parent (occult--overlay-at-point)))
    (pcase occult-auto-reveal
      ('echo
       (message "%s"
                (truncate-string-to-width
                 (buffer-substring-no-properties
                  (overlay-start parent) (overlay-end parent))
                 (* 5 (frame-width)) nil nil occult-ellipsis)))
      ('expand
       (when-let ((body (overlay-get parent 'occult-body)))
         (when (overlay-buffer body)
           (overlay-put body 'invisible nil)
           (overlay-put body 'before-string nil)))
       (setq occult--auto-reveal-ov parent)))))

(defun occult--post-command ()
  "Post-command handler for auto-reveal management."
  (occult--re-hide-auto-revealed)
  (occult--auto-reveal-at-point))

;;; Evil integration

(defun occult--evil-search-reveal (&rest _args)
  "After an evil search command, temporarily reveal the fold at point."
  (when-let ((parent (occult--overlay-at-point)))
    (when-let ((body (overlay-get parent 'occult-body)))
      (when (overlay-buffer body)
        (overlay-put body 'invisible nil)
        (overlay-put body 'before-string nil)))
    (setq occult--auto-reveal-ov parent)))

(defvar occult--evil-advised nil
  "Non-nil if evil search advice has been installed.")

(defun occult--setup-evil ()
  "Install advice on evil search commands for fold reveal."
  (unless occult--evil-advised
    (dolist (fn '(evil-ex-search-forward
                  evil-ex-search-backward
                  evil-ex-search-next
                  evil-ex-search-previous))
      (advice-add fn :after #'occult--evil-search-reveal))
    (setq occult--evil-advised t)))

;;; Internal minor mode

(define-minor-mode occult--mode
  "Internal mode managing occult hooks in the current buffer.
Not intended for direct use - activates automatically when folds
are created and deactivates when the last fold is removed."
  :lighter occult-lighter
  (if occult--mode
      (progn
        (add-to-invisibility-spec 'occult)
        (add-hook 'before-revert-hook #'occult--save-overlays nil t)
        (add-hook 'after-revert-hook #'occult--restore-overlays nil t)
        (add-hook 'post-command-hook #'occult--post-command nil t))
    (remove-from-invisibility-spec 'occult)
    (remove-hook 'before-revert-hook #'occult--save-overlays t)
    (remove-hook 'after-revert-hook #'occult--restore-overlays t)
    (remove-hook 'post-command-hook #'occult--post-command t)
    (setq occult--auto-reveal-ov nil)))

(defun occult--ensure-mode ()
  "Activate the internal mode if not already active."
  (unless occult--mode
    (occult--mode 1))
  (when (and (not occult--evil-advised)
             (featurep 'evil))
    (occult--setup-evil)))

(defun occult--maybe-disable-mode ()
  "Deactivate the internal mode if no folds remain in the buffer."
  (when (and occult--mode
             (null (occult--overlays-in (point-min) (point-max))))
    (occult--mode -1)))

;;; Public commands

;;;###autoload
(defun occult-hide-region (beg end)
  "Collapse the region between BEG and END into a summary fold.
Refuses if the region is empty, blank, or overlaps an existing fold."
  (when (and beg end (< beg end)
             (not (string-blank-p
                   (buffer-substring-no-properties beg end))))
    (if (occult--overlays-in beg end)
        (user-error "Region overlaps an existing occult fold")
      (occult--create-overlay beg end)
      (deactivate-mark)
      t)))

;;;###autoload
(defun occult-toggle ()
  "Toggle an occult fold at point or on the active region.

With an active region, collapse it into a summary line.
With point on an existing fold (no region), expand it.
Otherwise, do nothing."
  (interactive)
  (if (use-region-p)
      (occult-hide-region (region-beginning) (region-end))
    (if-let ((ov (occult--overlay-at-point)))
        (occult--remove-overlay ov)
      (user-error "No region selected and no occult fold at point"))))

;;;###autoload
(defun occult-reveal-all ()
  "Remove all occult folds in the current buffer."
  (interactive)
  (let ((ovs (occult--overlays-in (point-min) (point-max))))
    (mapc #'occult--delete-fold ovs)
    (occult--maybe-disable-mode)
    (message "Revealed %d fold(s)" (length ovs))))

(provide 'occult)
;;; occult.el ends here
