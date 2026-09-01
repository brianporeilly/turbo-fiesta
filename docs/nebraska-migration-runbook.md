# Migrating a Flatcar node to the `nas-stable` track

Use this for any node currently on stock/official Flatcar that needs to move
onto the custom build (tape modules + official ZFS/Podman/containerd sysexts).

## 0. Prerequisites

- SSH access to the target node as `core`, with sudo.
- The custom build's artifacts are already published as a GH release, and a
  matching package + channel + group (`nas-stable`) already exists in your
  self-hosted Nebraska instance, pointing at those release assets.

## 1. Trust the dev signing key (one-time, per node, before its first switch)

Custom builds are signed with Flatcar's open-source **dev key**, not the
official production key -- the production key requires physical HSM access
that isn't available outside Flatcar's own release infrastructure. A stock
node only trusts the official key by default, so the very first update onto
this track will fail signature verification unless this is done first.

```bash
curl -fsSL -o /tmp/devkey.pem \
  https://raw.githubusercontent.com/flatcar-linux/coreos-overlay/main/coreos-base/coreos-au-key/files/developer-v1.pub.pem
sudo umount /usr/share/update_engine/update-payload-key.pub.pem 2>/dev/null || true
sudo mount --bind /tmp/devkey.pem /usr/share/update_engine/update-payload-key.pub.pem
sudo systemctl restart update-engine
```

This bind mount only needs to survive long enough for the *upcoming* update to
verify and apply -- it does not need to persist across reboots. Once the node
is actually running a custom-built image, that image should carry the dev key
natively for verifying its *own* future updates. Worth explicitly confirming
this the first time (see step 5) rather than assuming it, since it hasn't
been independently verified end-to-end yet.

## 2. Point the node at your Nebraska instance and the `nas-stable` group

```bash
sudo tee /etc/flatcar/update.conf > /dev/null <<'EOF'
GROUP=nas-stable
SERVER=https://<your-nebraska-instance>/v1/update/
EOF
sudo systemctl restart update-engine
```

## 3. Trigger the update

```bash
update_engine_client -update
update_engine_client -status
```

Watch `CURRENT_OP` until it reaches `UPDATE_STATUS_UPDATED_NEED_REBOOT`. If it
goes back to `IDLE` with no progress, or `-status` doesn't show what you
expect, check the real error immediately rather than retrying blind:

```bash
journalctl -u update-engine -n 100 --no-pager
```

## 4. Reboot

```bash
sudo reboot
```

## 5. Verify

```bash
grep '^VERSION=' /etc/os-release          # should show your custom build's version string
uname -r                                   # should match this build's kernel

# Tape modules
modinfo st
modinfo sg
sudo modprobe st && sudo modprobe sg
lsmod | grep -E '^st |^sg '

# Sysexts (zfs / podman / containerd-flatcar)
systemd-sysext status

# Update mechanism health, and whether the dev key persisted natively
update_engine_client -status
sudo umount /usr/share/update_engine/update-payload-key.pub.pem 2>/dev/null && \
  echo "dev key was still bind-mounted (unexpected -- investigate)" || \
  echo "no leftover bind mount (expected)"
```

If a *future* update on this same node fails signature verification again,
that means the running image did **not** carry the dev key natively as
expected -- repeat step 1 on this node and flag it, since that would mean the
"one-time per node" assumption in this runbook is wrong.

## Known gotchas from getting this pipeline working

- **`FLATCAR_VERSION` must be clean (no `+timestamp`/`+hash` suffix) for
  official sysexts to resolve** -- otherwise sysext downloads 404 against
  Flatcar's real infrastructure, since it looks up a URL keyed on the exact
  version string.
- **`FLATCAR_BUILD_ID` must still be a real, non-empty value even when
  `FLATCAR_VERSION` is clean** -- an empty `BUILD_ID` on disk (not just an
  unsuffixed version) triggers `build_sysext`'s own dev-rebuild fallback
  comparison, which will never match and fails the build with "Version
  mismatch between board flatcar release and SDK container flatcar release."
  Both conditions have to be satisfied together.
- **`version.txt` must be patched from *inside* the SDK container**, in
  `ci_build_steps.sh`, not on the host between `run_sdk_container` calls --
  `run_sdk_container` rewrites that file fresh on every invocation, so a
  host-side edit gets silently overwritten before the build ever sees it.
