;;; browser-gt.el --- WebSocket bridge to a Chrome/Firefox extension  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org
;; URL: https://github.com/dmgerman/browser-gt
;; Version: 0.94
;; Package-Requires: ((emacs "27.1") (websocket "1.13") (org "9.8"))

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

;; Provides a local WebSocket server that exchanges JSON frames with a
;; Chrome (MV3) extension.  Frames carry one of two shapes:
;;
;;   Request : { "id": "<uuid>", "name": "NAME",   "payload": {...} }
;;   Response: { "requestId": "<uuid>",            "payload": {...} }
;;
;; Request names are SCREAMING_SNAKE_CASE.  Incoming requests are
;; dispatched to handlers registered with
;; `browser-gt-register-handler'.  Outgoing requests are made with
;; `browser-gt-request-async' (callback-based) or
;; `browser-gt-request' (sync wrapper using `accept-process-output').
;;
;; Built-in handlers:
;;
;;   ORG_CAPTURE       -- org-capture (template key configurable)
;;   ORG_ROAM_CAPTURE  -- standard org-roam-capture
;;   EWW               -- open URL in eww
;;
;; Per-feature backends register additional handlers:
;;
;;   browser-gt-chatgpt.el  -- CHATGPT
;;   browser-gt-www.el      -- SAVE_PAGE
;;   browser-gt-youtube.el  -- YOUTUBE, YOUTUBE_TRANSCRIPT
;;
;; Usage:
;;   (require 'browser-gt)
;;   (browser-gt-start)   ; start the server
;;   (browser-gt-stop)    ; stop the server

;;; Code:

(require 'websocket)
(require 'json)
(require 'org-id)
(require 'cl-lib)
(require 'subr-x)

;; Forward declarations.  These dynamic variables belong to org-capture and
;; org-roam, which are not necessarily loaded when this file is byte-compiled.
;; Without the defvar declarations a `let' on `org-capture-initial' would be
;; treated as a lexical binding and `org-capture' would never see the value.
(defvar org-capture-initial)
(defvar org-store-link-plist)
(defvar org-capture-link-is-already-stored)
(declare-function org-capture          "org-capture" (&optional goto keys))
(declare-function org-roam-capture-    "ext:org-roam" (&rest args))
(declare-function org-roam-node-create "ext:org-roam" (&rest args))

(defconst browser-gt-version "0.94"
  "Current version of the browser-gt package.")

;;;###autoload
(defun browser-gt-version (&optional here)
  "Return the browser-gt version string.
Interactively, display the version in the echo area.  With prefix
argument HERE, insert the version at point instead.  When called
from Lisp the return value is always the version string."
  (interactive "P")
  (let ((string (format "Browser-gt %s" browser-gt-version)))
    (cond
     (here
      (insert string))
     ((called-interactively-p 'interactive)
      (message "%s" string))))
  browser-gt-version)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar browser-gt-port 9130
  "Port the Chrome server WebSocket server listens on.")

(defvar browser-gt-host 'local
  "Host the WebSocket server binds to.  `local' = 127.0.0.1.")

(defcustom browser-gt-clients-file
  (locate-user-emacs-file "browser-gt-clients.eld")
  "File in which browser-gt remembers instance-UUID → assigned-name mappings.

When two profiles or two installs of the same browser both connect
without a user-set label, arrival order alone would decide which
one becomes `chrome' and which one becomes `chrome-<short>' — and
that order can flip between Emacs sessions, so
`browser-gt-default-client' set to `chrome' would silently target a
different install after a reboot.  This file breaks the tie: the
name assigned to each `instance' UUID is persisted here and reused
whenever that install reconnects, regardless of connection order.

A user-set label always wins over the registry — relabeling in
the extension options page takes effect on the next CLIENT_HELLO
and the new name is what gets remembered from then on.

Format is one elisp form (an alist of `(INSTANCE . NAME)' pairs)
written with `pp'.  The file is safe to delete at any time: the
next hello repopulates it, at the cost of one Emacs session's
worth of arrival-order naming while the registry rebuilds.  Set
to nil to disable persistence entirely."
  :type '(choice (file :tag "File")
                 (const :tag "Disable persistence" nil))
  :group 'browser-gt)

(defvar browser-gt-org-capture-key nil
  "Org-capture template key used by the ORG_CAPTURE handler.
nil means the user selects the template interactively.")

(defcustom browser-gt-default-client nil
  "Name of the connected browser-gt client to address by default.
One of:

  - nil — each browser-gt command auto-detects: the sole connected
    client when only one is connected, prompt-or-error when more
    than one.
  - a string returned by `browser-gt-connected-clients' — typically
    \"chrome\" or \"firefox\".
  - the string \"eww\" — `browser-gt-browse-url' opens URLs in eww
    instead of a connected browser.  This applies only to URL
    routing; every other browser-gt helper (insert-selection,
    scroll-page, tab-manager, chatgpt, youtube, …) needs a real
    WS-bridge client and falls back to single-connected /
    prompt-on-ambiguity when this value is \"eww\".

This is the single user-wide default used by every browser-gt
command that needs to pick a client.  Set once in your config
and the multi-client prompt disappears.  Change it mid-session
with `M-x browser-gt-set-default-client' (prefix arg clears it back
to nil).  The assumption is that interactive use targets one
browser at a time; programmatic callers can still talk to either
browser by passing an explicit CLIENT to the helpers."
  :type '(choice (const  :tag "Auto / prompt on ambiguity" nil)
                 (const  :tag "Internal eww" "eww")
                 (string :tag "Client name"))
  :group 'browser-gt)

(defvar browser-gt-request-timeout 10
  "Seconds to wait for a response to an Emacs-initiated request before timing out.")

(defvar browser-gt-eval-request-timeout 30
  "Seconds to wait for `EVAL_IN_ACTIVE_TAB' before timing out.
Overrides `browser-gt-request-timeout' for eval requests only.  Set
to match the browser-side consent auto-deny (30 s in
`extension/src/consent.js') so the elisp side does not give up
before the user has a chance to respond to the consent overlay.")

(defvar browser-gt-eval-consent-hint-delay 1.5
  "Seconds to wait before hinting that the consent overlay may need action.
When an `EVAL_IN_ACTIVE_TAB' request has not returned within this
many seconds, `browser-gt-request-async' emits a message reminding the
user that the in-page consent overlay may be waiting for a click.
The hint is cancelled the moment the response arrives, so requests
against tabs that already have consent never trigger it.")

(defvar browser-gt-client-connected-functions nil
  "Abnormal hook run when a browser client completes CLIENT_HELLO.
Each function is called with one argument: the client's final
display name (a string, as returned by `browser-gt-connected-clients').
The client is already in `browser-gt--clients' by the time the hook
fires, so `browser-gt-browser-tabs' and the other client-name-based
APIs will find it.  Use this hook to trigger post-connect setup:
refresh a cached tab list, notify the user, open the tab manager,
etc.")

(defvar browser-gt-client-disconnected-functions nil
  "Abnormal hook run when a browser client's WebSocket closes.
Each function is called with one argument: the client's display
name (a string).  The client has already been removed from
`browser-gt--clients' by the time the hook fires, so
`browser-gt-connected-clients' will not include the name.  If a socket
closes before CLIENT_HELLO ever completed the client had no
assigned name and the hook is not run.")

(defvar browser-gt-debug nil
  "When non-nil, log every WebSocket frame to *browser-gt* buffer.")

(defvar browser-gt-debug-timing nil
  "When non-nil, log per-stage latency breakdown for every slow request.
Uses timing stamps attached to Chrome responses by the extension (see
`ai/slow-random-response-time.md').  A request is considered slow when
its total wall-clock time exceeds `browser-gt-slow-request-threshold'.
When the flag is nil the advice still fires the slow-line message on
slow requests but omits the per-stage breakdown.")

(defvar browser-gt-slow-request-threshold 0.5
  "Seconds above which `browser-gt-request' logs a slow-line to *Messages*.
Set to a small positive number to catch outliers; set to nil to
suppress the slow-line entirely.")

(defvar browser-gt--last-response-timing nil
  "Timing plist from the most recent WebSocket response frame.
Populated by `browser-gt--handle-response' from the wire-level
`:__timing' field (see `ai/slow-random-response-time.md').  Read by
`browser-gt--timing-advice'; not part of the public API.")

(defvar browser-gt-pandoc-executable "pandoc"
  "Path to the pandoc executable used for HTML → org conversion.
Shared by browser-gt-www and browser-gt-chatgpt backends.")

(defvar browser-gt-max-message-bytes (* 64 1024 1024)
  "Maximum bytes a single WebSocket message may accumulate to.
Page-html and ChatGPT-turns payloads are inherently large, so this is
set high (64 MiB) by default — large enough for any plausible page
save, low enough that a stuck or hostile sender cannot grow Emacs's
heap unbounded.  A client whose pending message exceeds this limit is
disconnected and its accumulator dropped; a fresh connection is
required to retry.  Set to nil to disable the cap.")

(defcustom browser-gt-clients-needing-activation
  '("firefox")
  "Browser-gt client names whose macOS app needs an explicit foreground nudge.
Chrome activates itself via its WebExtension API when its window
is focused; Firefox on macOS does not, hence the fallback.  Clients
not in this list are left alone — Chrome's main process isn't even
the one holding the WebSocket (a helper is), so a PID-based
activation against it would be a no-op anyway.

Has no effect outside `system-type' `darwin'.  Used by
`browser-gt-activate-client', called from `browser-gt-url-handler' and
`browser-gt-tab-manager' after any window-focusing operation."
  :type '(repeat (string :tag "Browser-gt client"))
  :group 'browser-gt)

(defcustom browser-gt-client-app-names
  '(("firefox" . "Firefox"))
  "Alist mapping a browser-gt client name to its macOS application name.
Fallback for clients in `browser-gt-clients-needing-activation' when
the more precise PID-based lookup via `lsof' + `ps' fails to find
the process.  The value is the application's display name as
`open -a' expects it (e.g. \"Firefox\", \"Firefox Developer Edition\")."
  :type '(alist :key-type   (string :tag "Browser-gt client")
                :value-type (string :tag "macOS .app name"))
  :group 'browser-gt)

;; ── State ────────────────────────────────────────────────────────────────────

(defvar browser-gt--server-process nil
  "The `websocket-server' process, or nil if not running.")

(defvar browser-gt--clients nil
  "Alist of currently connected clients as (NAME . WS) pairs.
NAME is the identifier the client announced via CLIENT_HELLO, or
\"unknown-N\" until the client identifies itself.  WS is the
underlying websocket object.")

(defvar browser-gt--client-instances nil
  "Alist mapping websocket → instance UUID string.
Populated by `browser-gt--handle-client-hello' from the extension's
`chrome.storage.local' UUID.  Consulted when a new CLIENT_HELLO
arrives with an INSTANCE already registered on a different ws: the
stale entry is closed and its slot reused, so a reconnecting profile
keeps its name instead of accumulating suffixes.")

(defvar browser-gt--name-registry nil
  "Alist mapping instance UUID → assigned display name.
Persisted to `browser-gt-clients-file' so the same install gets the
same name across Emacs restarts regardless of connection order.
Loaded once on `browser-gt-start' and updated on every CLIENT_HELLO
that yields a naming decision.  A user-set label always overrides
whatever is in here for that instance's next hello.")

(defvar browser-gt--connect-counter 0
  "Monotonic counter for naming unidentified clients.
Reset on `browser-gt-start'; never decrements during a server's
lifetime so two unidentified connections cannot collide on the
same fallback name.")

(defvar browser-gt--current-ws nil
  "Websocket currently being dispatched, bound during handler execution.
Built-in handlers (notably CLIENT_HELLO) read this to discover which
client sent the request.  User-registered handlers should ignore it.")

(defvar browser-gt--handlers nil
  "Alist mapping request name (string) to handler function.
Handler is called with one argument, the request payload (a plist),
and must return a value JSON-encodable as the response payload.")

(defvar browser-gt--pending-callbacks nil
  "Alist mapping outstanding request id (string) to (CALLBACK . TIMER).
CALLBACK is invoked with the decoded response payload.  TIMER is the
`run-at-time' timer that aborts the request on timeout.")

(defvar browser-gt--rx-buffers nil
  "Per-client accumulators for in-progress fragmented messages.
Alist mapping each client websocket to the bytes received so far for
the in-progress fragmented message on that connection.  Cleared once
the final fragment (FIN bit set) arrives or the client disconnects.")

;; ── Debug logging ────────────────────────────────────────────────────────────

(defun browser-gt--log (fmt &rest args)
  "Append FMT formatted with ARGS to *browser-gt* when debug is enabled."
  (when browser-gt-debug
    (with-current-buffer (get-buffer-create "*browser-gt*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S.%3N] ")
              (apply #'format fmt args)
              "\n"))))

(defun browser-gt--warn (fmt &rest args)
  "Surface a browser-gt warning to the user and the debug log.
FMT and ARGS are passed through `format'.  The formatted message is
emitted to *Messages* and appended to the *browser-gt* debug
buffer."
  (let ((msg (apply #'format fmt args)))
    (message "Browser-gt: %s" msg)
    (browser-gt--log "[WARN] %s" msg)))

;; ── Name-registry persistence ────────────────────────────────────────────────
;;
;; The registry maps instance UUID → last-assigned display name.  It
;; is loaded on `browser-gt-start' and saved on every hello that touches
;; it (and once more on `browser-gt-stop').  The file format is a single
;; elisp form so the file is diff-friendly and hand-editable in a
;; pinch; the header comment reminds a future reader why it exists.

(defconst browser-gt--registry-file-header
  ";; -*- mode: emacs-lisp; coding: utf-8; -*-\n\
;; browser-gt client-name registry — auto-generated, do NOT edit by hand.\n\
;; Maps per-install `instance' UUIDs to the display names Emacs\n\
;; assigned them, so the same install keeps its name across\n\
;; sessions regardless of connection order.  Delete this file to\n\
;; reset; the next hello will repopulate it.  See\n\
;; `browser-gt-clients-file' for the full rationale.\n\n"
  "Header comment prepended to `browser-gt-clients-file'.")

(defun browser-gt--load-name-registry ()
  "Return the persisted name registry as an alist, or nil.
Reads `browser-gt-clients-file'.  Returns nil when the file is
missing, unreadable, empty, or its contents are not an alist —
each case is a soft failure that a warning surfaces once; the
server keeps running with an empty registry."
  (let ((file browser-gt-clients-file))
    (cond
     ((or (null file) (not (file-exists-p file)))
      nil)
     ((not (file-readable-p file))
      (browser-gt--warn "clients file %s not readable; using empty registry" file)
      nil)
     (t
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (let ((form (read (current-buffer))))
              (if (and (listp form)
                       (seq-every-p (lambda (c) (and (consp c)
                                                     (stringp (car c))
                                                     (stringp (cdr c))))
                                    form))
                  form
                (browser-gt--warn "clients file %s malformed; using empty registry"
                               file)
                nil)))
        (error
         (browser-gt--warn "could not read clients file %s: %s; using empty registry"
                        file (error-message-string err))
         nil))))))

(defun browser-gt--save-name-registry ()
  "Persist `browser-gt--name-registry' to `browser-gt-clients-file' atomically.
Writes to a sibling `.tmp' file first, then renames — so a crash
mid-write leaves the previous good file intact.  No-op when
`browser-gt-clients-file' is nil (persistence disabled) or when the
registry is empty and no file exists yet (avoids creating an empty
file for users who never hit a hello)."
  (let ((file browser-gt-clients-file))
    (when (and file
               (or browser-gt--name-registry (file-exists-p file)))
      (condition-case err
          (let ((tmp (concat file ".tmp")))
            (with-temp-file tmp
              (insert browser-gt--registry-file-header)
              (let ((print-level  nil)
                    (print-length nil))
                (pp browser-gt--name-registry (current-buffer))))
            (rename-file tmp file t))
        (error
         (browser-gt--warn "could not save clients file %s: %s"
                        file (error-message-string err)))))))

(defun browser-gt--registry-set (instance name)
  "Set (INSTANCE . NAME) in the registry and persist.
Removes any prior binding for INSTANCE before inserting the new
pair, so the alist stays flat.  Persistence is best-effort — a
save failure warns but does not abort the hello."
  (setq browser-gt--name-registry
        (cons (cons instance name)
              (cl-remove-if (lambda (c) (equal (car c) instance))
                            browser-gt--name-registry)))
  (browser-gt--save-name-registry))

(defun browser-gt--registry-clear (instance)
  "Remove INSTANCE from the registry and persist.
Called from `browser-gt--handle-client-hello' when a labeled hello
arrives — the registry only remembers default-case assignments,
so any prior entry for INSTANCE is stale once the user has
declared a label.  No-op when INSTANCE is not present."
  (when (assoc instance browser-gt--name-registry)
    (setq browser-gt--name-registry
          (cl-remove-if (lambda (c) (equal (car c) instance))
                        browser-gt--name-registry))
    (browser-gt--save-name-registry)))

;; ── Server lifecycle ─────────────────────────────────────────────────────────

;;;###autoload
(defun browser-gt-start ()
  "Start the browser-gt WebSocket server on `browser-gt-port'.
A failure to bind the port (another Emacs already holds it,
permission denied, etc.) is downgraded to a warning: the server
stays disabled and `browser-gt--server-process' remains nil rather
than propagating an error to the caller.  This keeps a broken
port from crashing an init.el `browser-gt-start' call — the user can
fix the underlying condition and re-invoke."
  (interactive)
  (when (and browser-gt--server-process
             (not (eq (process-status browser-gt--server-process) 'closed)))
    (browser-gt-stop))
  (setq browser-gt--clients nil
        browser-gt--client-instances nil
        browser-gt--connect-counter 0
        browser-gt--pending-callbacks nil
        browser-gt--name-registry (browser-gt--load-name-registry)
        browser-gt--server-process nil)
  (condition-case err
      (progn
        (setq browser-gt--server-process
              (websocket-server
               browser-gt-port
               :host browser-gt-host
               :on-open    #'browser-gt--on-open
               :on-close   #'browser-gt--on-close
               :on-message #'browser-gt--on-message
               :on-error   #'browser-gt--on-error))
        (browser-gt--log "[SERVER] started on port %d" browser-gt-port)
        (message "Browser-gt WebSocket server started on port %d" browser-gt-port))
    (error
     (setq browser-gt--server-process nil)
     (browser-gt--warn
      "could not bind port %d: %s. \
Server is disabled; fix the condition (typically another Emacs \
holding the port) and re-run `M-x browser-gt-start'."
      browser-gt-port (error-message-string err)))))

;;;###autoload
(defun browser-gt-stop ()
  "Stop the Chrome server WebSocket server."
  (interactive)
  (when browser-gt--server-process
    (websocket-server-close browser-gt--server-process)
    (setq browser-gt--server-process nil))
  (browser-gt--cancel-all-pending "server stopped")
  (browser-gt--save-name-registry)
  (setq browser-gt--clients nil
        browser-gt--client-instances nil
        browser-gt--connect-counter 0)
  (browser-gt--log "[SERVER] stopped")
  (message "Chrome server stopped"))

;; ── Connection callbacks ─────────────────────────────────────────────────────

(defun browser-gt--on-open (ws)
  "Register newly connected client WS under a placeholder name.
The client should send a CLIENT_HELLO request as its first frame to
replace the placeholder with a stable identifier."
  (let ((name (format "unknown-%d" (cl-incf browser-gt--connect-counter))))
    (setq browser-gt--clients
          (cons (cons name ws) browser-gt--clients))
    (browser-gt--log "[CONNECT] %s (clients=%d)"
                        name (length browser-gt--clients))))

(defun browser-gt--on-close (ws)
  "Remove disconnected client WS and drop its rx buffer and instance record."
  (let ((cell (rassq ws browser-gt--clients)))
    (setq browser-gt--clients
          (cl-remove-if (lambda (c) (eq (cdr c) ws)) browser-gt--clients)
          browser-gt--client-instances
          (cl-remove-if (lambda (c) (eq (car c) ws))
                        browser-gt--client-instances)
          browser-gt--rx-buffers
          (cl-remove-if (lambda (c) (eq (car c) ws)) browser-gt--rx-buffers))
    (browser-gt--log "[DISCONNECT] %s (clients=%d)"
                        (if cell (car cell) "?")
                        (length browser-gt--clients))
    (when cell
      (run-hook-with-args 'browser-gt-client-disconnected-functions
                          (car cell)))))

(defun browser-gt--on-error (_ws sym err)
  "Surface WebSocket error ERR in callback SYM."
  (browser-gt--warn "error in %s: %S" sym err))

;; ── Dispatch ─────────────────────────────────────────────────────────────────

(defun browser-gt--drop-client-over-limit (ws combined-len)
  "Drop WS and its rx accumulator; warn that COMBINED-LEN exceeded the cap.
Called from `browser-gt--on-message' when a pending message would push
the per-client accumulator past `browser-gt-max-message-bytes'.  The
accumulator is freed before the close so a stalled close does not
keep the buffer pinned."
  (setq browser-gt--rx-buffers
        (cl-remove-if (lambda (c) (eq (car c) ws)) browser-gt--rx-buffers))
  (browser-gt--warn
   "client message exceeded %d bytes (had %d); dropping connection"
   browser-gt-max-message-bytes combined-len)
  (ignore-errors (websocket-close ws)))

(defun browser-gt--on-message (ws frame)
  "Accumulate FRAME bytes for WS; dispatch once a complete message arrives.
A WebSocket message may be split across many frames (large payloads such
as page HTML routinely run into the hundreds of KB).  We keep a per-client
buffer of frame text and only JSON-parse once the FIN bit is set on the
final frame.  Frames with a `:name' field are requests; frames with a
`:requestId' field are responses to Emacs-initiated requests.
A pending message that would grow past `browser-gt-max-message-bytes'
disconnects the client instead of growing the accumulator further."
  (let* ((text       (or (websocket-frame-text frame) ""))
         (complete-p (websocket-frame-completep frame))
         (prior-cell (assq ws browser-gt--rx-buffers))
         (combined   (concat (cdr prior-cell) text)))
    (cond
     ;; Over the size cap — disconnect and stop accumulating.
     ((and browser-gt-max-message-bytes
           (> (length combined) browser-gt-max-message-bytes))
      (browser-gt--drop-client-over-limit ws (length combined)))
     ;; Still receiving — stash and wait.
     ((not complete-p)
      (if prior-cell
          (setcdr prior-cell combined)
        (setq browser-gt--rx-buffers
              (cons (cons ws combined) browser-gt--rx-buffers)))
      (browser-gt--log "[RECV-CONT] +%d byte(s); total=%d"
                          (length text) (length combined)))
     ;; Final fragment — drop the accumulator and dispatch.
     (t
      (when prior-cell
        (setq browser-gt--rx-buffers
              (cl-remove-if (lambda (c) (eq (car c) ws))
                            browser-gt--rx-buffers)))
      (browser-gt--log "[RECV] %d byte(s)" (length combined))
      (let ((msg (condition-case err
                     (json-parse-string combined
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil)
                   (error
                    (browser-gt--warn "could not parse frame as JSON: %s"
                                         (error-message-string err))
                    nil))))
        (cond
         ((null msg) nil)
         ((plist-get msg :name)
          (browser-gt--handle-request ws msg))
         ((plist-get msg :requestId)
          (browser-gt--handle-response msg))
         (t
          (browser-gt--warn "unknown frame shape (no :name or :requestId): %S"
                               msg))))))))

(defun browser-gt--handle-request (ws msg)
  "Look up handler for MSG and send the response back over WS."
  (let* ((name    (plist-get msg :name))
         (id      (or (plist-get msg :id) "<unknown>"))
         (payload (plist-get msg :payload))
         (handler (cdr (assoc name browser-gt--handlers))))
    (let ((response-payload
           (if handler
               (condition-case err
                   (let ((browser-gt--current-ws ws))
                     (funcall handler payload))
                 (error
                  (browser-gt--warn "handler %s signalled: %s"
                                       name (error-message-string err))
                  `((status . "error")
                    (message . ,(error-message-string err)))))
             (progn
               (browser-gt--warn "no handler registered for request: %s"
                                    name)
               `((status . "error")
                 (message . ,(format "Unknown request: %s" name)))))))
      ;; Surface the handler's status line to the user.  Errors are
      ;; already reported via `browser-gt--warn' in the error path
      ;; above, so we only message on success here to avoid duplicates.
      (let ((status (alist-get 'status response-payload))
            (text   (alist-get 'message response-payload)))
        (when (and text (equal status "ok"))
          (message "Browser-gt [%s]: %s" name text)))
      (browser-gt--send-to ws
                              `((requestId . ,id)
                                (payload   . ,response-payload))))))

(defun browser-gt--handle-response (msg)
  "Invoke the pending callback for MSG's requestId.
If no pending callback matches (likely already timed out), surfaces a warning."
  (let* ((id   (plist-get msg :requestId))
         (cell (assoc id browser-gt--pending-callbacks)))
    (if (null cell)
        (browser-gt--warn "response for unknown/timed-out request id: %s" id)
      (let ((callback (cadr cell))
            (timer    (cddr cell)))
        (when (timerp timer) (cancel-timer timer))
        (setq browser-gt--pending-callbacks
              (cl-remove-if (lambda (c) (equal (car c) id))
                            browser-gt--pending-callbacks))
        ;; Stash the wire-level :__timing (Chrome-only, may be nil) so
        ;; the sync `browser-gt-request' path can hand it to
        ;; `browser-gt--timing-advice' after the callback returns.
        ;; See ai/slow-random-response-time.md.
        (setq browser-gt--last-response-timing (plist-get msg :__timing))
        (condition-case err
            (funcall callback (plist-get msg :payload))
          (error
           (browser-gt--warn "response callback for %s signalled: %s"
                                id (error-message-string err))))))))

;; ── Sending ──────────────────────────────────────────────────────────────────

(defun browser-gt--send-to (ws data)
  "JSON-encode DATA and send it on WS."
  (let ((text (json-encode data)))
    (browser-gt--log "[SEND] %s" text)
    (websocket-send-text ws text)))

(defun browser-gt--target-for (client name)
  "Resolve a request target without signalling.
Returns one of:
  (ok   . WS)  — send to WS.
  (err  . MSG) — abort: caller-supplied CLIENT not connected, or
                 multiple clients are connected and CLIENT is nil.
  (none . MSG) — no clients connected at all.
NAME appears in MSG and is informational only."
  (cond
   (client
    (let ((cell (assoc client browser-gt--clients)))
      (if cell
          (cons 'ok (cdr cell))
        (cons 'err
              (format
               "requested client %S is not connected (connected: %s)"
               client
               (if browser-gt--clients
                   (mapconcat #'car browser-gt--clients ", ")
                 "none"))))))
   ((null browser-gt--clients)
    (cons 'none (format "no client connected; dropping request %s" name)))
   ((= 1 (length browser-gt--clients))
    (cons 'ok (cdar browser-gt--clients)))
   (t
    (cons 'err
          (format "%d clients connected (%s); specify CLIENT for request %S"
                  (length browser-gt--clients)
                  (mapconcat #'car browser-gt--clients ", ")
                  name)))))

(defun browser-gt-connected-clients ()
  "Return the list of connected client names, in connection order (newest first)."
  (mapcar #'car browser-gt--clients))

;; ── Public browser API ───────────────────────────────────────────────────────
;;
;; `browser-gt-browsers' and `browser-gt-browser-tabs' are the stable
;; entry points other packages should build on.  They speak in the
;; user-facing "browser" vocabulary, hide the internal alists, and
;; validate their inputs.  `browser-gt-connected-clients' remains for
;; cheap name-only enumeration.

(defun browser-gt--client-instance-for-ws (ws)
  "Return the instance UUID recorded for WS, or nil."
  (cdr (assq ws browser-gt--client-instances)))

(defun browser-gt--client-instance-for-name (name)
  "Return the instance UUID recorded for the browser named NAME, or nil."
  (browser-gt--client-instance-for-ws
   (cdr (assoc name browser-gt--clients))))

(defun browser-gt-browsers ()
  "Return the connected browsers as a list of plists.
Each plist has:
  :name      — display name (also returned by `browser-gt-connected-clients').
  :instance  — per-install UUID string, stable across reconnects
               (see `browser-gt-clients-file').
Order matches `browser-gt-connected-clients' (newest connection first).
Downstream packages should prefer this over
`browser-gt-connected-clients' when they need to persist a reference
to a specific install across sessions."
  (mapcar (lambda (cell)
            (list :name     (car cell)
                  :instance (browser-gt--client-instance-for-ws (cdr cell))))
          browser-gt--clients))

(defun browser-gt--normalize-browsers (browsers)
  "Resolve BROWSERS to a validated list of connected browser names.
BROWSERS is one of: nil (every connected browser), a name string
\(wrap in a one-element list), or a list of name strings (each
must be connected).  Signals `user-error' when no browser is
connected, or when any requested name is not currently connected."
  (let ((all (browser-gt-connected-clients)))
    (cond
     ((null browsers)
      (or all (user-error "Browser-gt: no browser connected")))
     ((stringp browsers)
      (browser-gt--normalize-browsers (list browsers)))
     ((listp browsers)
      (let ((missing (seq-remove (lambda (b) (member b all)) browsers)))
        (when missing
          (user-error
           "Browser-gt: not connected: %s (connected: %s)"
           (mapconcat #'identity missing ", ")
           (if all (mapconcat #'identity all ", ") "none"))))
      browsers)
     (t
      (user-error
       "Browser-gt: BROWSERS must be nil, a string, or a list of strings; got %S"
       browsers)))))

(defun browser-gt-browser-tabs (&optional browsers)
  "Return open tabs from the connected browsers.
BROWSERS narrows the query:
  - nil          — every entry in `browser-gt-connected-clients'.
  - name string  — that single browser only.
  - list of strings — every browser in the list.

Each returned element is the extension's raw tab plist extended
with two browser-gt-specific keys:
  :browser-gt-browser  — the browser name that owns the tab (same
                      shape as `browser-gt-connected-clients' entries
                      and safe to pass to `browser-gt-request').
  :browser-gt-instance — the browser's per-install UUID, stable
                      across reconnects.
Signals `user-error' when no browser is connected, or when any
requested name is not connected.

Requests are issued sequentially — parallel would need
`browser-gt-request-async' callback juggling and tab enumeration is
fast enough that the extra complexity is not worth it for the two
or three browsers this package is designed for.  A failing
browser is logged via `message' and its tabs are omitted; the
caller sees an empty list only when every queried browser failed."
  (let ((selected (browser-gt--normalize-browsers browsers)))
    (apply #'append
           (mapcar
            (lambda (name)
              (let ((instance (browser-gt--client-instance-for-name name)))
                (condition-case err
                    (mapcar (lambda (tab)
                              (append tab
                                      (list :browser-gt-browser  name
                                            :browser-gt-instance instance)))
                            (browser-gt-request "GET_ALL_TABS" nil name))
                  (error
                   (message "Browser-gt: %s failed: %s"
                            name (error-message-string err))
                   nil))))
            selected))))

(defun browser-gt-focus-tab (tab &optional focus-window)
  "Focus TAB in the browser that owns it.
TAB is a plist as returned by `browser-gt-browser-tabs' — it must
carry both `:id' (the browser's numeric tab id) and
`:browser-gt-browser' (the owning browser's name).  FOCUS-WINDOW
non-nil also raises the browser's OS window so the tab becomes
visually foreground, and on macOS nudges the browser app itself
via `browser-gt-activate-client' for browsers listed in
`browser-gt-clients-needing-activation'.

Signals `user-error' when TAB lacks either required key, or when
its owning browser is not currently connected.

Returns the browser-side response payload plist: `(:status \"ok\")'
on success, `(:status \"error\" :message MSG)' when the browser
rejected the request (typically because the tab id no longer
exists — the tab was closed between fetch and focus).  Callers
that want to react to \"tab is gone\" should check
`(plist-get response :status)'."
  (let ((id      (plist-get tab :id))
        (browser (plist-get tab :browser-gt-browser)))
    (unless (numberp id)
      (user-error "Browser-gt-focus-tab: TAB has no numeric :id"))
    (unless (and (stringp browser) (not (string-empty-p browser)))
      (user-error "Browser-gt-focus-tab: TAB has no :browser-gt-browser"))
    (unless (member browser (browser-gt-connected-clients))
      (user-error
       "Browser-gt-focus-tab: browser %S is not connected (connected: %s)"
       browser
       (let ((all (browser-gt-connected-clients)))
         (if all (mapconcat #'identity all ", ") "none"))))
    (let ((response
           (browser-gt-request "FOCUS_TAB"
                            (if focus-window
                                `(:id ,id :focusWindow t)
                              `(:id ,id))
                            browser)))
      (when (and focus-window
                 (equal (plist-get response :status) "ok"))
        (browser-gt-activate-client browser))
      response)))

(defun browser-gt-close-tab (tab)
  "Close TAB in the browser that owns it.
TAB is a plist as returned by `browser-gt-browser-tabs' — it must
carry both `:id' (the browser's numeric tab id) and
`:browser-gt-browser' (the owning browser's name).

Signals `user-error' when TAB lacks either required key, or when
its owning browser is not currently connected.

Returns the browser-side response payload plist: `(:status \"ok\")'
on success, `(:status \"error\" :message MSG)' when the browser
rejected the request (typically because the tab id no longer
exists — the tab was closed between fetch and close).  Callers
that want to distinguish \"closed by us\" from \"already gone\"
should check `(plist-get response :status)'.

Note: `chrome.tabs.remove' bypasses any in-page `beforeunload'
prompt — those only fire from user-initiated UI closes — so
pages with unsaved form state close without a dialog.  Firefox
behaves the same way."
  (let ((id      (plist-get tab :id))
        (browser (plist-get tab :browser-gt-browser)))
    (unless (numberp id)
      (user-error "Browser-gt-close-tab: TAB has no numeric :id"))
    (unless (and (stringp browser) (not (string-empty-p browser)))
      (user-error "Browser-gt-close-tab: TAB has no :browser-gt-browser"))
    (unless (member browser (browser-gt-connected-clients))
      (user-error
       "Browser-gt-close-tab: browser %S is not connected (connected: %s)"
       browser
       (let ((all (browser-gt-connected-clients)))
         (if all (mapconcat #'identity all ", ") "none"))))
    (browser-gt-request "CLOSE_TAB" `(:id ,id) browser)))

(defun browser-gt--broadcast (data &optional client)
  "JSON-encode DATA and send it to one connected client.
With CLIENT nil and exactly one client connected, that client is the
target.  With CLIENT a string, the matching named client is targeted.
Returns the websocket the frame was sent on, or nil if the resolution
fails (also surfaces a warning so the failure is not silent)."
  (pcase (browser-gt--target-for client (alist-get 'name data))
    (`(ok . ,ws)
     (browser-gt--send-to ws data)
     ws)
    (`(err . ,msg)
     (browser-gt--warn "%s" msg)
     nil)
    (`(none . ,msg)
     (browser-gt--warn "%s" msg)
     nil)))

;; ── Handler registry ─────────────────────────────────────────────────────────

(defun browser-gt-register-handler (name handler)
  "Register HANDLER as the handler for request NAME.
NAME is a SCREAMING_SNAKE_CASE string.  HANDLER is called with the
request payload (a plist) and must return a value JSON-encodable as the
response payload.  Re-registering overwrites the previous binding."
  (setq browser-gt--handlers
        (cons (cons name handler)
              (cl-remove-if (lambda (c) (string= (car c) name))
                            browser-gt--handlers))))

(defun browser-gt-unregister-handler (name)
  "Remove the handler for request NAME, if any."
  (setq browser-gt--handlers
        (cl-remove-if (lambda (c) (string= (car c) name))
                      browser-gt--handlers)))

;; ── Built-in CLIENT_HELLO handler ────────────────────────────────────────────

(defconst browser-gt--instance-suffix-length 6
  "Number of hex characters from INSTANCE to append on a label collision.
6 leaves ~1 in 16M for a same-label-different-instance collision — well
below the point at which two profiles on one machine would notice.")

(defun browser-gt--resolve-client-name (label instance ws)
  "Return a display name for WS given LABEL and INSTANCE (both non-empty strings).
Returns LABEL when no other ws is registered under it.  On collision,
returns `LABEL-SHORT' where SHORT is the first
`browser-gt--instance-suffix-length' hex characters of INSTANCE.  In the
astronomically-unlikely event that suffix collides too, falls back to
the full `LABEL-INSTANCE'.  WS is permitted to already own LABEL
\(idempotent reuse — a hello arriving for the same ws that is already
mapped)."
  (let ((cell (assoc label browser-gt--clients)))
    (if (or (null cell) (eq (cdr cell) ws))
        label
      (let* ((short   (substring instance 0 browser-gt--instance-suffix-length))
             (name    (concat label "-" short))
             (again   (assoc name browser-gt--clients)))
        (if (or (null again) (eq (cdr again) ws))
            name
          (concat label "-" instance))))))

(defun browser-gt--close-stale-instance-ws (instance new-ws)
  "If INSTANCE is already registered on a ws other than NEW-WS, drop it.
The stale ws is unregistered from every state table and closed.  This
is what makes a reconnecting extension reuse its previous slot instead
of accumulating suffixes — the same INSTANCE arrives on a new ws while
the old ws has not yet been noticed as dead."
  (let ((cell (rassoc instance browser-gt--client-instances)))
    (when (and cell (not (eq (car cell) new-ws)))
      (let* ((stale-ws  (car cell))
             (name-cell (rassq stale-ws browser-gt--clients)))
        (browser-gt--log "[HELLO] instance %s already on stale ws (%s); \
closing and reusing slot"
                            (substring instance 0 browser-gt--instance-suffix-length)
                            (if name-cell (car name-cell) "?"))
        (setq browser-gt--clients
              (cl-remove-if (lambda (c) (eq (cdr c) stale-ws))
                            browser-gt--clients)
              browser-gt--client-instances
              (cl-remove-if (lambda (c) (eq (car c) stale-ws))
                            browser-gt--client-instances)
              browser-gt--rx-buffers
              (cl-remove-if (lambda (c) (eq (car c) stale-ws))
                            browser-gt--rx-buffers))
        (ignore-errors (websocket-close stale-ws))))))

(defun browser-gt--handle-client-hello (payload)
  "Built-in CLIENT_HELLO handler.
Renames the entry for the websocket currently being dispatched using
the LABEL and INSTANCE announced in PAYLOAD.  LABEL is the display
name (user-configurable, defaults to the build's kind).  INSTANCE is
a per-install UUID from the extension's `chrome.storage.local'; it is
stable across reconnects, so a hello arriving with an INSTANCE that
is already registered on a different ws replaces the stale entry
instead of appending a suffix.  On label collision between two
distinct instances, `LABEL-SHORT' is used (see
`browser-gt--resolve-client-name').

The PAYLOAD must include a `:version' string that exactly matches
`browser-gt-version'.  The version check is strict: any mismatch
\(including a missing or empty version) rejects the hello with an
error payload, leaves the client unregistered (its placeholder
\"unknown-N\" name persists), and the extension's ws-client treats
the connection as incompatible and stops the reconnect loop."
  (let ((ws        browser-gt--current-ws)
        (client    (plist-get payload :client))
        (raw-label (plist-get payload :label))
        (instance  (plist-get payload :instance))
        (version   (plist-get payload :version)))
    (unless ws
      (error "CLIENT_HELLO invoked outside a request dispatch"))
    (unless (and (stringp client) (not (string-empty-p client)))
      (error "CLIENT_HELLO requires payload.client (non-empty string)"))
    (unless (and (stringp instance)
                 (>= (length instance) browser-gt--instance-suffix-length))
      (error "CLIENT_HELLO requires payload.instance \
\(string with at least %d chars); got: %S"
             browser-gt--instance-suffix-length instance))
    (unless (and (stringp version) (not (string-empty-p version)))
      (error "CLIENT_HELLO requires payload.version (non-empty string); \
emacs=%s, extension sent: %S" browser-gt-version version))
    (unless (string= version browser-gt-version)
      (error "version mismatch: emacs=%s extension=%s; \
rebuild and reload both sides"
             browser-gt-version version))
    ;; `label-set' means the user actually configured a label in the
    ;; extension options page.  The extension omits the `:label'
    ;; field entirely when unset, so field presence — not equality
    ;; to the client kind — is the honest signal.  Old logic that
    ;; checked (not (string= label client)) could not tell a user
    ;; who deliberately labeled their install \"chrome\" from a user
    ;; who had no label at all, and would re-apply a stale registry
    ;; entry on the second case.
    (let* ((label-set (and (stringp raw-label) (not (string-empty-p raw-label))))
           (label     (if label-set raw-label client)))
      (browser-gt--close-stale-instance-ws instance ws)
      (let* ((final-name (browser-gt--resolve-hello-name
                          label label-set instance ws))
             (others     (cl-remove-if (lambda (c) (eq (cdr c) ws))
                                       browser-gt--clients))
             (other-ins  (cl-remove-if (lambda (c) (eq (car c) ws))
                                       browser-gt--client-instances)))
        (setq browser-gt--clients
              (cons (cons final-name ws) others)
              browser-gt--client-instances
              (cons (cons ws instance) other-ins))
        ;; Registry policy: the registry exists to stabilise default
        ;; naming across sessions.  When the user sets a label the
        ;; default case is irrelevant, so any prior registry entry
        ;; for this instance is stale and gets cleared — that way a
        ;; later label-clear reverts to a fresh default assignment
        ;; instead of resurrecting the label as if it were the
        ;; default.  When the label is unset we record whatever we
        ;; assigned so the same install keeps that name next
        ;; session.
        (if label-set
            (browser-gt--registry-clear instance)
          (browser-gt--registry-set instance final-name))
        (browser-gt--log "[HELLO] %s instance=%s (clients=%d)"
                            final-name
                            (substring instance 0
                                       browser-gt--instance-suffix-length)
                            (length browser-gt--clients))
        (run-hook-with-args 'browser-gt-client-connected-functions final-name)
        `((status . "ok")
          (client . ,final-name))))))

(defun browser-gt--resolve-hello-name (label label-set instance ws)
  "Return the display name for a hello with LABEL and INSTANCE on WS.
LABEL-SET non-nil means the user configured a custom label — the
registry is ignored and `browser-gt--resolve-client-name' picks fresh
so a relabel in the options page takes effect immediately.  Nil
means the label is the default (equal to the client kind); consult
`browser-gt--name-registry' for a remembered name, falling back to
fresh resolution when the remembered name is currently held by
another live ws."
  (or (and (not label-set)
           (let* ((remembered (cdr (assoc instance browser-gt--name-registry)))
                  (cell       (and remembered
                                   (assoc remembered browser-gt--clients))))
             (and remembered
                  (or (null cell) (eq (cdr cell) ws))
                  remembered)))
      (browser-gt--resolve-client-name label instance ws)))

(browser-gt-register-handler "CLIENT_HELLO"
                                #'browser-gt--handle-client-hello)

;; ── Async request primitive (Emacs → browser) ────────────────────────────────

(defun browser-gt--cancel-all-pending (reason)
  "Cancel every pending callback with an error payload citing REASON."
  (let ((pending browser-gt--pending-callbacks))
    (setq browser-gt--pending-callbacks nil)
    (dolist (cell pending)
      (let ((id       (car cell))
            (callback (cadr cell))
            (timer    (cddr cell)))
        (when (timerp timer) (cancel-timer timer))
        (condition-case err
            (funcall callback `(:status "error" :message ,reason))
          (error
           (browser-gt--warn "cancellation callback for %s signalled: %s"
                                id (error-message-string err))))))))

(defun browser-gt--effective-timeout (name)
  "Return the request timeout to use for a request named NAME.
`EVAL_IN_ACTIVE_TAB' uses `browser-gt-eval-request-timeout' so the
elisp side can outlast the browser-side consent overlay auto-deny;
every other request uses `browser-gt-request-timeout'."
  (if (equal name "EVAL_IN_ACTIVE_TAB")
      browser-gt-eval-request-timeout
    browser-gt-request-timeout))

(defun browser-gt--schedule-consent-hint (name)
  "Return a timer that hints about the consent overlay, or nil.
When NAME is `EVAL_IN_ACTIVE_TAB', schedule a message after
`browser-gt-eval-consent-hint-delay' seconds reminding the user that
the in-page consent overlay may be waiting.  Callers must cancel
the returned timer when the request completes so the hint does not
fire spuriously after a quick reply."
  (when (equal name "EVAL_IN_ACTIVE_TAB")
    (run-at-time
     browser-gt-eval-consent-hint-delay nil
     (lambda ()
       (message
        "Browser-gt: waiting on the browser -- if a per-tab consent overlay appeared, grant it to continue")))))

;; ── Stale-target reporting ───────────────────────────────────────────────────
;;
;; Requests carry a tab id read earlier (a `GET_ALL_TABS' snapshot, an
;; org-babel `:tab-id' header), and the tab may be gone by the time the
;; request lands.  Most call sites read only the response's success
;; fields, so such a request used to look like it had worked.

(defconst browser-gt--stale-target-re
  (rx (or (seq "no " (or "tab" "window") " with id " (+ digit))
          "the target tab no longer exists"))
  "Regexp matching an extension error about a tab or window that is gone.
The wording comes from extension/src/stale-tab.js, which normalises
Chrome's and Firefox's differing messages into this one; the two
must be changed together.")

(defun browser-gt--stale-target-message (response)
  "Return RESPONSE's message when it reports a closed tab or window, else nil."
  (let ((status (plist-get response :status))
        (msg    (plist-get response :message)))
    (and (equal status "error")
         (stringp msg)
         (string-match-p browser-gt--stale-target-re msg)
         msg)))

(defun browser-gt--warn-on-stale-target (name response)
  "Warn when RESPONSE to request NAME reports a tab or window that is gone."
  (let ((msg (browser-gt--stale-target-message response)))
    (when msg
      (browser-gt--warn "%s: %s" name msg))))

(defun browser-gt-request-async (name payload callback &optional client)
  "Send a request NAME with PAYLOAD to the browser; invoke CALLBACK on response.
CALLBACK receives the decoded response payload (a plist).  If the
request times out CALLBACK is called with (:status \"error\"
:message \"timeout\").  Returns the request id, or nil if no client
is connected.

The timeout is `browser-gt-request-timeout' by default; requests named
`EVAL_IN_ACTIVE_TAB' use the larger `browser-gt-eval-request-timeout'
so the elisp side outlasts the browser-side consent overlay
auto-deny.  For eval requests, a `browser-gt-eval-consent-hint-delay'
timer also fires a reminder message about the consent overlay
unless the response arrives first.

CLIENT, if non-nil, names which connected client to target (e.g.
\"chrome\", \"firefox\").  When omitted, the request is sent to the
sole connected client; when more than one is connected, CALLBACK is
invoked with a status:error payload and nil is returned."
  (pcase (browser-gt--target-for client name)
    (`(ok . ,ws)
     (let* ((id         (org-id-uuid))
            (hint-timer (browser-gt--schedule-consent-hint name))
            (wrapped    (lambda (response)
                          (when (timerp hint-timer)
                            (cancel-timer hint-timer))
                          (browser-gt--warn-on-stale-target name response)
                          (funcall callback response)))
            (timer      (run-at-time (browser-gt--effective-timeout name) nil
                                     #'browser-gt--timeout-request id)))
       (setq browser-gt--pending-callbacks
             (cons (cons id (cons wrapped timer))
                   browser-gt--pending-callbacks))
       (browser-gt--send-to ws
                               `((id      . ,id)
                                 (name    . ,name)
                                 (payload . ,(or payload :null))))
       id))
    (`(err . ,msg)
     (browser-gt--warn "%s" msg)
     (funcall callback `(:status "error" :message ,msg))
     nil)
    (`(none . ,msg)
     (browser-gt--warn "%s" msg)
     (funcall callback '(:status "error" :message "no client connected"))
     nil)))

(defun browser-gt--timeout-request (id)
  "Time out the pending request with ID."
  (let ((cell (assoc id browser-gt--pending-callbacks)))
    (when cell
      (setq browser-gt--pending-callbacks
            (cl-remove-if (lambda (c) (equal (car c) id))
                          browser-gt--pending-callbacks))
      (browser-gt--warn "request %s timed out after %ss"
                           id browser-gt-request-timeout)
      (condition-case err
          (funcall (cadr cell) '(:status "error" :message "timeout"))
        (error
         (browser-gt--warn "timeout callback for %s signalled: %s"
                              id (error-message-string err)))))))

(defun browser-gt-request (name &optional payload client)
  "Synchronously send NAME/PAYLOAD to the browser and return the response payload.
Blocks via `accept-process-output' until the response arrives or the
timeout elapses.  Signals an error on timeout, when no client is
connected, when more than one client is connected and CLIENT was not
supplied, or when CLIENT names a client that is not connected.
Do NOT use this from inside a websocket callback — it can re-enter
the dispatcher.

CLIENT, if non-nil, names the client to target (e.g. \"chrome\",
\"firefox\").  See `browser-gt-connected-clients' for the current
roster."
  (catch 'browser-gt--result
    (let ((id (browser-gt-request-async
               name payload
               (lambda (response)
                 (throw 'browser-gt--result response))
               client)))
      (unless id
        ;; Request-async already warned and invoked the callback with a
        ;; status:error payload, so escalate to an error here too.
        (error "Browser-gt-request: no acceptable target for %s" name))
      (let ((deadline (+ (float-time)
                         (+ 0.5 (browser-gt--effective-timeout name)))))
        (cl-labels
            ((pump ()
               (cond
                ((> (float-time) deadline)
                 (if (equal name "EVAL_IN_ACTIVE_TAB")
                     (user-error "Browser-gt: request %s timed out (did the per-tab consent overlay appear?  Grant consent and try again)"
                                 name)
                   (error "Request %s timed out" name)))
                (t
                 (accept-process-output nil 0.05)
                 (pump)))))
          (pump))))))

;; ── Diagnostic timing advice ─────────────────────────────────────────────────
;;
;; Diagnostic scaffolding for the intermittent multi-second stalls
;; documented in ai/slow-random-response-time.md.  The advice is
;; installed unconditionally but only emits a *Messages* line when the
;; observed wall-clock time exceeds `browser-gt-slow-request-threshold'.
;; When `browser-gt-debug-timing' is non-nil AND the extension attached a
;; `:__timing' plist to the response frame, a per-stage breakdown is
;; appended so latency can be attributed to WS transport, offscreen
;; -> SW hop, in-SW dispatch, chrome.* API, or return trip.
;;
;; Revert plan (see slow-random-response-time.md): delete
;; `browser-gt-debug-timing', `browser-gt-slow-request-threshold',
;; `browser-gt--last-response-timing', `browser-gt--format-timing-deltas',
;; `browser-gt--timing-advice', and the `advice-add' call below; drop the
;; matching setq in `browser-gt--handle-response'.

(defun browser-gt--format-timing-deltas (t0-float timing dt-total)
  "Return a one-line per-stage breakdown for TIMING or nil.
T0-FLOAT is the pre-send `float-time' (seconds).  TIMING is the plist
extracted from the response's `:__timing' field (`:t1' .. `:t4'
in `Date.now' milliseconds; a Chrome-only field, may be nil).
DT-TOTAL is the total wall-clock seconds already measured by the
caller; the return-trip delta is derived as dt-total minus the
sum of the other deltas so all five sum to the observed total."
  (when timing
    (let* ((t0-ms (* 1000.0 t0-float))
           (t1    (plist-get timing :t1))
           (t2    (plist-get timing :t2))
           (t3    (plist-get timing :t3))
           (t4    (plist-get timing :t4)))
      (when (and (numberp t1) (numberp t2) (numberp t3) (numberp t4))
        (let* ((d-ws       (max 0 (- t1 t0-ms)))       ; t1 - t0
               (d-hop      (max 0 (- t2 t1)))          ; t2 - t1
               (d-dispatch (max 0 (- t3 t2)))          ; t3 - t2
               (d-api      (max 0 (- t4 t3)))          ; t4 - t3
               (d-return   (max 0 (- (* 1000.0 dt-total)
                                     (+ d-ws d-hop d-dispatch d-api)))))
          (format "[ws=%.0fms hop=%.0fms disp=%.0fms api=%.0fms ret=%.0fms]"
                  d-ws d-hop d-dispatch d-api d-return))))))

(defun browser-gt--timing-advice (orig name &rest args)
  "Around advice on `browser-gt-request' that logs slow requests.
ORIG is the original function, NAME the request name, ARGS the
remaining args.  See ai/slow-random-response-time.md."
  (let ((t0 (float-time))
        ;; Clear before the call so a stale value from a prior request
        ;; cannot leak into this one's breakdown.
        (browser-gt--last-response-timing nil))
    (unwind-protect
        (let ((result (apply orig name args)))
          (let* ((dt        (- (float-time) t0))
                 (threshold browser-gt-slow-request-threshold)
                 (slow?     (and (numberp threshold) (> dt threshold))))
            (when slow?
              (let ((breakdown (and browser-gt-debug-timing
                                    (browser-gt--format-timing-deltas
                                     t0 browser-gt--last-response-timing dt))))
                (message "[browser-gt slow] %s took %.3fs @ %s%s"
                         name dt (format-time-string "%FT%T")
                         (if breakdown (concat " " breakdown) ""))))
            result))
      ;; Ensure the stash does not linger past this call even on error.
      (setq browser-gt--last-response-timing nil))))

(advice-add 'browser-gt-request :around #'browser-gt--timing-advice)

;; ── Convenience: respond-fast-then-defer ─────────────────────────────────────

(defun browser-gt-defer (fn &rest args)
  "Schedule FN to run with ARGS on the next idle tick.
Use inside a handler that wants to return immediately while the real
work happens out-of-band."
  (run-at-time 0 nil (lambda () (apply fn args))))

;; ── Payload cache (preserved across the rewrite) ─────────────────────────────
;;
;; Templates pull these via %(browser-gt-get-url) etc.  The variables
;; are populated by `browser-gt--prime-payload-cache' inside each
;; capture handler.

(defvar browser-gt--current-url nil
  "URL from the most recent browser-gt payload.")

(defvar browser-gt--current-title nil
  "Title from the most recent browser-gt payload.")

(defvar browser-gt--current-text nil
  "Selected text from the most recent browser-gt payload.")

(defun browser-gt-get-url ()
  "Return the URL from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browser-gt--current-url "")
    (setq browser-gt--current-url nil)))

(defun browser-gt-get-title ()
  "Return the title from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browser-gt--current-title "")
    (setq browser-gt--current-title nil)))

(defun browser-gt-get-selection ()
  "Return the selected text from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browser-gt--current-text "")
    (setq browser-gt--current-text nil)))

(defun browser-gt--prime-payload-cache (payload)
  "Populate the payload cache vars from PAYLOAD."
  (setq browser-gt--current-url   (plist-get payload :url)
        browser-gt--current-title (or (plist-get payload :title) "")
        browser-gt--current-text  (or (plist-get payload :text)  "")))

;; ── Shared helpers ───────────────────────────────────────────────────────────

(defun browser-gt--maybe-raise (payload)
  "Raise and focus the selected Emacs frame if PAYLOAD's :raise is t."
  (when (eq (plist-get payload :raise) t)
    (select-frame-set-input-focus (selected-frame))))

;; ── Client process activation (macOS) ────────────────────────────────────────
;;
;; Chrome activates its window via the WebExtension API on macOS;
;; Firefox often does not.  After a `FOCUS_TAB' that requested
;; `:focusWindow t', call `browser-gt-activate-client' to bring the
;; specific browser process to the OS foreground.  The PID-based
;; lookup disambiguates multiple instances of the same browser
;; (several Firefox profiles, for example).

(defun browser-gt--lsof-client-pids ()
  "Return the PIDs of processes connected OUT to `browser-gt-port'.
A connection's client row is the one whose NAME field's remote
endpoint is `:browser-gt-port'.  Filtering by the direction of the
arrow avoids confusing the server side (Emacs) with the clients.
Returns nil when `lsof' is unavailable or no connections exist."
  (let* ((remote (format "->127.0.0.1:%d" browser-gt-port))
         (raw    (with-temp-buffer
                   (when (zerop (call-process "lsof" nil t nil
                                              "-nP"
                                              (format "-iTCP:%d" browser-gt-port)
                                              "-sTCP:ESTABLISHED"))
                     (buffer-string)))))
    (and raw
         (seq-filter
          #'identity
          (mapcar
           (lambda (line)
             (and (string-match-p (regexp-quote remote) line)
                  (let ((fields (split-string line)))
                    (and (>= (length fields) 2)
                         (string-match-p "\\`[0-9]+\\'" (nth 1 fields))
                         (string-to-number (nth 1 fields))))))
           (split-string raw "\n" t))))))

(defun browser-gt--pid-command (pid)
  "Return the full command line of PID via `ps', or nil on failure.
`ps -o command=' prints the executable path plus arguments without
truncating, which is how we tell `Google Chrome' apart from any
other process whose `lsof' COMMAND field was clipped to 9 chars."
  (with-temp-buffer
    (and (zerop (call-process "ps" nil t nil
                              "-p" (number-to-string pid)
                              "-o" "command="))
         (let ((s (string-trim (buffer-string))))
           (and (not (string-empty-p s)) s)))))

(defun browser-gt--client-pid (client)
  "Return the PID of the process connected to browser-gt as CLIENT, or nil.
Walks every established outbound TCP connection to `browser-gt-port',
asks `ps' for each candidate's full command line, and picks the
first whose path contains CLIENT (case-insensitive substring).
Disambiguates between multiple instances of the same browser
\(e.g. several Firefox profiles): each instance has a distinct PID
and only one of them holds the WebSocket to Emacs."
  (when (eq system-type 'darwin)
    (let ((needle (downcase client)))
      (seq-find
       (lambda (pid)
         (let ((cmd (browser-gt--pid-command pid)))
           (and cmd (string-match-p (regexp-quote needle)
                                    (downcase cmd)))))
       (browser-gt--lsof-client-pids)))))

(defun browser-gt--macos-activate-pid (pid)
  "Bring the macOS process with PID to the foreground, async.
Uses System Events because plain `open -a' would target whichever
instance of the bundled .app macOS considers canonical, not the
specific PID we know is holding the browser-gt WebSocket."
  (call-process
   "osascript" nil 0 nil
   "-e"
   (format
    "tell application \"System Events\" to set frontmost of (first process whose unix id is %d) to true"
    pid)))

(defun browser-gt-activate-client (client)
  "Bring the macOS app of CLIENT to the foreground if it needs the nudge.
No-op outside `system-type' `darwin' and for clients not in
`browser-gt-clients-needing-activation'.  PID-based activation via
`lsof' + `ps' + System Events is preferred; falls back to
`open -a APP' from `browser-gt-client-app-names' when the PID lookup
returns nothing.  Async (does not block the Emacs side)."
  (when (and (eq system-type 'darwin)
             (member client browser-gt-clients-needing-activation))
    (let ((pid (browser-gt--client-pid client)))
      (cond
       (pid
        (browser-gt--macos-activate-pid pid))
       (t
        (let ((app (cdr (assoc client browser-gt-client-app-names))))
          (when (and (stringp app) (not (string-empty-p app)))
            (call-process "open" nil 0 nil "-a" app))))))))

;; ── Org sanitizers ───────────────────────────────────────────────────────────
;;
;; Everything coming off the wire is page-controlled.  Org-mode is a
;; structured language: a stray `\\n* heading' in a description, a
;; `]' in a title, or a captured URL with an `elisp:' scheme can all
;; change the resulting document's meaning — at worst, run elisp when
;; the user later clicks a captured link.  These helpers escape such
;; content at the boundary so handlers can splice page strings into
;; templates and drawers without thinking about it each time.

(defconst browser-gt--safe-link-schemes
  '("http" "https" "ftp" "ftps" "mailto" "news")
  "Schemes accepted by `browser-gt--make-link'.
URLs with any other scheme (`elisp:', `shell:', `eshell:', `javascript:',
…) are rendered as plain text instead of a clickable Org link, so a
captured page cannot plant a link that runs code if a user later follows
it.  Add to this list only after weighing what `org-link-parameters'
does with the scheme in your config.")

(defun browser-gt--safe-link-url-p (url)
  "Return non-nil if URL's scheme is in `browser-gt--safe-link-schemes'."
  (and (stringp url)
       (let ((case-fold-search t))
         (when (string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\):" url)
           (member (downcase (match-string 1 url))
                   browser-gt--safe-link-schemes)))))

(defun browser-gt--escape-org-link-target (s)
  "Make S safe to splice as the target of an Org link.
A literal `]' breaks the link parser; replace with its URL-encoded form."
  (replace-regexp-in-string "\\]" "%5D" (or s "")))

(defun browser-gt--escape-org-link-desc (s)
  "Make S safe to splice as the description of an Org link.
Collapses newlines (descriptions must be single-line) and replaces the
bracket characters with curly look-alikes so they cannot close the
description bracket."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[\n\r]+" " " s))
         (s (replace-regexp-in-string "\\]" "}" s))
         (s (replace-regexp-in-string "\\[" "{" s)))
    s))

(defun browser-gt--make-link (url description)
  "Return `[[URL][DESCRIPTION]]' when URL has a safe scheme.
Otherwise return a plain-text fallback like `desc (url)' so a captured
page cannot plant a clickable `elisp:'/`shell:'/`javascript:' link.
DESCRIPTION defaults to URL if nil or empty."
  (let* ((url (or url ""))
         (description (if (and (stringp description)
                               (not (string-empty-p description)))
                          description
                        url)))
    (if (browser-gt--safe-link-url-p url)
        (format "[[%s][%s]]"
                (browser-gt--escape-org-link-target url)
                (browser-gt--escape-org-link-desc description))
      (format "%s (%s)"
              (browser-gt--escape-org-link-desc description)
              (browser-gt--escape-org-link-desc url)))))

(defun browser-gt--sanitize-org-meta (s)
  "Sanitize S for a single-line Org metadata context.
Use for property-drawer values, `#+keyword:' lines, headings.
Collapses newlines to spaces and replaces `]' with `}' so a value cannot
terminate a surrounding link or drawer line, or carry a heading break."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[\n\r]+" " " s))
         (s (replace-regexp-in-string "\\]" "}" s)))
    s))

(defun browser-gt--sanitize-org-body (s)
  "Sanitize S for multi-line Org body text.
Indents any line that would otherwise start an Org heading (`*' in
column 0), a drawer marker (`:NAME:'), or a file-level keyword
\(`#+...'), so structure cannot be injected by a page-controlled
selection, description, or transcript.  Indented variants of those
constructs are inert to the Org parser."
  (replace-regexp-in-string
   "^\\(\\*+ \\|#\\+\\|:[A-Za-z_-]+:\\)"
   " \\1"
   (or s "")))

(defun browser-gt--capture-initial (payload)
  "Build the org-capture-initial string from PAYLOAD's url, title, and text.
The link is built via `browser-gt--make-link' (which blocks unsafe schemes)
and any body text is passed through `browser-gt--sanitize-org-body' so it
cannot introduce headings or drawer markers."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "Web capture"))
         (text  (or (plist-get payload :text) "")))
    (concat (browser-gt--make-link url title)
            (unless (string-empty-p text)
              (concat "\n\n" (browser-gt--sanitize-org-body text))))))

(defun browser-gt--store-link-plist (payload)
  "Return an `org-store-link-plist' for PAYLOAD's url and title.
Drives `%a' (annotation) expansion in `org-capture' templates so that
each capture sees the current browser link rather than whatever link
Emacs happened to store last.  `:annotation' is set explicitly because
`org-capture' reads it directly when `org-capture-link-is-already-stored'
is non-nil.  For an unsafe URL scheme the `:link' field is left blank
\(so `%L'/`%l' do not splice a clickable bad link) and `:annotation' is
the plain-text rendering produced by `browser-gt--make-link'."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "Web capture")))
    (list :type "http"
          :link        (if (browser-gt--safe-link-url-p url) url "")
          :description (browser-gt--escape-org-link-desc title)
          :annotation  (browser-gt--make-link url title))))

(defun browser-gt--require-payload (payload)
  "Signal if PAYLOAD is nil."
  (unless payload
    (error "Missing 'payload' in request")))

(defun browser-gt--ok (&optional message)
  "Return a standard OK response payload, optionally with MESSAGE."
  (if message
      `((status . "ok") (message . ,message))
    '((status . "ok"))))

(defun browser-gt--strip-svg (html)
  "Return HTML with every inline <svg>…</svg> block removed.
Used by HTML→org backends to keep decorative icons out of the
pandoc-extracted media (their fixed-pixel-less viewBox-only definitions
render at librsvg's huge default size in org buffers)."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (while (re-search-forward "<svg[[:space:]\n][^>]*>" nil t)
      (let ((start (match-beginning 0)))
        (when (re-search-forward "</svg>" nil t)
          (delete-region start (point)))))
    (buffer-string)))

;; ── Built-in handlers ────────────────────────────────────────────────────────

(defun browser-gt--handle-org-capture (payload)
  "Handle ORG_CAPTURE request with PAYLOAD.
Schedules the actual capture and returns immediately (respond-fast-then-defer)."
  (browser-gt--require-payload payload)
  (browser-gt-defer #'browser-gt--org-capture payload)
  (browser-gt--ok "Org-capture started"))

(defun browser-gt--handle-org-roam-capture (payload)
  "Handle ORG_ROAM_CAPTURE request with PAYLOAD.
Schedules the actual capture and returns immediately (respond-fast-then-defer)."
  (browser-gt--require-payload payload)
  (browser-gt-defer #'browser-gt--org-roam-capture payload)
  (browser-gt--ok "Org-roam-capture started"))

(defun browser-gt--handle-eww (payload)
  "Handle EWW request with PAYLOAD.
Schedules the eww invocation and returns immediately
\(respond-fast-then-defer)."
  (browser-gt--require-payload payload)
  (unless (plist-get payload :url)
    (error "Missing url in payload"))
  (browser-gt-defer #'browser-gt--eww payload)
  (browser-gt--ok "Eww started"))

;; ── Action implementations ───────────────────────────────────────────────────

(defun browser-gt--org-capture (payload)
  "Open `org-capture' pre-filled from PAYLOAD.
Uses `browser-gt-org-capture-key' if set, otherwise prompts interactively."
  (condition-case err
      (let ((org-capture-initial              (browser-gt--capture-initial payload))
            (org-store-link-plist             (browser-gt--store-link-plist payload))
            (org-capture-link-is-already-stored t))
        (browser-gt--prime-payload-cache payload)
        (browser-gt--maybe-raise payload)
        (org-capture nil browser-gt-org-capture-key))
    (error
     (browser-gt--warn "org-capture failed: %s" (error-message-string err)))))

(defun browser-gt--org-roam-capture (payload)
  "Open org-roam-capture, seeding the payload cache from PAYLOAD."
  (condition-case err
      (let ((org-capture-initial              (browser-gt--capture-initial payload))
            (org-store-link-plist             (browser-gt--store-link-plist payload))
            (org-capture-link-is-already-stored t))
        (browser-gt--prime-payload-cache payload)
        (browser-gt--maybe-raise payload)
        (org-roam-capture-
         :node (org-roam-node-create)))
    (error
     (browser-gt--warn "org-roam-capture failed: %s" (error-message-string err)))))

(defun browser-gt--eww (payload)
  "Open the URL from PAYLOAD in eww."
  (condition-case err
      (let ((url (plist-get payload :url)))
        (browser-gt--maybe-raise payload)
        (eww url))
    (error
     (browser-gt--warn "eww failed: %s" (error-message-string err)))))

;; ── Register built-in handlers ───────────────────────────────────────────────

(browser-gt-register-handler "ORG_CAPTURE"      #'browser-gt--handle-org-capture)
(browser-gt-register-handler "ORG_ROAM_CAPTURE" #'browser-gt--handle-org-roam-capture)
(browser-gt-register-handler "EWW"              #'browser-gt--handle-eww)

;; ── Emacs-side quick helpers ────────────────────────────────────────────────
;;
;; Small commands that grab something from the active browser tab and
;; either insert it at point (interactive call) or return it as a
;; string (Lisp call).  CLIENT, when non-nil, names the connected
;; client; nil delegates the choice to `browser-gt-request' (which uses
;; the sole connected client or signals if more than one is
;; connected).

;;;###autoload
(defun browser-gt-set-default-client (&optional client)
  "Set `browser-gt-default-client' to CLIENT.
With a prefix argument, clear the setting back to nil without
prompting (subsequent commands fall back to auto-detection /
prompt-on-ambiguity).  Interactively, prompts via `completing-read'
over the currently-connected clients plus the literal \"eww\";
defaults to the existing value when it is still connected,
otherwise to the first connected client.  Selecting \"eww\" stores
the string \"eww\", which routes `browser-gt-browse-url' to eww
instead of a browser — every other browser-gt command then falls
back to its single-connected / prompt-on-ambiguity behavior.

The model is: interactive use targets one browser at a time —
this command picks which one.  Programmatic callers can still
talk to either browser concurrently by passing an explicit
CLIENT argument to `browser-gt-request' or any of the helpers."
  (interactive
   (list
    (if current-prefix-arg
        nil
      (let* ((connected (browser-gt-connected-clients))
             (choices   (append connected '("eww"))))
        (unless connected
          (user-error "Browser-gt: no client connected"))
        (let ((chosen
               (completing-read
                (format "Default browser (%s): "
                        (mapconcat #'identity choices ", "))
                choices nil t nil nil
                (cond
                 ((equal browser-gt-default-client "eww") "eww")
                 ((and (member browser-gt-default-client connected)
                       browser-gt-default-client))
                 (t (car connected))))))
          chosen)))))
  (setq browser-gt-default-client client)
  (message "Browser-gt-default-client = %S" client))

(defun browser-gt--read-client-interactive ()
  "Return a connected browser-gt client name for an interactive command.
Resolution order:
  1. `browser-gt-default-client' when it names a currently-connected
     client.
  2. The sole connected client when only one is connected.
  3. A `completing-read' over the connected clients when more than
     one is connected — and the chosen value is stored into
     `browser-gt-default-client' so subsequent commands stop asking.
     The setting survives for the rest of the Emacs session; put a
     `setq' in your config to make it permanent.
Signals `user-error' when no client is connected.  Lisp callers
that want the same behavior can call this directly; the bare-Lisp
path (passing CLIENT=nil to a helper) still delegates to
`browser-gt-request' and errors on ambiguous multi-client state."
  (let ((connected (browser-gt-connected-clients)))
    (cond
     ((null connected)
      (user-error "Browser-gt: no client connected"))
     ;; `browser-gt-default-client' set to "eww" is URL-routing only;
     ;; non-URL helpers (the callers of this function) need an actual
     ;; WS-bridge client, so fall through as if no default were set.
     ((and browser-gt-default-client
           (not (equal browser-gt-default-client "eww"))
           (member browser-gt-default-client connected))
      browser-gt-default-client)
     ((= 1 (length connected))
      (car connected))
     (t
      (let ((chosen
             (completing-read
              (format "Browser (%s): "
                      (mapconcat #'identity connected ", "))
              connected nil t nil nil
              (car connected))))
        ;; Remember for the rest of this Emacs session so the user
        ;; isn't asked again every time a browser-gt command runs.  Do
        ;; not overwrite an "eww" default — that setting is a
        ;; deliberate URL-routing choice the user can keep across
        ;; transient WS-bridge picks made here.
        (unless (equal browser-gt-default-client "eww")
          (setq browser-gt-default-client chosen))
        chosen)))))

(defun browser-gt--active-tab (&optional client)
  "Return the active tab plist from CLIENT, or signal if none."
  (let ((tab (car (browser-gt-request "GET_ACTIVE_TAB" nil client))))
    (unless tab
      (error "Browser-gt: no active tab"))
    tab))

(defun browser-gt--eval-active (code &optional client)
  "Run CODE in the active tab of CLIENT and return its result value.
Unwraps the standard `EVAL_IN_ACTIVE_TAB' response shape.  Signals
`user-error' when the response status is not \"ok\" -- for example,
per-tab consent denial or a browser-side timeout -- carrying the
browser message.  Timeout messages get the consent hint appended
since consent-related delays are the most common cause."
  (let* ((resp   (browser-gt-request "EVAL_IN_ACTIVE_TAB"
                                  (list :code code) client))
         (status (plist-get resp :status)))
    (unless (equal status "ok")
      (let ((msg (or (plist-get resp :message) "eval request failed")))
        (user-error "Browser-gt: %s%s"
                    msg
                    (if (equal msg "timeout")
                        " (did the per-tab consent overlay appear?  Grant consent and try again)"
                      ""))))
    (plist-get (car (plist-get resp :result)) :result)))

;;;###autoload
(defun browser-gt-org-link (&optional client)
  "Insert (or return) an Org link to the active browser tab.
The link is `[[URL][TITLE]]' built via `browser-gt--make-link', so
unsafe schemes (elisp:, javascript:, ...) fall back to a plain-text
rendering.  When called interactively the link is inserted at point
and the return value is nil; interactive callers signal `user-error'
when the active tab has no URL.  When called from Lisp the link
string is returned, or nil when the tab has no URL.  CLIENT, when
non-nil, names the connected browser-gt client; interactively the
command prompts when more than one client is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let* ((tab (browser-gt--active-tab client))
         (url (plist-get tab :url)))
    (cond
     ((null url)
      (if (called-interactively-p 'any)
          (user-error "Browser-gt: active tab has no URL")
        nil))
     (t
      (let* ((title (or (plist-get tab :title) url))
             (link  (browser-gt--make-link url title)))
        (if (called-interactively-p 'any)
            (progn (insert link) nil)
          link))))))

;;;###autoload
(defun browser-gt-selection (&optional client)
  "Insert (or return) the active tab's current text selection.
When called interactively, the selection text is inserted at point
and the return value is nil; an empty selection inserts nothing.
When called from Lisp the selection string is returned, or the
empty string when nothing is selected.  Errors from the eval layer
propagate through `browser-gt--eval-active' -- per-tab consent denial,
timeout, or no client -- and their message text already carries the
consent hint.  CLIENT, when non-nil, names the connected browser-gt
client; interactively the command prompts when more than one client
is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let ((text (or (browser-gt--eval-active
                   "window.getSelection().toString()" client)
                  "")))
    (if (called-interactively-p 'any)
        (progn (insert text) nil)
      text)))

;;;###autoload
(defun browser-gt-url (&optional client)
  "Insert (or return) the URL of the active browser tab.
When called interactively, the URL is inserted at point and the
return value is nil; interactive callers signal `user-error' when
the active tab has no URL.  When called from Lisp the URL string
is returned, or nil when the tab has no URL.  CLIENT, when non-nil,
names the connected browser-gt client; interactively the command
prompts when more than one client is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let ((url (plist-get (browser-gt--active-tab client) :url)))
    (if (called-interactively-p 'any)
        (progn
          (unless url (user-error "Browser-gt: active tab has no URL"))
          (insert url)
          nil)
      url)))

;;;###autoload
(defun browser-gt-title (&optional client)
  "Insert (or return) the title of the active browser tab.
When called interactively, the title is inserted at point and the
return value is nil; interactive callers signal `user-error' when
the active tab has no title.  When called from Lisp the title
string is returned, or nil when the tab has no title.  CLIENT,
when non-nil, names the connected browser-gt client; interactively
the command prompts when more than one client is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let ((title (plist-get (browser-gt--active-tab client) :title)))
    (if (called-interactively-p 'any)
        (progn
          (unless title (user-error "Browser-gt: active tab has no title"))
          (insert title)
          nil)
      title)))

(defun browser-gt--format-time-hms (total-seconds)
  "Format TOTAL-SECONDS as `H:MM:SS' / `M:SS' / `S'.
Drops leading zero components — sub-hour timestamps come back as
`M:SS', sub-minute timestamps as `S' (no leading zero).  TOTAL-SECONDS
is truncated to an integer (so 12.7 → 12).  Negative inputs clamp
to zero."
  (let* ((n (max 0 (truncate total-seconds)))
         (h (/ n 3600))
         (m (% (/ n 60) 60))
         (s (% n 60)))
    (cond
     ((> h 0) (format "%d:%02d:%02d" h m s))
     ((> m 0) (format "%d:%02d" m s))
     (t       (format "%d" s)))))

;;;###autoload
(defun browser-gt-video-current-time (&optional client)
  "Insert (or return) the first `<video>' element's current time.
Format is `H:MM:SS' for an hour or more, `M:SS' for sub-hour, and a
bare `S' for sub-minute (see `browser-gt--format-time-hms').  When
called interactively the timestamp is inserted at point and nil is
returned; from Lisp the string is returned.  Signals `user-error'
if the active tab has no video element.  CLIENT, when non-nil,
names the connected browser-gt client; interactively the command
prompts when more than one client is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let* ((code "(() => { const v = document.querySelector('video');
                         return v ? v.currentTime : null; })()")
         (seconds (browser-gt--eval-active code client)))
    (unless (numberp seconds)
      (user-error "Browser-gt: no video on this page"))
    (let ((str (browser-gt--format-time-hms seconds)))
      (if (called-interactively-p 'any)
          (progn (insert str) nil)
        str))))

;;;###autoload
(defun browser-gt-video-toggle-play (&optional client)
  "Toggle play / pause on the first `<video>' in the active tab.
Plays if the video is paused, pauses if it is playing.  Messages the
new state in the echo area.  Errors with a short message if the page
has no video element.  CLIENT, when non-nil, names the connected
browser-gt client; interactively the command prompts when more than
one client is connected."
  (interactive (list (browser-gt--read-client-interactive)))
  (let* ((code
          "(() => {
             const v = document.querySelector('video');
             if (!v) return { ok: false, reason: 'no video on this page' };
             if (v.paused) { v.play(); return { ok: true, state: 'playing' }; }
             v.pause(); return { ok: true, state: 'paused' };
           })()")
         (result (browser-gt--eval-active code client)))
    (unless (plist-get result :ok)
      (user-error "Browser-gt: %s"
                  (or (plist-get result :reason) "unknown")))
    (message "Video %s" (plist-get result :state))))

;;;###autoload
(defun browser-gt-video-advance (&optional arg client)
  "Advance the first `<video>' in the active tab by ARG seconds.
Default is 5 seconds forward.  A numeric prefix N seeks N seconds
\(sign honored — negative goes back).  A bare `C-u' or
`\\[negative-argument]' seeks 5 seconds back.  Errors with a short
message if the page has no video element.  CLIENT, when non-nil,
names the connected browser-gt client; interactively the command
prompts when more than one client is connected."
  (interactive (list current-prefix-arg
                     (browser-gt--read-client-interactive)))
  (let* ((seconds (cond
                   ((null arg) 5)
                   ((numberp arg) arg)
                   (t -5)))
         (code (format
                "(() => {
                   const v = document.querySelector('video');
                   if (!v) return { ok: false, reason: 'no video on this page' };
                   v.currentTime = Math.max(0, v.currentTime + (%d));
                   return { ok: true, currentTime: v.currentTime };
                 })()"
                seconds))
         (result (browser-gt--eval-active code client)))
    (unless (plist-get result :ok)
      (user-error "Browser-gt: %s"
                  (or (plist-get result :reason) "unknown")))
    (message "Video at %.1fs" (plist-get result :currentTime))))

;;;###autoload
(defun browser-gt-scroll-page (&optional arg client)
  "Scroll the active browser tab by ARG viewport heights.
With no prefix: scroll one page forward.  A numeric prefix N scrolls
N pages (sign honored — positive forward, negative back).  A bare
`C-u' or `\\[negative-argument]' scrolls one page back — these
non-numeric prefixes invert direction with magnitude 1, since they
do not encode a page count themselves.  CLIENT, when non-nil, names
the connected browser-gt client; interactively the command prompts
when more than one client is connected."
  (interactive (list current-prefix-arg
                     (browser-gt--read-client-interactive)))
  (let* ((n (cond
             ((null arg) 1)
             ((numberp arg) arg)
             (t -1)))
         (code (format
                "window.scrollBy({top: (%d) * window.innerHeight, left: 0, behavior: 'smooth'})"
                n)))
    (browser-gt--eval-active code client)
    (when (called-interactively-p 'any)
      (message "Scrolled %d page%s" n (if (= (abs n) 1) "" "s")))))

(provide 'browser-gt)

;;; browser-gt.el ends here
