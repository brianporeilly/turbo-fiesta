#!/bin/bash
set -euo pipefail

PREFIX="nas-flatcar"
CHANNEL=stable
CONTAINER_NAME="nas-flatcar-build"

# --- 1. Figure out what we'd be building, and whether we already have it ---

# grep|head triggers a harmless "Broken pipe" from grep once head is satisfied;
# pipefail would otherwise turn that into a (spurious) pipeline failure.
UPSTREAM_TAG=$(set +o pipefail; git ls-remote --tags --sort='-v:refname' \
  https://github.com/flatcar/scripts.git \
  | grep -E "$CHANNEL-[0-9.]+$" | head -n1 | sed 's#.*refs/tags/##')

if [[ -z "$UPSTREAM_TAG" ]]; then
  echo "Could not determine latest $CHANNEL tag from flatcar/scripts" >&2
  exit 1
fi

# Fingerprint the config change itself, so editing it later produces a new
# tag even if upstream's version hasn't moved.
CONFIG_LINES="CONFIG_CHR_DEV_ST=m;CONFIG_CHR_DEV_SG=m"
CONFIG_HASH=$(echo "$CONFIG_LINES" | sha256sum | cut -c1-8)
TAG="${PREFIX}-${UPSTREAM_TAG}-${CONFIG_HASH}"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Already built $TAG, skipping"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "skip=true" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

echo "Building $TAG (upstream $UPSTREAM_TAG)"

# --- 2. Clone the target release and apply the config change ---

git clone --branch "$UPSTREAM_TAG" --depth 1 https://github.com/flatcar/scripts.git
cd scripts

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

# --- 3. Build. Same container name for both calls so the second call ---
# ---    reuses the package cache the first call just built.          ---

./run_sdk_container -n "$CONTAINER_NAME" ./build_packages --board=amd64-usr

cp ../ci_build_steps.sh .   # from inside scripts/, assuming both files started as siblings
chmod +x ci_build_steps.sh
./run_sdk_container -n "$CONTAINER_NAME" bash ci_build_steps.sh

# --- 4. Bring the artifacts out to where the rest of the workflow expects them ---

cd ..
mv scripts/dist ./dist
echo "Collected artifacts:"
ls -la dist/

for f in flatcar_production_update.gz flatcar_production_pxe.vmlinuz flatcar_production_pxe_image.cpio.gz; do
  if [[ ! -f "dist/$f" ]]; then
    echo "Artifact missing after copy-out: dist/$f" >&2
    exit 1
  fi
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "skip=false" >> "$GITHUB_OUTPUT"
  echo "tag=$TAG" >> "$GITHUB_OUTPUT"
  echo "upstream=$UPSTREAM_TAG" >> "$GITHUB_OUTPUT"
fi
