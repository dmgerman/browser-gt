// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// executor.js (Firefox MV2) — per-target adapter for "run this
// function in a tab and return its value".
//
// MV2's browser.tabs.executeScript only accepts a code STRING, not a
// function reference plus args.  We serialise the call by stringifying
// the function and JSON-stringifying its arguments.  The resulting
// code runs in the content-script isolated world (same as a regular
// declared content script).  That is sufficient for every caller in
// the shared tree:
//
//   - consent.js renders a DOM overlay (no page-world access needed).
//   - payload.js reads `window.getSelection` and an element's
//     innerHTML (both available from the isolated world).
//
// Args must be JSON-serialisable.  Functions, DOM nodes, and class
// instances will not survive the round trip; the caller is responsible
// for keeping payloads to primitives, plain objects, and arrays.
//
// Firefox MV2 returns each frame's last-expression value as
// `[value, value, …]`.  We return the first frame's value, mirroring
// the Chrome adapter's contract.

export async function executeInTab({ tabId, func, args = [] }) {
  const encodedArgs = args.map((a) => JSON.stringify(a)).join(", ");
  const code        = `(${func.toString()})(${encodedArgs})`;
  const results     = await browser.tabs.executeScript(tabId, { code });
  return results?.[0];
}
