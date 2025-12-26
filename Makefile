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
	@printf "\e[36m%-35s %s\e[0m\n" "Command" "Usage"
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
.PHONY: build build-dev run run-release shell test bench download-zig wpt data
.PHONY: end2end

zig_version = $(shell grep 'recommended_zig_version = "' "vendor/zig-js-runtime/build.zig" | cut -d'"' -f2)

## Download the zig recommended version
download-zig:
	$(eval url = "https://ziglang.org/download/$(zig_version)/zig-$(OS)-$(ARCH)-$(zig_version).tar.xz")
	$(eval dest = "/tmp/zig-$(OS)-$(ARCH)-$(zig_version).tar.xz")
	@printf "\e[36mDownload zig version $(zig_version)...\e[0m\n"
	@curl -o "$(dest)" -L "$(url)" || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mDownloaded $(dest)\e[0m\n"

## Build in release-safe mode
build:
	@printf "\e[36mBuilding (release safe)...\e[0m\n"
	$(ZIG) build -Doptimize=ReleaseSafe -Dgit_commit=$$(git rev-parse --short HEAD) || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

## Build in debug mode
build-dev:
	@printf "\e[36mBuilding (debug)...\e[0m\n"
	@$(ZIG) build -Dgit_commit=$$(git rev-parse --short HEAD) || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

## Run the server in release mode
run: build
	@printf "\e[36mRunning...\e[0m\n"
	@./zig-out/bin/lightpanda || (printf "\e[33mRun ERROR\e[0m\n"; exit 1;)

## Run the server in debug mode
run-debug: build-dev
	@printf "\e[36mRunning...\e[0m\n"
	@./zig-out/bin/lightpanda || (printf "\e[33mRun ERROR\e[0m\n"; exit 1;)

## Run a JS shell in debug mode
shell:
	@printf "\e[36mBuilding shell...\e[0m\n"
	@$(ZIG) build shell || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)

## Run WPT tests
wpt:
	@printf "\e[36mBuilding wpt...\e[0m\n"
	@$(ZIG) build wpt -- $(filter-out $@,$(MAKECMDGOALS)) || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)

wpt-summary:
	@printf "\e[36mBuilding wpt...\e[0m\n"
	@$(ZIG) build wpt -- --summary $(filter-out $@,$(MAKECMDGOALS)) || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)

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
