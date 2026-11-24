#!/usr/bin/env bash
# prepare-source.sh — fetch linux-7.0.14, apply patches, merge defconfig+fragment.
# Usage: ./scripts/prepare-source.sh --debian 13 --arch amd64 [--kernel-version 7.0.14]
set -euo pipefail

DEBIAN_VER="13"
ARCH="$(uname -m)"
KVER=""
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debian) DEBIAN_VER="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --kernel-version) KVER="$2"; shift 2;;
    --help|-h) sed -n '1,12p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$KVER" ]]; then
  # VERSION file holds e.g. "7.0.14-eaglercraftos1" — strip suffix
  KVER="$(cut -d- -f1 < "$ROOT/VERSION" | tr -d ' \n')"
fi
if [[ "$ARCH" == "x86_64" ]]; then ARCH="amd64"; fi
if [[ "$ARCH" == "aarch64" ]]; then ARCH="arm64"; fi
if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
  echo "error: --arch must be amd64 or arm64 (got $ARCH)" >&2; exit 2
fi

# kernel.org layout: v7.x for 7.0.x
MAJOR="$(echo "$KVER" | cut -d. -f1)"
TARBALL="linux-${KVER}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"

DLDIR="$ROOT/build/dl"
SRCDIR="$ROOT/build/linux-${KVER}"
mkdir -p "$DLDIR"

echo "[prepare] kernel $KVER arch=$ARCH debian=$DEBIAN_VER"
echo "[prepare] fetching $URL"
if [[ ! -f "$DLDIR/$TARBALL" ]]; then
  curl -fL --retry 3 --retry-delay 5 -o "$DLDIR/$TARBALL" "$URL" || {
    echo "error: could not download $URL" >&2
    echo "hint: if kernel.org has not published $KVER yet, bump VERSION to the closest published 7.0.x" >&2
    exit 1
  }
fi
sha256sum "$DLDIR/$TARBALL" | tee "$DLDIR/$TARBALL.sha256"

if [[ ! -d "$SRCDIR" ]]; then
  echo "[prepare] extracting…"
  tar -xJf "$DLDIR/$TARBALL" -C "$ROOT/build/"
fi
cd "$SRCDIR"

echo "[prepare] applying patches…"
for p in "$ROOT"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  echo "  - $(basename "$p")"
  patch -p1 --forward < "$p" || {
    echo "note: patch $(basename "$p") may already be applied; continuing"
  }
done

echo "[prepare] defconfig + fragment merge…"
if [[ "$ARCH" == "amd64" ]]; then
  make ARCH=x86_64 x86_64_defconfig
  FRAG="$ROOT/configs/config-amd64"
  KARCH="x86_64"
else
  make ARCH=arm64 defconfig
  FRAG="$ROOT/configs/config-arm64"
  KARCH="arm64"
fi
./scripts/kconfig/merge_config.sh -m -O . ./.config "$FRAG"
make ARCH="$KARCH" olddefconfig

echo "[prepare] effective LOCALVERSION / HZ / PREEMPT:"
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_HZ_[0-9]+=|CONFIG_PREEMPT|CONFIG_ZSWAP=|CONFIG_TCP_CONG_BBR=)' .config || true
echo "[prepare] OK: $SRCDIR/.config ready"
