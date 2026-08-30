# Build intel-media-driver (iHD) from a tagged release.
#
# Debian trixie ships 25.2.3 and sid ships 26.1.6, neither of which have
# intel/media-driver#1990. Without that fix, Arc A310 won't work without rebar,
# which isn't supported on the C240 M4. VA-API will crash because it assumes
# rebar and tries to map a region outside the visible 256MB window (small bar)
#
# Built against trixie, not sid. sid supplies libva 1.24, which looked like the
# closer match to Jellyfin's bundled 1.23 runtime - it isn't. A driver built
# against sid failed to load under the 1.23.0 runtime with "has no function
# __vaDriverInit_1_0": the fallback chain exhausted every version it knew about
# and found nothing, because compatibility only flows one direction. A newer
# libva runtime can fall back to an older driver's __vaDriverInit_<maj>_<min>
# symbol; it can't call a symbol from a driver built against a newer API than
# itself. trixie's libva is 1.22, below the runtime's 1.23, so the fallback
# actually reaches it.
#
# trixie's glibc (2.41) also matches the container's exactly, avoiding a
# separate GLIBC_2.xx-not-found failure sid can produce once it moves past the
# container's glibc version.
FROM debian:trixie AS build

ARG MEDIA_DRIVER_TAG=intel-media-26.3.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake g++ make pkg-config \
      libva-dev libdrm-dev libx11-dev libxext-dev libxfixes-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN git clone --depth 1 https://github.com/intel/gmmlib.git \
    && git clone --depth 1 --branch "$MEDIA_DRIVER_TAG" https://github.com/intel/media-driver.git

# CMAKE_POLICY_VERSION_MINIMUM: sid ships CMake 4.x, which dropped support for
# cmake_minimum_required(VERSION <3.5). Both projects still declare old minimums.
#
# gmmlib must be installed, not just present - media-driver locates it with
# pkg_check_modules(igdgmm), which reads igdgmm.pc. Installed to the image so
# the media-driver build finds it, and into /out so it ships alongside the
# driver, which links against libigdgmm.so at runtime.
RUN mkdir build_gmm && cd build_gmm \
    && cmake ../gmmlib \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/usr \
         -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && make -j"$(nproc)" \
    && make install \
    && make install DESTDIR=/out

RUN mkdir build_media && cd build_media \
    && cmake ../media-driver \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/usr \
         -DMEDIA_BUILD_FATAL_WARNINGS=OFF \
         -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out

RUN mkdir /dist \
    && find /out -name 'iHD_drv_video.so' -exec cp {} /dist/ \; \
    && find /out -name 'libigdgmm.so*' -exec cp -a {} /dist/ \; \
    && strip --strip-unneeded /dist/iHD_drv_video.so /dist/libigdgmm.so.*.* \
    && ls -l /dist

FROM scratch
COPY --from=build /dist /
