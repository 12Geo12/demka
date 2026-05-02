#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026 - Простая версия
# Автоматическое определение интерфейсов, без резервных копий
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DNS_SUFFIX="au-team.irpo"

# Вывод
msg_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
msg_er() { echo -e "${RED}[✗]${NC} $1"; }
msg_in() { echo -e "${BLUE}[i]${NC} $1"; }

# Проверка root
[ "$EUID" -ne 0 ] && { msg_er "Запустите от root"; exit 1; }

# Очистка экрана
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DHCP Server Setup for Demo2026${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

# Автоопределение интерфейсов
echo -e "\n${BLUE}Поиск интерфейсов...${NC}\n"

# Массивы для данных
declare -a IFACES
declare -a IPS
declare -a MASKS
declare -a GATES
declare -a RANGES
declare -a DNS

# Создаём временный файл для вывода
TMPFILE="/tmp/dhcp_ifaces_$$"

# Получаем список интерфейсов
ip -br addr show type vlan > "$TMPFILE" 2>/dev/null
if [ ! -s "$TMPFILE" ]; then
    ip -br addr show | grep -v "^lo" > "$TMPFILE"
fi

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    
    # Определение параметров по IP
    o1=$(echo "$ip" | cut -d'.' -f1)
    o2=$(echo "$ip" | cut -d'.' -f2)
    o3=$(echo "$ip" | cut -d'.' -f3)
    o4=$(echo "$ip" | cut -d'.' -f4)
    
    case "$o3" in
        1)
            net="VLAN100 (SRV-Net)"
            mask="255.255.255.224"
            range="192.168.1.2 192.168.1.30"
            dns_ip="192.168.1.1"
            ;;
        2)
            net="VLAN200 (CLI-Net)"
            mask="255.255.255.240"
            range="192.168.2.2 192.168.2.14"
            dns_ip="192.168.1.2"
            ;;
        3)
            net="VLAN999 (Mgmt)"
            mask="255.255.255.248"
            range="192.168.3.2 192.168.3.6"
            dns_ip="192.168.1.2"
            ;;
        *)
            net="Unknown"
            mask="255.255.255.0"
            range=""
            dns_ip=""
            ;;
    esac
    
    IFACES[$idx]="$iface"
    IPS[$idx]="$ip"
    MASKS[$idx]="$mask"
    GATES[$idx]="$ip"
    RANGES[$idx]="$range"
    DNS[$idx]="$dns_ip"
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface ${YELLOW}→${NC} $ip ${CYAN}($net)${NC}"
    
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"

TOTAL=$idx

[ $TOTAL -eq 0 ] && { msg_er "Интерфейсы не найдены"; exit 1; }

# Выбор интерфейса
echo ""
read -r -p "Выберите интерфейс [1-$TOTAL]: " num

if ! echo "$num" | grep -qE '^[0-9]+$'; then
    msg_er "Неверный выбор"
    exit 1
fi

if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL" ]; then
    msg_er "Неверный выбор"
    exit 1
fi

SEL=$((num-1))
IFACE="${IFACES[$SEL]}"
IP="${IPS[$SEL]}"
MASK="${MASKS[$SEL]}"
GATE="${GATES[$SEL]}"
RANGE="${RANGES[$SEL]}"
DNS_IP="${DNS[$SEL]}"

# Получаем сеть
o3=$(echo "$IP" | cut -d'.' -f3)
case "$o3" in
    1) NETWORK="192.168.1.0" ;;
    2) NETWORK="192.168.2.0" ;;
    3) NETWORK="192.168.3.0" ;;
    *) 
        o1=$(echo "$IP" | cut -d'.' -f1)
        o2=$(echo "$IP" | cut -d'.' -f2)
        NETWORK="${o1}.${o2}.${o3}.0"
        ;;
esac

# Показ параметров
echo ""
echo -e "${CYAN}Параметры DHCP:${NC}"
echo -e "  Интерфейс:  ${YELLOW}$IFACE${NC}"
echo -e "  Сеть:       ${YELLOW}$NETWORK${NC}"
echo -e "  Маска:      ${YELLOW}$MASK${NC}"
echo -e "  Шлюз:       ${YELLOW}$GATE${NC}"
echo -e "  Диапазон:   ${YELLOW}$RANGE${NC}"
echo -e "  DNS:        ${YELLOW}$DNS_IP${NC}"
echo -e "  Суффикс:    ${YELLOW}$DNS_SUFFIX${NC}"
echo ""

read -r -p "Применить? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; exit 0 ;;
esac

# Установка пакета
echo ""
msg_in "Установка dhcp-server..."
dnf install -y dhcp-server >/dev/null 2>&1 || { msg_er "Ошибка установки"; exit 1; }
msg_ok "Пакет установлен"

# Создание конфига
msg_in "Создание конфигурации..."

cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP for Demo2026
authoritative;
default-lease-time 600;
max-lease-time 7200;

subnet $NETWORK netmask $MASK {
    range $RANGE;
    option domain-name-servers $DNS_IP;
    option domain-name "$DNS_SUFFIX";
    option routers $GATE;
}
EOF

msg_ok "Конфиг создан"

# Настройка sysconfig
echo "DHCPDARGS=\"$IFACE\"" > /etc/sysconfig/dhcpd
msg_ok "Интерфейс настроен: $IFACE"

# Firewall
if command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null
    nft add rule inet filter input udp dport 67 accept 2>/dev/null
    nft add rule inet filter input udp dport 68 accept 2>/dev/null
    msg_ok "Firewall настроен (nftables)"
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
    msg_ok "Firewall настроен (iptables)"
fi

# Проверка конфига
if ! dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1; then
    msg_er "Ошибка в конфигурации"
    exit 1
fi

# Запуск
msg_in "Запуск dhcpd..."
systemctl stop dhcpd 2>/dev/null
systemctl enable --now dhcpd

sleep 2

if systemctl is-active --quiet dhcpd; then
    msg_ok "DHCP сервер запущен!"
else
    msg_er "Ошибка запуска"
    journalctl -u dhcpd -n 10 --no-pager
    exit 1
fi

# Итог
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DHCP сервер настроен и запущен!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "Клиент получит IP из диапазона: ${YELLOW}$RANGE${NC}"
echo -e "Шлюз: ${YELLOW}$GATE${NC}"
echo -e "DNS: ${YELLOW}$DNS_IP${NC}"
echo -e "Суффикс: ${YELLOW}$DNS_SUFFIX${NC}"
