#!/bin/bash

# ================== 颜色代码 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：修改内核参数需要 root 权限，请使用 root 用户运行此脚本。${RESET}"
   exit 1
fi

# ================== 网络重载模块 ==================
reload_network() {
    echo -e "${YELLOW}--> 正在尝试重载网络服务以触发 IPv6 地址分配...${RESET}"
    if command -v netplan >/dev/null 2>&1; then
        netplan apply >/dev/null 2>&1
    elif systemctl is-active --quiet systemd-networkd; then
        systemctl restart systemd-networkd >/dev/null 2>&1
    elif systemctl is-active --quiet networking; then
        systemctl restart networking >/dev/null 2>&1
    elif systemctl is-active --quiet NetworkManager; then
        systemctl restart NetworkManager >/dev/null 2>&1
    else
        echo -e "${YELLOW}未检测到标准网络重载工具，如果未获取到 IPv6，请手动执行网络重启命令${RESET}"
    fi
    echo -e "正在等待网卡完成 IP 协商 (约 4 秒)..."
    sleep 4
}

# ================== 状态检测 & Check.Place 融合 ==================
check_status() {
    local status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local has_inet6=$(ip a | grep -w inet6)

    echo -e "${CYAN}=========================================================${RESET}"
    echo -e "${CYAN}                 系统级 IPv6 管理工具                    ${RESET}"
    echo -e "${CYAN}=========================================================${RESET}"

    if [[ "$status" == "1" ]]; then
        echo -e "内核 sysctl 状态: ${RED}已禁用 IPv6${RESET}"
    elif [[ "$status" == "0" ]]; then
        echo -e "内核 sysctl 状态: ${GREEN}已启用 IPv6${RESET}"
    else
        echo -e "内核 sysctl 状态: ${YELLOW}未知状态${RESET}"
    fi

    if [[ -z "$has_inet6" ]]; then
        echo -e "网卡接口层状态  : ${RED}未挂载 IPv6 协议栈${RESET}"
    else
        echo -e "网卡接口层状态  : ${GREEN}已分配 IPv6 栈 (至少具备 fe80 本地链路)${RESET}"
    fi
    echo -e "${CYAN}=========================================================${RESET}"
    
    # 融合 Check.Place 核心库进行精准检测
    echo -e "${YELLOW}正在调用 Check.Place 数据库进行高精度 IP 属性检测，请稍候...${RESET}"
    
    # 执行原生检测命令，只输出基础信息面板(-I)
    bash <(curl -Ls https://Check.Place) -I
    
    echo -e "${CYAN}=========================================================${RESET}"
}

# ================== 核心功能 ==================
enable_ipv6() {
    echo -e "\n${YELLOW}--> 正在清理旧的 IPv6 禁用规则...${RESET}"
    sed -i '/net.ipv6.conf.*.disable_ipv6/d' /etc/sysctl.conf

    echo -e "${YELLOW}--> 正在应用启用规则...${RESET}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    
    reload_network
    echo -e "${GREEN}系统级 IPv6 启用流程完毕！${RESET}\n"
    read -n 1 -s -r -p "按任意键刷新面板以查看最新 IP 状态..."
}

disable_ipv6() {
    echo -e "\n${YELLOW}--> 正在清理旧的 IPv6 规则以防冲突...${RESET}"
    sed -i '/net.ipv6.conf.*.disable_ipv6/d' /etc/sysctl.conf

    echo -e "${YELLOW}--> 正在写入永久禁用规则...${RESET}"
    cat >> /etc/sysctl.conf <<EOF
# Script: Disable IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

    echo -e "${YELLOW}--> 正在应用禁用规则...${RESET}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}系统级 IPv6 已成功禁用！所有网卡已关闭 IPv6 协议栈。${RESET}\n"
    read -n 1 -s -r -p "按任意键刷新面板..."
}

# ================== 交互菜单 ==================
while true; do
    clear
    check_status
    
    echo "  1. 启用 IPv6 (Enable)"
    echo "  2. 禁用 IPv6 (Disable)"
    echo "  0. 退出脚本"
    echo -e "${CYAN}=========================================================${RESET}"
    read -p "请输入对应的数字选项: " choice

    case "$choice" in
        1) enable_ipv6 ;;
        2) disable_ipv6 ;;
        0) echo -e "已退出脚本。"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
    esac
done
