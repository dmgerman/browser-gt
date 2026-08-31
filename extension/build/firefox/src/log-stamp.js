// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
// Assisted-by: Claude:claude-opus-5
//
// log-stamp.js — the timestamp prefix every module's `log' helper uses.
//
// Two forms of the same instant on every line: epoch milliseconds, which
// is what the timing stamps on the wire are measured in and what sorts
// and subtracts without parsing, and local civil time to the
// millisecond, which is what the user reads and what the Emacs
// *Messages* slow-line carries.  Emacs writes the identical pair, so a
// line from either side can be located in the other log by either field.
//
// Local time, not UTC: Emacs formats with `format-time-string' in the
// local zone, and the point of the second field is that the two logs
// read alike.
//
// See doc/latency-instrumentation.org.

export function stamp(ms) {
  const t = ms ?? Date.now();
  const d = new Date(t);
  const p = (n, width = 2) => String(n).padStart(width, "0");
  return `${t} ${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
       + `T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
       + `.${p(d.getMilliseconds(), 3)}`;
}
