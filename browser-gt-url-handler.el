;;; browsel-url-handler.el --- URL routing through browsel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser
;; URL: https://github.com/dmgerman/browsel

;; SPDX-License-Identifier: GPL-3.0-or-later
;;
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

;; Optional browsel module that routes URLs from Emacs to a connected
;; browser via the WebSocket bridge.  Drop-in `browsel-browse-url' is
;; compatible with `browse-url-browser-function', so any Emacs command
;; that opens a URL (org links, eww, mu4e, Dired, …) can be made to go
;; through browsel.
;;
;; Routing is configured in `browsel-url-routes' as an ordered list of
;; plists: each entry maps a URL pattern to a client, an
;; incognito flag, and an optional separate match used to detect when
;; the URL is "already open" in some tab.  First match in the list
;; wins; URLs that match nothing fall through to
;; `browsel-default-client', non-incognito.
;;
;; A route's `:client' may be the string \"eww\" (or
;; `browsel-default-client' itself may be \"eww\") to render the URL
;; inside Emacs with eww instead of dispatching to a connected
;; browser.  No WS bridge call is made in that case; buffer reuse is
;; left to `eww-reuse-buffers'.
;;
;; When an existing matching tab is found (under the route's incognito
;; constraint), the function focuses it and raises the browser window.
;; Otherwise a fresh tab is opened — in an incognito window for
;; incognito routes, or via plain OPEN_TAB for the rest.
;;
;; Example configuration:
;;
;;   (setq browsel-url-routes
;;         '((:pattern "\\`https?://\\(www\\.\\)?github\\.com/"
;;            :client  "chrome")
;;           (:pattern "\\`https?://app\\.slack\\.com/"
;;            :client  "chrome"
;;            :tab-match "\\`https?://app\\.slack\\.com/")
;;           (:pattern "\\`https?://news\\."
;;            :client  "firefox"
;;            :incognito t)))
;;
;;   ;; Route every URL Emacs opens through browsel:
;;   (setq browse-url-browser-function #'browsel-browse-url)
;;
;; Incognito caveat: opening an incognito tab requires the user to
;; toggle "Allow in incognito" for the browsel extension in
;; `chrome://extensions' (or the Firefox equivalent).  When the toggle
;; is off the extension cannot enumerate or create incognito windows;
;; `browsel-browse-url' detects the failure, warns, and falls back to
;; a normal (non-incognito) tab so the user still reaches the page.
;;
;; URL preprocessing: `browsel-browse-url-preprocess-functions' is an
;; abnormal hook of URL-rewriting functions run before routing.  Each
;; function receives a URL string and returns a (possibly rewritten)
;; URL string; functions apply in list order and the output of one
;; feeds the next.  The rewritten URL is what routing, tab matching,
;; and the browser dispatch all see.  Intended for lossless rewrites
;; — un-wrapping tracker links, canonicalizing amp-URLs, and the like.

;;; Code:

(require 'browsel)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'url-parse)

;; ── Configuration ──────────────────────────────────────────────────────────

(defcustom browsel-url-routes nil
  "Ordered list of URL routing rules for `browsel-browse-url'.

Each element is a plist with these keys:

  :pattern REGEX
    Regular expression matched against the full URL.  The match is
    a substring match (anywhere in the URL) — leading/trailing `.*'
    is redundant.  Anchor explicitly with `\\\\=`' and `\\\\='' if a
    strict whole-string match is wanted.

    Convention: include a trailing `/' on host patterns (e.g.
    `\"uvic\\\\.ca/\"' rather than `\"uvic\\\\.ca\"') so a stray
    occurrence of the host string inside a query parameter of some
    other URL doesn't false-match.

    The first matching entry in the list wins.

  :client CLIENT-NAME
    String — the browsel client to address (e.g. \"chrome\" or
    \"firefox\").  Must name a currently-connected client.
    May also be the string \"eww\", in which case the URL is opened
    in Emacs with `eww' and the WS bridge is not used.  When
    `:client' is \"eww\", `:incognito' and `:tab-match' are ignored;
    buffer reuse is governed by `eww-reuse-buffers'.

  :incognito BOOL
    Optional.  When non-nil, the tab is opened in an incognito /
    private window.  Requires the user to have toggled \"Allow in
    incognito\" on the browsel extension; without that toggle the
    extension cannot create or even enumerate incognito windows,
    `browsel-browse-url' detects the failure, warns once, and
    falls back to a normal tab.

  :tab-match REGEX
    Optional override for the already-open detection.  When set,
    this regex is matched against the tab URLs returned by
    `GET_ALL_TABS'.  Without this key the tab match defaults to
    \"the tab URL must contain the requested URL\" (regexp-quoted),
    independent of `:pattern' — routing (which client) and tab
    matching (which open tab) are separate concerns.

URLs that match no entry fall through to `browsel-default-client',
non-incognito, with identical-URL match."
  :type '(repeat plist)
  :group 'browsel)

(defcustom browsel-browse-url-preprocess-functions nil
  "Abnormal hook of URL-rewriting functions run before routing.
Each function receives a URL string and must return a URL string.
Functions are applied in list order and the output of one is fed
into the next.  The rewritten URL is what `browsel-browse-url'
matches against `browsel-url-routes' and passes to the browser (or
eww).

Intended for lossless URL rewriting — un-wrapping tracker links,
canonicalizing amp-URLs, and the like.  Functions must be pure
\(URL string in, URL string out) and must return the input
unchanged when they do not apply."
  :type 'hook
  :group 'browsel)

;; ── Matching helpers ───────────────────────────────────────────────────────

(defun browsel-url-handler--domain (url)
  "Return the host of URL with a leading `www.' stripped, or nil.
Used by the no-route fallback to find an already-open tab whose URL
contains the same domain — e.g. opening `https://amazon.ca/' will
reuse a tab already on `https://www.amazon.ca/dp/B1234'."
  (let ((host (and (stringp url)
                   (ignore-errors
                     (url-host (url-generic-parse-url url))))))
    (and host
         (not (string-empty-p host))
         (replace-regexp-in-string "\\`www\\." "" host))))

(defun browsel-url-handler--bare-domain-p (url)
  "Return non-nil when URL is a bare domain (no path beyond `/').
Used to scope the no-route domain-substring fallback to URLs that
explicitly target a site's root.  A URL with a real path (e.g.
`https://github.com/foo/bar') resolves via identical-URL match
instead, so it doesn't land on whichever other-page tab on the
same domain happens to be the most-recently-accessed."
  (let ((path (and (stringp url)
                   (ignore-errors
                     (url-filename (url-generic-parse-url url))))))
    (or (null path)
        (string-empty-p path)
        (string= path "/"))))

(defun browsel-url-handler--match-route (url)
  "Return the first entry in `browsel-url-routes' whose :pattern matches URL.
Returns nil if no entry matches."
  (seq-find (lambda (route)
              (let ((pat (plist-get route :pattern)))
                (and (stringp pat)
                     (string-match-p pat url))))
            browsel-url-routes))

(defun browsel-url-handler--tab-matches-p (tab url tab-match incognito)
  "Return non-nil when TAB qualifies as already-open for URL under this route.
TAB is a plist as returned by `GET_ALL_TABS'.  TAB-MATCH, when a
non-empty string, is a regex used in place of identical-URL
comparison.  INCOGNITO, when non-nil, restricts matching to tabs in
incognito windows."
  (let ((tab-url (plist-get tab :url))
        (tab-incog (eq (plist-get tab :incognito) t)))
    (and (stringp tab-url)
         (or (not incognito) tab-incog)
         (if (and (stringp tab-match) (not (string-empty-p tab-match)))
             (string-match-p tab-match tab-url)
           (string= tab-url url)))))

(defun browsel-url-handler--find-existing-tab (url client incognito tab-match)
  "Return the most-recently-accessed matching tab from CLIENT, or nil.
URL, INCOGNITO, and TAB-MATCH are forwarded to
`browsel-url-handler--tab-matches-p' for the filter."
  (let* ((tabs    (browsel-request "GET_ALL_TABS" nil client))
         (matches (seq-filter
                   (lambda (tab)
                     (browsel-url-handler--tab-matches-p
                      tab url tab-match incognito))
                   (or tabs '()))))
    (car (seq-sort-by
          (lambda (tab) (or (plist-get tab :lastAccessed) 0))
          #'>
          matches))))

;; ── Open primitives ────────────────────────────────────────────────────────

(defun browsel-url-handler--focus (tab client)
  "Activate TAB inside CLIENT, raise its window, and nudge the macOS app.
The OS-level app activation is delegated to `browsel-activate-client'
in `browsel.el' (shared with `browsel-tab-manager')."
  (browsel-request "FOCUS_TAB"
                   (list :id (plist-get tab :id) :focusWindow t)
                   client)
  (browsel-activate-client client))

(defun browsel-url-handler--open-new (url client incognito)
  "Open URL in a new tab on CLIENT.
INCOGNITO non-nil routes via `OPEN_INCOGNITO_TAB'; if that fails
\(typically because the extension lacks the \"Allow in incognito\"
toggle), the function warns and falls back to a normal tab so the
URL still reaches the user.  After the tab is opened,
`browsel-activate-client' brings the browser process to the OS
foreground the same way the focus-existing-tab path does."
  (if (not incognito)
      (browsel-request "OPEN_TAB" (list :url url) client)
    (condition-case err
        (browsel-request "OPEN_INCOGNITO_TAB" (list :url url) client)
      (error
       (message "browsel: incognito open failed (%s); using normal tab"
                (error-message-string err))
       (browsel-request "OPEN_TAB" (list :url url) client))))
  (browsel-activate-client client))

;; ── Public command ─────────────────────────────────────────────────────────

;;;###autoload
(defun browsel-browse-url (url &rest _ignored)
  "Open URL in a browser via browsel, honoring `browsel-url-routes'.

URL is first passed through
`browsel-browse-url-preprocess-functions' (an abnormal hook of
URL-rewriting functions applied in order); the rewritten URL is
what routing, tab matching, and the browser dispatch all see.

Two separate concerns:

  (a) ROUTING — which client to send the URL to.  The first route
      in `browsel-url-routes' whose `:pattern' matches URL provides
      the client and incognito flag.  No route matches →
      `browsel-default-client', non-incognito.  When the resolved
      client is the string \"eww\", the URL is opened in Emacs with
      `eww' and the rest of this docstring (tab matching, incognito,
      window raising) does not apply.

  (b) TAB MATCHING — whether to focus an already-open tab or open
      a new one.  By default the tab URL must fully contain the
      requested URL: a sub-page of the requested URL still counts
      (requesting `https://github.com/x/y' focuses a tab on
      `https://github.com/x/y/issues/3'), but an unrelated page on
      the same domain does not.  Bare-domain requests get a small
      relaxation — the requested host (with leading `www.' stripped)
      is the substring needle, so opening `https://amazon.ca/' still
      reuses an open tab on `https://www.amazon.ca/dp/B1234'.  A
      route's `:tab-match' overrides the default.

After resolution, if a tab qualifies as already open on the target
client (subject to the route's incognito constraint), the function
focuses it and brings the window forward.  Otherwise a fresh tab is
opened — in an incognito window for incognito routes, in the active
window otherwise.

Compatible with `browse-url-browser-function'; extra arguments are
accepted and ignored."
  (interactive (list (read-string "URL: ")))
  (let* ((url       (seq-reduce (lambda (u fn) (funcall fn u))
                                browsel-browse-url-preprocess-functions
                                url))
         (route     (browsel-url-handler--match-route url))
         ;; No route, no `browsel-default-client': pick a client now
         ;; rather than erroring out.  `browsel--read-client-interactive'
         ;; returns the sole connected client when there is only one,
         ;; prompts the user when there are several, and stores the
         ;; chosen value into `browsel-default-client' so the next
         ;; URL doesn't ask again.  It signals `user-error' when no
         ;; client is connected at all — same end state as before,
         ;; clearer message.
         (client    (or (plist-get route :client)
                        browsel-default-client
                        (browsel--read-client-interactive)))
         (incognito (plist-get route :incognito))
         ;; Routing (which client) and tab matching (which existing
         ;; tab) follow different rules.  The route's `:pattern' is
         ;; only for deciding the client; tab matching defaults to
         ;; URL substring — the tab URL must fully contain the
         ;; requested URL.  An explicit `:tab-match' overrides.
         (tab-match (or (plist-get route :tab-match)
                        (if (browsel-url-handler--bare-domain-p url)
                            ;; Bare-domain shortcut: the host (minus
                            ;; `www.') is the needle, so a bare
                            ;; `amazon.ca/' still focuses an open
                            ;; `www.amazon.ca/...' tab.
                            (let ((d (browsel-url-handler--domain url)))
                              (and d (regexp-quote d)))
                          ;; URL with a path: tab URL must contain the
                          ;; full requested URL.  Sub-pages of the
                          ;; requested URL still count (`.../foo'
                          ;; focuses a tab on `.../foo/issues/3'),
                          ;; but unrelated pages on the same domain
                          ;; do not.
                          (regexp-quote url)))))
    (cond
     ;; eww short-circuit — no WS bridge, no tab matching; eww's own
     ;; `eww-reuse-buffers' governs whether an existing eww buffer is
     ;; reused.
     ((equal client "eww")
      (eww url))
     (t
      (let ((existing (browsel-url-handler--find-existing-tab
                       url client incognito tab-match)))
        (if existing
            (browsel-url-handler--focus existing client)
          (browsel-url-handler--open-new url client incognito)))))))

(provide 'browsel-url-handler)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-url-handler.el ends here
