# TARGETARCH is a built-in argument provided by Docker, representing the target architecture (e.g., amd64, arm64)
# https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope

ARG MINISIG=0.12
ARG ZIG=0.14.0
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG V8=11.1.134
ARG ZIG_V8=v0.1.17

# Define the base image alias
FROM ubuntu:24.04 AS base

# Stage 1: Clone source code
FROM base AS source

# Install dependencies for this stage
RUN apt-get update -yq && \
    apt-get install -yq --no-install-recommends git ca-certificates

# force use of http instead of ssh with github
RUN cat <<EOF > /root/.gitconfig
[url "https://github.com/"]
    insteadOf="git@github.com:"
EOF

RUN git clone --recursive https://github.com/lightpanda-io/browser.git /browser

# Stage 2: Download V8
FROM base AS v8_download

ARG V8
ARG ZIG_V8
ARG TARGETARCH # Declare TARGETARCH to use it in this stage

# Install dependencies needed for this stage
RUN apt-get update -yq && \
    apt-get install -yq --no-install-recommends curl ca-certificates

# Map TARGETARCH for V8 download paths
RUN case ${TARGETARCH} in \
      amd64) MAPPED_ARCH=x86_64 ;; \
      arm64) MAPPED_ARCH=aarch64 ;; \
      *) MAPPED_ARCH=${TARGETARCH} ;; \
    esac && \
    echo "Using V8 download architecture: ${MAPPED_ARCH} based on TARGETARCH: ${TARGETARCH}" && \
    # Download V8 using mapped arch
    curl --fail -L -o /libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/libc_v8_${V8}_linux_${MAPPED_ARCH}.a

# Stage 3: Download Zig and Minisign
FROM base AS zig_download

ARG MINISIG
ARG ZIG
ARG ZIG_MINISIG
ARG TARGETARCH # Declare TARGETARCH to use it in this stage

# Install dependencies needed for Zig and Minisign install
RUN apt-get update -yq && \
    apt-get install -yq --no-install-recommends curl xz-utils ca-certificates

# Install Minisign and Zig
RUN case ${TARGETARCH} in \
      amd64) MAPPED_ARCH=x86_64 ;; \
      arm64) MAPPED_ARCH=aarch64 ;; \
      *) MAPPED_ARCH=${TARGETARCH} ;; \
    esac && \
    echo "Using mapped architecture: ${MAPPED_ARCH} based on TARGETARCH: ${TARGETARCH}" && \
    # install minisig
    curl --fail -L -O https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xvzf minisign-${MINISIG}-linux.tar.gz && \
    mv minisign-linux/${MAPPED_ARCH}/minisign /usr/local/bin/minisign && \
    rm -fr minisign-${MINISIG}-linux.tar.gz minisign-linux && \
    # install zig using mapped arch (MAPPED_ARCH)
    curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-linux-${MAPPED_ARCH}-${ZIG}.tar.xz && \
    curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-linux-${MAPPED_ARCH}-${ZIG}.tar.xz.minisig && \
    minisign -Vm zig-linux-${MAPPED_ARCH}-${ZIG}.tar.xz -P ${ZIG_MINISIG} && \
    tar xvf zig-linux-${MAPPED_ARCH}-${ZIG}.tar.xz && \
    mv zig-linux-${MAPPED_ARCH}-${ZIG} /zig

# Stage 4: Build stage
FROM base AS builder

ARG TARGETARCH # Declare TARGETARCH to use it in this stage

# Install build dependencies (removed xz-utils, kept curl for potential other uses)
RUN apt-get update -yq && \
    apt-get install -yq \
        python3 ca-certificates git \
        pkg-config libglib2.0-dev \
        gperf libexpat1-dev \
        cmake clang \
        curl git

# Copy installed Zig from the zig_download stage
COPY --from=zig_download /zig /usr/local/lib/zig
# Create the symlink in the builder stage
RUN ln -s /usr/local/lib/zig/zig /usr/local/bin/zig

# Copy source code
COPY --from=source /browser /browser
COPY --from=source /root/.gitconfig /root/.gitconfig

WORKDIR /browser

# Install build dependencies from source
RUN make install-libiconv
RUN make install-netsurf
RUN make install-mimalloc

# Place V8 library using mapped arch names for build system paths
COPY --from=v8_download /libc_v8.a /libc_v8.a
RUN case ${TARGETARCH} in \
      amd64) MAPPED_V8_BUILD_ARCH=x86_64 ;; \
      arm64) MAPPED_V8_BUILD_ARCH=aarch64 ;; \
      *) MAPPED_V8_BUILD_ARCH=${TARGETARCH} ;; \
    esac && \
    echo "Using V8 build architecture path: ${MAPPED_V8_BUILD_ARCH} based on TARGETARCH: ${TARGETARCH}" && \
    mkdir -p v8/build/${MAPPED_V8_BUILD_ARCH}-linux/release/ninja/obj/zig/ && \
    mkdir -p v8/build/${MAPPED_V8_BUILD_ARCH}-linux/debug/ninja/obj/zig/ && \
    cp /libc_v8.a v8/build/${MAPPED_V8_BUILD_ARCH}-linux/release/ninja/obj/zig/libc_v8.a && \
    cp /libc_v8.a v8/build/${MAPPED_V8_BUILD_ARCH}-linux/debug/ninja/obj/zig/libc_v8.a

# Build release
# Ensure git context is available for rev-parse
RUN zig build --release=safe -Doptimize=ReleaseSafe -Dgit_commit=$(git rev-parse --short HEAD)

# Stage 5: Final runtime stage
FROM base

# copy ca certificates
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# copy application binary
COPY --from=builder /browser/zig-out/bin/lightpanda /bin/lightpanda

EXPOSE 9222/tcp

CMD ["/bin/lightpanda", "serve", "--host", "0.0.0.0", "--port", "9222"]
