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

# ================== 高精度 IP 详情检测 (Maxmind + IPinfo) ==================
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
    echo -en "正在查询 Maxmind & IPinfo 数据库以进行精准比对...\r"

    # 使用 IP.SB (纯正 Maxmind GeoIP 数据库) 获取使用地
    local geo_res=$(curl -s -4 --max-time 5 "https://api.ip.sb/geoip/${ip}")
    
    # 使用 IPinfo 获取真实的 Whois 注册地和公司属性
    local whois_res=$(curl -s -4 --max-time 5 "https://ipinfo.io/${ip}/json")

    # 清除上一行的提示
    echo -e "\033[2K\r\c"

    if [[ -n "$geo_res" ]]; then
        # 解析 Maxmind (ip.sb)
        local usage_country=$(echo "$geo_res" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        local usage_code=$(echo "$geo_res" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4)
        local asn=$(echo "$geo_res" | grep -o '"asn":[^,]*' | cut -d':' -f2 | tr -d ' ')
        
        # 解析 IPinfo
        local org=$(echo "$whois_res" | grep -o '"org": "[^"]*"' | cut -d'"' -f4 | cut -d' ' -f2-)
        local reg_code=$(echo "$whois_res" | grep -o '"country": "[^"]*"' | cut -d'"' -f4)
        local hosting=$(echo "$whois_res" | grep -o '"hosting": true\|"hosting": false' | cut -d' ' -f2)

        # 容错处理
        [[ -z "$org" ]] && org=$(echo "$geo_res" | grep -o '"organization":"[^"]*"' | cut -d'"' -f4)
        [[ -z "$reg_code" ]] && reg_code="$usage_code"
        
        echo -e "自治系统 (ASN) : ${CYAN}AS${asn} ${org}${RESET}"
        
        # 常见国家名称汉化
        local usage_cn="$usage_country"
        [[ "$usage_code" == "CN" ]] && usage_cn="中国"
        [[ "$usage_code" == "SG" ]] && usage_cn="新加坡"
        [[ "$usage_code" == "US" ]] && usage_cn="美国"
        [[ "$usage_code" == "GB" ]] && usage_cn="英国"
        [[ "$usage_code" == "HK" ]] && usage_cn="香港"
        [[ "$usage_code" == "JP" ]] && usage_cn="日本"
        [[ "$usage_code" == "TW" ]] && usage_cn="台湾"
        
        local reg_cn=""
        [[ "$reg_code" == "CN" ]] && reg_cn="中国"
        [[ "$reg_code" == "SG" ]] && reg_cn="新加坡"
        [[ "$reg_code" == "US" ]] && reg_cn="美国"
        [[ "$reg_code" == "GB" ]] && reg_cn="英国"
        [[ "$reg_code" == "HK" ]] && reg_cn="香港"
        [[ "$reg_code" == "JP" ]] && reg_cn="日本"
        [[ "$reg_code" == "TW" ]] && reg_cn="台湾"

        # 打印比对结果
        echo -e "使用地 (Geo)   : ${CYAN}[${usage_code}] ${usage_cn}${RESET} (Maxmind)"
        
        if [[ -n "$reg_cn" ]]; then
            echo -e "注册地 (Whois) : ${CYAN}[${reg_code}] ${reg_cn}${RESET} (IPinfo)"
        else
            echo -e "注册地 (Whois) : ${CYAN}[${reg_code}]${RESET} (IPinfo)"
        fi

        # 核心判定逻辑：使用地与注册地一致即为原生
        if [[ "$usage_code" == "$reg_code" ]]; then
            echo -e "IP 路由类型    : ${GREEN}原生 IP (Native)${RESET}"
        else
            echo -e "IP 路由类型    : ${RED}广播 IP (Broadcast)${RESET}"
        fi
        
        # 业务属性判定 (综合 IPinfo 标记与常见机房关键字)
        if [[ "$hosting" == "true" || -n $(echo "$org" | grep -i "cloud\|hosting\|datacenter\|datawave\|ocean\|alibaba\|tencent") ]]; then
            echo -e "IP 业务属性    : ${YELLOW}数据中心 / 机房 (Hosting)${RESET}"
        else
            echo -e "IP 业务属性    : ${GREEN}住宅 / 商业宽带 (Residential/ISP)${RESET}"
        fi
    else
        echo -e "${RED}无法获取详细归属地信息，请检查 VPS 对外访问网络。${RESET}"
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
    
    # 强制分别检测 IPv4 和 IPv6，排版清晰
    check_ip_info "4"
    
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
