// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-5
//
// Extracts the current ChatGPT conversation from the DOM.
//
// Three properties of the page shape this file:
//
//   1. The conversation is virtualized, and older turns are fetched as the
//      view approaches them. A freshly loaded tab holds only the last few
//      turns; the rest arrive in bursts while scrolling up. The DOM keeps a
//      sliding window of a few turns and removes the others, so a single
//      querySelectorAll returns a scroll-position-dependent subset and still
//      looks like success. We climb from the newest turn to the oldest and
//      accumulate units keyed by data-chatgpt-search-unit-key.
//
//      Reaching the end of what is loaded is not reaching the oldest turn,
//      and the difference is invisible: the container simply stops moving
//      for a second while the next chunk is fetched. Treating one such
//      pause as the top of the conversation is what makes a 23-turn thread
//      save as 7 turns and report success. The climb therefore requires
//      several consecutive rounds with no movement, no growth, and no new
//      units before it accepts that it is at the oldest turn.
//
//   2. The scroll container is a column-reverse flex box: scrollTop is 0 at
//      the newest turn and negative toward the oldest, and scrollHeight
//      changes while scrolling because turns mount, unmount, and load. The
//      only assumption made about it is that increasing scrollTop moves
//      toward the newest turn, which holds for both container directions.
//      Turn order comes from measured geometry rather than the order units
//      were seen in, since the climb meets them newest-first.
//
//   3. A reply body carries interface chrome (icon <svg>s, copy/edit
//      buttons, citation favicons) and its code blocks have no <pre>. A
//      <code> with no <pre> ancestor is inline code by HTML semantics, so a
//      converter collapses a multi-line block into one line and drops every
//      newline. clean() removes the chrome and restores block semantics
//      before any HTML leaves the page.
//
// Selector reference, and the observations behind all of the above:
// ai/2026-09-25-chatgpt-changes.md. Verified against ChatGPT build
// e74a52d7f5d8aa5dbff2cced1149587fceddaf3c on 2026-09-25.

var api = (typeof browser !== "undefined") ? browser : chrome;

// Flip to true to get `[chatgpt-extract]` traces in the page console.
const DEBUG = false;
const log = DEBUG
  ? (...args) => console.log("[chatgpt-extract]", ...args)
  : () => {};

// Every ChatGPT-specific selector lives here. Classes are hashed CSS modules
// (MarkdownRoot-rZKhxa, Paragraph-kKnbIo) that churn on each deploy, so match
// on data-* attributes, and on their presence rather than their value where
// the value is empty or looks enumerable.
const SELECTORS = {
  // A message unit. Its key is "<turn-id>:<index>:<role>"; only the role
  // segment is dependable (see roleOf and keyOf).
  unit:        "[data-chatgpt-search-unit-key]",
  // Identity. messageIds is space-separated and the assistant unit repeats
  // its own id; selectionId and turnKey are the fallbacks.
  messageIds:  "data-chatgpt-search-message-ids",
  selectionId: "[data-chatgpt-selection-message-id]",
  turnKey:     "[data-turn-key]",
  // Pre-2026-09 markup, kept so a rollback on OpenAI's side is a non-event.
  unitLegacy:  "[data-message-author-role]",
  userBody:    "[data-user-message-bubble]",
  replyBody:   "[data-markdown-text-style]",
  scroller:    "[data-app-action-timeline-scroll]",
  // ChatGPT's own "omit this from a markdown copy" marker, on the action bar
  // above each code block. Better than the hashed class it sits next to.
  copyExclude: '[data-markdown-copy="exclude"]',
  // Screen-reader heading ("ChatGPT said:") inside an assistant unit.
  srHeading:   "[data-conversation-role]",
};

// Climb tuning. A step overlaps the previous window by 20% so a turn that
// mounts slowly is still seen on the next step. A step that changes nothing
// waits longer, because the usual reason is that older turns are being
// fetched; QUIET_ROUNDS of those in a row is what ends the climb.
const STEP_FRACTION = 0.8;
const STEP_SETTLE_MS = 600;
const QUIET_SETTLE_MS = 1000;
const QUIET_ROUNDS = 4;
const MAX_STEPS = 600;

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

// ── Unit identity ───────────────────────────────────────────────────────────

// Which markup this page uses: "unit-key" (current) or "author-role" (legacy).
function detectSchema() {
  if (document.querySelector(SELECTORS.unit)) return "unit-key";
  if (document.querySelector(SELECTORS.unitLegacy)) return "author-role";
  return null;
}

function unitNodes(schema) {
  return document.querySelectorAll(
    schema === "unit-key" ? SELECTORS.unit : SELECTORS.unitLegacy,
  );
}

// A stable identity for the message in NODE, used to recognise it again on
// a later sighting.
//
// The unit key must not be used for this. On conversations whose turn ids
// have not settled — every turn of some conversations, not just new ones —
// its prefix is "fallback-turn-N", where N is the unit's index *within the
// mounted window*. The same message then carries different keys at
// different scroll positions, and worse, two different messages collide on
// one key: a climb keyed that way duplicates some rounds and drops others.
// The message id is a real UUID and is present on both roles.
function keyOf(node, schema) {
  if (schema !== "unit-key") return node.getAttribute("data-message-id");

  const ids = node.getAttribute(SELECTORS.messageIds);
  if (ids && ids.trim()) return ids.trim().split(/\s+/)[0];

  const selected = node.querySelector(SELECTORS.selectionId);
  if (selected) return selected.getAttribute("data-chatgpt-selection-message-id");

  // The turn container's key is the round's user message id, so it needs
  // the role to tell the two units of a round apart.
  const turn = node.closest(SELECTORS.turnKey);
  if (turn) return turn.getAttribute("data-turn-key") + ":" + roleOf(node, schema);

  // Last resort. Window-relative when the prefix is "fallback-turn-N", but
  // better than discarding the message.
  return node.getAttribute("data-chatgpt-search-unit-key");
}

function roleOf(node, schema) {
  if (schema !== "unit-key") return node.getAttribute("data-message-author-role");
  // Take the role off the end of the key. The prefix is a turn id, not a
  // message id, and is not always a UUID — turns whose ids have not settled
  // use "fallback-turn-0". The middle index is neither dense nor consistent
  // between the two forms, so nothing may be parsed positionally.
  const key = node.getAttribute("data-chatgpt-search-unit-key") || "";
  const colon = key.lastIndexOf(":");
  return colon === -1 ? "" : key.slice(colon + 1);
}

// The unit wraps more than the message: the assistant's screen-reader
// heading is its first child. Read the body from the nested node, and fall
// back to the unit so a future tweak degrades instead of returning nothing —
// clean() drops the heading either way.
function bodyOf(node, role) {
  const sel = role === "user" ? SELECTORS.userBody : SELECTORS.replyBody;
  return node.querySelector(sel) || node;
}

// ── Cleaning ────────────────────────────────────────────────────────────────

// Return the cleaned innerHTML of EL: the message without the interface
// around it, and with code blocks that survive conversion. Anything reading
// this HTML — pandoc, a markdown serialiser, a plain-text extractor — would
// otherwise faithfully translate the chrome and corrupt the code blocks.
function clean(el) {
  const c = el.cloneNode(true);

  // "ChatGPT said:" and friends; only reachable when bodyOf fell back to the
  // whole unit, but harmless to always run.
  c.querySelectorAll(".sr-only, " + SELECTORS.srHeading).forEach((n) => n.remove());

  // Decorative icons and the buttons holding them. Pandoc turns an inline
  // <svg> into an <img> with a base64 data: URI, hundreds of characters of
  // noise per icon. Most carry aria-hidden, but not all, so match the
  // element type instead.
  c.querySelectorAll("svg, button").forEach((n) => n.remove());

  // Citation favicons nest a link inside its own description. Assistant
  // images are kept: the favicon pattern is an empty alt inside an <a>.
  c.querySelectorAll("img").forEach((n) => {
    const src = n.getAttribute("src") || "";
    const alt = (n.getAttribute("alt") || "").trim();
    if (src.startsWith("data:")
        || /faviconV2|gstatic\.com/.test(src)
        || (n.closest("a") && alt === "")) {
      n.remove();
    }
  });

  // The code-block action bar holds the language label. Read the label onto
  // the code element before removing the bar, or the label leaks into the
  // prose as a stray "Plain text" paragraph and the language is lost.
  c.querySelectorAll(SELECTORS.copyExclude).forEach((n) => {
    const label = (n.textContent || "").trim().toLowerCase();
    const code = n.parentElement && n.parentElement.querySelector("code");
    if (code && label && label !== "plain text" && /^[\w+#.-]+$/.test(label)) {
      code.classList.add("language-" + label);
    }
    n.remove();
  });

  // Restore block semantics. The class reset must happen for every <code>,
  // inline ones included: a converter reads the first class as the language
  // name and would otherwise emit `#+begin_src whitespace-pre!`.
  c.querySelectorAll("code").forEach((n) => {
    const lang = [...n.classList].find((x) => x.startsWith("language-"));
    n.className = lang || "";
    if (!n.closest("pre") && /\n/.test(n.textContent || "")) {
      const pre = document.createElement("pre");
      n.replaceWith(pre);
      pre.appendChild(n);
    }
  });

  return c;
}

function snapshot(node, role) {
  const body = bodyOf(node, role);
  const cleaned = clean(body);
  // innerText is layout-dependent: under content-visibility it returns empty
  // or truncated text while textContent still works. Prefer it for its line
  // breaks, fall back to the cleaned clone's textContent when it is empty.
  const text = (body.innerText || "").trim() || (cleaned.textContent || "").trim();
  return { html: cleaned.innerHTML.trim(), text };
}

// ── Collection ──────────────────────────────────────────────────────────────

// Record every unit currently mounted into TURNS, keyed by message id, and
// return how many were new. Position is the unit's offset inside the
// scrolled content: viewport offset plus the current scrollTop, which is
// invariant under scrolling in either direction.
//
// A sighting is kept or discarded whole. Taking the position from one
// sighting and the text from another would, if two messages ever shared an
// identity again, file one message's words at another's place in the
// conversation — which reads as a plausible conversation that never
// happened, rather than as an error.
function collect(turns, schema, scroller) {
  const scrollerTop = scroller ? scroller.getBoundingClientRect().top : 0;
  const scrollTop = scroller ? scroller.scrollTop : 0;
  let added = 0;

  unitNodes(schema).forEach((node) => {
    const key = keyOf(node, schema);
    if (!key) return;
    const role = roleOf(node, schema);
    // Only user and assistant have been observed. Ignore anything else
    // rather than mis-binding a tool or system unit to a known role.
    if (role !== "user" && role !== "assistant") return;

    const snap = snapshot(node, role);
    if (!snap.text && !snap.html) return;

    const position = node.getBoundingClientRect().top - scrollerTop + scrollTop;
    const prev = turns.get(key);
    if (!prev) {
      turns.set(key, { role, html: snap.html, text: snap.text, position });
      added++;
      return;
    }
    // A later sighting can hold more: a reply still streaming when the
    // climb passed it, or a body that was only partly mounted. It also
    // carries a better position, measured with more of the page mounted.
    if (snap.text.length >= prev.text.length) {
      prev.html = snap.html;
      prev.text = snap.text;
      prev.position = position;
    }
  });
  return added;
}

function turnsToArray(turns) {
  // The climb meets turns newest-first, so insertion order is not
  // conversation order. Sort by measured position instead.
  return Array.from(turns.values())
    .filter((t) => t.text || t.html)
    .sort((a, b) => a.position - b.position)
    .map((t) => ({ role: t.role, html: t.html, text: t.text }));
}

// ── Sweep ───────────────────────────────────────────────────────────────────

function findScroller(schema) {
  const named = document.querySelector(SELECTORS.scroller);
  if (named) return named;
  const first = document.querySelector(
    schema === "unit-key" ? SELECTORS.unit : SELECTORS.unitLegacy,
  );
  return first ? findScrollableAncestor(first) : null;
}

// Walk the whole conversation and return { turns, complete, … }. `complete`
// says whether the oldest turn was actually reached; a caller must not
// present a partial climb as the conversation.
async function harvest() {
  const schema = detectSchema();
  const turns = new Map();
  if (!schema) {
    return { schema: null, turns, complete: false,
             reason: "no message units found (selectors may be stale)" };
  }

  const scroller = findScroller(schema);
  if (!scroller) {
    collect(turns, schema, null);
    return { schema, turns, complete: false, reason: "no scroll container found" };
  }

  // A column-reverse container scrolls from 0 (newest) down to a negative
  // scrollTop (oldest); a normal one from 0 (oldest) up to scrollHeight.
  // Increasing scrollTop moves toward the newest turn in both.
  const reverse = window.getComputedStyle(scroller).flexDirection === "column-reverse";
  const resume = scroller.scrollTop;

  log("schema:", schema, "reverse:", reverse, "scrollTop:", scroller.scrollTop,
      "scrollHeight:", scroller.scrollHeight, "clientHeight:", scroller.clientHeight);

  // Start at the newest turn, so the climb covers the whole conversation
  // whatever the user was looking at.
  scroller.scrollTop = reverse ? 0 : scroller.scrollHeight;
  await sleep(STEP_SETTLE_MS);
  collect(turns, schema, scroller);

  // Climb toward the oldest turn one window at a time. Stepping by less
  // than a screen — rather than jumping to the far end — keeps consecutive
  // windows overlapping, so no turn can pass by unseen between samples.
  let steps = 0;
  let quiet = 0;
  while (steps < MAX_STEPS && quiet < QUIET_ROUNDS) {
    const top = scroller.scrollTop;
    const height = scroller.scrollHeight;

    scroller.scrollTop = top - scroller.clientHeight * STEP_FRACTION;
    await sleep(quiet > 0 ? QUIET_SETTLE_MS : STEP_SETTLE_MS);
    steps++;

    const added = collect(turns, schema, scroller);
    const moved = scroller.scrollTop < top - 1;
    const grew = scroller.scrollHeight > height;

    // No movement, no growth and nothing new means either the oldest turn
    // or a fetch in flight. They look identical, so only a run of them is
    // taken as the end of the conversation.
    quiet = (moved || grew || added > 0) ? 0 : quiet + 1;
    log("climb", steps, "top:", top, "->", scroller.scrollTop, "h:", height,
        "->", scroller.scrollHeight, "added:", added, "quiet:", quiet);
  }

  scroller.scrollTop = resume;
  await sleep(STEP_SETTLE_MS);
  // The newest turn can have grown while the climb ran, and the restored
  // view is where it is mounted.
  collect(turns, schema, scroller);

  const complete = quiet >= QUIET_ROUNDS;
  log("done:", turns.size, "units in", steps, "steps, complete:", complete);
  return {
    schema,
    turns,
    complete,
    reason: complete ? null
      : "gave up after " + steps + " scroll steps without reaching the oldest turn",
  };
}

// ── Message handler ─────────────────────────────────────────────────────────

function payloadFrom(result) {
  return {
    source: "chatgpt",
    url: location.href,
    title: document.title,
    turns: turnsToArray(result.turns),
    // Virtualization means a scrape can be a scroll-position-dependent
    // window rather than the conversation. Say which it was; the Emacs side
    // warns when this is false.
    complete: result.complete,
    incompleteReason: result.reason || null,
    schema: result.schema,
    build: document.documentElement.getAttribute("data-build") || null,
  };
}

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.method === "extract-conversation") {
    harvest()
      .then((result) => sendResponse({ payload: payloadFrom(result) }))
      .catch((err) => {
        console.error("browser-gt: ChatGPT sweep failed, falling back to the "
                      + "turns currently in the DOM:", err);
        const schema = detectSchema();
        const turns = new Map();
        if (schema) collect(turns, schema);
        sendResponse({
          payload: payloadFrom({
            schema,
            turns,
            complete: false,
            reason: "sweep failed: " + (err && err.message ? err.message : String(err)),
          }),
        });
      });
    return true; // keep channel open for async response
  }
});
