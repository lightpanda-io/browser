# Variables
# ---------

ZIG := zig
BC := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# option test filter make test F="server"
F=

# Extra flags forwarded to every `$(ZIG) build` invocation. Most commonly used
# to point at a prebuilt V8 archive and skip the multi-minute source rebuild:
#   ZIGFLAGS=-Dprebuilt_v8_path=/path/to/libc_v8.a make test
ZIGFLAGS ?=

# OS and ARCH
kernel = $(shell uname -ms)
ifeq ($(kernel), Darwin arm64)
	OS := macos
	ARCH := aarch64
else ifeq ($(kernel), Darwin x86_64)
	OS := macos
	ARCH := x86_64
else ifeq ($(kernel), Linux aarch64)
	OS := linux
	ARCH := aarch64
else ifeq ($(kernel), Linux arm64)
	OS := linux
	ARCH := aarch64
else ifeq ($(kernel), Linux x86_64)
	OS := linux
	ARCH := x86_64
else
	$(error "Unhandled kernel: $(kernel)")
endif


# Darwin SDK shim for macOS 26+
# -----------------------------
# macOS 26 CommandLineTools dropped `arm64-macos` from every system .tbd
# export — only `arm64e-macos` remains. Zig 0.15.x bundles a
# libSystem.tbd that still has `arm64-macos` but is pinned to macOS 15.5;
# its auto-detection picks the higher-numbered system SDK and the arm64
# link fails with ~30 undefined libSystem / CoreFoundation /
# SystemConfiguration symbols.
#
# When the system SDK lacks `arm64-macos`, build a hybrid SDK shim into
# .lp-cache/darwin-sdk-shim/ once: usr/include and friends are
# symlinked from the system SDK, libSystem.tbd is swapped for Zig's
# bundled copy, every other .tbd is rewritten to also export arm64-macos.
# A repo-local xcrun wrapper at $(DARWIN_SDK_SHIM_BIN)/xcrun is prepended
# to PATH for `zig` invocations, so Zig's SDK detection lands on the
# shim instead of the system SDK. Hosts that don't need the shim (older
# macOS, Linux, or any future Apple SDK that puts arm64-macos back) skip
# this block entirely — the Makefile is identical to before.
ifeq ($(OS), macos)
SYS_SDK := $(shell /usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)
# Check the FIRST `targets:` block in libSystem.tbd (the main libSystem entry,
# which is what the Mach-O linker resolves `-lSystem` against). The
# `[^e]arm64-macos` regex avoids the false-positive match on `arm64e-macos`
# substrings; sub-library entries lower in the .tbd may carry arm64-macos
# even when the main entry doesn't, but those aren't what the link picks up.
NEEDS_DARWIN_SDK_SHIM := $(shell awk '/^targets:/ { if ($$0 !~ /[^e]arm64-macos/) print "yes"; exit }' "$(SYS_SDK)/usr/lib/libSystem.tbd" 2>/dev/null)

ifeq ($(NEEDS_DARWIN_SDK_SHIM), yes)
DARWIN_SDK_SHIM_DIR := $(BC).lp-cache/darwin-sdk-shim
DARWIN_SDK_SHIM_SDK := $(DARWIN_SDK_SHIM_DIR)/sdk
DARWIN_SDK_SHIM_BIN := $(DARWIN_SDK_SHIM_DIR)/bin
DARWIN_SDK_SHIM_MARK := $(DARWIN_SDK_SHIM_DIR)/.built

# Prepend the wrapper bin dir to PATH and point the wrapper at the shim
# SDK. Both vars are exported so `zig build` and any nested invocations
# pick them up. The wrapper falls through to /usr/bin/xcrun if the env
# var or the directory is missing, so an in-progress build won't trip
# over a partial shim.
export PATH := $(DARWIN_SDK_SHIM_BIN):$(PATH)
export LIGHTPANDA_DARWIN_SDK_SHIM := $(DARWIN_SDK_SHIM_SDK)

$(DARWIN_SDK_SHIM_MARK): $(BC)scripts/darwin-sdk-shim.sh
	@printf "\033[36mBuilding macOS 26 SDK shim at $(DARWIN_SDK_SHIM_DIR) (one-time)...\033[0m\n"
	@$(BC)scripts/darwin-sdk-shim.sh "$(DARWIN_SDK_SHIM_DIR)"
	@mkdir -p $(DARWIN_SDK_SHIM_DIR)
	@touch $(DARWIN_SDK_SHIM_MARK)

.PHONY: darwin-sdk-shim darwin-sdk-shim-clean
## Build (or rebuild) the macOS 26 SDK shim used to link arm64-macos binaries
darwin-sdk-shim: $(DARWIN_SDK_SHIM_MARK)

## Remove the macOS SDK shim; next test/build rebuilds it
darwin-sdk-shim-clean:
	@find $(DARWIN_SDK_SHIM_DIR) -mindepth 1 -delete 2>/dev/null || true
	@rmdir $(DARWIN_SDK_SHIM_DIR) 2>/dev/null || true
endif
endif


# Prebuilt V8
# -----------
# Building V8 from source takes 10+ minutes. `make download-v8` fetches the
# matching prebuilt archive from the zig-v8-fork releases instead. The versions
# are read from the install action so they can't drift from CI.
V8_ACTION := .github/actions/install/action.yml
V8_VERSION := $(shell awk -F\' '/^  v8:/{f=1} f&&/default:/{print $$2; exit}' $(V8_ACTION))
ZIG_V8_TAG := $(shell awk -F\' '/^  zig-v8:/{f=1} f&&/default:/{print $$2; exit}' $(V8_ACTION))
V8_ARCHIVE := libc_v8_$(V8_VERSION)_$(OS)_$(ARCH).a
V8_CACHE   := .lp-cache/prebuilt-v8/$(V8_ARCHIVE)

# If the prebuilt archive is in place and the caller hasn't set ZIGFLAGS, point
# the build at it rather than building V8 from source.
ifeq ($(strip $(ZIGFLAGS)),)
  ifneq ($(wildcard $(V8_CACHE)),)
    ZIGFLAGS := -Dprebuilt_v8_path=$(V8_CACHE)
  endif
endif


# Infos
# -----
.PHONY: help

## Display this help screen
help:
	@printf "\033[36m%-35s %s\033[0m\n" "Command" "Usage"
	@sed -n -e '/^## /{'\
		-e 's/## //g;'\
		-e 'h;'\
		-e 'n;'\
		-e 's/:.*//g;'\
		-e 'G;'\
		-e 's/\n/ /g;'\
		-e 'p;}' Makefile | awk '{printf "\033[33m%-35s\033[0m%s\n", $$1, substr($$0,length($$1)+1)}'


# $(ZIG) commands
# ------------
.PHONY: build build-v8-snapshot build-dev download-v8 run run-release test bench data end2end clean

## Download the prebuilt V8 archive (skips the 10+ min source build)
download-v8:
	@mkdir -p $(dir $(V8_CACHE))
	@test -f $(V8_CACHE) || ( \
		printf "\033[36mDownloading prebuilt V8 $(V8_VERSION) ($(ZIG_V8_TAG))...\033[0m\n"; \
		curl -fL --progress-bar -o $(V8_CACHE) \
			https://github.com/lightpanda-io/zig-v8-fork/releases/download/$(ZIG_V8_TAG)/$(V8_ARCHIVE) \
		|| (rm -f $(V8_CACHE); printf "\033[33mDownload ERROR\033[0m\n"; exit 1) )
	@printf "\033[33mV8 ready: %s\033[0m\n" "$(V8_CACHE)"

## Build v8 snapshot
build-v8-snapshot: $(DARWIN_SDK_SHIM_MARK)
	@printf "\033[36mBuilding v8 snapshot (release safe)...\033[0m\n"
	@$(ZIG) build $(ZIGFLAGS) -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in release-fast mode
build: build-v8-snapshot
	@printf "\033[36mBuilding (release fast)...\033[0m\n"
	@$(ZIG) build $(ZIGFLAGS) -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in debug mode
build-dev: $(DARWIN_SDK_SHIM_MARK)
	@printf "\033[36mBuilding (debug)...\033[0m\n"
	@$(ZIG) build $(ZIGFLAGS) || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Run the server in release mode
run: build
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Run the server in debug mode
run-debug: build-dev
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Test - `grep` is used to filter out the huge compile command on build
ifeq ($(OS), macos)
test: $(DARWIN_SDK_SHIM_MARK)
	@script -q /dev/null sh -c 'TEST_FILTER="${F}" $(ZIG) build $(ZIGFLAGS) test -freference-trace' 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
else
test:
	@script -qec 'TEST_FILTER="${F}" $(ZIG) build $(ZIGFLAGS) test -freference-trace' /dev/null 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
endif

## Run demo/runner end to end tests
end2end:
	@test -d ../demo
	cd ../demo && go run runner/main.go

## Remove build artifacts (keeps .lp-cache/ and zig-pkg/ — slow to re-fetch)
clean:
	rm -rf zig-out .zig-cache src/snapshot.bin
	cd src/html5ever && cargo clean
ifeq ($(NEEDS_DARWIN_SDK_SHIM), yes)
	@find $(DARWIN_SDK_SHIM_DIR) -mindepth 1 -delete 2>/dev/null || true
	@rmdir $(DARWIN_SDK_SHIM_DIR) 2>/dev/null || true
endif

# Install and build required dependencies commands
# ------------
.PHONY: install

install: build

data:
	cd src/data && go run public_suffix_list_gen.go > public_suffix_list.zig
