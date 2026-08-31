# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

EXTENSION_NAME ?= browser-gt-extension
VERSION        := $(shell python3 -c 'import json; print(json.load(open("config.json"))["extension"]["version"])')

# ── Build targets and directories ────────────────────────────────────────────
#
# Each browser target gets its own loadable directory under build/.
# `make` with no arguments builds every known target.
#
#   make            same as `make all`
#   make all        build every known target
#   make chrome     materialise build/chrome/
#   make firefox    materialise build/firefox/
#   make package    zip build/<TARGET>/ (controlled by TARGET=... variable)
#
# Sources are organised as:
#   src/              JS shared between all targets
#   html/             HTML shared between all targets
#   icons/            icons shared between all targets
#   targets/<name>/   per-target overlays (background script, eval impl,
#                     anything specific to that runtime)
#
# A per-target build copies the shared tree, then overlays
# targets/<name>/ on top, then generates manifest.json from
# config.json + config.extensionTargets[<name>].

TARGET           ?= chrome
KNOWN_TARGETS    := chrome firefox

BUILD_DIR        ?= build/$(TARGET)
DIST_DIR         ?= ../dist
ZIP              := $(DIST_DIR)/$(EXTENSION_NAME)-$(TARGET)-$(VERSION).zip
BUILD_ABS        := $(abspath $(BUILD_DIR))
MANIFEST_BUILDER := scripts/build-manifest.py

# Shared sources copied verbatim into every build.  manifest.json is
# generated and is NOT listed here.
SHARED_FILES := config.json \
                src/core.js \
                src/ws-client.js \
                src/identity.js \
                src/focus-tracker.js \
                src/handlers.js \
                src/log-stamp.js \
                src/stale-tab.js \
                src/payload.js \
                src/consent.js \
                src/popup.js \
                src/options.js \
                src/content.js \
                src/content-chatgpt.js \
                html/popup.html \
                html/options.html \
                icons/icon16.png \
                icons/icon48.png \
                icons/icon128.png \
                icons/icon-red-16.png \
                icons/icon-red-48.png \
                icons/icon-red-128.png

# Per-target overlay files.  Discovered at build time by `find`
# under targets/$(TARGET)/, so adding a new file in a target tree
# requires no Makefile edit.

.PHONY: default all chrome firefox build package lint clean help bump

# `make` with no arguments builds every known target.
default: all

all: $(KNOWN_TARGETS)

chrome:
	@$(MAKE) --no-print-directory TARGET=chrome build

firefox:
	@$(MAKE) --no-print-directory TARGET=firefox build

# `build` is the worker target; users normally invoke `make`,
# `make chrome`, or `make firefox` rather than calling it directly.
build: $(BUILD_DIR)/manifest.json

help:
	@echo "Targets:"
	@echo "  make                same as 'make all'"
	@echo "  make all            build every known target ($(KNOWN_TARGETS))"
	@echo "  make chrome         materialise build/chrome/"
	@echo "  make firefox        materialise build/firefox/"
	@echo "  make package        produce $(DIST_DIR)/$(EXTENSION_NAME)-<TARGET>-<VERSION>.zip"
	@echo "                      (set TARGET=firefox for the Firefox variant)"
	@echo "  make lint           validate config.json and check source files exist"
	@echo "  make clean          remove build/ and $(DIST_DIR)/"
	@echo "  make bump VERSION=X.Y[.Z]"
	@echo "                      update browser-gt.el + config.json in lockstep"

# ── Source-side checks (no build artefacts) ─────────────────────────────────

lint:
	@echo "validating config.json"
	@python3 -c 'import json; json.load(open("config.json"))' \
	  || { echo "config.json is not valid JSON"; exit 1; }
	@for f in $(SHARED_FILES); do \
	  if [ ! -f "$$f" ]; then echo "missing shared source file: $$f"; exit 1; fi; \
	done
	@for t in $(KNOWN_TARGETS); do \
	  if [ ! -d "targets/$$t" ]; then \
	    echo "warning: targets/$$t/ does not exist; skipping checks"; \
	    continue; \
	  fi; \
	done
	@echo "OK"

# ── Build the loadable directory for $(TARGET) ──────────────────────────────

$(BUILD_DIR)/manifest.json: lint config.json $(MANIFEST_BUILDER) $(SHARED_FILES)
	@case " $(KNOWN_TARGETS) " in *" $(TARGET) "*) ;; \
	  *) echo "unknown TARGET=$(TARGET); known: $(KNOWN_TARGETS)"; exit 1 ;; esac
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@echo "copying shared sources into $(BUILD_DIR)/"
	@for f in $(SHARED_FILES); do \
	  mkdir -p "$(BUILD_DIR)/$$(dirname $$f)"; \
	  cp "$$f" "$(BUILD_DIR)/$$f"; \
	done
	@if [ -d "targets/$(TARGET)" ]; then \
	  echo "overlaying targets/$(TARGET)/ into $(BUILD_DIR)/"; \
	  cd targets/$(TARGET) && find . -type f -print0 | while IFS= read -r -d '' f; do \
	    rel="$${f#./}"; \
	    mkdir -p "$(BUILD_ABS)/$$(dirname $$rel)"; \
	    cp "$$f" "$(BUILD_ABS)/$$rel"; \
	  done; \
	else \
	  echo "warning: targets/$(TARGET)/ does not exist (no overlay applied)"; \
	fi
	@python3 $(MANIFEST_BUILDER) --target $(TARGET) $(BUILD_DIR)/manifest.json
	@python3 -c 'import json; json.load(open("$(BUILD_DIR)/manifest.json"))' \
	  || { echo "generated manifest is not valid JSON"; exit 1; }
	@echo "checking that every imported JS module resolves inside $(BUILD_DIR)/"
	@cd $(BUILD_DIR) && for f in $$(find src -name '*.js'); do \
	  for imp in $$(grep -oE 'from[[:space:]]*"\./[^"]+\.js"' "$$f" \
	                  | sed -E 's/.*"\.\/([^"]+)"/\1/'); do \
	    dir="$$(dirname $$f)"; \
	    if [ ! -f "$$dir/$$imp" ]; then \
	      echo "$$f imports $$imp but $$dir/$$imp does not exist"; exit 1; \
	    fi; \
	  done; \
	done
	@echo "build OK -> $(BUILD_ABS)"

# ── Package and clean ────────────────────────────────────────────────────────

$(DIST_DIR):
	mkdir -p $(DIST_DIR)

package: build $(DIST_DIR)
	@echo "building $(ZIP)"
	@rm -f $(ZIP)
	@cd $(BUILD_DIR) && zip -r -q $(abspath $(ZIP)) .
	@echo "wrote $(ZIP)"

clean:
	rm -rf build $(DIST_DIR)

# ── Version bump ─────────────────────────────────────────────────────────────
#
# `browser-gt-version' in ../browser-gt.el and `extension.version' in
# config.json must be the same string (CLIENT_HELLO is strict on
# exact-match).  `make bump VERSION=X.Y[.Z]' rewrites both in place.
# Rebuild afterwards (`make' or `make chrome'/`make firefox') so the
# bumped version reaches manifest.json.

bump:
	@if [ -z "$(VERSION)" ]; then \
	  echo 'usage: make bump VERSION=X.Y[.Z]'; exit 1; \
	fi
	@python3 scripts/bump-version.py "$(VERSION)"
