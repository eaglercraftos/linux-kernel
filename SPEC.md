# SPEC — linux-eaglercraftos

## 1. Identity

- Name: `linux-eaglercraftos`
- Base: Linux `7.0.14` (tarball `linux-7.0.14.tar.xz` from kernel.org `v7.x`)
- `EXTRAVERSION` / local: `-eaglercraftos` → `uname -r` = `7.0.14-eaglercraftos`
- Debian pkg revision: `1~debian<12|13|14>` → e.g. `7.0.14-eaglercraftos1~debian13`
- Architectures built: `amd64`, `arm64` (both native, never cross-compiled in CI)

## 2. Target matrix

- Build hosts (GitHub Actions, exact label strings):
  - amd64 jobs: `ubuntu-24.04`
  - arm64 jobs: `ubuntu-24.04-arm`
- Build containers (codename-pinned docker images): `debian:bookworm-slim`,
  `debian:trixie-slim`, `debian:forky-slim`
  (bookworm = 12, trixie = 13, forky = 14; custom pre-baked equivalents:
  `eaglercraftos-builder:bookworm|trixie|forky` from `docker/Dockerfile.*`)
- Outputs per cell: `linux-image`, `linux-headers`, `linux-libc-dev` (.deb + buildinfo + changes)

## 3. Builder contract (`scripts/build.sh`)

Flags: `--debian 12|13|14|bookworm|trixie|forky` (default trixie),
`--arch amd64|arm64` (default native),
`--jobs N` (default nproc), `--output DIR` (default `out/`),
`--kernel-version X.Y.Z` (default from `VERSION`), `--image NAME`
(override docker image, default `debian:<codename>-slim`), `--no-docker`,
`--print-deps`, `--help`.

Must:
1. Refuse arch/host mismatch (`uname -m` vs `--arch`) with a clear error.
2. Install deps: `build-essential bc bison flex libssl-dev libelf-dev dwarves
   pahole zstd debhelper rsync kmod cpio pahole python3 pahole` + arch extras
   (`libncurses-dev` for menuconfig users) — version-pinned per Debian where needed.
3. Call `scripts/prepare-source.sh` (fetch → verify → patch → defconfig+fragment merge).
4. Run `make -jN bindeb-pkg` (preferred) falling back to `deb-pkg`, with:
   `KDEB_PKGVERSION`, `KBUILD_BUILD_TIMESTAMP=$SOURCE_DATE_EPOCH`,
   `KBUILD_BUILD_USER=eaglercraftos`, `KBUILD_BUILD_HOST=debian<n>-<arch>`.
5. Move artifacts to `out/` and print sha256sums.

## 4. Source prep contract (`scripts/prepare-source.sh`)

1. Download `$KERNEL_TARBALL_URL` to `build/dl/` with retry; keep a `.sha256` file.
2. Extract to `build/linux-7.0.14/`.
3. `git apply` every `patches/*.patch` in sorted order (fail fast).
4. Start from `arch/x86/configs/x86_64_defconfig` (amd64) or
   `arch/arm64/configs/defconfig` (arm64), then merge the matching
   `configs/config-<arch>` fragment via `scripts/kconfig/merge_config.sh -m`.
5. `make olddefconfig`, then dump effective `.config` + `diff` vs fragment into `out/`.

## 5. Kernel config deltas (both arches unless noted)

- `CONFIG_LOCALVERSION="-eaglercraftos"`, `CONFIG_LOCALVERSION_AUTO=n`
- Scheduler/timers: `CONFIG_HZ_1000=y` (amd64), `CONFIG_HZ_300=y` (arm64),
  `CONFIG_PREEMPT_VOLUNTARY=y` (amd64), `CONFIG_PREEMPT=y` (arm64)
- Memory: `CONFIG_ZSWAP=y`, `CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y`,
  `CONFIG_ZRAM=m`, `CONFIG_ZSMALLOC=y`, `CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y`
- Net: `CONFIG_TCP_CONG_BBRV3=y` (or BBR if v3 kconfig name differs — fragment uses `=y` guarded),
  `CONFIG_DEFAULT_FQ_CODEL=y`, `CONFIG_WIREGUARD=m`
- FS: `CONFIG_SQUASHFS=y` + `CONFIG_SQUASHFS_ZSTD=y`, `CONFIG_OVERLAY_FS=y`,
  `CONFIG_EXFAT_FS=y`, `CONFIG_NTFS3_FS=m`, `CONFIG_TMPFS_POSIX_ACL=y`
- USB/input: `CONFIG_USB_HID=y`, `CONFIG_INPUT_JOYSTICK=y`, `CONFIG_INPUT_EVDEV=y`,
  `CONFIG_USB_SERIAL=y` + common `USB_SERIAL_*=m`
- DRM: keep `CONFIG_DRM_I915=m`, `CONFIG_DRM_AMDGPU=m`, `CONFIG_DRM_NOUVEAU=m`,
  `CONFIG_DRM_V3D=m`, `CONFIG_DRM_VC4=m`, `CONFIG_DRM_PANFROST=m` (fragment sets `=m`
  so missing symbols on one arch are tolerated via merge `-m`)
- Sound: `CONFIG_SND_HDA_INTEL=m`, `CONFIG_SND_SOC_SOF_HDA=m` (laptop audio for kiosks)
- Debug: `CONFIG_DEBUG_INFO_NONE=y` (strip `-g` for size; CI keeps `linux-image-dbg` off),
  `CONFIG_PRINTK_TIME=n`, `CONFIG_MAGIC_SYSRQ=y`
- Security: `CONFIG_SECURITY_APPARMOR=y`, `CONFIG_DEFAULT_SECURITY_APPARMOR=y`
  (Debian default MAC), `CONFIG_STACKPROTECTOR_STRONG=y`

## 6. CI contract (`.github/workflows/build.yml`)

- `on: push to main, pull_request, workflow_dispatch, tag v*`.
- `strategy.matrix`: `debian: [bookworm, trixie, forky]`, `arch: [amd64, arm64]`.
- `runs-on: ${{ matrix.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}`
  (exact strings — this is the requirement).
- Steps: checkout → (free disk space) → build inside `debian:<codename>-slim`
  container OR directly on runner with docker run (documented choice: docker run
  so the runner image stays exactly `ubuntu-24.04*`) → upload-artifact
  `eaglercraftos-7.0.14-<codename>-<arch>` → `repo` job merges all debs and runs
  `make-repo.sh` (real key from `REPO_GPG_PRIVATE_KEY` secret, else throwaway
  `--gen-key`) → upload-artifact `apt-repo` → on tag, gh CLI release attach
  (avoids pinning third-party SHAs in the template), including `apt-repo.tar.gz`.
- No QEMU, no `docker buildx --platform` emulation anywhere.

## 7. APT repo contract (`scripts/make-repo.sh`)

- Input: directory of `.deb` files (e.g. `out/` or merged CI artifacts).
- Layout: `pool/main/*.deb` (shared), per-suite
  `dists/<bookworm|trixie|forky>/main/binary-<amd64|arm64>/Packages{,.gz,.xz}`,
  suite `Release` via `apt-ftparchive release`, signed `InRelease` + `Release.gpg`.
- Suite routing by `~debian<N>` version suffix (bookworm=12, trixie=13, forky=14):
  `dpkg-scanpackages --arch <a> pool/main` filtered to the suite's suffix.
- Flags: `--input`, `--output`, `--suites`, `--archs`, `--origin`, `--label`,
  plus exactly one of `--gen-key` (throwaway CI key, exports `KEY.gpg` +
  `SIGNING-KEY-PRIVATE.asc`), `--sign-key KEYID`, `--no-sign` (lab only).
- Client lines: `deb [arch=<a> signed-by=/usr/share/keyrings/eaglercraftos.gpg]
  <repo-url> <suite> main` with `KEY.gpg` dearmored into the keyring path.

## 8. Non-goals

- No out-of-tree dkms (nvidia, zfs) in the base image.
- No SecureBoot signing (document `mokutil` flow instead).
- No 32-bit (i386/armhf) builds.
- Linux 7.0.14 is treated as given; if kernel.org hasn't published that
  exact version yet, `prepare-source.sh` fails with the URL it tried so the
  maintainer can bump `VERSION` to the closest published 7.0.x.
