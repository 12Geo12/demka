#!/bin/bash
#===============================================================================
# NAT Setup for Demo2026 - Alt Linux
# На основе: https://github.com/12Geo12/demka/blob/main/1.2.nat.sh
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Вывод
msg_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
msg_er() { echo -e "${RED}[✗]${NC} $1"; }
msg_in() { echo -e "${BLUE}[i]${NC} $1"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root (su -)"
    exit 1
fi

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${WHITE}NAT Setup for Demo2026${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

# Проверка и установка iptables
echo ""
msg_in "Проверка iptables..."
if ! command -v iptables >/dev/null 2>&1; then
    msg_in "Установка iptables..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y iptables
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iptables
    fi
fi
msg_ok "iptables установлен"

# Включение IP forwarding
echo ""
msg_in "Проверка IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
msg_ok "IP forwarding включен"

# Вопрос об очистке
echo ""
echo -e "${YELLOW}Очистить существующие правила NAT?${NC}"
echo "  1) Да"
echo "  2) Нет"
read -r -p "Выбор [1-2]: " clear_choice

case "$clear_choice" in
    1)
        msg_in "Очистка правил..."
        iptables -t nat -F 2>/dev/null
        iptables -F FORWARD 2>/dev/null
        iptables -t mangle -F 2>/dev/null
        msg_ok "Правила очищены"
        ;;
esac

# Получаем список интерфейсов
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}Доступные интерфейсы:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# Создаём временный файл со списком
TMPFILE="/tmp/nat_ifaces_$$"
ls /sys/class/net | grep -v lo > "$TMPFILE"

idx=1
while IFS= read -r iface; do
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    
    # Цвет статуса
    if [ "$status" = "up" ]; then
        status_show="${GREEN}UP${NC}"
    else
        status_show="${YELLOW}$status${NC}"
    fi
    
    printf "  ${GREEN}[%2d]${NC} %-15s [%b] IP: %s\n" "$idx" "$iface" "$status_show" "$ip_addr"
    echo "$iface" >> /tmp/nat_iface_list_$$
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"
TOTAL=$((idx - 1))

echo ""
echo -e "${YELLOW}Выберите WAN интерфейс (к ISP/Internet):${NC}"
read -r -p "Номер [1-$TOTAL]: " wan_num

case "$wan_num" in
    ''|*[!0-9]*)
        msg_er "Неверный выбор"
        rm -f /tmp/nat_iface_list_$$
        exit 1
        ;;
esac

WAN=$(sed -n "${wan_num}p" /tmp/nat_iface_list_$$)
msg_ok "WAN интерфейс: $WAN"

# Автоматически определяем LAN интерфейсы
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}LAN интерфейсы (все кроме WAN):${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"

LAN_FILE="/tmp/nat_lan_$$"
> "$LAN_FILE"
LAN_NETS_FILE="/tmp/nat_nets_$$"
> "$LAN_NETS_FILE"

while IFS= read -r iface; do
    if [ "$iface" != "$WAN" ]; then
        ip_net=$(ip -o -f inet addr show "$iface" 2>/dev/null | awk '{print $4}')
        if [ -n "$ip_net" ]; then
            echo "$iface" >> "$LAN_FILE"
            echo "$ip_net" >> "$LAN_NETS_FILE"
            echo -e "  ${GREEN}•${NC} $iface ${YELLOW}→${NC} $ip_net"
        fi
    fi
done < /tmp/nat_iface_list_$$

rm -f /tmp/nat_iface_list_$$

LAN_COUNT=$(wc -l < "$LAN_FILE")

if [ "$LAN_COUNT" -eq 0 ]; then
    msg_er "LAN интерфейсы не найдены"
    rm -f "$LAN_FILE" "$LAN_NETS_FILE"
    exit 1
fi

msg_ok "Найдено LAN интерфейсов: $LAN_COUNT"

# Подтверждение
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${WHITE}WAN:${NC} $WAN"
echo -e "${WHITE}LAN:${NC} $(cat "$LAN_FILE" | tr '\n' ' ')"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"

echo ""
read -r -p "Применить NAT? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; rm -f "$LAN_FILE" "$LAN_NETS_FILE"; exit 0 ;;
esac

# Настройка NAT
echo ""
echo -e "${CYAN}Настройка NAT правил...${NC}"
echo ""

# Читаем LAN интерфейсы и сети
idx=0
while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        echo -e "  ${GREEN}NAT:${NC} $iface ($net) -> $WAN"
        iptables -t nat -A POSTROUTING -o "$WAN" -s "$net" -j MASQUERADE
    fi
    idx=$((idx + 1))
done < "$LAN_FILE" 3< "$LAN_NETS_FILE"

# Настройка FORWARD
echo ""
echo -e "${CYAN}Настройка FORWARD цепочки...${NC}"
echo ""

# 1. Разрешаем установленные соединения
echo -e "  ${GREEN}Разрешение ESTABLISHED,RELATED...${NC}"
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 2. Разрешаем LAN -> WAN
idx=0
while IFS= read -r iface && IFS= read -r net <&3; do
    if [ -n "$net" ]; then
        echo -e "  ${GREEN}FORWARD:${NC} $iface -> $WAN"
        iptables -A FORWARD -i "$iface" -o "$WAN" -s "$net" -j ACCEPT
    fi
    idx=$((idx + 1))
done < "$LAN_FILE" 3< "$LAN_NETS_FILE"

# 3. Разрешаем WAN -> LAN (ответный трафик)
while IFS= read -r iface; do
    echo -e "  ${GREEN}FORWARD:${NC} $WAN -> $iface (ответный)"
    iptables -A FORWARD -i "$WAN" -o "$iface" -j ACCEPT
done < "$LAN_FILE"

# 4. Разрешаем между LAN (VLAN <-> VLAN)
if [ "$LAN_COUNT" -gt 1 ]; then
    echo ""
    echo -e "${CYAN}Настройка пересылки между LAN...${NC}"
    
    while IFS= read -r iface1; do
        while IFS= read -r iface2; do
            if [ "$iface1" != "$iface2" ]; then
                echo -e "  ${GREEN}FORWARD:${NC} $iface1 <-> $iface2"
                iptables -A FORWARD -i "$iface1" -o "$iface2" -j ACCEPT
            fi
        done < "$LAN_FILE"
    done < "$LAN_FILE"
fi

rm -f "$LAN_FILE" "$LAN_NETS_FILE"

# Сохранение правил
echo ""
msg_in "Сохранение правил..."

if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables
    msg_ok "Правила сохранены: /etc/sysconfig/iptables"
elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
    msg_ok "Правила сохранены: /etc/iptables/rules.v4"
else
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    msg_ok "Правила сохранены: /etc/sysconfig/iptables"
fi

# Включение сервиса iptables
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^iptables.service"; then
        systemctl enable iptables --now 2>/dev/null
        msg_ok "Сервис iptables включен"
    fi
fi

# Показать результат
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${WHITE}NAT таблица:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
iptables -t nat -L -n -v --line-numbers 2>/dev/null | head -20

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${WHITE}FORWARD цепочка:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20

# Итог
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  NAT настроен!                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${WHITE}WAN:${NC} $WAN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}ping 8.8.8.8${NC}      - проверить связь"
echo -e "  ${YELLOW}ping google.com${NC}  - проверить DNS"
echo ""
echo -e "${YELLOW}На клиенте:${NC}"
echo -e "  ${WHITE}echo 'nameserver 8.8.8.8' > /etc/resolv.conf${NC}"
echo -e "  ${WHITE}ping 8.8.8.8${NC}"
