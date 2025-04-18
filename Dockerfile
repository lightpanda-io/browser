FROM ubuntu:24.04

ARG MINISIG=0.12
ARG ZIG=0.14.0
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG ZIG_V8=v0.1.17

RUN apt-get update -yq && \
    apt-get install -yq xz-utils \
        python3 ca-certificates git \
        pkg-config libglib2.0-dev \
        gperf libexpat1-dev \
        cmake clang \
        curl git gh

# install minisig
RUN curl --fail -L -O https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xvzf minisign-${MINISIG}-linux.tar.gz

# install zig
RUN curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-linux-$( uname -m )-${ZIG}.tar.xz
RUN curl --fail -L -O https://ziglang.org/download/${ZIG}/zig-linux-$( uname -m )-${ZIG}.tar.xz.minisig

RUN minisign-linux/$( uname -m )/minisign -Vm zig-linux-$( uname -m )-${ZIG}.tar.xz -P ${ZIG_MINISIG}

# clean minisg
RUN rm -fr minisign-0.11-linux.tar.gz minisign-linux

# install zig
RUN tar xvf zig-linux-$( uname -m )-${ZIG}.tar.xz && \
    mv zig-linux-$( uname -m )-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-linux-$( uname -m )-${ZIG}/zig /usr/local/bin/zig

# clean up zig install
RUN rm -fr zig-linux-$( uname -m )-${ZIG}.tar.xz zig-linux-$( uname -m )-${ZIG}.tar.xz.minisig

# force use of http instead of ssh with github
RUN cat <<EOF > /root/.gitconfig
[url "https://github.com/"]
    insteadOf="git@github.com:"
EOF

# clone lightpanda
COPY . /browser

WORKDIR /browser

RUN make install-libiconv && \
    make install-netsurf && \
    make install-mimalloc

# download and install v8
RUN gh release download -R lightpanda-io/zig-v8-fork ${ZIG_V8} --pattern '*_linux_$( uname -m ).a' -O libc_v8.a && \
    mkdir -p v8/build/$( uname -m )-linux/release/ninja/obj/zig/ && \
    mkdir -p v8/build/$( uname -m )-linux/debug/ninja/obj/zig/ && \
    cp libc_v8.a v8/build/$( uname -m )-linux/release/ninja/obj/zig/libc_v8.a && \
    cp libc_v8.a v8/build/$( uname -m )-linux/debug/ninja/obj/zig/libc_v8.a && \

# build release
RUN zig build --release=safe -Doptimize=ReleaseSafe -Dgit_commit=$(git rev-parse --short HEAD)

FROM ubuntu:24.04

# copy ca certificates
COPY --from=0 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=0 /browser/zig-out/bin/lightpanda /bin/lightpanda

EXPOSE 9222/tcp

CMD ["/bin/lightpanda", "serve", "--host", "0.0.0.0", "--port", "9222"]
