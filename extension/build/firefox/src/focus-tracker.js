// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// focus-tracker.js — record when each browser window last had OS focus.
//
// Neither Chrome nor Firefox is a reliable source of "when was the
// user last actually looking at this tab":
//
//   Chrome sets `Tab.lastAccessed' once, at the moment a tab is made
//   active.  Bringing the browser to the OS foreground without a tab
//   change never updates it.  So a tab active for an hour reads as
//   "one hour ago" even if the user just switched back to Chrome.
//
//   Firefox continuously advances `Tab.lastAccessed' for the active
//   tab in every window, regardless of OS focus.  That over-reports
//   the tab as "now" even while the browser sits in the background.
//
// This module papers over both by owning its own record: every time
// a window gains OS focus, we stamp its id with the current time; on
// focus loss we stamp the outgoing window one more time (its last
// moment of confirmed observation).  The `tabs-query-mru-safe'
// adapter in handlers.js calls `activeTabTimestamp' at query time to
// substitute an accurate `lastAccessed' for every active tab.
//
// State is process-local: Chrome's MV3 service worker respawns will
// wipe it.  `initFocusTracking' seeds from `windows.getLastFocused'
// on start so the currently-focused window is recovered immediately;
// any window observed only during a dormant SW window falls back to
// the browser's raw value until the next focus event.

const api = (typeof browser !== "undefined") ? browser : chrome;

let currentFocusedWindow = null;   // windowId or null when no window has focus
const lastFocusedAt = new Map();   // windowId → ms (last confirmed focused moment)

function stampWindow(windowId, timestamp) {
  if (typeof windowId === "number" && windowId >= 0) {
    lastFocusedAt.set(windowId, timestamp);
  }
}

function onFocusChange(newWindowId) {
  const now = Date.now();
  // The outgoing window was focused right up until this event, so
  // credit it with `now' before we move on.  This is what makes
  // "Cmd-Tab away then query" return the moment of the away action
  // instead of whichever earlier moment we last observed.
  if (currentFocusedWindow !== null && currentFocusedWindow !== newWindowId) {
    stampWindow(currentFocusedWindow, now);
  }
  if (newWindowId === api.windows.WINDOW_ID_NONE) {
    currentFocusedWindow = null;
    return;
  }
  currentFocusedWindow = newWindowId;
  stampWindow(newWindowId, now);
}

export function initFocusTracking() {
  api.windows.onFocusChanged.addListener(onFocusChange);
  // Seed from whatever window currently claims focus so a query
  // arriving before the first `onFocusChanged' event still gets an
  // accurate answer.  `getLastFocused' returns the most-recently
  // focused window whether or not it currently has OS focus; the
  // `focused' flag distinguishes the two cases.
  api.windows.getLastFocused({ populate: false }).then((win) => {
    if (win && typeof win.id === "number") {
      stampWindow(win.id, Date.now());
      if (win.focused) currentFocusedWindow = win.id;
    }
  }).catch(() => { /* extension may load before any window exists */ });
}

// Return the timestamp to report as `lastAccessed' for the active
// tab in WINDOWID.  Callers pass RAWFALLBACK — the browser's own
// value — used only when the tracker has no record for the window
// (extension loaded after the fact, or MV3 SW respawn hasn't caught
// a focus event yet).
export function activeTabTimestamp(windowId, rawFallback) {
  if (currentFocusedWindow === windowId) return Date.now();
  if (lastFocusedAt.has(windowId))       return lastFocusedAt.get(windowId);
  return rawFallback;
}
