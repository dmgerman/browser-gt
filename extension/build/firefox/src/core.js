// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// core.js — shared router used by every target's background entry.
//
// Owns:
//   • config (bundled + storage merge) and context-menu rebuild,
//   • per-tab icon swapping for consent state,
//   • notifications + badge,
//   • dispatch of context-menu clicks, keyboard commands, popup buttons,
//   • the runtime.onMessage switch for popup/content traffic,
//   • event-listener registration for runtime/contextMenus/commands/tabs/
//     storage.
//
// Does NOT own the WebSocket.  The per-target background supplies a
// transport object:
//
//   transport.sendRequest(name, payload)  → Promise<replyPayload>
//                                            (throws on error)
//   transport.reconnect()                 → Promise<{ ok }>
//   transport.getStatus()                 → "CONNECTED"/"CONNECTING"/
//                                            "DISCONNECTED", or a
//                                            Promise resolving to one
//                                            (Chrome pulls through to
//                                            the offscreen document)
//
// The per-target background also calls `setWsStatus(status)` when the
// WebSocket state changes, so the popup and the SW (Chrome) or the
// background page (Firefox) see the same value.  Incoming Emacs
// requests are dispatched via `dispatchIncomingEmacsRequest(request)`
// which the per-target code wires into its WebSocket frame handler.

import { dispatchEmacsRequest } from "./handlers.js";
import { gatherPayload } from "./payload.js";
import {
  forgetTabConsent,
  getTabConsent,
  rememberTabConsent,
  tabHasConsent,
  CONSENT_DURATIONS,
} from "./consent.js";
import { clearLastError, safeTabsCall } from "./stale-tab.js";

const api = (typeof browser !== "undefined") ? browser : chrome;

// ── Per-tab icon (red when this tab has eval consent) ───────────────────────
//
// `api.action.setIcon({ path })` is flaky inside MV3 service workers
// (fetch failures), so we build ImageData ourselves via OffscreenCanvas.
// We cache one ImageData-per-size pair per icon variant for the lifetime
// of the surrounding background context.

const ICON_SIZES = [16, 48, 128];
const iconCache = { normal: null, red: null };

async function loadIconImageData(isRed) {
  const entries = await Promise.all(ICON_SIZES.map(async (size) => {
    const file = isRed ? `icons/icon-red-${size}.png` : `icons/icon${size}.png`;
    const blob = await (await fetch(api.runtime.getURL(file))).blob();
    const bmp  = await createImageBitmap(blob);
    const canvas = new OffscreenCanvas(size, size);
    const ctx    = canvas.getContext("2d");
    ctx.drawImage(bmp, 0, 0, size, size);
    return [size, ctx.getImageData(0, 0, size, size)];
  }));
  return Object.fromEntries(entries);
}

async function getIconImageData(isRed) {
  const key = isRed ? "red" : "normal";
  if (!iconCache[key]) iconCache[key] = await loadIconImageData(isRed);
  return iconCache[key];
}

async function refreshTabIcon(tabId) {
  try {
    const granted   = await tabHasConsent(tabId);
    const imageData = await getIconImageData(granted);
    await api.action.setIcon({ tabId, imageData });
  } catch (e) {
    // Tab closed between consent change and icon update — harmless.
    clearLastError();
    log("setIcon failed for", tabId, e?.message);
  }
}

async function refreshAllTabIcons() {
  const tabs = await api.tabs.query({});
  await Promise.all(tabs.map((t) => refreshTabIcon(t.id)));
}

// ── Logging / notifications / badge ─────────────────────────────────────────

// Epoch-millisecond prefix so these lines interleave with the Emacs
// *browser-gt* timing log; see doc/latency-instrumentation.org.
function log(...args) {
  console.log(`[${Date.now()}]`, "[core]", ...args);
}

function notify(message) {
  api.notifications.create({
    type: "basic",
    iconUrl: api.runtime.getURL("icons/icon48.png"),
    title: "browser-gt",
    message,
  });
}

let badgeTimer = null;
function badge(text, color, durationMs = 3000) {
  if (badgeTimer) clearTimeout(badgeTimer);
  api.action.setBadgeText({ text });
  api.action.setBadgeBackgroundColor({ color });
  badgeTimer = setTimeout(() => {
    api.action.setBadgeText({ text: "" });
    badgeTimer = null;
  }, durationMs);
}
const badgeOk        = () => badge("✓", "#4a4");
const badgeError     = (message) => { badge("!", "#c33", 5000); notify(message); };

// ── Config (bundled + storage merge) ─────────────────────────────────────────

let cachedConfig    = null;
let refreshInFlight = null;
let wsStatus        = "DISCONNECTED";

async function loadBundledConfig() {
  try {
    const res = await fetch(api.runtime.getURL("config.json"));
    return await res.json();
  } catch (e) {
    log("could not load bundled config.json:", e);
    notify(`Could not load bundled config.json: ${e?.message ?? e}`);
    return { menus: [], handlers: [] };
  }
}

async function loadConfig() {
  const bundled = await loadBundledConfig();
  const stored  = await api.storage.local.get(["menus", "handlers"]);
  return {
    menus:    stored.menus    ?? bundled.menus    ?? [],
    handlers: stored.handlers ?? bundled.handlers ?? [],
  };
}

// Serialise refreshes: onInstalled, onStartup, the boot call, and the
// onChanged listener can all fire concurrently.  Without this lock two
// rebuilds race through `contextMenus.removeAll` before either has
// reached `contextMenus.create`, and the second batch fails with
// "Cannot create item with duplicate id".
async function refreshConfig() {
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = (async () => {
    try {
      cachedConfig = await loadConfig();
      log("config loaded:", cachedConfig);
      await rebuildContextMenus(cachedConfig);
      return cachedConfig;
    } finally {
      refreshInFlight = null;
    }
  })();
  return refreshInFlight;
}

async function ensureConfig() {
  return cachedConfig ?? await refreshConfig();
}

// ── Context menus ────────────────────────────────────────────────────────────

const VALID_CONTEXTS = new Set(["selection", "link", "image", "page"]);

function triggerToContexts(trigger) {
  const triggers = Array.isArray(trigger) ? trigger : [trigger ?? "page"];
  return triggers.map((t) => (VALID_CONTEXTS.has(t) ? t : "page"));
}

function removeAllContextMenus() {
  return new Promise((resolve) => api.contextMenus.removeAll(resolve));
}

async function rebuildContextMenus(config) {
  await removeAllContextMenus();
  for (const m of config.menus ?? []) {
    if (!m.id || !m.title || !m.request) {
      log("skipping malformed menu entry:", m);
      continue;
    }
    const opts = {
      id:       m.id,
      title:    m.title,
      contexts: triggerToContexts(m.trigger),
    };
    if (Array.isArray(m.documentUrlPatterns) && m.documentUrlPatterns.length > 0) {
      opts.documentUrlPatterns = m.documentUrlPatterns;
    }
    if (Array.isArray(m.targetUrlPatterns) && m.targetUrlPatterns.length > 0) {
      opts.targetUrlPatterns = m.targetUrlPatterns;
    }
    api.contextMenus.create(opts);
  }
}

const findMenu          = (config, id)      => (config.menus ?? []).find((m) => m.id === id);
const findMenuByCommand = (config, command) => (config.menus ?? []).find((m) => m.command?.name === command);

// ── Menu click dispatch ─────────────────────────────────────────────────────

async function effectiveRaise(menu) {
  const { raiseOverrides } = await api.storage.local.get(["raiseOverrides"]);
  const override = raiseOverrides?.[menu.id];
  return override !== undefined ? override : menu.raise;
}

async function handleMenuClick(transport, menu, info, tab) {
  try {
    const base    = await gatherPayload(menu.payload, { tab, info });
    const raise   = await effectiveRaise(menu);
    const payload = (raise !== undefined) ? { ...base, raise } : base;
    const response = await transport.sendRequest(menu.request, payload);
    badgeOk();
    const text = response?.message ?? `${menu.title}: done`;
    notify(text);
    return text;
  } catch (e) {
    log("menu dispatch failed:", e);
    badgeError(`${menu.title}: ${e?.message ?? e}`);
    throw e;
  }
}

async function handleCommand(transport, command) {
  const config = await ensureConfig();
  const menu   = findMenuByCommand(config, command);
  if (!menu) {
    notify(`No menu bound to keyboard command: ${command}`);
    return;
  }
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (!tab) {
    notify("No active tab.");
    return;
  }
  await handleMenuClick(transport, menu, {}, tab);
}

// ── Status broadcasting ─────────────────────────────────────────────────────

export function setWsStatus(next) {
  if (wsStatus === next) return;
  wsStatus = next;
  log("ws status:", wsStatus);
  // Best-effort broadcast to popup; no-op if popup is closed.
  api.runtime
    .sendMessage({ target: "popup", type: "WS_STATUS", status: wsStatus })
    .catch(() => {});
}

// ── Incoming-request dispatch (Emacs → browser) ─────────────────────────────

export async function dispatchIncomingEmacsRequest(request, timingOut) {
  const config = await ensureConfig();
  return await dispatchEmacsRequest(request, config.handlers ?? [], timingOut);
}

// ── runtime.onMessage switch (popup + content scripts) ──────────────────────

function installMessageRouter(transport) {
  api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg) return false;
    // Only handle messages addressed to us.
    if (msg.target !== undefined && msg.target !== "service-worker") return false;

    switch (msg.type) {
      case "WS_STATUS_QUERY": {
        // transport.getStatus() may return a Promise (Chrome's
        // pull-through to the offscreen document); Promise.resolve
        // also accepts the sync string Firefox returns.  On rejection
        // fall back to the last broadcast value so the popup is not
        // forced to "Disconnected" by a transient round-trip failure.
        Promise.resolve(transport.getStatus()).then(
          (status) => sendResponse({ status }),
          ()       => sendResponse({ status: wsStatus }),
        );
        return true;
      }

      case "WS_RECONNECT": {
        Promise.resolve()
          .then(() => transport.reconnect())
          .then(
            (r) => sendResponse(r ?? { ok: true }),
            (e) => sendResponse({ ok: false, error: e?.message ?? String(e) }),
          );
        return true;
      }

      case "SEND_REQUEST": {
        Promise.resolve()
          .then(() => transport.sendRequest(msg.name, msg.payload))
          .then(
            (payload) => sendResponse({ ok: true, payload }),
            (e)       => sendResponse({ ok: false, error: e?.message ?? String(e) }),
          );
        return true;
      }

      case "RELAY_TO_EMACS": {
        Promise.resolve()
          .then(() => transport.sendRequest(msg.name, msg.payload))
          .then(
            ()  => sendResponse({ ok: true }),
            (e) => sendResponse({ ok: false, error: e?.message ?? String(e) }),
          );
        return true;
      }

      case "POPUP_MENU_CLICK": {
        (async () => {
          try {
            const config = await ensureConfig();
            const menu   = findMenu(config, msg.menuId);
            if (!menu) throw new Error(`unknown menu: ${msg.menuId}`);
            const tab     = await safeTabsCall(
              () => api.tabs.get(msg.tabId),
              `tabs.get(${msg.tabId})`,
              msg.tabId);
            const message = await handleMenuClick(transport, menu, {}, tab);
            sendResponse({ ok: true, message });
          } catch (e) {
            sendResponse({ ok: false, error: e?.message ?? String(e) });
          }
        })();
        return true;
      }

      case "CONSENT_GET": {
        getTabConsent(msg.tabId).then(
          (info) => sendResponse({ ok: true, ...info }),
          (e)    => sendResponse({ ok: false, error: e?.message ?? String(e) }),
        );
        return true;
      }

      case "CONSENT_GRANT": {
        (async () => {
          try {
            const ms = CONSENT_DURATIONS[msg.kind];
            if (ms === undefined) throw new Error(`unknown consent kind: ${msg.kind}`);
            await rememberTabConsent(msg.tabId, ms);
            await refreshTabIcon(msg.tabId);
            const info = await getTabConsent(msg.tabId);
            sendResponse({ ok: true, ...info });
          } catch (e) {
            sendResponse({ ok: false, error: e?.message ?? String(e) });
          }
        })();
        return true;
      }

      case "CONSENT_REVOKE": {
        (async () => {
          try {
            await forgetTabConsent(msg.tabId);
            await refreshTabIcon(msg.tabId);
            sendResponse({ ok: true, state: "absent", expiry: null });
          } catch (e) {
            sendResponse({ ok: false, error: e?.message ?? String(e) });
          }
        })();
        return true;
      }

      case "CONSENTED_TABS": {
        (async () => {
          try {
            const { consentByTab } = await api.storage.session.get(["consentByTab"]);
            const now = Date.now();
            const candidates = Object.entries(consentByTab ?? {})
              .filter(([, entry]) => entry.expiry == null || entry.expiry > now);
            const tabs = (await Promise.all(candidates.map(async ([tabIdStr, entry]) => {
              const tabId = Number(tabIdStr);
              const tab   = await api.tabs.get(tabId).catch(() => {
                clearLastError();
                return null;
              });
              if (!tab) return null;
              return {
                tabId,
                title:      tab.title ?? "",
                url:        tab.url ?? "",
                favIconUrl: tab.favIconUrl ?? "",
                windowId:   tab.windowId,
                expiry:     entry.expiry,
              };
            }))).filter(Boolean);
            sendResponse({ ok: true, tabs });
          } catch (e) {
            sendResponse({ ok: false, error: e?.message ?? String(e) });
          }
        })();
        return true;
      }

      default:
        return false;
    }
  });
}

// ── Event listeners ─────────────────────────────────────────────────────────

function installEventListeners(transport) {
  const reportBootError = (where) => (e) => {
    log(`${where} bootstrap failed:`, e);
    notify(`Bootstrap failed (${where}): ${e?.message ?? e}`);
  };

  api.runtime.onInstalled.addListener(() => {
    refreshConfig().catch(reportBootError("onInstalled"));
  });

  api.runtime.onStartup.addListener(() => {
    refreshConfig().catch(reportBootError("onStartup"));
  });

  api.storage.onChanged.addListener((changes) => {
    if (changes.menus || changes.handlers) {
      refreshConfig().catch((e) => {
        log("config refresh failed:", e);
        notify(`Config refresh failed: ${e?.message ?? e}`);
      });
    }
  });

  api.contextMenus.onClicked.addListener(async (info, tab) => {
    const config = await ensureConfig();
    const menu   = findMenu(config, info.menuItemId);
    if (!menu) {
      notify(`Unknown menu item: ${info.menuItemId}`);
      return;
    }
    await handleMenuClick(transport, menu, info, tab);
  });

  api.commands.onCommand.addListener((command) => {
    handleCommand(transport, command).catch((e) => {
      log("command failed:", e);
      badgeError(`${command}: ${e?.message ?? e}`);
    });
  });

  // Drop the per-tab consent token when its tab goes away.  Tab ids are
  // reused, so a stale entry would silently grant consent to a new tab
  // that happens to inherit the id.
  api.tabs.onRemoved.addListener((tabId) => {
    forgetTabConsent(tabId).catch((e) => log("consent cleanup failed:", e));
  });

  // Re-check the icon every time a tab is activated, in case its
  // consent expired (1h grant) while it was in the background.
  api.tabs.onActivated.addListener(({ tabId }) => {
    refreshTabIcon(tabId);
  });
}

// ── Public entry point ──────────────────────────────────────────────────────

export async function initRouter(transport) {
  if (!transport
      || typeof transport.sendRequest !== "function"
      || typeof transport.reconnect   !== "function"
      || typeof transport.getStatus   !== "function") {
    throw new Error("initRouter: transport must supply sendRequest, reconnect, getStatus");
  }
  installMessageRouter(transport);
  installEventListeners(transport);
  try {
    await refreshConfig();
    // After a background restart the consent store survives, so paint
    // any still-granted tabs red right away.
    await refreshAllTabIcons();
  } catch (e) {
    log("boot failed:", e);
    notify(`browser-gt boot failed: ${e?.message ?? e}`);
  }
}
