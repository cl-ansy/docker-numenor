#!/usr/bin/env bash
#
# Build the container that builds intel-media-driver,
# drop iHD_drv_video.so + libigdgmm into $OUTDIR.
#
# To use them, add to compose/jellyfin.yml:
#
#     environment:
#       LIBVA_DRIVERS_PATH: ${OUTDIR}
#       LD_LIBRARY_PATH: ${OUTDIR}
#     volumes:
#       - ${OUTDIR}:${OUTDIR}:ro
#
# LD_LIBRARY_PATH is needed so the driver finds the libigdgmm built with it,
# rather than an older one inside the image.
#
# then:
#
# docker exec -it jellyfin sh -c '/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128; echo exit=\$?'
#
# exit=0 with profiles listed means it worked. exit=135 is still SIGBUS.
# A GLIBC_2.xx-not-found error means the sid build is too new for the Jellyfin

set -euo pipefail

TAG="${MEDIA_DRIVER_TAG:-intel-media-26.3.1}"
OUTDIR="${OUTDIR:-/opt/iHD}"

cd "$(dirname "$0")"

echo "Building ${TAG} -> ${OUTDIR}"

sudo mkdir -p "$OUTDIR"
sudo docker build \
  --build-arg "MEDIA_DRIVER_TAG=${TAG}" \
  --output "type=local,dest=${OUTDIR}" \
  .

sudo chmod 0644 "${OUTDIR}"/*.so*
ls -l "${OUTDIR}"
