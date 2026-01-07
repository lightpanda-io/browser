# Variables
# ---------

ZIG := zig
BC := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# option test filter make test F="server"
F=

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
.PHONY: build build-v8-snapshot build-dev run run-release shell test bench wpt data end2end

## Build v8 snapshot
build-v8-snapshot:
	@printf "\033[36mBuilding v8 snapshot (release safe)...\033[0m\n"
	@$(ZIG) build -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in release-fast mode
build: build-v8-snapshot
	@printf "\033[36mBuilding (release safe)...\033[0m\n"
	@$(ZIG) build -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin -Dgit_commit=$$(git rev-parse --short HEAD) || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Build in debug mode
build-dev:
	@printf "\033[36mBuilding (debug)...\033[0m\n"
	@$(ZIG) build -Dgit_commit=$$(git rev-parse --short HEAD) || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)
	@printf "\033[33mBuild OK\033[0m\n"

## Run the server in release mode
run: build
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Run the server in debug mode
run-debug: build-dev
	@printf "\033[36mRunning...\033[0m\n"
	@./zig-out/bin/lightpanda || (printf "\033[33mRun ERROR\033[0m\n"; exit 1;)

## Run a JS shell in debug mode
shell:
	@printf "\033[36mBuilding shell...\033[0m\n"
	@$(ZIG) build shell || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)

## Run WPT tests
wpt:
	@printf "\033[36mBuilding wpt...\033[0m\n"
	@$(ZIG) build wpt -- $(filter-out $@,$(MAKECMDGOALS)) || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)

wpt-summary:
	@printf "\033[36mBuilding wpt...\033[0m\n"
	@$(ZIG) build wpt -- --summary $(filter-out $@,$(MAKECMDGOALS)) || (printf "\033[33mBuild ERROR\033[0m\n"; exit 1;)

## Test - `grep` is used to filter out the huge compile command on build
ifeq ($(OS), macos)
test:
	@script -q /dev/null sh -c 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace' 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
else
test:
	@script -qec 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace' /dev/null 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
endif

## Run demo/runner end to end tests
end2end:
	@test -d ../demo
	cd ../demo && go run runner/main.go

# Install and build required dependencies commands
# ------------
.PHONY: install

## Install and build dependencies for release
install: install-submodule

data:
	cd src/data && go run public_suffix_list_gen.go > public_suffix_list.zig

## Init and update git submodule
install-submodule:
	@git submodule init && \
	git submodule update
