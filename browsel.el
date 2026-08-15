;;; browsel.el --- WebSocket bridge to a Chrome/Firefox extension  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org
;; URL: https://github.com/dmgerman/browsel
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
;; `browsel-register-handler'.  Outgoing requests are made with
;; `browsel-request-async' (callback-based) or
;; `browsel-request' (sync wrapper using `accept-process-output').
;;
;; Built-in handlers:
;;
;;   ORG_CAPTURE       -- org-capture (template key configurable)
;;   ORG_ROAM_CAPTURE  -- standard org-roam-capture
;;   EWW               -- open URL in eww
;;
;; Per-feature backends register additional handlers:
;;
;;   browsel-chatgpt.el  -- CHATGPT
;;   browsel-www.el      -- SAVE_PAGE
;;   browsel-youtube.el  -- YOUTUBE, YOUTUBE_TRANSCRIPT
;;
;; Usage:
;;   (require 'browsel)
;;   (browsel-start)   ; start the server
;;   (browsel-stop)    ; stop the server

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

(defconst browsel-version "0.94"
  "Current version of the browsel package.")

;;;###autoload
(defun browsel-version (&optional here)
  "Return the browsel version string.
Interactively, display the version in the echo area.  With prefix
argument HERE, insert the version at point instead.  When called
from Lisp the return value is always the version string."
  (interactive "P")
  (let ((string (format "browsel %s" browsel-version)))
    (cond
     (here
      (insert string))
     ((called-interactively-p 'interactive)
      (message "%s" string))))
  browsel-version)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar browsel-port 9130
  "Port the Chrome server WebSocket server listens on.")

(defvar browsel-host 'local
  "Host the WebSocket server binds to.  `local' = 127.0.0.1.")

(defcustom browsel-clients-file
  (locate-user-emacs-file "browsel-clients.eld")
  "File in which browsel remembers instance-UUID → assigned-name mappings.

When two profiles or two installs of the same browser both connect
without a user-set label, arrival order alone would decide which
one becomes `chrome' and which one becomes `chrome-<short>' — and
that order can flip between Emacs sessions, so
`browsel-default-client' set to `chrome' would silently target a
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
  :group 'browsel)

(defvar browsel-org-capture-key nil
  "Org-capture template key used by the ORG_CAPTURE handler.
nil means the user selects the template interactively.")

(defcustom browsel-default-client nil
  "Name of the connected browsel client to address by default.
One of:

  - nil — each browsel command auto-detects: the sole connected
    client when only one is connected, prompt-or-error when more
    than one.
  - a string returned by `browsel-connected-clients' — typically
    \"chrome\" or \"firefox\".
  - the string \"eww\" — `browsel-browse-url' opens URLs in eww
    instead of a connected browser.  This applies only to URL
    routing; every other browsel helper (insert-selection,
    scroll-page, tab-manager, chatgpt, youtube, …) needs a real
    WS-bridge client and falls back to single-connected /
    prompt-on-ambiguity when this value is \"eww\".

This is the single user-wide default used by every browsel
command that needs to pick a client.  Set once in your config
and the multi-client prompt disappears.  Change it mid-session
with `M-x browsel-set-default-client' (prefix arg clears it back
to nil).  The assumption is that interactive use targets one
browser at a time; programmatic callers can still talk to either
browser by passing an explicit CLIENT to the helpers."
  :type '(choice (const  :tag "Auto / prompt on ambiguity" nil)
                 (const  :tag "Internal eww" "eww")
                 (string :tag "Client name"))
  :group 'browsel)

(defvar browsel-request-timeout 10
  "Seconds to wait for a response to an Emacs-initiated request before timing out.")

(defvar browsel-debug nil
  "When non-nil, log every WebSocket frame to *browsel* buffer.")

(defvar browsel-debug-timing nil
  "When non-nil, log per-stage latency breakdown for every slow request.
Uses timing stamps attached to Chrome responses by the extension (see
`ai/slow-random-response-time.md').  A request is considered slow when
its total wall-clock time exceeds `browsel-slow-request-threshold'.
When the flag is nil the advice still fires the slow-line message on
slow requests but omits the per-stage breakdown.")

(defvar browsel-slow-request-threshold 0.5
  "Seconds above which `browsel-request' logs a slow-line to *Messages*.
Set to a small positive number to catch outliers; set to nil to
suppress the slow-line entirely.")

(defvar browsel--last-response-timing nil
  "Timing plist from the most recent WebSocket response frame.
Populated by `browsel--handle-response' from the wire-level
`:__timing' field (see `ai/slow-random-response-time.md').  Read by
`browsel--timing-advice'; not part of the public API.")

(defvar browsel-pandoc-executable "pandoc"
  "Path to the pandoc executable used for HTML → org conversion.
Shared by browsel-www and browsel-chatgpt backends.")

(defvar browsel-max-message-bytes (* 64 1024 1024)
  "Maximum bytes a single WebSocket message may accumulate to.
Page-html and ChatGPT-turns payloads are inherently large, so this is
set high (64 MiB) by default — large enough for any plausible page
save, low enough that a stuck or hostile sender cannot grow Emacs's
heap unbounded.  A client whose pending message exceeds this limit is
disconnected and its accumulator dropped; a fresh connection is
required to retry.  Set to nil to disable the cap.")

(defcustom browsel-clients-needing-activation
  '("firefox")
  "Browsel client names whose macOS app needs an explicit foreground nudge.
Chrome activates itself via its WebExtension API when its window
is focused; Firefox on macOS does not, hence the fallback.  Clients
not in this list are left alone — Chrome's main process isn't even
the one holding the WebSocket (a helper is), so a PID-based
activation against it would be a no-op anyway.

Has no effect outside `system-type' `darwin'.  Used by
`browsel-activate-client', called from `browsel-url-handler' and
`browsel-tab-manager' after any window-focusing operation."
  :type '(repeat (string :tag "browsel client"))
  :group 'browsel)

(defcustom browsel-client-app-names
  '(("firefox" . "Firefox"))
  "Alist mapping a browsel client name to its macOS application name.
Fallback for clients in `browsel-clients-needing-activation' when
the more precise PID-based lookup via `lsof' + `ps' fails to find
the process.  The value is the application's display name as
`open -a' expects it (e.g. \"Firefox\", \"Firefox Developer Edition\")."
  :type '(alist :key-type   (string :tag "browsel client")
                :value-type (string :tag "macOS .app name"))
  :group 'browsel)

;; ── State ────────────────────────────────────────────────────────────────────

(defvar browsel--server-process nil
  "The `websocket-server' process, or nil if not running.")

(defvar browsel--clients nil
  "Alist of currently connected clients as (NAME . WS) pairs.
NAME is the identifier the client announced via CLIENT_HELLO, or
\"unknown-N\" until the client identifies itself.  WS is the
underlying websocket object.")

(defvar browsel--client-instances nil
  "Alist mapping websocket → instance UUID string.
Populated by `browsel--handle-client-hello' from the extension's
`chrome.storage.local' UUID.  Consulted when a new CLIENT_HELLO
arrives with an INSTANCE already registered on a different ws: the
stale entry is closed and its slot reused, so a reconnecting profile
keeps its name instead of accumulating suffixes.")

(defvar browsel--name-registry nil
  "Alist mapping instance UUID → assigned display name.
Persisted to `browsel-clients-file' so the same install gets the
same name across Emacs restarts regardless of connection order.
Loaded once on `browsel-start' and updated on every CLIENT_HELLO
that yields a naming decision.  A user-set label always overrides
whatever is in here for that instance's next hello.")

(defvar browsel--connect-counter 0
  "Monotonic counter for naming unidentified clients.
Reset on `browsel-start'; never decrements during a server's
lifetime so two unidentified connections cannot collide on the
same fallback name.")

(defvar browsel--current-ws nil
  "Websocket currently being dispatched, bound during handler execution.
Built-in handlers (notably CLIENT_HELLO) read this to discover which
client sent the request.  User-registered handlers should ignore it.")

(defvar browsel--handlers nil
  "Alist mapping request name (string) to handler function.
Handler is called with one argument, the request payload (a plist),
and must return a value JSON-encodable as the response payload.")

(defvar browsel--pending-callbacks nil
  "Alist mapping outstanding request id (string) to (CALLBACK . TIMER).
CALLBACK is invoked with the decoded response payload.  TIMER is the
`run-at-time' timer that aborts the request on timeout.")

(defvar browsel--rx-buffers nil
  "Per-client accumulators for in-progress fragmented messages.
Alist mapping each client websocket to the bytes received so far for
the in-progress fragmented message on that connection.  Cleared once
the final fragment (FIN bit set) arrives or the client disconnects.")

;; ── Debug logging ────────────────────────────────────────────────────────────

(defun browsel--log (fmt &rest args)
  "Append FMT formatted with ARGS to *browsel* when debug is enabled."
  (when browsel-debug
    (with-current-buffer (get-buffer-create "*browsel*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S.%3N] ")
              (apply #'format fmt args)
              "\n"))))

(defun browsel--warn (fmt &rest args)
  "Surface a browsel warning to the user and the debug log.
FMT and ARGS are passed through `format'.  The formatted message is
emitted to *Messages* and appended to the *browsel* debug
buffer."
  (let ((msg (apply #'format fmt args)))
    (message "browsel: %s" msg)
    (browsel--log "[WARN] %s" msg)))

;; ── Name-registry persistence ────────────────────────────────────────────────
;;
;; The registry maps instance UUID → last-assigned display name.  It
;; is loaded on `browsel-start' and saved on every hello that touches
;; it (and once more on `browsel-stop').  The file format is a single
;; elisp form so the file is diff-friendly and hand-editable in a
;; pinch; the header comment reminds a future reader why it exists.

(defconst browsel--registry-file-header
  ";; -*- mode: emacs-lisp; coding: utf-8; -*-\n\
;; browsel client-name registry — auto-generated, do NOT edit by hand.\n\
;; Maps per-install `instance' UUIDs to the display names Emacs\n\
;; assigned them, so the same install keeps its name across\n\
;; sessions regardless of connection order.  Delete this file to\n\
;; reset; the next hello will repopulate it.  See\n\
;; `browsel-clients-file' for the full rationale.\n\n"
  "Header comment prepended to `browsel-clients-file'.")

(defun browsel--load-name-registry ()
  "Return the persisted name registry as an alist, or nil.
Reads `browsel-clients-file'.  Returns nil when the file is
missing, unreadable, empty, or its contents are not an alist —
each case is a soft failure that a warning surfaces once; the
server keeps running with an empty registry."
  (let ((file browsel-clients-file))
    (cond
     ((or (null file) (not (file-exists-p file)))
      nil)
     ((not (file-readable-p file))
      (browsel--warn "clients file %s not readable; using empty registry" file)
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
                (browsel--warn "clients file %s malformed; using empty registry"
                               file)
                nil)))
        (error
         (browsel--warn "could not read clients file %s: %s; using empty registry"
                        file (error-message-string err))
         nil))))))

(defun browsel--save-name-registry ()
  "Persist `browsel--name-registry' to `browsel-clients-file' atomically.
Writes to a sibling `.tmp' file first, then renames — so a crash
mid-write leaves the previous good file intact.  No-op when
`browsel-clients-file' is nil (persistence disabled) or when the
registry is empty and no file exists yet (avoids creating an empty
file for users who never hit a hello)."
  (let ((file browsel-clients-file))
    (when (and file
               (or browsel--name-registry (file-exists-p file)))
      (condition-case err
          (let ((tmp (concat file ".tmp")))
            (with-temp-file tmp
              (insert browsel--registry-file-header)
              (let ((print-level  nil)
                    (print-length nil))
                (pp browsel--name-registry (current-buffer))))
            (rename-file tmp file t))
        (error
         (browsel--warn "could not save clients file %s: %s"
                        file (error-message-string err)))))))

(defun browsel--registry-set (instance name)
  "Set (INSTANCE . NAME) in the registry and persist.
Removes any prior binding for INSTANCE before inserting the new
pair, so the alist stays flat.  Persistence is best-effort — a
save failure warns but does not abort the hello."
  (setq browsel--name-registry
        (cons (cons instance name)
              (cl-remove-if (lambda (c) (equal (car c) instance))
                            browsel--name-registry)))
  (browsel--save-name-registry))

(defun browsel--registry-clear (instance)
  "Remove INSTANCE from the registry and persist.
Called from `browsel--handle-client-hello' when a labeled hello
arrives — the registry only remembers default-case assignments,
so any prior entry for INSTANCE is stale once the user has
declared a label.  No-op when INSTANCE is not present."
  (when (assoc instance browsel--name-registry)
    (setq browsel--name-registry
          (cl-remove-if (lambda (c) (equal (car c) instance))
                        browsel--name-registry))
    (browsel--save-name-registry)))

;; ── Server lifecycle ─────────────────────────────────────────────────────────

;;;###autoload
(defun browsel-start ()
  "Start the browsel WebSocket server on `browsel-port'.
A failure to bind the port (another Emacs already holds it,
permission denied, etc.) is downgraded to a warning: the server
stays disabled and `browsel--server-process' remains nil rather
than propagating an error to the caller.  This keeps a broken
port from crashing an init.el `browsel-start' call — the user can
fix the underlying condition and re-invoke."
  (interactive)
  (when (and browsel--server-process
             (not (eq (process-status browsel--server-process) 'closed)))
    (browsel-stop))
  (setq browsel--clients nil
        browsel--client-instances nil
        browsel--connect-counter 0
        browsel--pending-callbacks nil
        browsel--name-registry (browsel--load-name-registry)
        browsel--server-process nil)
  (condition-case err
      (progn
        (setq browsel--server-process
              (websocket-server
               browsel-port
               :host browsel-host
               :on-open    #'browsel--on-open
               :on-close   #'browsel--on-close
               :on-message #'browsel--on-message
               :on-error   #'browsel--on-error))
        (browsel--log "[SERVER] started on port %d" browsel-port)
        (message "browsel WebSocket server started on port %d" browsel-port))
    (error
     (setq browsel--server-process nil)
     (browsel--warn
      "could not bind port %d: %s. \
Server is disabled; fix the condition (typically another Emacs \
holding the port) and re-run `M-x browsel-start'."
      browsel-port (error-message-string err)))))

;;;###autoload
(defun browsel-stop ()
  "Stop the Chrome server WebSocket server."
  (interactive)
  (when browsel--server-process
    (websocket-server-close browsel--server-process)
    (setq browsel--server-process nil))
  (browsel--cancel-all-pending "server stopped")
  (browsel--save-name-registry)
  (setq browsel--clients nil
        browsel--client-instances nil
        browsel--connect-counter 0)
  (browsel--log "[SERVER] stopped")
  (message "Chrome server stopped"))

;; ── Connection callbacks ─────────────────────────────────────────────────────

(defun browsel--on-open (ws)
  "Register newly connected client WS under a placeholder name.
The client should send a CLIENT_HELLO request as its first frame to
replace the placeholder with a stable identifier."
  (let ((name (format "unknown-%d" (cl-incf browsel--connect-counter))))
    (setq browsel--clients
          (cons (cons name ws) browsel--clients))
    (browsel--log "[CONNECT] %s (clients=%d)"
                        name (length browsel--clients))))

(defun browsel--on-close (ws)
  "Remove disconnected client WS and drop its rx buffer and instance record."
  (let ((cell (rassq ws browsel--clients)))
    (setq browsel--clients
          (cl-remove-if (lambda (c) (eq (cdr c) ws)) browsel--clients)
          browsel--client-instances
          (cl-remove-if (lambda (c) (eq (car c) ws))
                        browsel--client-instances)
          browsel--rx-buffers
          (cl-remove-if (lambda (c) (eq (car c) ws)) browsel--rx-buffers))
    (browsel--log "[DISCONNECT] %s (clients=%d)"
                        (if cell (car cell) "?")
                        (length browsel--clients))))

(defun browsel--on-error (_ws sym err)
  "Surface WebSocket error ERR in callback SYM."
  (browsel--warn "error in %s: %S" sym err))

;; ── Dispatch ─────────────────────────────────────────────────────────────────

(defun browsel--drop-client-over-limit (ws combined-len)
  "Drop WS and its rx accumulator; warn that COMBINED-LEN exceeded the cap.
Called from `browsel--on-message' when a pending message would push
the per-client accumulator past `browsel-max-message-bytes'.  The
accumulator is freed before the close so a stalled close does not
keep the buffer pinned."
  (setq browsel--rx-buffers
        (cl-remove-if (lambda (c) (eq (car c) ws)) browsel--rx-buffers))
  (browsel--warn
   "client message exceeded %d bytes (had %d); dropping connection"
   browsel-max-message-bytes combined-len)
  (ignore-errors (websocket-close ws)))

(defun browsel--on-message (ws frame)
  "Accumulate FRAME bytes for WS; dispatch once a complete message arrives.
A WebSocket message may be split across many frames (large payloads such
as page HTML routinely run into the hundreds of KB).  We keep a per-client
buffer of frame text and only JSON-parse once the FIN bit is set on the
final frame.  Frames with a `:name' field are requests; frames with a
`:requestId' field are responses to Emacs-initiated requests.
A pending message that would grow past `browsel-max-message-bytes'
disconnects the client instead of growing the accumulator further."
  (let* ((text       (or (websocket-frame-text frame) ""))
         (complete-p (websocket-frame-completep frame))
         (prior-cell (assq ws browsel--rx-buffers))
         (combined   (concat (cdr prior-cell) text)))
    (cond
     ;; Over the size cap — disconnect and stop accumulating.
     ((and browsel-max-message-bytes
           (> (length combined) browsel-max-message-bytes))
      (browsel--drop-client-over-limit ws (length combined)))
     ;; Still receiving — stash and wait.
     ((not complete-p)
      (if prior-cell
          (setcdr prior-cell combined)
        (setq browsel--rx-buffers
              (cons (cons ws combined) browsel--rx-buffers)))
      (browsel--log "[RECV-CONT] +%d byte(s); total=%d"
                          (length text) (length combined)))
     ;; Final fragment — drop the accumulator and dispatch.
     (t
      (when prior-cell
        (setq browsel--rx-buffers
              (cl-remove-if (lambda (c) (eq (car c) ws))
                            browsel--rx-buffers)))
      (browsel--log "[RECV] %d byte(s)" (length combined))
      (let ((msg (condition-case err
                     (json-parse-string combined
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil)
                   (error
                    (browsel--warn "could not parse frame as JSON: %s"
                                         (error-message-string err))
                    nil))))
        (cond
         ((null msg) nil)
         ((plist-get msg :name)
          (browsel--handle-request ws msg))
         ((plist-get msg :requestId)
          (browsel--handle-response msg))
         (t
          (browsel--warn "unknown frame shape (no :name or :requestId): %S"
                               msg))))))))

(defun browsel--handle-request (ws msg)
  "Look up handler for MSG and send the response back over WS."
  (let* ((name    (plist-get msg :name))
         (id      (or (plist-get msg :id) "<unknown>"))
         (payload (plist-get msg :payload))
         (handler (cdr (assoc name browsel--handlers))))
    (let ((response-payload
           (if handler
               (condition-case err
                   (let ((browsel--current-ws ws))
                     (funcall handler payload))
                 (error
                  (browsel--warn "handler %s signalled: %s"
                                       name (error-message-string err))
                  `((status . "error")
                    (message . ,(error-message-string err)))))
             (progn
               (browsel--warn "no handler registered for request: %s"
                                    name)
               `((status . "error")
                 (message . ,(format "Unknown request: %s" name)))))))
      ;; Surface the handler's status line to the user.  Errors are
      ;; already reported via `browsel--warn' in the error path
      ;; above, so we only message on success here to avoid duplicates.
      (let ((status (alist-get 'status response-payload))
            (text   (alist-get 'message response-payload)))
        (when (and text (equal status "ok"))
          (message "browsel [%s]: %s" name text)))
      (browsel--send-to ws
                              `((requestId . ,id)
                                (payload   . ,response-payload))))))

(defun browsel--handle-response (msg)
  "Invoke the pending callback for MSG's requestId.
If no pending callback matches (likely already timed out), surfaces a warning."
  (let* ((id   (plist-get msg :requestId))
         (cell (assoc id browsel--pending-callbacks)))
    (if (null cell)
        (browsel--warn "response for unknown/timed-out request id: %s" id)
      (let ((callback (cadr cell))
            (timer    (cddr cell)))
        (when (timerp timer) (cancel-timer timer))
        (setq browsel--pending-callbacks
              (cl-remove-if (lambda (c) (equal (car c) id))
                            browsel--pending-callbacks))
        ;; Stash the wire-level :__timing (Chrome-only, may be nil) so
        ;; the sync `browsel-request' path can hand it to
        ;; `browsel--timing-advice' after the callback returns.
        ;; See ai/slow-random-response-time.md.
        (setq browsel--last-response-timing (plist-get msg :__timing))
        (condition-case err
            (funcall callback (plist-get msg :payload))
          (error
           (browsel--warn "response callback for %s signalled: %s"
                                id (error-message-string err))))))))

;; ── Sending ──────────────────────────────────────────────────────────────────

(defun browsel--send-to (ws data)
  "JSON-encode DATA and send it on WS."
  (let ((text (json-encode data)))
    (browsel--log "[SEND] %s" text)
    (websocket-send-text ws text)))

(defun browsel--target-for (client name)
  "Resolve a request target without signalling.
Returns one of:
  (ok   . WS)  — send to WS.
  (err  . MSG) — abort: caller-supplied CLIENT not connected, or
                 multiple clients are connected and CLIENT is nil.
  (none . MSG) — no clients connected at all.
NAME appears in MSG and is informational only."
  (cond
   (client
    (let ((cell (assoc client browsel--clients)))
      (if cell
          (cons 'ok (cdr cell))
        (cons 'err
              (format
               "requested client %S is not connected (connected: %s)"
               client
               (if browsel--clients
                   (mapconcat #'car browsel--clients ", ")
                 "none"))))))
   ((null browsel--clients)
    (cons 'none (format "no client connected; dropping request %s" name)))
   ((= 1 (length browsel--clients))
    (cons 'ok (cdar browsel--clients)))
   (t
    (cons 'err
          (format "%d clients connected (%s); specify CLIENT for request %S"
                  (length browsel--clients)
                  (mapconcat #'car browsel--clients ", ")
                  name)))))

(defun browsel-connected-clients ()
  "Return the list of connected client names, in connection order (newest first)."
  (mapcar #'car browsel--clients))

;; ── Public browser API ───────────────────────────────────────────────────────
;;
;; `browsel-browsers' and `browsel-browser-tabs' are the stable
;; entry points other packages should build on.  They speak in the
;; user-facing "browser" vocabulary, hide the internal alists, and
;; validate their inputs.  `browsel-connected-clients' remains for
;; cheap name-only enumeration.

(defun browsel--client-instance-for-ws (ws)
  "Return the instance UUID recorded for WS, or nil."
  (cdr (assq ws browsel--client-instances)))

(defun browsel--client-instance-for-name (name)
  "Return the instance UUID recorded for the browser named NAME, or nil."
  (browsel--client-instance-for-ws
   (cdr (assoc name browsel--clients))))

(defun browsel-browsers ()
  "Return the connected browsers as a list of plists.
Each plist has:
  :name      — display name (also returned by `browsel-connected-clients').
  :instance  — per-install UUID string, stable across reconnects
               (see `browsel-clients-file').
Order matches `browsel-connected-clients' (newest connection first).
Downstream packages should prefer this over
`browsel-connected-clients' when they need to persist a reference
to a specific install across sessions."
  (mapcar (lambda (cell)
            (list :name     (car cell)
                  :instance (browsel--client-instance-for-ws (cdr cell))))
          browsel--clients))

(defun browsel--normalize-browsers (browsers)
  "Resolve BROWSERS to a validated list of connected browser names.
BROWSERS is one of: nil (every connected browser), a name string
\(wrap in a one-element list), or a list of name strings (each
must be connected).  Signals `user-error' when no browser is
connected, or when any requested name is not currently connected."
  (let ((all (browsel-connected-clients)))
    (cond
     ((null browsers)
      (or all (user-error "Browsel: no browser connected")))
     ((stringp browsers)
      (browsel--normalize-browsers (list browsers)))
     ((listp browsers)
      (let ((missing (seq-remove (lambda (b) (member b all)) browsers)))
        (when missing
          (user-error
           "Browsel: not connected: %s (connected: %s)"
           (mapconcat #'identity missing ", ")
           (if all (mapconcat #'identity all ", ") "none"))))
      browsers)
     (t
      (user-error
       "browsel: BROWSERS must be nil, a string, or a list of strings; got %S"
       browsers)))))

(defun browsel-browser-tabs (&optional browsers)
  "Return open tabs from the connected browsers.
BROWSERS narrows the query:
  - nil          — every entry in `browsel-connected-clients'.
  - name string  — that single browser only.
  - list of strings — every browser in the list.

Each returned element is the extension's raw tab plist extended
with two browsel-specific keys:
  :browsel-browser  — the browser name that owns the tab (same
                      shape as `browsel-connected-clients' entries
                      and safe to pass to `browsel-request').
  :browsel-instance — the browser's per-install UUID, stable
                      across reconnects.
Signals `user-error' when no browser is connected, or when any
requested name is not connected.

Requests are issued sequentially — parallel would need
`browsel-request-async' callback juggling and tab enumeration is
fast enough that the extra complexity is not worth it for the two
or three browsers this package is designed for.  A failing
browser is logged via `message' and its tabs are omitted; the
caller sees an empty list only when every queried browser failed."
  (let ((selected (browsel--normalize-browsers browsers)))
    (apply #'append
           (mapcar
            (lambda (name)
              (let ((instance (browsel--client-instance-for-name name)))
                (condition-case err
                    (mapcar (lambda (tab)
                              (append tab
                                      (list :browsel-browser  name
                                            :browsel-instance instance)))
                            (browsel-request "GET_ALL_TABS" nil name))
                  (error
                   (message "browsel: %s failed: %s"
                            name (error-message-string err))
                   nil))))
            selected))))

(defun browsel-focus-tab (tab &optional focus-window)
  "Focus TAB in the browser that owns it.
TAB is a plist as returned by `browsel-browser-tabs' — it must
carry both `:id' (the browser's numeric tab id) and
`:browsel-browser' (the owning browser's name).  FOCUS-WINDOW
non-nil also raises the browser's OS window so the tab becomes
visually foreground, and on macOS nudges the browser app itself
via `browsel-activate-client' for browsers listed in
`browsel-clients-needing-activation'.

Signals `user-error' when TAB lacks either required key, or when
its owning browser is not currently connected.

Returns the browser-side response payload plist: `(:status \"ok\")'
on success, `(:status \"error\" :message MSG)' when the browser
rejected the request (typically because the tab id no longer
exists — the tab was closed between fetch and focus).  Callers
that want to react to \"tab is gone\" should check
`(plist-get response :status)'."
  (let ((id      (plist-get tab :id))
        (browser (plist-get tab :browsel-browser)))
    (unless (numberp id)
      (user-error "browsel-focus-tab: TAB has no numeric :id"))
    (unless (and (stringp browser) (not (string-empty-p browser)))
      (user-error "browsel-focus-tab: TAB has no :browsel-browser"))
    (unless (member browser (browsel-connected-clients))
      (user-error
       "Browsel-focus-tab: browser %S is not connected (connected: %s)"
       browser
       (let ((all (browsel-connected-clients)))
         (if all (mapconcat #'identity all ", ") "none"))))
    (let ((response
           (browsel-request "FOCUS_TAB"
                            (if focus-window
                                `(:id ,id :focusWindow t)
                              `(:id ,id))
                            browser)))
      (when (and focus-window
                 (equal (plist-get response :status) "ok"))
        (browsel-activate-client browser))
      response)))

(defun browsel-close-tab (tab)
  "Close TAB in the browser that owns it.
TAB is a plist as returned by `browsel-browser-tabs' — it must
carry both `:id' (the browser's numeric tab id) and
`:browsel-browser' (the owning browser's name).

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
        (browser (plist-get tab :browsel-browser)))
    (unless (numberp id)
      (user-error "browsel-close-tab: TAB has no numeric :id"))
    (unless (and (stringp browser) (not (string-empty-p browser)))
      (user-error "browsel-close-tab: TAB has no :browsel-browser"))
    (unless (member browser (browsel-connected-clients))
      (user-error
       "Browsel-close-tab: browser %S is not connected (connected: %s)"
       browser
       (let ((all (browsel-connected-clients)))
         (if all (mapconcat #'identity all ", ") "none"))))
    (browsel-request "CLOSE_TAB" `(:id ,id) browser)))

(defun browsel--broadcast (data &optional client)
  "JSON-encode DATA and send it to one connected client.
With CLIENT nil and exactly one client connected, that client is the
target.  With CLIENT a string, the matching named client is targeted.
Returns the websocket the frame was sent on, or nil if the resolution
fails (also surfaces a warning so the failure is not silent)."
  (pcase (browsel--target-for client (alist-get 'name data))
    (`(ok . ,ws)
     (browsel--send-to ws data)
     ws)
    (`(err . ,msg)
     (browsel--warn "%s" msg)
     nil)
    (`(none . ,msg)
     (browsel--warn "%s" msg)
     nil)))

;; ── Handler registry ─────────────────────────────────────────────────────────

(defun browsel-register-handler (name handler)
  "Register HANDLER as the handler for request NAME.
NAME is a SCREAMING_SNAKE_CASE string.  HANDLER is called with the
request payload (a plist) and must return a value JSON-encodable as the
response payload.  Re-registering overwrites the previous binding."
  (setq browsel--handlers
        (cons (cons name handler)
              (cl-remove-if (lambda (c) (string= (car c) name))
                            browsel--handlers))))

(defun browsel-unregister-handler (name)
  "Remove the handler for request NAME, if any."
  (setq browsel--handlers
        (cl-remove-if (lambda (c) (string= (car c) name))
                      browsel--handlers)))

;; ── Built-in CLIENT_HELLO handler ────────────────────────────────────────────

(defconst browsel--instance-suffix-length 6
  "Number of hex characters from INSTANCE to append on a label collision.
6 leaves ~1 in 16M for a same-label-different-instance collision — well
below the point at which two profiles on one machine would notice.")

(defun browsel--resolve-client-name (label instance ws)
  "Return a display name for WS given LABEL and INSTANCE (both non-empty strings).
Returns LABEL when no other ws is registered under it.  On collision,
returns `LABEL-SHORT' where SHORT is the first
`browsel--instance-suffix-length' hex characters of INSTANCE.  In the
astronomically-unlikely event that suffix collides too, falls back to
the full `LABEL-INSTANCE'.  WS is permitted to already own LABEL
\(idempotent reuse — a hello arriving for the same ws that is already
mapped)."
  (let ((cell (assoc label browsel--clients)))
    (if (or (null cell) (eq (cdr cell) ws))
        label
      (let* ((short   (substring instance 0 browsel--instance-suffix-length))
             (name    (concat label "-" short))
             (again   (assoc name browsel--clients)))
        (if (or (null again) (eq (cdr again) ws))
            name
          (concat label "-" instance))))))

(defun browsel--close-stale-instance-ws (instance new-ws)
  "If INSTANCE is already registered on a ws other than NEW-WS, drop it.
The stale ws is unregistered from every state table and closed.  This
is what makes a reconnecting extension reuse its previous slot instead
of accumulating suffixes — the same INSTANCE arrives on a new ws while
the old ws has not yet been noticed as dead."
  (let ((cell (rassoc instance browsel--client-instances)))
    (when (and cell (not (eq (car cell) new-ws)))
      (let* ((stale-ws  (car cell))
             (name-cell (rassq stale-ws browsel--clients)))
        (browsel--log "[HELLO] instance %s already on stale ws (%s); \
closing and reusing slot"
                            (substring instance 0 browsel--instance-suffix-length)
                            (if name-cell (car name-cell) "?"))
        (setq browsel--clients
              (cl-remove-if (lambda (c) (eq (cdr c) stale-ws))
                            browsel--clients)
              browsel--client-instances
              (cl-remove-if (lambda (c) (eq (car c) stale-ws))
                            browsel--client-instances)
              browsel--rx-buffers
              (cl-remove-if (lambda (c) (eq (car c) stale-ws))
                            browsel--rx-buffers))
        (ignore-errors (websocket-close stale-ws))))))

(defun browsel--handle-client-hello (payload)
  "Built-in CLIENT_HELLO handler.
Renames the entry for the websocket currently being dispatched using
the LABEL and INSTANCE announced in PAYLOAD.  LABEL is the display
name (user-configurable, defaults to the build's kind).  INSTANCE is
a per-install UUID from the extension's `chrome.storage.local'; it is
stable across reconnects, so a hello arriving with an INSTANCE that
is already registered on a different ws replaces the stale entry
instead of appending a suffix.  On label collision between two
distinct instances, `LABEL-SHORT' is used (see
`browsel--resolve-client-name').

The PAYLOAD must include a `:version' string that exactly matches
`browsel-version'.  The version check is strict: any mismatch
\(including a missing or empty version) rejects the hello with an
error payload, leaves the client unregistered (its placeholder
\"unknown-N\" name persists), and the extension's ws-client treats
the connection as incompatible and stops the reconnect loop."
  (let ((ws        browsel--current-ws)
        (client    (plist-get payload :client))
        (raw-label (plist-get payload :label))
        (instance  (plist-get payload :instance))
        (version   (plist-get payload :version)))
    (unless ws
      (error "CLIENT_HELLO invoked outside a request dispatch"))
    (unless (and (stringp client) (not (string-empty-p client)))
      (error "CLIENT_HELLO requires payload.client (non-empty string)"))
    (unless (and (stringp instance)
                 (>= (length instance) browsel--instance-suffix-length))
      (error "CLIENT_HELLO requires payload.instance \
\(string with at least %d chars); got: %S"
             browsel--instance-suffix-length instance))
    (unless (and (stringp version) (not (string-empty-p version)))
      (error "CLIENT_HELLO requires payload.version (non-empty string); \
emacs=%s, extension sent: %S" browsel-version version))
    (unless (string= version browsel-version)
      (error "version mismatch: emacs=%s extension=%s; \
rebuild and reload both sides"
             browsel-version version))
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
      (browsel--close-stale-instance-ws instance ws)
      (let* ((final-name (browsel--resolve-hello-name
                          label label-set instance ws))
             (others     (cl-remove-if (lambda (c) (eq (cdr c) ws))
                                       browsel--clients))
             (other-ins  (cl-remove-if (lambda (c) (eq (car c) ws))
                                       browsel--client-instances)))
        (setq browsel--clients
              (cons (cons final-name ws) others)
              browsel--client-instances
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
            (browsel--registry-clear instance)
          (browsel--registry-set instance final-name))
        (browsel--log "[HELLO] %s instance=%s (clients=%d)"
                            final-name
                            (substring instance 0
                                       browsel--instance-suffix-length)
                            (length browsel--clients))
        `((status . "ok")
          (client . ,final-name))))))

(defun browsel--resolve-hello-name (label label-set instance ws)
  "Return the display name for a hello with LABEL and INSTANCE on WS.
LABEL-SET non-nil means the user configured a custom label — the
registry is ignored and `browsel--resolve-client-name' picks fresh
so a relabel in the options page takes effect immediately.  Nil
means the label is the default (equal to the client kind); consult
`browsel--name-registry' for a remembered name, falling back to
fresh resolution when the remembered name is currently held by
another live ws."
  (or (and (not label-set)
           (let* ((remembered (cdr (assoc instance browsel--name-registry)))
                  (cell       (and remembered
                                   (assoc remembered browsel--clients))))
             (and remembered
                  (or (null cell) (eq (cdr cell) ws))
                  remembered)))
      (browsel--resolve-client-name label instance ws)))

(browsel-register-handler "CLIENT_HELLO"
                                #'browsel--handle-client-hello)

;; ── Async request primitive (Emacs → browser) ────────────────────────────────

(defun browsel--cancel-all-pending (reason)
  "Cancel every pending callback with an error payload citing REASON."
  (let ((pending browsel--pending-callbacks))
    (setq browsel--pending-callbacks nil)
    (dolist (cell pending)
      (let ((id       (car cell))
            (callback (cadr cell))
            (timer    (cddr cell)))
        (when (timerp timer) (cancel-timer timer))
        (condition-case err
            (funcall callback `(:status "error" :message ,reason))
          (error
           (browsel--warn "cancellation callback for %s signalled: %s"
                                id (error-message-string err))))))))

(defun browsel-request-async (name payload callback &optional client)
  "Send a request NAME with PAYLOAD to the browser; invoke CALLBACK on response.
CALLBACK receives the decoded response payload (a plist).  If the
request times out (`browsel-request-timeout' seconds) CALLBACK is
called with (:status \"error\" :message \"timeout\").  Returns the
request id, or nil if no client is connected.

CLIENT, if non-nil, names which connected client to target (e.g.
\"chrome\", \"firefox\").  When omitted, the request is sent to the
sole connected client; when more than one is connected, CALLBACK is
invoked with a status:error payload and nil is returned."
  (pcase (browsel--target-for client name)
    (`(ok . ,ws)
     (let* ((id    (org-id-uuid))
            (timer (run-at-time browsel-request-timeout nil
                                #'browsel--timeout-request id)))
       (setq browsel--pending-callbacks
             (cons (cons id (cons callback timer))
                   browsel--pending-callbacks))
       (browsel--send-to ws
                               `((id      . ,id)
                                 (name    . ,name)
                                 (payload . ,(or payload :null))))
       id))
    (`(err . ,msg)
     (browsel--warn "%s" msg)
     (funcall callback `(:status "error" :message ,msg))
     nil)
    (`(none . ,msg)
     (browsel--warn "%s" msg)
     (funcall callback '(:status "error" :message "no client connected"))
     nil)))

(defun browsel--timeout-request (id)
  "Time out the pending request with ID."
  (let ((cell (assoc id browsel--pending-callbacks)))
    (when cell
      (setq browsel--pending-callbacks
            (cl-remove-if (lambda (c) (equal (car c) id))
                          browsel--pending-callbacks))
      (browsel--warn "request %s timed out after %ss"
                           id browsel-request-timeout)
      (condition-case err
          (funcall (cadr cell) '(:status "error" :message "timeout"))
        (error
         (browsel--warn "timeout callback for %s signalled: %s"
                              id (error-message-string err)))))))

(defun browsel-request (name &optional payload client)
  "Synchronously send NAME/PAYLOAD to the browser and return the response payload.
Blocks via `accept-process-output' until the response arrives or the
timeout elapses.  Signals an error on timeout, when no client is
connected, when more than one client is connected and CLIENT was not
supplied, or when CLIENT names a client that is not connected.
Do NOT use this from inside a websocket callback — it can re-enter
the dispatcher.

CLIENT, if non-nil, names the client to target (e.g. \"chrome\",
\"firefox\").  See `browsel-connected-clients' for the current
roster."
  (catch 'browsel--result
    (let ((id (browsel-request-async
               name payload
               (lambda (response)
                 (throw 'browsel--result response))
               client)))
      (unless id
        ;; Request-async already warned and invoked the callback with a
        ;; status:error payload, so escalate to an error here too.
        (error "Browsel-request: no acceptable target for %s" name))
      (let ((deadline (+ (float-time)
                         (+ 0.5 browsel-request-timeout))))
        (cl-labels
            ((pump ()
               (cond
                ((> (float-time) deadline)
                 (error "Request %s timed out" name))
                (t
                 (accept-process-output nil 0.05)
                 (pump)))))
          (pump))))))

;; ── Diagnostic timing advice ─────────────────────────────────────────────────
;;
;; Diagnostic scaffolding for the intermittent multi-second stalls
;; documented in ai/slow-random-response-time.md.  The advice is
;; installed unconditionally but only emits a *Messages* line when the
;; observed wall-clock time exceeds `browsel-slow-request-threshold'.
;; When `browsel-debug-timing' is non-nil AND the extension attached a
;; `:__timing' plist to the response frame, a per-stage breakdown is
;; appended so latency can be attributed to WS transport, offscreen
;; -> SW hop, in-SW dispatch, chrome.* API, or return trip.
;;
;; Revert plan (see slow-random-response-time.md): delete
;; `browsel-debug-timing', `browsel-slow-request-threshold',
;; `browsel--last-response-timing', `browsel--format-timing-deltas',
;; `browsel--timing-advice', and the `advice-add' call below; drop the
;; matching setq in `browsel--handle-response'.

(defun browsel--format-timing-deltas (t0-float timing dt-total)
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

(defun browsel--timing-advice (orig name &rest args)
  "Around advice on `browsel-request' that logs slow requests.
ORIG is the original function, NAME the request name, ARGS the
remaining args.  See ai/slow-random-response-time.md."
  (let ((t0 (float-time))
        ;; Clear before the call so a stale value from a prior request
        ;; cannot leak into this one's breakdown.
        (browsel--last-response-timing nil))
    (unwind-protect
        (let ((result (apply orig name args)))
          (let* ((dt        (- (float-time) t0))
                 (threshold browsel-slow-request-threshold)
                 (slow?     (and (numberp threshold) (> dt threshold))))
            (when slow?
              (let ((breakdown (and browsel-debug-timing
                                    (browsel--format-timing-deltas
                                     t0 browsel--last-response-timing dt))))
                (message "[browsel slow] %s took %.3fs @ %s%s"
                         name dt (format-time-string "%FT%T")
                         (if breakdown (concat " " breakdown) ""))))
            result))
      ;; Ensure the stash does not linger past this call even on error.
      (setq browsel--last-response-timing nil))))

(advice-add 'browsel-request :around #'browsel--timing-advice)

;; ── Convenience: respond-fast-then-defer ─────────────────────────────────────

(defun browsel-defer (fn &rest args)
  "Schedule FN to run with ARGS on the next idle tick.
Use inside a handler that wants to return immediately while the real
work happens out-of-band."
  (run-at-time 0 nil (lambda () (apply fn args))))

;; ── Payload cache (preserved across the rewrite) ─────────────────────────────
;;
;; Templates pull these via %(browsel-get-url) etc.  The variables
;; are populated by `browsel--prime-payload-cache' inside each
;; capture handler.

(defvar browsel--current-url nil
  "URL from the most recent browsel payload.")

(defvar browsel--current-title nil
  "Title from the most recent browsel payload.")

(defvar browsel--current-text nil
  "Selected text from the most recent browsel payload.")

(defun browsel-get-url ()
  "Return the URL from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browsel--current-url "")
    (setq browsel--current-url nil)))

(defun browsel-get-title ()
  "Return the title from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browsel--current-title "")
    (setq browsel--current-title nil)))

(defun browsel-get-selection ()
  "Return the selected text from the current payload and clear it.
Returns an empty string if not set or already consumed."
  (prog1 (or browsel--current-text "")
    (setq browsel--current-text nil)))

(defun browsel--prime-payload-cache (payload)
  "Populate the payload cache vars from PAYLOAD."
  (setq browsel--current-url   (plist-get payload :url)
        browsel--current-title (or (plist-get payload :title) "")
        browsel--current-text  (or (plist-get payload :text)  "")))

;; ── Shared helpers ───────────────────────────────────────────────────────────

(defun browsel--maybe-raise (payload)
  "Raise and focus the selected Emacs frame if PAYLOAD's :raise is t."
  (when (eq (plist-get payload :raise) t)
    (select-frame-set-input-focus (selected-frame))))

;; ── Client process activation (macOS) ────────────────────────────────────────
;;
;; Chrome activates its window via the WebExtension API on macOS;
;; Firefox often does not.  After a `FOCUS_TAB' that requested
;; `:focusWindow t', call `browsel-activate-client' to bring the
;; specific browser process to the OS foreground.  The PID-based
;; lookup disambiguates multiple instances of the same browser
;; (several Firefox profiles, for example).

(defun browsel--lsof-client-pids ()
  "Return the PIDs of processes connected OUT to `browsel-port'.
A connection's client row is the one whose NAME field's remote
endpoint is `:browsel-port'.  Filtering by the direction of the
arrow avoids confusing the server side (Emacs) with the clients.
Returns nil when `lsof' is unavailable or no connections exist."
  (let* ((remote (format "->127.0.0.1:%d" browsel-port))
         (raw    (with-temp-buffer
                   (when (zerop (call-process "lsof" nil t nil
                                              "-nP"
                                              (format "-iTCP:%d" browsel-port)
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

(defun browsel--pid-command (pid)
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

(defun browsel--client-pid (client)
  "Return the PID of the process connected to browsel as CLIENT, or nil.
Walks every established outbound TCP connection to `browsel-port',
asks `ps' for each candidate's full command line, and picks the
first whose path contains CLIENT (case-insensitive substring).
Disambiguates between multiple instances of the same browser
\(e.g. several Firefox profiles): each instance has a distinct PID
and only one of them holds the WebSocket to Emacs."
  (when (eq system-type 'darwin)
    (let ((needle (downcase client)))
      (seq-find
       (lambda (pid)
         (let ((cmd (browsel--pid-command pid)))
           (and cmd (string-match-p (regexp-quote needle)
                                    (downcase cmd)))))
       (browsel--lsof-client-pids)))))

(defun browsel--macos-activate-pid (pid)
  "Bring the macOS process with PID to the foreground, async.
Uses System Events because plain `open -a' would target whichever
instance of the bundled .app macOS considers canonical, not the
specific PID we know is holding the browsel WebSocket."
  (call-process
   "osascript" nil 0 nil
   "-e"
   (format
    "tell application \"System Events\" to set frontmost of (first process whose unix id is %d) to true"
    pid)))

(defun browsel-activate-client (client)
  "Bring the macOS app of CLIENT to the foreground if it needs the nudge.
No-op outside `system-type' `darwin' and for clients not in
`browsel-clients-needing-activation'.  PID-based activation via
`lsof' + `ps' + System Events is preferred; falls back to
`open -a APP' from `browsel-client-app-names' when the PID lookup
returns nothing.  Async (does not block the Emacs side)."
  (when (and (eq system-type 'darwin)
             (member client browsel-clients-needing-activation))
    (let ((pid (browsel--client-pid client)))
      (cond
       (pid
        (browsel--macos-activate-pid pid))
       (t
        (let ((app (cdr (assoc client browsel-client-app-names))))
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

(defconst browsel--safe-link-schemes
  '("http" "https" "ftp" "ftps" "mailto" "news")
  "Schemes accepted by `browsel--make-link'.
URLs with any other scheme (`elisp:', `shell:', `eshell:', `javascript:',
…) are rendered as plain text instead of a clickable Org link, so a
captured page cannot plant a link that runs code if a user later follows
it.  Add to this list only after weighing what `org-link-parameters'
does with the scheme in your config.")

(defun browsel--safe-link-url-p (url)
  "Return non-nil if URL's scheme is in `browsel--safe-link-schemes'."
  (and (stringp url)
       (let ((case-fold-search t))
         (when (string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\):" url)
           (member (downcase (match-string 1 url))
                   browsel--safe-link-schemes)))))

(defun browsel--escape-org-link-target (s)
  "Make S safe to splice as the target of an Org link.
A literal `]' breaks the link parser; replace with its URL-encoded form."
  (replace-regexp-in-string "\\]" "%5D" (or s "")))

(defun browsel--escape-org-link-desc (s)
  "Make S safe to splice as the description of an Org link.
Collapses newlines (descriptions must be single-line) and replaces the
bracket characters with curly look-alikes so they cannot close the
description bracket."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[\n\r]+" " " s))
         (s (replace-regexp-in-string "\\]" "}" s))
         (s (replace-regexp-in-string "\\[" "{" s)))
    s))

(defun browsel--make-link (url description)
  "Return `[[URL][DESCRIPTION]]' when URL has a safe scheme.
Otherwise return a plain-text fallback like `desc (url)' so a captured
page cannot plant a clickable `elisp:'/`shell:'/`javascript:' link.
DESCRIPTION defaults to URL if nil or empty."
  (let* ((url (or url ""))
         (description (if (and (stringp description)
                               (not (string-empty-p description)))
                          description
                        url)))
    (if (browsel--safe-link-url-p url)
        (format "[[%s][%s]]"
                (browsel--escape-org-link-target url)
                (browsel--escape-org-link-desc description))
      (format "%s (%s)"
              (browsel--escape-org-link-desc description)
              (browsel--escape-org-link-desc url)))))

(defun browsel--sanitize-org-meta (s)
  "Sanitize S for a single-line Org metadata context.
Use for property-drawer values, `#+keyword:' lines, headings.
Collapses newlines to spaces and replaces `]' with `}' so a value cannot
terminate a surrounding link or drawer line, or carry a heading break."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[\n\r]+" " " s))
         (s (replace-regexp-in-string "\\]" "}" s)))
    s))

(defun browsel--sanitize-org-body (s)
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

(defun browsel--capture-initial (payload)
  "Build the org-capture-initial string from PAYLOAD's url, title, and text.
The link is built via `browsel--make-link' (which blocks unsafe schemes)
and any body text is passed through `browsel--sanitize-org-body' so it
cannot introduce headings or drawer markers."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "Web capture"))
         (text  (or (plist-get payload :text) "")))
    (concat (browsel--make-link url title)
            (unless (string-empty-p text)
              (concat "\n\n" (browsel--sanitize-org-body text))))))

(defun browsel--store-link-plist (payload)
  "Return an `org-store-link-plist' for PAYLOAD's url and title.
Drives `%a' (annotation) expansion in `org-capture' templates so that
each capture sees the current browser link rather than whatever link
Emacs happened to store last.  `:annotation' is set explicitly because
`org-capture' reads it directly when `org-capture-link-is-already-stored'
is non-nil.  For an unsafe URL scheme the `:link' field is left blank
\(so `%L'/`%l' do not splice a clickable bad link) and `:annotation' is
the plain-text rendering produced by `browsel--make-link'."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "Web capture")))
    (list :type "http"
          :link        (if (browsel--safe-link-url-p url) url "")
          :description (browsel--escape-org-link-desc title)
          :annotation  (browsel--make-link url title))))

(defun browsel--require-payload (payload)
  "Signal if PAYLOAD is nil."
  (unless payload
    (error "Missing 'payload' in request")))

(defun browsel--ok (&optional message)
  "Return a standard OK response payload, optionally with MESSAGE."
  (if message
      `((status . "ok") (message . ,message))
    '((status . "ok"))))

(defun browsel--strip-svg (html)
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

(defun browsel--handle-org-capture (payload)
  "Handle ORG_CAPTURE request with PAYLOAD.
Schedules the actual capture and returns immediately (respond-fast-then-defer)."
  (browsel--require-payload payload)
  (browsel-defer #'browsel--org-capture payload)
  (browsel--ok "Org-capture started"))

(defun browsel--handle-org-roam-capture (payload)
  "Handle ORG_ROAM_CAPTURE request with PAYLOAD.
Schedules the actual capture and returns immediately (respond-fast-then-defer)."
  (browsel--require-payload payload)
  (browsel-defer #'browsel--org-roam-capture payload)
  (browsel--ok "Org-roam-capture started"))

(defun browsel--handle-eww (payload)
  "Handle EWW request with PAYLOAD.
Schedules the eww invocation and returns immediately
\(respond-fast-then-defer)."
  (browsel--require-payload payload)
  (unless (plist-get payload :url)
    (error "Missing url in payload"))
  (browsel-defer #'browsel--eww payload)
  (browsel--ok "Eww started"))

;; ── Action implementations ───────────────────────────────────────────────────

(defun browsel--org-capture (payload)
  "Open `org-capture' pre-filled from PAYLOAD.
Uses `browsel-org-capture-key' if set, otherwise prompts interactively."
  (condition-case err
      (let ((org-capture-initial              (browsel--capture-initial payload))
            (org-store-link-plist             (browsel--store-link-plist payload))
            (org-capture-link-is-already-stored t))
        (browsel--prime-payload-cache payload)
        (browsel--maybe-raise payload)
        (org-capture nil browsel-org-capture-key))
    (error
     (browsel--warn "org-capture failed: %s" (error-message-string err)))))

(defun browsel--org-roam-capture (payload)
  "Open org-roam-capture, seeding the payload cache from PAYLOAD."
  (condition-case err
      (let ((org-capture-initial              (browsel--capture-initial payload))
            (org-store-link-plist             (browsel--store-link-plist payload))
            (org-capture-link-is-already-stored t))
        (browsel--prime-payload-cache payload)
        (browsel--maybe-raise payload)
        (org-roam-capture-
         :node (org-roam-node-create)))
    (error
     (browsel--warn "org-roam-capture failed: %s" (error-message-string err)))))

(defun browsel--eww (payload)
  "Open the URL from PAYLOAD in eww."
  (condition-case err
      (let ((url (plist-get payload :url)))
        (browsel--maybe-raise payload)
        (eww url))
    (error
     (browsel--warn "eww failed: %s" (error-message-string err)))))

;; ── Register built-in handlers ───────────────────────────────────────────────

(browsel-register-handler "ORG_CAPTURE"      #'browsel--handle-org-capture)
(browsel-register-handler "ORG_ROAM_CAPTURE" #'browsel--handle-org-roam-capture)
(browsel-register-handler "EWW"              #'browsel--handle-eww)

;; ── Emacs-side quick helpers ────────────────────────────────────────────────
;;
;; Small commands that grab something from the active browser tab and
;; either insert it at point (interactive call) or return it as a
;; string (Lisp call).  CLIENT, when non-nil, names the connected
;; client; nil delegates the choice to `browsel-request' (which uses
;; the sole connected client or signals if more than one is
;; connected).

;;;###autoload
(defun browsel-set-default-client (&optional client)
  "Set `browsel-default-client' to CLIENT.
With a prefix argument, clear the setting back to nil without
prompting (subsequent commands fall back to auto-detection /
prompt-on-ambiguity).  Interactively, prompts via `completing-read'
over the currently-connected clients plus the literal \"eww\";
defaults to the existing value when it is still connected,
otherwise to the first connected client.  Selecting \"eww\" stores
the string \"eww\", which routes `browsel-browse-url' to eww
instead of a browser — every other browsel command then falls
back to its single-connected / prompt-on-ambiguity behavior.

The model is: interactive use targets one browser at a time —
this command picks which one.  Programmatic callers can still
talk to either browser concurrently by passing an explicit
CLIENT argument to `browsel-request' or any of the helpers."
  (interactive
   (list
    (if current-prefix-arg
        nil
      (let* ((connected (browsel-connected-clients))
             (choices   (append connected '("eww"))))
        (unless connected
          (user-error "Browsel: no client connected"))
        (let ((chosen
               (completing-read
                (format "Default browser (%s): "
                        (mapconcat #'identity choices ", "))
                choices nil t nil nil
                (cond
                 ((equal browsel-default-client "eww") "eww")
                 ((and (member browsel-default-client connected)
                       browsel-default-client))
                 (t (car connected))))))
          chosen)))))
  (setq browsel-default-client client)
  (message "browsel-default-client = %S" client))

(defun browsel--read-client-interactive ()
  "Return a connected browsel client name for an interactive command.
Resolution order:
  1. `browsel-default-client' when it names a currently-connected
     client.
  2. The sole connected client when only one is connected.
  3. A `completing-read' over the connected clients when more than
     one is connected — and the chosen value is stored into
     `browsel-default-client' so subsequent commands stop asking.
     The setting survives for the rest of the Emacs session; put a
     `setq' in your config to make it permanent.
Signals `user-error' when no client is connected.  Lisp callers
that want the same behavior can call this directly; the bare-Lisp
path (passing CLIENT=nil to a helper) still delegates to
`browsel-request' and errors on ambiguous multi-client state."
  (let ((connected (browsel-connected-clients)))
    (cond
     ((null connected)
      (user-error "Browsel: no client connected"))
     ;; `browsel-default-client' set to "eww" is URL-routing only;
     ;; non-URL helpers (the callers of this function) need an actual
     ;; WS-bridge client, so fall through as if no default were set.
     ((and browsel-default-client
           (not (equal browsel-default-client "eww"))
           (member browsel-default-client connected))
      browsel-default-client)
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
        ;; isn't asked again every time a browsel command runs.  Do
        ;; not overwrite an "eww" default — that setting is a
        ;; deliberate URL-routing choice the user can keep across
        ;; transient WS-bridge picks made here.
        (unless (equal browsel-default-client "eww")
          (setq browsel-default-client chosen))
        chosen)))))

(defun browsel--active-tab (&optional client)
  "Return the active tab plist from CLIENT, or signal if none."
  (let ((tab (car (browsel-request "GET_ACTIVE_TAB" nil client))))
    (unless tab
      (error "Browsel: no active tab"))
    tab))

(defun browsel--eval-active (code &optional client)
  "Run CODE in the active tab of CLIENT and return its result value.
Unwraps the standard `EVAL_IN_ACTIVE_TAB' response shape."
  (let ((resp (browsel-request "EVAL_IN_ACTIVE_TAB"
                               (list :code code) client)))
    (plist-get (car (plist-get resp :result)) :result)))

;;;###autoload
(defun browsel-org-link (&optional client)
  "Insert (or return) an Org link to the active browser tab.
The link is `[[URL][TITLE]]' built via `browsel--make-link', so
unsafe schemes (elisp:, javascript:, …) fall back to a plain-text
rendering.  When called interactively the link is inserted at point
and the return value is nil; when called from Lisp the link string
is returned.  CLIENT, when non-nil, names the connected browsel
client; interactively the command prompts when more than one client
is connected."
  (interactive (list (browsel--read-client-interactive)))
  (let* ((tab   (browsel--active-tab client))
         (url   (plist-get tab :url))
         (title (or (plist-get tab :title) url))
         (link  (browsel--make-link url title)))
    (if (called-interactively-p 'any)
        (progn (insert link) nil)
      link)))

;;;###autoload
(defun browsel-selection (&optional client)
  "Insert (or return) the active tab's current text selection.
When called interactively, the selection text is inserted at point
and the return value is nil; when called from Lisp the selection
string is returned (empty string when nothing is selected).
CLIENT, when non-nil, names the connected browsel client;
interactively the command prompts when more than one client is
connected."
  (interactive (list (browsel--read-client-interactive)))
  (let* ((raw  (browsel--eval-active
                "window.getSelection().toString()" client))
         (text (or raw "")))
    (if (called-interactively-p 'any)
        (progn (insert text) nil)
      text)))

;;;###autoload
(defun browsel-url (&optional client)
  "Insert (or return) the URL of the active browser tab.
When called interactively, the URL is inserted at point and the
return value is nil; when called from Lisp the URL string is
returned, or nil when the tab has no URL.  CLIENT, when non-nil,
names the connected browsel client; interactively the command
prompts when more than one client is connected."
  (interactive (list (browsel--read-client-interactive)))
  (let ((url (plist-get (browsel--active-tab client) :url)))
    (if (called-interactively-p 'any)
        (progn (insert (or url "")) nil)
      url)))

;;;###autoload
(defun browsel-title (&optional client)
  "Insert (or return) the title of the active browser tab.
When called interactively, the title is inserted at point and the
return value is nil; when called from Lisp the title string is
returned, or nil when the tab has no title.  CLIENT, when non-nil,
names the connected browsel client; interactively the command
prompts when more than one client is connected."
  (interactive (list (browsel--read-client-interactive)))
  (let ((title (plist-get (browsel--active-tab client) :title)))
    (if (called-interactively-p 'any)
        (progn (insert (or title "")) nil)
      title)))

(defun browsel--format-time-hms (total-seconds)
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
(defun browsel-video-current-time (&optional client)
  "Insert (or return) the first `<video>' element's current time.
Format is `H:MM:SS' for an hour or more, `M:SS' for sub-hour, and a
bare `S' for sub-minute (see `browsel--format-time-hms').  When
called interactively the timestamp is inserted at point and nil is
returned; from Lisp the string is returned.  Signals `user-error'
if the active tab has no video element.  CLIENT, when non-nil,
names the connected browsel client; interactively the command
prompts when more than one client is connected."
  (interactive (list (browsel--read-client-interactive)))
  (let* ((code "(() => { const v = document.querySelector('video');
                         return v ? v.currentTime : null; })()")
         (seconds (browsel--eval-active code client)))
    (unless (numberp seconds)
      (user-error "Browsel: no video on this page"))
    (let ((str (browsel--format-time-hms seconds)))
      (if (called-interactively-p 'any)
          (progn (insert str) nil)
        str))))

;;;###autoload
(defun browsel-video-toggle-play (&optional client)
  "Toggle play / pause on the first `<video>' in the active tab.
Plays if the video is paused, pauses if it is playing.  Messages the
new state in the echo area.  Errors with a short message if the page
has no video element.  CLIENT, when non-nil, names the connected
browsel client; interactively the command prompts when more than
one client is connected."
  (interactive (list (browsel--read-client-interactive)))
  (let* ((code
          "(() => {
             const v = document.querySelector('video');
             if (!v) return { ok: false, reason: 'no video on this page' };
             if (v.paused) { v.play(); return { ok: true, state: 'playing' }; }
             v.pause(); return { ok: true, state: 'paused' };
           })()")
         (result (browsel--eval-active code client)))
    (unless (plist-get result :ok)
      (user-error "browsel: %s"
                  (or (plist-get result :reason) "unknown")))
    (message "Video %s" (plist-get result :state))))

;;;###autoload
(defun browsel-video-advance (&optional arg client)
  "Advance the first `<video>' in the active tab by ARG seconds.
Default is 5 seconds forward.  A numeric prefix N seeks N seconds
\(sign honored — negative goes back).  A bare `C-u' or
`\\[negative-argument]' seeks 5 seconds back.  Errors with a short
message if the page has no video element.  CLIENT, when non-nil,
names the connected browsel client; interactively the command
prompts when more than one client is connected."
  (interactive (list current-prefix-arg
                     (browsel--read-client-interactive)))
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
         (result (browsel--eval-active code client)))
    (unless (plist-get result :ok)
      (user-error "browsel: %s"
                  (or (plist-get result :reason) "unknown")))
    (message "Video at %.1fs" (plist-get result :currentTime))))

;;;###autoload
(defun browsel-scroll-page (&optional arg client)
  "Scroll the active browser tab by ARG viewport heights.
With no prefix: scroll one page forward.  A numeric prefix N scrolls
N pages (sign honored — positive forward, negative back).  A bare
`C-u' or `\\[negative-argument]' scrolls one page back — these
non-numeric prefixes invert direction with magnitude 1, since they
do not encode a page count themselves.  CLIENT, when non-nil, names
the connected browsel client; interactively the command prompts
when more than one client is connected."
  (interactive (list current-prefix-arg
                     (browsel--read-client-interactive)))
  (let* ((n (cond
             ((null arg) 1)
             ((numberp arg) arg)
             (t -1)))
         (code (format
                "window.scrollBy({top: (%d) * window.innerHeight, left: 0, behavior: 'smooth'})"
                n)))
    (browsel--eval-active code client)
    (when (called-interactively-p 'any)
      (message "Scrolled %d page%s" n (if (= (abs n) 1) "" "s")))))

(provide 'browsel)

;;; browsel.el ends here
