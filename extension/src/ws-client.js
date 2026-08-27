// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// ws-client.js — WebSocket client used by every browser-gt target.
//
// One entry point: `startWebSocketClient(options)`.  It opens a
// WebSocket to the Emacs server, identifies itself with a CLIENT_HELLO
// request, correlates request/response frames, and reconnects on close.
//
// Wire protocol (spookfox-compatible):
//
//   Emacs ↔ browser request : { id, name, payload }
//   Emacs ↔ browser response: { requestId, payload }
//
// The same module is imported by Chrome's offscreen document (where the
// WebSocket has to live, because MV3 service workers idle) and by the
// Firefox background page (which is persistent and holds the socket
// directly).  Per-target glue is supplied through `options`:
//
//   options.clientName        REQUIRED string, e.g. "chrome" or
//                             "firefox".  Identifies the KIND of
//                             browser (used by Emacs for macOS
//                             activation and app-name lookups); hard
//                             coded per build.
//   options.instance          REQUIRED string, per-install UUID from
//                             src/identity.js.  Emacs uses it to
//                             disambiguate collisions when two clients
//                             share a label, and to recognise a
//                             reconnect from the same install (so the
//                             stale entry can be replaced instead of
//                             accumulating suffixes).
//   options.label             Optional string, user-visible display
//                             name.  Defaults to options.clientName on
//                             the wire when omitted.  Set from the
//                             extension options page to distinguish
//                             two Chrome profiles from each other, for
//                             example.
//   options.version           REQUIRED string, the extension's
//                             manifest version.  Sent alongside the
//                             client name; Emacs requires an exact
//                             match against its `browser-gt-version'
//                             or it rejects the hello and the
//                             connection enters the terminal
//                             INCOMPATIBLE state.
//   options.onStatus          (status) → void.  Called on every change
//                             of "CONNECTING" / "CONNECTED" /
//                             "DISCONNECTED" / "INCOMPATIBLE".  The
//                             INCOMPATIBLE state is terminal: the
//                             socket is closed and no reconnect is
//                             attempted until reconnect() is called
//                             explicitly.
//   options.onIncompatible    Optional (message) → void.  Invoked
//                             once with the mismatch text so the host
//                             can raise a notification or badge.
//   options.onIncomingRequest (request) → Promise<responsePayload>.
//                             Called when Emacs sends a request frame.
//                             The returned payload is sent back as
//                             { requestId, payload }.
//   options.url               WebSocket URL.  Default
//                             "ws://127.0.0.1:9130".  127.0.0.1 — not
//                             "localhost" — avoids IPv6 resolution
//                             failure on macOS.
//   options.reconnectMs       Reconnect delay in ms.  Default 5000.
//   options.requestTimeoutMs  Per-request timeout in ms.  Default 5000.
//
// Returns { sendRequest, reconnect, getStatus }.

const DEFAULT_URL              = "ws://127.0.0.1:9130";
const DEFAULT_RECONNECT_MS     = 5000;
const DEFAULT_REQUEST_TIMEOUT  = 5000;

// ── Diagnostic timing ────────────────────────────────────────────────────
//
// See doc/latency-instrumentation.org.  DEBUG_TIMING gates the drift
// heartbeat below; it is the only periodic work this module does, so it
// is the only thing worth a flag.  The timestamp prefix on `log' costs
// nothing beyond what the surrounding frame logging already costs and
// is always on.
//
// RESET TO false BEFORE CUTTING A RELEASE.  The heartbeat wakes the
// socket host twice a second for the lifetime of the browser session.
const DEBUG_TIMING       = true;
const HEARTBEAT_MS       = 500;
const DRIFT_THRESHOLD_MS = 200;

export function startWebSocketClient(options) {
  if (!options || typeof options.clientName !== "string" || !options.clientName) {
    throw new Error("startWebSocketClient: options.clientName (string) required");
  }
  if (typeof options.instance !== "string" || !options.instance) {
    throw new Error("startWebSocketClient: options.instance (string) required");
  }
  if (options.label !== undefined
      && (typeof options.label !== "string" || !options.label)) {
    throw new Error("startWebSocketClient: options.label, when given, must be a non-empty string");
  }
  if (typeof options.version !== "string" || !options.version) {
    throw new Error("startWebSocketClient: options.version (string) required");
  }
  if (typeof options.onStatus !== "function") {
    throw new Error("startWebSocketClient: options.onStatus (function) required");
  }
  if (typeof options.onIncomingRequest !== "function") {
    throw new Error("startWebSocketClient: options.onIncomingRequest (function) required");
  }

  const url             = options.url             ?? DEFAULT_URL;
  const reconnectMs     = options.reconnectMs     ?? DEFAULT_RECONNECT_MS;
  const requestTimeout  = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT;
  const displayName     = options.label ?? options.clientName;
  const tag             = `[ws:${displayName}]`;

  let ws             = null;
  let reconnectTimer = null;
  let status         = "DISCONNECTED";
  // Terminal state: when set, the close handler suppresses the auto
  // reconnect.  An explicit reconnect() call clears it so the user can
  // recover after rebuilding both sides.
  let incompatible   = false;
  const pending      = new Map();   // requestId → { resolve, reject, timer }

  // Epoch milliseconds, not a formatted time: the Emacs side stamps its
  // *browser-gt* timing lines the same way, from the same system clock,
  // so lines from the two logs can be merged and compared directly.
  function log(...args) {
    console.log(`[${Date.now()}]`, tag, ...args);
  }

  // The host of this socket is a page with no visible content — Chrome's
  // offscreen document, or Firefox's background page.  Chrome lowers the
  // priority of a renderer hosting no visible page, so an arriving frame
  // can wait in the task queue before `onMessage' runs.  The Emacs side
  // cannot see where the frame stopped and reports that wait as
  // transport cost.
  //
  // A fixed-period timer that reports its own lateness exposes the stall
  // without needing a request to provoke it.  Caveat when reading the
  // output: browsers throttle timers in hidden pages by policy, so drift
  // here is an upper bound on the problem, not a direct measurement of
  // it.  The informative case is the disagreement — frames arriving late
  // while drift stays near zero means task delivery, not scheduling, is
  // the delay.
  function startDriftHeartbeat() {
    let expected = Date.now() + HEARTBEAT_MS;
    setInterval(() => {
      const now   = Date.now();
      const drift = now - expected;
      expected = now + HEARTBEAT_MS;
      if (drift > DRIFT_THRESHOLD_MS) {
        log(`event-loop drift ${drift}ms (heartbeat period ${HEARTBEAT_MS}ms)`);
      }
    }, HEARTBEAT_MS);
  }

  function setStatus(next) {
    if (status === next) return;
    status = next;
    try { options.onStatus(status); }
    catch (e) { log("onStatus threw:", e); }
  }

  function clearReconnect() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  }

  function scheduleReconnect() {
    clearReconnect();
    reconnectTimer = setTimeout(connect, reconnectMs);
  }

  function connect() {
    clearReconnect();
    if (ws && (ws.readyState === WebSocket.OPEN ||
               ws.readyState === WebSocket.CONNECTING)) {
      return;
    }
    setStatus("CONNECTING");
    log("connecting to", url);
    try {
      ws = new WebSocket(url);
    } catch (e) {
      log("WebSocket constructor failed:", e);
      setStatus("DISCONNECTED");
      scheduleReconnect();
      return;
    }
    ws.addEventListener("open", onOpen);
    ws.addEventListener("close", onClose);
    ws.addEventListener("error", onError);
    ws.addEventListener("message", onMessage);
  }

  async function onOpen() {
    log("connected");
    setStatus("CONNECTED");
    // Identify ourselves first.  This must complete before any other
    // outgoing request, so that Emacs has a name to address us by when
    // both Chrome and Firefox are connected at once.  The hello carries
    // the extension's version; an exact mismatch against the Emacs side
    // returns an error reply that we treat as terminal.
    try {
      // `label' is included only when the user has explicitly set
      // one in the extension options page.  Defaulting to
      // `clientName' here would rob the Emacs side of the ability
      // to distinguish "user labeled this install 'chrome'" from
      // "user has no label at all" — both would arrive as
      // `label: "chrome"' and the registry-versus-user-intent
      // logic in `browser-gt--handle-client-hello' could not tell
      // which case applies.
      const helloPayload = {
        client:   options.clientName,
        instance: options.instance,
        version:  options.version,
      };
      if (options.label !== undefined) {
        helloPayload.label = options.label;
      }
      const reply = await sendRequest("CLIENT_HELLO", helloPayload);
      if (reply && reply.status === "error") {
        const message = reply.message ?? "CLIENT_HELLO rejected";
        log("incompatible:", message);
        incompatible = true;
        try { options.onIncompatible?.(message); }
        catch (e) { log("onIncompatible threw:", e); }
        setStatus("INCOMPATIBLE");
        try { ws.close(); } catch (e) { /* already closing */ }
        return;
      }
      log("CLIENT_HELLO acknowledged as", reply?.client ?? displayName);
    } catch (e) {
      log("CLIENT_HELLO failed:", e?.message ?? e);
    }
  }

  function onClose() {
    log("closed");
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error("WebSocket closed before response"));
      pending.delete(id);
    }
    if (incompatible) {
      // Stay in INCOMPATIBLE; an explicit reconnect() call resets the
      // flag so the user can recover after rebuilding both sides.
      return;
    }
    setStatus("DISCONNECTED");
    scheduleReconnect();
  }

  function onError(e) {
    log("error", e);
    // The "close" event will follow; let it drive the reconnect.
  }

  function onMessage(event) {
    handleFrame(event.data);
  }

  function tryParse(text) {
    try { return JSON.parse(text); }
    catch (e) {
      log("bad frame", e?.message ?? e, text);
      return null;
    }
  }

  function handleFrame(text) {
    log("recv", text);
    const msg = tryParse(text);
    if (msg === null) return;

    if (msg.name) {
      // Emacs is asking us for something.
      //
      // `onIncomingRequest' may return either a plain payload or a
      // { payload, __timing } envelope.  The envelope form lets a
      // target (currently Chrome) attach diagnostic timing to the wire
      // frame without polluting the payload shape — payloads may be
      // arrays or scalars where object-spreading `__timing' inside
      // would corrupt the value.  See doc/latency-instrumentation.org.
      Promise.resolve()
        .then(() => options.onIncomingRequest(msg))
        .then(
          (result) => sendFrame(buildResponseFrame(msg.id, result)),
          (e) => sendFrame({ requestId: msg.id,
                             payload: { status: "error", message: e?.message ?? String(e) } }),
        );
      return;
    }
    if (msg.requestId) {
      const entry = pending.get(msg.requestId);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(msg.requestId);
      entry.resolve(msg.payload);
      return;
    }
    log("unknown frame shape", msg);
  }

  // Build the response wire frame from whatever `onIncomingRequest'
  // returned.  Envelope shape `{ payload, __timing }' is unpacked so
  // `__timing' sits alongside `payload' on the wire, not nested inside
  // it.  Any other shape is treated as the payload itself.
  function buildResponseFrame(requestId, result) {
    if (result
        && typeof result === "object"
        && !Array.isArray(result)
        && Object.prototype.hasOwnProperty.call(result, "__timing")
        && Object.prototype.hasOwnProperty.call(result, "payload")) {
      return { requestId,
               payload:   result.payload ?? { status: "ok" },
               __timing:  result.__timing };
    }
    return { requestId, payload: result ?? { status: "ok" } };
  }

  function sendFrame(obj) {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      throw new Error("WebSocket not connected");
    }
    const text = JSON.stringify(obj);
    log("send", text);
    ws.send(text);
  }

  function sendRequest(name, payload) {
    return new Promise((resolve, reject) => {
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        reject(new Error("not connected"));
        return;
      }
      const id = crypto.randomUUID();
      const timer = setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error(`request ${name} timed out`));
        }
      }, requestTimeout);
      pending.set(id, { resolve, reject, timer });
      try {
        sendFrame({ id, name, payload: payload ?? null });
      } catch (e) {
        clearTimeout(timer);
        pending.delete(id);
        reject(e);
      }
    });
  }

  function reconnect() {
    // Manual reconnect clears the terminal state.  If the underlying
    // mismatch hasn't been fixed the next CLIENT_HELLO will be rejected
    // again and incompatible will be set anew; if it has, the
    // connection proceeds normally.
    incompatible = false;
    if (ws) {
      try { ws.close(); } catch (e) {}
    }
    connect();
  }

  function getStatus() { return status; }

  connect();
  if (DEBUG_TIMING) startDriftHeartbeat();
  return { sendRequest, reconnect, getStatus };
}
