// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// popup.js — connection status + config-driven action buttons.

const api = (typeof browser !== "undefined") ? browser : chrome;

const dot         = document.getElementById("dot");
const statusText  = document.getElementById("status-text");
const messageEl   = document.getElementById("message");
const customEl    = document.getElementById("custom-actions");
const optionsLink = document.getElementById("options-link");
const logoEl      = document.getElementById("logo");
const identityNameEl     = document.getElementById("identity-name");
const identityNameHintEl = document.getElementById("identity-name-hint");
const identityUuidEl     = document.getElementById("identity-uuid");
const swErrorEl          = document.getElementById("sw-error");
const versionEl          = document.getElementById("version");

// Show the extension's version next to the browser-gt title so a user
// glancing at the popup can tell which build is loaded — matches
// what the options page has always shown.
versionEl.textContent = `v${api.runtime.getManifest().version}`;

const LOGO_DEFAULT = "../icons/icon128.png";
const LOGO_RED     = "../icons/icon-red-128.png";

// Storage keys — must match identity.js and options.js.
const IDENTITY_LABEL_KEY    = "browser-gt-label";
const IDENTITY_INSTANCE_KEY = "browser-gt-instance";

function isConsentLive(info) {
  return info?.state === "granted"
      && (info.expiry == null || info.expiry > Date.now());
}

function setLogoForConsent(info) {
  logoEl.src = isConsentLive(info) ? LOGO_RED : LOGO_DEFAULT;
}

function setStatus(status) {
  dot.className = "dot " + (status?.toLowerCase() ?? "disconnected");
  const label = {
    CONNECTED:    "Connected",
    CONNECTING:   "Connecting…",
    DISCONNECTED: "Disconnected",
    INCOMPATIBLE: "Version mismatch — rebuild and reload",
  }[status] ?? "Unknown";
  statusText.textContent = label;
}

function setMessage(text, isError = false) {
  messageEl.textContent = text ?? "";
  messageEl.style.color = isError ? "#c33" : "#555";
}

function sendToBackground(message) {
  return new Promise((resolve) => {
    api.runtime.sendMessage(message, (response) => {
      if (api.runtime.lastError) {
        resolve({ ok: false, error: api.runtime.lastError.message });
        return;
      }
      resolve(response ?? {});
    });
  });
}

async function getActiveTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

// ── Reconnect / options ─────────────────────────────────────────────────────

document.getElementById("reconnect").addEventListener("click", async () => {
  setMessage("Reconnecting…");
  const r = await sendToBackground({ target: "service-worker", type: "WS_RECONNECT" });
  if (r?.ok) setMessage("Reconnect requested.");
  else       setMessage(`Reconnect failed: ${r?.error ?? "unknown"}`, true);
});

optionsLink.addEventListener("click", () => api.runtime.openOptionsPage());

// ── Consent panel (this tab) ────────────────────────────────────────────────

const stateEl   = document.getElementById("consent-state");
const buttonsEl = document.getElementById("consent-buttons");

function describeConsent({ state, expiry }) {
  if (state !== "granted") return { text: "Not granted", cls: "absent" };
  if (expiry == null) return { text: "Allowed until tab closes", cls: "granted" };
  const remaining = expiry - Date.now();
  if (remaining <= 0) return { text: "Not granted", cls: "absent" };
  const mins = Math.ceil(remaining / 60000);
  return {
    text: mins >= 60
      ? `Allowed (${(mins / 60).toFixed(1)} h left)`
      : `Allowed (${mins} min left)`,
    cls: "granted",
  };
}

function setConsentUI(tabId, info) {
  const { text, cls } = describeConsent(info);
  stateEl.textContent = text;
  stateEl.className   = "consent-state " + cls;
  buttonsEl.innerHTML = "";
  setLogoForConsent(info);

  const mkBtn = (label, type, kind) => {
    const b = document.createElement("button");
    b.textContent = label;
    if (type === "revoke") b.className = "revoke";
    b.addEventListener("click", async () => {
      const message = type === "revoke"
        ? { target: "service-worker", type: "CONSENT_REVOKE", tabId }
        : { target: "service-worker", type: "CONSENT_GRANT",  tabId, kind };
      const r = await sendToBackground(message);
      if (r?.ok) {
        setConsentUI(tabId, r);
        renderConsentedTabs();
      } else {
        setMessage(`Consent: ${r?.error ?? "unknown"}`, true);
      }
    });
    return b;
  };

  if (info.state === "granted" &&
      (info.expiry == null || info.expiry > Date.now())) {
    buttonsEl.appendChild(mkBtn("Revoke", "revoke"));
  } else {
    buttonsEl.appendChild(mkBtn("1 hour",   "grant", "hour"));
    buttonsEl.appendChild(mkBtn("This tab", "grant", "tab"));
  }
}

async function renderConsent() {
  const tab = await getActiveTab();
  if (!tab) {
    stateEl.textContent = "(no active tab)";
    stateEl.className   = "consent-state absent";
    buttonsEl.innerHTML = "";
    setLogoForConsent(null);
    return;
  }
  const r = await sendToBackground({
    target: "service-worker", type: "CONSENT_GET", tabId: tab.id,
  });
  if (r?.ok) setConsentUI(tab.id, r);
  else       setMessage(`Consent: ${r?.error ?? "unknown"}`, true);
}

// ── Consented tabs (jump list) ──────────────────────────────────────────────

const consentedTabsEl = document.getElementById("consented-tabs");

function shortRemaining(expiry) {
  if (expiry == null) return "until close";
  const ms = expiry - Date.now();
  if (ms <= 0) return "expired";
  const mins = Math.ceil(ms / 60000);
  return mins >= 60 ? `${(mins / 60).toFixed(1)} h left` : `${mins} min left`;
}

async function renderConsentedTabs() {
  const r = await sendToBackground({ target: "service-worker", type: "CONSENTED_TABS" });
  consentedTabsEl.innerHTML = "";
  if (!r?.ok || !r.tabs?.length) return;

  const header = document.createElement("div");
  header.className   = "header";
  header.textContent = `Tabs with permission (${r.tabs.length})`;
  consentedTabsEl.appendChild(header);

  for (const t of r.tabs) {
    const row = document.createElement("div");
    row.className = "ctab";

    if (t.favIconUrl) {
      const fav = document.createElement("img");
      fav.className = "fav";
      fav.src       = t.favIconUrl;
      fav.onerror   = () => fav.remove();
      row.appendChild(fav);
    }

    const meta = document.createElement("div");
    meta.className = "meta";
    const titleEl = document.createElement("div");
    titleEl.className   = "title";
    titleEl.textContent = t.title || t.url || `tab ${t.tabId}`;
    const subEl = document.createElement("div");
    subEl.className   = "sub";
    let host = "";
    try { host = new URL(t.url).host; } catch {}
    subEl.textContent = `${host} · ${shortRemaining(t.expiry)}`;
    meta.appendChild(titleEl);
    meta.appendChild(subEl);
    row.appendChild(meta);

    const revoke = document.createElement("button");
    revoke.className   = "revoke";
    revoke.textContent = "Revoke";
    revoke.addEventListener("click", async (e) => {
      e.stopPropagation();
      await sendToBackground({ target: "service-worker", type: "CONSENT_REVOKE", tabId: t.tabId });
      await renderConsentedTabs();
      await renderConsent();
    });
    row.appendChild(revoke);

    row.addEventListener("click", async () => {
      // A consented tab can be closed manually between popup render
      // and click; without a catch the resulting promise rejection
      // becomes an unhandled runtime error.  Explicitly consume
      // `runtime.lastError' as well because Firefox stashes the
      // error there even when the promise rejects properly.
      try {
        await api.tabs.update(t.tabId, { active: true });
      } catch (e) {
        void api.runtime.lastError;
        setMessage(`Tab ${t.tabId} is no longer open`, true);
        return;
      }
      if (typeof t.windowId === "number") {
        try {
          await api.windows.update(t.windowId, { focused: true });
        } catch {
          void api.runtime.lastError;
        }
      }
      window.close();
    });

    consentedTabsEl.appendChild(row);
  }
}

// ── Config-driven action buttons ────────────────────────────────────────────
//
// Renders one button per `menus[]` entry from config.json (or the
// chrome.storage.local override).  Clicking a button forwards a
// POPUP_MENU_CLICK to the service worker so the full payload-gathering
// pipeline (gatherPayload + raise + handlers) runs identically to the
// right-click context-menu path.

async function loadMenus() {
  const stored = await api.storage.local.get(["menus"]);
  if (stored.menus) return stored.menus;
  try {
    const res = await fetch(api.runtime.getURL("config.json"));
    return (await res.json()).menus ?? [];
  } catch (e) {
    return [];
  }
}

// A menu whose only trigger is "link" or "image" cannot fire from the
// popup — there is no clicked anchor or image to pull info.linkUrl /
// info.srcUrl from.  Showing such buttons would just produce confusing
// failures.  Keep them in the context menu only.
function popupCapable(m) {
  const triggers = Array.isArray(m.trigger) ? m.trigger : [m.trigger ?? "page"];
  return triggers.some((t) => t !== "link" && t !== "image");
}

async function renderActions() {
  const menus = (await loadMenus()).filter(popupCapable);
  customEl.innerHTML = "";
  if (!menus.length) return;
  for (const m of menus) {
    const btn = document.createElement("button");
    btn.className   = "action";
    btn.textContent = m.title;
    if (m.command?.name) btn.dataset.command = m.command.name;
    btn.addEventListener("click", async () => {
      const tab = await getActiveTab();
      if (!tab) { setMessage("No active tab.", true); return; }
      // "Sent…" is optimistic — the request is on its way to Emacs.
      // Replaced by "Finished: <emacs reply>" once Emacs responds.
      setMessage("Sent…");
      const r = await sendToBackground({
        target:  "service-worker",
        type:    "POPUP_MENU_CLICK",
        menuId:  m.id,
        tabId:   tab.id,
      });
      if (r?.ok) setMessage(`Finished: ${r.message ?? "ok"}`);
      else       setMessage(`Error: ${r?.error ?? "unknown"}`, true);
    });
    customEl.appendChild(btn);
  }
}

// ── Shortcut hints ──────────────────────────────────────────────────────────
//
// Annotate each action button with its CURRENT keyboard shortcut.  Chrome
// returns whatever the user has actually bound at chrome://extensions/shortcuts
// (possibly different from the suggested key in the manifest); an empty
// `shortcut` means the user hasn't bound one yet.

async function commandShortcutMap() {
  if (!api.commands?.getAll) return {};
  try {
    const commands = await api.commands.getAll();
    return Object.fromEntries(
      commands.map((c) => [c.name, c.shortcut ?? ""]),
    );
  } catch (e) {
    return {};
  }
}

function annotateButton(btn, shortcut) {
  if (!shortcut) return;
  const span = document.createElement("span");
  span.className   = "shortcut";
  span.textContent = shortcut;
  btn.appendChild(span);
}

async function applyShortcutHints() {
  const map = await commandShortcutMap();
  document.querySelectorAll("[data-command]").forEach((btn) => {
    annotateButton(btn, map[btn.dataset.command]);
  });
}

// ── Identity block (name + uuid) ────────────────────────────────────────────
//
// Reads the storage keys populated by src/identity.js and shows the
// name Emacs will see plus the persistent instance UUID.  When the
// label is unset, the effective name is the build's clientName —
// detected via the `browser` global (Firefox exposes it natively;
// Chrome does not, absent a polyfill).  This is the same heuristic
// the top-of-file `api` picker uses, so the popup stays consistent
// with itself.

const IS_FIREFOX          = typeof browser !== "undefined";
const DEFAULT_CLIENT_NAME = IS_FIREFOX ? "firefox" : "chrome";

async function renderIdentity() {
  const stored = await api.storage.local.get([IDENTITY_LABEL_KEY,
                                              IDENTITY_INSTANCE_KEY]);
  const label    = stored[IDENTITY_LABEL_KEY];
  const instance = stored[IDENTITY_INSTANCE_KEY];
  const isLabelSet = typeof label === "string" && label.length > 0;

  identityNameEl.textContent = isLabelSet ? label : DEFAULT_CLIENT_NAME;
  identityNameHintEl.textContent = isLabelSet
    ? ""
    : "(default — set a label to run multiple)";
  identityUuidEl.textContent = instance || IDENTITY_MISSING_MESSAGE;
}

// The UUID lands in storage the first time the background page (Firefox)
// or offscreen document (Chrome) runs `readOrCreateIdentity'.  If the
// popup opens and it isn't there, the extension's own lifecycle didn't
// complete — the WS-reconnect button in this popup can't fix it, so the
// message points at the extension page, not the reconnect action.  The
// service-worker check below is the authoritative signal for the
// "extension truly not running" case; this message is a safe fallback
// for the slower "storage write is still pending" window.
const IDENTITY_MISSING_MESSAGE = IS_FIREFOX
  ? "(not yet generated — reload the extension in about:debugging)"
  : "(not yet generated — reload the extension in chrome://extensions)";

// ── Live status updates from the service worker ─────────────────────────────

api.runtime.onMessage.addListener((msg) => {
  if (msg?.target !== "popup") return false;
  if (msg.type === "WS_STATUS") setStatus(msg.status);
  return false;
});

// ── Service-worker / background-page health check ──────────────────────────
//
// The popup opens even when the extension's own background script (SW
// on Chrome, background.js on Firefox) failed to load — the popup is a
// standalone HTML page.  When that happens, every `sendToBackground'
// call fails with "Could not establish connection" / "Receiving end
// does not exist" because nothing is listening for the message.
//
// Users who don't know to open the extension page and click "Errors"
// will see the popup's stale-looking status and give up.  Surface the
// real state with a red banner naming the exact remedial step.

function isSwNotRunning(response) {
  const msg = response?.error;
  return typeof msg === "string" && (
    msg.includes("Could not establish connection")
    || msg.includes("Receiving end does not exist")
  );
}

function showSwFailed() {
  const page = IS_FIREFOX
    ? "about:debugging#/runtime/this-firefox"
    : "chrome://extensions";
  const errorsHint = IS_FIREFOX
    ? "click <em>Inspect</em> on the browser-gt card and read the console"
    : "click the <em>Errors</em> button on the browser-gt card";
  swErrorEl.innerHTML = `
    <strong>Extension background script isn't running.</strong><br>
    Open <code>${page}</code>, ${errorsHint} for the exact reason,
    then reload the extension.  The <em>Reconnect</em> button below
    only touches the WebSocket — it cannot restart a failed load.
  `;
  swErrorEl.style.display = "block";
  dot.className        = "dot incompatible";
  statusText.textContent = "Extension not loaded";
}

// On open, query the current status.  Route the "SW not running" case
// into the banner rather than the silent DISCONNECTED fallback.
sendToBackground({ target: "service-worker", type: "WS_STATUS_QUERY" })
  .then((r) => {
    if (isSwNotRunning(r)) {
      showSwFailed();
    } else {
      setStatus(r?.status ?? "DISCONNECTED");
    }
  });

renderActions().then(applyShortcutHints);
renderConsent();
renderConsentedTabs();
renderIdentity();
