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

# ================== 极速高精度 IP 属性检测 ==================
fetch_ip_details() {
    local version=$1
    local ip=$2
    
    echo -e "\n${CYAN}--- IPv${version} 网络状态 ---${RESET}"
    if [[ -z "$ip" ]]; then
        echo -e "公网状态       : ${YELLOW}未获取到公网 IP (请检查路由或网络配置)${RESET}"
        return
    fi
    echo -e "公网 IP 地址   : ${GREEN}${ip}${RESET}"
    
    # 极速调用专业商业接口，直接分离 Geo(使用地) 和 Whois(注册地)
    local api_url="https://api.ipapi.is/?q=${ip}"
    local ip_data
    
    if [[ "$version" == "4" ]]; then
        ip_data=$(curl -s -4 --max-time 3 "$api_url")
    else
        ip_data=$(curl -s -6 --max-time 3 "$api_url")
    fi
    
    if [[ -z "$ip_data" || "$ip_data" == *"error"* ]]; then
        echo -e "${RED}数据查询超时或被限流，无法获取详细归属地。${RESET}"
        return
    fi

    # 轻量级文本解析，摆脱依赖
    local usage_code=$(echo "$ip_data" | grep -A 5 '"location":' | grep -o '"country_code": "[^"]*"' | cut -d'"' -f4 | head -n 1)
    local usage_country=$(echo "$ip_data" | grep -A 5 '"location":' | grep -o '"country": "[^"]*"' | cut -d'"' -f4 | head -n 1)
    
    local reg_code=$(echo "$ip_data" | grep -A 5 '"asn":' | grep -o '"country": "[^"]*"' | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]' | head -n 1)
    local asn_num=$(echo "$ip_data" | grep -A 5 '"asn":' | grep -o '"asn": [0-9]*' | cut -d' ' -f2 | head -n 1)
    local org=$(echo "$ip_data" | grep -A 5 '"company":' | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | head -n 1)
    local is_dc=$(echo "$ip_data" | grep -o '"is_datacenter": \(true\|false\)' | cut -d' ' -f2 | head -n 1)

    [[ -z "$reg_code" ]] && reg_code="$usage_code"
    [[ -z "$usage_country" ]] && usage_country="$usage_code"

    # 常见地区简易汉化
    [[ "$usage_code" == "CN" ]] && usage_country="中国"
    [[ "$usage_code" == "SG" ]] && usage_country="新加坡"
    [[ "$usage_code" == "US" ]] && usage_country="美国"
    [[ "$usage_code" == "GB" ]] && usage_country="英国"
    [[ "$usage_code" == "HK" ]] && usage_country="香港"
    [[ "$usage_code" == "JP" ]] && usage_country="日本"
    [[ "$usage_code" == "TW" ]] && usage_country="台湾"

    echo -e "自治系统 (ASN) : ${CYAN}AS${asn_num} ${org}${RESET}"
    echo -e "使用地 (Geo)   : ${CYAN}[${usage_code}] ${usage_country}${RESET}"
    echo -e "注册地 (Whois) : ${CYAN}[${reg_code}]${RESET}"

    # 核心判定：使用地与注册地一致即为原生，不一致即为广播
    if [[ "$usage_code" == "$reg_code" ]]; then
        echo -e "IP 路由类型    : ${GREEN}原生 IP (Native)${RESET}"
    else
        echo -e "IP 路由类型    : ${RED}广播 IP (Broadcast)${RESET}"
    fi
    
    # 业务属性判定
    if [[ "$is_dc" == "true" || -n $(echo "$org" | grep -i "cloud\|hosting\|datacenter\|datawave") ]]; then
        echo -e "IP 业务属性    : ${YELLOW}数据中心 / 机房 (Hosting)${RESET}"
    else
        echo -e "IP 业务属性    : ${GREEN}住宅 / 商业宽带 (Residential/ISP)${RESET}"
    fi
}

# ================== 基础状态与 IP 显示 ==================
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
    
    echo -en "正在极速获取 IP 属性分析...\r"
    
    local public_ipv4=$(curl -s -4 --max-time 2 http://icanhazip.com || curl -s -4 --max-time 2 http://ifconfig.me/ip)
    local public_ipv6=""
    
    if [[ "$status" == "0" ]] && [[ -n "$has_inet6" ]]; then
        public_ipv6=$(curl -s -6 --max-time 2 http://icanhazip.com || curl -s -6 --max-time 2 http://ifconfig.co/ip)
    fi

    echo -e "\033[2K\r\c"

    # 执行详情获取
    fetch_ip_details "4" "$public_ipv4"
    
    if [[ "$status" == "0" ]] && [[ -n "$has_inet6" ]]; then
        fetch_ip_details "6" "$public_ipv6"
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
        1) 
            enable_ipv6
            read -n 1 -s -r -p "按任意键返回主菜单刷新状态..." 
            ;;
        2) 
            disable_ipv6
            read -n 1 -s -r -p "按任意键返回主菜单刷新状态..." 
            ;;
        0) 
            echo -e "已退出脚本。"
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选项，请重新输入！${RESET}"
            sleep 1 
            ;;
    esac
done
