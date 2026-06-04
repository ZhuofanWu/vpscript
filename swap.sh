#!/usr/bin/env bash
set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

SWAPFILE="/swapfile"
FSTAB="/etc/fstab"

log() {
    echo -e "${CYAN}==>${RESET} $*"
}

ok() {
    echo -e "${GREEN}完成:${RESET} $*"
}

warn() {
    echo -e "${YELLOW}提示:${RESET} $*"
}

die() {
    echo -e "${RED}错误:${RESET} $*" >&2
    exit 1
}

if [ "${EUID}" -ne 0 ]; then
    die "请使用 root 权限运行此脚本，例如: curl -fsSL URL | sudo bash"
fi

for cmd in awk cmp cp chmod date df free mktemp mkswap rm swapon swapoff; do
    command -v "${cmd}" >/dev/null 2>&1 || die "缺少必要命令: ${cmd}"
done

size_bytes() {
    case "$1" in
        256M) echo 268435456 ;;
        512M) echo 536870912 ;;
        1G) echo 1073741824 ;;
        *) die "不支持的 Swap 大小: $1" ;;
    esac
}

size_mib() {
    case "$1" in
        256M) echo 256 ;;
        512M) echo 512 ;;
        1G) echo 1024 ;;
        *) die "不支持的 Swap 大小: $1" ;;
    esac
}

active_swap_bytes() {
    awk 'NR > 1 { total += $3 * 1024 } END { print total + 0 }' /proc/swaps
}

standard_size_label() {
    local bytes="$1"
    local label target diff tolerance

    tolerance=$((8 * 1024 * 1024))
    for label in 256M 512M 1G; do
        target="$(size_bytes "${label}")"
        diff=$((bytes - target))
        if [ "${diff}" -lt 0 ]; then
            diff=$((-diff))
        fi

        if [ "${diff}" -le "${tolerance}" ]; then
            echo "${label}"
            return 0
        fi
    done

    return 1
}

format_bytes() {
    local bytes="$1"

    if [ "${bytes}" -eq 0 ]; then
        echo "0"
        return 0
    fi

    awk -v bytes="${bytes}" 'BEGIN {
        if (bytes >= 1073741824) {
            printf "%.1fG", bytes / 1073741824
        } else {
            printf "%.0fM", bytes / 1048576
        }
    }'
}

read_choice() {
    local prompt="$1"
    local choice

    if [ ! -r /dev/tty ]; then
        die "无法读取交互终端，请在可交互的 shell 中运行此脚本"
    fi

    printf "%s" "${prompt}" >&2
    IFS= read -r choice </dev/tty

    echo "${choice}"
}

show_active_swap() {
    local current_bytes="$1"

    if [ "${current_bytes}" -eq 0 ]; then
        echo -e "当前 Swap 状态: ${YELLOW}关闭${RESET}" >&2
        return 0
    fi

    echo -e "当前 Swap 状态: ${GREEN}开启${RESET} ($(format_bytes "${current_bytes}"))" >&2
    swapon --show >&2
}

choose_action() {
    local current_bytes="$1"
    local current_label=""
    local choice i label
    local -a labels actions

    if [ "${current_bytes}" -gt 0 ]; then
        current_label="$(standard_size_label "${current_bytes}" || true)"
        labels+=("关闭 Swap")
        actions+=("off")
    fi

    for label in 256M 512M 1G; do
        if [ "${label}" = "${current_label}" ]; then
            continue
        fi

        labels+=("设置 ${label} Swap")
        actions+=("${label}")
    done

    echo -e "${CYAN}========================================================${RESET}" >&2
    show_active_swap "${current_bytes}"
    echo -e "${CYAN}========================================================${RESET}" >&2
    echo "请选择操作：" >&2

    for i in "${!labels[@]}"; do
        echo "  $((i + 1))) ${labels[$i]}" >&2
    done

    while true; do
        choice="$(read_choice "请输入对应的序号 [1-${#actions[@]}]: ")"

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#actions[@]}" ]; then
            echo "${actions[$((choice - 1))]}"
            return 0
        fi

        warn "无效选择，请重新输入" >&2
    done
}

cleanup_swap_fstab_entries() {
    local backup tmp

    if [ ! -f "${FSTAB}" ]; then
        return 0
    fi

    tmp="$(mktemp)"

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        $3 == "swap" { next }
        { print }
    ' "${FSTAB}" > "${tmp}"

    if cmp -s "${FSTAB}" "${tmp}"; then
        rm -f "${tmp}"
        return 0
    fi

    backup="${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${FSTAB}" "${backup}"
    cp "${tmp}" "${FSTAB}"
    rm -f "${tmp}"

    warn "已备份 ${FSTAB} 到 ${backup}"
}

disable_swap() {
    local show_result="${1:-yes}"
    local current_bytes

    current_bytes="$(active_swap_bytes)"
    if [ "${current_bytes}" -gt 0 ]; then
        log "关闭当前所有 Swap"
        swapoff -a
    else
        warn "当前没有启用的 Swap"
    fi

    cleanup_swap_fstab_entries

    if [ -f "${SWAPFILE}" ]; then
        log "删除 ${SWAPFILE}"
        rm -f "${SWAPFILE}"
    fi

    if [ "${show_result}" = "yes" ]; then
        ok "Swap 已关闭"
    fi
}

ensure_disk_space() {
    local label="$1"
    local required_kib available_kib margin_kib

    required_kib=$(( $(size_mib "${label}") * 1024 ))
    margin_kib=$((64 * 1024))
    available_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"

    if [ "${available_kib}" -lt $((required_kib + margin_kib)) ]; then
        die "根分区可用空间不足，创建 ${label} Swap 至少需要约 $((required_kib / 1024 + 64))M 可用空间"
    fi
}

create_swapfile() {
    local label="$1"
    local mib

    mib="$(size_mib "${label}")"
    ensure_disk_space "${label}"

    log "创建 ${label} Swap 文件"
    rm -f "${SWAPFILE}"

    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${label}" "${SWAPFILE}"; then
            warn "fallocate 创建失败，改用 dd 创建"
            dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${mib}" status=progress
        fi
    else
        dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${mib}" status=progress
    fi

    chmod 600 "${SWAPFILE}"
    mkswap "${SWAPFILE}"
    swapon "${SWAPFILE}"
}

enable_swap() {
    local label="$1"

    disable_swap no
    create_swapfile "${label}"

    log "写入开机自动挂载配置"
    echo "${SWAPFILE} none swap sw 0 0" >> "${FSTAB}"

    ok "${label} Swap 已开启"
}

main() {
    local action current_bytes

    current_bytes="$(active_swap_bytes)"
    action="$(choose_action "${current_bytes}")"

    case "${action}" in
        off)
            disable_swap
            ;;
        256M|512M|1G)
            enable_swap "${action}"
            ;;
        *)
            die "未知操作: ${action}"
            ;;
    esac

    echo
    free -h
}

main "$@"
