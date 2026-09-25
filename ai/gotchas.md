# Non-obvious gotchas

Non-obvious failure modes encountered while building this bridge.  Each
cost real debugging time; documented here so it doesn't have to be
re-discovered.

## MV3 service worker

### `chrome.action.setIcon({path: ...})` fails with "Failed to fetch"

The path-based form of `setIcon` runs a fetch under the hood that
breaks inside service workers regardless of whether the path is
correct.  The user sees `[bg] setIcon failed for <tabId> Failed to set
icon 'icons/icon16.png': Failed to fetch` and the icon doesn't change.

Fix: build `ImageData` from the PNGs via `OffscreenCanvas` and call
`setIcon({tabId, imageData})` instead.  Pattern is in
`extension/src/background.js` → `loadIconImageData()`.  Cache the
ImageData per icon variant for the SW lifetime so the conversion only
runs once.

### Service worker registration "Status code: 3"

Means the SW file couldn't be evaluated.  In our case this has always
been a JS module import that doesn't exist in the build dir.  Common
cause: a new `src/foo.js` was added to source but not to `SRC_FILES`
in the Makefile — `make build` skipped copying it, and the import in
`background.js` (or wherever) can't resolve.

The Makefile's `lint` step now walks `import` statements and verifies
the imported file is in `SRC_FILES`.  If status-3 ever happens again,
that check failed silently or someone bypassed it.

### Generated manifest.json: no comments, no `_comment` field

Chrome's manifest parser:
- Rejects `//` and `/* */` comments outright (it's strict JSON).
- Warns on any unknown top-level key including `_comment` / `_meta`
  / etc. — they used to be silently ignored, no longer.

Conclusion: there's no in-file way to mark `manifest.json` as
generated.  The build dir's existence (`extension/build/`) and the
gitignore are the signposts; the file itself stays bare.

## Networking

### `localhost` resolves to ::1 first on macOS Chrome

The Emacs `websocket-server` binds to IPv4 `127.0.0.1` when started
with `:host 'local`.  Chrome on macOS resolves `localhost` to `::1`
(IPv6) preferentially.  The browser's connection attempt fails on
IPv6 and *does not* fall back to IPv4 — you get a silent
"Reconnecting…" forever.

Fix: hardcode `ws://127.0.0.1:9130` in `extension/src/offscreen.js`,
and match it in `config.json` `host_permissions`.  Never use
`localhost` for the WS URL.

Diagnostic:

```bash
curl --max-time 3 -i --http1.1 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGVzdA==" \
  http://127.0.0.1:9130/
```

Returns `HTTP/1.1 101 Switching Protocols` on success.  If that works
and the extension can't connect, look at the URL Chrome is dialing.

### WebSocket frames fragment for large payloads

The Emacs `websocket` library calls `:on-message` per-frame, not
per-message.  WebSocket fragments large messages (>~128 KB) into one
initial frame with FIN=0 plus several continuation frames.  Naïvely
JSON-parsing each frame yields one truncated parse plus several
garbage parses, surfacing as a flurry of:

    browsel: could not parse frame as JSON: End of file while parsing JSON
    browsel: could not parse frame as JSON: could not parse JSON stream

Fix: accumulate frame text into a per-client buffer keyed by the
websocket object, only parse when `(websocket-frame-completep frame)`
returns t.  Pattern is in `browsel.el` →
`browsel--on-message` + `browsel--rx-buffers`.

Clean up the buffer on `:on-close` too — stale connections leak
their accumulator otherwise.

### Accumulate frame *bytes*, not frame text

The obvious way to write that accumulator — `websocket-frame-text` per
frame, concatenated — is wrong, and stays hidden until a payload is
both large enough to fragment and not pure ASCII.

`websocket-frame-text` is `(decode-coding-string
(websocket-frame-payload frame) 'utf-8)`: it decodes **each frame on
its own**.  A multibyte character split across the boundary decodes as
two invalid halves, and the reassembled message fails to parse at
exactly that offset:

    [RECV-CONT] +130500 byte(s); total=130500
    [RECV-CONT] +130390 byte(s); total=261072
    [RECV] 302259 byte(s)
    [WARN] could not parse frame as JSON: invalid utf-8 encoding: 1, nil, 130499

Emacs then never answers, and the browser reports `request CHATGPT
timed out` — which points at the wrong side of the bridge entirely.

Fix: accumulate `websocket-frame-payload` (raw unibyte bytes) and
`decode-coding-string` once, when the FIN bit arrives.  This also makes
`browser-gt-max-message-bytes` count bytes rather than characters,
which is what the name says.

Regression test: send a >128 KB frame with a multibyte character placed
near offset 131072 and check that a reply comes back.

## Emacs Lisp

### `defvar` doesn't override an already-bound variable

If you change a defvar default (e.g. `browsel-port` from `9129`
to `9130`), reloading the file in a running Emacs **doesn't** pick up
the new default.  The variable is already bound; `defvar` is a no-op
on bound symbols.

Live-session fix: `(setq browsel-port 9130)` explicitly after
the `load-file`.  On the next Emacs restart, `defvar` takes the new
default cleanly from the fresh load.

Always do this in the live-session reload incantation when changing
a defvar default — don't trust the documentation default.

### checkdoc's imperative check scans the whole first docstring line

`checkdoc` does not merely check that a docstring *starts* with an
imperative verb.  With `checkdoc-verb-check-experimental-flag` on (the
default), it searches the **entire first line** — case-insensitively —
for any word in `checkdoc-common-verbs-wrong-voice`
(`checkdoc.el`, `checkdoc-this-string-valid-engine`).

So an UPPERCASE argument name that happens to be a plural verb trips
it even when the docstring begins correctly:

```elisp
(defun browser-gt--format-receive-deltas (t4 marks dt-end-ms)
  "Return a receive-delta summary string from MARKS, or nil.   ; ✗
   → browser-gt.el:1566: Probably "MARKS" should be imperative "Mark"
```

The alist includes `marks`, `checks`, `sets`, `calls`, `finds`,
`contains`, `returns`, `adds`, `allows`, and ~70 more.  Fix by moving
the argument reference off line 1:

```elisp
  "Return a receive-delta summary string, or nil.               ; ✓
The result has the form \" S6=..ms ...\"; MARKS is ..."
```

### `lexical-binding: t` breaks dynamic `let` on `org-capture-initial`

Symbols like `org-capture-initial`, `org-capture-templates`, and
`org-capture-key` are dynamic variables in `org-capture.el`.  Under
`lexical-binding: t`, a `let` form binds them lexically — so the
callee (`org-capture`) doesn't see the value.  No error; the value
just silently doesn't take effect.

Fix: forward-declare with `(defvar org-capture-initial)` at the top
of any file using `lexical-binding: t`.  This tells the byte-compiler
to treat the symbol as special.

Same trick for `org-capture-templates`.  Both are in
`browsel.el` and `browsel-youtube.el`.

## ChatGPT specifically

The full selector survey, with the probes that produced it, is in
`ai/2026-09-25-chatgpt-changes.md`.  The three items below are the ones
that do not announce themselves as breakage.

### The conversation is virtualized: a single querySelectorAll lies

Only about 4-5 turns are in the DOM at once; the rest are removed, not
hidden.  `document.querySelectorAll('[data-chatgpt-search-unit-key]')`
therefore returns whatever is near the current scroll position and
*succeeds*, so a capture of a 23-turn conversation silently yields 6
turns and looks fine.

`extension/src/content-chatgpt.js` climbs from the newest turn to the
oldest and accumulates units keyed by `data-chatgpt-search-unit-key`.
It reports whether it reached the oldest turn;
`browser-gt-chatgpt.el` writes `#+chatgpt_incomplete:` into the file
and warns when it did not.  Any new feature that reads a whole
conversation needs the same treatment, or a name that says it returns
only what is rendered.

### Older turns load lazily, and the pause looks exactly like the top

This one already shipped a wrong fix once, so it is worth stating
plainly: **"the container stopped scrolling" does not mean "this is
the oldest turn."**

A freshly loaded tab holds only the last few turns.  Scrolling up
fetches the next chunk over the network, and until it arrives,
`scrollTop` is clamped, `scrollHeight` is unchanged, and no new units
appear.  That is indistinguishable from having reached the top.  A
first version broke out of the climb after one such round, declared
the oldest turn reached, and saved 7 turns of a 23-turn conversation
*with `complete: true`* — a silent, plausible-looking wrong answer.

Measured on a cold reload of a 23-turn conversation: `scrollHeight`
starts at 4011 with 10 units mounted and grows in bursts (+2726,
+1113, +2744, +4589, …) over 13 scroll-and-wait rounds, about 9
seconds, before settling at 20960.  Quiet rounds occur *between* those
bursts, one at a time.

So the climb ends only after `QUIET_ROUNDS` (4) consecutive rounds
with no movement, no `scrollHeight` growth, and no new units, and it
waits longer after a quiet round than after a productive one.  Do not
lower that constant to make captures faster — a single quiet round
happens routinely in the middle of a healthy climb.

Also: do not jump straight to `-scrollHeight` to reach the top.  It
clamps at the end of what is loaded, which is what made the broken
version look correct on a warm tab.  Warm tabs are the trap here; test
against a freshly reloaded one, since that is what a user who just
opened a conversation has.

### `data-chatgpt-search-unit-key` is not an identity

The key looks like `<turn-id>:<index>:<role>`, and the obvious reading is
that the prefix identifies the turn.  It does not, always.  Two schemes
coexist — UUID prefixes and `fallback-turn-N` — and **both appeared in
one conversation on build `d162ff86`** (4 fallback and 6 UUID keys among
the units mounted at one moment).  Some whole conversations use nothing
but fallback keys.

In a `fallback-turn-N` key, N is the unit's index **within the mounted
window**, not within the conversation.  Across a climb the same message
therefore carries different keys at different scroll positions, and two
different messages collide on one key.  Keyed that way, a capture
duplicates some rounds and loses others — one 6-round conversation saved
with a round repeated verbatim and its opening prompt replaced by a copy
of a later one.

Use `data-chatgpt-search-message-ids` instead: real UUIDs, present on
both roles (the assistant unit repeats its own id, so take the first
token).  `keyOf()` falls back to `data-chatgpt-selection-message-id`,
then to the turn container's `data-turn-key` plus the role.

The earlier handoff note (`ai/2026-09-25-chatgpt-changes.md`) describes
fallback keys as appearing on "a conversation whose ids had not settled
yet".  That reading does not hold on this build — treat fallback keys as
a normal state, not a transient one.

### Turn order cannot come from the order units were seen

Because the climb goes newest-first, and because the window around any
scroll position mounts several units at once, neither insertion order
nor per-round ordering gives conversation order.

`collect()` measures each unit's offset within the scrolled content
(`getBoundingClientRect().top - containerTop + scrollTop`) and sorts
by it at the end.  That quantity is invariant under scrolling and
stable when older turns load, because a `column-reverse` container
anchors at the bottom.  The measurement is refreshed on every sighting
— an early one is taken while less is mounted and is less accurate.

### The conversation scroll container is `column-reverse`

`[data-app-action-timeline-scroll]` has `scrollTop === 0` at the
*newest* turn and a *negative* scrollTop toward the oldest (observed:
`-18719` with `scrollHeight` 19404).  `scrollHeight` also changes while
scrolling, because turns mount and unmount.

Code carrying the usual assumptions — `scrollTop >= 0`, bottom means
`scrollTop === scrollHeight - clientHeight`, `scrollHeight` is stable —
misbehaves without erroring.  What holds in both directions, and all
the sweep relies on, is that increasing `scrollTop` moves toward the
newest turn.

### Code blocks have no `<pre>`, so converters drop every newline

A code block is now `div.CodeBlock > [data-markdown-copy="exclude"] +
div > code`.  A `<code>` with no `<pre>` ancestor is *inline* code by
HTML semantics, so pandoc emits inline verbatim and the whole block
collapses to one line with the newlines gone.  It reads as ChatGPT
having written a bad code block, not as a scraping bug.

`clean()` in `content-chatgpt.js` wraps any multi-line `<code>` in a
`<pre>` and lifts the language label off the action bar first.  It also
resets `className` on every `<code>`: a converter reads the first class
as the language name, which would otherwise be the Tailwind utility
`whitespace-pre!`, yielding `#+begin_src whitespace-pre!`.

Related: pandoc converts an inline `<svg>` into an `<img>` with a
base64 `data:` URI, hundreds of characters of noise per decorative
icon.  Icons are removed in the page by `clean()`, and
`browser-gt--strip-svg` removes any that survive before pandoc runs.

## YouTube specifically

### Caption baseUrl is now PoToken-gated

The `baseUrl` field on each entry of
`captions.playerCaptionsTracklistRenderer.captionTracks` no longer
returns the transcript via direct fetch.  As of mid-2025 YouTube
requires `pot` (Proof of Origin Token) or `c` (client identity) params
that the page's player adds internally before sending the request.

What you see when calling without them: HTTP 200 OK with an empty
body (`SyntaxError: Unexpected end of JSON input` when you try to
`response.json()`).  No error code, just nothing.

Workarounds, preferred first:

1. Open the "Show transcript" panel and scrape
   `transcript-segment-view-model` elements (the new component name —
   the older `ytd-transcript-segment-renderer` is gone).  Timestamp in
   `.ytwTranscriptSegmentViewModelTimestamp`, text in the trailing
   `span.ytAttributedStringHost`.
2. Use `yt-dlp` on the Emacs side (existing `YOUTUBE_TRANSCRIPT`
   handler).  Cheap, just shells out.

### `ytInitialPlayerResponse` vanishes after SPA navigation

`window.ytInitialPlayerResponse` is set ONCE at full page load.  When
the user clicks from one video to another, YouTube's SPA navigation
DOES NOT refresh this global — it can be stale (holding the previous
video's data) or completely absent on later pageviews.

Always prefer
`document.getElementById('movie_player').getPlayerResponse()` first,
fall back to the global only if that's null:

```js
const pr = (document.getElementById('movie_player')?.getPlayerResponse?.())
        || window.ytInitialPlayerResponse;
```

This is the canonical way to get the current video's player response.

## Process

### Per-tab consent for `EVAL_IN_ACTIVE_TAB` interacts with the request timeout

The consent overlay (in `extension/src/consent.js`) allows 30s for the
user to click.  `browsel-request-timeout` is 10s (was 5s).  If
the user is in another window and doesn't see the prompt for >10s,
Emacs times out — but the eval still executes when they eventually
click Allow, with no caller to receive the result.

If you're invoking `EVAL_IN_ACTIVE_TAB` from a script (e.g. via
emacsclient), have the user grant consent on the target tab before the
script runs.  Retrying through the timeout doesn't help — the second
request will get a fresh prompt anyway.
