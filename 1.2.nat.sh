#!/bin/bash
#===============================================================================
# NAT Setup for Demo2026 - Alt Linux (Совместимая версия)
# Исходник: https://github.com/12Geo12/demka/blob/main/proba.sh
#===============================================================================
# Эта версия использует только стандартные конструкции bash
# без process substitution для максимальной совместимости
#===============================================================================

#--- Цвета --------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

#--- Функции ------------------------------------------------------------------
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[WARN]${NC} $1"; }
line() { echo -e "${CYAN}================================================${NC}"; }

#--- Проверка root ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root: su -"
    exit 1
fi

#--- Заголовок ----------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     NAT Setup for Demo2026 - Compatible Version      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

#===============================================================================
# ЭТАП 1: Проверка iptables
#===============================================================================
line
echo -e "${WHITE}ЭТАП 1: Проверка iptables${NC}"
line
echo ""

if command -v iptables >/dev/null 2>&1; then
    msg_ok "iptables установлен: $(iptables --version 2>&1 | head -1)"
else
    msg_in "Установка iptables..."
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq iptables 2>/dev/null || dnf install -y -q iptables 2>/dev/null
    msg_ok "iptables установлен"
fi

#===============================================================================
# ЭТАП 2: IP Forwarding
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 2: IP Forwarding${NC}"
line
echo ""

# Включаем временно
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Постоянно
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

msg_ok "IP forwarding включен"
echo ""
echo -e "${CYAN}>>> Проверка:${NC}"
echo -e "  ${YELLOW}sysctl net.ipv4.ip_forward${NC}"
sysctl net.ipv4.ip_forward 2>/dev/null

#===============================================================================
# ЭТАП 3: Список интерфейсов
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 3: Выбор интерфейсов${NC}"
line
echo ""

echo -e "${CYAN}Доступные интерфейсы:${NC}"
echo ""

# Создаём временные файлы
IFACE_LIST="/tmp/nat_ifaces_$$"
IFACE_IPS="/tmp/nat_ips_$$"
> "$IFACE_LIST"
> "$IFACE_IPS"

idx=1
for iface in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    
    if [ "$status" = "up" ]; then
        status_str="${GREEN}UP${NC}"
    else
        status_str="${YELLOW}${status}${NC}"
    fi
    
    if [[ "$iface" == *"."* ]]; then
        iface_type="${CYAN}[VLAN]${NC}"
    else
        iface_type="${GREEN}[ETH]${NC}"
    fi
    
    printf "  ${GREEN}[%2d]${NC} %-15s %s %-8s IP: ${YELLOW}%s${NC}\n" \
        "$idx" "$iface" "$status_str" "$iface_type" "${ip_addr:-N/A}"
    
    echo "$iface" >> "$IFACE_LIST"
    echo "$ip_addr" >> "$IFACE_IPS"
    idx=$((idx + 1))
done

TOTAL=$((idx - 1))

echo ""
echo -e "${YELLOW}Выберите WAN интерфейс (к интернету):${NC}"
read -r -p "Номер [1-$TOTAL]: " wan_num

# Проверка ввода
if ! echo "$wan_num" | grep -qE '^[0-9]+$'; then
    msg_er "Неверный ввод"
    rm -f "$IFACE_LIST" "$IFACE_IPS"
    exit 1
fi

if [ "$wan_num" -lt 1 ] || [ "$wan_num" -gt "$TOTAL" ]; then
    msg_er "Выберите от 1 до $TOTAL"
    rm -f "$IFACE_LIST" "$IFACE_IPS"
    exit 1
fi

WAN=$(sed -n "${wan_num}p" "$IFACE_LIST")
WAN_IP=$(sed -n "${wan_num}p" "$IFACE_IPS")
msg_ok "WAN интерфейс: ${YELLOW}$WAN${NC} ($WAN_IP)"

#===============================================================================
# ЭТАП 4: LAN интерфейсы
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 4: LAN подсети${NC}"
line
echo ""

LAN_FILE="/tmp/nat_lan_$$"
LAN_NETS="/tmp/nat_nets_$$"
> "$LAN_FILE"
> "$LAN_NETS"

echo -e "${CYAN}Обнаруженные LAN подсети:${NC}"
echo ""

# Читаем файл построчно (совместимый способ)
exec 3< "$IFACE_LIST"
exec 4< "$IFACE_IPS"
while IFS= read -r iface <&3 && IFS= read -r ip_addr <&4; do
    if [ "$iface" != "$WAN" ] && [ -n "$ip_addr" ]; then
        echo "$iface" >> "$LAN_FILE"
        echo "$ip_addr" >> "$LAN_NETS"
        echo -e "  ${GREEN}•${NC} $iface ${YELLOW}→${NC} $ip_addr"
    fi
done
exec 3<&-
exec 4<&-

rm -f "$IFACE_LIST" "$IFACE_IPS"

LAN_COUNT=$(wc -l < "$LAN_FILE")

if [ "$LAN_COUNT" -eq 0 ]; then
    msg_er "LAN подсети не найдены"
    rm -f "$LAN_FILE" "$LAN_NETS"
    exit 1
fi

msg_ok "Найдено LAN подсетей: ${YELLOW}$LAN_COUNT${NC}"

#===============================================================================
# ЭТАП 5: Подтверждение
#===============================================================================
echo ""
line
echo -e "${WHITE}Конфигурация:${NC}"
line
echo ""
echo -e "  ${BLUE}WAN:${NC} $WAN ($WAN_IP)"
echo -e "  ${BLUE}LAN:${NC}"
while IFS= read -r iface && IFS= read -r net <&3; do
    echo -e "    ${GREEN}•${NC} $iface → $net"
done < "$LAN_FILE" 3< "$LAN_NETS"

echo ""
echo -e "${YELLOW}Очистить старые правила NAT?${NC}"
echo "  1) Да"
echo "  2) Нет"
read -r -p "Выбор [1-2]: " clear_choice

echo ""
read -r -p "Применить NAT? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    msg_in "Отменено"
    rm -f "$LAN_FILE" "$LAN_NETS"
    exit 0
fi

#===============================================================================
# ЭТАП 6: Настройка NAT
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 5: Настройка NAT${NC}"
line
echo ""

# Очистка
if [ "$clear_choice" = "1" ]; then
    msg_in "Очистка правил..."
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F FORWARD 2>/dev/null
    msg_ok "Правила очищены"
fi

# MASQUERADE
echo ""
msg_in "Добавление MASQUERADE правил..."

while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        iptables -t nat -A POSTROUTING -o "$WAN" -s "$net" -j MASQUERADE
        echo -e "  ${GREEN}✓${NC} $net → $WAN"
    fi
done < "$LAN_FILE" 3< "$LAN_NETS"

msg_ok "NAT правила добавлены"

#===============================================================================
# ЭТАП 7: FORWARD цепочка
#===============================================================================
echo ""
msg_in "Настройка FORWARD..."

# Established
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
echo -e "  ${GREEN}✓${NC} ESTABLISHED,RELATED"

# LAN → WAN
while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        iptables -A FORWARD -i "$iface" -o "$WAN" -s "$net" -j ACCEPT
        echo -e "  ${GREEN}✓${NC} $iface → $WAN"
    fi
done < "$LAN_FILE" 3< "$LAN_NETS"

# WAN → LAN (ответный)
while IFS= read -r iface; do
    iptables -A FORWARD -i "$WAN" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT
done < "$LAN_FILE"

# Между VLAN
if [ "$LAN_COUNT" -gt 1 ]; then
    while IFS= read -r iface1; do
        while IFS= read -r iface2; do
            if [ "$iface1" != "$iface2" ]; then
                iptables -A FORWARD -i "$iface1" -o "$iface2" -j ACCEPT
            fi
        done < "$LAN_FILE"
    done < "$LAN_FILE"
    echo -e "  ${GREEN}✓${NC} VLAN routing"
fi

msg_ok "FORWARD настроен"

rm -f "$LAN_FILE" "$LAN_NETS"

#===============================================================================
# ЭТАП 8: Сохранение
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 6: Сохранение${NC}"
line
echo ""

msg_in "Сохранение правил..."
mkdir -p /etc/sysconfig 2>/dev/null
iptables-save > /etc/sysconfig/iptables
msg_ok "Сохранено: /etc/sysconfig/iptables"

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable iptables --now 2>/dev/null
fi

#===============================================================================
# ЭТАП 9: Вывод результатов
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 7: Проверка${NC}"
line
echo ""

echo -e "${CYAN}>>> iptables -t nat -L -n -v --line-numbers${NC}"
echo ""
iptables -t nat -L -n -v --line-numbers 2>/dev/null

echo ""
echo -e "${CYAN}>>> iptables -L FORWARD -n -v --line-numbers | head -20${NC}"
echo ""
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20

echo ""
echo -e "${CYAN}>>> ip route show${NC}"
echo ""
ip route show

echo ""
echo -e "${CYAN}>>> cat /proc/sys/net/ipv4/ip_forward${NC}"
cat /proc/sys/net/ipv4/ip_forward

#===============================================================================
# ЭТАП 10: Проверка связности
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 8: Проверка связности${NC}"
line
echo ""

WAN_GW=$(ip route show default 2>/dev/null | awk '{print $3}')
if [ -n "$WAN_GW" ]; then
    echo -e "${CYAN}>>> ping -c 2 $WAN_GW (шлюз)${NC}"
    if ping -c 2 -W 2 "$WAN_GW" >/dev/null 2>&1; then
        msg_ok "Шлюз доступен"
    else
        msg_wa "Шлюз недоступен"
    fi
fi

echo ""
echo -e "${CYAN}>>> ping -c 2 8.8.8.8 (Google DNS)${NC}"
if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    msg_ok "Интернет доступен"
else
    msg_wa "8.8.8.8 недоступен"
fi

#===============================================================================
# ИТОГ
#===============================================================================
echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              NAT УСПЕШНО НАСТРОЕН!                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "  ${BLUE}WAN:${NC} $WAN"
echo -e "  ${BLUE}LAN подсетей:${NC} $LAN_COUNT"
echo ""
echo -e "${CYAN}Команды для проверки:${NC}"
echo -e "  ${YELLOW}iptables -t nat -L -n -v${NC}   - список NAT"
echo -e "  ${YELLOW}iptables -L FORWARD -n${NC}     - список FORWARD"
echo ""
echo -e "${CYAN}На клиенте:${NC}"
echo -e "  ${YELLOW}ping 8.8.8.8${NC}"
echo -e "  ${YELLOW}ping ya.ru${NC}"
echo ""

