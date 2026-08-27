// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// options.js — edit menus[] and handlers[] in chrome.storage.local,
// plus per-action overrides for "raise Emacs?".

const api = (typeof browser !== "undefined") ? browser : chrome;

const menusEl    = document.getElementById("menus");
const versionEl  = document.getElementById("version");
versionEl.textContent = `v${api.runtime.getManifest().version_name ?? api.runtime.getManifest().version}`;
const handlersEl = document.getElementById("handlers");
const statusEl   = document.getElementById("status");
const raiseBody  = document.querySelector("#raise-table tbody");
const labelEl    = document.getElementById("label");
const instanceEl = document.getElementById("instance");

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className   = kind ?? "";
}

function format(value) {
  return JSON.stringify(value ?? [], null, 2);
}

async function loadBundled() {
  const res = await fetch(api.runtime.getURL("config.json"));
  return await res.json();
}

// ── Raw JSON editors ────────────────────────────────────────────────────────

function parseOrThrow(text, name) {
  try {
    const value = JSON.parse(text);
    if (!Array.isArray(value)) {
      throw new Error(`${name} must be a JSON array`);
    }
    return value;
  } catch (e) {
    throw new Error(`${name}: ${e.message}`);
  }
}

document.getElementById("save").addEventListener("click", async () => {
  try {
    const menus    = parseOrThrow(menusEl.value,    "menus");
    const handlers = parseOrThrow(handlersEl.value, "handlers");
    await api.storage.local.set({ menus, handlers });
    setStatus("Saved. Context menus rebuilt.", "ok");
  } catch (e) {
    setStatus(e.message, "error");
  }
});

document.getElementById("reset").addEventListener("click", async () => {
  await api.storage.local.remove(["menus", "handlers"]);
  await loadCurrent();
  setStatus("Reset to bundled defaults.", "ok");
});

document.getElementById("reload").addEventListener("click", () => {
  loadCurrent().then(() => setStatus("Reloaded from storage.", "ok"));
});

// ── Raise overrides ─────────────────────────────────────────────────────────
//
// Renders one row per menu with a checkbox showing the effective raise
// behaviour.  Saving writes the {menuId: bool} map to
// chrome.storage.local.raiseOverrides.  Only present keys override; missing
// keys fall back to the menu's bundled raise value.

async function loadEffectiveMenus() {
  const stored  = await api.storage.local.get(["menus"]);
  if (stored.menus) return stored.menus;
  const bundled = await loadBundled();
  return bundled.menus ?? [];
}

async function renderRaiseTable() {
  raiseBody.innerHTML = "";
  const menus     = await loadEffectiveMenus();
  const stored    = await api.storage.local.get(["raiseOverrides"]);
  const overrides = stored.raiseOverrides ?? {};
  for (const m of menus) {
    const tr = document.createElement("tr");

    const tdAction = document.createElement("td");
    tdAction.textContent = m.title ?? m.id;
    tr.appendChild(tdAction);

    const tdReq = document.createElement("td");
    tdReq.textContent = m.request ?? "";
    tdReq.style.fontFamily = "ui-monospace, Menlo, monospace";
    tdReq.style.fontSize   = "11px";
    tdReq.style.color      = "#555";
    tr.appendChild(tdReq);

    const tdToggle = document.createElement("td");
    tdToggle.className = "toggle";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.dataset.menuId = m.id;
    cb.checked = overrides[m.id] ?? (m.raise === true);
    tdToggle.appendChild(cb);
    tr.appendChild(tdToggle);

    const tdDefault = document.createElement("td");
    tdDefault.className = "default";
    tdDefault.textContent = m.raise === true ? "on" : "off";
    tr.appendChild(tdDefault);

    raiseBody.appendChild(tr);
  }
}

document.getElementById("save-raise").addEventListener("click", async () => {
  const overrides = {};
  raiseBody.querySelectorAll("input[type=checkbox]").forEach((cb) => {
    overrides[cb.dataset.menuId] = cb.checked;
  });
  await api.storage.local.set({ raiseOverrides: overrides });
  setStatus("Saved raise overrides.", "ok");
});

document.getElementById("reset-raise").addEventListener("click", async () => {
  await api.storage.local.remove(["raiseOverrides"]);
  await renderRaiseTable();
  setStatus("Cleared raise overrides; each menu now follows its config default.", "ok");
});

// ── Client label + instance UUID ────────────────────────────────────────────
//
// The label is a user-settable display name sent in CLIENT_HELLO and
// used by Emacs to distinguish concurrent clients (e.g. two Chrome
// profiles connected at once).  Empty label = fall back to the
// build's clientName ("chrome"/"firefox") on the wire.
//
// The instance UUID is generated once by src/identity.js and shown
// here read-only so the user can identify this install without
// digging into storage.

const LABEL_KEY    = "browser-gt-label";
const INSTANCE_KEY = "browser-gt-instance";

async function renderIdentity() {
  const stored = await api.storage.local.get([LABEL_KEY, INSTANCE_KEY]);
  labelEl.value          = stored[LABEL_KEY]    ?? "";
  instanceEl.textContent = stored[INSTANCE_KEY] ?? "(not yet generated — start the extension once)";
}

document.getElementById("save-label").addEventListener("click", async () => {
  const value = labelEl.value.trim();
  if (value === "") {
    await api.storage.local.remove([LABEL_KEY]);
    setStatus("Cleared label; will use browser default.", "ok");
  } else {
    await api.storage.local.set({ [LABEL_KEY]: value });
    setStatus(`Saved label: ${value}. Reconnect the extension to take effect.`, "ok");
  }
  await renderIdentity();
});

document.getElementById("clear-label").addEventListener("click", async () => {
  await api.storage.local.remove([LABEL_KEY]);
  await renderIdentity();
  setStatus("Cleared label; will use browser default.", "ok");
});

// ── Boot ────────────────────────────────────────────────────────────────────

async function loadCurrent() {
  const stored  = await api.storage.local.get(["menus", "handlers"]);
  const bundled = await loadBundled();
  menusEl.value    = format(stored.menus    ?? bundled.menus);
  handlersEl.value = format(stored.handlers ?? bundled.handlers);
  await renderRaiseTable();
  await renderIdentity();
  setStatus("");
}

loadCurrent();
