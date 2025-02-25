FROM ubuntu:22.04

ARG ZIG=0.13.0
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG OS=linux
ARG ARCH=x86_64
ARG V8=11.1.134
ARG ZIG_V8=v0.1.11

RUN apt-get update -yq && \
    apt-get install -yq xz-utils \
        python3 ca-certificates git \
        pkg-config libglib2.0-dev \
        gperf libexpat1-dev \
        cmake clang \
        curl git

# install minisig
RUN curl -L -O https://github.com/jedisct1/minisign/releases/download/0.11/minisign-0.11-linux.tar.gz && \
    tar xvzf minisign-0.11-linux.tar.gz

# install zig
RUN curl -O https://ziglang.org/download/${ZIG}/zig-linux-x86_64-${ZIG}.tar.xz && \
    curl -O https://ziglang.org/download/${ZIG}/zig-linux-x86_64-${ZIG}.tar.xz.minisig

RUN minisign-linux/x86_64/minisign -Vm zig-linux-x86_64-${ZIG}.tar.xz -P ${ZIG_MINISIG}

# clean minisg
RUN rm -fr minisign-0.11-linux.tar.gz minisign-linux

# install zig
RUN tar xvf zig-linux-x86_64-${ZIG}.tar.xz && \
    mv zig-linux-x86_64-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-linux-x86_64-${ZIG}/zig /usr/local/bin/zig

# clean up zig install
RUN rm -fr zig-linux-x86_64-${ZIG}.tar.xz zig-linux-x86_64-${ZIG}.tar.xz.minisig

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

RUN cd vendor/zig-js-runtime && \
    git submodule init && \
    git submodule update --recursive

RUN make install-libiconv && \
    make install-netsurf && \
    make install-mimalloc

# download and install v8
RUN curl -L -o libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/libc_v8_${V8}_${OS}_${ARCH}.a && \
    mkdir -p vendor/zig-js-runtime/vendor/v8/${ARCH}-${OS}/release && \
    mv libc_v8.a vendor/zig-js-runtime/vendor/v8/${ARCH}-${OS}/release/libc_v8.a

# build release
RUN make build

FROM ubuntu:22.04

# copy ca certificates
COPY --from=0 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=0 /browser/zig-out/bin/lightpanda /bin/lightpanda

EXPOSE 9222/tcp

CMD ["/bin/lightpanda", "serve", "--host", "0.0.0.0", "--port", "9222"]
