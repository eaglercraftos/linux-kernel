# linux-kernel

Custom Linux kernel based on **Linux 7.0.14** for **amd64 (x86_64)** and **arm64 (aarch64)**,
packaged as Debian `.deb` files for **Debian 12 (bookworm), 13 (trixie), 14 (forky)** —
plus a signed **APT package repo** so targets can `apt install` the kernel.

Docker images are codename-pinned: `debian:bookworm-slim`, `debian:trixie-slim`,
`debian:forky-slim` (native arch, see `docker/` for pre-baked builder images).

CI builds natively on GitHub Actions:
- `amd64` → `runs-on: ubuntu-24.04`
- `arm64` → `runs-on: ubuntu-24.04-arm`

No QEMU / no cross-compiler: each job runs in a native `debian:<codename>-slim`
container on the matching runner arch.

## Layout (copy `src/*` in this editor to your git repo root,
then move `github-workflows/build.yml` to `.github/workflows/build.yml`)

```
scripts/build.sh               one-shot builder (docker or bare metal)
scripts/prepare-source.sh      fetch 7.0.14 + verify + apply patches + defconfig merge
scripts/make-repo.sh           build signed APT repo from out/*.deb (-> repo/)
configs/config-amd64           Kconfig fragment for amd64 (merged over defconfig)
configs/config-arm64           Kconfig fragment for arm64
patches/0001-*.patch           LOCALVERSION + EaglercraftOS defaults
docker/Dockerfile.bookworm     builder image: eaglercraftos-builder:bookworm
docker/Dockerfile.trixie       builder image: eaglercraftos-builder:trixie
docker/Dockerfile.forky        builder image: eaglercraftos-builder:forky
github-workflows/build.yml     -> install as .github/workflows/build.yml (build + repo jobs)
out/                           build output (*.deb, *.buildinfo, *.changes) [gitignored]
repo/                          APT repo (KEY.gpg, dists/<suite>/, pool/) [generated]
```

## Quick start (local, with docker)

`--debian` accepts numbers or codenames (`12|bookworm`, `13|trixie`, `14|forky`):

```bash
# Debian 13 (trixie), native arch:
./scripts/build.sh --debian trixie --arch amd64

# Explicit everything, 8 jobs:
./scripts/build.sh --debian 12 --arch arm64 --jobs 8

# Bare metal on a Debian bookworm/trixie/forky host (no docker):
./scripts/build.sh --debian forky --arch amd64 --no-docker

# With your own pre-baked builder image (docker/Dockerfile.*):
docker build -f docker/Dockerfile.trixie -t eaglercraftos-builder:trixie .
./scripts/build.sh --debian trixie --arch amd64 --image eaglercraftos-builder:trixie
```

Output lands in `out/`:
`linux-image-7.0.14-eaglercraftos_7.0.14-eaglercraftos1~debian13_amd64.deb`,
`linux-headers-...deb`, `linux-libc-dev_...deb`.

Install on target (single machine):

```bash
sudo dpkg -i out/linux-image-*.deb out/linux-headers-*.deb
sudo update-grub   # amd64 only; arm64 uses flash-kernel / u-boot / EFI stub as appropriate
sudo reboot
```

Suggested cmdline for quiet kiosk/browser boxes (in `/etc/default/grub` or extlinux):
`loglevel=4 quiet splash zswap.enabled=1 zswap.compressor=zstd`

## APT package repo

Build a signed repo from any set of built debs (suites are split by the
`~debian<N>` version suffix, so one `pool/` serves bookworm + trixie + forky):

```bash
./scripts/build.sh --debian bookworm --arch amd64   # repeat per combo…
./scripts/build.sh --debian trixie  --arch amd64
./scripts/make-repo.sh --input out --output repo --gen-key
```

Host `repo/` on any static file server (GitHub Pages, nginx, …). Clients:

```bash
# Suite = bookworm | trixie | forky to match the target's Debian release.
curl -fsSL https://YOUR-HOST/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/eaglercraftos.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/eaglercraftos.gpg] https://YOUR-HOST trixie main" \
  | sudo tee /etc/apt/sources.list.d/eaglercraftos.sources
sudo apt update && sudo apt install -y linux-image-7.0.14-eaglercraftos
```

Notes:
- `--gen-key` makes a throwaway key and exports `repo/KEY.gpg` (plus
  `repo/SIGNING-KEY-PRIVATE.asc` — delete/replace for production).
- Production: store a long-lived key as the `REPO_GPG_PRIVATE_KEY` repo secret —
  CI's `repo` job imports it and signs with `--sign-key` automatically.
- `--no-sign` builds an unsigned repo for lab testing only
  (`deb [trusted=yes] …` on the client).

## Versioning

- Upstream: `7.0.14` from `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.14.tar.xz`
- Debian pkg version: `7.0.14-eaglercraftos1~debian<12|13|14>`
- Kernel release string (`uname -r`): `7.0.14-eaglercraftos`
- Tag releases as `v7.0.14-eaglercraftos1` — the workflow attaches all six `.deb` sets
  plus `apt-repo.tar.gz` to the GitHub Release.

## What is tuned vs vanilla 7.0.14?

See `SPEC.md` + the two `configs/` fragments. Summary: `LOCALVERSION=-eaglercraftos`,
1000 Hz + voluntary preempt on amd64, full preempt on arm64, zswap/zstd + zram,
BBRv3 + FQ_CODEL, SquashFS/OverlayFS/exFAT/NTFS3 built in, USB/gamepad/serial,
modern DRM/i915/amdgpu/nouveau/v3d/vc4/panfrost bits kept as modules, debug spam off.

No proprietary blobs are added. Firmware comes from stock Debian
`firmware-linux` / `firmware-sof-signed` packages.

## CI

`.github/workflows/build.yml` defines 6 native build jobs + 1 repo job:

| debian   | arch  | runs-on           | container              |
|----------|-------|-------------------|------------------------|
| bookworm | amd64 | ubuntu-24.04      | debian:bookworm-slim   |
| trixie   | amd64 | ubuntu-24.04      | debian:trixie-slim     |
| forky    | amd64 | ubuntu-24.04      | debian:forky-slim      |
| bookworm | arm64 | ubuntu-24.04-arm  | debian:bookworm-slim   |
| trixie   | arm64 | ubuntu-24.04-arm  | debian:trixie-slim     |
| forky    | arm64 | ubuntu-24.04-arm  | debian:forky-slim      |

Each build job runs `scripts/build.sh --debian <codename> --arch <a> --no-docker`
inside the container (the runner already matches the arch), then uploads
`out/*.deb` as `eaglercraftos-7.0.14-<codename>-<arch>`. The `repo` job merges all
debs, runs `make-repo.sh` (real key from `REPO_GPG_PRIVATE_KEY` secret, else a
throwaway `--gen-key`), and uploads the `apt-repo` artifact.

## Reproducibility notes

- `KBUILD_BUILD_TIMESTAMP` is pinned to the `SOURCE_DATE_EPOCH` exported by
  `build.sh` (git tag date, else fixed fallback) so repeated builds agree.
- `prepare-source.sh` prints the tarball sha256 it downloaded; pin it in your
  fork once kernel.org publishes 7.0.14 digests.
- ccache is used automatically when installed (`CC="ccache gcc"`).
