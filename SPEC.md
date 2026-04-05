# occult.el - Functional Specification

From Latin *occultus* ("hidden, secret"). Collapse any buffer region into a
single-line summary while keeping the underlying text fully intact.

## Problem

When working in Emacs buffers - LLM chat sessions, org documents, eshell, etc. -
verbose sections become visual clutter. Folding mechanisms like outline-mode or
org-cycle are structure-aware and don't work on arbitrary regions. We need a way
to visually collapse any selected region, with the guarantee that:

- The hidden text remains in the buffer (accessible to `buffer-string`,
  `buffer-substring`, org-export, copy/kill, LLM context extraction)
- Search (isearch AND evil-ex-search) can find text inside folds
- It works in any buffer: read-only, special-mode, TUI Emacs

## Core Mechanism

Each fold is backed by a pair of overlays: a parent covering the entire region
and a body covering the hidden suffix. The first line of the region remains
live, navigable buffer text.

- Parent overlay spans `[beg, end)` and carries the indicator glyph as
  `before-string`, an interaction keymap, a face, and `modification-hooks`.
- Body overlay spans `[split, end)` where `split` is the first-line break (or
  `beg + occult-summary-max-length`, whichever comes first). It carries
  `invisible 'occult` and prepends the ellipsis via `before-string`.
- The two overlays are linked via `occult-body` / `occult-parent` properties.
- `buffer-invisibility-spec` includes `'occult` whenever the internal mode is
  active, so the body text is hidden from display.
- `buffer-string` / `buffer-substring-no-properties` return the full original
  text regardless of overlay state - this is what LLM packages, org-export, and
  copy/kill use.

## Public API

Interactive commands and a programmatic function.

### `occult-toggle`

Interactive, DWIM behavior:

- Region active: collapse the region into a summary overlay.
- Point on an occult overlay (no region): expand it AND reactivate the region
  at the fold's original boundaries (point moves to `end`, mark is set to
  `beg`, `activate-mark` is called).
- Neither: signals `user-error` ("No region selected and no occult fold at
  point").

### `occult-reveal-all`

Remove all occult overlays in the current buffer. Emits `Revealed N fold(s)`
in the echo area. Leaves point and mark untouched.

### `occult-hide-region` (beg end)

Non-interactive. Programmatic entry point for creating a fold.

- Returns `t` on success, `nil` on silent refusal (empty / whitespace-only
  region, or `beg >= end`).
- Calls `deactivate-mark` on success.
- Signals `user-error` if the region overlaps an existing occult fold.

### `occult-edit-region`

Open the fold at point in a narrowed indirect buffer for editing. Bound to
`e` on the fold keymap.

- Signals `user-error` if point is not on an occult fold.
- Creates an indirect buffer via `make-indirect-buffer` with CLONE=t.
- Deletes all occult overlays inside the indirect buffer so the fold content
  is fully visible and modification-hooks do not fire on shared text edits.
- Narrows to the fold range and activates `occult-edit-mode`.
- Base buffer's fold stays collapsed throughout the session.
- Returns the indirect buffer (also displayed via `pop-to-buffer`).
- If base buffer is read-only, the session is created in view mode
  (see below).

### `occult-edit-commit` / `occult-edit-abort`

Commands active only inside `occult-edit-mode`. Both signal `user-error` if
called outside an edit session.

- `occult-edit-commit`: marks the indirect buffer unmodified and kills it,
  keeping all user changes live in the base buffer (text is shared via the
  indirect-buffer mechanism, no re-insertion needed).
- `occult-edit-abort`: restores the fold region to its original contents
  using `replace-buffer-contents` under `inhibit-modification-hooks`, which
  shifts the base's fold overlays to match the original boundaries without
  dissolving them. Prompts with `yes-or-no-p` when the buffer is modified.

In a read-only view session both commands simply close the view buffer
without touching the base buffer.

## Edit Mode

`occult-edit-mode` is a buffer-local minor mode enabled inside the indirect
buffer created by `occult-edit-region`.

- Keymap `occult-edit-mode-map` binds `occult-edit-commit-key` to
  `occult-edit-commit` and `occult-edit-abort-key` to `occult-edit-abort`.
  The map is rebuilt from the custom key variables whenever the mode is
  enabled, and when either custom is set through `customize-set-variable`.
- `header-line-format` is set to `(:eval (occult-edit--header-line))`, so
  the displayed keys always reflect the current bindings via
  `where-is-internal`.

### Edit session header

```
 Edit Occult Fold  │ C-c C-c commit │ C-c C-k abort
```

### View session header (read-only base buffer)

```
 View Occult Fold  │ C-c C-k close
```

The view variant hides the commit binding entirely because there is nothing
to commit; the abort key is relabelled "close" and simply kills the view
buffer.

### Session state

Each session stores buffer-local state inside the indirect buffer:

| Variable                      | Meaning                                   |
|-------------------------------|-------------------------------------------|
| `occult-edit--original-text`  | Fold content at session start (abort).    |
| `occult-edit--base-buffer`    | Base buffer the session is attached to.   |
| `occult-edit--read-only-p`    | `t` iff base buffer was read-only at start. |

## Point and Mark State After Operations

- After `occult-hide-region` success (including via `occult-toggle` collapse
  branch): mark is deactivated, point is unchanged.
- After `occult-toggle` expand branch: the region is active at the fold's
  former boundaries, point at `end`, mark at `beg`.
- After `occult-reveal-all`: point and mark are untouched.

## No User-Facing Top-Level Minor Mode

There is no `occult-mode` the user toggles for folding. The user calls
`occult-toggle` and it works. An internal minor mode (`occult--mode`)
activates/deactivates automatically to manage buffer-local hooks when folds
exist. The user never interacts with it directly.

`occult-edit-mode` is different: it is enabled only inside the indirect
buffer `occult-edit-region` creates, and the user interacts with it
indirectly through the commit/abort key bindings surfaced in the header
line.

## Overlay Properties

Folds use two overlays.

### Parent overlay

| Property             | Value                                                  |
|----------------------|--------------------------------------------------------|
| `occult`             | `t` (marker for finding our overlays)                  |
| `occult-body`        | Reference to the body overlay                          |
| `face`               | `occult-summary`                                       |
| `before-string`      | Indicator string                                       |
| `keymap`             | TAB/mouse-1 toggle the fold; `e` opens it for editing  |
| `help-echo`          | "Press TAB to expand"                                  |
| `evaporate`          | `t`                                                    |
| `modification-hooks` | Remove the fold if underlying text is edited           |

### Body overlay

| Property                             | Value                              |
|--------------------------------------|------------------------------------|
| `occult-parent`                      | Back-reference to parent overlay   |
| `invisible`                          | `'occult`                          |
| `before-string`                      | Ellipsis string                    |
| `evaporate`                          | `t`                                |
| `isearch-open-invisible`             | `occult--isearch-reveal`           |
| `isearch-open-invisible-temporary`   | `occult--isearch-reveal-temporary` |

## Summary Line Format

```
📎 First line of the region...
```

The visible portion of a folded region is live buffer text from `beg` up to
`split`, where `split = min(line-end, end, beg + occult-summary-max-length)`.
The body overlay takes over from `split` and prepends `occult-ellipsis` via
its `before-string`.

- Indicator: customizable via `occult-indicator`, default `"📎 "`
- Ellipsis: customizable via `occult-ellipsis`, default `"..."`
- Max length: customizable via `occult-summary-max-length`, default `80`
- The first line is not synthesized or copied - it is the actual underlying
  buffer text, navigable and selectable.

## Faces

Inherit from standard faces to work in light and dark themes without custom colors.

- `occult-summary` - the summary text. Inherits from `shadow`, adds `:slant italic`.
- `occult-indicator` - the prefix glyph. Inherits from `font-lock-constant-face`.
- `occult-edit-header` - edit/view label in the header line. Bold, inherits
  from `font-lock-function-name-face`.
- `occult-edit-commit-key` - commit key in the header line. Bold, inherits
  from `success`.
- `occult-edit-abort-key` - abort/close key in the header line. Bold,
  inherits from `error`.
- `occult-edit-header-separator` - pipes and descriptive labels in the
  header line. Inherits from `shadow`.

## Search Integration

### isearch (C-s / C-r)

Native integration via `invisible` property on the body overlay:

- `isearch-open-invisible-temporary`: temporarily reveals the fold while
  searching, re-hides when search moves on
- `isearch-open-invisible`: permanently reveals (deletes both overlays) when
  isearch exits with point inside a fold

### evil-ex-search (/ and ?)

Optional integration, only when evil is loaded. After `evil-ex-search-forward`,
`evil-ex-search-backward`, `evil-ex-search-next`, `evil-ex-search-previous` - if
point lands inside an occult overlay, temporarily reveal it. Re-hide is driven
by `post-command-hook` via shared `occult--auto-reveal-ov` state: once point
leaves the revealed fold, the hook re-hides it.

Implemented via advice on evil search commands, guarded by `(featurep 'evil)`.

## Auto-Reveal

Controlled by `occult-auto-reveal`:

- `nil` (default): folds stay collapsed until explicitly toggled
- `echo`: show full text in echo area when point is on a fold (truncated to
  approximately five frame-widths of characters)
- `expand`: temporarily expand when point enters, re-collapse when point leaves

isearch integration is always active regardless of this setting.

## Revert-Buffer Persistence

Folds survive `revert-buffer` (important for LLM chat buffers, eshell, etc.):

- `before-revert-hook`: save `(beg end content-hash)` tuples for all occult
  overlays into a buffer-local variable. `content-hash` is the SHA-256 of the
  region text.
- `after-revert-hook`: for each saved tuple, verify text at `(beg . end)`
  matches the stored hash. If yes, re-create the fold. If the hash does not
  match (or `end > point-max`), the fold is lost (graceful degradation).

This works reliably for append-only buffers (LLM, eshell) where old content
doesn't shift. For buffers that rebuild entirely (Dired `g`), folds are
lost - which is the expected behavior.

## Edge Cases

- Overlapping regions: signals `user-error` ("Region overlaps an existing
  occult fold")
- Nested folds: same `user-error` (subsumed by the overlap check)
- Empty / whitespace-only region: silent no-op, returns `nil`
- `beg >= end`: silent no-op, returns `nil`
- Single-line region: works (collapses to truncated summary)
- Read-only buffers: folds can be created and revealed normally; 
  `occult-edit-region` opens a view-only session instead of an edit session
- Buffers with no associated file: `occult-edit-region` works because the
  indirect buffer is created via `make-indirect-buffer`, which does not
  depend on the base buffer having a file
- Editing inside the indirect buffer: text propagates immediately to the
  base buffer (shared text), but the fold overlay in base stays collapsed
  because the modification-hooks only fire on the cloned overlays that were
  deleted from the indirect buffer at session start

## Customizable Variables

| Variable                    | Default      | Description                               |
|-----------------------------|--------------|-------------------------------------------|
| `occult-indicator`          | `"📎 "`      | Prefix string for summary line            |
| `occult-ellipsis`           | `"..."`      | Suffix string for summary line            |
| `occult-summary-max-length` | `80`         | Max chars from first line to show         |
| `occult-auto-reveal`        | `nil`        | Auto-reveal mode: nil, echo, or expand    |
| `occult-lighter`            | `" Occ"`     | Mode-line lighter (internal mode)         |
| `occult-edit-lighter`       | `" OccEdit"` | Mode-line lighter inside an edit session  |
| `occult-edit-commit-key`    | `"C-c C-c"`  | Key that commits an edit session          |
| `occult-edit-abort-key`     | `"C-c C-k"`  | Key that aborts / closes an edit session  |

## Package Metadata

- Requires: Emacs 29.1
- No external dependencies (evil integration is optional/lazy)
- License: GPL-3.0-or-later
- Single file: `occult.el`
