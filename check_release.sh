#!/bin/bash
set -euo pipefail

PREFIX="nas-flatcar"
CHANNEL=stable
CONTAINER_NAME="nas-flatcar-build"

# --- 0. Figure out how to run git: native, or containerized fallback ---

if command -v git >/dev/null 2>&1; then
  GIT_MODE=native
elif command -v podman >/dev/null 2>&1; then
  GIT_MODE=podman
elif command -v docker >/dev/null 2>&1; then
  GIT_MODE=docker
else
  echo "No git, podman, or docker found on this host -- cannot proceed" >&2
  exit 1
fi
echo "Using git mode: $GIT_MODE"

# Always run relative to $PWD -- for the containerized case this means
# "cd into the directory you want git to operate on before calling git_cmd".
git_cmd() {
  case "$GIT_MODE" in
    native)
      git -c safe.directory='*' "$@"
      ;;
    podman|docker)
      "$GIT_MODE" run --rm -v "$PWD":/workspace -w /workspace \
        docker.io/alpine/git -c safe.directory='*' "$@"
      ;;
  esac
}

# --- 1. Figure out what we'd be building, and whether we already have it ---

# grep|head triggers a harmless "Broken pipe" from grep once head is satisfied;
# pipefail would otherwise turn that into a (spurious) pipeline failure.
UPSTREAM_TAG=$(set +o pipefail; git_cmd ls-remote --tags --sort='-v:refname' \
  https://github.com/flatcar/scripts.git \
  | grep -E "$CHANNEL-[0-9.]+$" | head -n1 | sed 's#.*refs/tags/##')

if [[ -z "$UPSTREAM_TAG" ]]; then
  echo "Could not determine latest $CHANNEL tag from flatcar/scripts" >&2
  exit 1
fi

# Fingerprint the config change itself, so editing it later produces a new
# tag even if upstream's version hasn't moved.
CONFIG_LINES="CONFIG_CHR_DEV_ST=m;CONFIG_CHR_DEV_SG=m"
if command -v sha256sum >/dev/null 2>&1; then
  CONFIG_HASH=$(echo "$CONFIG_LINES" | sha256sum | cut -c1-8)
else
  # Minimal hosts (e.g. Flatcar itself) may not ship sha256sum -- cksum is
  # POSIX and near-universal, and this only needs to be stable, not secure.
  CONFIG_HASH=$(echo "$CONFIG_LINES" | cksum | cut -d' ' -f1)
fi
TAG="${PREFIX}-${UPSTREAM_TAG}-${CONFIG_HASH}"

# --- 2. Check whether we've already built this, if gh is available ---

if command -v gh >/dev/null 2>&1; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Already built $TAG, skipping"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "skip=true" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi
else
  echo "gh not found -- skipping 'already built' check, building unconditionally (local run)"
fi

echo "Building $TAG (upstream $UPSTREAM_TAG)"

# --- 3. Get a scripts/ checkout at the right tag, reusing one if present ---

if [[ -d scripts/.git ]]; then
  echo "Reusing existing scripts/ checkout, resetting to $UPSTREAM_TAG"
  cd scripts
  git_cmd fetch --depth 1 origin "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}" 2>/dev/null || true
  git_cmd checkout -f "$UPSTREAM_TAG"
  git_cmd clean -fdx
else
  git_cmd clone --branch "$UPSTREAM_TAG" --depth 1 https://github.com/flatcar/scripts.git
  cd scripts
fi

# --- 4. Apply the config change ---

DEFCONFIG=$(ls sdk_container/src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-* | head -n1)
for line in "CONFIG_CHR_DEV_ST=m" "CONFIG_CHR_DEV_SG=m"; do
  grep -qxF "$line" "$DEFCONFIG" || echo "$line" >> "$DEFCONFIG"
done

git_cmd add "$DEFCONFIG"
if ! git_cmd diff --cached --quiet; then
  git_cmd -c user.email="ci@example.com" -c user.name="NAS Flatcar CI" commit -m "Enable CHR_DEV_ST and CHR_DEV_SG"
else
  echo "Defconfig already contains desired lines, nothing to commit"
fi

# --- 5. Build. Same container name for both calls so the second call ---
# ---    reuses the package cache the first call just built.          ---

./run_sdk_container -n "$CONTAINER_NAME" ./build_packages --board=amd64-usr

# Only copy this in after the expensive step, so there's no chance of it
# affecting whatever build_packages uses to detect a changed working tree.
cp ../ci_build_steps.sh .
chmod +x ci_build_steps.sh

./run_sdk_container -n "$CONTAINER_NAME" bash ci_build_steps.sh

# --- 6. Bring the artifacts out to where the rest of the workflow expects them ---

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
