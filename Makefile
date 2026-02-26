# OpenCode for Termux - local build orchestrator

SHELL := /bin/bash
.DEFAULT_GOAL := help

VER ?= latest
VERS ?=
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
MORE ?=
ODIR ?=

.PHONY: help all runtime stage deb pacman batch clean status

help:
	@echo "OpenCode Termux build helper"
	@echo
	@echo "Recommended:"
	@echo "  make all VER=1.2.10 PKG=both"
	@echo "  make all VER=latest PKG=pacman"
	@echo "  make batch VERS='1.2.10 1.2.11 1.2.12' PKG=both"
	@echo "  make batch VERS='1.1.[1-20]' PKG=deb ODIR=~/oct-out"
	@echo "  make runtime VER=latest"
	@echo
	@echo "Wrapper-style syntax (supported by tools/make-opencode):"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both"
	@echo "  ./tools/make-opencode --batch --vers '1.2.10 1.2.11' --pkg pacman"
	@echo "  ./tools/make-opencode --batch --vers '1.1.[1-20]' --pkg both --odir ~/oct-out"

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
		$(MAKE) all VER=$$v PKG=$(PKG) MORE="$(MORE)" PACKAGER_NAME='$(PACKAGER_NAME)' ODIR='$(ODIR)' || exit 1; \
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
	@if [ -n "$(ODIR)" ]; then mkdir -p "$(ODIR)" && cp -f packaging/dpkg/opencode_*.deb "$(ODIR)/" 2>/dev/null || true; fi

pacman:
	rm -rf packaging/pacman/pkg packaging/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' ./scripts/package/package_pacman.sh
	@if [ -n "$(ODIR)" ]; then mkdir -p "$(ODIR)" && cp -f packaging/pacman/opencode-*.pkg.* "$(ODIR)/" 2>/dev/null || true; fi

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
