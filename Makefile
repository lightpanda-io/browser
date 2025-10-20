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
.PHONY: build build-dev run run-release shell test bench download-zig wpt data get-v8 build-v8 build-v8-dev
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
	@script -q /dev/null sh -c 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace --summary all' 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
else
test:
	@script -qec 'TEST_FILTER="${F}" $(ZIG) build test -freference-trace --summary all' /dev/null 2>&1 \
		| grep --line-buffered -v "^/.*zig test -freference-trace"
endif

## Run demo/runner end to end tests
end2end:
	@test -d ../demo
	cd ../demo && go run runner/main.go

## v8
get-v8:
	@printf "\e[36mGetting v8 source...\e[0m\n"
	@$(ZIG) build get-v8

build-v8-dev:
	@printf "\e[36mBuilding v8 (dev)...\e[0m\n"
	@$(ZIG) build build-v8

build-v8:
	@printf "\e[36mBuilding v8...\e[0m\n"
	@$(ZIG) build -Doptimize=ReleaseSafe build-v8

# Install and build required dependencies commands
# ------------
.PHONY: install-submodule
.PHONY: install-libiconv
.PHONY: _install-netsurf install-netsurf clean-netsurf test-netsurf install-netsurf-dev
.PHONY: install-mimalloc install-mimalloc-dev clean-mimalloc
.PHONY: install-dev install

## Install and build dependencies for release
install: install-submodule install-libiconv install-netsurf install-mimalloc

## Install and build dependencies for dev
install-dev: install-submodule install-libiconv install-netsurf-dev install-mimalloc-dev

install-netsurf-dev: _install-netsurf
install-netsurf-dev: OPTCFLAGS := -O0 -g -DNDEBUG

install-netsurf: _install-netsurf
install-netsurf: OPTCFLAGS := -DNDEBUG

BC_NS := $(BC)vendor/netsurf/out/$(OS)-$(ARCH)
ICONV := $(BC)vendor/libiconv/out/$(OS)-$(ARCH)
# TODO: add Linux iconv path (I guess it depends on the distro)
# TODO: this way of linking libiconv is not ideal. We should have a more generic way
# and stick to a specif version. Maybe build from source. Anyway not now.
_install-netsurf: clean-netsurf
	@printf "\e[36mInstalling NetSurf...\e[0m\n" && \
	ls $(ICONV)/lib/libiconv.a 1> /dev/null || (printf "\e[33mERROR: you need to execute 'make install-libiconv'\e[0m\n"; exit 1;) && \
	mkdir -p $(BC_NS) && \
	cp -R vendor/netsurf/share $(BC_NS) && \
	export PREFIX=$(BC_NS) && \
	export OPTLDFLAGS="-L$(ICONV)/lib" && \
	export OPTCFLAGS="$(OPTCFLAGS) -I$(ICONV)/include" && \
	printf "\e[33mInstalling libwapcaplet...\e[0m\n" && \
	cd vendor/netsurf/libwapcaplet && \
	BUILDDIR=$(BC_NS)/build/libwapcaplet make install && \
	cd ../libparserutils && \
	printf "\e[33mInstalling libparserutils...\e[0m\n" && \
	BUILDDIR=$(BC_NS)/build/libparserutils make install && \
	cd ../libhubbub && \
	printf "\e[33mInstalling libhubbub...\e[0m\n" && \
	BUILDDIR=$(BC_NS)/build/libhubbub make install && \
	rm src/treebuilder/autogenerated-element-type.c && \
	cd ../libdom && \
	printf "\e[33mInstalling libdom...\e[0m\n" && \
	BUILDDIR=$(BC_NS)/build/libdom make install && \
	printf "\e[33mRunning libdom example...\e[0m\n" && \
	cd examples && \
	$(ZIG) cc \
	-I$(ICONV)/include \
	-I$(BC_NS)/include \
	-L$(ICONV)/lib \
	-L$(BC_NS)/lib \
	-liconv \
	-ldom \
	-lhubbub \
	-lparserutils \
	-lwapcaplet \
	-o a.out \
	dom-structure-dump.c \
	$(ICONV)/lib/libiconv.a && \
	./a.out > /dev/null && \
	rm a.out && \
	printf "\e[36mDone NetSurf $(OS)\e[0m\n"

clean-netsurf:
	@printf "\e[36mCleaning NetSurf build...\e[0m\n" && \
	rm -Rf $(BC_NS)

test-netsurf:
	@printf "\e[36mTesting NetSurf...\e[0m\n" && \
	export PREFIX=$(BC_NS) && \
	export LDFLAGS="-L$(ICONV)/lib -L$(BC_NS)/lib" && \
	export CFLAGS="-I$(ICONV)/include -I$(BC_NS)/include" && \
	cd vendor/netsurf/libdom && \
	BUILDDIR=$(BC_NS)/build/libdom make test

download-libiconv:
ifeq ("$(wildcard vendor/libiconv/libiconv-1.17)","")
	@mkdir -p vendor/libiconv
	@cd vendor/libiconv && \
	curl -L https://github.com/lightpanda-io/libiconv/releases/download/1.17/libiconv-1.17.tar.gz | tar -xvzf -
endif

build-libiconv: clean-libiconv
	@cd vendor/libiconv/libiconv-1.17 && \
	./configure --prefix=$(ICONV) --enable-static && \
	make && make install

install-libiconv: download-libiconv build-libiconv

clean-libiconv:
ifneq ("$(wildcard vendor/libiconv/libiconv-1.17/Makefile)","")
	@cd vendor/libiconv/libiconv-1.17 && \
	make clean
endif

data:
	cd src/data && go run public_suffix_list_gen.go > public_suffix_list.zig

.PHONY: _build_mimalloc

MIMALLOC := $(BC)vendor/mimalloc/out/$(OS)-$(ARCH)
_build_mimalloc: clean-mimalloc
	@mkdir -p $(MIMALLOC)/build && \
	cd $(MIMALLOC)/build && \
	cmake -DMI_BUILD_SHARED=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_OVERRIDE=OFF $(OPTS) ../../.. && \
	make && \
	mkdir -p $(MIMALLOC)/lib

install-mimalloc-dev: _build_mimalloc
install-mimalloc-dev: OPTS=-DCMAKE_BUILD_TYPE=Debug
install-mimalloc-dev:
	@cd $(MIMALLOC) && \
	mv build/libmimalloc-debug.a lib/libmimalloc.a

install-mimalloc: _build_mimalloc
install-mimalloc:
	@cd $(MIMALLOC) && \
	mv build/libmimalloc.a lib/libmimalloc.a

clean-mimalloc:
	@rm -Rf $(MIMALLOC)/build

## Init and update git submodule
install-submodule:
	@git submodule init && \
	git submodule update
