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

# ================== IP 详情检测 (双栈) ==================
check_ip_info() {
    local version=$1
    local ip

    if [[ "$version" == "4" ]]; then
        echo -e "\n${CYAN}--- IPv4 网络状态 ---${RESET}"
        ip=$(curl -s -4 --max-time 3 http://icanhazip.com || curl -s -4 --max-time 3 http://ifconfig.me/ip)
    else
        echo -e "\n${CYAN}--- IPv6 网络状态 ---${RESET}"
        ip=$(curl -s -6 --max-time 3 http://icanhazip.com || curl -s -6 --max-time 3 http://ifconfig.co/ip)
    fi

    if [[ -z "$ip" ]]; then
        echo -e "公网状态       : ${YELLOW}未检测到可用公网 IPv${version} 地址${RESET}"
        return
    fi

    echo -e "公网 IP 地址   : ${GREEN}${ip}${RESET}"

    # 请求 ip-api.com 获取 Geo 使用地及 ASN (强制用 v4 请求避免路由未通卡死)
    local geo_api="http://ip-api.com/json/${ip}?fields=country,countryCode,city,isp,org,as,hosting"
    local geo_res=$(curl -s -4 --max-time 5 "$geo_api")
    
    # 请求 ipinfo.io 获取 Whois 注册地
    local whois_api="https://ipinfo.io/${ip}/json"
    local whois_res=$(curl -s -4 --max-time 5 "$whois_api")

    if [[ -n "$geo_res" ]]; then
        local usage_country=$(echo "$geo_res" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        local usage_code=$(echo "$geo_res" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
        local isp=$(echo "$geo_res" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        local as_info=$(echo "$geo_res" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
        local hosting=$(echo "$geo_res" | grep -o '"hosting":true\|"hosting":false' | cut -d':' -f2)

        local reg_code=$(echo "$whois_res" | grep -o '"country": "[^"]*"' | cut -d'"' -f4)
        # 如果获取失败则 fallback 回使用地代码
        [[ -z "$reg_code" ]] && reg_code="$usage_code"

        echo -e "自治系统 (ASN) : ${CYAN}${as_info}${RESET}"
        echo -e "组织 / ISP     : ${CYAN}${isp}${RESET}"
        echo -e "使用地 (Geo)   : ${CYAN}[${usage_code}] ${usage_country}${RESET}"
        echo -e "注册地 (Whois) : ${CYAN}[${reg_code}]${RESET}"

        # 核心逻辑：如果使用地与注册地一致为原生，不一致为广播
        if [[ "$usage_code" == "$reg_code" ]]; then
            echo -e "IP 路由类型    : ${GREEN}原生 IP (Native)${RESET}"
        else
            echo -e "IP 路由类型    : ${RED}广播 IP (Broadcast)${RESET}"
        fi
        
        # 补充：机房与家用宽带区分
        if [[ "$hosting" == "true" ]]; then
            echo -e "IP 业务属性    : ${YELLOW}数据中心/机房 (Hosting)${RESET}"
        else
            echo -e "IP 业务属性    : ${GREEN}住宅/商业宽带 (Residential/ISP)${RESET}"
        fi
    else
        echo -e "${RED}无法获取归属地详情，API 请求超时或限流。${RESET}"
    fi
}

# ================== 状态检测 ==================
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
    
    # 无论 IPv6 状态如何，始终显示 IPv4
    check_ip_info "4"
    
    # 仅当系统启用了 IPv6 且网卡挂载了协议栈时，检测 IPv6
    if [[ "$status" == "0" ]] && [[ -n "$has_inet6" ]]; then
        check_ip_info "6"
    fi
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
        1) enable_ipv6; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        2) disable_ipv6; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        0) echo -e "已退出脚本。"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
    esac
done
