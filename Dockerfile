FROM debian:stable-slim

ARG MINISIG=0.12
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG V8=14.0.365.4
ARG ZIG_V8=v0.2.6
ARG TARGETPLATFORM

RUN apt-get update -yq && \
    apt-get install -yq xz-utils ca-certificates \
        pkg-config libglib2.0-dev \
        clang make curl git

# Get Rust
RUN curl https://sh.rustup.rs -sSf | sh -s -- --profile minimal -y
ENV PATH="/root/.cargo/bin:${PATH}"

# install minisig
RUN curl --fail -L -O https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xvzf minisign-${MINISIG}-linux.tar.gz -C /

# clone lightpanda
RUN git clone https://github.com/lightpanda-io/browser.git
WORKDIR /browser

# install zig
RUN ZIG=$(grep '\.minimum_zig_version = "' "build.zig.zon" | cut -d'"' -f2) && \
    case $TARGETPLATFORM in \
      "linux/arm64") ARCH="aarch64" ;; \
      *) ARCH="x86_64" ;; \
    esac && \
    curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-${ARCH}-linux-${ZIG}.tar.xz && \
    curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-${ARCH}-linux-${ZIG}.tar.xz.minisig && \
    /minisign-linux/${ARCH}/minisign -Vm zig-${ARCH}-linux-${ZIG}.tar.xz -P ${ZIG_MINISIG} && \
    tar xvf zig-${ARCH}-linux-${ZIG}.tar.xz && \
    mv zig-${ARCH}-linux-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-${ARCH}-linux-${ZIG}/zig /usr/local/bin/zig

# install deps
RUN git submodule init && \
    git submodule update --recursive

# download and install v8
RUN case $TARGETPLATFORM in \
    "linux/arm64") ARCH="aarch64" ;; \
    *) ARCH="x86_64" ;; \
    esac && \
    curl --fail -L -o libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/libc_v8_${V8}_linux_${ARCH}.a && \
    mkdir -p v8/ && \
    mv libc_v8.a v8/libc_v8.a

# build v8 snapshot
RUN zig build -Doptimize=ReleaseFast \
    -Dprebuilt_v8_path=v8/libc_v8.a \
    snapshot_creator -- src/snapshot.bin

# build release
RUN zig build -Doptimize=ReleaseFast \
    -Dsnapshot_path=../../snapshot.bin \
    -Dprebuilt_v8_path=v8/libc_v8.a \
    -Dgit_commit=$(git rev-parse --short HEAD)

FROM debian:stable-slim

RUN apt-get update -yq && \
    apt-get install -yq tini

FROM debian:stable-slim

# copy ca certificates
COPY --from=0 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=0 /browser/zig-out/bin/lightpanda /bin/lightpanda
COPY --from=1 /usr/bin/tini /usr/bin/tini

EXPOSE 9222/tcp

# Lightpanda install only some signal handlers, and PID 1 doesn't have a default SIGTERM signal handler.
# Using "tini" as PID1 ensures that signals work as expected, so e.g. "docker stop" will not hang.
# (See https://github.com/krallin/tini#why-tini).
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/lightpanda", "serve", "--host", "0.0.0.0", "--port", "9222", "--log_level", "info"]
