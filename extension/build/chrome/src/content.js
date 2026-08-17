// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// content.js — relay window.postMessage to the background service worker.
//
// Pages can trigger Emacs requests by posting a message like:
//
//   window.postMessage(
//     { source: "browser-gt", name: "EWW", payload: { url: "..." } },
//     "*"
//   );
//
// This mirrors the spookfox SPOOKFOX_RELAY_TO_EMACS hook so existing
// page-side integrations keep working.  Pages should only be considered
// allowed if they speak this protocol intentionally.

var api = (typeof browser !== "undefined") ? browser : chrome;

window.addEventListener("message", (event) => {
  if (event.source !== window) return;
  const data = event.data;
  if (!data || data.source !== "browser-gt") return;
  if (typeof data.name !== "string" || !data.name) return;
  api.runtime.sendMessage({
    target:  "service-worker",
    type:    "RELAY_TO_EMACS",
    name:    data.name,
    payload: data.payload ?? null,
  });
});
