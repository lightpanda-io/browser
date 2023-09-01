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


# Zig commands
# ------------
.PHONY: build build-release run run-release shell test bench

## Build in debug mode
build:
	@printf "\e[36mBuilding (debug)...\e[0m\n"
	@zig build -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

build-release:
	@printf "\e[36mBuilding (release safe)...\e[0m\n"
	@zig build -Drelease-safe -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

## Run the server
run: build
	@printf "\e[36mRunning...\e[0m\n"
	@./zig-out/bin/browsercore || (printf "\e[33mRun ERROR\e[0m\n"; exit 1;)

## Run a JS shell in release-safe mode
shell:
	@printf "\e[36mBuilding shell...\e[0m\n"
	@zig build shell -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)

## Test
test:
	@printf "\e[36mTesting...\e[0m\n"
	@zig build test -Dengine=v8 || (printf "\e[33mTest ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mTest OK\e[0m\n"

# Install and build required dependencies commands
# ------------
.PHONY: install-submodule
.PHONY: install-lexbor install-jsruntime install-jsruntime-dev
.PHONY: install-dev install

## Install and build dependencies for release
install: install-submodule install-lexbor install-jsruntime

## Install and build dependencies for dev
install-dev: install-submodule install-lexbor install-jsruntime-dev

## Install and build v8 engine for dev
install-lexbor:
	@mkdir -p vendor/lexbor
	@cd vendor/lexbor && \
	cmake ../lexbor-src -DLEXBOR_BUILD_SHARED=OFF && \
	make

install-jsruntime-dev:
	@cd vendor/jsruntime-lib && \
	make install-dev

install-jsruntime:
	@cd vendor/jsruntime-lib && \
	make install

## Init and update git submodule
install-submodule:
	@git submodule init && \
	git submodule update
