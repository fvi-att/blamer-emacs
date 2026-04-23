# blamer.el

Chunked `git blame` overlays for Emacs, rendered between the line numbers
and the source text. Each commit chunk is painted with its own subtle
background color, and a child-frame popup shows the full commit detail
when the cursor lands on a blamed line.

```
26-04-23 alice │ #!/usr/bin/env bash
               │ # previous banner
26-04-23 bob   │ set -euo pipefail
               │
26-04-23 alice │ cleanup() {
               │   rm -f "${tmp:-}"
               │ }
```

The blame prefix stays compact by default: **commit date + author**.
You can change the visible inline columns from `M-x customize-group RET
blamer`, and the inline area widens or shrinks to the longest visible
value in the current window instead of reserving a fixed width. Full
details (author, timestamp, 12-char hash, summary) appear in a popup or
echo area when you move point into the chunk.

## Features

- **Chunk grouping** — the inline prefix is drawn only on the first line
  of each same-commit run; continuation lines keep the source aligned.
- **Per-commit background color** — hue derived from the commit hash,
  so the colored stripe visualizes how far each chunk extends.
- **Popup details** — a frameless child frame on GUI Emacs (echo area
  fallback on TTY) shows author / date / hash / summary on point hover.
- **Mouse tooltips** — `help-echo` is attached to the inline prefix too,
  so hovering with the mouse works as well.
- **Auto-enable** — `global-blamer-mode` activates only for file-visiting
  buffers inside a git working tree.
- **Zero dependencies** beyond Emacs 27.1.

## Requirements

- Emacs 27.1 or newer (`color.el`, `make-frame` child frames).
- `git` executable on `PATH`.

## Installation

### straight.el

```elisp
(straight-use-package
 '(blamer :type git :host github :repo "fvi-att/blamer-emacs"))
(global-blamer-mode 1)
```

### use-package + straight

```elisp
(use-package blamer
  :straight (blamer :type git :host github :repo "fvi-att/blamer-emacs")
  :hook (after-init . global-blamer-mode)
  :bind (("C-c b b" . blamer-show-commit-at-point)
         ("C-c b y" . blamer-copy-commit-hash-at-point)
         ("C-c b r" . blamer-refresh)))
```

### Manual

Clone the repository somewhere and point `load-path` at it:

```elisp
(add-to-list 'load-path "/path/to/blamer-emacs")
(require 'blamer)
(global-blamer-mode 1)
```

### MELPA

Not yet available. A MELPA recipe is planned.

## Usage

| Command                              | Description                                       |
|--------------------------------------|---------------------------------------------------|
| `M-x blamer-mode`                    | Toggle in the current buffer.                     |
| `M-x global-blamer-mode`             | Toggle globally (auto-enables on git-tracked files). |
| `M-x blamer-refresh`                 | Recompute blame overlays (e.g. after an external commit). |
| `M-x blamer-show-commit-at-point`    | Force the popup to show for the chunk at point.   |
| `M-x blamer-copy-commit-hash-at-point` | Kill-ring the full 40-char commit hash.         |

Point movement to a blamed line opens the popup automatically after
`blamer-popup-delay` seconds of idle time. Moving off the blamed line,
switching buffers, or disabling `blamer-mode` hides it.

## Customization

All options live in the `blamer` customize group (`M-x customize-group
RET blamer`).

### Inline prefix

| Variable                     | Default       | Meaning                                         |
|------------------------------|---------------|-------------------------------------------------|
| `blamer-inline-columns`      | `(date author)` | Ordered inline columns to render.             |
| `blamer-comment-max-length`  | `10`          | Max inline summary width before truncation.     |
| `blamer-date-format`         | `"%y-%m-%d"`  | `format-time-string` spec for the inline date.  |
| `blamer-separator`           | `" │ "`       | Glyph between blame prefix and source.          |
| `blamer-uncommitted-label`   | `"Uncommitted"` | Label shown for uncommitted lines.            |
| `blamer-uncommitted-summary` | `"(not yet committed)"` | Summary text for uncommitted lines.   |
| `blamer-author-max-length`   | `5`           | Max inline author width before truncation.      |
| `blamer-hash-length`         | `6`           | Max inline hash width before truncation.        |

`blamer-inline-columns` accepts any ordered combination of `author`,
`date`, `summary`, and `hash`. The default stays intentionally small,
but you can expose more metadata inline when needed. The separator
position follows the longest visible value in the current window, so the
blame gutter grows and shrinks as you scroll.

### Chunk background color

| Variable                        | Default | Meaning                                    |
|---------------------------------|---------|--------------------------------------------|
| `blamer-background-saturation`  | `0.32`  | HSL saturation (0.0 – 1.0).                |
| `blamer-background-lightness`   | `0.22`  | HSL lightness. Use ≈0.85 for light themes. |

Colors are deterministic: the hue comes from the commit hash, so each
commit keeps the same tint across sessions and files.

### Popup

| Variable                              | Default             | Meaning                                          |
|---------------------------------------|---------------------|--------------------------------------------------|
| `blamer-popup-enabled`                | `t`                 | Set `nil` to disable the popup entirely.         |
| `blamer-popup-delay`                  | `0.5`               | Idle seconds before the popup appears.           |
| `blamer-popup-detail-date-format`     | `"%Y-%m-%d %H:%M"` | Date format inside the popup.                    |
| `blamer-popup-max-width`              | `70`                | Maximum inner width of the popup frame (columns). |

### Timing

| Variable             | Default | Meaning                                          |
|----------------------|---------|--------------------------------------------------|
| `blamer-idle-delay`  | `0.3`   | Seconds to wait after `save` / `revert` before recomputing. |

### Faces

All inline columns inherit from `blamer-face`, so tuning font size or
contrast is a one-liner:

```elisp
(set-face-attribute 'blamer-face nil :height 0.55)
```

| Face                     | Purpose                                  |
|--------------------------|------------------------------------------|
| `blamer-face`            | Base face (inherits `shadow`).           |
| `blamer-author-face`     | Author column.                           |
| `blamer-date-face`       | Date column.                             |
| `blamer-comment-face`    | Summary column.                          |
| `blamer-hash-face`       | Hash column.                             |
| `blamer-separator-face`  | The `│` glyph.                           |

### Recipe: compact dark theme

```elisp
(setq blamer-comment-max-length 8
      blamer-date-format "%m-%d"
      blamer-inline-columns '(date summary)
      blamer-background-saturation 0.25
      blamer-background-lightness 0.2)
(set-face-attribute 'blamer-face nil :height 0.55)
```

### Recipe: show author + hash inline

```elisp
(setq blamer-inline-columns '(author date hash summary)
      blamer-author-max-length 10
      blamer-hash-length 8)
```

### Recipe: light theme

```elisp
(setq blamer-background-lightness 0.88
      blamer-background-saturation 0.35)
```

### Recipe: disable the popup, keep inline + tooltip

```elisp
(setq blamer-popup-enabled nil)
```

The inline prefix still carries `help-echo`, so mouse tooltips keep
working even with the popup off.

## How it works

1. `git blame --porcelain` is run against the file on disk.
2. The output is parsed into `(LINENO . COMMIT-PLIST)` entries.
3. For each line, a zero-width overlay is placed at `line-beginning-position`
   with a `before-string` that contains the blame prefix (or a same-width
   spacer for continuation lines).
4. `display-line-numbers-mode` renders line numbers in its dedicated
   pre-text area, so the blame prefix appears **between** the numbers
   and the source text.
5. A global `post-command-hook` watches for point entering a blamed
   line and schedules the popup after `blamer-popup-delay` idle seconds.

## Limitations / notes

- Blame is computed against the **on-disk** file; unsaved changes are
  ignored until the next save.
- Files not yet committed are labeled as `Uncommitted` with no background
  color.
- The popup uses Emacs child frames (requires `display-graphic-p`).
  On a terminal it falls back to the echo area.
- Very large files will take as long as `git blame` takes; no
  asynchronous path yet.

## Development

```sh
# Byte-compile (also runs as a lint)
emacs -Q --batch -L . -f batch-byte-compile blamer.el
```

No tests yet. Contributions welcome.

## License

MIT. See [LICENSE](LICENSE).
