# Browsercore

## Build

### Prerequisites

Browsercore is written with [Zig](https://ziglang.org/) `0.10.1`. You have to
install it with the right version in order to build the project.

Browsercore also depends on
[js-runtimelib](https://github.com/francisbouvier/jsruntime-lib/) and
[lexbor](https://github.com/lexbor/lexbor) libs.

To be able to build the v8 engine for js-runtimelib, you have to install some libs:

For Debian/Ubuntu based Linux:
```
sudo apt install xz-utils \
    python3 ca-certificates git \
    pkg-config libglib2.0-dev \
    libexpat1-dev \
    cmake clang
```

For MacOS, you only need Python 3 and cmake.

To be able to build lexbor, you need to install also `cmake`.

### Install and build dependencies

The project uses git submodule for dependencies.
The `make install-submodule` will init and update the submodules in the `vendor/`
directory.

```
make install-submodule
```

### Build netsurf

The command `make install-netsurf` will build netsurf libs used by browsercore.
```
make install-netsurf
```

### Build lexbor

The command `make install-lexbor` will build lexbor lib used by browsercore.
```
make install-lexbor
```

### Build jsruntime-lib

The command `make install-jsruntime-dev` uses jsruntime-lib's `zig-v8` dependency to build v8 engine lib.
Be aware the build task is very long and cpu consuming.

Build v8 engine for debug/dev version, it creates
`vendor/jsruntime-lib/vendor/v8/$ARCH/debug/libc_v8.a` file.

```
make install-jsruntime-dev
```

You should also build a release vesion of v8 with:

```
make install-jsruntime
```

### All in one build

You can run `make intall` and `make install-dev` to install deps all in one.

## Test

You can test browsercore by running `make test`.
