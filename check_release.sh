#!/bin/bash
set -euo pipefail

PREFIX="nas-flatcar"
CHANNEL=stable

UPSTREAM_TAG=$(set +o pipefail; git ls-remote --tags --sort='-v:refname' https://github.com/flatcar/scripts.git | grep -E "$CHANNEL-[0-9.]+$" | head -n1 | sed 's#.*refs/tags/##')

CONFIG_LINES="CONFIG_SCSI_TAPE=m;CONFIG_CHR_DEV_SG=m"
CONFIG_HASH=$(echo "$CONFIG_LINES" | sha256sum | cut -c1-8)
TAG="${PREFIX}-${UPSTREAM_TAG}-${CONFIG_HASH}"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Already built $TAG, skipping"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "Building $TAG (upstream $UPSTREAM_TAG)"
git clone --branch "$UPSTREAM_TAG" --depth 1 https://github.com/flatcar/scripts.git
cd scripts

./run_sdk_container ./build_packages --board=amd64-usr

DEFCONFIG=$(ls sdk_container/src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-* | head -n1)
for line in "CONFIG_SCSI_TAPE=m" "CONFIG_CHR_DEV_SG=m"; do
  grep -qxF "$line" "$DEFCONFIG" || echo "$line" >> "$DEFCONFIG"
done

./run_sdk_container bash -c '
  set -e
  rm -f /build/amd64-usr/var/tmp/portage/sys-kernel/coreos-modules-*/.compiled 2>/dev/null || true
  emerge-amd64-usr sys-kernel/coreos-modules
  emerge-amd64-usr sys-kernel/coreos-kernel
  ./build_image --board=amd64-usr
'

cd ..

BUILD_DIR="build/images/amd64-usr/latest"
echo "Build output directory contents:"
ls -la "$BUILD_DIR"

mkdir -p dist
for f in flatcar_production_update.gz flatcar_production_pxe.vmlinuz flatcar_production_pxe_image.cpio.gz; do
  if [[ ! -f "$BUILD_DIR/$f" ]]; then
    echo "Expected artifact missing: $BUILD_DIR/$f" >&2
    exit 1
  fi
  cp "$BUILD_DIR/$f" dist/
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "skip=false" >> "$GITHUB_OUTPUT"
  echo "tag=$TAG" >> "$GITHUB_OUTPUT"
  echo "upstream=$UPSTREAM_TAG" >> "$GITHUB_OUTPUT"
fi
