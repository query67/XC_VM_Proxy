# XC_VM_Proxy — release archive builder
#
# Produces the artifacts consumed by the panel's ProxyArchiveUpdater / cron:proxy:
#
#   dist/proxy.tar.gz     — proxy-node bundle, unpacks into MAIN_HOME on the node
#   dist/hashes.md5       — "<md5>  proxy.tar.gz"    (parsed by GitHubReleases::getAssetHash)
#   dist/hashes.sha256    — "<sha256>  proxy.tar.gz" (forward hygiene; panel uses md5 today)
#
# Upload all three as GitHub release assets (see .github/workflows/build-release.yml).
# Tags MUST be bare semver (X.Y.Z, no "v" prefix) — the panel's isValidVersion() /
# version_compare only accept bare tags.
#
# The archive is byte-reproducible for a given commit: LC_ALL=C stable sort, pinned
# owner/group, mtime = commit time (never wall-clock), gzip -n. Requires GNU tar.
#
# @license AGPL-3.0

SHELL := /bin/bash

MAIN_DIR  := ./src
DIST_DIR  := ./dist
# Stage on a real filesystem where chmod is honoured. The repo may live on a mount
# that forces 0777 (NTFS/exFAT/CIFS) where chmod is a no-op — staging there would
# ship world-writable perms regardless of set_permissions. /tmp is ext4/tmpfs.
TEMP_DIR  := /tmp/xc_vm_proxy_stage
ASSET     := proxy.tar.gz

# Version: CI passes the release tag (make build VERSION=1.2.3); locally derive it.
VERSION           ?= $(shell git describe --tags --always 2>/dev/null || echo 0.0.0)
GIT_SHA           := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Reproducible mtime: commit time of HEAD — stable per tag, never `date`/now.
SOURCE_DATE_EPOCH := $(shell git log -1 --format=%ct 2>/dev/null || echo 0)

.PHONY: all build default clean stage set_permissions write_version \
        verify_no_lfs_pointers archive hashes check-reproducible

all: build
default: build

## Full release build.
build: clean stage set_permissions write_version verify_no_lfs_pointers archive hashes
	@echo "==> Done: $(DIST_DIR)/$(ASSET)  (version: $(VERSION), sha: $(GIT_SHA))"

clean:
	@echo "==> Cleaning $(DIST_DIR) and $(TEMP_DIR)"
	@[ -d "$(TEMP_DIR)" ] && chmod -R u+rwX "$(TEMP_DIR)" 2>/dev/null || true
	@rm -rf "$(DIST_DIR)" "$(TEMP_DIR)"
	@mkdir -p "$(DIST_DIR)" "$(TEMP_DIR)"

## Stage only git-tracked files from src/ (no untracked local cruft). Tracked
## .gitkeep placeholders recreate the empty runtime dirs (sessions/sockets/var),
## then are removed — the empty dirs remain in the archive.
stage:
	@echo "==> Staging git-tracked files from $(MAIN_DIR)"
	@git -C "$(MAIN_DIR)" ls-files -z | tar --null -C "$(MAIN_DIR)" -T - -cf - | tar -C "$(TEMP_DIR)" -xf -
	@find "$(TEMP_DIR)" -name .gitkeep -delete

## Normalise permissions in the staged tree BEFORE archiving.
##
## Ports the ORIGINAL intended scheme (nginx files 0550, php 0550 + 0551 binaries,
## config/runtime dirs 0750) with two fixes:
##   1. `find -exec ... \;` (the old Makefile had `\ ` — an escaped space — so every
##      find-based chmod silently failed and files shipped with their 0777 git bits);
##   2. a 0755/0644 baseline first, so paths the scheme does not touch stop being
##      world-writable (rsync/git perms were 0777 in the source tree);
##   3. crons/includes/service normalised 0777 -> 0755 (executable, not world-writable);
##      server.key hardened 0755 -> 0640.
## Safe because the whole stack runs as the owner (xc_vm).
set_permissions:
	@echo "==> Setting permissions in $(TEMP_DIR)"
	@find "$(TEMP_DIR)" -type d -exec chmod 0755 {} \;
	@find "$(TEMP_DIR)" -type f -exec chmod 0644 {} \;
	@chmod 0750 "$(TEMP_DIR)/bin" 2>/dev/null || true
	@find "$(TEMP_DIR)/bin/nginx" -type d -exec chmod 0750 {} \; 2>/dev/null || true
	@find "$(TEMP_DIR)/bin/nginx" -type f -exec chmod 0550 {} \; 2>/dev/null || true
	@chmod 0755 "$(TEMP_DIR)/bin/nginx/conf" 2>/dev/null || true
	@chmod 0644 "$(TEMP_DIR)/bin/nginx/conf/server.crt" 2>/dev/null || true
	@chmod 0640 "$(TEMP_DIR)/bin/nginx/conf/server.key" 2>/dev/null || true
	@find "$(TEMP_DIR)/bin/php" -exec chmod 0550 {} \; 2>/dev/null || true
	@for d in etc sessions sockets; do chmod 0750 "$(TEMP_DIR)/bin/php/$$d" 2>/dev/null || true; done
	@find "$(TEMP_DIR)/bin/php/var" -type d -exec chmod 0750 {} \; 2>/dev/null || true
	@chmod 0551 "$(TEMP_DIR)/bin/php/bin/php" 2>/dev/null || true
	@chmod 0551 "$(TEMP_DIR)/bin/php/sbin/php-fpm" 2>/dev/null || true
	@chmod 0755 "$(TEMP_DIR)/bin/php/lib/php/extensions/no-debug-non-zts-20210902" 2>/dev/null || true
	@chmod 0755 "$(TEMP_DIR)/crons" "$(TEMP_DIR)/includes" 2>/dev/null || true
	@find "$(TEMP_DIR)/crons"    -type f -exec chmod 0755 {} \; 2>/dev/null || true
	@find "$(TEMP_DIR)/includes" -type f -exec chmod 0755 {} \; 2>/dev/null || true
	@chmod 0755 "$(TEMP_DIR)/service" 2>/dev/null || true
	@find "$(TEMP_DIR)" -type f -name '*.sh' -exec chmod 0755 {} \;
	@chmod 0750 "$(TEMP_DIR)/config" 2>/dev/null || true

## Provenance file inside the archive — git tag + short sha only, NO wall-clock,
## so the tarball stays byte-reproducible for a given commit.
write_version:
	@echo "==> Writing version.json ($(VERSION) / $(GIT_SHA))"
	@printf '{\n  "version": "%s",\n  "commit": "%s"\n}\n' "$(VERSION)" "$(GIT_SHA)" > "$(TEMP_DIR)/version.json"
	@chmod 0644 "$(TEMP_DIR)/version.json"

## Fail the build if a checkout without LFS left 130-byte pointer stubs staged.
verify_no_lfs_pointers:
	@echo "==> Verifying no Git LFS pointer files in $(TEMP_DIR)"
	@pointers=$$(grep -rlI '^version https://git-lfs.github.com/spec/v1' "$(TEMP_DIR)" 2>/dev/null || true); \
	if [ -n "$$pointers" ]; then \
		echo "ERROR: Git LFS pointer files staged (checkout without 'lfs: true'):"; \
		echo "$$pointers" | sed 's|^$(TEMP_DIR)/|   - |'; \
		exit 1; \
	fi; \
	echo "OK: no LFS pointers staged"

## Deterministic tarball. LC_ALL=C → locale-stable --sort=name; owner/group pinned;
## mtime = commit time (not now); gzip -n drops the gzip header timestamp/name.
archive:
	@echo "==> Building $(DIST_DIR)/$(ASSET) (deterministic)"
	@cd "$(TEMP_DIR)" && LC_ALL=C tar \
		--sort=name \
		--format=gnu \
		--numeric-owner --owner=0 --group=0 \
		--mtime=@$(SOURCE_DATE_EPOCH) \
		-cf - . | gzip -n > "$(CURDIR)/$(DIST_DIR)/$(ASSET)"

## hashes.md5 / hashes.sha256 in the panel's expected "<hash>  <name>" format
## (bare filename, no path — run from inside DIST_DIR).
hashes:
	@echo "==> Writing hashes"
	@cd "$(DIST_DIR)" && md5sum    "$(ASSET)" > hashes.md5
	@cd "$(DIST_DIR)" && sha256sum "$(ASSET)" > hashes.sha256
	@cat "$(DIST_DIR)/hashes.md5" "$(DIST_DIR)/hashes.sha256"

## CI smoke: build twice, assert identical sha256 (proves determinism).
check-reproducible:
	@$(MAKE) --no-print-directory build >/dev/null
	@a=$$(sha256sum "$(DIST_DIR)/$(ASSET)" | awk '{print $$1}'); \
	$(MAKE) --no-print-directory build >/dev/null; \
	b=$$(sha256sum "$(DIST_DIR)/$(ASSET)" | awk '{print $$1}'); \
	if [ "$$a" = "$$b" ]; then echo "OK: reproducible ($$a)"; else echo "FAIL: $$a != $$b"; exit 1; fi
