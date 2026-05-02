#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026 - Простая версия
# Автоматическое определение VLAN по имени интерфейса
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
declare -a NETWORKS
declare -a VIDS

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
    
    # Определяем VLAN ID из имени интерфейса
    # Примеры: vlan100, ens37.100, eth0.100, enp0s8.100
    case "$iface" in
        *.*)
            # Формат interface.vlan (ens37.100)
            vid=$(echo "$iface" | cut -d'.' -f2 | cut -d'@' -f1)
            ;;
        vlan*)
            # Формат vlan100
            vid=$(echo "$iface" | sed 's/vlan//')
            ;;
        *)
            vid="0"
            ;;
    esac
    
    # Получаем октеты IP
    o1=$(echo "$ip" | cut -d'.' -f1)
    o2=$(echo "$ip" | cut -d'.' -f2)
    o3=$(echo "$ip" | cut -d'.' -f3)
    o4=$(echo "$ip" | cut -d'.' -f4)
    
    # Определяем параметры по VLAN ID
    case "$vid" in
        100)
            net_name="VLAN100 (SRV-Net)"
            mask="255.255.255.224"
            prefix="27"
            # Диапазон: от 2 до 30 (исключаем 0, 1=шлюз, 31=broadcast)
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.30"
            dns_ip="${o1}.${o2}.${o3}.1"
            ;;
        200)
            net_name="VLAN200 (CLI-Net)"
            mask="255.255.255.240"
            prefix="28"
            # Диапазон: от 2 до 14 (исключаем 0, 1=шлюз, 15=broadcast)
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.14"
            dns_ip="${o1}.${o2}.${o3}.1"
            ;;
        999)
            net_name="VLAN999 (Management)"
            mask="255.255.255.248"
            prefix="29"
            # Диапазон: от 2 до 6 (исключаем 0, 1=шлюз, 7=broadcast)
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.6"
            dns_ip="${o1}.${o2}.${o3}.1"
            ;;
        *)
            # Неизвестный VLAN - автоматический расчёт
            net_name="VLAN$vid (Unknown)"
            mask="255.255.255.0"
            prefix="24"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.254"
            dns_ip="${o1}.${o2}.${o3}.1"
            ;;
    esac
    
    # Сеть
    network="${o1}.${o2}.${o3}.0"
    range="$range_start $range_end"
    
    IFACES[$idx]="$iface"
    IPS[$idx]="$ip"
    MASKS[$idx]="$mask"
    GATES[$idx]="$ip"
    RANGES[$idx]="$range"
    DNS[$idx]="$dns_ip"
    NETWORKS[$idx]="$network"
    VIDS[$idx]="$vid"
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface ${YELLOW}→${NC} $ip ${CYAN}($net_name /$prefix)${NC}"
    
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
NETWORK="${NETWORKS[$SEL]}"
VID="${VIDS[$SEL]}"

# Показ параметров
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DHCP:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  Интерфейс:  ${YELLOW}$IFACE${NC}"
echo -e "  VLAN ID:    ${YELLOW}$VID${NC}"
echo -e "  Сеть:       ${YELLOW}$NETWORK${NC}"
echo -e "  Маска:      ${YELLOW}$MASK${NC}"
echo -e "  Шлюз:       ${YELLOW}$GATE${NC}"
echo -e "  Диапазон:   ${YELLOW}$RANGE${NC}"
echo -e "  DNS:        ${YELLOW}$DNS_IP${NC}"
echo -e "  Суффикс:    ${YELLOW}$DNS_SUFFIX${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

read -r -p "Применить? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; exit 0 ;;
esac

# Установка пакета
echo ""
msg_in "Установка dhcp-server..."
if dnf install -y dhcp-server; then
    msg_ok "Пакет установлен"
else
    msg_er "Ошибка установки пакета"
    exit 1
fi

# Создание конфига
msg_in "Создание конфигурации..."

cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP for Demo2026
# VLAN $VID - Interface $IFACE
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

msg_ok "Конфиг создан: /etc/dhcp/dhcpd.conf"

# Настройка sysconfig
echo "DHCPDARGS=\"$IFACE\"" > /etc/sysconfig/dhcpd
msg_ok "Интерфейс настроен: $IFACE"

# Firewall
msg_in "Настройка firewall..."
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
msg_in "Проверка конфигурации..."
if dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1; then
    msg_ok "Конфигурация валидна"
else
    msg_er "Ошибка в конфигурации"
    cat /etc/dhcp/dhcpd.conf
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
    msg_er "Ошибка запуска dhcpd"
    echo ""
    echo "Журнал:"
    journalctl -u dhcpd -n 20 --no-pager
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
echo ""
echo -e "Для проверки на клиенте:"
echo -e "  ${CYAN}# nmcli con reload${NC}"
echo -e "  ${CYAN}# nmcli con up <интерфейс>${NC}"
