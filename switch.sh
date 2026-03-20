#!/bin/bash
#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# - Проверка конфликтов IP
# - Выбор Router ID
# - Вывод полезных команд
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Функция определения сети (без ipcalc)
get_network_from_iface() {
    local iface=$1
    local ip_mask=$(ip -4 addr show dev "$iface" | grep -oP 'inet \K[\d./]+')
    if [[ -z "$ip_mask" ]]; then return; fi
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
    local IFS='.'; read -r i1 i2 i3 i4 <<< "$ip"
    local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    local ip_int=$(( (i1 << 24) | (i2 << 16) | (i3 << 8) | i4 ))
    local net_int=$(( ip_int & mask ))
    echo "$(( (net_int >> 24) & 0xFF )).$(( (net_int >> 16) & 0xFF )).$(( (net_int >> 8) & 0xFF )).$(( net_int & 0xFF ))/$cidr"
}

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

#===============================================================================
# НАЧАЛО
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗"
echo "║         FRR OSPF/GRE
