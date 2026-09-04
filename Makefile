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

.PHONY: help all runtime stage deb pacman deb-native pacman-native native-pkg batch clean status steps matrix selfcheck release-upload test transplant transplant-predict transplant-check transplant-upx seccomp-harden family-glibc family-native family-compressed range-build fleet-upx fleet-status sha-stage push-stage clean-artifacts

help:
	@echo "OpenCode Termux build helper"
	@echo
	@echo "━━━ [Families] Single-version per-family builds ━━━"
	@echo "  make family-glibc VER=1.18.21       # glibc wrapper (deb + pacman)"
	@echo "  make family-native VER=1.18.21      # transplant + seccomp-harden + native pkgs"
	@echo "  make family-compressed VER=1.18.21  # UPX-compressed variant (local)"
	@echo
	@echo "━━━ [Range Batch] Multi-version builds ━━━"
	@echo "  make range-build FROM=1.18.15 TO=1.18.27 LINES=glibc,native"
	@echo "    Features: continue-on-fail, npm retry ≤3, disk guardrail, SHA256SUMS"
	@echo
	@echo "━━━ [Fleet] Distributed UPX ━━━"
	@echo "  python3 tools/fleet-push.py        # 推荐: 节点常驻 release 自源(断点续传)"
	@echo "  make fleet-upx VER=1.18.21 NODES=\"miao@host1 miao@host2\"   # 旧法: 本机分发"
	@echo "  make fleet-status                 # probe nodes"
	@echo
	@echo "━━━ [Release Staging] ━━━"
	@echo "  make sha-stage                    # regenerate SHA256SUMS-prebatch"
	@echo "  make push-stage TAG=Push260903 BATCH=prebatch  # dry-run upload"
	@echo "    Set PUSH=1 to actually execute"
	@echo
	@echo "━━━ [Legacy] Per-target builds ━━━"
	@echo "  Glibc: make all VER=1.2.10 PKG=both | make runtime | make stage | make deb | make pacman"
	@echo "  Native: make transplant VER=1.18.21 | make deb-native | make pacman-native | make native-pkg"
	@echo "  Compressed: make transplant-upx VER=1.18.21"
	@echo
	@echo "━━━ [Batch/Matrix] ━━━"
	@echo "  make batch VERS='1.2.10 1.2.11' PKG=both"
	@echo "  make matrix VERS='1.2.9 1.2.10' TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258"
	@echo
	@echo "━━━ [Debug/Introspection] ━━━"
	@echo "  make steps | make status | make selfcheck | make test"
	@echo
	@echo "━━━ [Housekeeping] ━━━"
	@echo "  make clean-artifacts VER=1.18.21   # remove transplant artifacts"
	@echo "  make clean                          # remove glibc staging"
	@echo
	@echo "━━━ [Transplant Notes] ━━━"
	@echo "  section-format graphs require android Bun base >= 1.4.0"
	@echo "  make transplant-predict VER=1.18.22   # dry-run feasibility gate"
	@echo "  QUARANTINE: bun-base resolve failure writes bun-base.QUARANTINE.json"
	@echo
	@echo "━━━ [Wrapper CLI] ━━━"
	@echo "  ./tools/make-opencode --all --ver 1.2.10 --pkg both"
	@echo "  TARGET_HOST=192.168.1.22 TARGET_USER=u0_a258 ./tools/upgrade-matrix.sh"
	@echo
	@echo "━━━ ⚠ Standalone (frozen) ━━━"
	@echo "  No new standalone builds. Use scripts directly:"
	@echo "    ./scripts/package/package_deb_standalone.sh"
	@echo "    ./scripts/package/package_pacman_standalone.sh"

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
# bun-base pairing is resolved internally from tools/transplant/config/bun-bind.json
# (min_base_for_section: section-format graphs require android Bun base >= 1.4.0;
#  trailer-format <=1.3.x require a 1.3.x base). A resolve failure aborts with a
#  non-zero exit and writes artifacts/transplant/<ver>/bun-base.QUARANTINE.json
#  (QUARANTINE) — no hardcoded base fallback remains in this chain.
transplant:
	@if [ -z "$(VER)" ]; then \
		echo "Error: VER is empty. Example: make transplant VER=1.3.13"; \
		exit 1; \
	fi
	@echo "==> transplant VER=$(VER)"
	python3 tools/transplant/transplant.py all --ver $(VER) --tgz $${TMPDIR:-/tmp}/$$(npm pack opencode-linux-arm64@$(VER) --pack-destination $${TMPDIR:-/tmp} 2>/dev/null | tail -n1)
	@# W7c2: TUI swap + post-swap pty probe are now performed INSIDE
	@# `transplant.py all` (tools/transplant/swap_tui.py graft + tui_probe gate),
	@# which records `tui_probe` in report.json. The Makefile only adds the
	@# QUARANTINE signal when the bionic libopentui.so build is absent: upgrade
	@# the old silent WARN into an explicit `tui:"absent"` in the report so the
	@# gap is impossible to miss (no silent skip).
	@if [ -f artifacts/transplant/opentui-bionic/libopentui.so ]; then \
		echo "==> bionic libopentui present; swap + tui_probe handled by transplant.py all"; \
	else \
		echo "WARN: artifacts/transplant/opentui-bionic/libopentui.so not found -> quarantine (tui:absent)"; \
		python3 -c "import json; p='artifacts/transplant/$(VER)/report.json'; \
		  r=json.load(open(p)); r['tui']='absent'; json.dump(r, open(p,'w'), indent=2); \
		  print('  report.tui=absent (bionic libopentui.so absent)')"; \
		fi
	@# W11: self-activating seccomp hardening (DT_NEEDED libopencode-crhandler.so
	@# + SIGSYS handler/PLT interposer shim). WARN-skips when the toolchain is
	@# missing; idempotent (already-hardened products are detected and skipped).
	$(MAKE) --no-print-directory seccomp-harden VER=$(VER)
# libopentui (task-tui-common-fix): ensure the canonical bionic libopentui.so
# exists AND carries the FFI negative-coordinate guard. Every transplant-built
# version equal-length-swaps THIS file, so a stale/unguarded slot lib poisons
# the whole version family (the 1.18.15-27 batch shipped pre-342d68d guards).
# Common layer: apply ALL patches/opentui/*.patch -> zig bionic build ->
# symbol-range guard scan + dlopen hostile-FFI harness -> install to slot.
# LIBOPENTUI_OPTIONAL=1 downgrades a build failure to a WARN (quarantine path
# for toolchain-less environments); default is loud.
libopentui:
	@if [ -f artifacts/transplant/opentui-bionic/libopentui.so ] && \
	    bash tools/transplant/build-libopentui.sh --check artifacts/transplant/opentui-bionic/libopentui.so; then \
		echo "==> libopentui: guard-verified .so present"; \
	elif bash tools/transplant/build-libopentui.sh; then \
		echo "==> libopentui: built + guard-verified via common layer"; \
	elif [ "$(LIBOPENTUI_OPTIONAL)" = "1" ]; then \
		echo "WARN: libopentui build failed -> transplant will quarantine (tui:absent)"; \
	else \
		echo "ERROR: libopentui build failed (common layer); set LIBOPENTUI_OPTIONAL=1 to downgrade to WARN" >&2; \
		exit 1; \
	fi

transplant: VER?= latest

# transplant-predict: DRY-RUN feasibility gate (no downloads; metadata/local state only).
# Wraps `transplant.py predict`; exit 0=OK, 1=FAIL, 2=NEEDS_INFO. Safe to run before `transplant`.
transplant-predict:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make transplant-predict VER=1.18.22"; \
		exit 1; \
	fi
	@echo "==> transplant-predict VER=$(VER)"
	python3 tools/transplant/transplant.py predict --ver $(VER)
transplant: libopentui
transplant-predict: VER?= latest

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

# seccomp-harden: W11 self-activating seccomp hardening of a revived native product.
# Builds tools/shim/sigsys_handler.c -> libopencode-crhandler.so (SIGSYS handler
# for the inline-svc sites + syscall()/close_range() PLT interposers for the
# spawn-child fd-hygiene path) and rewrites the product's dynamic section so the
# shim is the FIRST DT_NEEDED entry (no env vars, no LD_PRELOAD). The patcher is
# zero-displacement (tools/transplant/crhandler_patch.py): file size, PT_LOADs
# and the graft are provably untouched. The PRE-patch copy is kept as
# *.pre-crhandler next to the product for rollback evidence. WARN-skips when the
# toolchain is missing; idempotent (already-hardened products are detected).
# Runs automatically inside `transplant` after the TUI swap; MUST run BEFORE
# transplant-upx (upx packing hides the dynamic section).
seccomp-harden:
	@if [ -z "$(VER)" ]; then \
		echo "Error: VER is empty. Example: make seccomp-harden VER=1.18.21"; \
		exit 1; \
	fi
	@if ! command -v clang >/dev/null 2>&1; then \
		echo "WARN: clang not found; skipping seccomp hardening (seccomp-harden skipped)"; \
		exit 0; \
	fi
	@if [ ! -f tools/shim/sigsys_handler.c ] || [ ! -f tools/transplant/crhandler_patch.py ]; then \
		echo "WARN: tools/shim/sigsys_handler.c or tools/transplant/crhandler_patch.py missing; skipping seccomp hardening"; \
		exit 0; \
	fi
	@SRC="$(SRC)"; \
	if [ -z "$$SRC" ]; then \
		if [ -f $(NATIVE_DIR)/opencode-native-tui ]; then SRC=$(NATIVE_DIR)/opencode-native-tui; \
		elif [ -f $(NATIVE_DIR)/opencode-native-revived ]; then SRC=$(NATIVE_DIR)/opencode-native-revived; \
		elif [ -f $(NATIVE_DIR)/opencode-native ]; then SRC=$(NATIVE_DIR)/opencode-native; \
		else \
			echo "WARN: no revived product in $(NATIVE_DIR); skipping seccomp hardening"; \
			exit 0; \
		fi; \
	fi; \
	echo "==> seccomp-harden VER=$(VER) source=$$SRC"; \
	clang -shared -fPIC -O2 -o $(NATIVE_DIR)/libopencode-crhandler.so tools/shim/sigsys_handler.c || exit 1; \
	if grep -aqF libopencode-crhandler.so "$$SRC"; then \
		echo "==> seccomp-harden: $$SRC already hardened, skip (shim rebuilt)"; \
		exit 0; \
	fi; \
	cp -p "$$SRC" "$$SRC.pre-crhandler" || exit 1; \
	python3 tools/transplant/crhandler_patch.py "$$SRC" || exit 1; \
	echo "seccomp-harden: pre-patch copy kept at $$SRC.pre-crhandler";
	@# Post-patch sync: when tui was patched, ensure revived reflects the
	@# hardened binary. transplant.py produces both tui and revived, but
	@# seccomp-harden patches only the preferred source (typically tui).
	if [ "$$SRC" = "$(NATIVE_DIR)/opencode-native-tui" ] && [ -f "$(NATIVE_DIR)/opencode-native-revived" ]; then \
		if ! grep -aqF libopencode-crhandler.so "$(NATIVE_DIR)/opencode-native-revived"; then \
			rm -f "$(NATIVE_DIR)/opencode-native-revived"; \
			cp -p "$(NATIVE_DIR)/opencode-native-tui" "$(NATIVE_DIR)/opencode-native-revived"; \
			echo "seccomp-harden: synced hardened tui -> revived"; \
		fi; \
	fi

# transplant-check: golden regression across layout families
# (tests/transplant/test_golden.py; fixtures pre-downloaded by scripts/fetch-fixtures.sh)
transplant-check:
	python3 tests/transplant/test_golden.py --fixtures-dir tests/transplant/fixtures/tgz

# ══════════════════════════════════════════════════════════════════════
# Grouped family targets (single-version per-family builds)
# ══════════════════════════════════════════════════════════════════════

# family-glibc: build glibc wrapper packages for a single version
# Usage: make family-glibc VER=1.18.21
family-glibc: runtime stage
	@if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb VER=$(VER); \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman VER=$(VER); \
	else \
		$(MAKE) deb VER=$(VER) && $(MAKE) pacman VER=$(VER); \
	fi

# family-native: transplant + seccomp-harden + native packages for a single version
# Usage: make family-native VER=1.18.21
family-native:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make family-native VER=1.18.21"; \
		exit 1; \
	fi
	$(MAKE) transplant VER=$(VER)
	$(MAKE) deb-native VER=$(VER) && $(MAKE) pacman-native VER=$(VER)

# family-compressed: UPX-compressed variant (local build)
# Usage: make family-compressed VER=1.18.21
family-compressed:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make family-compressed VER=1.18.21"; \
		exit 1; \
	fi
	$(MAKE) transplant VER=$(VER)
	$(MAKE) transplant-upx VER=$(VER)

# ══════════════════════════════════════════════════════════════════════
# Range batch build (multi-version, continue-on-fail)
# ══════════════════════════════════════════════════════════════════════

# range-build: build multiple versions across families with resilience
# Usage: make range-build FROM=1.18.15 TO=1.18.27 LINES=glibc,native
# Features: continue-on-fail, npm retry ≤3, disk guardrail, SHA256SUMS accumulation
range-build:
	@if [ -z "$(FROM)" ] || [ -z "$(TO)" ]; then \
		echo "Error: FROM and TO are required. Example: make range-build FROM=1.18.15 TO=1.18.27 LINES=glibc,native"; \
		exit 1; \
	fi
	@if [ -z "$(LINES)" ]; then \
		echo "Error: LINES is required (glibc,native[,compressed])"; \
		exit 1; \
	fi
	bash scripts/range-build.sh FROM=$(FROM) TO=$(TO) LINES=$(LINES)

# ══════════════════════════════════════════════════════════════════════
# Fleet UPX (distributed compression)
# ══════════════════════════════════════════════════════════════════════

# fleet-upx: distribute UPX compression across multiple nodes
# Usage: make fleet-upx VER=1.18.21 NODES="miao@100.98.3.121 miao@100.110.50.37"
# Features: sshpass -p 0, xz -9 outbound, opportunistic dispatch, local verify
fleet-upx:
	@if [ -z "$(VER)" ] || [ -z "$(NODES)" ]; then \
		echo "Error: VER and NODES are required. Example: make fleet-upx VER=1.18.21 NODES=\"miao@host1 miao@host2\""; \
		exit 1; \
	fi
	bash scripts/fleet-upx.sh VER=$(VER) NODES="$(NODES)"

# fleet-status: probe fleet nodes for availability
fleet-status:
	bash scripts/fleet-upx.sh --status

# ══════════════════════════════════════════════════════════════════════
# Release staging
# ══════════════════════════════════════════════════════════════════════

# sha-stage: regenerate SHA256SUMS-prebatch.txt from packing/
sha-stage:
	bash scripts/sha-stage.sh

# push-stage: build gh release create command (dry-run by default)
# Usage: make push-stage TAG=Push260903 BATCH=prebatch
# Set PUSH=1 to actually execute upload
push-stage:
	@if [ -z "$(TAG)" ]; then \
		echo "Error: TAG is required. Example: make push-stage TAG=Push260903 BATCH=prebatch"; \
		exit 1; \
	fi
	bash scripts/push-stage.sh TAG=$(TAG) BATCH=$(BATCH)$(if $(PUSH),PUSH=1)

# ══════════════════════════════════════════════════════════════════════
# Housekeeping
# ══════════════════════════════════════════════════════════════════════

# clean-artifacts: remove transplant artifacts for a specific version
# Usage: make clean-artifacts VER=1.18.21
clean-artifacts:
	@if [ -z "$(VER_IS_SET)" ]; then \
		echo "Error: VER is required. Example: make clean-artifacts VER=1.18.21"; \
		exit 1; \
	fi
	rm -rf artifacts/transplant/$(VER)
	@echo "Cleaned artifacts for $(VER)"

# ══════════════════════════════════════════════════════════════════════
# Standalone (frozen, warning banner)
# ══════════════════════════════════════════════════════════════════════

# Standalone targets are FROZEN. No new builds. Use scripts directly:
#   ./scripts/package/package_deb_standalone.sh
#   ./scripts/package/package_pacman_standalone.sh
# ══════════════════════════════════════════════════════════════════════

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
