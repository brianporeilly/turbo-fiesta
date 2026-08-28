#!/bin/bash
set -e

export COREOS_OFFICIAL=1

rm -f /build/amd64-usr/var/tmp/portage/sys-kernel/coreos-modules-*/.compiled 2>/dev/null || true
emerge-amd64-usr sys-kernel/coreos-modules
emerge-amd64-usr sys-kernel/coreos-kernel
./build_image --board=amd64-usr

# Find the build output directory. It's a sibling of this checkout inside
# the container's mount namespace only -- there's no guarantee that holds
# on the host, so everything here operates container-side and copies into
# this checkout (which we know round-trips to the host) at the very end.
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

# build_image only produces the general-purpose image + bootloader files
# (flatcar_production_image.vmlinuz/.grub/.shim). PXE-specific artifacts
# need a separate, explicit format pass, written into the same directory
# so the rest of this script doesn't need to track a second location.
# --image_compression_formats=none since these are consumed directly by
# the netboot process, not something meant to be downloaded+decompressed.
./image_to_vm.sh --board=amd64-usr --format=pxe \
  --from="${BUILD_OUT}" --to="${BUILD_OUT}" \
  --image_compression_formats=none

echo "Full build output directory contents (after PXE generation):"
ls -la "$BUILD_OUT"

mkdir -p dist
MISSING=()

# flatcar_production_update.bin is the real update payload in current
# builds (older docs/tooling reference "flatcar_production_update.gz",
# but that name doesn't appear in actual build output any more -- .bin
# is its replacement). Do NOT use flatcar_test_update.gz -- that's signed
# with the test key, not something a real Nebraska/update_engine setup
# should trust. flatcar_production_update.bin.bz2 is a compressed copy
# of the same payload; .bin itself is what update tooling has historically
# consumed directly, so that's the one we ship.
#
# flatcar_production_pxe.vmlinuz + flatcar_production_pxe_image.cpio.gz
# are the direct kernel/initrd pair for iPXE. flatcar_production_pxe_grub.efi
# is an alternative GRUB-chainload path -- not required for a direct
# kernel+initrd iPXE menu entry, but cheap to keep around for flexibility.
for f in flatcar_test_update.gz flatcar_production_update.bin.bz2 flatcar_production_pxe.vmlinuz flatcar_production_pxe_image.cpio.gz flatcar_production_pxe_grub.efi; do
  if [[ -f "${BUILD_OUT}${f}" ]]; then
    cp "${BUILD_OUT}${f}" dist/
    echo "Collected: $f"
  else
    echo "Not found, skipping: ${BUILD_OUT}${f}" >&2
    MISSING+=("$f")
  fi
done

if [[ -f dist/flatcar_production_update.bin.bz2 ]]; then
  ( cd dist && sha256sum flatcar_production_update.bin.bz2 > flatcar_production_update.bin.bz2.sha256 )
  echo "Wrote checksum:"
  cat dist/flatcar_production_update.bin.bz2.sha256
fi
if [[ -f dist/flatcar_test_update.gz ]]; then
  ( cd dist && sha256sum flatcar_test_update.gz > flatcar_test_update.gz.sha256 )
  echo "Wrote checksum:"
  cat dist/flatcar_test_update.gz.sha256
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Missing artifacts: ${MISSING[*]}" >&2
  echo "(see the directory listing above for what was actually produced)" >&2
fi

echo "dist/ contents:"
ls -la dist/
