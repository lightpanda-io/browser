FROM ubuntu:24.04

ARG MINISIG=0.12
ARG ZIG=0.14.1
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG ARCH=x86_64
ARG V8=13.6.233.8
ARG ZIG_V8=v0.1.24

RUN apt-get update -yq && \
    apt-get install -yq xz-utils \
        python3 ca-certificates git \
        pkg-config libglib2.0-dev \
        gperf libexpat1-dev \
        cmake clang \
        curl git

# install minisig
RUN curl --fail -L -O https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xvzf minisign-${MINISIG}-linux.tar.gz

# install zig
RUN curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-${ARCH}-linux-${ZIG}.tar.xz
RUN curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-${ARCH}-linux-${ZIG}.tar.xz.minisig

RUN minisign-linux/${ARCH}/minisign -Vm zig-${ARCH}-linux-${ZIG}.tar.xz -P ${ZIG_MINISIG}

# clean minisg
RUN rm -fr minisign-0.11-linux.tar.gz minisign-linux

# install zig
RUN tar xvf zig-${ARCH}-linux-${ZIG}.tar.xz && \
    mv zig-${ARCH}-linux-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-${ARCH}-linux-${ZIG}/zig /usr/local/bin/zig

# clean up zig install
RUN rm -fr zig-${ARCH}-linux-${ZIG}.tar.xz zig-${ARCH}-linux-${ZIG}.tar.xz.minisig

# force use of http instead of ssh with github
RUN cat <<EOF > /root/.gitconfig
[url "https://github.com/"]
    insteadOf="git@github.com:"
EOF

# clone lightpanda
RUN git clone git@github.com:lightpanda-io/browser.git

WORKDIR /browser

# install deps
RUN git submodule init && \
    git submodule update --recursive

RUN make install-libiconv && \
    make install-netsurf && \
    make install-mimalloc

# download and install v8
RUN curl --fail -L -o libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/libc_v8_${V8}_linux_${ARCH}.a && \
    mkdir -p v8/out/linux/release/obj/zig/ && \
    mv libc_v8.a v8/out/linux/release/obj/zig/libc_v8.a

# build release
RUN make build

FROM ubuntu:24.04

# copy ca certificates
COPY --from=0 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=0 /browser/zig-out/bin/lightpanda /bin/lightpanda

EXPOSE 9222/tcp

CMD ["/bin/lightpanda", "serve", "--host", "0.0.0.0", "--port", "9222"]
