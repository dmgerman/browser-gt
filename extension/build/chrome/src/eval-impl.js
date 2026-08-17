// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// eval-impl.js (Chrome) — runtime-specific JavaScript-eval primitive.
//
// The shared `handlers.js` imports the three functions exported here.
// Each browser target supplies its own implementation; for Chrome the
// implementation is `chrome.userScripts.execute`, which requires the
// user to have toggled "Allow User Scripts" on for this extension in
// chrome://extensions.

export function evalAvailable() {
  return !!chrome.userScripts && typeof chrome.userScripts.execute === "function";
}

export function evalUnavailableMessage() {
  return "chrome.userScripts.execute unavailable. " +
         "Enable 'Allow User Scripts' for this extension in chrome://extensions.";
}

export async function evalInTab({ tabId, code, world = "MAIN" }) {
  return await chrome.userScripts.execute({
    target: { tabId },
    js: [{ code }],
    world,
  });
}
