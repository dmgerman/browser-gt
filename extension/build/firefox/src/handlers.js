// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// handlers.js — dispatch Emacs-initiated requests via the handlers[] config.
//
// A handler entry looks like:
//   { name: "GET_ALL_TABS", api: "chrome.tabs.query", args: {} }
//   { name: "OPEN_TAB",     api: "chrome.tabs.create", "args-from": "payload" }
//   { name: "FOCUS_TAB",    api: "chrome.tabs.update", "args-shape": "focus-tab" }
//   { name: "EVAL_IN_ACTIVE_TAB", api: "chrome.userScripts.execute",
//       "args-shape": "user-script" }
//
// args        — static argument literal
// args-from   — "payload": pass the request payload through
// args-shape  — named adapter (see SHAPE_ADAPTERS) for irregular APIs
//
// API resolution is reflective: "chrome.tabs.query" is split on '.' and
// walked from `chrome`.  This is plain property access, not eval, so it is
// not blocked by MV3 CSP.  The set of reachable APIs is bounded by what the
// manifest declares in permissions.

import { ensureConsent, tabHasConsent } from "./consent.js";
import { evalAvailable, evalUnavailableMessage, evalInTab } from "./eval-impl.js";
import { activeTabTimestamp } from "./focus-tracker.js";
import {
  assertTabExists,
  clearLastError,
  coerceTabId,
  safeTabsCall,
} from "./stale-tab.js";

const api = (typeof browser !== "undefined") ? browser : chrome;

// chrome.action.setIcon({path}) fails inside MV3 service workers
// ("Failed to fetch") regardless of path correctness.  We build ImageData
// from the bundled PNGs the same way background.js does.  Cache lives for
// the SW's lifetime; both icon variants get loaded lazily on first use.

const ICON_SIZES = [16, 48, 128];
const iconCache  = { normal: null, red: null };

async function loadIconImageData(isRed) {
  const out = {};
  for (const size of ICON_SIZES) {
    const file = isRed ? `icons/icon-red-${size}.png` : `icons/icon${size}.png`;
    const blob = await (await fetch(api.runtime.getURL(file))).blob();
    const bmp  = await createImageBitmap(blob);
    const canvas = new OffscreenCanvas(size, size);
    canvas.getContext("2d").drawImage(bmp, 0, 0, size, size);
    out[size] = canvas.getContext("2d").getImageData(0, 0, size, size);
  }
  return out;
}

async function syncTabIcon(tabId) {
  try {
    const granted = await tabHasConsent(tabId);
    const key = granted ? "red" : "normal";
    if (!iconCache[key]) iconCache[key] = await loadIconImageData(granted);
    await api.action.setIcon({ tabId, imageData: iconCache[key] });
  } catch {
    clearLastError();          // tab may have closed; harmless
  }
}

const SHAPE_ADAPTERS = {
  // { url: "..." } -> creates a tab in an incognito window.  If an
  // incognito window already exists for this profile, reuse it
  // (chrome.tabs.create + windowId).  Otherwise open a fresh
  // incognito window with the URL (chrome.windows.create + incognito).
  // The parent window is focused so the OS brings it forward.  Fails
  // with an actionable message if the extension lacks "Allow in
  // incognito" — the elisp side catches that and degrades.
  async "open-incognito-tab"(payload) {
    if (!payload || typeof payload.url !== "string") {
      throw new Error("open-incognito-tab: payload.url (string) required");
    }
    let wins;
    try {
      wins = await api.windows.getAll({
        populate: false,
        windowTypes: ["normal"],
      });
    } catch (e) {
      throw new Error(
        "open-incognito-tab: enumerate windows failed (" + e.message + ")",
      );
    }
    const inc = wins.find((w) => w.incognito === true);
    if (inc) {
      const tab = await api.tabs.create({
        windowId: inc.id,
        url:      payload.url,
        active:   true,
      });
      await api.windows.update(inc.id, { focused: true });
      return tab;
    }
    let win;
    try {
      win = await api.windows.create({
        url:       payload.url,
        incognito: true,
        focused:   true,
      });
    } catch (e) {
      // Most common failure: extension lacks "Allow in incognito" toggle.
      throw new Error(
        "open-incognito-tab: create incognito window failed (" + e.message +
        "); enable 'Allow in incognito' for the browser-gt extension",
      );
    }
    return (win && win.tabs && win.tabs[0]) || { status: "ok" };
  },

  // { url: "..." } -> chrome.tabs.create({ url }) followed by
  // chrome.windows.update(newTab.windowId, { focused: true }).  The
  // extra windows.update fixes a Chrome-on-macOS quirk: tabs.create
  // alone activates the new tab inside its window but does NOT bring
  // the browser app to the OS foreground when the app is in the
  // background.  windows.update with focused:true does.  Returns the
  // created tab so callers see the same shape they used to.
  async "open-tab-focused"(payload) {
    const args = payload && typeof payload === "object" ? payload : {};
    if (typeof args.url !== "string" || args.url.length === 0) {
      throw new Error("open-tab-focused: payload.url (string) required");
    }
    const tab = await api.tabs.create(args);
    if (tab && typeof tab.windowId === "number") {
      try {
        await api.windows.update(tab.windowId, { focused: true });
      } catch (e) {
        // Best-effort: focus failure should not invalidate the
        // already-created tab.  Caller still gets a usable Tab.
      }
    }
    return tab;
  },

  // { id: 123 } -> chrome.tabs.update(123, { active: true })
  // optional { focusWindow: true } also focuses the parent window.
  //
  // When focusWindow is requested we (a) focus the window BEFORE
  // activating the tab and (b) call windows.update({focused:true})
  // twice.  Chrome on macOS is flaky about cross-window raising when
  // the app is already frontmost with a different window on top of its
  // own window stack: a single windows.update sometimes activates the
  // tab inside its window but leaves a sibling Chrome window covering
  // it.  Focusing first + repeating the call are the two cheapest
  // known workarounds; combined they reliably bring the target window
  // to the front of Chrome's window order.
  async "focus-tab"(payload) {
    if (!payload || payload.id === undefined) {
      throw new Error("focus-tab: payload.id (tab id) required");
    }
    const id = coerceTabId(payload.id, "focus-tab");
    if (payload.focusWindow) {
      const tab = await safeTabsCall(
        () => api.tabs.get(id),
        `tabs.get(${id})`,
        id);
      if (tab.windowId !== undefined) {
        await safeTabsCall(
          () => api.windows.update(tab.windowId, { focused: true }),
          `windows.update(${tab.windowId})`);
      }
      await safeTabsCall(
        () => api.tabs.update(id, { active: true }),
        `tabs.update(${id})`,
        id);
      // Second raise (see above).  Best-effort: the tab is active by
      // now, so a window closing in between must not fail the request.
      if (tab.windowId !== undefined) {
        try {
          await api.windows.update(tab.windowId, { focused: true });
        } catch (e) {
          clearLastError();
          console.warn(`[browser-gt] re-focus windows.update(${tab.windowId}): ` +
                       `${e?.message ?? e}`);
        }
      }
    } else {
      await safeTabsCall(
        () => api.tabs.update(id, { active: true }),
        `tabs.update(${id})`,
        id);
    }
    return { status: "ok" };
  },

  // { id: 123 } -> chrome.tabs.remove(123)
  async "tab-id"(payload) {
    if (!payload || payload.id === undefined) {
      throw new Error("tab-id: payload.id required");
    }
    const id = coerceTabId(payload.id, "tab-id");
    return await safeTabsCall(
      () => api.tabs.remove(id),
      `tabs.remove(${id})`,
      id);
  },

  // GET_ALL_TABS with an accurate `lastAccessed' for active tabs.
  //
  // Neither browser is a reliable source for the active tab: Chrome
  // never updates `Tab.lastAccessed' between activations, so a tab
  // active for an hour still reads "an hour ago" even if the user
  // just switched back to Chrome; Firefox continuously advances it
  // to wall-clock time whether the browser has OS focus or not.
  //
  // The `focus-tracker' module records every window's last confirmed
  // OS-focused moment via `windows.onFocusChanged'.  At query time
  // `activeTabTimestamp' returns:
  //   - `Date.now()' when the tab's window currently has focus
  //   - the last-focused stamp when the window was focused before
  //   - the browser's own `lastAccessed' as fallback when we have
  //     no record (initial load, SW respawn between events)
  //
  // Non-active tabs pass through untouched: both browsers report
  // those correctly.
  async "tabs-query-mru-safe"(payload) {
    // Emacs sends nil payload as the JSON-encoded keyword :null,
    // which arrives here as the string "null" (an Emacs
    // json-encode quirk).  Any non-object payload — null, "null",
    // undefined, an array — is treated as "no filter" so tabs.query
    // sees a plain {} and returns every tab.  A real filter object
    // is passed through unchanged.
    const query = (payload
                   && typeof payload === "object"
                   && !Array.isArray(payload))
      ? payload
      : {};
    const tabs = await api.tabs.query(query);
    return tabs.map((tab) => {
      if (!tab.active) return tab;
      const ts = activeTabTimestamp(tab.windowId, tab.lastAccessed);
      return { ...tab, lastAccessed: ts };
    });
  },

  // { code: "..." } -> runtime-specific eval primitive in ./eval-impl.js.
  // Defaults to the active tab and world: "MAIN" (sees the page's window).
  // Gated by ensureConsent: the first invocation on each tab displays an
  // in-page overlay asking the user to allow/deny.
  async "user-script"(payload) {
    if (!payload || typeof payload.code !== "string") {
      throw new Error("user-script: payload.code (string) required");
    }
    // Check an Emacs-supplied id here: reaching the consent overlay
    // with a closed tab used to report it as a page that cannot be
    // scripted.
    let tabId = payload.tabId;
    if (tabId === undefined) {
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      if (!tab) throw new Error("no active tab for user-script execution");
      tabId = tab.id;
    } else {
      tabId = coerceTabId(tabId, "user-script");
      await assertTabExists(tabId);
    }
    if (!evalAvailable()) {
      throw new Error(evalUnavailableMessage());
    }
    // Per-tab consent.  Throws on deny or 30s timeout.
    await ensureConsent(tabId, payload.code);
    // After ensureConsent the storage entry may have flipped from absent
    // to granted (user clicked Allow 1h / Allow this tab in the overlay).
    // Sync the toolbar icon so the tab looks red right away.
    await syncTabIcon(tabId);
    // The tab can still close while the consent overlay is up (30s).
    const result = await safeTabsCall(
      () => evalInTab({
        tabId,
        code:  payload.code,
        world: payload.world ?? "USER_SCRIPT",
      }),
      `eval in tab ${tabId}`,
      tabId);
    return { status: "ok", result };
  },
};

function resolveApi(path) {
  if (!path || typeof path !== "string") {
    throw new Error("handler missing `api` path");
  }
  if (!path.startsWith("chrome.")) {
    throw new Error(`api path must start with 'chrome.': ${path}`);
  }
  // Config strings are written with the "chrome." prefix because that
  // is the namespace Chrome's documentation uses; the actual lookup
  // walks the cross-browser shim so the same path works in Firefox.
  const parts = path.split(".").slice(1);
  let cursor = api;
  for (const segment of parts) {
    if (cursor == null || typeof cursor !== "object") {
      throw new Error(`api path not reachable: ${path} (broke at '${segment}')`);
    }
    cursor = cursor[segment];
  }
  if (typeof cursor !== "function") {
    throw new Error(`api path does not resolve to a function: ${path}`);
  }
  return cursor;
}

function pickArgs(handler, payload) {
  if (handler["args-from"] === "payload") return payload ?? {};
  if (handler.args !== undefined)         return handler.args;
  return {};
}

export async function dispatchEmacsRequest(request, handlers, timingOut) {
  const { name, payload } = request;
  const handler = (handlers ?? []).find((h) => h.name === name);
  if (!handler) {
    throw new Error(`no handler registered for request: ${name}`);
  }

  if (handler["args-shape"]) {
    const adapter = SHAPE_ADAPTERS[handler["args-shape"]];
    if (!adapter) {
      throw new Error(`unknown args-shape: ${handler["args-shape"]}`);
    }
    // See doc/latency-instrumentation.org.  `t3' is captured just
    // before the resolved handler runs; the caller stamps `t4' after
    // this function resolves.  Delta `t4 - t3' isolates the actual
    // chrome.* API call from surrounding dispatch overhead.
    if (timingOut) timingOut.t3 = Date.now();
    return await adapter(payload, handler);
  }

  const fn   = resolveApi(handler.api);
  const args = pickArgs(handler, payload);
  if (timingOut) timingOut.t3 = Date.now();
  // chrome.* APIs in MV3 return promises directly.
  const result = await fn(args);
  return result === undefined ? { status: "ok" } : result;
}
