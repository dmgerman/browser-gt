// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// identity.js — persistent per-install identity for CLIENT_HELLO.
//
// Emacs uses two fields to distinguish concurrently-connected clients:
//
//   `label`    — display name.  Defaults to the build's clientName
//                ("chrome" / "firefox").  The user can override it from
//                the options page to something meaningful like
//                "chrome-work" when they run two profiles concurrently.
//   `instance` — per-install UUID.  Stable across reconnects and
//                extension reloads (stored in chrome.storage.local,
//                which is profile-scoped so two Chrome profiles get
//                distinct values).  Emacs uses the first 6 hex chars as
//                a collision suffix when two clients happen to share a
//                label.
//
// `readOrCreateIdentity(api)` returns { instance, label } — reading
// both from storage.local under the `browser-gt-instance` and
// `browser-gt-label` keys, generating a UUID on first call.  `label` is
// left undefined when the user has not set one so the caller can fall
// back to its build-time default.

const KEY_INSTANCE = "browser-gt-instance";
const KEY_LABEL    = "browser-gt-label";

export async function readOrCreateIdentity(api) {
  const stored = await api.storage.local.get([KEY_INSTANCE, KEY_LABEL]);
  let instance = stored[KEY_INSTANCE];
  if (typeof instance !== "string" || !instance) {
    instance = crypto.randomUUID();
    await api.storage.local.set({ [KEY_INSTANCE]: instance });
  }
  const rawLabel = stored[KEY_LABEL];
  const label    = (typeof rawLabel === "string" && rawLabel.length > 0)
    ? rawLabel
    : undefined;
  return { instance, label };
}

export const IDENTITY_KEYS = { INSTANCE: KEY_INSTANCE, LABEL: KEY_LABEL };
