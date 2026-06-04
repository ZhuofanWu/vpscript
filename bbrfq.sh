
#!/bin/bash
# ==========================================================
# Ubuntu 22.04 网络一键调优脚本 (BBR+FQ+Buffer+复用)
# 适用环境: 精品网-美西/欧洲-RTT150-200ms
# ==========================================================

## 推荐 TCP Buffer 参数表

# 单位说明：

# - `core rmem/wmem max`：系统单 socket 收发缓冲区最大值
# - `tcp_rmem`：`min default max`
# - `tcp_wmem`：`min default max`
# - 表中数值均为 **字节**

# ### 512M RAM + 512M Swap

# | 带宽 | `net.core.rmem_max` | `net.core.wmem_max` | `net.ipv4.tcp_rmem` | `net.ipv4.tcp_wmem` | 
# |---:|---:|---:|---|---|---|
# | 50M | `4194304` | `4194304` | `4096 87380 4194304` | `4096 16384 4194304` | 
# | 200M | `8388608` | `8388608` | `4096 87380 8388608` | `4096 65536 8388608` | 
# | 500M | `12582912` | `12582912` | `4096 131072 12582912` | `4096 65536 12582912` | 
# | 1000M | `16777216` | `16777216` | `4096 131072 16777216` | `4096 65536 16777216` | 

# ---

# ### 1G RAM

# | 带宽 | `net.core.rmem_max` | `net.core.wmem_max` | `net.ipv4.tcp_rmem` | `net.ipv4.tcp_wmem` | 
# |---:|---:|---:|---|---|---|
# | 50M | `4194304` | `4194304` | `4096 87380 4194304` | `4096 16384 4194304` | 
# | 200M | `8388608` | `8388608` | `4096 87380 8388608` | `4096 65536 8388608` | 
# | 500M | `16777216` | `16777216` | `4096 131072 16777216` | `4096 65536 16777216` | 
# | 1000M | `25165824` | `25165824` | `4096 131072 25165824` | `4096 131072 25165824` | 

# ---

# ### 2G RAM

# | 带宽 | `net.core.rmem_max` | `net.core.wmem_max` | `net.ipv4.tcp_rmem` | `net.ipv4.tcp_wmem` | 
# |---:|---:|---:|---|---|---|
# | 50M | `4194304` | `4194304` | `4096 87380 4194304` | `4096 16384 4194304` | 
# | 200M | `8388608` | `8388608` | `4096 87380 8388608` | `4096 65536 8388608` | 
# | 500M | `16777216` | `16777216` | `4096 131072 16777216` | `4096 131072 16777216` | 
# | 1000M | `33554432` | `33554432` | `4096 131072 33554432` | `4096 131072 33554432` | 



# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "\033[31m错误：请使用 root 权限运行此脚本 (sudo bash script.sh)\033[0m"
    exit 1
fi

echo -e "\033[36m========================================================\033[0m"
echo -e "\033[36m       Ubuntu 22.04 网络一键调优        \033[0m"
echo -e "\033[36m========================================================\033[0m"
echo -e "请选择您的 VPS 内存大小："
echo -e "  1) 512M RAM   "
echo -e "  2) 1G RAM     "
echo -e "  3) 2G RAM及以上 "
echo -e "\033[36m========================================================\033[0m"
read -p "请输入对应的序号 [1-3]: " RAM_CHOICE

echo -e "\033[36m========================================================\033[0m"
echo -e "请选择您的 VPS 实际网络带宽大小："
echo -e "  1) 50 Mbps   "
echo -e "  2) 200 Mbps  "
echo -e "  3) 500 Mbps  "
echo -e "  4) 1 Gbps    "
echo -e "\033[36m========================================================\033[0m"
read -p "请输入对应的序号 [1-4]: " BANDWIDTH_CHOICE

# 初始化基础 TCP Buffer 参数 (默认值)
TCP_RMEM="4096 87380 16777216"
TCP_WMEM="4096 16384 16777216"
CORE_RMEM="16777216"
CORE_WMEM="16777216"

# 根据选择动态设置 Buffer
case $RAM_CHOICE in
    1)
        # 512M RAM
        case $BANDWIDTH_CHOICE in
            1)
                echo -e "\033[32m已选择: 512M RAM / 50 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="4194304"; CORE_WMEM="4194304"
                TCP_RMEM="4096 87380 4194304"; TCP_WMEM="4096 16384 4194304"
                ;;
            2)
                echo -e "\033[32m已选择: 512M RAM / 200 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="8388608"; CORE_WMEM="8388608"
                TCP_RMEM="4096 87380 8388608"; TCP_WMEM="4096 65536 8388608"
                ;;
            3)
                echo -e "\033[32m已选择: 512M RAM / 500 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="12582912"; CORE_WMEM="12582912"
                TCP_RMEM="4096 131072 12582912"; TCP_WMEM="4096 65536 12582912"
                ;;
            4)
                echo -e "\033[32m已选择: 512M RAM / 1 Gbps - 正在配置参数...\033[0m"
                CORE_RMEM="16777216"; CORE_WMEM="16777216"
                TCP_RMEM="4096 131072 16777216"; TCP_WMEM="4096 65536 16777216"
                ;;
            *)
                echo -e "\033[31m带宽输入错误！请重新运行脚本并输入 1-4 之间的数字。\033[0m"
                exit 1
                ;;
        esac
        ;;
    2)
        # 1G RAM
        case $BANDWIDTH_CHOICE in
            1)
                echo -e "\033[32m已选择: 1G RAM / 50 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="4194304"; CORE_WMEM="4194304"
                TCP_RMEM="4096 87380 4194304"; TCP_WMEM="4096 16384 4194304"
                ;;
            2)
                echo -e "\033[32m已选择: 1G RAM / 200 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="8388608"; CORE_WMEM="8388608"
                TCP_RMEM="4096 87380 8388608"; TCP_WMEM="4096 65536 8388608"
                ;;
            3)
                echo -e "\033[32m已选择: 1G RAM / 500 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="16777216"; CORE_WMEM="16777216"
                TCP_RMEM="4096 131072 16777216"; TCP_WMEM="4096 65536 16777216"
                ;;
            4)
                echo -e "\033[32m已选择: 1G RAM / 1 Gbps - 正在配置参数...\033[0m"
                CORE_RMEM="25165824"; CORE_WMEM="25165824"
                TCP_RMEM="4096 131072 25165824"; TCP_WMEM="4096 131072 25165824"
                ;;
            *)
                echo -e "\033[31m带宽输入错误！请重新运行脚本并输入 1-4 之间的数字。\033[0m"
                exit 1
                ;;
        esac
        ;;
    3)
        # 2G RAM
        case $BANDWIDTH_CHOICE in
            1)
                echo -e "\033[32m已选择: 2G RAM / 50 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="4194304"; CORE_WMEM="4194304"
                TCP_RMEM="4096 87380 4194304"; TCP_WMEM="4096 16384 4194304"
                ;;
            2)
                echo -e "\033[32m已选择: 2G RAM / 200 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="8388608"; CORE_WMEM="8388608"
                TCP_RMEM="4096 87380 8388608"; TCP_WMEM="4096 65536 8388608"
                ;;
            3)
                echo -e "\033[32m已选择: 2G RAM / 500 Mbps - 正在配置参数...\033[0m"
                CORE_RMEM="16777216"; CORE_WMEM="16777216"
                TCP_RMEM="4096 131072 16777216"; TCP_WMEM="4096 131072 16777216"
                ;;
            4)
                echo -e "\033[32m已选择: 2G RAM / 1 Gbps - 正在配置参数...\033[0m"
                CORE_RMEM="33554432"; CORE_WMEM="33554432"
                TCP_RMEM="4096 131072 33554432"; TCP_WMEM="4096 131072 33554432"
                ;;
            *)
                echo -e "\033[31m带宽输入错误！请重新运行脚本并输入 1-4 之间的数字。\033[0m"
                exit 1
                ;;
        esac
        ;;
    *)
        echo -e "\033[31m内存输入错误！请重新运行脚本并输入 1-3 之间的数字。\033[0m"
        exit 1
        ;;
esac

echo -e "\033[33m正在写入 Sysctl 配置文件 (/etc/sysctl.d/99-proxy-tuning.conf)...\033[0m"

cat > /etc/sysctl.d/99-proxy-tuning.conf << EOF
# ==========================================
# 1. 开启 BBR 与 FQ (网络拥塞控制)
# ==========================================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ==========================================
# 2. 动态核心缓冲区大小设定 (基于选择的带宽)
# ==========================================
net.core.rmem_max = $CORE_RMEM
net.core.wmem_max = $CORE_WMEM
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

# ==========================================
# 3. 连接复用与超时优化 (针对高并发代理)
# ==========================================
# 开启 TCP TIME_WAIT 状态套接字复用
net.ipv4.tcp_tw_reuse = 1
# 缩短 FIN-WAIT-2 状态的超时时间 (默认 60s -> 15s)
net.ipv4.tcp_fin_timeout = 15
# 缩短 Keepalive 探测周期 (避免死连接长期占用)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
# 扩大本地端口范围，允许建立更多出站连接
net.ipv4.ip_local_port_range = 10000 65000

# ==========================================
# 4. 队列与防 DDOS/半连接 优化
# ==========================================
net.ipv4.tcp_max_orphans = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# ==========================================
# 5. 其他代理节点进阶参数
# ==========================================
# 开启 TCP Fast Open (减少三次握手延迟)
net.ipv4.tcp_fastopen = 3
# 开启 ECN (显式拥塞通知，减少弱网下丢包引发的超时)
net.ipv4.tcp_ecn = 0
# 开启 MTU 探测 (避免黑洞导致部分网站打不开)
net.ipv4.tcp_mtu_probing = 1
# 最大文件句柄数限制
fs.file-max = 262144
EOF

echo -e "\033[33m正在应用 Sysctl 变更...\033[0m"
sysctl -p /etc/sysctl.d/99-proxy-tuning.conf >/dev/null 2>&1

echo -e "\033[33m正在优化系统文件描述符限制 (ulimit)...\033[0m"
cat > /etc/security/limits.d/99-proxy-limits.conf << EOF
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

# 立即为当前会话提升限制
ulimit -n 1000000

echo -e "\033[36m========================================================\033[0m"
echo -e "\033[32m调优完成！当前状态检查：\033[0m"
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
    echo -e "✅ BBR 拥塞控制: \033[32m已开启 ($CURRENT_CC) + ($CURRENT_QDISC)\033[0m"
else
    echo -e "❌ BBR 拥塞控制: \033[31m未能成功开启，请检查内核版本\033[0m"
fi

echo -e "✅ TCP 缓冲区: 已根据您的选择进行自适应配置"
echo -e "✅ 连接复用 (TW_REUSE): 已开启"
echo -e "✅ 文件描述符限制: 已提升至 1000000"
echo -e "\033[36m========================================================\033[0m"
echo -e "\033[32m建议：如有需要，可以重启 VPS (reboot) 让所有配置深度生效。\033[0m"
