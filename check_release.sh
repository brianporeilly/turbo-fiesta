#!/bin/bash
set -euo pipefail

PREFIX="nas-flatcar"
CHANNEL=stable
CONTAINER_NAME="nas-flatcar-build"

UPSTREAM_TAG=$(set +o pipefail; git ls-remote --tags --sort='-v:refname' https://github.com/flatcar/scripts.git | grep -E "$CHANNEL-[0-9.]+$" | head -n1 | sed 's#.*refs/tags/##')

CONFIG_LINES="CONFIG_CHR_DEV_ST=m;CONFIG_CHR_DEV_SG=m"
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

./run_sdk_container -n "$CONTAINER_NAME" ./build_packages --board=amd64-usr

DEFCONFIG=$(ls sdk_container/src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-* | head -n1)
for line in "CONFIG_CHR_DEV_ST=m" "CONFIG_CHR_DEV_SG=m"; do
  grep -qxF "$line" "$DEFCONFIG" || echo "$line" >> "$DEFCONFIG"
done

git config user.email "ci@example.com"
git config user.name "NAS Flatcar CI"
git add "$DEFCONFIG"
if ! git diff --cached --quiet; then
  git commit -m "Enable CHR_DEV_ST and CHR_DEV_SG"
else
  echo "Defconfig already contains desired lines, nothing to commit"
fi

./run_sdk_container -n "$CONTAINER_NAME" bash -c '
  set -e
  rm -f /build/amd64-usr/var/tmp/portage/sys-kernel/coreos-modules-*/.compiled 2>/dev/null || true
  emerge-amd64-usr sys-kernel/coreos-modules
  emerge-amd64-usr sys-kernel/coreos-kernel
  ./build_image --board=amd64-usr
'

cd ..

source scripts/sdk_container/.repo/manifests/version.txt

shopt -s nullglob
MATCHES=(build/images/amd64-usr/*"${FLATCAR_VERSION}"*/)
shopt -u nullglob

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "No build output directory found matching version '${FLATCAR_VERSION}'" >&2
  echo "Contents of build/images/amd64-usr/:" >&2
  ls -la build/images/amd64-usr/ >&2 || echo "(directory doesn't exist either)" >&2
  exit 1
elif [[ ${#MATCHES[@]} -gt 1 ]]; then
  echo "Multiple build output directories matched — ambiguous:" >&2
  printf '%s\n' "${MATCHES[@]}" >&2
  exit 1
fi

BUILD_DIR="${MATCHES[0]}"
echo "Found build output: $BUILD_DIR"
ls -la "$BUILD_DIR"

mkdir -p dist
for f in flatcar_production_update.gz flatcar_production_pxe.vmlinuz flatcar_production_pxe_image.cpio.gz; do
  if [[ ! -f "${BUILD_DIR}${f}" ]]; then
    echo "Expected artifact missing: ${BUILD_DIR}${f}" >&2
    exit 1
  fi
  cp "${BUILD_DIR}${f}" dist/
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "skip=false" >> "$GITHUB_OUTPUT"
  echo "tag=$TAG" >> "$GITHUB_OUTPUT"
  echo "upstream=$UPSTREAM_TAG" >> "$GITHUB_OUTPUT"
fi
