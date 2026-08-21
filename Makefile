# Top-level Makefile for browser-gt.
#
# Drives both the elisp side (compile, lint) and delegates to the
# extension's own Makefile for the WebExtension builds.
#
# Targets:
#   make                — compile + extension (default)
#   make lint           — package-lint every browser-gt*.el file
#   make checkdoc       — checkdoc every browser-gt*.el file (errors on any warning)
#   make check-declare  — verify declare-function file arguments (errors on any mismatch)
#   make compile        — byte-compile every browser-gt*.el file (errors on warning)
#   make extension      — rebuild Chrome + Firefox extension targets
#                         (delegates to extension/Makefile's default target)
#   make clean          — remove every *.elc file
#   make test           — run ERT tests (no-op until tests/ exists)
#   make check          — compile + lint + checkdoc + check-declare +
#                         test + info
#   make check-ci       — `make check' under every Emacs in
#                         $(CI_EMACS_LIST) (emacs-plus@30 and @31,
#                         matching the GitHub Actions matrix; run
#                         before pushing).  Errors out when either
#                         binary is absent.
#   make info           — rebuild browser-gt.info and dir from README.org
#                         (both are committed artifacts, not cleaned).
#                         Also runs from `default', `check', and `all',
#                         gated by README.org's mtime, so a stale info
#                         cannot slip into a commit.
#   make all            — check + extension
#
# Override the Emacs binary by passing EMACS=path/to/emacs.

EMACS ?= emacs

# Foundational files first so follow-on files can (require 'browser-gt) without
# erroring when compiled in isolation.
EL_FILES = browser-gt.el \
           browser-gt-www.el \
           browser-gt-chatgpt.el \
           browser-gt-youtube.el \
           browser-gt-tab-manager.el \
           browser-gt-babel.el \
           browser-gt-url-handler.el

# Project-local ELPA so the user's personal package directory is not touched
# and CI starts from a clean slate every run.
ELPA_DIR = .elpa

# Dependencies installed into the project-local ELPA before lint/compile.
# `websocket' is the runtime dependency declared in browser-gt.el's
# Package-Requires; `package-lint' is the lint tool itself.  Vertico is
# a *soft* runtime dependency of browser-gt-tab-manager.el — the anchor-
# restore path prefers vertico's internals when they are available and
# degrades gracefully otherwise — so it is NOT installed here.  Byte-
# compile stays warning-free via the `declare-function' / `defvar'
# stubs at the top of that file.
DEPS = websocket package-lint

# Common Emacs invocation header: project-local package-user-dir, MELPA in
# package-archives, package-initialize so installed packages are on load-path.
EMACS_BATCH = $(EMACS) -Q --batch \
  --eval "(setq package-user-dir (expand-file-name \"$(ELPA_DIR)\"))" \
  --eval "(require 'package)" \
  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
  --eval "(package-initialize)"

.PHONY: default lint checkdoc check-declare compile test clean check check-ci extension info all

# Default target: byte-compile the elisp, rebuild the WebExtension
# bundles, and regenerate the Info manual if README.org changed.
# Info regeneration is dependency-gated -- if README.org has not been
# touched since browser-gt.info was last built, this is a no-op.  Lint is
# not included here so the common edit-then-`make' loop stays fast;
# run `make check' or `make all' before committing.
default: compile extension info

$(ELPA_DIR):
	@mkdir -p $@

$(ELPA_DIR)/.installed: | $(ELPA_DIR)
	$(EMACS_BATCH) \
	  --eval "(unless package-archive-contents (package-refresh-contents))" \
	  $(foreach pkg,$(DEPS),--eval "(unless (package-installed-p '$(pkg)) (package-install '$(pkg)))")
	@touch $@

lint: $(ELPA_DIR)/.installed
	$(EMACS_BATCH) \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit $(EL_FILES)

# checkdoc runs in batch via `checkdoc-file', which writes warnings to
# stderr (via `display-warning') but never exits non-zero on its own.
# After each file, peek at the `*Warnings*' buffer to detect whether any
# warning was emitted and exit 1 on the first one so CI fails on
# regressions.  Stderr already carries the human-readable diagnostic;
# no need to re-print it.  `-L .' lets each file `require' its siblings
# during checkdoc's own load.
checkdoc:
	@$(EMACS_BATCH) \
	  -L . \
	  --eval "(require 'checkdoc)" \
	  --eval "(let ((had-issue nil)) \
	            (dolist (f command-line-args-left) \
	              (with-current-buffer (get-buffer-create \"*Warnings*\") (erase-buffer)) \
	              (checkdoc-file f) \
	              (when (> (buffer-size (get-buffer-create \"*Warnings*\")) 0) \
	                (setq had-issue t))) \
	            (when had-issue (kill-emacs 1)))" \
	  $(EL_FILES)

# check-declare verifies the file argument of every `declare-function' form
# by loading the named file and checking that the function is defined there.
# `check-declare-file' returns a list of errors (or nil on success) and
# writes a human-readable report to the `*Check Declarations Warnings*'
# buffer.  We aggregate over all files and exit 1 on any finding so CI
# fails on regressions.  `-L .' lets each file `require' its siblings.
check-declare:
	@$(EMACS_BATCH) \
	  -L . \
	  --eval "(require 'check-declare)" \
	  --eval "(let ((had-issue nil)) \
	            (dolist (f command-line-args-left) \
	              (when (check-declare-file f) \
	                (setq had-issue t))) \
	            (when had-issue \
	              (with-current-buffer (get-buffer-create check-declare-warning-buffer) \
	                (princ (buffer-string))) \
	              (kill-emacs 1)))" \
	  $(EL_FILES)

# Compile each file in a fresh subprocess so a definition leaked by one file
# cannot mask a missing `require' in another.  Treats every byte-compile
# warning as a hard error so CI catches them before commit.  `-L .' puts the
# source tree on the load-path so files compile in order even though they
# (require 'browser-gt) before browser-gt.elc exists.
compile: $(ELPA_DIR)/.installed
	@set -e; \
	for f in $(EL_FILES); do \
	  echo "==> compiling $$f"; \
	  $(EMACS_BATCH) \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    -L . \
	    -f batch-byte-compile $$f; \
	done

# ERT runner.  No-op until tests are added under tests/.  Present so
# `check' has the same target set as the sibling *-gt packages.
test:
	@if ls tests/*-test.el >/dev/null 2>&1; then \
	  $(EMACS_BATCH) \
	    -L . \
	    -L tests \
	    $(foreach f,$(wildcard tests/*-test.el),-l $(f)) \
	    -f ert-run-tests-batch-and-exit; \
	else \
	  echo "no tests/*-test.el files; skipping"; \
	fi

clean:
	rm -f *.elc

# Info manual (multi-file ELPA convention): browser-gt.info and dir both
# live at the package root and are committed.  `make clean' does NOT
# touch them -- they are source-of-truth artifacts consumed by ELPA
# activation.  Regenerate after editing README.org.
INFO_FILE = browser-gt.info
INFO_DIR  = dir

info: $(INFO_FILE) $(INFO_DIR)

# Stage README.org as browser-gt.org so Org's basename-derived output
# filename matches `#+texinfo_filename'.  Without this, Org produces
# README.texi -> browser-gt.info (from @setfilename) and then its
# post-processing looks for README.info and fails.
$(INFO_FILE): README.org
	cp README.org browser-gt.org
	$(EMACS) -Q --batch \
	  --eval "(setq load-prefer-newer t)" \
	  --eval "(require 'ox-texinfo)" \
	  browser-gt.org \
	  -f org-texinfo-export-to-info
	rm -f browser-gt.org browser-gt.texi

$(INFO_DIR): $(INFO_FILE)
	install-info --info-file=$(INFO_FILE) --dir-file=$(INFO_DIR)

# Delegate to the extension's own Makefile.  Its default target builds
# both Chrome and Firefox bundles.
extension:
	$(MAKE) -C extension

check: compile lint checkdoc check-declare test info

# CI-mirror check.  EMACS_30 / EMACS_31 are the Package-Requires floor
# and the latest release, matching the GitHub Actions matrix in
# .github/workflows/package-lint.yml.  Both are mandatory: a skipped
# version reports a pass that CI does not agree with, so `check-ci'
# refuses to run until both are installed.  The default `make check'
# runs under whatever `emacs' resolves to on PATH and cannot prove
# multi-version compatibility.
EMACS_30 ?= /opt/homebrew/opt/emacs-plus@30/bin/emacs
EMACS_31 ?= /opt/homebrew/opt/emacs-plus@31/bin/emacs
CI_EMACS_LIST ?= $(EMACS_30) $(EMACS_31)

# Every binary is verified before the first one runs, so a missing
# install is reported up front rather than after a full pass.
check-ci:
	@missing=""; \
	for e in $(CI_EMACS_LIST); do \
	  [ -x "$$e" ] || missing="$$missing $$e"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "check-ci: required Emacs not executable:$$missing"; \
	  echo "Install both:  brew install emacs-plus@30 emacs-plus@31"; \
	  echo "Or override:   make check-ci CI_EMACS_LIST=\"/path/to/emacs ...\""; \
	  exit 1; \
	fi
	@for e in $(CI_EMACS_LIST); do \
	  echo "==> check-ci under $$e ($$($$e --version | head -1))"; \
	  $(MAKE) EMACS=$$e check || exit 1; \
	done

all: check extension
