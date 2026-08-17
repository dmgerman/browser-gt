// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// payload.js — build the request payload a menu sends to Emacs.
//
// `payload` in a menu entry is either a STRING (built-in kind) or an
// OBJECT { kind: "...", ... } selecting a parameterised kind.
//
// String kinds (no parameters):
//   page-url                 url, title from the tab (ignores click context)
//   page-url-with-selection  url, title, text (current selection)
//   selection-text           url, title, text (selection or click target)
//   page-html                url, title, html (main/article/body innerHTML)
//   link-url                 url = info.linkUrl, title = the anchor's
//                            innerText (read from the live DOM); "" when
//                            no matching <a href> is found.
//   image-url                url = info.srcUrl, title = tab title
//   url                      context-aware: link URL > image URL > tab URL.
//                            With a link, title = anchor text (as in
//                            link-url); otherwise title = selection text or
//                            the tab title.  Use when a single menu serves
//                            multiple triggers (e.g. "page" + "link") and
//                            you want the click to decide which URL to send.
//   url-only                 like "url" but returns just { url } with no
//                            title.  Use when the Emacs handler has its own
//                            authoritative title source (e.g. YouTube oEmbed)
//                            and would only have to ignore whatever the
//                            anchor's aria-label happens to read out.
//
// Object kinds:
//   { kind: "tab-message", method: "...", message: { ... }? }
//       api.tabs.sendMessage(tabId, { method, ...message }) -> reply.payload
//       Generic bridge to a domain-specific content script.  The content
//       script registers a runtime.onMessage listener and dispatches on the
//       `method` field, then replies sendResponse({ payload: ... }).  Adding
//       a new scraper is a drop-in: declare the content script in
//       config.contentScripts, dispatch on a fresh `method` in the new
//       script, and reference it from a menu's `payload`.  No JS edit here.
//
// Each handler returns an object suitable as the WS request payload.

import { executeInTab } from "./executor.js";

const api = (typeof browser !== "undefined") ? browser : chrome;

async function readLinkTextInTab(tabId, linkUrl) {
  // Find the first <a href> whose normalized href equals the URL Chrome
  // reported for the click, and return its accessible name: aria-label
  // → title → trimmed innerText → first <img>'s alt.  Same fallback
  // chain Chrome uses for the link's accessibility name and tooltip,
  // so a plain <a>Click here</a> still returns "Click here" while a
  // YouTube thumbnail anchor (which wraps an <img> plus a duration
  // badge) returns the full descriptive aria-label instead of the
  // badge's "12:34".  Empty string means no matching anchor or no
  // useful text — Emacs falls back to its own metadata lookup then.
  try {
    return (await executeInTab({
      tabId,
      func: (href) => {
        const a = [...document.querySelectorAll("a[href]")]
                    .find((el) => el.href === href);
        if (!a) return "";
        const aria = a.getAttribute("aria-label")?.trim();
        if (aria) return aria;
        const title = a.getAttribute("title")?.trim();
        if (title) return title;
        const text = a.innerText?.trim();
        if (text) return text;
        const alt = a.querySelector("img[alt]")?.getAttribute("alt")?.trim();
        return alt ?? "";
      },
      args: [linkUrl],
    })) ?? "";
  } catch (e) {
    return "";
  }
}

async function readSelectionInTab(tabId) {
  try {
    return (await executeInTab({
      tabId,
      func: () => window.getSelection?.().toString() ?? "",
    })) ?? "";
  } catch (e) {
    return "";
  }
}

async function extractMainHtml(tabId) {
  const r = await executeInTab({
    tabId,
    func: () => {
      const el = document.querySelector("main") ||
                 document.querySelector("article") ||
                 document.querySelector("[role='main']") ||
                 document.body;
      return { html: el.innerHTML.trim(), url: location.href, title: document.title };
    },
  });
  if (!r) throw new Error("could not extract page content");
  return r;
}

// Invoke METHOD in a tab's content script and resolve with its
// `reply.payload'.  This is the generic bridge used by tab-message
// payloads.  The "Receiving end does not exist" error deserves its
// own message: it almost always means the tab was open before the
// extension was last (re)loaded, so no content script was ever
// injected into it — reloading the tab fixes it.  The raw browser
// wording is technically correct but obscure.
function callTabMethod(tabId, method, extra) {
  return new Promise((resolve, reject) => {
    const message = { method, ...(extra ?? {}) };
    api.tabs.sendMessage(tabId, message, (reply) => {
      if (api.runtime.lastError) {
        const raw = api.runtime.lastError.message || "";
        const noReceiver = raw.includes("Could not establish connection")
                        || raw.includes("Receiving end does not exist");
        reject(new Error(
          noReceiver
            ? `tab-message '${method}': content script not loaded — ` +
              `reload the tab (Cmd-R / Ctrl-R) and try again`
            : `tab-message '${method}': ${raw}`
        ));
        return;
      }
      if (!reply?.payload) {
        reject(new Error(`tab-message '${method}': content script returned no payload`));
        return;
      }
      resolve(reply.payload);
    });
  });
}

export async function gatherPayload(payload, { tab, info } = {}) {
  if (!tab) throw new Error("no active tab");

  // Object form: a parameterised kind.
  if (payload && typeof payload === "object") {
    switch (payload.kind) {
      case "tab-message":
        if (!payload.method) {
          throw new Error("tab-message payload requires `method`");
        }
        return await callTabMethod(tab.id, payload.method, payload.message);
      default:
        throw new Error(`unknown payload kind: ${payload.kind}`);
    }
  }

  // String form: a built-in kind.
  switch (payload) {
    case "page-url":
      return { url: tab.url, title: tab.title };

    case "page-url-with-selection":
    case "selection-text": {
      const text = info?.selectionText ?? await readSelectionInTab(tab.id);
      return { url: tab.url, title: tab.title, text };
    }

    case "page-html":
      return await extractMainHtml(tab.id);

    case "link-url": {
      if (info?.linkUrl) {
        return { url: info.linkUrl,
                 title: await readLinkTextInTab(tab.id, info.linkUrl) };
      }
      return { url: tab.url, title: tab.title };
    }

    case "image-url":
      return { url: info?.srcUrl ?? tab.url, title: tab.title };

    case "url": {
      // Context-aware: prefer the most specific URL the click implies.
      // When a link is involved the title is the link's anchor text;
      // otherwise fall back to selection text or the tab title.
      if (info?.linkUrl) {
        return { url: info.linkUrl,
                 title: await readLinkTextInTab(tab.id, info.linkUrl) };
      }
      return {
        url:   info?.srcUrl ?? tab.url,
        title: info?.selectionText || tab.title,
      };
    }

    case "url-only":
      return { url: info?.linkUrl ?? info?.srcUrl ?? tab.url };

    default:
      throw new Error(`unknown payload kind: ${payload}`);
  }
}
