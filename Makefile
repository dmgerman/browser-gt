# Top-level Makefile for browsel.
#
# Drives both the elisp side (compile, lint) and delegates to the
# extension's own Makefile for the WebExtension builds.
#
# Targets:
#   make                — compile + extension (default)
#   make lint           — package-lint every browsel*.el file
#   make checkdoc       — checkdoc every browsel*.el file (errors on any warning)
#   make check-declare  — verify declare-function file arguments (errors on any mismatch)
#   make compile        — byte-compile every browsel*.el file (errors on warning)
#   make extension      — rebuild Chrome + Firefox extension targets
#                         (delegates to extension/Makefile's default target)
#   make clean          — remove every *.elc file
#   make check          — compile + lint + checkdoc + check-declare
#   make check-ci       — same as `make check' but under $(CI_EMACS)
#                         (defaults to emacs-plus@30, matching the
#                         GitHub Actions matrix; run before pushing)
#   make info           — rebuild browsel.info and dir from README.org
#                         (both are committed artifacts, not cleaned)
#   make all            — check + extension
#
# Override the Emacs binary by passing EMACS=path/to/emacs.

EMACS ?= emacs

# Foundational files first so follow-on files can (require 'browsel) without
# erroring when compiled in isolation.
EL_FILES = browsel.el \
           browsel-www.el \
           browsel-chatgpt.el \
           browsel-youtube.el \
           browsel-tab-manager.el \
           browsel-babel.el \
           browsel-url-handler.el

# Project-local ELPA so the user's personal package directory is not touched
# and CI starts from a clean slate every run.
ELPA_DIR = .elpa

# Dependencies installed into the project-local ELPA before lint/compile.
# `websocket' is the runtime dependency declared in browsel.el's
# Package-Requires; `package-lint' is the lint tool itself.  Vertico is
# a *soft* runtime dependency of browsel-tab-manager.el — the anchor-
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

.PHONY: default lint checkdoc check-declare compile clean check check-ci extension info all

# Default target: byte-compile the elisp and rebuild the WebExtension
# bundles.  Lint is not included here so the common edit-then-`make' loop
# stays fast; run `make check' or `make all' before committing.
default: compile extension

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
# (require 'browsel) before browsel.elc exists.
compile: $(ELPA_DIR)/.installed
	@set -e; \
	for f in $(EL_FILES); do \
	  echo "==> compiling $$f"; \
	  $(EMACS_BATCH) \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    -L . \
	    -f batch-byte-compile $$f; \
	done

clean:
	rm -f *.elc

# Info manual (multi-file ELPA convention): browsel.info and dir both
# live at the package root and are committed.  `make clean' does NOT
# touch them -- they are source-of-truth artifacts consumed by ELPA
# activation.  Regenerate after editing README.org.
INFO_FILE = browsel.info
INFO_DIR  = dir

info: $(INFO_FILE) $(INFO_DIR)

# Stage README.org as browsel.org so Org's basename-derived output
# filename matches `#+texinfo_filename'.  Without this, Org produces
# README.texi -> browsel.info (from @setfilename) and then its
# post-processing looks for README.info and fails.
$(INFO_FILE): README.org
	cp README.org browsel.org
	$(EMACS) -Q --batch \
	  --eval "(setq load-prefer-newer t)" \
	  --eval "(require 'ox-texinfo)" \
	  browsel.org \
	  -f org-texinfo-export-to-info
	rm -f browsel.org browsel.texi

$(INFO_DIR): $(INFO_FILE)
	install-info --info-file=$(INFO_FILE) --dir-file=$(INFO_DIR)

# Delegate to the extension's own Makefile.  Its default target builds
# both Chrome and Firefox bundles.
extension:
	$(MAKE) -C extension

check: compile lint checkdoc check-declare

# CI-mirror check: force the same Emacs version the GitHub Actions
# matrix pins.  The default `make check' runs under whatever `emacs'
# resolves to on the developer's PATH, which is typically the
# latest release and has looser checkdoc / package-lint rules than
# the version CI uses; that lets docstring drift slip through to a
# CI failure.  Set CI_EMACS below to the absolute path of the
# CI-matching binary and use `make check-ci' before pushing.
CI_EMACS ?= /opt/homebrew/opt/emacs-plus@30/bin/emacs

check-ci:
	@if [ ! -x "$(CI_EMACS)" ]; then \
	  echo "CI_EMACS not executable: $(CI_EMACS)"; \
	  echo "Install with: brew install emacs-plus@30"; \
	  echo "Or override: make check-ci CI_EMACS=/path/to/emacs"; \
	  exit 1; \
	fi
	$(MAKE) EMACS=$(CI_EMACS) check

all: check extension
