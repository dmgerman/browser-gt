// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-4-7
//
// Extracts the current ChatGPT conversation from the DOM.
//
// ChatGPT virtualizes in two dimensions:
//   1. Between messages: turns are mounted and unmounted as you scroll the
//      conversation list.
//   2. Within long messages: each top-level child of an assistant turn carries
//      data-start (an offset into the source markdown) and is itself
//      mounted/unmounted as the section enters or leaves the viewport. The
//      message wrapper stays put while its body fades in and out.
//
// We scroll top-to-bottom and, on every pass, record any currently mounted
// sections keyed by data-start, per message. At the end we stitch each
// message's sections back together in data-start order. Messages with no
// sectioned children (typical user turns, short replies) fall back to a
// whole-message snapshot.
//
// See ai/chatgpt.md for the full background on why this is the shape it is.

var api = (typeof browser !== "undefined") ? browser : chrome;

// Flip to true to get `[chatgpt-extract]` traces in the page console.
const DEBUG = false;
const log = DEBUG
  ? (...args) => console.log("[chatgpt-extract]", ...args)
  : () => {};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function findScrollableAncestor(el) {
  let node = el.parentElement;
  while (node && node !== document.documentElement) {
    const oy = window.getComputedStyle(node).overflowY;
    if ((oy === "auto" || oy === "scroll") && node.scrollHeight > node.clientHeight) {
      return node;
    }
    node = node.parentElement;
  }
  return document.documentElement;
}

function hasDataStartAncestor(el, root) {
  let p = el.parentElement;
  while (p && p !== root) {
    if (p.hasAttribute("data-start")) return true;
    p = p.parentElement;
  }
  return false;
}

function collectVisible(map, container) {
  const containerTop = container.getBoundingClientRect().top;
  const containerScroll = container.scrollTop;

  document.querySelectorAll("[data-message-author-role]").forEach((node) => {
    const id = node.getAttribute("data-message-id");
    if (!id) return;
    const role = node.getAttribute("data-message-author-role");

    // Position within the scrollable content, stable across scroll positions.
    // We refresh this on every visit so the *latest* layout state wins —
    // earlier sightings happen with smaller scrollHeight and less mounted
    // above, giving inaccurate positions for the sticky tail wrappers.
    const position = node.getBoundingClientRect().top - containerTop + containerScroll;

    const existingEntry = map.get(id);
    if (existingEntry) existingEntry.position = position;

    // Gather what's actually mounted right now before touching the map.
    // ChatGPT keeps the last few message *wrappers* mounted regardless of
    // scroll, but unmounts their inner [data-start] sections when off-screen;
    // creating an empty entry here would make haveTarget() lie.
    const newSections = [];
    node.querySelectorAll("[data-start]").forEach((el) => {
      if (hasDataStartAncestor(el, node)) return;
      const start = el.getAttribute("data-start");
      if (start == null) return;
      const text = el.innerText;
      if (!text) return;
      newSections.push({ start, html: el.outerHTML, text });
    });

    let fallbackHtml = "";
    let fallbackText = "";
    if (newSections.length === 0) {
      fallbackHtml = node.innerHTML.trim();
      fallbackText = node.innerText.trim();
    }

    if (newSections.length === 0 && !fallbackText) return;

    let entry = existingEntry;
    if (!entry) {
      entry = { role, sections: new Map(), html: "", text: "", position };
      map.set(id, entry);
    }

    for (const s of newSections) {
      const existing = entry.sections.get(s.start);
      if (!existing || s.text.length >= existing.text.length) {
        entry.sections.set(s.start, { html: s.html, text: s.text });
      }
    }

    if (newSections.length === 0 && fallbackText.length > entry.text.length) {
      entry.html = fallbackHtml;
      entry.text = fallbackText;
    }
  });
}

function lastMountedMessageId() {
  const all = document.querySelectorAll("[data-message-author-role][data-message-id]");
  if (all.length === 0) return null;
  return all[all.length - 1].getAttribute("data-message-id");
}

function stateSignature(map) {
  let sectionCount = 0;
  let totalChars = 0;
  for (const entry of map.values()) {
    sectionCount += entry.sections.size;
    for (const v of entry.sections.values()) totalChars += v.text.length;
    totalChars += entry.text.length;
  }
  return sectionCount + ":" + totalChars;
}

function turnsToArray(map) {
  // Map insertion order doesn't equal conversation order: ChatGPT keeps the
  // last few wrappers sticky, so the first collect at scroll-top inserts
  // bottom-of-conversation turns right after top-of-conversation turns.
  // Sort by recorded absolute Y inside the scroll container instead.
  const entries = Array.from(map.values()).sort((a, b) => a.position - b.position);
  const out = [];
  for (const entry of entries) {
    let html;
    let text;
    if (entry.sections.size > 0) {
      const sorted = Array.from(entry.sections.entries()).sort(
        (a, b) => Number(a[0]) - Number(b[0]),
      );
      html = sorted.map(([, v]) => v.html).join("");
      text = sorted.map(([, v]) => v.text).join("\n\n").trim();
    } else {
      html = entry.html;
      text = entry.text;
    }
    if (text) out.push({ role: entry.role, html, text });
  }
  return out;
}

async function scrollToLoadAll() {
  const firstMsg = document.querySelector("[data-message-author-role]");
  if (!firstMsg) return new Map();

  const container = findScrollableAncestor(firstMsg);
  const turns = new Map();

  log("invoked. initial scrollTop:", container.scrollTop, "scrollHeight:", container.scrollHeight,
      "clientHeight:", container.clientHeight, "container:", container);
  log("initial last mounted id:", lastMountedMessageId(),
      "initial mounted count:", document.querySelectorAll("[data-message-author-role][data-message-id]").length);

  // Anchor on the actual last turn.
  container.scrollTop = container.scrollHeight;
  await sleep(1000);
  let targetId = lastMountedMessageId();
  log("anchor pass 1: scrollTop:", container.scrollTop, "scrollHeight:", container.scrollHeight,
      "targetId:", targetId);
  container.scrollTop = container.scrollHeight;
  await sleep(600);
  targetId = lastMountedMessageId() || targetId;
  log("anchor pass 2: scrollTop:", container.scrollTop, "scrollHeight:", container.scrollHeight,
      "targetId:", targetId);

  container.scrollTop = 0;
  await sleep(800);
  collectVisible(turns, container);
  log("after scroll-to-top: turns:", turns.size, "haveTarget:", turns.has(targetId));

  const haveTarget = () => !targetId || turns.has(targetId);

  let lastScrollTop = -1;
  let iter = 0;
  while (true) {
    const { scrollTop, clientHeight, scrollHeight } = container;

    if (haveTarget() && scrollTop + clientHeight >= scrollHeight - 50) {
      log("main loop exit (bottom + target):", "iter:", iter, "scrollTop:", scrollTop,
          "scrollHeight:", scrollHeight, "turns:", turns.size);
      break;
    }
    if (scrollTop === lastScrollTop) {
      log("main loop exit (stuck):", "iter:", iter, "scrollTop:", scrollTop,
          "scrollHeight:", scrollHeight, "haveTarget:", haveTarget(), "turns:", turns.size);
      break;
    }

    lastScrollTop = scrollTop;
    container.scrollTop += clientHeight * 0.8;
    await sleep(700);
    collectVisible(turns, container);
    iter++;
  }

  // Settle at the bottom. scrollTop = scrollHeight stops at the *estimated*
  // bottom and doesn't make ChatGPT's virtualizer commit the unmeasured
  // tail; scrollIntoView on the target node does, because it's the same
  // motion the user would make.
  let prevSignature = "";
  let stableCount = 0;
  for (let i = 0; i < 12; i++) {
    const targetNode = targetId
      ? document.querySelector(`[data-message-id="${CSS.escape(targetId)}"]`)
      : null;
    if (targetNode) {
      targetNode.scrollIntoView({ block: "end" });
    } else {
      container.scrollTop = container.scrollHeight;
    }
    await sleep(900);
    collectVisible(turns, container);
    const sig = stateSignature(turns);
    const bottomNow = lastMountedMessageId();
    log("settle iter", i, "scrollTop:", container.scrollTop, "scrollHeight:", container.scrollHeight,
        "sig:", sig, "haveTarget:", haveTarget(), "bottomNow:", bottomNow,
        "targetMounted:", !!targetNode, "turns:", turns.size);
    if (haveTarget() && sig === prevSignature) {
      stableCount++;
      if (stableCount >= 2) {
        log("settle exit: stable for 2 iterations");
        break;
      }
    } else {
      stableCount = 0;
    }
    prevSignature = sig;
  }

  log("final: turns:", turns.size, "targetId captured:", turns.has(targetId));
  log("turn dump (id role sections secChars fallbackChars):");
  for (const [id, entry] of turns) {
    let secChars = 0;
    for (const v of entry.sections.values()) secChars += v.text.length;
    log(`  ${id} ${entry.role} sec=${entry.sections.size} secChars=${secChars} fbChars=${entry.text.length}`);
  }
  return turns;
}

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.method === "extract-conversation") {
    scrollToLoadAll()
      .then((turnsMap) => {
        sendResponse({
          payload: {
            source: "chatgpt",
            url: location.href,
            title: document.title,
            turns: turnsToArray(turnsMap),
          },
        });
      })
      .catch((err) => {
        console.error("browser-gt: scrollToLoadAll failed, falling back to visible turns:", err);
        const turnsMap = new Map();
        const firstMsg = document.querySelector("[data-message-author-role]");
        if (firstMsg) collectVisible(turnsMap, findScrollableAncestor(firstMsg));
        sendResponse({
          payload: {
            source: "chatgpt",
            url: location.href,
            title: document.title,
            turns: turnsToArray(turnsMap),
          },
        });
      });
    return true; // keep channel open for async response
  }
});
