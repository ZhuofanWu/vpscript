#!/usr/bin/env bash
set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

log() {
    echo -e "${CYAN}==>${RESET} $*"
}

ok() {
    echo -e "${GREEN}完成:${RESET} $*"
}

die() {
    echo -e "${RED}错误:${RESET} $*" >&2
    exit 1
}

if [ "${EUID}" -ne 0 ]; then
    die "请使用 root 权限运行此脚本，例如: curl -fsSL URL | sudo bash"
fi

if ! command -v apt-get >/dev/null 2>&1; then
    die "此脚本仅支持使用 apt 的 Debian/Ubuntu 系统"
fi

if [ ! -r /etc/os-release ]; then
    die "无法读取 /etc/os-release，不能识别系统版本"
fi

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        docker_repo_os="${ID}"
        ;;
    *)
        die "当前系统 (${PRETTY_NAME:-unknown}) 暂不支持；请使用 Debian 或 Ubuntu"
        ;;
esac

repo_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [ -z "${repo_codename}" ]; then
    die "无法识别系统代号，不能配置 Docker 官方 apt 源"
fi

export DEBIAN_FRONTEND=noninteractive

log "移除可能冲突的旧 Docker/容器包"
conflicting_packages=(
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
)

for pkg in "${conflicting_packages[@]}"; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        apt-get remove -y "${pkg}"
    fi
done

log "安装 apt 依赖"
apt-get update
apt-get install -y ca-certificates curl

log "配置 Docker 官方 GPG key"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${docker_repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

log "配置 Docker 官方 apt 源"
arch="$(dpkg --print-architecture)"
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_repo_os} ${repo_codename} stable
EOF

log "安装 Docker Engine、Buildx 和 Compose 插件"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "启动并设置 Docker 开机自启"
systemctl enable --now docker

ok "Docker 安装完成"
docker --version
docker compose version
