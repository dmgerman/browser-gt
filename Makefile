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

all: check extension
