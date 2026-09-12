# Calculate Linux Docker image

Docker images of Calculate Linux. There is no official Calculate image on Docker Hub, so this repo builds one.

Three Dockerfiles, three ways to get there:

| File                 | Base            | Arch            | What you get                                              |
|----------------------|-----------------|-----------------|-----------------------------------------------------------|
| `Dockerfile`         | `scratch`       | x86_64          | official CLC rootfs from the mirror, fetched via Alpine   |
| `Dockerfile.scratch` | `scratch`       | x86_64          | same rootfs, fetched with `ADD --unpack`, no helper image |
| `Dockerfile.stage3`  | `gentoo/stage3` | 8 platforms     | Gentoo plus Calculate overlay and `calculate-utils`       |

The first two take the same rootfs that `lxc-create -t download --server mirror.calculate-linux.org` uses and pack it into a regular Docker image. The third one is not an official Calculate build, it is Gentoo with Calculate tooling built from source, because Calculate ships no arm64 rootfs and no arm64 binhost.

None of the images has an init. OpenRC does not start, PID 1 is your own process. `cl-update`, `emerge` and other Calculate tools are in place, but the images differ in where packages come from. The rootfs images install binary packages from the Calculate binhost right away: in a fresh container `emerge -p sys-process/htop` resolves to a `[binary]` package without any sync. The stage3 image has no binhost and drops its Gentoo tree after the build, so there the first step is a sync, see [Run](#run).

All three images are trimmed: documentation, man and info pages and every translation except English and Russian are removed, and `INSTALL_MASK` keeps later `emerge` runs from bringing them back. The mask is appended to the profile value, so the profile's own entries (for example `/etc/systemd` in the Calculate container profile) stay in force. To get man pages back, remove `/etc/portage/make.conf/docker` in the rootfs images or the `INSTALL_MASK` line in `/etc/portage/make.conf` in the stage3 image and re-emerge the package.

## Build with Alpine helper (`Dockerfile`)

An `alpine` stage reads the LXC index `meta/1.0/index-system` on the mirror, finds the line for the requested distro and architecture, downloads `rootfs.tar.xz`, unpacks it and removes `resolv.conf`, `hostname` and `hosts` (Docker manages those itself). In the same step it deletes documentation, man and info pages, translations other than `en*` and `ru`, and the 19 MiB `eix` cache (`eix-update` regenerates it), then writes the `INSTALL_MASK` file `/etc/portage/make.conf/docker`. The final stage is `FROM scratch` with a single `COPY`, so the image is one layer and nothing deleted in the helper stage reaches it.

```bash
docker build -t calculate/clc:latest .
```

Build arguments:

| ARG          | Default                               | Purpose                              |
|--------------|---------------------------------------|--------------------------------------|
| `CLC_MIRROR` | `https://mirror.calculate-linux.org`  | Calculate mirror                     |
| `CLC_DISTRO` | `scratch`                             | distro name as listed in the index   |
| `CLC_ARCH`   | `x86_64`                              | architecture as listed in the index  |

Example with another mirror:

```bash
docker build -t calculate/clc:latest \
  --build-arg CLC_MIRROR=https://mirror.yandex.ru/calculate .
```

To see which images the mirror currently offers:

```bash
curl -sS https://mirror.calculate-linux.org/meta/1.0/index-system
```

Line format: `distro;release;arch;variant;date;path`.

## Build without Alpine image (`Dockerfile.scratch`)

Uses `ADD --unpack=true` to extract the remote tarball straight into the root of an intermediate stage. Needs a recent BuildKit (Dockerfile frontend 1.16 or newer). The trimming step is the same as in `Dockerfile`, but it runs with the `bash` of the Calculate rootfs itself, so no third-party image takes part in the build. The price is that the builder has to execute x86_64 binaries: on an arm64 host the step runs under emulation (QEMU or Rosetta in Docker Desktop). The final stage copies the trimmed tree into `scratch`, the image is one layer and has the same file list as the `Dockerfile` image (64591 paths in both, compared on 2026-09-11).

The image path is passed as a build argument. The mirror keeps only the current build, the default goes stale within days (`scratch-20260908` already returns 404), so resolve the path from the index first:

```bash
docker build -f Dockerfile.scratch -t calculate/clc:latest \
  --build-arg CLC_IMAGE="$(curl -fsSL https://mirror.calculate-linux.org/meta/1.0/index-system \
    | awk -F';' '$1=="scratch" && $3=="x86_64" {p=$6} END{print p}')" .
```

Build arguments:

| ARG          | Default                                    | Purpose                          |
|--------------|--------------------------------------------|----------------------------------|
| `CLC_MIRROR` | `https://mirror.calculate-linux.org`       | Calculate mirror                 |
| `CLC_IMAGE`  | `container/scratch-20260910-x86_64`        | image path from the mirror index |

## Build from Gentoo stage3 (`Dockerfile.stage3`)

Starts from `gentoo/stage3`, enables the Calculate overlay with `eselect repository`, accepts all keywords from that overlay (it carries no arm64 keywords at all) and emerges `sys-apps/calculate-utils`. Everything is compiled from source, the first build takes a while. Distfiles live in a BuildKit cache mount, so rebuilds do not download sources again.

A few Portage tweaks are needed to make `calculate-utils` build outside of x86_64:

- `calculate-utils` supports only Python 3.12 and 3.13, while the stage3 profile may already default to a newer interpreter. `PYTHON_TARGET` is added next to the profile target instead of replacing it, otherwise Portage ends up with slot conflicts on `dev-python/*`.
- The live ebuild `calculate-utils-9999` is masked so releases get picked, since `**` keywords would otherwise make the live version the newest.
- USE flags `install`, `pxe`, `desktop`, `client` are disabled: they pull the installer and bootloader stack (`syslinux` and friends) which is x86-only and useless in a container.
- `dev-lang/rust-bin` gets `CPU_FLAGS_X86: sse2`. The 32-bit x86 profile (`x86/23.0/i686`) does not enable SSE2, `rust-bin` refuses to install without it (`REQUIRED_USE="x86? ( cpu_flags_x86_sse2 )"`), and Rust cannot be avoided: `dev-vcs/git` asks for it through USE `rust`, `dev-python/cryptography` builds Rust code. On other platforms the entry is inert, the dependency plan for amd64 and arm64 is identical with and without it.

After `calculate-utils` is in place, the build removes what only the build needed:

- `emerge --depclean --with-bdeps=n` drops packages that the build added on top of stage3 and that nothing needs at runtime: 13 packages on arm64, the largest being `rust-bin` (546 MiB), `cython` (46 MiB) and `maturin` (34 MiB). Everything `gentoo/stage3` itself ships stays: before the build the Dockerfile writes the installed package list into a temporary set `@docker-stage3-base`, adds it to `world_sets` for the duration of the depclean and then restores `world_sets`. Without that protection depclean also removes 92 stage3 packages (237 MiB: cmake, meson, autotools, gettext, pkgconf and others), and ebuilds that rely on them without declaring them break: `app-misc/jq` fails in configure with `syntax error near unexpected token 'onig,'` because `pkg.m4` from the removed `pkgconf` is missing. Passing the added packages to depclean as arguments is not an option either: with explicit atoms depclean selects all of them, `calculate-utils` and `git` included, because world membership does not protect a package named on the command line.
- The Gentoo tree is cut down to `profiles`, `eclass` and `metadata/layout.conf`, 23 MiB instead of 735 MiB. `profiles` stays because `/etc/portage/make.profile` points into it, so Portage configuration remains valid until the next sync. `eclass` stays because the Calculate overlay inherits eclasses from the Gentoo tree: without it every `emerge` before the sync prints `distutils-r1.eclass could not be found by inherit()` for `calculate-utils`. The Calculate overlay stays whole with its `.git`, so `emerge --sync calculate` does a `git pull`. The previous version of this Dockerfile deleted `.git` of every repository, and `emerge --sync calculate` in that image fails with `returned code = 128`.
- Documentation, man and info pages and translations other than `en*` and `ru` are deleted, and `INSTALL_MASK` in `make.conf` keeps them out of later merges.

Removing files in a later `RUN` would not shrink much: the documentation, man pages and translations of the stage3 packages live in the 1.23 GB base layer of `gentoo/stage3`, and a deletion in an upper layer only hides them. So the build runs in a `build` stage, and the final stage copies its root into `scratch` with a single `COPY`. All files sit in that one layer (`WORKDIR` adds a second, empty layer of 16 bytes), and the image shares nothing with `gentoo/stage3`; layer sharing would only have saved a download on a host that already holds that exact `gentoo/stage3` layer.

Sizes before and after the trimming, measured on 2026-09-11 (download size is the sum of compressed layers, gzip before, zstd level 19 after):

| Image                          | Unpacked         | Download             |
|--------------------------------|------------------|----------------------|
| stage3, arm64                  | 2.8 GB -> 1.4 GB | 729 MiB -> 268 MiB   |
| stage3, amd64                  | not measured     | 796 MiB -> not measured |
| rootfs and scratch, x86_64     | 1.8 GB -> 1.5 GB | 558 MiB -> 316 MiB   |

Locally stage3 was built only for arm64; the amd64 figure appears with the first CI run.

The image builds for eight of the nine platforms `gentoo/stage3` publishes: `linux/amd64`, `linux/arm64`, `linux/386`, `linux/arm/v6`, `linux/arm/v7`, `linux/ppc64le`, `linux/riscv64`, `linux/s390x`. The ninth, `linux/arm/v5`, is out of reach: its profile pulls in `features/wd40`, whose `package.mask` covers packages requiring Rust, and `calculate-utils` depends on `dev-python/pyopenssl`, which sits on that list. No Portage setting in this Dockerfile can fix that without dropping a real dependency of `calculate-utils`.

s390x needs its own base tag. Inside the `gentoo/stage3:latest` manifest list the s390x image was built on 2022-12-05, every other platform on 2026-09-07 (checked on 2026-09-11), and on that old image Portage stops with slot conflicts on perl 5.34 and libxml2 next to an installed glibc 2.35 that the tree now masks. The per-architecture tag `s390x-openrc` is current:

```bash
docker build --platform linux/s390x -f Dockerfile.stage3 \
  -t calculate/clc:s390x --build-arg STAGE3_TAG=s390x-openrc .
```

arm64, for example on Apple Silicon:

```bash
docker build --platform linux/arm64 -f Dockerfile.stage3 \
  -t calculate/clc:arm64 --build-arg JOBS=12 --build-arg EMERGE_JOBS=2 .
```

Host architecture, whatever it is:

```bash
docker build -f Dockerfile.stage3 -t calculate/clc:stage3 --build-arg JOBS=8 .
```

`JOBS` should not exceed the CPU count given to the Docker VM, check it with `docker info --format '{{.NCPU}}'`. Peak parallelism is `JOBS * EMERGE_JOBS` threads, plan memory accordingly.

Build arguments:

| ARG                 | Default      | Purpose                                             |
|---------------------|--------------|-----------------------------------------------------|
| `STAGE3_TAG`        | `latest`     | `gentoo/stage3` tag, pin it for reproducible builds |
| `JOBS`              | `4`          | `MAKEOPTS -j` and emerge load limit                 |
| `EMERGE_JOBS`       | `2`          | packages built in parallel by emerge                |
| `CALCULATE_OVERLAY` | `calculate`  | overlay name in `eselect repository`                |
| `PYTHON_TARGET`     | `python3_13` | extra Python target required by `calculate-utils`   |

In this image `cl-update` has no binhost to pull from, so it behaves as a wrapper around `emerge` and updates from source. Neither `cl-update` nor `emerge` has a tree to work with until the Gentoo repository is synced, see [Run](#run).

## Images built by CI

`.github/workflows/docker-publish.yml` runs on every push to `main`, on `v*.*.*` tags and on pull requests. Pull requests only build, nothing is pushed. The nightly `schedule` trigger is commented out; while it is, no `nightly` tags are produced. All three Dockerfiles are built, and everything lands in `ghcr.io/pytoshka/clc-docker` under the tags `docker/metadata-action` derives from the event (`main`, `nightly`, the git tag) plus `latest`:

| Tag                                                       | Dockerfile           | Platforms    | Published when             |
|-----------------------------------------------------------|----------------------|--------------|----------------------------|
| `latest`, `main`, `nightly`, `vX.Y.Z`                     | `Dockerfile.stage3`  | amd64, arm64 | both native builds succeed |
| `latest-rootfs`, `main-rootfs`, `nightly-rootfs`, `vX.Y.Z-rootfs`     | `Dockerfile`         | x86_64       | the build succeeds         |
| `latest-scratch`, `main-scratch`, `nightly-scratch`, `vX.Y.Z-scratch` | `Dockerfile.scratch` | x86_64       | the build succeeds         |

Bare `latest` is the stage3 image because it is the only one with an arm64 variant. Calculate publishes a single rootfs, `x86_64` (the mirror index lists exactly one line, checked on 2026-09-11), so a rootfs tag pulled on Apple Silicon or another arm64 host fails with `no matching manifest for linux/arm64/v8`. With stage3 behind `latest`, `docker pull ghcr.io/pytoshka/clc-docker` works on both architectures, and the official rootfs stays available under its suffix:

```bash
docker pull ghcr.io/pytoshka/clc-docker                # stage3, amd64 or arm64, picked by the host
docker pull ghcr.io/pytoshka/clc-docker:latest-rootfs  # official rootfs, x86_64 only
```

`latest` follows the default branch: every push to `main` moves it, and so does a nightly run while the schedule is enabled. A `v*.*.*` tag moves it too, so tagging an older commit points `latest` back at that commit until the next push. Each image gets its suffix on `latest` as well (`suffix=...,onlatest=true` on one line of `flavor`), otherwise the three jobs would race for the same `latest`, since they push to one repository. The tags published before this layout, `latest-stage3`, `main-stage3` and `nightly-stage3`, are no longer updated.

The x86_64 images come from one `build` job with a matrix over `Dockerfile` and `Dockerfile.scratch`. For `Dockerfile.scratch` the job resolves the current rootfs path from the mirror index and passes it as `CLC_IMAGE`, so a stale default in the Dockerfile does not break CI.

CI builds `Dockerfile.stage3` only for amd64 and arm64, both natively and without QEMU: `stage3-build` runs amd64 on `ubuntu-24.04` and arm64 on `ubuntu-24.04-arm`. The other platforms listed above build locally but are not published. A build job pushes its image by digest only, without a tag. `stage3-merge` assembles the manifest list, tags it and signs it with cosign, the same way the x86_64 images are signed. It picks digests by an explicit platform list and stops if one of them is missing, so `latest` is never published with one architecture only. Layer cache goes to the GitHub Actions cache with a separate scope per Dockerfile and per platform, otherwise the jobs would overwrite each other's cache.

Layers are pushed compressed with zstd at level 19 (`LAYER_COMPRESSION` in the workflow). BuildKit uses the `klauspost/compress` implementation, which at that level gives the rootfs layer 316 MiB against 558 MiB with the default gzip, and the arm64 stage3 268 MiB. Docker Engine pulls zstd layers starting with 23.0 (per its release notes); an older engine cannot pull these images at all. The layer is compressed on every push: a local export of the rootfs image with these settings took 47 seconds.

## Run

```bash
docker run -it --rm ghcr.io/pytoshka/clc-docker
```

The stage3 image (`latest`) needs the Gentoo tree first. `emerge-webrsync` downloads a snapshot that unpacks to 711 MiB, `emerge --sync calculate` pulls the overlay. Before the sync `emerge` answers `there are no ebuilds to satisfy`, after it the package resolves:

```bash
emerge-webrsync
emerge --sync calculate
emerge app-misc/jq
```

The rootfs images (`latest-rootfs`, `latest-scratch`) take binary packages from the Calculate binhost without a sync; `cl-update` updates the system:

```bash
emerge app-misc/jq
cl-update
```

Packages built with USE `filecaps` get file capabilities that Docker's default capability set does not include, and their binaries then fail with `Operation not permitted`. `sys-process/htop` is one of them: it is installed with `cap_sys_ptrace=ep` and starts only in a container run with `--cap-add SYS_PTRACE`.
