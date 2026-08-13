#!/bin/bash
set -e

rm -f /build/amd64-usr/var/tmp/portage/sys-kernel/coreos-modules-*/.compiled 2>/dev/null || true
emerge-amd64-usr sys-kernel/coreos-modules
emerge-amd64-usr sys-kernel/coreos-kernel
./build_image --board=amd64-usr

# Collect artifacts from inside the container. Build output is a sibling
# of this checkout inside the container's mount namespace only -- there's
# no guarantee that relationship holds on the host, so we copy into the
# checkout itself, which we know round-trips to the host.
FLATCAR_VERSION_INSIDE=$(grep "^FLATCAR_VERSION=" sdk_container/.repo/manifests/version.txt | cut -d= -f2)

shopt -s nullglob
MATCHES=(../build/images/amd64-usr/*"${FLATCAR_VERSION_INSIDE}"*/)
shopt -u nullglob

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "No build output directory found (container-side) matching version '${FLATCAR_VERSION_INSIDE}'" >&2
  echo "Contents of ../build/images/amd64-usr/:" >&2
  ls -la ../build/images/amd64-usr/ >&2 || echo "(directory does not exist)" >&2
  exit 1
elif [[ ${#MATCHES[@]} -gt 1 ]]; then
  echo "Multiple build output directories matched -- ambiguous:" >&2
  printf "%s\n" "${MATCHES[@]}" >&2
  exit 1
fi

BUILD_OUT="${MATCHES[0]}"
echo "Container-side build output: ${BUILD_OUT}"

mkdir -p dist
for f in flatcar_production_update.gz flatcar_production_pxe.vmlinuz flatcar_production_pxe_image.cpio.gz; do
  if [[ ! -f "${BUILD_OUT}${f}" ]]; then
    echo "Expected artifact missing: ${BUILD_OUT}${f}" >&2
    exit 1
  fi
  cp "${BUILD_OUT}${f}" dist/
done
