#!/usr/bin/env bash
set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

DEFAULT_GITHUB_USER="${GITHUB_USER:-ZhuofanWu}"
ROOT_SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${ROOT_SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_CONFIG_DIR}/99-vpscript-pubkey.conf"
RUN_ID="$(date +%Y%m%d%H%M%S)"
TMP_DIR=""
SSHD_BIN=""

declare -a RESTORE_FILES=()
declare -a RESTORE_BACKUPS=()

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

cleanup() {
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}

trap cleanup EXIT

if [ "${EUID}" -ne 0 ]; then
    die "请使用 root 权限运行此脚本，例如: curl -fsSL URL | sudo bash"
fi

for cmd in awk cat chmod chown cmp cp curl date install mktemp rm ssh-keygen; do
    command -v "${cmd}" >/dev/null 2>&1 || die "缺少必要命令: ${cmd}"
done

SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
if [ -z "${SSHD_BIN}" ] && [ -x /usr/sbin/sshd ]; then
    SSHD_BIN="/usr/sbin/sshd"
fi
[ -n "${SSHD_BIN}" ] || die "缺少必要命令: sshd"

TMP_DIR="$(mktemp -d)"

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
                warn "请输入 y 或 n" >&2
                ;;
        esac
    done
}

valid_github_user() {
    local user="$1"

    [[ "${user}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] && [[ ! "${user}" =~ -$ ]]
}

choose_github_user() {
    local user

    while true; do
        user="$(read_input "请输入 GitHub 用户名 [${DEFAULT_GITHUB_USER}]: ")"
        user="${user:-${DEFAULT_GITHUB_USER}}"

        if valid_github_user "${user}"; then
            echo "${user}"
            return 0
        fi

        warn "GitHub 用户名格式无效，请重新输入" >&2
    done
}

valid_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

detect_current_ssh_port() {
    local port

    port="$("${SSHD_BIN}" -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    if valid_port "${port}"; then
        echo "${port}"
        return 0
    fi

    echo "22"
}

detect_dropin_ssh_port() {
    local port

    if [ ! -f "${SSHD_DROPIN}" ]; then
        return 1
    fi

    port="$(awk '
        /^[[:space:]]*#/ { next }
        tolower($1) == "port" { print $2; exit }
    ' "${SSHD_DROPIN}")"

    if valid_port "${port}"; then
        echo "${port}"
        return 0
    fi

    return 1
}

choose_ssh_port() {
    local current_port="$1"
    local port

    if read_yes_no "是否替换 SSH 端口？当前检测为 ${current_port} [y/N]: " "n"; then
        while true; do
            port="$(read_input "请输入新的 SSH 端口 [1-65535]: ")"

            if valid_port "${port}"; then
                echo "${port}"
                return 0
            fi

            warn "端口无效，请输入 1-65535 之间的数字" >&2
        done
    fi

    echo "${current_port}"
}

fetch_github_keys() {
    local github_user="$1"
    local output="$2"
    local raw_output="${TMP_DIR}/github.keys.raw"
    local url="https://github.com/${github_user}.keys"

    log "下载 GitHub SSH 公钥: ${url}"
    if ! curl -fsSL --retry 3 --connect-timeout 10 "${url}" -o "${raw_output}"; then
        die "下载公钥失败，请确认 GitHub 用户名和网络连接"
    fi

    awk 'NF { sub(/\r$/, ""); print }' "${raw_output}" > "${output}"
}

validate_public_keys() {
    local file="$1"
    local one_key="${TMP_DIR}/one_key.pub"
    local line
    local line_no=0
    local count=0

    while IFS= read -r line || [ -n "${line}" ]; do
        line_no=$((line_no + 1))
        [ -z "${line}" ] && continue

        printf "%s\n" "${line}" > "${one_key}"
        if ! ssh-keygen -l -f "${one_key}" >/dev/null 2>&1; then
            die "下载的公钥第 ${line_no} 行不是有效 SSH 公钥"
        fi

        count=$((count + 1))
    done < "${file}"

    if [ "${count}" -eq 0 ]; then
        die "没有获取到有效公钥，请先在 GitHub 账号中添加 SSH public key"
    fi

    echo "${count}"
}

print_public_key_fingerprints() {
    local file="$1"
    local one_key="${TMP_DIR}/fingerprint_key.pub"
    local line

    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        printf "%s\n" "${line}" > "${one_key}"
        ssh-keygen -l -f "${one_key}"
    done < "${file}"
}

install_authorized_keys() {
    local source="$1"
    local backup

    install -m 0700 -d "${ROOT_SSH_DIR}"

    if [ -L "${AUTHORIZED_KEYS}" ]; then
        die "${AUTHORIZED_KEYS} 是符号链接，请先手动处理后再运行"
    fi

    if [ -f "${AUTHORIZED_KEYS}" ]; then
        backup="${AUTHORIZED_KEYS}.bak.${RUN_ID}"
        cp "${AUTHORIZED_KEYS}" "${backup}"
        chmod 600 "${backup}"
        warn "已备份原公钥文件到 ${backup}"
    fi

    cp "${source}" "${AUTHORIZED_KEYS}"
    chown root:root "${ROOT_SSH_DIR}" "${AUTHORIZED_KEYS}"
    chmod 700 "${ROOT_SSH_DIR}"
    chmod 600 "${AUTHORIZED_KEYS}"
}

backup_tracked_file() {
    local file="$1"
    local backup
    local i

    for i in "${!RESTORE_FILES[@]}"; do
        if [ "${RESTORE_FILES[$i]}" = "${file}" ]; then
            return 0
        fi
    done

    if [ -f "${file}" ]; then
        backup="${file}.bak.${RUN_ID}"
        cp "${file}" "${backup}"
    else
        backup="__missing__"
    fi

    RESTORE_FILES+=("${file}")
    RESTORE_BACKUPS+=("${backup}")
}

restore_tracked_files() {
    local i file backup

    for i in "${!RESTORE_FILES[@]}"; do
        file="${RESTORE_FILES[$i]}"
        backup="${RESTORE_BACKUPS[$i]}"

        if [ "${backup}" = "__missing__" ]; then
            rm -f "${file}"
        else
            cp "${backup}" "${file}"
        fi
    done
}

ensure_sshd_include_dir() {
    local tmp

    install -m 0755 -d "${SSHD_CONFIG_DIR}"

    if [ ! -f "${SSHD_CONFIG}" ]; then
        die "找不到 ${SSHD_CONFIG}"
    fi

    if awk '
        /^[[:space:]]*#/ { next }
        $1 == "Include" && $2 == "/etc/ssh/sshd_config.d/*.conf" { found = 1 }
        END { exit found ? 0 : 1 }
    ' "${SSHD_CONFIG}"; then
        return 0
    fi

    log "为 sshd_config 添加 drop-in include"
    backup_tracked_file "${SSHD_CONFIG}"
    tmp="$(mktemp)"
    {
        echo "Include /etc/ssh/sshd_config.d/*.conf"
        cat "${SSHD_CONFIG}"
    } > "${tmp}"
    cp "${tmp}" "${SSHD_CONFIG}"
    rm -f "${tmp}"
}

comment_global_sshd_directives() {
    local file="$1"
    local include_port="$2"
    local tmp
    local directive_names="AuthorizedKeysFile PubkeyAuthentication PasswordAuthentication KbdInteractiveAuthentication ChallengeResponseAuthentication PermitRootLogin"

    [ -f "${file}" ] || return 0

    if [ "${include_port}" = "yes" ]; then
        directive_names="${directive_names} Port"
    fi

    tmp="$(mktemp)"
    awk -v directive_names="${directive_names}" '
        BEGIN {
            split(directive_names, names, " ")
            for (i in names) {
                wanted[tolower(names[i])] = 1
            }
            in_match = 0
        }
        {
            stripped = $0
            sub(/^[[:space:]]+/, "", stripped)
            split(stripped, parts, /[[:space:]]+/)
            key = tolower(parts[1])

            if (tolower(stripped) ~ /^match[[:space:]]/) {
                in_match = 1
            }

            if (!in_match && key in wanted && $0 !~ /^[[:space:]]*#/) {
                print "# vpscript disabled old sshd setting: " $0
                next
            }

            print
        }
    ' "${file}" > "${tmp}"

    if cmp -s "${file}" "${tmp}"; then
        rm -f "${tmp}"
        return 0
    fi

    backup_tracked_file "${file}"
    cp "${tmp}" "${file}"
    rm -f "${tmp}"
}

write_sshd_dropin() {
    local ssh_port="$1"
    local include_port="$2"

    backup_tracked_file "${SSHD_DROPIN}"

    {
        echo "# Managed by vpscript sshkey.sh"
        echo "AuthorizedKeysFile .ssh/authorized_keys"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "ChallengeResponseAuthentication no"
        echo "PermitRootLogin prohibit-password"
        if [ "${include_port}" = "yes" ]; then
            echo "Port ${ssh_port}"
        fi
    } > "${SSHD_DROPIN}"

    chmod 644 "${SSHD_DROPIN}"
}

configure_sshd() {
    local current_port="$1"
    local ssh_port="$2"
    local include_port="no"
    local dropin_port=""
    local file

    if [ "${ssh_port}" != "${current_port}" ]; then
        include_port="yes"
    else
        dropin_port="$(detect_dropin_ssh_port || true)"
        if [ -n "${dropin_port}" ]; then
            include_port="yes"
        fi
    fi

    ensure_sshd_include_dir
    comment_global_sshd_directives "${SSHD_CONFIG}" "${include_port}"

    for file in "${SSHD_CONFIG_DIR}"/*.conf; do
        [ -e "${file}" ] || continue
        [ "${file}" = "${SSHD_DROPIN}" ] && continue
        comment_global_sshd_directives "${file}" "${include_port}"
    done

    write_sshd_dropin "${ssh_port}" "${include_port}"
}

validate_sshd_config() {
    log "验证 SSH 配置"

    if ! "${SSHD_BIN}" -t; then
        restore_tracked_files
        die "SSH 配置校验失败，已回滚 sshd 配置文件"
    fi
}

open_ufw_port_if_needed() {
    local ssh_port="$1"

    if ! command -v ufw >/dev/null 2>&1; then
        return 0
    fi

    if ufw status 2>/dev/null | awk 'tolower($0) ~ /^status:[[:space:]]*active/ { found = 1 } END { exit found ? 0 : 1 }'; then
        log "检测到 UFW 已启用，放行 ${ssh_port}/tcp"
        if ! ufw allow "${ssh_port}/tcp" >/dev/null; then
            warn "UFW 放行 ${ssh_port}/tcp 失败，请手动检查防火墙规则"
        fi
    fi
}

reload_sshd() {
    log "重载 SSH 服务"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl reload ssh 2>/dev/null; then
            return 0
        fi

        if systemctl reload sshd 2>/dev/null; then
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        if service ssh reload 2>/dev/null; then
            return 0
        fi

        if service sshd reload 2>/dev/null; then
            return 0
        fi
    fi

    die "无法重载 SSH 服务，请手动执行: systemctl reload ssh"
}

detect_public_hostname() {
    local host

    host="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "${host}" ]; then
        echo "${host}"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        host="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
        if [ -n "${host}" ]; then
            echo "${host}"
            return 0
        fi
    fi

    echo "0.0.0.0"
}

print_windows_ssh_config() {
    local hostname="$1"
    local ssh_port="$2"

    echo -e "${CYAN}========================================================${RESET}"
    echo "Windows SSH config 可复制以下内容："
    echo
    echo "Host example"
    echo "    Hostname ${hostname}"
    echo "    User root"
    if [ "${ssh_port}" != "22" ]; then
        echo "    Port ${ssh_port}"
    fi
    echo "    IdentityFile ~/.ssh/id_ed25519"
    echo -e "${CYAN}========================================================${RESET}"
}

main() {
    local github_user
    local keys_file="${TMP_DIR}/github.keys"
    local key_count
    local current_port
    local ssh_port
    local public_hostname

    echo -e "${CYAN}========================================================${RESET}"
    echo -e "${CYAN}       Root SSH 公钥登录一键配置${RESET}"
    echo -e "${CYAN}========================================================${RESET}"

    github_user="$(choose_github_user)"
    current_port="$(detect_current_ssh_port)"
    ssh_port="$(choose_ssh_port "${current_port}")"

    fetch_github_keys "${github_user}" "${keys_file}"
    key_count="$(validate_public_keys "${keys_file}")"

    echo
    log "将用 GitHub 公钥覆盖 ${AUTHORIZED_KEYS}"
    print_public_key_fingerprints "${keys_file}"
    if ! read_yes_no "确认清除原公钥并替换为以上 GitHub 公钥？[Y/n]: " "y"; then
        die "用户取消"
    fi

    install_authorized_keys "${keys_file}"
    configure_sshd "${current_port}" "${ssh_port}"
    validate_sshd_config
    open_ufw_port_if_needed "${ssh_port}"
    reload_sshd

    public_hostname="$(detect_public_hostname)"

    ok "已安装 ${key_count} 个公钥到 ${AUTHORIZED_KEYS}"
    ok "已启用 root 公钥登录，并关闭 SSH 密码登录"
    if [ "${ssh_port}" != "${current_port}" ]; then
        ok "SSH 端口已替换为 ${ssh_port}"
    fi

    print_windows_ssh_config "${public_hostname}" "${ssh_port}"
    warn "不要关闭当前 SSH 会话；请新开终端测试公钥登录成功后再断开。"
}

main "$@"
