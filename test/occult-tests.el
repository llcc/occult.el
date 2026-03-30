;;; occult-tests.el --- Tests for occult.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for occult - collapse and reveal buffer regions.
;;
;;; Code:

(require 'buttercup)
(require 'occult)

;;; Helpers

(defmacro occult-test-with-buffer (text &rest body)
  "Run BODY in a temp buffer with TEXT inserted."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun occult-test--fold-count ()
  "Count occult folds (parent overlays) in the current buffer."
  (length (occult--overlays-in (point-min) (point-max))))

(defun occult-test--body-overlay (parent)
  "Get the body overlay associated with PARENT."
  (overlay-get parent 'occult-body))

;;; Visible end calculation

(describe "occult--visible-end"
  (it "returns end-of-first-line for short lines"
    (occult-test-with-buffer "Short\nSecond line\n"
      (expect (occult--visible-end 1 19) :to-equal 6)))

  (it "caps at occult-summary-max-length"
    (let ((occult-summary-max-length 5))
      (occult-test-with-buffer "This is a long first line\nSecond\n"
        (expect (occult--visible-end 1 33) :to-equal 6))))

  (it "does not exceed end"
    (occult-test-with-buffer "Hi\n"
      (expect (occult--visible-end 1 3) :to-equal 3))))

;;; Overlay creation - two-overlay structure

(describe "occult-hide-region"
  (it "creates a parent overlay spanning the full region"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (let ((parent (occult--overlay-at-point)))
        (expect parent :to-be-truthy)
        (expect (overlay-start parent) :to-equal 1)
        (expect (overlay-end parent) :to-equal 22))))

  (it "creates a body overlay for the hidden portion"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect body :to-be-truthy)
        (expect (overlay-get body 'invisible) :to-equal 'occult))))

  (it "leaves the first line as navigable text"
    (occult-test-with-buffer "Visible first line\nHidden second\n"
      (occult-hide-region 1 34)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        ;; Body starts after first line, not at fold start
        (expect (overlay-start body) :to-be-greater-than 1))))

  (it "shows indicator in parent before-string"
    (occult-test-with-buffer "Hello\nWorld\n"
      (occult-hide-region 1 13)
      (let ((parent (occult--overlay-at-point)))
        (expect (overlay-get parent 'before-string) :to-match "📎"))))

  (it "shows ellipsis in body before-string"
    (occult-test-with-buffer "Hello\nWorld\n"
      (occult-hide-region 1 13)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect (overlay-get body 'before-string) :to-match "\\.\\.\\."))))

  (it "refuses overlapping regions"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 8)
      (expect (occult-hide-region 5 15) :to-throw 'user-error)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "refuses empty regions"
    (occult-test-with-buffer "Hello\n"
      (expect (occult-hide-region 3 3) :not :to-be-truthy)))

  (it "refuses blank regions"
    (occult-test-with-buffer "   \n  \n"
      (expect (occult-hide-region 1 7) :not :to-be-truthy)))

  (it "returns truthy on success"
    (occult-test-with-buffer "Hello world\n"
      (expect (occult-hide-region 1 13) :to-be-truthy)))

  (it "works in read-only buffers"
    (occult-test-with-buffer "Read only content\n"
      (setq buffer-read-only t)
      (occult-hide-region 1 19)
      (expect (occult-test--fold-count) :to-equal 1))))

;;; Toggle

(describe "occult-toggle"
  (it "collapses active region"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (set-mark 1)
      (goto-char 15)
      (activate-mark)
      (occult-toggle)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "expands fold at point - removes both overlays"
    (occult-test-with-buffer "Line 1\nLine 2\n"
      (occult-hide-region 1 15)
      (goto-char 1)
      (occult-toggle)
      (expect (occult-test--fold-count) :to-equal 0)
      ;; Verify no stale body overlays remain
      (expect (length (overlays-in (point-min) (point-max))) :to-equal 0)))

  (it "signals when nothing to toggle"
    (occult-test-with-buffer "Hello\n"
      (goto-char 1)
      (expect (occult-toggle) :to-throw 'user-error))))

;;; Reveal all

(describe "occult-reveal-all"
  (it "removes all folds including body overlays"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\nLine 4\n"
      (occult-hide-region 1 8)
      (occult-hide-region 15 22)
      (expect (occult-test--fold-count) :to-equal 2)
      (occult-reveal-all)
      (expect (occult-test--fold-count) :to-equal 0)
      (expect (length (overlays-in (point-min) (point-max))) :to-equal 0)))

  (it "disables internal mode after revealing all"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (expect occult--mode :to-be-truthy)
      (occult-reveal-all)
      (expect occult--mode :not :to-be-truthy))))

;;; Internal mode lifecycle

(describe "occult--mode"
  (it "activates when first fold is created"
    (occult-test-with-buffer "Hello world\n"
      (expect occult--mode :not :to-be-truthy)
      (occult-hide-region 1 13)
      (expect occult--mode :to-be-truthy)))

  (it "deactivates when last fold is removed"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (goto-char 1)
      (occult-toggle)
      (expect occult--mode :not :to-be-truthy)))

  (it "adds occult to invisibility spec when active"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (expect (memq 'occult buffer-invisibility-spec) :to-be-truthy)))

  (it "removes occult from invisibility spec when deactivated"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult-reveal-all)
      (expect (memq 'occult buffer-invisibility-spec) :not :to-be-truthy))))

;;; Buffer text preservation

(describe "buffer text preservation"
  (it "buffer-string returns full text with active folds"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (expect (buffer-string) :to-equal "Line 1\nLine 2\nLine 3\n")))

  (it "buffer-substring-no-properties returns full text"
    (occult-test-with-buffer "Line 1\nLine 2\nLine 3\n"
      (occult-hide-region 1 22)
      (expect (buffer-substring-no-properties 1 22)
              :to-equal "Line 1\nLine 2\nLine 3\n"))))

;;; Revert persistence

(describe "revert persistence"
  (it "saves overlay state"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      (expect occult--saved-overlays :to-be-truthy)
      (expect (length occult--saved-overlays) :to-equal 1)))

  (it "restores overlays when content matches"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      ;; Simulate revert - remove all overlays manually
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      (expect (occult-test--fold-count) :to-equal 0)
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 1)))

  (it "skips restoration when content hash mismatches"
    (occult-test-with-buffer "Hello world\n"
      (occult-hide-region 1 13)
      (occult--save-overlays)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (delete-overlay ov))
      ;; Mutate buffer content
      (goto-char 1)
      (delete-char 5)
      (insert "Goodbye")
      (occult--restore-overlays)
      (expect (occult-test--fold-count) :to-equal 0))))

;;; Content hash

(describe "occult--content-hash"
  (it "returns consistent hash for same content"
    (occult-test-with-buffer "Hello world\n"
      (let ((h1 (occult--content-hash 1 13))
            (h2 (occult--content-hash 1 13)))
        (expect h1 :to-equal h2))))

  (it "returns different hash for different content"
    (occult-test-with-buffer "Hello world, goodbye world\n"
      (let ((h1 (occult--content-hash 1 13))
            (h2 (occult--content-hash 13 28)))
        (expect h1 :not :to-equal h2)))))

;;; isearch integration

(describe "isearch integration"
  (it "sets isearch-open-invisible on body overlay"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (expect (overlay-get body 'isearch-open-invisible) :to-be-truthy))))

  (it "permanently reveals via isearch-open-invisible on body"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        (occult--isearch-reveal body)
        (expect (occult-test--fold-count) :to-equal 0)
        ;; Both overlays gone
        (expect (length (overlays-in (point-min) (point-max))) :to-equal 0))))

  (it "temporarily reveals and re-hides body"
    (occult-test-with-buffer "First line\nSecond line\n"
      (occult-hide-region 1 23)
      (let* ((parent (occult--overlay-at-point))
             (body (occult-test--body-overlay parent)))
        ;; Reveal
        (occult--isearch-reveal-temporary body nil)
        (expect (overlay-get body 'invisible) :to-equal nil)
        (expect (overlay-get body 'before-string) :to-equal nil)
        ;; Re-hide
        (occult--isearch-reveal-temporary body t)
        (expect (overlay-get body 'invisible) :to-equal 'occult)
        (expect (overlay-get body 'before-string) :to-be-truthy)))))

;;; Navigability

(describe "cursor navigation"
  (it "allows point on the visible portion of a fold"
    (occult-test-with-buffer "Visible text here\nHidden text\n"
      (occult-hide-region 1 30)
      ;; Point should be placeable within the visible first line
      (goto-char 5)
      (expect (point) :to-equal 5)
      (expect (occult--overlay-at-point) :to-be-truthy)))

  (it "body overlay starts after visible text"
    (occult-test-with-buffer "First line\nSecond line\nThird line\n"
      (let ((occult-summary-max-length 50))
        (occult-hide-region 1 35)
        (let* ((parent (occult--overlay-at-point))
               (body (occult-test--body-overlay parent)))
          ;; Body should not start at position 1
          (expect (overlay-start body) :to-be-greater-than 1)
          ;; Body should start at end of first line (pos 11)
          (expect (overlay-start body) :to-equal 11))))))

(provide 'occult-tests)

;; Local Variables:
;; package-lint-main-file: "occult.el"
;; End:
;;; occult-tests.el ends here
