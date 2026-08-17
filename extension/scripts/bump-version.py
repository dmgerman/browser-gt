#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
# Assisted-by: Claude:claude-opus-4-7
#
# Bump the browser-gt version in browser-gt.el and config.json in lockstep.
#
# Three places must move together:
#   1. `(defconst browser-gt-version "...")' in browser-gt.el  — the wire
#      version enforced by CLIENT_HELLO's strict equality check.
#   2. `;; Version: ...' in browser-gt.el's file header      — what MELPA
#      and package.el read to name the installed package version.
#   3. `"version": "..."' in extension/config.json        — copied
#      into every built manifest.json and sent in CLIENT_HELLO.
#
# Any one of them drifting from the others causes user-visible
# breakage (a version-check reject, a stale MELPA display, or a
# mismatched hello).  This script updates all three from a single
# command; run it from the repo root or from extension/ — the paths
# it touches are resolved relative to the script's own location.
#
# Usage: scripts/bump-version.py X.Y[.Z]

import pathlib
import re
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: bump-version.py X.Y[.Z]")
    version = sys.argv[1]
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", version):
        sys.exit(f"invalid version: {version!r}")

    extension_dir = pathlib.Path(__file__).resolve().parent.parent
    repo_root = extension_dir.parent
    cfg_path = extension_dir / "config.json"
    el_path = repo_root / "browser-gt.el"

    # Regex-substitute each file in place so unrelated formatting
    # (array layout in config.json, blank lines and comments in
    # browser-gt.el) is preserved verbatim.  Each entry names the file
    # and the pattern; browser-gt.el has TWO patterns (the file header
    # and the `browser-gt-version' defconst) — a match count > 1 means
    # they must both hit, so a single-shot bump keeps them in sync.
    changed = []
    for path, patterns in [
        (el_path, [
            re.compile(r'(^;; Version: )[^\s]+', re.MULTILINE),
            re.compile(r'(\(defconst browser-gt-version ")[^"]*(")'),
        ]),
        (cfg_path, [
            re.compile(r'("version":\s*")[^"]*(")'),
        ]),
    ]:
        text = path.read_text()
        new = text
        for pattern in patterns:
            if not pattern.search(new):
                sys.exit(f"version field not found in {path} for {pattern.pattern!r}")
            # Header pattern captures only one group (the prefix);
            # defconst / json patterns capture two (prefix + suffix
            # quote).  Build the replacement dynamically so both
            # shapes work.
            groups = pattern.groups
            if groups == 1:
                new = pattern.sub(rf"\g<1>{version}", new, count=1)
            else:
                new = pattern.sub(rf"\g<1>{version}\g<2>", new, count=1)
        if new != text:
            path.write_text(new)
            changed.append(path.name)

    if changed:
        print(f"bumped {', '.join(changed)} -> {version}")
    else:
        print(f"already at {version}; nothing to do")


if __name__ == "__main__":
    main()
