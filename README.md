# Calculate Linux Docker image

Docker images of Calculate Linux. There is no official Calculate image on Docker Hub, so this repo builds one.

Three Dockerfiles, three ways to get there:

| File                 | Base            | Arch            | What you get                                              |
|----------------------|-----------------|-----------------|-----------------------------------------------------------|
| `Dockerfile`         | `scratch`       | x86_64          | official CLC rootfs from the mirror, fetched via Alpine   |
| `Dockerfile.scratch` | `scratch`       | x86_64          | same rootfs, fetched with `ADD --unpack`, no helper image |
| `Dockerfile.stage3`  | `gentoo/stage3` | arm64 or x86_64 | Gentoo plus Calculate overlay and `calculate-utils`       |

The first two take the same rootfs that `lxc-create -t download --server mirror.calculate-linux.org` uses and pack it into a regular Docker image. The third one is not an official Calculate build, it is Gentoo with Calculate tooling built from source, because Calculate ships no arm64 rootfs and no arm64 binhost.

None of the images has an init. OpenRC does not start, PID 1 is your own process. `cl-update`, `emerge` and other Calculate tools work as usual.

## Build with Alpine helper (`Dockerfile`)

An `alpine` stage reads the LXC index `meta/1.0/index-system` on the mirror, finds the line for the requested distro and architecture, downloads `rootfs.tar.xz`, unpacks it and removes `resolv.conf`, `hostname` and `hosts` (Docker manages those itself). The final stage is `FROM scratch` with a single `COPY`, so the image is one layer.

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

Uses `ADD --unpack=true` to extract the remote tarball straight into the image root. Needs a recent BuildKit (Dockerfile frontend 1.16 or newer). The image path is passed as a build argument, so resolve it from the index first:

```bash
docker build -f Dockerfile.scratch -t calculate/clc:latest \
  --build-arg CLC_IMAGE="$(curl -fsSL https://mirror.calculate-linux.org/meta/1.0/index-system \
    | awk -F';' '$1=="scratch" && $3=="x86_64" {p=$6} END{print p}')" .
```

Build arguments:

| ARG          | Default                                    | Purpose                          |
|--------------|--------------------------------------------|----------------------------------|
| `CLC_MIRROR` | `https://mirror.calculate-linux.org`       | Calculate mirror                 |
| `CLC_IMAGE`  | `container/scratch-20260908-x86_64`        | image path from the mirror index |

## Build from Gentoo stage3 (`Dockerfile.stage3`)

Starts from `gentoo/stage3`, enables the Calculate overlay with `eselect repository`, accepts all keywords from that overlay (it carries no arm64 keywords at all) and emerges `sys-apps/calculate-utils`. Everything is compiled from source, the first build takes a while. Distfiles live in a BuildKit cache mount, so rebuilds do not download sources again.

A few Portage tweaks are needed to make `calculate-utils` build outside of x86_64:

- `calculate-utils` supports only Python 3.12 and 3.13, while the stage3 profile may already default to a newer interpreter. `PYTHON_TARGET` is added next to the profile target instead of replacing it, otherwise Portage ends up with slot conflicts on `dev-python/*`.
- The live ebuild `calculate-utils-9999` is masked so releases get picked, since `**` keywords would otherwise make the live version the newest.
- USE flags `install`, `pxe`, `desktop`, `client` are disabled: they pull the installer and bootloader stack (`syslinux` and friends) which is x86-only and useless in a container.

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

In this image `cl-update` has no binhost to pull from, so it behaves as a wrapper around `emerge` and updates from source.

## Run

```bash
docker run -it --rm calculate/clc:latest
```

Inside:

```bash
cl-update
emerge app-misc/htop
```
