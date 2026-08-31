// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// offscreen.js (Chrome) — host the WebSocket on behalf of the service
// worker.
//
// MV3 service workers idle out after ~30s and would kill any WebSocket
// they held.  An offscreen document is a hidden DOM page that does not
// idle, so it is a safe host for the long-lived socket.  All of the
// actual WebSocket logic lives in `src/ws-client.js`; this file is
// only the offscreen-side glue: it wires the shared client to
// chrome.runtime messages so the service worker can drive
// send/reconnect/status-query and so incoming Emacs requests can hop
// back up to the SW for handler dispatch.

import { startWebSocketClient } from "./ws-client.js";
import { stamp } from "./log-stamp.js";

// Epoch-millisecond and civil-time prefix so these lines interleave with
// the Emacs *browser-gt* timing log; see doc/latency-instrumentation.org.
function log(...args) { console.log(`[${stamp()}]`, "[offscreen]", ...args); }

// Ask the service worker to dispatch one Emacs-initiated request and
// resolve with the payload it returns.  The SW already has the
// merged handler config; doing the dispatch here would require
// duplicating that, and the SW is alive whenever a frame arrives
// (the WebSocket message wakes it).
function dispatchIncomingViaServiceWorker(request, arrivedAt) {
  // See doc/latency-instrumentation.org.  `t1' marks the moment the
  // incoming request is observed at the offscreen document — the
  // earliest point the extension code can see it.  ws-client passes it
  // in from the socket's own message event; the fallback covers a
  // caller that does not supply one.  Forwarded to the SW so `t2 - t1'
  // isolates the offscreen -> SW hop (SW cold-start signature).
  const t1 = arrivedAt ?? Date.now();
  // `parse' is the interval this document spent between the socket
  // event and handing the request off: JSON.parse plus the frame log.
  // It is inside what Emacs reports as `ws' and is worth naming, since
  // frame logging is on by default in this build.
  log(`dispatch ${request?.name ?? "?"} id=${request?.id ?? "?"}`
      + ` t1=${t1} parse=${Date.now() - t1}ms`);
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(
      { target: "service-worker", type: "WS_REQUEST", request, t1 },
      (response) => {
        // Round trip as seen from here: SW wake-up, dispatch, the
        // chrome.* call, and the reply coming back.  The SW reports the
        // same interval broken down; a large difference between the two
        // is messaging overhead this side cannot otherwise attribute.
        log(`dispatched ${request?.name ?? "?"} id=${request?.id ?? "?"}`
            + ` in ${Date.now() - t1}ms`);
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }
        resolve(response ?? { status: "ok" });
      },
    );
  });
}

// Offscreen documents expose only the messaging subset of
// chrome.runtime — `getManifest` is not in that subset, so we ask the
// service worker for the extension's version.  Identity (the
// persistent per-install UUID and the optional user-set label) is
// fetched through the SW for the same reason: routing storage access
// through one owner avoids a race where SW and offscreen would both
// try to create the initial UUID.  Top-level await on an ES module
// delays the rest of this file until the SW responds, which is
// acceptable here because the SW's onMessage listener is registered
// synchronously at SW boot and is reachable as soon as this document
// has been created.
function askServiceWorker(type) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(
      { target: "service-worker", type },
      (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }
        if (!response) {
          reject(new Error(`service worker returned no response for ${type}`));
          return;
        }
        if (response.error) {
          reject(new Error(response.error));
          return;
        }
        resolve(response);
      },
    );
  });
}

const versionResponse  = await askServiceWorker("GET_VERSION");
const identityResponse = await askServiceWorker("GET_IDENTITY");
const version  = versionResponse.version;
const instance = identityResponse.instance;
const label    = identityResponse.label;
log("starting ws client at version", version,
    "instance", instance,
    label ? `label ${label}` : "no label");

const client = startWebSocketClient({
  clientName: "chrome",
  instance,
  label,
  version,
  onStatus: (status) => {
    chrome.runtime
      .sendMessage({ target: "service-worker", type: "WS_STATUS", status })
      .catch(() => {});
  },
  onIncompatible: (message) => {
    chrome.runtime
      .sendMessage({ target: "service-worker", type: "WS_INCOMPATIBLE", message })
      .catch(() => {});
  },
  onIncomingRequest: dispatchIncomingViaServiceWorker,
});

// Messages from the service worker.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.target !== "offscreen") return false;
  switch (msg.type) {
    case "WS_STATUS_QUERY":
      sendResponse({ status: client.getStatus() });
      return false;

    case "WS_RECONNECT":
      try {
        client.reconnect();
        sendResponse({ ok: true });
      } catch (e) {
        sendResponse({ ok: false, error: e?.message ?? String(e) });
      }
      return false;

    case "SEND_REQUEST":
      client.sendRequest(msg.name, msg.payload).then(
        (payload) => sendResponse({ ok: true, payload }),
        (e)       => sendResponse({ ok: false, error: e?.message ?? String(e) }),
      );
      return true;

    default:
      log("unknown message type:", msg.type);
      return false;
  }
});
