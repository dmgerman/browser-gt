# browser-gt

Bidirectional WebSocket bridge between Emacs and a WebExtension on
`127.0.0.1:9130`.  Two builds ship from the same sources: a Chrome
Manifest V3 build and a Firefox Manifest V2 build.  Replaces the
previous HTTP-on-9129 design.  Full architecture, request catalog,
and configuration schema live in `README.org` — start there for
anything substantive.

## Rules

- **Never commit.**  Tell the user when changes are ready; they commit.
- **Development happens in the `dmg-devel` branch.**  Warn the user if
  the current branch is `main` (check with `git branch --show-current`)
  before making changes.
- **Never modify `spookfox/` or `emacsProtocol/`** — frozen reference
  material.  They're checked into the tree on purpose so you can read
  the wire protocol and the old extension; if either ever needs an
  update, ask first.
- **Edit only `extension/`, never `extension/build/`.**  The build dir
  is regenerated from sources by `make`, but it IS tracked in git so
  users can load the extension without running the toolchain.  After
  any change under `extension/` (src, html, icons, config.json, or
  targets/<name>/), run `cd extension && make` and stage the resulting
  diff under `extension/build/` alongside the source change — CI
  (`.github/workflows/extension-consistency.yml`) fails otherwise.

## Source map

| Path                              | Owns                                                        |
|-----------------------------------|-------------------------------------------------------------|
| `browser-gt.el`                | Server lifecycle, JSON frame dispatch, async/sync request primitives, shared helpers, `ORG_CAPTURE` / `ORG_ROAM_CAPTURE` / `EWW` handlers |
| `browser-gt-www.el`            | `SAVE_PAGE`                                                 |
| `browser-gt-chatgpt.el`        | `CHATGPT`                                                   |
| `browser-gt-youtube.el`        | `YOUTUBE`, `YOUTUBE_TRANSCRIPT`                              |
| `browser-gt-babel.el`          | `org-babel-execute:browser-gt-js`                               |
| `extension/config.json`           | Single source of truth: shared `extension` block + per-target overlays in `extensionTargets.<name>`, plus menus, handlers, contentScripts |
| `extension/src/`                  | Shared extension JS (handlers, popup, options, content scripts, consent) |
| `extension/html/` / `icons/`      | Shared extension HTML + icons                                |
| `extension/targets/<name>/`       | Per-target overlay tree.  `chrome/` (Manifest V3) has background.js, offscreen.js, eval-impl.js, executor.js.  `firefox/` (Manifest V2) has its own background.js, eval-impl.js, executor.js. |
| `extension/scripts/`              | `build-manifest.py` (takes `--target`), `make-red-icons.py`  |
| `extension/Makefile`              | `make` (= `make all`) / `make chrome` / `make firefox` / `make package` / `make lint` |
| `extension/build/<target>/`       | Generated per-target loadable directory. Tracked in git; regenerate with `make` and commit alongside source changes. |

## Build / verify cycle

```bash
# Extension changes:
cd extension && make              # builds every known target (chrome + firefox)
cd extension && make chrome       # builds build/chrome/ only
cd extension && make firefox      # builds build/firefox/ only (Manifest V2)
                                  # `make lint` runs as part of each target build

# Elisp changes — byte-compile to catch warnings before reload.
# Either let package.el resolve `websocket`:
emacs --batch -Q --eval '(progn (require (quote package)) (package-initialize))' -L . \
  --eval '(dolist (f (list "browser-gt.el" "browser-gt-www.el" \
                           "browser-gt-chatgpt.el" "browser-gt-youtube.el" \
                           "browser-gt-babel.el")) \
           (or (byte-compile-file f) (kill-emacs 1)))'
# ...or add the websocket package's directory with `-L` if the user uses
# straight.el or similar:  -L <path-to-websocket>

# Reload in the user's running Emacs:
emacsclient -e '(progn (browser-gt-stop) \
                       (load-file "browser-gt.el") \
                       (browser-gt-start))'

# Confirm the WS is reachable:
lsof -nP -iTCP:9130 -sTCP:LISTEN
```

After a manifest-affecting change the user must reload the extension
card in `chrome://extensions` — `make build` alone doesn't restart Chrome.

## Further reading for you

- `README.org` — comprehensive user-facing docs.
- `ai/spookfox-like.md` — the original design rationale.  Use as
  historical context if a decision seems weird.
- `ai/gotchas.md` — non-obvious failure modes encountered during the build
  that aren't documented elsewhere.  Read before debugging.
- `~/.claude/skills/browser-gt/` — how to *use* the bridge from a
  Claude Code session (read tabs, eval JS, etc.).  Distinct from
  building the bridge itself.

## When uncertain

Default to `README.org`; if it's not in there, ask.  Don't infer wire
protocol shapes or handler semantics — the parts are wired together
deliberately and silent guessing has cost us hours in the past
(IPv6 localhost, MV3 setIcon, lexical-binding capture variables).  All
written down in `ai/gotchas.md`.
