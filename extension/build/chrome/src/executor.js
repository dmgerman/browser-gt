// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// executor.js (Chrome) — per-target adapter for "run this function in
// a tab and return its value".
//
// Shared code in src/consent.js and src/payload.js calls
// `executeInTab({ tabId, func, args })`.  On Chrome we forward to
// `chrome.scripting.executeScript`, which natively accepts a function
// reference plus an args array.  We always read the first frame's
// result, because the only callers inject DOM-touching helpers that
// run once per tab (consent overlay, selection read, main-html extract).

export async function executeInTab({ tabId, func, args = [] }) {
  const results = await chrome.scripting.executeScript({
    target: { tabId },
    func,
    args,
  });
  return results?.[0]?.result;
}
