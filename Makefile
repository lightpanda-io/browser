# Infos
# -----
.PHONY: help

## Display this help screen
help:
	@printf "\e[36m%-35s %s\e[0m\n" "Command" "Usage"
	@sed -n '/^## /{\
		s/## //g;\
		h;\
		n;\
		s/:.*//g;\
		G;\
		s/\n/ /g;\
		p;}' Makefile | awk '{printf "\033[33m%-35s\033[0m%s\n", $$1, substr($$0,length($$1)+1)}'


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
