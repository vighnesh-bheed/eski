ARG BASE_IMAGE=docker.io/library/ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

FROM ${BASE_IMAGE} AS build
ARG BASE_IMAGE
ARG UBUNTU_SNAPSHOT=20261002T000000Z
ARG CA_CERTIFICATES_DEB=ca-certificates_20240203_all.deb
ARG CA_CERTIFICATES_SHA256=641de77d8f142cfd62a1a6f964ba67b20754d3337c480efb529d086075a06c9a
ARG ODIN_RELEASE=dev-2026-10
ARG ODIN_SHA256=c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab
ARG CLANG_VERSION=1:18.0-59~exp2
ARG CLANG_18_VERSION=1:18.1.3-1ubuntu1
ARG BINUTILS_VERSION=2.42-4ubuntu2.10
ARG LIBC6_VERSION=2.39-0ubuntu8.9
ARG OPENSSL_VERSION=3.0.13-0ubuntu3.16
ARG LIBUNWIND_VERSION=1.6.2-3build1.1
ARG LIBLZMA_VERSION=5.6.1+really5.4.5-1ubuntu0.3
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ADD --checksum=sha256:${CA_CERTIFICATES_SHA256} https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/pool/main/c/ca-certificates/${CA_CERTIFICATES_DEB} /tmp/ca-certificates.deb
ADD --checksum=sha256:${ODIN_SHA256} https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/odin-linux-amd64-${ODIN_RELEASE}.tar.gz /tmp/odin.tar.gz
RUN test "$(dpkg --print-architecture)" = amd64; \
    dpkg-deb --extract /tmp/ca-certificates.deb /tmp/ca-bootstrap; \
    mkdir -p /etc/ssl/certs; \
    cat /tmp/ca-bootstrap/usr/share/ca-certificates/mozilla/*.crt > /etc/ssl/certs/ca-certificates.crt; \
    rm -rf /tmp/ca-bootstrap /tmp/ca-certificates.deb /var/lib/apt/lists/* /etc/apt/sources.list /etc/apt/sources.list.d/*; \
    printf 'Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/%s/\nSuites: noble noble-updates noble-security\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "$UBUNTU_SNAPSHOT" > /etc/apt/sources.list.d/snapshot.sources; \
    apt-get -o APT::Update::Error-Mode=any update; \
    DPKG_DEB_THREADS_MAX=1 DEBIAN_FRONTEND=noninteractive nice -n 10 apt-get install -y --no-install-recommends \
        "clang=${CLANG_VERSION}" "clang-18=${CLANG_18_VERSION}" "binutils=${BINUTILS_VERSION}" \
        "libc6=${LIBC6_VERSION}" "libc6-dev=${LIBC6_VERSION}" \
        "libssl-dev=${OPENSSL_VERSION}" "libssl3t64=${OPENSSL_VERSION}" \
        "libunwind-dev=${LIBUNWIND_VERSION}" "libunwind8=${LIBUNWIND_VERSION}" \
        "liblzma-dev=${LIBLZMA_VERSION}" "liblzma5=${LIBLZMA_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir /opt/odin; \
    tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 --no-same-owner; \
    rm /tmp/odin.tar.gz; \
    test -x /opt/odin/odin; \
    test -f /opt/odin/LICENSE

WORKDIR /build
COPY src/ src/
COPY third_party/lua/ third_party/lua/
COPY tools/build_lua.sh tools/build_diagnostics.sh tools/source_digest.sh tools/
COPY LICENSE /out/doc/LICENSE
COPY THIRD_PARTY_NOTICES.md /out/doc/THIRD_PARTY_NOTICES.md
ARG BUILD_JOBS=2
ARG SOURCE_REVISION=unknown
ARG ESKI_VERSION=unknown
ARG ESKI_LICENSE=Apache-2.0
RUN nice -n 10 bash tools/build_lua.sh release; \
    nice -n 10 bash tools/build_diagnostics.sh release; \
    nice -n 10 /opt/odin/odin check src -vet -strict-style -thread-count:"${BUILD_JOBS}"; \
    nice -n 10 /opt/odin/odin build src -o:speed -thread-count:"${BUILD_JOBS}" -out:/out/eski; \
    mkdir -p /out/lib; \
    cp -L /usr/lib/x86_64-linux-gnu/libunwind.so.8 /out/lib/libunwind.so.8; \
    cp -L /usr/lib/x86_64-linux-gnu/liblzma.so.5 /out/lib/liblzma.so.5; \
    test "$(/out/eski -v | sed -n 's/.* license=//p')" = "$ESKI_LICENSE"; \
    if [ "$ESKI_VERSION" != unknown ]; then test "$(/out/eski -v)" = "eski v=${ESKI_VERSION} license=${ESKI_LICENSE}"; fi; \
    cp /opt/odin/LICENSE /out/doc/ODIN-LICENSE; \
    { \
        printf 'name=eski\n'; \
        printf 'version=%s\n' "$(/out/eski -v)"; \
        printf 'license=%s\n' "$ESKI_LICENSE"; \
        printf 'license_sha256=%s\n' "$(sha256sum /out/doc/LICENSE | cut -d' ' -f1)"; \
        printf 'notices_sha256=%s\n' "$(sha256sum /out/doc/THIRD_PARTY_NOTICES.md | cut -d' ' -f1)"; \
        printf 'binary_path=/usr/local/bin/eski\n'; \
        printf 'binary_sha256=%s\n' "$(sha256sum /out/eski | cut -d' ' -f1)"; \
        printf 'source_revision=%s\n' "$SOURCE_REVISION"; \
        printf 'source_sha256=%s\n' "$(bash tools/source_digest.sh)"; \
        printf 'lua_version=5.1.5\n'; \
        printf 'lua_source_archive_sha256=%s\n' "$(sha256sum third_party/lua/vendor/lua-5.1.5.tar.gz | cut -d' ' -f1)"; \
        printf 'lua_manifest_sha256=%s\n' "$(sha256sum third_party/lua/manifest.json | cut -d' ' -f1)"; \
        printf 'lua_library_sha256=%s\n' "$(sha256sum .build/lua/release/libeslua-runtime.a | cut -d' ' -f1)"; \
        printf 'lua_build_input_sha256=%s\n' "$(cat .build/lua/release/input.sha256)"; \
        printf 'diagnostics_source_sha256=%s\n' "$(sha256sum src/diagnostics_native/diagnostics.c | cut -d' ' -f1)"; \
        printf 'diagnostics_library_sha256=%s\n' "$(sha256sum .build/diagnostics/release/libeski-diagnostics.a | cut -d' ' -f1)"; \
        printf 'diagnostics_build_input_sha256=%s\n' "$(cat .build/diagnostics/release/input.sha256)"; \
        printf 'libunwind_sha256=%s\n' "$(sha256sum /out/lib/libunwind.so.8 | cut -d' ' -f1)"; \
        printf 'liblzma_sha256=%s\n' "$(sha256sum /out/lib/liblzma.so.5 | cut -d' ' -f1)"; \
        printf 'build_flags=-o:speed -thread-count:%s\n' "$BUILD_JOBS"; \
        printf 'check_flags=-vet -strict-style\n'; \
        printf 'odin_version=%s\n' "$(/opt/odin/odin version | awk '{print $NF}')"; \
        printf 'odin_release=%s\n' "$ODIN_RELEASE"; \
        printf 'odin_archive_sha256=%s\n' "$ODIN_SHA256"; \
        printf 'base_image=%s\n' "$BASE_IMAGE"; \
        printf 'ubuntu_snapshot=%s\n' "$UBUNTU_SNAPSHOT"; \
        printf 'ca_certificates_sha256=%s\n' "$CA_CERTIFICATES_SHA256"; \
        dpkg-query -W -f='package.${Package}=${Version}\n' clang clang-18 binutils libc6 libc6-dev libssl-dev libssl3t64 libunwind-dev libunwind8 liblzma-dev liblzma5; \
    } > /out/doc/build-info.txt; \
    chmod 0755 /out/eski; \
    chmod 0644 /out/doc/*

FROM ${BASE_IMAGE} AS runtime
ARG BASE_IMAGE
ARG SOURCE_REVISION=unknown
ARG ESKI_VERSION=unknown
ARG ESKI_LICENSE=Apache-2.0
LABEL org.opencontainers.image.title="eski" \
      org.opencontainers.image.description="Eski, a Redis compatible in-memory data store" \
      org.opencontainers.image.version="${ESKI_VERSION}" \
      org.opencontainers.image.licenses="${ESKI_LICENSE}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"
RUN groupadd --gid 10001 eski && \
    useradd --uid 10001 --gid 10001 --no-log-init --no-create-home --home-dir /data --shell /usr/sbin/nologin eski && \
    mkdir /data && \
    chown 10001:10001 /data
COPY --from=build /out/eski /usr/local/bin/eski
COPY --from=build /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=build /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=build /out/lib/ /usr/lib/x86_64-linux-gnu/
COPY --from=build /usr/share/doc/libssl3t64/copyright /usr/share/doc/eski/OPENSSL-COPYRIGHT
COPY --from=build /usr/share/doc/libunwind8/copyright /usr/share/doc/eski/LIBUNWIND-COPYRIGHT
COPY --from=build /usr/share/doc/liblzma5/copyright /usr/share/doc/eski/LIBLZMA-COPYRIGHT
COPY --from=build /out/doc/ /usr/share/doc/eski/
RUN ["/usr/local/bin/eski", "-v"]
WORKDIR /data
USER 10001:10001
VOLUME ["/data"]
EXPOSE 6399
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/eski"]
