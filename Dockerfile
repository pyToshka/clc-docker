# syntax=docker/dockerfile:1

FROM alpine:3.20 AS fetch
ARG CLC_MIRROR=https://mirror.calculate-linux.org
ARG CLC_DISTRO=scratch
ARG CLC_ARCH=x86_64
RUN apk add --no-cache curl xz tar \
 && curl -fSL "${CLC_MIRROR}/meta/1.0/index-system" -o /index-system \
 && IMG_PATH="$(awk -F';' -v d="${CLC_DISTRO}" -v a="${CLC_ARCH}" \
      '$1==d && $3==a {p=$6} END{print p}' /index-system)" \
 && echo "Using: ${IMG_PATH}" \
 && test -n "${IMG_PATH}" \
 && mkdir /rootfs \
 && curl -fSL "${CLC_MIRROR}/${IMG_PATH}/rootfs.tar.xz" \
  | tar -xJ --numeric-owner -C /rootfs \
 && rm -f /rootfs/etc/resolv.conf /rootfs/etc/hostname /rootfs/etc/hosts \
 && mkdir -p /rootfs/run /rootfs/tmp /rootfs/var/tmp \
 && chmod 1777 /rootfs/tmp /rootfs/var/tmp

FROM scratch
COPY --from=fetch /rootfs/ /

ENV LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CMD ["/bin/bash"]