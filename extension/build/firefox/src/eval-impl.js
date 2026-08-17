// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// eval-impl.js (Firefox MV2) — runtime-specific JavaScript-eval
// primitive for the `EVAL_IN_ACTIVE_TAB` handler.
//
// MV2 Firefox runs arbitrary code via `browser.tabs.executeScript`,
// which:
//
//   - takes a code STRING (not a function reference),
//   - runs the script in the content-script isolated world (same
//     execution context our declared content scripts run in),
//   - resolves its returned Promise with an array of the last
//     expression's value from each frame the script ran in.
//
// We return a shape that matches Chrome's MV3 `userScripts.execute`
// response — `[{ frameId, documentId, result }, …]` — so the babel
// integration on the Emacs side parses both targets uniformly.
//
// Limitations called out, not silently swallowed:
//
//   - `world: "MAIN"` (the user's default) is not supported on MV2
//     Firefox; the script always runs in the isolated world.  When
//     `world` is anything but "USER_SCRIPT", we throw with a clear
//     message so the babel block fails visibly instead of returning a
//     value evaluated in the wrong context.
//   - `tabId` defaults to the active tab in the current window,
//     matching the Chrome adapter's `tabHasConsent` flow.

export function evalAvailable() { return true; }

export function evalUnavailableMessage() {
  // evalAvailable() always returns true, so this is never read.  Kept
  // for symmetry with the Chrome adapter's shape.
  return "JavaScript evaluation is available on Firefox MV2.";
}

function isUsableWorld(world) {
  // Treat "USER_SCRIPT" and the falsy/default case as the isolated
  // content-script world.  Anything else (notably "MAIN") is rejected.
  if (world == null || world === "" || world === "USER_SCRIPT") return true;
  return false;
}

export async function evalInTab({ tabId, code, world }) {
  if (!isUsableWorld(world)) {
    throw new Error(
      `world: ${JSON.stringify(world)} is not supported on Firefox MV2; ` +
      `browser-gt only runs scripts in the content-script isolated world. ` +
      `Use ":world USER_SCRIPT" or omit :world to run in the isolated context.`,
    );
  }
  const results = await browser.tabs.executeScript(tabId, { code });
  return results.map((value, frameId) => ({
    frameId,
    documentId: null,
    result: value,
  }));
}
