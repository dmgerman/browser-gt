# Makefile for browser-gt.
#
# Package-specific settings only; every shared rule lives in
# Makefile.common, which is an identical copy across the dmg packages.
# Run `make help' for the target list, and see the header of
# Makefile.common for what each variable below controls.
#
# Besides the elisp, this drives the WebExtension builds by delegating
# to extension/Makefile.

PACKAGE = browser-gt

# Foundational file first so follow-on files can (require 'browser-gt)
# without erroring when compiled in isolation.
EL_FILES = browser-gt.el \
           browser-gt-www.el \
           browser-gt-chatgpt.el \
           browser-gt-youtube.el \
           browser-gt-tab-manager.el \
           browser-gt-babel.el \
           browser-gt-url-handler.el

# `websocket' is the runtime dependency declared in Package-Requires;
# `package-lint' is the lint tool itself.  Vertico is a *soft* runtime
# dependency of browser-gt-tab-manager.el — the anchor-restore path
# prefers vertico's internals when available and degrades gracefully
# otherwise — so it is NOT installed here.  Byte-compile stays
# warning-free via the `declare-function' / `defvar' stubs at the top
# of that file.
DEPS = websocket package-lint

# No suite yet; `make test' reports the skip until tests/*.el appears.
TEST_DIR = tests

INFO_SRC = README.org

# The WebExtension bundles are rebuilt alongside the elisp so a source
# change and its build output stay in the same commit.
DEFAULT_EXTRA = extension

HELP_EXTRA = "  make extension      rebuild the Chrome + Firefox bundles" \
             "  make all            check + extension"

include Makefile.common

# Delegate to the extension's own Makefile; its default target builds
# both the Chrome (Manifest V3) and Firefox (Manifest V2) bundles.
.PHONY: extension all

extension:
	$(MAKE) -C extension

# Guard against linting a checkout that is not the one git (and hence
# CI) sees.  A second, stale checkout whose `.git' file points at a
# gitdir whose `core.worktree' names a *different* directory reads as
# "clean" to git while `make' happily compiles and lints the stale
# files sitting next to it -- a green `check-ci' on code that is not
# what gets pushed.  That is exactly how the 2026-09-22 checkdoc
# failure reached CI.  Comparing the physical path of `git
# rev-parse --show-toplevel' against $(CURDIR) catches it outright.
#
# It is a prerequisite of `compile' rather than an entry of
# CHECK_EXTRA: `compile' is the first thing `check' (and so
# `check-ci') runs, while CHECK_EXTRA is appended last, after the
# stale files have already been linted.  It lives here, not in
# Makefile.common, because that file is a synced copy that must not
# be edited in place.
.PHONY: check-worktree
compile: check-worktree
check-worktree:
	@top=`git rev-parse --show-toplevel 2>/dev/null`; \
	if [ -z "$$top" ]; then \
	  echo "not inside a git worktree: $(CURDIR)"; \
	  exit 1; \
	fi; \
	if [ "`cd \"$$top\" && pwd -P`" != "`cd \"$(CURDIR)\" && pwd -P`" ]; then \
	  echo "WRONG WORKTREE -- refusing to run."; \
	  echo "  make is running in: $(CURDIR)"; \
	  echo "  git resolves to   : $$top"; \
	  echo "Sources here are NOT what git or CI sees; cd to the path above."; \
	  exit 1; \
	fi

all: check extension
