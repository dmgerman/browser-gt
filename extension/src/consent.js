// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// consent.js — per-tab consent gate for code-eval requests.
//
// Threat model: anything that can connect to ws://127.0.0.1:9130 can
// send EVAL_IN_ACTIVE_TAB requests and run JavaScript with full access
// to cookies, localStorage, and authenticated session state of the
// active tab.  We don't want any process — including a compromised
// Emacs — to silently exfiltrate sensitive data.
//
// Gate: the first EVAL_IN_ACTIVE_TAB request targeting a tab paints
// an in-page overlay with a code preview and four buttons:
//   - Deny             → return an error to Emacs.
//   - Allow once       → execute this request, prompt again next time.
//   - Allow 1 hour     → execute now AND remember for 1 hour (or until
//                        the tab closes, whichever comes first).
//   - Allow this tab   → execute now AND remember until the tab closes.
//
// Consent is stored in chrome.storage.session as a map keyed by tab id:
//
//   { "<tabId>": { expiry: <ms-since-epoch> | null } }
//
// expiry === null  →  no time limit; dies when the tab closes.
// expiry: number   →  expires at that wall-clock time.
//
// Session storage survives service-worker shutdowns but clears on
// browser restart.  background.js wipes individual tab ids on
// chrome.tabs.onRemoved.  Stale entries from expired durations are
// harmless (we check `expiry > Date.now()` at every gate); they get
// pruned the next time the popup queries / grants on that tab.

import { executeInTab } from "./executor.js";
import { safeTabsCall, staleTabMessage } from "./stale-tab.js";

const CONSENT_KEY        = "consentByTab";
const CODE_PREVIEW_CHARS = 800;
const CONSENT_TIMEOUT_MS = 30000;  // 30s, then treat as deny
const ONE_HOUR_MS        = 60 * 60 * 1000;

const api = (typeof browser !== "undefined") ? browser : chrome;

// ── Persistence ──────────────────────────────────────────────────────────────

async function loadMap() {
  const stored = await api.storage.session.get([CONSENT_KEY]);
  return stored[CONSENT_KEY] ?? {};
}

async function saveMap(map) {
  await api.storage.session.set({ [CONSENT_KEY]: map });
}

function isLive(entry) {
  if (!entry) return false;
  if (entry.expiry == null) return true;
  return entry.expiry > Date.now();
}

// ── Public state queries ────────────────────────────────────────────────────

export async function tabHasConsent(tabId) {
  const map = await loadMap();
  return isLive(map[tabId]);
}

/** Returns { state: "granted" | "absent", expiry: number | null } */
export async function getTabConsent(tabId) {
  const map = await loadMap();
  const entry = map[tabId];
  if (!isLive(entry)) {
    return { state: "absent", expiry: null };
  }
  return { state: "granted", expiry: entry.expiry };
}

/**
 * Grant consent for a tab.
 *   durationMs = 0 (or null/undefined)  →  no expiry; lives until tab close.
 *   durationMs > 0                      →  expires at now + durationMs.
 */
export async function rememberTabConsent(tabId, durationMs) {
  const map = await loadMap();
  map[tabId] = {
    expiry: durationMs > 0 ? Date.now() + durationMs : null,
  };
  await saveMap(map);
}

export async function forgetTabConsent(tabId) {
  const map = await loadMap();
  if (!(tabId in map)) return;
  delete map[tabId];
  await saveMap(map);
}

// ── Overlay ──────────────────────────────────────────────────────────────────
//
// The overlay function below runs INSIDE THE PAGE via
// chrome.scripting.executeScript.  It must be self-contained: no closures
// from this module, no imports, no `chrome.*` calls (the page context
// doesn't have them).  Arguments come in via the `args` parameter.

function showConsentOverlay(code, timeoutMs) {
  return new Promise((resolve) => {
    document.getElementById("__browser-gt-consent")?.remove();

    const overlay = document.createElement("div");
    overlay.id = "__browser-gt-consent";
    overlay.style.cssText = [
      "position: fixed",
      "top: 12px",
      "right: 12px",
      "z-index: 2147483647",
      "max-width: 480px",
      "background: #ffffff",
      "color: #1a1a1a",
      "border: 2px solid #2a8a2a",
      "border-radius: 10px",
      "padding: 14px 16px",
      "box-shadow: 0 8px 32px rgba(0,0,0,0.25)",
      "font-family: system-ui, -apple-system, sans-serif",
      "font-size: 13px",
      "line-height: 1.45",
    ].join(";");

    const title = document.createElement("div");
    title.textContent = "Emacs wants to evaluate JavaScript on this page";
    title.style.cssText = "font-weight: 600; margin-bottom: 6px;";
    overlay.appendChild(title);

    const origin = document.createElement("div");
    origin.textContent = location.origin;
    origin.style.cssText = "color: #555; font-size: 12px; margin-bottom: 10px;";
    overlay.appendChild(origin);

    const pre = document.createElement("pre");
    pre.textContent = code;
    pre.style.cssText = [
      "background: #f4f4f4",
      "border: 1px solid #ddd",
      "border-radius: 4px",
      "padding: 8px",
      "margin: 0 0 12px 0",
      "max-height: 140px",
      "overflow: auto",
      "font-family: ui-monospace, Menlo, monospace",
      "font-size: 11px",
      "white-space: pre-wrap",
      "word-break: break-all",
      "color: #1a1a1a",
    ].join(";");
    overlay.appendChild(pre);

    const row = document.createElement("div");
    row.style.cssText = "display: flex; gap: 6px; justify-content: flex-end; flex-wrap: wrap;";

    const mkBtn = (label, value, bg, fg) => {
      const btn = document.createElement("button");
      btn.textContent = label;
      btn.style.cssText = [
        "padding: 6px 10px",
        "font-size: 12px",
        "border: 1px solid #aaa",
        "border-radius: 4px",
        "background: " + bg,
        "color: " + fg,
        "cursor: pointer",
      ].join(";");
      btn.addEventListener("click", () => {
        clearTimeout(killTimer);
        overlay.remove();
        resolve(value);
      });
      return btn;
    };

    row.appendChild(mkBtn("Deny",           "deny", "#c33",     "#fff"));
    row.appendChild(mkBtn("Allow once",     "once", "#f4f4f4",  "#222"));
    row.appendChild(mkBtn("Allow 1 hour",   "hour", "#fff4d9",  "#222"));
    row.appendChild(mkBtn("Allow this tab", "tab",  "#dceedb",  "#222"));
    overlay.appendChild(row);

    overlay.addEventListener("keydown", (e) => e.stopPropagation(), true);
    (document.body || document.documentElement).appendChild(overlay);

    const killTimer = setTimeout(() => {
      overlay.remove();
      resolve("deny");
    }, timeoutMs);
  });
}

// ── Prompt orchestration ─────────────────────────────────────────────────────

async function askConsent(tabId, fullCode) {
  const preview = fullCode.length > CODE_PREVIEW_CHARS
        ? fullCode.slice(0, CODE_PREVIEW_CHARS) + "\n…"
        : fullCode;
  try {
    return await safeTabsCall(
      () => executeInTab({
        tabId,
        func: showConsentOverlay,
        args: [preview, CONSENT_TIMEOUT_MS],
      }),
      `consent overlay in tab ${tabId}`,
      tabId);
  } catch (e) {
    // A closed tab is not an unscriptable page; do not relabel it as one.
    if (staleTabMessage(e, tabId)) throw e;
    throw new Error(
      `consent prompt could not be shown (${e?.message ?? e}); ` +
      `internal and store-managed pages cannot be evaluated`,
    );
  }
}

// ── Public gate (used by the user-script adapter) ───────────────────────────

export async function ensureConsent(tabId, code) {
  if (await tabHasConsent(tabId)) return;
  const choice = await askConsent(tabId, code);
  switch (choice) {
    case "deny":
    case undefined:
      throw new Error("Permission denied by user");
    case "once":
      return;                                          // run once, don't store
    case "hour":
      await rememberTabConsent(tabId, ONE_HOUR_MS);
      return;
    case "tab":
      await rememberTabConsent(tabId, 0);              // null expiry
      return;
    default:
      throw new Error(`unexpected consent answer: ${choice}`);
  }
}

// ── Public grant helper (used by the popup) ─────────────────────────────────

export const CONSENT_DURATIONS = {
  hour:    ONE_HOUR_MS,
  tab:     0,
};
