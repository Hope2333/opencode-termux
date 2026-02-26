# OpenCode for Termux - local build orchestrator

SHELL := /bin/bash
.DEFAULT_GOAL := help

VER ?= latest
VERS ?=
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
MORE ?=
ODIR ?=
MIX ?= 0

OUTPUT_ROOT := $(if $(ODIR),$(ODIR),$(CURDIR)/packing)

.PHONY: help all runtime stage deb pacman batch clean status steps

help:
	@echo "OpenCode Termux build helper"
	@echo
	@echo "Mainline scope:"
	@echo "  - Local Termux packaging workflow (deb + pacman)"
	@echo "  - armv7 CI prebuild handoff is non-mainline/deferred"
	@echo "  - arm32 adaptation is deferred (tracked outside mainline)"
	@echo
	@echo "Primary commands:"
	@echo "  make all VER=1.2.10 PKG=both"
	@echo "  make all VER=latest PKG=pacman"
	@echo "  make all VER=1.2.10 PKG=both ODIR=~/oct-out"
	@echo "  make all VER=1.2.10 PKG=both ODIR=~/oct-out MIX=1"
	@echo "  make runtime VER=latest"
	@echo "  make stage"
	@echo "  make deb"
	@echo "  make pacman"
	@echo
	@echo "Batch commands:"
	@echo "  make batch VERS='1.2.10 1.2.11 1.2.12' PKG=both"
	@echo "  make batch VERS='1.1.[1-20]' PKG=deb ODIR=~/oct-out"
	@echo "  make batch VERS='1.1.[1-20]' PKG=pacman ODIR=~/oct-out MIX=1"
	@echo
	@echo "Version resolution in tools/produce-local.sh:"
	@echo "  1) explicit version argument"
	@echo "  2) latest npm version if omitted"
	@echo "  3) GitHub release fallback if npm version unavailable"
	@echo
	@echo "Output policy:"
	@echo "  - Default root: ./packing"
	@echo "  - With ODIR: write to ODIR only (do not use ./packing)"
	@echo "  - Default layout: deb/ and pacman/ subfolders"
	@echo "  - MIX=1 or --mix: flatten all artifacts into one directory"
	@echo
	@echo "Workspace policy:"
	@echo "  - Temporary work under project-local ./.work"
	@echo "  - Auto-clean after runtime wrap"
	@echo "  - KEEP_WORK=1 keeps workspace for debugging"
	@echo
	@echo "Debug/introspection:"
	@echo "  make steps"
	@echo "  make status"
	@echo
	@echo "Wrapper CLI (tools/make-opencode):"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both"
	@echo "  ./tools/make-opencode --all --ver latest --pkg pacman"
	@echo "  ./tools/make-opencode --batch --vers '1.2.10 1.2.11' --pkg pacman"
	@echo "  ./tools/make-opencode --batch --vers '1.1.[1-20]' --pkg both --odir ~/oct-out"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both --odir ~/oct-out --mix"

steps:
	@echo "Build steps: clean -> runtime -> stage -> package"
	@echo "Package steps: deb and/or pacman depending on PKG"
	@echo "Output root: $(OUTPUT_ROOT)"
	@echo "Mix(flatten): $(MIX)"

all: clean runtime stage
	@if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb; \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman; \
	else \
		$(MAKE) deb && $(MAKE) pacman; \
	fi

batch:
	@if [ -z "$(VERS)" ]; then \
		echo "Error: VERS is empty. Example: make batch VERS='1.2.10 1.2.11' PKG=both"; \
		exit 1; \
	fi
	@expanded=(); \
	for token in $(VERS); do \
		if [[ "$$token" =~ ^([0-9]+\.[0-9]+)\.\[([0-9]+)-([0-9]+)\]$$ ]]; then \
			base="$${BASH_REMATCH[1]}"; start="$${BASH_REMATCH[2]}"; end="$${BASH_REMATCH[3]}"; \
			for ((i=start; i<=end; i++)); do expanded+=("$$base.$$i"); done; \
		else \
			expanded+=("$$token"); \
		fi; \
	done; \
	for v in "$${expanded[@]}"; do \
		echo "=== Batch build for version $$v ==="; \
		$(MAKE) all VER=$$v PKG=$(PKG) MORE="$(MORE)" PACKAGER_NAME='$(PACKAGER_NAME)' ODIR='$(ODIR)' MIX='$(MIX)' || exit 1; \
	done

runtime:
	@if [ "$(VER)" = "latest" ]; then \
		./tools/produce-local.sh $(MORE); \
	else \
		./tools/produce-local.sh $(VER) $(MORE); \
	fi

stage:
	./scripts/build.sh

deb:
	rm -rf packaging/dpkg/work
	MAINTAINER='$(PACKAGER_NAME)' ./scripts/package/package_deb.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packaging/dpkg/opencode_*.deb "$(OUTPUT_ROOT)/" 2>/dev/null || true; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/deb" && cp -f packaging/dpkg/opencode_*.deb "$(OUTPUT_ROOT)/deb/" 2>/dev/null || true; \
	fi

pacman:
	rm -rf packaging/pacman/pkg packaging/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' ./scripts/package/package_pacman.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packaging/pacman/opencode-*.pkg.* "$(OUTPUT_ROOT)/" 2>/dev/null || true; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/pacman" && cp -f packaging/pacman/opencode-*.pkg.* "$(OUTPUT_ROOT)/pacman/" 2>/dev/null || true; \
	fi

status:
	@echo "Staged runtime:"; \
	if [ -x artifacts/staged/prefix/lib/opencode/runtime/opencode ]; then \
		artifacts/staged/prefix/lib/opencode/runtime/opencode --version; \
	else \
		echo "<missing>"; \
	fi

clean:
	rm -rf artifacts/staged packaging/dpkg/work packaging/pacman/pkg packaging/pacman/src
	@echo "Clean complete"
