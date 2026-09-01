# 构建用 builder 镜像：所有构建路径（mmdebstrap / debootstrap 自举 / squashfs 切片）所需工具
# 用阿里云源（直连 deb.debian.org 在国内慢到会拖垮构建）
FROM debian:13
# ⚠️ docker build 会从 daemon 的 http-proxy drop-in 继承代理（本机是 10.3.32.34:17777），
#    而那个代理到不了国内镜像站，apt 会全部 Err。这里显式清空；需要走代理时用
#    --build-arg http_proxy=... 覆盖。同一个坑在 docker run 侧靠 -e http_proxy= 解决。
ARG http_proxy=""
ARG https_proxy=""
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG no_proxy="*"
ENV DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.sources && \
    printf 'Types: deb\nURIs: http://mirrors.aliyun.com/debian\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
      > /etc/apt/sources.list.d/debian.sources && \
    printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/no-lang && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      mmdebstrap debootstrap apt-utils ca-certificates curl wget \
      zstd xz-utils squashfs-tools \
      rpm cpio \
      dpkg-dev perl file arch-test procps \
      gpgv gpg \
      python3-minimal \
    && rm -rf /var/lib/apt/lists/*
# 自检：缺任何一个都不该构建成功
RUN for c in mmdebstrap debootstrap unsquashfs gpgv gpg python3 curl zstd dpkg-scanpackages; do \
      command -v $c >/dev/null || { echo "缺少 $c"; exit 1; }; done && \
    mmdebstrap --version && debootstrap --version
