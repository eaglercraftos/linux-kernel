#!/usr/bin/env bash
# build.sh — one-shot linux-eaglercraftos builder for Debian 12/13/14 × amd64/arm64.
# Docker images are codename-pinned: debian:bookworm-slim, debian:trixie-slim,
# debian:forky-slim (native arch). CI runs these on ubuntu-24.04 (amd64) or
# ubuntu-24.04-arm (arm64) runners.
#
#   ./scripts/build.sh --debian trixie --arch amd64
#   ./scripts/build.sh --debian 12 --arch arm64 --jobs 8 --output out
#   ./scripts/build.sh --debian forky --arch amd64 --image eaglercraftos-builder:forky
#   ./scripts/build.sh --print-deps --debian bookworm
set -euo pipefail

DEBIAN_INPUT="trixie"
ARCH="$(uname -m)"
JOBS="$(nproc 2>/dev/null || echo 4)"
OUTDIR="out"
KVER=""
IMAGE=""
NO_DOCKER=0
PRINT_DEPS=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '1,11p' "$0"
  echo ""
  echo "flags: --debian 12|13|14|bookworm|trixie|forky (default: trixie)"
  echo "       --arch amd64|arm64  --jobs N  --output DIR"
  echo "       --kernel-version 7.0.14  --image NAME  --no-docker  --print-deps  --help"
  echo ""
  echo "docker images: debian:bookworm-slim  debian:trixie-slim  debian:forky-slim"
  echo "custom builder images: docker/Dockerfile.{bookworm,trixie,forky}"
  echo "  docker build -f docker/Dockerfile.trixie -t eaglercraftos-builder:trixie ."
}

codename_for() {
  case "$1" in
    12|bookworm) echo "bookworm";;
    13|trixie) echo "trixie";;
    14|forky) echo "forky";;
    *) echo "error: --debian must be 12|13|14 or bookworm|trixie|forky (got $1)" >&2; return 1;;
  esac
}

vernum_for() {
  case "$1" in
    bookworm) echo "12";;
    trixie) echo "13";;
    forky) echo "14";;
    *) echo "$1";;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debian) DEBIAN_INPUT="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --jobs|-j) JOBS="$2"; shift 2;;
    --output|-o) OUTDIR="$2"; shift 2;;
    --kernel-version) KVER="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --no-docker) NO_DOCKER=1; shift;;
    --print-deps) PRINT_DEPS=1; shift;;
    --help|-h) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

CODENAME="$(codename_for "$DEBIAN_INPUT")" || exit 2
DEBIAN_VER="$(vernum_for "$CODENAME")"
if [[ -z "$IMAGE" ]]; then IMAGE="debian:${CODENAME}-slim"; fi

case "$ARCH" in x86_64) ARCH="amd64";; aarch64) ARCH="arm64";; esac
case "$(uname -m)" in x86_64) HOST="amd64";; aarch64) HOST="arm64";; *) HOST="$(uname -m)";; esac
if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then echo "error: --arch must be amd64|arm64" >&2; exit 2; fi

if [[ -z "$KVER" ]]; then KVER="$(cut -d- -f1 < "$ROOT/VERSION" | tr -d ' \n')"; fi
# e.g. 7.0.14-eaglercraftos1~debian13
KDEB_PKGVERSION="${KVER}-eaglercraftos1~debian${DEBIAN_VER}"

deps_for() {
  local v="$1"
  local base="build-essential bc bison flex libssl-dev libelf-dev libncurses-dev dwarves pahole zstd debhelper rsync kmod cpio python3 perl git curl xz-utils tar patch"
  # forky needs newer toolchain bits explicitly; bookworm/trixie stock gcc is fine.
  if [[ "$v" == "14" ]]; then echo "$base gcc-14 g++-14"; else echo "$base"; fi
}

if [[ "$PRINT_DEPS" == "1" ]]; then deps_for "$DEBIAN_VER"; exit 0; fi

if [[ "$ARCH" != "$HOST" ]]; then
  echo "error: native build only — host is $HOST but --arch=$ARCH." >&2
  echo "hint: run the arm64 build on an ubuntu-24.04-arm runner (or arm64 box)," >&2
  echo "      and the amd64 build on ubuntu-24.04. No QEMU." >&2
  exit 1
fi

echo "[build] linux-eaglercraftos $KVER debian=$CODENAME($DEBIAN_VER) arch=$ARCH jobs=$JOBS"
echo "[build] image=$IMAGE pkgversion=$KDEB_PKGVERSION"

if [[ "$NO_DOCKER" == "0" && -f /.dockerenv ]] || [[ "$NO_DOCKER" == "0" && "${IN_DOCKER:-0}" == "1" ]]; then
  NO_DOCKER=1
fi

if [[ "$NO_DOCKER" == "0" ]]; then
  # Re-exec ourselves inside the matching codename container (native arch image).
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found. Re-run with --no-docker on a Debian $CODENAME host," >&2
    echo "       or install docker." >&2; exit 1
  fi
  echo "[build] entering $IMAGE container (native $ARCH)…"
  docker run --rm \
    -v "$ROOT:/work" -w /work \
    -e IN_DOCKER=1 \
    "$IMAGE" \
    bash -c "apt-get update -qq && apt-get install -y -qq $(deps_for "$DEBIAN_VER") >/dev/null && chmod +x scripts/*.sh && ./scripts/build.sh --debian $CODENAME --arch $ARCH --jobs $JOBS --output $OUTDIR --kernel-version $KVER --no-docker"
  exit $?
fi

echo "[build] installing build deps ($CODENAME)…"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq $(deps_for "$DEBIAN_VER")
fi

bash "$ROOT/scripts/prepare-source.sh" --debian "$DEBIAN_VER" --arch "$ARCH" --kernel-version "$KVER"

SRCDIR="$ROOT/build/linux-${KVER}"
cd "$SRCDIR"

if command -v ccache >/dev/null 2>&1; then
  export CC="ccache gcc" CXX="ccache g++"
  ccache --max-size=5G >/dev/null 2>&1 || true
fi

# Reproducible timestamp: tag date if available, else fixed fallback.
if git -C "$ROOT" log -1 --format=%ct >/dev/null 2>&1; then
  export SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
else
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
fi
export KBUILD_BUILD_USER=eaglercraftos
export KBUILD_BUILD_HOST="${CODENAME}-${ARCH}"
export KDEB_PKGVERSION

if [[ "$ARCH" == "amd64" ]]; then KARCH="x86_64"; else KARCH="arm64"; fi

echo "[build] make ARCH=$KARCH -j$JOBS bindeb-pkg…"
if ! make ARCH="$KARCH" -j"$JOBS" bindeb-pkg; then
  echo "[build] bindeb-pkg failed, trying deb-pkg…"
  make ARCH="$KARCH" -j"$JOBS" deb-pkg
fi

mkdir -p "$ROOT/$OUTDIR"
# deb-pkg drops files one level above src; collect them.
mv ../*.deb ../*.buildinfo ../*.changes "$ROOT/$OUTDIR/" 2>/dev/null || true
cp .config "$ROOT/$OUTDIR/config-${KVER}-eaglercraftos-${ARCH}-${CODENAME}" || true

echo "[build] artifacts in $OUTDIR/:"
ls -lh "$ROOT/$OUTDIR/"
( cd "$ROOT/$OUTDIR" && sha256sum ./* > SHA256SUMS && cat SHA256SUMS )
echo "[build] done — install with: sudo dpkg -i $OUTDIR/linux-image-*.deb $OUTDIR/linux-headers-*.deb"
echo "[build] ... or add them to the APT repo: ./scripts/make-repo.sh --input $OUTDIR --output repo --gen-key"
