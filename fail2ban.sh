#!/usr/bin/env bash
set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

JAIL_DIR="/etc/fail2ban/jail.d"
JAIL_FILE="${JAIL_DIR}/99-vpscript-sshd.local"
RUN_ID="$(date +%Y%m%d%H%M%S)"
SSHD_BIN=""

log() {
    echo -e "${CYAN}==>${RESET} $*"
}

ok() {
    echo -e "${GREEN}完成:${RESET} $*"
}

warn() {
    echo -e "${YELLOW}提示:${RESET} $*" >&2
}

die() {
    echo -e "${RED}错误:${RESET} $*" >&2
    exit 1
}

if [ "${EUID}" -ne 0 ]; then
    die "请使用 root 权限运行此脚本，例如: curl -fsSL URL | sudo bash"
fi

for cmd in awk cat chmod cp date install mktemp rm; do
    command -v "${cmd}" >/dev/null 2>&1 || die "缺少必要命令: ${cmd}"
done

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
        ;;
    *)
        die "当前系统 (${PRETTY_NAME:-unknown}) 暂不支持；请使用 Debian 或 Ubuntu"
        ;;
esac

read_input() {
    local prompt="$1"
    local value

    if [ ! -r /dev/tty ]; then
        die "无法读取交互终端，请在可交互的 shell 中运行此脚本"
    fi

    printf "%s" "${prompt}" >&2
    if ! IFS= read -r value </dev/tty; then
        die "读取输入失败，请在可交互的 shell 中运行此脚本"
    fi

    echo "${value}"
}

read_yes_no() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        value="$(read_input "${prompt}")"
        value="${value:-${default}}"

        case "${value}" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            *)
                warn "请输入 y 或 n"
                ;;
        esac
    done
}

valid_port() {
    local port="$1"

    [[ "${port}" =~ ^([1-9][0-9]*|0)$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

normalize_ports() {
    local raw="$1"
    local part normalized=""
    local -a parts
    local -A seen

    raw="${raw//[[:space:]]/}"
    raw="${raw//;/,}"

    if [ -z "${raw}" ]; then
        return 1
    fi

    IFS=',' read -r -a parts <<< "${raw}"

    for part in "${parts[@]}"; do
        [ -z "${part}" ] && return 1

        if ! valid_port "${part}"; then
            return 1
        fi

        if [ -n "${seen[$part]:-}" ]; then
            continue
        fi

        seen["${part}"]=1
        if [ -z "${normalized}" ]; then
            normalized="${part}"
        else
            normalized="${normalized},${part}"
        fi
    done

    echo "${normalized}"
}

detect_sshd_bin() {
    SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
    if [ -z "${SSHD_BIN}" ] && [ -x /usr/sbin/sshd ]; then
        SSHD_BIN="/usr/sbin/sshd"
    fi
}

detect_ssh_ports() {
    local ports=""

    detect_sshd_bin
    if [ -n "${SSHD_BIN}" ]; then
        ports="$("${SSHD_BIN}" -T 2>/dev/null | awk '
            tolower($1) == "port" && $2 ~ /^[0-9]+$/ {
                if (ports == "") {
                    ports = $2
                } else {
                    ports = ports "," $2
                }
            }
            END { print ports }
        ' || true)"
    fi

    if [ -n "${ports}" ]; then
        normalize_ports "${ports}" && return 0
    fi

    echo "22"
}

choose_ssh_ports() {
    local detected="$1"
    local input normalized

    while true; do
        input="$(read_input "请输入 SSH 端口，多个用逗号分隔 [${detected}]: ")"
        input="${input:-${detected}}"

        if normalized="$(normalize_ports "${input}")"; then
            echo "${normalized}"
            return 0
        fi

        warn "端口格式无效，请输入 1-65535 之间的数字，多个端口用逗号分隔"
    done
}

valid_positive_int() {
    local value="$1"

    [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]
}

read_positive_int() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        value="$(read_input "${prompt}")"
        value="${value:-${default}}"

        if valid_positive_int "${value}"; then
            echo "${value}"
            return 0
        fi

        warn "请输入大于 0 的整数"
    done
}

choose_policy() {
    local choice bantime findtime maxretry

    echo -e "${CYAN}========================================================${RESET}" >&2
    echo "请选择 SSH 防爆破策略：" >&2
    echo "  1) 标准：10 分钟内失败 5 次，封禁 1 小时" >&2
    echo "  2) 严格：10 分钟内失败 3 次，封禁 24 小时" >&2
    echo "  3) 自定义" >&2
    echo -e "${CYAN}========================================================${RESET}" >&2

    while true; do
        choice="$(read_input "请输入对应的序号 [1-3]: ")"
        choice="${choice:-1}"

        case "${choice}" in
            1)
                echo "3600|600|5|标准"
                return 0
                ;;
            2)
                echo "86400|600|3|严格"
                return 0
                ;;
            3)
                bantime="$(read_positive_int "请输入封禁时间，单位秒 [3600]: " "3600")"
                findtime="$(read_positive_int "请输入统计窗口，单位秒 [600]: " "600")"
                maxretry="$(read_positive_int "请输入失败次数阈值 [5]: " "5")"
                echo "${bantime}|${findtime}|${maxretry}|自定义"
                return 0
                ;;
            *)
                warn "无效选择，请重新输入"
                ;;
        esac
    done
}

detect_client_ip() {
    local client_ip=""

    if [ -n "${SSH_CONNECTION:-}" ]; then
        client_ip="${SSH_CONNECTION%% *}"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        client_ip="${SSH_CLIENT%% *}"
    fi

    if [[ "${client_ip}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        echo "${client_ip}"
    fi
}

choose_ignoreip() {
    local client_ip="$1"
    local ignoreip="127.0.0.1/8 ::1"

    if [ -n "${client_ip}" ]; then
        if read_yes_no "是否将当前登录 IP (${client_ip}) 加入 fail2ban 白名单？[Y/n]: " "y"; then
            ignoreip="${ignoreip} ${client_ip}"
        fi
    fi

    echo "${ignoreip}"
}

install_fail2ban() {
    local -a packages=(fail2ban)

    if [ -d /run/systemd/system ]; then
        packages+=(python3-systemd)
    fi

    export DEBIAN_FRONTEND=noninteractive

    log "安装 fail2ban"
    apt-get update
    apt-get install -y "${packages[@]}"

    command -v fail2ban-client >/dev/null 2>&1 || die "fail2ban-client 安装失败"
}

detect_backend() {
    if [ -d /run/systemd/system ]; then
        echo "systemd"
    else
        echo "auto"
    fi
}

backup_jail_file() {
    local backup=""

    if [ -f "${JAIL_FILE}" ]; then
        backup="${JAIL_FILE}.bak.${RUN_ID}"
        cp "${JAIL_FILE}" "${backup}"
        warn "已备份原 fail2ban 配置到 ${backup}"
    fi

    echo "${backup}"
}

restore_jail_file() {
    local backup="$1"

    if [ -n "${backup}" ]; then
        cp "${backup}" "${JAIL_FILE}"
    else
        rm -f "${JAIL_FILE}"
    fi
}

write_jail_config() {
    local ssh_ports="$1"
    local bantime="$2"
    local findtime="$3"
    local maxretry="$4"
    local ignoreip="$5"
    local backend="$6"

    install -m 0755 -d "${JAIL_DIR}"

    cat > "${JAIL_FILE}" <<EOF
# Managed by vpscript fail2ban.sh

[sshd]
enabled = true
port = ${ssh_ports}
filter = sshd
backend = ${backend}
ignoreip = ${ignoreip}
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
EOF

    chmod 644 "${JAIL_FILE}"
}

validate_fail2ban_config() {
    local backup="$1"

    log "验证 fail2ban 配置"
    if ! fail2ban-client -t; then
        restore_jail_file "${backup}"
        die "fail2ban 配置校验失败，已回滚 ${JAIL_FILE}"
    fi
}

start_fail2ban_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable fail2ban >/dev/null 2>&1 || warn "设置 fail2ban 开机自启失败，请手动检查"
        if systemctl restart fail2ban; then
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        if service fail2ban restart; then
            return 0
        fi
    fi

    return 1
}

restart_fail2ban() {
    local backup="$1"

    log "启动并设置 fail2ban 开机自启"

    if start_fail2ban_service; then
        return 0
    fi

    warn "fail2ban 服务启动失败，正在回滚 ${JAIL_FILE}"
    restore_jail_file "${backup}"
    if fail2ban-client -t >/dev/null 2>&1; then
        start_fail2ban_service >/dev/null 2>&1 || true
    fi

    die "无法启动 fail2ban 服务，已回滚脚本写入的配置，请手动检查服务日志"
}

print_status() {
    echo -e "${CYAN}========================================================${RESET}"
    echo -e "${GREEN}fail2ban 配置完成${RESET}"
    echo -e "${CYAN}========================================================${RESET}"
    echo "配置文件: ${JAIL_FILE}"
    echo

    if fail2ban-client status sshd >/dev/null 2>&1; then
        fail2ban-client status sshd
    else
        warn "无法读取 sshd jail 状态，请稍后执行: fail2ban-client status sshd"
    fi
}

main() {
    local detected_ports ssh_ports
    local policy bantime findtime maxretry policy_name
    local client_ip ignoreip backend backup

    echo -e "${CYAN}========================================================${RESET}"
    echo -e "${CYAN}       SSH 防爆破一键配置 (fail2ban)${RESET}"
    echo -e "${CYAN}========================================================${RESET}"

    detected_ports="$(detect_ssh_ports)"
    ssh_ports="$(choose_ssh_ports "${detected_ports}")"

    policy="$(choose_policy)"
    IFS='|' read -r bantime findtime maxretry policy_name <<< "${policy}"

    client_ip="$(detect_client_ip)"
    ignoreip="$(choose_ignoreip "${client_ip}")"

    install_fail2ban
    backend="$(detect_backend)"
    backup="$(backup_jail_file)"

    log "写入 sshd jail 配置 (${policy_name}策略)"
    write_jail_config "${ssh_ports}" "${bantime}" "${findtime}" "${maxretry}" "${ignoreip}" "${backend}"
    validate_fail2ban_config "${backup}"
    restart_fail2ban "${backup}"

    ok "SSH 端口: ${ssh_ports}"
    ok "策略: ${policy_name}，${findtime} 秒内失败 ${maxretry} 次，封禁 ${bantime} 秒"
    ok "白名单: ${ignoreip}"
    print_status
}

main "$@"
