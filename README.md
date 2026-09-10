# Calculate Linux Docker image

Docker image of Calculate Linux built from scratch using the official container rootfs from the Calculate mirror.

There is no official Calculate image on Docker Hub.
This project takes the same rootfs that `lxc-create -t download --server mirror.calculate-linux.org` uses and packs it into a regular Docker image.

## Build
 
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
 
## Run
 
```bash
docker run -it --rm calculate/clc:latest
```