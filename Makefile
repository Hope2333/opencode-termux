# OpenCode for Termux - local build orchestrator

SHELL := /data/data/com.termux/files/usr/bin/bash
.DEFAULT_GOAL := help

VER ?= latest
VERS ?=
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
MORE ?=
ODIR ?=
MIX ?= 0

# Release upload target variables
TAG ?= Push$(shell date +%y%m%d)
REPO ?= Hope2333/opencode-termux
# Release staging dir: /tmp is not app-writable on Termux; honor TMPDIR
RELEASE_DIR ?= $(if $(TMPDIR),$(TMPDIR),/tmp)/oc-release-$(TAG)
NATIVE ?=
VER_IS_SET = $(filter-out file default,$(origin VER))
NATIVE_VER = $(if $(VER_IS_SET),$(VER),$(VERS))
NATIVE_DIR = artifacts/transplant/$(NATIVE_VER)

OUTPUT_ROOT := $(if $(ODIR),$(ODIR),$(CURDIR)/packing)

.PHONY: help all runtime stage deb pacman deb-native pacman-native native-pkg batch clean status steps matrix selfcheck release-upload test transplant-check transplant-upx

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
	@echo "Native provider commands (experimental headless line):"
	@echo "  make transplant VER=1.18.21       # build native binary first"
	@echo "  make transplant-upx VER=1.18.21   # OPTIONAL: UPX-pack the revived product (last step!)""
	@echo "  make deb-native VER=1.18.21       # opencode .deb provider (native mainline)"
	@echo "  make pacman-native VER=1.18.21    # opencode pacman provider (native mainline)"
	@echo "  make native-pkg VER=1.18.21       # both native packages"
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
	@echo "  make selfcheck"
	@echo "  make matrix VERS='1.2.9 1.2.10' ODIR=~/oct-out"
	@echo
	@echo "Wrapper CLI (tools/make-opencode):"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both"
	@echo "  ./tools/make-opencode --all --ver latest --pkg pacman"
	@echo "  ./tools/make-opencode --batch --vers '1.2.10 1.2.11' --pkg pacman"
	@echo "  ./tools/make-opencode --batch --vers '1.1.[1-20]' --pkg both --odir ~/oct-out"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both --odir ~/oct-out --mix"
	@echo "  TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258 ./tools/upgrade-matrix.sh"

steps:
	@echo "Build steps: clean -> runtime -> stage -> package"
	@echo "Package steps: deb and/or pacman depending on PKG"
	@echo "Output root: $(OUTPUT_ROOT)"
	@echo "Mix(flatten): $(MIX)"

all: clean runtime stage
	@V="$(VER)"; \
	if [ "$$V" = "latest" ]; then V=""; fi; \
	if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb VERSION=$$V; \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman VERSION=$$V; \
	else \
		$(MAKE) deb VERSION=$$V && $(MAKE) pacman VERSION=$$V; \
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
	rm -rf packing/dpkg/work
	MAINTAINER='$(PACKAGER_NAME)' ./scripts/package/package_deb.sh
	@if [ "$(OUTPUT_ROOT)" != "$(CURDIR)/packing" ]; then \
		if [ "$(MIX)" = "1" ]; then \
			mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/dpkg/opencode-glibc_$(VER)_aarch64.deb "$(OUTPUT_ROOT)/"; \
		else \
			mkdir -p "$(OUTPUT_ROOT)/deb" && cp -f packing/dpkg/opencode-glibc_$(VER)_aarch64.deb "$(OUTPUT_ROOT)/deb/"; \
		fi; \
	fi

pacman:
	rm -rf packing/pacman/pkg packing/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' ./scripts/package/package_pacman.sh
	@if [ "$(OUTPUT_ROOT)" != "$(CURDIR)/packing" ]; then \
		if [ "$(MIX)" = "1" ]; then \
			mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/pacman/opencode-glibc-$(VER)-*.pkg.* "$(OUTPUT_ROOT)/"; \
		else \
			mkdir -p "$(OUTPUT_ROOT)/pacman" && cp -f packing/pacman/opencode-glibc-$(VER)-*.pkg.* "$(OUTPUT_ROOT)/pacman/"; \
		fi; \
	fi

# Native provider packaging (transplant revival line, stable mainline since 27/28).
# Provides the same `opencode` command as the glibc wrapper packages; the two
# providers conflict (installing one replaces the other). The glibc wrapper line is now the appendix (renamed opencode-glibc); native is the stable mainline.
deb-native:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make deb-native VER=1.18.21"; \
		exit 1; \
	fi
	rm -rf packing/dpkg-native/work
	MAINTAINER='$(PACKAGER_NAME)' VERSION='$(VER)' ./scripts/package/package_deb_native.sh
	@if [ "$(OUTPUT_ROOT)" != "$(CURDIR)/packing" ]; then \
		if [ "$(MIX)" = "1" ]; then \
			mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/dpkg-native/opencode_[0-9]*.deb "$(OUTPUT_ROOT)/"; \
		else \
			mkdir -p "$(OUTPUT_ROOT)/deb" && cp -f packing/dpkg-native/opencode_[0-9]*.deb "$(OUTPUT_ROOT)/deb/"; \
		fi; \
	fi

pacman-native:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make pacman-native VER=1.18.21"; \
		exit 1; \
	fi
	rm -rf packing/pacman/pkg packing/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' VERSION='$(VER)' ./scripts/package/package_pacman_native.sh
	@if [ "$(OUTPUT_ROOT)" != "$(CURDIR)/packing" ]; then \
		if [ "$(MIX)" = "1" ]; then \
			mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/pacman/opencode-[0-9]*.pkg.* "$(OUTPUT_ROOT)/"; \
		else \
			mkdir -p "$(OUTPUT_ROOT)/pacman" && cp -f packing/pacman/opencode-[0-9]*.pkg.* "$(OUTPUT_ROOT)/pacman/"; \
		fi; \
	fi

native-pkg: deb-native pacman-native

status:
	@echo "Staged runtime:"; \
	if [ -x artifacts/staged/prefix/lib/opencode/runtime/opencode ]; then \
		artifacts/staged/prefix/lib/opencode/runtime/opencode --version; \
	else \
		echo "<missing>"; \
	fi

selfcheck:
	./tools/plugin-selfcheck.sh

# Run the shell unit test suite (bats). Fetches a pinned bats-core on demand.
test:
	./tests/run.sh

matrix:
	@VERS='$(VERS)' ODIR='$(ODIR)' TARGET_HOST='$(TARGET_HOST)' TARGET_PORT='$(TARGET_PORT)' TARGET_USER='$(TARGET_USER)' ./tools/upgrade-matrix.sh

# transplant: build native android binary via transplant pipeline
# (tools/transplant/transplant.py, zero-glibc native-android path)
# Output: artifacts/transplant/<ver>/opencode-native + report.json
transplant:
	@if [ -z "$(VER)" ]; then \
		echo "Error: VER is empty. Example: make transplant VER=1.3.13"; \
		exit 1; \
	fi
	@echo "==> transplant VER=$(VER)"
	python3 tools/transplant/transplant.py all --ver $(VER) --tgz $${TMPDIR:-/tmp}/$$(npm pack opencode-linux-arm64@$(VER) --pack-destination $${TMPDIR:-/tmp} 2>/dev/null | tail -n1)
	@# W7c2: swap bionic libopentui.so into the grafted binary so OpenTUI renders
	@# on Android/bionic. WARN-skip when the bionic build is absent.
	@if [ -f artifacts/transplant/opentui-bionic/libopentui.so ]; then \
		echo "==> swapping bionic libopentui (tools/transplant/swap_tui.py)"; \
		strip_bin=$$(command -v llvm-strip || command -v strip); \
		cp artifacts/transplant/opentui-bionic/libopentui.so $${TMPDIR:-/tmp}/libopentui-strip.so; \
		$$strip_bin --strip-debug $${TMPDIR:-/tmp}/libopentui-strip.so; \
		python3 tools/transplant/swap_tui.py \
			--binary $(NATIVE_DIR)/opencode-native-revived \
			--tui-lib $${TMPDIR:-/tmp}/libopentui-strip.so \
			--out $(NATIVE_DIR)/opencode-native-tui; \
	else \
		echo "WARN: artifacts/transplant/opentui-bionic/libopentui.so not found; skipping TUI swap"; \
	fi
transplant: VER?= latest

# transplant-upx: OPTIONAL final step — UPX-pack an already-revived native product.
# MUST run AFTER transplant (swap_tui.py / revive_patch break on a packed ELF).
# Requires a revived product in $(NATIVE_DIR); override source with SRC=<path>.
# Produces opencode-native-<ver>-upx, KEEPS the original, writes upx-report-<ver>.json
# (both sha256 + ratio). WARN-skips when upx is missing.
transplant-upx:
	@if [ -z "$(VER)" ]; then \
		echo "Error: VER is empty. Example: make transplant-upx VER=1.18.21"; \
		exit 1; \
	fi
	@if ! command -v upx >/dev/null 2>&1; then \
		echo "WARN: upx not found; skipping UPX compression (transplant-upx skipped)"; \
		exit 0; \
	fi
	@SRC="$(SRC)"; \
	if [ -z "$$SRC" ]; then \
		if [ -f $(NATIVE_DIR)/opencode-native-tui ]; then SRC=$(NATIVE_DIR)/opencode-native-tui; \
		elif [ -f $(NATIVE_DIR)/opencode-native-revived ]; then SRC=$(NATIVE_DIR)/opencode-native-revived; \
		elif [ -f $(NATIVE_DIR)/opencode-native ]; then SRC=$(NATIVE_DIR)/opencode-native; \
		else \
			echo "Error: no revived product in $(NATIVE_DIR); run 'make transplant VER=$(VER)' first"; \
			exit 1; \
		fi; \
	fi; \
	echo "==> transplant-upx VER=$(VER) source=$$SRC"; \
	OUT=$(NATIVE_DIR)/opencode-native-$(VER)-upx; \
	cp -p "$$SRC" "$$OUT"; \
	upx $(UPX_OPTS) --no-color "$$OUT"; \
	RC=$$?; \
	if [ $$RC -ne 0 ]; then echo "Error: upx failed rc=$$RC"; rm -f "$$OUT"; exit $$RC; fi; \
	SRC_SHA=$$(sha256sum "$$SRC" | cut -d' ' -f1); \
	OUT_SHA=$$(sha256sum "$$OUT" | cut -d' ' -f1); \
	ORIG_SIZE=$$(stat -c%s "$$SRC"); \
	UPX_SIZE=$$(stat -c%s "$$OUT"); \
	RATIO=$$(awk "BEGIN{printf \"%.2f\", $$UPX_SIZE*100/$$ORIG_SIZE}"); \
	echo "original : $$SRC_SHA  $$ORIG_SIZE B"; \
	echo "upx      : $$OUT_SHA  $$UPX_SIZE B ($$RATIO%)"; \
	python3 -c 'import json,sys; src,out,ss,os_,osz,usz,ratio=sys.argv[1:]; ver=out.split("opencode-native-",1)[1].split("-upx",1)[0]; d=out.rfind("/"); rep={"version":ver,"source":src,"source_sha256":ss,"source_size":int(osz),"upx_binary":out,"upx_sha256":os_,"upx_size":int(usz),"ratio_pct":float(ratio),"note":"packed MUST be the final pipeline step; swap_tui.py/revive_patch break on packed ELF"}; open(out[:d]+"/upx-report-"+ver+".json","w").write(json.dumps(rep,indent=2)); print("wrote upx-report-"+ver+".json")' "$$SRC" "$$OUT" "$$SRC_SHA" "$$OUT_SHA" "$$ORIG_SIZE" "$$UPX_SIZE" "$$RATIO" || exit 1; \
	echo "==> transplant-upx done: original kept at $$SRC; upx at $$OUT"
transplant-upx: VER?= latest
transplant-upx: UPX_OPTS?= --best

# transplant-check: golden regression across layout families
# (tests/transplant/test_golden.py; fixtures pre-downloaded by scripts/fetch-fixtures.sh)
transplant-check:
	python3 tests/transplant/test_golden.py --fixtures-dir tests/transplant/fixtures/tgz

clean:
	rm -rf artifacts/staged packing/dpkg/work packing/pacman/pkg packing/pacman/src
	@echo "Clean complete"

# NOTE: release-upload will gain a transplant prerequisite (native-android
# binary per version) — actual ordering wired in todo 18.
# ── Release upload (not shown in help) ──────────────────────────────────
# Automates: batch build → upload all assets to existing or new release tag.
# Usage:
#   make release-upload TAG=Push260522 VERS='1.15.[1-7]'
#   make release-upload TAG=Push260522 VERS='1.15.[1-7]' PKG=deb
#   make release-upload VERS='1.2.[10-20]' REPO=Hope2333/opencode-termux
#	 make release-upload TAG=Push260901 NATIVE=1 VER=1.3.13   # + native assets
#	                                                           #   (raw binary + report + watcher + opencode deb/pacman providers)
#	 make release-upload TAG=Stable260901 NATIVE=STABLE VER=1.18.21
#	                                                           #   native assets as FORMAL release (no --prerelease flag;
#	                                                           #   stable-mainline notes per 27/28 switch)
#
# Defaults:
#   TAG     = Push<YYMMDD> (auto-generated)
#   VERS    = (required for wrapper batch; may be omitted when NATIVE=1 + VER)
#   PKG     = both
#   REPO    = Hope2333/opencode-termux
#   NATIVE  = (empty) — set to 1 to also upload native-android transplant
#             assets (opencode-native + report.json + watcher pkg) for a
#             single version (VER, or VERS when it is a single version).
#             Fails fast (exit 1) when artifacts/transplant/<ver> is missing
#             or empty (anti-empty-release).
#             NATIVE=STABLE uploads the same asset set as a FORMAL release
#             (gh release create without --prerelease, stable-mainline notes)
#             per the 27/28 mainline switch; NATIVE=1 keeps the legacy path.
release-upload:
	@if [ -z "$(VERS)" ] && [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VERS is required. Example: make release-upload VERS='1.15.[1-7]' TAG=Push260522"; \
		exit 1; \
	fi
	@if [ "$(NATIVE)" = "1" ] || [ "$(NATIVE)" = "STABLE" ]; then \
		if [ ! -f "$(NATIVE_DIR)/opencode-native-revived" ] || [ -z "$$(ls -A $(NATIVE_DIR) 2>/dev/null)" ]; then \
			echo "Error: NATIVE=$(NATIVE) but $(NATIVE_DIR) is missing or empty (anti-empty-release)" >&2; \
			exit 1; \
		fi; \
		echo "NATIVE assets found: $(NATIVE_DIR)/opencode-native-revived + report.json + watcher pkg"; \
	fi
	@echo "=== Release upload: TAG=$(TAG) VERS=$(VERS) VER=$(VER) PKG=$(PKG) REPO=$(REPO) NATIVE=$(NATIVE) ==="
	@if [ -n "$(VERS)" ]; then \
		$(MAKE) batch VERS='$(VERS)' PKG='$(PKG)' ODIR='$(RELEASE_DIR)' MIX=1; \
	fi
	@echo "=== Uploading to release $(TAG) ==="; \
	upload_failed=0; \
	if ! gh release view "$(TAG)" --repo "$(REPO)" >/dev/null 2>&1; then \
		echo "Creating release $(TAG)..."; \
		if [ "$(NATIVE)" = "STABLE" ]; then \
			gh release create "$(TAG)" --repo "$(REPO)" --title "$(TAG)" --notes "OpenCode for Termux. Mainline (stable since 27/28): native bionic line - opencode-<ver>-aarch64-android-native / opencode_<ver>_aarch64.deb / opencode-<ver>-*-aarch64.pkg.* - zero-glibc, full TUI, Android API>=28. Appendix (legacy): glibc wrapper packages opencode-glibc_<ver>_aarch64.deb / opencode-glibc-<ver>-aarch64.pkg.tar.*." 2>&1 || exit 1; \
		else \
			gh release create "$(TAG)" --repo "$(REPO)" --title "$(TAG)" --notes "Dual-track OpenCode for Termux. Track 1 (glibc appendix, renamed opencode-glibc): glibc wrapper packages opencode-glibc_<ver>_aarch64.deb / opencode-glibc-<ver>-aarch64.pkg.tar.* - full TUI. Track 2 (native, stable mainline since 27/28): opencode_<ver>_aarch64.deb / opencode-<ver>-*-aarch64.pkg.* / *-android-native assets - zero-glibc, full TUI (bionic libopentui.so, W10a 5/5), Android API>=28." 2>&1 || exit 1; \
		fi; \
	else \
		echo "Release $(TAG) exists; rebinding tag to HEAD via gh api (HTTPS, SSH 22 blocked)..."; \
		gh api -X PATCH "repos/$(REPO)/git/refs/tags/$(TAG)" -f sha="$$(git rev-parse HEAD)" >/dev/null 2>&1 || echo "  (tag rebind skipped: API refused or already current)"; \
	fi; \
	for f in $(RELEASE_DIR)/opencode-glibc_*.deb $(RELEASE_DIR)/opencode-glibc-*.pkg.*; do \
		if [ -f "$$f" ]; then \
			echo "  uploading $$(basename $$f)..."; \
			if ! gh release upload "$(TAG)" "$$f" --repo "$(REPO)" --clobber 2>&1; then upload_failed=1; fi; \
		fi; \
	done; \
	mkdir -p "$(RELEASE_DIR)"; \
	echo "--- Dual-track asset naming ---"; \
	echo "    glibc wrapper line (appendix, renamed opencode-glibc): opencode-glibc_<ver>_aarch64.deb / opencode-glibc-<ver>-aarch64.pkg.tar.*"; \
	echo "    native line (stable mainline since 27/28): opencode-<ver>-aarch64-android-native / opencode_<ver>_aarch64.deb / opencode-<ver>-*-aarch64.pkg.* / opencode-<ver>-report.json / opencode-<ver>-watcher.tar.gz"; \
	if [ "$(NATIVE)" = "1" ] || [ "$(NATIVE)" = "STABLE" ]; then \
		cp "$(NATIVE_DIR)/opencode-native-revived" "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-aarch64-android-native"; \
		cp "$(NATIVE_DIR)/report.json" "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-report.json"; \
		tar czf "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-watcher.tar.gz" -C tools/watcher watcher shim.js install.sh; \
		echo "=== Building native provider packages (opencode) ==="; \
		MAINTAINER='$(PACKAGER_NAME)' VERSION='$(NATIVE_VER)' ./scripts/package/package_deb_native.sh; \
		PACKAGER_NAME='$(PACKAGER_NAME)' VERSION='$(NATIVE_VER)' ./scripts/package/package_pacman_native.sh; \
		cp packing/dpkg-native/opencode_[0-9]*.deb "$(RELEASE_DIR)/"; \
		cp packing/pacman/opencode-[0-9]*.pkg.* "$(RELEASE_DIR)/"; \
		for f in "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-aarch64-android-native" "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-report.json" "$(RELEASE_DIR)/opencode-$(NATIVE_VER)-watcher.tar.gz" $(RELEASE_DIR)/opencode_[0-9]*.deb $(RELEASE_DIR)/opencode-[0-9]*.pkg.*; do \
			echo "  uploading $$(basename $$f)..."; \
			if ! gh release upload "$(TAG)" "$$f" --repo "$(REPO)" --clobber 2>&1; then upload_failed=1; fi; \
		done; \
	fi; \
	if [ "$$upload_failed" -ne 0 ]; then echo "Error: one or more release assets failed to upload" >&2; exit 1; fi; \
	echo "=== Done: https://github.com/$(REPO)/releases/tag/$(TAG) ==="
