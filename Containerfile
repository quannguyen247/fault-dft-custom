FROM docker.io/library/swift:6.4.2-noble AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/build-python \
    && /opt/build-python/bin/pip install --no-cache-dir setuptools wheel
ENV PATH="/opt/build-python/bin:${PATH}"
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib --product fault -j 2 \
    && swift --version > /swift-version.txt
COPY setup.py requirements.txt Readme.md License ./
COPY fault ./fault
RUN spmFlags='-j 2' python3 -m pip wheel --no-deps --no-build-isolation . -w /wheels

FROM docker.io/library/ubuntu:24.04 AS build-tools
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl git g++ clang lld make cmake ninja-build bison flex gawk gperf \
    autoconf python3 pkg-config libffi-dev libreadline-dev zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

FROM build-tools AS tcl
WORKDIR /build/tcl
RUN curl -fL --retry 3 https://github.com/tcltk/tcl/archive/refs/tags/core-9-1-0.tar.gz \
    | tar -xz --strip-components=1
RUN cd unix && ./configure --prefix=/opt/tcl --enable-threads \
    && make -j 2 && make install

FROM build-tools AS iverilog
WORKDIR /build/iverilog
RUN curl -fL --retry 3 https://github.com/steveicarus/iverilog/archive/refs/tags/v13_0.tar.gz \
    | tar -xz --strip-components=1
RUN sh autoconf.sh && ./configure --prefix=/opt/iverilog \
    && make -j 2 && make install

# Yosys uses the Tcl 8.6 C ABI; the interactive Fault+ shell uses Tcl 9.1.
FROM build-tools AS tcl-compat
WORKDIR /build/tcl
RUN curl -fL --retry 3 https://github.com/tcltk/tcl/archive/refs/tags/core-8-6-18.tar.gz \
    | tar -xz --strip-components=1
RUN cd unix && ./configure --prefix=/opt/tcl-compat --enable-threads \
    && make -j 2 && make install

FROM build-tools AS yosys
COPY --from=tcl-compat /opt/tcl-compat /opt/tcl-compat
ENV PKG_CONFIG_PATH=/opt/tcl-compat/lib/pkgconfig
WORKDIR /build/yosys
RUN curl -fL --retry 3 https://github.com/YosysHQ/yosys/releases/download/v0.71/yosys.tar.gz | tar -xz
RUN cmake --preset release -G Ninja -DCMAKE_INSTALL_PREFIX=/opt/yosys \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
      -DBUILD_SHARED_LIBS=OFF -DYOSYS_ENABLE_UNIT_TESTS=OFF \
    && cmake --build build-rel --parallel 2 \
    && cmake --install build-rel --strip \
    && cp COPYING /opt/yosys/share/yosys/LICENSE \
    && cp abc/copyright.txt /opt/yosys/share/yosys/ABC-LICENSE
RUN mkdir -p /opt/yosys/share/yosys/licenses \
    && find libs abc -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -name copyright.txt \) \
       -exec cp --parents -t /opt/yosys/share/yosys/licenses {} +

FROM docker.io/library/ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-venv libpython3.12 libreadline8t64 libffi8 libatomic1 libcurl4t64 \
    libxml2 libsqlite3-0 libedit2 libbz2-1.0 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/python
COPY --from=tcl /opt/tcl /opt/tcl
COPY --from=tcl-compat /opt/tcl-compat /opt/tcl-compat
COPY --from=iverilog /opt/iverilog /opt/iverilog
COPY --from=yosys /opt/yosys /opt/yosys
ENV PATH="/opt/python/bin:/opt/tcl/bin:/opt/iverilog/bin:/opt/yosys/bin:${PATH}" \
    LD_LIBRARY_PATH=/opt/tcl/lib:/opt/tcl-compat/lib
RUN ln -s /opt/tcl/bin/tclsh9.1 /usr/local/bin/tclsh
COPY --from=build /wheels /wheels
COPY --from=build /swift-version.txt /swift-version.txt
COPY License OSAcknowledgements /usr/share/doc/fault/
COPY --from=iverilog /build/iverilog/COPYING /usr/share/doc/iverilog/COPYING
COPY --from=tcl /build/tcl/license.terms /usr/share/doc/tcl/license.terms
COPY --from=tcl-compat /build/tcl/license.terms /usr/share/doc/tcl-compat/license.terms
COPY faultplus /opt/faultplus
RUN python3 -m pip install --no-cache-dir pyverilog 'nl2bench==0.13.0' find_libpython \
    && python3 -m pip install --no-cache-dir --no-deps /wheels/*.whl /opt/faultplus \
    && rm -rf /wheels \
    && { cat /swift-version.txt; fault --version; faultplus --version; yosys -V; \
         iverilog -V 2>/dev/null | head -n 1; printf 'puts [info patchlevel]\n' | tclsh; } \
       > /opt/faultplus/VERSIONS.txt \
    && cat /opt/faultplus/VERSIONS.txt
ARG REVISION=local
LABEL org.opencontainers.image.source="https://github.com/quannguyen247/fault-plus" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0"
ENV HOME=/tmp TMPDIR=/tmp
WORKDIR /work
ENTRYPOINT ["faultplus"]
