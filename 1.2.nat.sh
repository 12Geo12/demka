#!/bin/bash
#===============================================================================
# NAT Setup for Demo2026 - Alt Linux (Улучшенная версия)
# Исходник: https://github.com/12Geo12/demka/blob/main/proba.sh
#===============================================================================
# Улучшения:
# - Исправлены ANSI коды цветов
# - Добавлена проверка конфликтов правил
# - Добавлены детальные выводы команд
# - Добавлена проверка связности после настройки
# - Улучшена обработка VLAN интерфейсов
#===============================================================================

#--- Цвета (исправленные ANSI коды) -------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

#--- Функции выводода ---------------------------------------------------------
msg_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
msg_er() { echo -e "${RED}[✗]${NC} $1"; }
msg_in() { echo -e "${BLUE}[i]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[!]${NC} $1"; }
msg_hd() { echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }

#--- Проверка root ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root (su -)"
    exit 1
fi

#--- Заголовок ----------------------------------------------------------------
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${WHITE}${BOLD}NAT Setup for Demo2026 - Improved Version${NC}         ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

#--- Вывод системной информации -----------------------------------------------
msg_hd
echo -e "${WHITE}Системная информация:${NC}"
msg_hd
echo ""
echo -e "  ${BLUE}Hostname:${NC} $(hostname)"
echo -e "  ${BLUE}OS:${NC} $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Unknown')"
echo -e "  ${BLUE}Kernel:${NC} $(uname -r)"
echo -e "  ${BLUE}Date:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

#===============================================================================
# 1. ПРОВЕРКА И УСТАНОВКА IPTABLES
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 1: Проверка iptables${NC}"
msg_hd
echo ""

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_VER=$(iptables --version 2>/dev/null | head -1)
    msg_ok "iptables установлен: ${YELLOW}$IPTABLES_VER${NC}"
else
    msg_in "Установка iptables..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq iptables iptables-ipv6
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q iptables iptables-ipv6
    fi
    msg_ok "iptables установлен"
fi

# Вывод текущих модулей ядра
echo ""
msg_in "Загруженные модули netfilter:"
lsmod 2>/dev/null | grep -E "^(nf_|iptable|ip_tables|x_tables)" | awk '{printf "  • %s\n", $1}' | head -10

#===============================================================================
# 2. ВКЛЮЧЕНИЕ IP FORWARDING
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 2: IP Forwarding${NC}"
msg_hd
echo ""

# Проверка текущего статуса
IP_FWD=$(cat /proc/sys/net/ipv4/ip_forward)
echo -e "  ${BLUE}Текущий статус:${NC} $IP_FWD"

if [ "$IP_FWD" != "1" ]; then
    msg_in "Включение IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# Постоянная настройка
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    msg_ok "Добавлено в /etc/sysctl.conf"
fi

# Дополнительные параметры sysctl для роутера
SYSCTL_PARAMS=(
    "net.ipv4.conf.all.forwarding=1"
    "net.ipv4.conf.default.forwarding=1"
)

for param in "${SYSCTL_PARAMS[@]}"; do
    KEY=$(echo "$param" | cut -d'=' -f1)
    VAL=$(echo "$param" | cut -d'=' -f2)
    if ! grep -q "^$KEY" /etc/sysctl.conf 2>/dev/null; then
        echo "$param" >> /etc/sysctl.conf
    fi
    sysctl -w "$param" >/dev/null 2>&1
done

msg_ok "IP forwarding включен"

# Вывод
echo ""
echo -e "${CYAN}Вывод команды:${NC} ${YELLOW}sysctl net.ipv4.ip_forward${NC}"
sysctl net.ipv4.ip_forward

#===============================================================================
# 3. ВЫБОР ИНТЕРФЕЙСОВ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 3: Выбор интерфейсов${NC}"
msg_hd
echo ""

# Получаем список интерфейсов с информацией
echo -e "${CYAN}Доступные интерфейсы:${NC}"
echo ""

IFACE_LIST="/tmp/nat_ifaces_$$"
> "$IFACE_LIST"

idx=1
for iface in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    driver=$(basename "$(readlink "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null || echo "-")
    
    # Определяем тип интерфейса
    if [[ "$iface" == *"."* ]]; then
        iface_type="${CYAN}VLAN${NC}"
    elif [ -d "/sys/class/net/${iface}/wireless" ]; then
        iface_type="${PURPLE}WLAN${NC}"
    elif [ "$driver" != "-" ]; then
        iface_type="${GREEN}ETH${NC}"
    else
        iface_type="${YELLOW}VIRT${NC}"
    fi
    
    # Цвет статуса
    if [ "$status" = "up" ]; then
        status_show="${GREEN}UP${NC}"
    else
        status_show="${YELLOW}${status}${NC}"
    fi
    
    printf "  ${GREEN}[%2d]${NC} %-18s [%b] %-6s IP: ${CYAN}%-18s${NC} Driver: %s\n" \
        "$idx" "$iface" "$status_show" "$iface_type" "${ip_addr:-N/A}" "$driver"
    
    echo "$iface" >> "$IFACE_LIST"
    idx=$((idx + 1))
done

TOTAL=$((idx - 1))

echo ""
echo -e "${YELLOW}Выберите WAN интерфейс (к ISP/Internet):${NC}"
read -r -p "Номер [1-$TOTAL]: " wan_num

# Валидация
case "$wan_num" in
    ''|*[!0-9]*)
        msg_er "Неверный выбор"
        rm -f "$IFACE_LIST"
        exit 1
        ;;
esac

if [ "$wan_num" -lt 1 ] || [ "$wan_num" -gt "$TOTAL" ]; then
    msg_er "Неверный диапазон"
    rm -f "$IFACE_LIST"
    exit 1
fi

WAN=$(sed -n "${wan_num}p" "$IFACE_LIST")
msg_ok "WAN интерфейс: ${YELLOW}$WAN${NC}"

# Получаем IP WAN для информации
WAN_IP=$(ip -4 addr show "$WAN" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
echo -e "  ${BLUE}IP адрес:${NC} $WAN_IP"

#===============================================================================
# 4. АВТООПРЕДЕЛЕНИЕ LAN
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 4: LAN интерфейсы${NC}"
msg_hd
echo ""

LAN_FILE="/tmp/nat_lan_$$"
LAN_NETS_FILE="/tmp/nat_nets_$$"
> "$LAN_FILE"
> "$LAN_NETS_FILE"

echo -e "${CYAN}Обнаруженные LAN подсети:${NC}"
echo ""

while IFS= read -r iface; do
    if [ "$iface" != "$WAN" ]; then
        # Получаем все IP адреса интерфейса (включая VLAN)
        while IFS= read -r ip_net; do
            [ -z "$ip_net" ] && continue
            
            # Определяем VLAN ID если есть
            if [[ "$iface" == *"."* ]]; then
                VID=$(echo "$iface" | cut -d'.' -f2)
                VLAN_INFO="${CYAN}(VLAN $VID)${NC}"
            else
                VLAN_INFO=""
            fi
            
            echo "$iface" >> "$LAN_FILE"
            echo "$ip_net" >> "$LAN_NETS_FILE"
            
            # Вычисляем префикс
            PREFIX=$(echo "$ip_net" | cut -d'/' -f2)
            IP=$(echo "$ip_net" | cut -d'/' -f1)
            
            echo -e "  ${GREEN}•${NC} $iface ${YELLOW}→${NC} $ip_net $VLAN_INFO"
        done < <(ip -o -f inet addr show "$iface" 2>/dev/null | awk '{print $4}')
    fi
done < "$IFACE_LIST"

rm -f "$IFACE_LIST"

LAN_COUNT=$(wc -l < "$LAN_FILE")

if [ "$LAN_COUNT" -eq 0 ]; then
    msg_er "LAN интерфейсы не найдены"
    rm -f "$LAN_FILE" "$LAN_NETS_FILE"
    exit 1
fi

msg_ok "Найдено LAN подсетей: ${YELLOW}$LAN_COUNT${NC}"

#===============================================================================
# 5. ПОДТВЕРЖДЕНИЕ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}Сводка конфигурации:${NC}"
msg_hd
echo ""
echo -e "  ${BLUE}WAN:${NC} $WAN (${WAN_IP:-N/A})"
echo -e "  ${BLUE}LAN интерфейсы:${NC}"
while IFS= read -r iface && IFS= read -r net <&3; do
    echo -e "    ${GREEN}•${NC} $iface ${YELLOW}→${NC} $net"
done < "$LAN_FILE" 3< "$LAN_NETS_FILE"

echo ""
echo -e "${YELLOW}Очистить существующие правила NAT?${NC}"
echo "  1) Да (рекомендуется)"
echo "  2) Нет (добавить к существующим)"
read -r -p "Выбор [1-2]: " clear_choice

echo ""
read -r -p "Применить NAT? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; rm -f "$LAN_FILE" "$LAN_NETS_FILE"; exit 0 ;;
esac

#===============================================================================
# 6. НАСТРОЙКА NAT
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 5: Настройка NAT${NC}"
msg_hd
echo ""

# Очистка если выбрано
case "$clear_choice" in
    1)
        msg_in "Очистка правил..."
        iptables -t nat -F 2>/dev/null
        iptables -t mangle -F 2>/dev/null
        iptables -F FORWARD 2>/dev/null
        iptables -X FORWARD 2>/dev/null
        msg_ok "Правила очищены"
        ;;
esac

# MASQUERADE правила
echo ""
msg_in "Добавление MASQUERADE правил..."

while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        iptables -t nat -A POSTROUTING -o "$WAN" -s "$net" -j MASQUERADE
        echo -e "  ${GREEN}✓${NC} MASQUERADE: ${YELLOW}$net${NC} → $WAN"
    fi
done < "$LAN_FILE" 3< "$LAN_NETS_FILE"

msg_ok "NAT правила добавлены"

#===============================================================================
# 7. НАСТРОЙКА FORWARD
#===============================================================================
echo ""
msg_in "Настройка FORWARD цепочки..."

# Разрешаем established/related
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
echo -e "  ${GREEN}✓${NC} ESTABLISHED,RELATED разрешены"

# LAN -> WAN
while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        iptables -A FORWARD -i "$iface" -o "$WAN" -s "$net" -j ACCEPT
        echo -e "  ${GREEN}✓${NC} FORWARD: $iface → $WAN"
    fi
done < "$LAN_FILE" 3< "$LAN_NETS_FILE"

# WAN -> LAN (ответный трафик)
while IFS= read -r iface; do
    iptables -A FORWARD -i "$WAN" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT
done < "$LAN_FILE"

# Между LAN (VLAN routing)
if [ "$LAN_COUNT" -gt 1 ]; then
    echo ""
    msg_in "Настройка маршрутизации между VLAN..."
    
    while IFS= read -r iface1; do
        while IFS= read -r iface2; do
            if [ "$iface1" != "$iface2" ]; then
                iptables -A FORWARD -i "$iface1" -o "$iface2" -j ACCEPT
                echo -e "  ${GREEN}✓${NC} $iface1 ↔ $iface2"
            fi
        done < "$LAN_FILE"
    done < "$LAN_FILE"
fi

msg_ok "FORWARD настроен"

rm -f "$LAN_FILE" "$LAN_NETS_FILE"

#===============================================================================
# 8. СОХРАНЕНИЕ ПРАВИЛ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 6: Сохранение правил${NC}"
msg_hd
echo ""

msg_in "Сохранение правил iptables..."

if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables
    msg_ok "Сохранено: ${YELLOW}/etc/sysconfig/iptables${NC}"
elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
    msg_ok "Сохранено: ${YELLOW}/etc/iptables/rules.v4${NC}"
else
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    msg_ok "Сохранено: ${YELLOW}/etc/sysconfig/iptables${NC}"
fi

# Включение сервиса
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^iptables.service"; then
        systemctl enable iptables --now 2>/dev/null
        msg_ok "Сервис iptables включен"
    fi
fi

#===============================================================================
# 9. ВЫВОД РЕЗУЛЬТАТОВ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 7: Проверка конфигурации${NC}"
msg_hd
echo ""

echo -e "${CYAN}>>> Вывод команды: iptables -t nat -L -n -v --line-numbers${NC}"
echo ""
iptables -t nat -L -n -v --line-numbers 2>/dev/null

echo ""
echo -e "${CYAN}>>> Вывод команды: iptables -L FORWARD -n -v --line-numbers${NC}"
echo ""
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -30

echo ""
echo -e "${CYAN}>>> Вывод команды: ip route show${NC}"
echo ""
ip route show

echo ""
echo -e "${CYAN}>>> Вывод команды: cat /proc/sys/net/ipv4/ip_forward${NC}"
echo ""
cat /proc/sys/net/ipv4/ip_forward

#===============================================================================
# 10. ПРОВЕРКА СВЯЗНОСТИ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 8: Проверка связности${NC}"
msg_hd
echo ""

# Проверка WAN шлюза
WAN_GW=$(ip route show default 2>/dev/null | awk '{print $3}')
if [ -n "$WAN_GW" ]; then
    echo -e "${CYAN}>>> Пинг до WAN шлюза ($WAN_GW):${NC}"
    if ping -c 3 -W 2 "$WAN_GW" &>/dev/null; then
        msg_ok "WAN шлюз доступен"
    else
        msg_wa "WAN шлюз недоступен"
    fi
fi

# Проверка интернета
echo ""
echo -e "${CYAN}>>> Пинг до 8.8.8.8 (Google DNS):${NC}"
if ping -c 3 -W 3 8.8.8.8 &>/dev/null; then
    msg_ok "Интернет доступен"
    ping -c 3 8.8.8.8 2>/dev/null | tail -2
else
    msg_wa "8.8.8.8 недоступен - проверьте WAN подключение"
fi

# Проверка DNS
echo ""
echo -e "${CYAN}>>> Разрешение DNS (ya.ru):${NC}"
if host ya.ru &>/dev/null; then
    msg_ok "DNS работает"
    host ya.ru 2>/dev/null | head -2
else
    msg_wa "DNS не работает"
fi

#===============================================================================
# ИТОГ
#===============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC} ${WHITE}${BOLD}NAT УСПЕШНО НАСТРОЕН!${NC}                                ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}WAN:${NC} $WAN"
echo -e "  ${BLUE}LAN подсетей:${NC} $LAN_COUNT"
echo ""
echo -e "${CYAN}Для проверки на клиенте:${NC}"
echo -e "  ${YELLOW}ping 8.8.8.8${NC}      - проверить связь"
echo -e "  ${YELLOW}ping ya.ru${NC}        - проверить DNS"
echo -e "  ${YELLOW}curl ifconfig.me${NC}  - узнать внешний IP"
echo ""
echo -e "${CYAN}Управление:${NC}"
echo -e "  ${YELLOW}iptables -t nat -L -n -v${NC}  - список NAT правил"
echo -e "  ${YELLOW}iptables -L FORWARD -n${NC}    - список FORWARD"
echo -e "  ${YELLOW}iptables-save${NC}             - сохранить правила"
echo ""

# Логирование
echo "$(date '+%Y-%m-%d %H:%M:%S') - NAT configured: WAN=$WAN, LAN_COUNT=$LAN_COUNT" >> /var/log/nat-setup.log 2>/dev/null
