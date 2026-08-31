// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// background.js (Firefox MV2) — persistent background page entry.
//
// All routing logic lives in src/core.js.  Firefox MV2 has a real
// persistent background page: it loads at extension start, stays
// resident as long as the browser is running, and holds the
// WebSocket directly via src/ws-client.js.  No offscreen indirection,
// no alarms heartbeat, no idle window.
//
// One MV2/MV3 difference must be papered over before the shared code
// runs: the toolbar action API.  Chrome MV3 calls `browser.action.*`;
// Firefox MV2 calls `browser.browserAction.*`.  The shared core.js
// uses `api.action`, so we alias it here, once, at module load.  The
// alias is a side effect of evaluating this module; subsequent
// imports of core.js then resolve `api.action.setIcon` against the
// MV2 API.

if (typeof browser !== "undefined"
    && !browser.action
    && browser.browserAction) {
  browser.action = browser.browserAction;
}

import {
  initRouter,
  setWsStatus,
  dispatchIncomingEmacsRequest,
} from "./core.js";
import { startWebSocketClient } from "./ws-client.js";
import { readOrCreateIdentity } from "./identity.js";
import { initFocusTracking } from "./focus-tracker.js";
import { stamp } from "./log-stamp.js";
import { formatMarks } from "./handlers.js";

initFocusTracking();

// ── Diagnostic timing ───────────────────────────────────────────────────────
//
// See doc/latency-instrumentation.org.  The MV2 build has no offscreen
// document and no service worker, so two of the four stamps Chrome
// reports do not exist here: the socket and the handlers live in the same
// persistent page.  `t2' is set equal to `t1' so `hop' reads 0 and the
// Emacs-side formatter, which requires all four, still works.
//
// This is the point of measuring Firefox at all: a stall that appears on
// Chrome and not here isolates the fault to the offscreen indirection,
// and one that appears on both puts it in the socket or in Emacs.
function log(...args) { console.log(`[${stamp()}]`, "[bg]", ...args); }

function logTiming(request, timing) {
  const t3 = timing.t3 ?? timing.t2;
  log(`timing ${request?.name ?? "?"} id=${request?.id ?? "?"}`
      + ` disp=${t3 - timing.t2}ms`
      + ` api=${timing.t4 - t3}ms`
      + formatMarks(timing)
      + ` t1=${timing.t1}`);
}

// `arrivedAt' comes from the socket's own message event in ws-client.js.
async function dispatchWithTiming(request, arrivedAt) {
  const t1 = arrivedAt ?? Date.now();
  const timing = { t1, t2: Date.now() };
  try {
    const payload = await dispatchIncomingEmacsRequest(request, timing);
    timing.t4 = Date.now();
    logTiming(request, timing);
    return { payload: payload ?? { status: "ok" }, __timing: timing };
  } catch (e) {
    timing.t4 = Date.now();
    logTiming(request, timing);
    throw e;
  }
}

const identity = await readOrCreateIdentity(browser);
const client = startWebSocketClient({
  clientName: "firefox",
  instance:   identity.instance,
  label:      identity.label,
  version:    browser.runtime.getManifest().version_name
              ?? browser.runtime.getManifest().version,
  onStatus:   setWsStatus,
  onIncompatible: (message) => {
    console.warn("[bg]", "version mismatch:", message);
    browser.notifications.create({
      type: "basic",
      iconUrl: browser.runtime.getURL("icons/icon48.png"),
      title: "browser-gt",
      message: `Version mismatch: ${message}`,
    });
  },
  onIncomingRequest: dispatchWithTiming,
});

initRouter({
  sendRequest: (name, payload) => client.sendRequest(name, payload),
  reconnect:   () => {
    client.reconnect();
    return { ok: true };
  },
  getStatus:   () => ({ status: client.getStatus(),
                        client: client.getClientName() }),
});
