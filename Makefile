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
build-v8-snapshot:
	@printf "\033[36mBuilding v8 snapshot (release safe)...\033[0m\n"
	@$(ZIG) build $(ZIGFLAGS) -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in release-fast mode
build: build-v8-snapshot
	@printf "\033[36mBuilding (release fast)...\033[0m\n"
	@$(ZIG) build $(ZIGFLAGS) -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in debug mode
build-dev:
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
test:
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

# Install and build required dependencies commands
# ------------
.PHONY: install

install: build

data:
	cd src/data && go run public_suffix_list_gen.go > public_suffix_list.zig
