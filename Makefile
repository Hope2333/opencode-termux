# OpenCode for Termux - local build orchestrator

SHELL := /bin/bash
.DEFAULT_GOAL := help

VER ?= latest
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
MORE ?=

.PHONY: help all runtime stage deb pacman clean status

help:
	@echo "OpenCode Termux build helper"
	@echo
	@echo "Recommended:"
	@echo "  make all VER=1.2.10 PKG=both"
	@echo "  make all VER=latest PKG=pacman"
	@echo "  make runtime VER=latest"
	@echo "  make stage"
	@echo "  make deb"
	@echo "  make pacman"
	@echo
	@echo "Wrapper-style syntax (supported by tools/make-opencode):"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both"

all: clean runtime stage
	@if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb; \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman; \
	else \
		$(MAKE) deb && $(MAKE) pacman; \
	fi

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

pacman:
	rm -rf packaging/pacman/pkg packaging/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' ./scripts/package/package_pacman.sh

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
