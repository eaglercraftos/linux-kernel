#!/usr/bin/env bash
# make-repo.sh — turn built .debs (out/) into a signed APT repository (repo/).
#
# Suites follow Debian codenames: bookworm (12), trixie (13), forky (14).
# Each suite ships component `main` for amd64 + arm64. Packages are routed
# into suites by their ~debian<N> version suffix, so one pool/ serves all.
#
#   ./scripts/make-repo.sh --input out --output repo --gen-key
#   ./scripts/make-repo.sh --input out --output repo --sign-key DEADBEEF
#   ./scripts/make-repo.sh --input out --output repo --no-sign   # testing only
#
# Users then install with (example for trixie, repo hosted at $REPO_URL):
#   curl -fsSL $REPO_URL/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/eaglercraftos.gpg
#   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/eaglercraftos.gpg] $REPO_URL trixie main" \
#     | sudo tee /etc/apt/sources.list.d/eaglercraftos.sources
#   sudo apt update && sudo apt install -y linux-image-7.0.14-eaglercraftos
set -euo pipefail

INPUT="out"
OUTPUT="repo"
SUITES="bookworm trixie forky"
ARCHS="amd64 arm64"
ORIGIN="EaglercraftOS"
LABEL="linux-eaglercraftos"
SIGN_MODE="gen-key"   # gen-key | sign-key | no-sign
SIGN_KEY=""
KEY_NAME="EaglercraftOS APT repo"
KEY_EMAIL="repo@eaglercraftos.local"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '1,20p' "$0"
  echo ""
  echo "flags: --input DIR --output DIR --suites \"bookworm trixie forky\""
  echo "       --archs \"amd64 arm64\" --origin NAME --label NAME"
  echo "       --gen-key | --sign-key KEYID | --no-sign"
}

vernum_for() {
  case "$1" in
    bookworm) echo "12";; trixie) echo "13";; forky) echo "14";;
    *) echo "error: unknown suite $1" >&2; exit 2;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --suites) SUITES="$2"; shift 2;;
    --archs) ARCHS="$2"; shift 2;;
    --origin) ORIGIN="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --gen-key) SIGN_MODE="gen-key"; shift;;
    --sign-key) SIGN_MODE="sign-key"; SIGN_KEY="$2"; shift 2;;
    --no-sign) SIGN_MODE="no-sign"; shift;;
    --key-name) KEY_NAME="$2"; shift 2;;
    --key-email) KEY_EMAIL="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

for tool in dpkg-scanpackages gzip xz apt-ftparchive; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: missing required tool: $tool" >&2
    echo "hint: sudo apt install -y dpkg-dev apt gzip xz-utils" >&2
    exit 1
  }
done
if [[ "$SIGN_MODE" != "no-sign" ]]; then
  command -v gpg >/dev/null 2>&1 || { echo "error: gpg required for signing (or use --no-sign)" >&2; exit 1; }
fi
if [[ "$SIGN_MODE" == "sign-key" && -z "$SIGN_KEY" ]]; then
  echo "error: --sign-key needs a KEYID" >&2; exit 2
fi

INDIR="$ROOT/$INPUT"
OUTDIR="$ROOT/$OUTPUT"
if [[ ! -d "$INDIR" ]]; then echo "error: input dir not found: $INDIR" >&2; exit 1; fi
shopt -s nullglob
DEBS=("$INDIR"/*.deb)
if [[ "${#DEBS[@]}" == "0" ]]; then echo "error: no .deb files in $INDIR" >&2; exit 1; fi

echo "[repo] ${#DEBS[@]} .deb(s) from $INPUT -> $OUTPUT (suites: $SUITES / archs: $ARCHS)"
POOL="$OUTDIR/pool/main"
mkdir -p "$POOL"
for d in "${DEBS[@]}"; do cp -n "$d" "$POOL/" 2>/dev/null || cp "$d" "$POOL/"; done

export GNUPGHOME="${GNUPGHOME:-}"
GEN_HOME=""
if [[ "$SIGN_MODE" == "gen-key" ]]; then
  GEN_HOME="$(mktemp -d)"
  export GNUPGHOME="$GEN_HOME"
  echo "[repo] generating throwaway signing key ($KEY_EMAIL)…"
  gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: $KEY_NAME
Name-Email: $KEY_EMAIL
Expire-Date: 2y
EOF
  SIGN_KEY="$(gpg --batch --list-keys --with-colons "$KEY_EMAIL" | awk -F: '/^fpr:/{print $10; exit}')"
  echo "[repo] key: $SIGN_KEY"
  gpg --armor --export "$KEY_EMAIL" > "$OUTDIR/KEY.gpg"
fi

GPG_OPTS=()
if [[ -n "${GNUPGHOME:-}" ]]; then GPG_OPTS+=(--homedir "$GNUPGHOME"); fi

cd "$OUTDIR"
for suite in $SUITES; do
  ver="$(vernum_for "$suite")"
  for arch in $ARCHS; do
    bindir="dists/$suite/main/binary-$arch"
    mkdir -p "$bindir"
    # Full-arch scan, then keep only this suite's ~debian<N> packages.
    if dpkg-scanpackages --arch "$arch" pool/main /dev/null 2>/dev/null \
        | awk -v needle="~debian${ver}" 'BEGIN{RS="";ORS="\n\n"} index($0, needle){print}' \
        > "$bindir/Packages"; then
      :
    else
      : > "$bindir/Packages"   # empty but valid (no packages for suite/arch yet)
    fi
    gzip -9kf "$bindir/Packages"
    xz -6kf "$bindir/Packages"
    count="$(grep -c '^Package: ' "$bindir/Packages" || true)"
    echo "[repo] $suite/$arch: $count package(s)"
  done
  # Suite Release metadata.
  cat > "/tmp/eagler-release-$suite.conf" <<EOF
APT::FTPArchive::Release::Origin "$ORIGIN";
APT::FTPArchive::Release::Label "$LABEL";
APT::FTPArchive::Release::Suite "$suite";
APT::FTPArchive::Release::Codename "$suite";
APT::FTPArchive::Release::Architectures "$ARCHS";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "$LABEL 7.0.14 kernel packages for $suite";
EOF
  apt-ftparchive -c "/tmp/eagler-release-$suite.conf" release "dists/$suite" > "dists/$suite/Release"
  if [[ "$SIGN_MODE" != "no-sign" ]]; then
    gpg --batch --yes "${GPG_OPTS[@]}" --local-user "$SIGN_KEY" \
      --clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"
    gpg --batch --yes "${GPG_OPTS[@]}" --local-user "$SIGN_KEY" \
      -abs -o "dists/$suite/Release.gpg" "dists/$suite/Release"
  fi
done

if [[ -n "$GEN_HOME" ]]; then
  # Keep the throwaway secret key next to the repo for the demo; production
  # should use --sign-key with a long-lived key from a secret instead.
  gpg --batch --yes "${GPG_OPTS[@]}" --armor --export-secret-keys "$KEY_EMAIL" > "$OUTDIR/SIGNING-KEY-PRIVATE.asc" || true
  chmod 600 "$OUTDIR/SIGNING-KEY-PRIVATE.asc" || true
  export GNUPGHOME=""
  echo "[repo] WARNING: throwaway key material in $OUTPUT/SIGNING-KEY-PRIVATE.asc — re-sign with a real key for production."
fi

echo ""
echo "[repo] done: $OUTPUT/"
find "$OUTDIR" -maxdepth 4 -type f | sort
echo ""
if [[ "$SIGN_MODE" == "no-sign" ]]; then
  echo "UNSIGNED repo (testing only). Client line needs [trusted=yes]:"
  echo "  deb [trusted=yes arch=amd64] file://$OUTDIR trixie main"
else
  echo "Install (example: trixie, repo served at https://YOUR-HOST/):"
  echo "  curl -fsSL https://YOUR-HOST/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/eaglercraftos.gpg"
  echo "  echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/eaglercraftos.gpg] https://YOUR-HOST trixie main\" \\"
  echo "    | sudo tee /etc/apt/sources.list.d/eaglercraftos.sources"
  echo "  sudo apt update && sudo apt install -y linux-image-7.0.14-eaglercraftos"
fi
