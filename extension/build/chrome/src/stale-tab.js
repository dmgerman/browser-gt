// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-5
//
// stale-tab.js — one wording for "that tab is gone", and the
// `runtime.lastError' bookkeeping that goes with it.
//
// Chrome rejects with "No tab with id: N", Firefox with "Invalid tab
// ID: N".  The normalised sentence is what `browser-gt--stale-target-re'
// matches on the elisp side; changing it there means changing it here.
//
// Firefox also stashes such a rejection into `runtime.lastError' even
// when we await and catch the promise, and nothing else in the Firefox
// path reads that slot — leaving an "Unchecked runtime.lastError" line
// with no stack.  Reading it inside the catch is what silences that.
// Use `safeTabsCall' for every API call a caller-supplied tab id can
// invalidate, `clearLastError' for best-effort calls whose failure we
// intend to ignore.

const api = (typeof browser !== "undefined") ? browser : chrome;

const STALE_TAB_RE    = /No tab with id:?\s*(\d+)|Invalid tab ID:?\s*(\d+)|tab was closed|Frame with ID \d+ was removed/i;
const STALE_WINDOW_RE = /No window with id:?\s*(\d+)|Invalid window ID:?\s*(\d+)/i;
const RESTRICTED_RE   = /Cannot access (?:contents of|a chrome|the url)|Missing host permission|The extensions gallery cannot be scripted|Extension manifest must request permission|cannot be scripted|is not allowed for scripting/i;

/** FALLBACKID names the tab when the browser's wording omits the number. */
export function staleTabMessage(e, fallbackId) {
  const raw = e?.message ?? String(e ?? "");
  const m   = STALE_TAB_RE.exec(raw);
  if (!m) return null;
  const id = m[1] ?? m[2] ?? fallbackId;
  return id === undefined
    ? "the target tab no longer exists (it was closed mid-request)"
    : `no tab with id ${id} (the tab was closed, or the id is stale)`;
}

export function staleWindowMessage(e, fallbackId) {
  const raw = e?.message ?? String(e ?? "");
  const m   = STALE_WINDOW_RE.exec(raw);
  if (!m) return null;
  const id = m[1] ?? m[2] ?? fallbackId;
  return `no window with id ${id} (the window was closed, or the id is stale)`;
}

export function restrictedPageMessage(e) {
  const raw = e?.message ?? String(e ?? "");
  if (!RESTRICTED_RE.test(raw)) return null;
  return `this page cannot be scripted (${raw}); browser-internal pages, ` +
         `the extension gallery, the PDF viewer, and — unless the ` +
         `extension is allowed in incognito — private-window tabs are ` +
         `all off limits`;
}

export async function safeTabsCall(fn, what, tabId) {
  try {
    return await fn();
  } catch (e) {
    void api.runtime.lastError;
    console.warn(`[browser-gt] ${what}: ${e?.message ?? e}`);
    const known = staleTabMessage(e, tabId)
               ?? staleWindowMessage(e)
               ?? restrictedPageMessage(e);
    throw known ? new Error(known) : e;
  }
}

// Emacs hands us `:tab-id "123"' often enough (org-babel headers are
// strings) that reaching `tabs.get' with one — an opaque type error —
// is worse than converting here.
export function coerceTabId(value, what) {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return Number(value.trim());
  }
  throw new Error(`${what}: tab id must be an integer, got ${JSON.stringify(value)}`);
}

export function clearLastError() {
  void api.runtime.lastError;
}

export async function assertTabExists(tabId) {
  return await safeTabsCall(
    () => api.tabs.get(tabId),
    `tabs.get(${tabId})`,
    tabId);
}
