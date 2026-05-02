#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026 - Alt Linux Version
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
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root (su -)"
    exit 1
fi

# Определение пакетного менеджера
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_NAME="dhcp-server"
        SERVICE_NAME="dhcpd"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAME="dhcp-server"
        SERVICE_NAME="dhcpd"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_NAME="isc-dhcp-server"
        SERVICE_NAME="isc-dhcp-server"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAME="dhcp"
        SERVICE_NAME="dhcpd"
    else
        msg_er "Пакетный менеджер не найден"
        msg_in "Попробуйте: apt-get install dhcp-server"
        exit 1
    fi
    msg_ok "Пакетный менеджер: $PKG_MANAGER"
}

# Очистка экрана
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DHCP Server Setup for Demo2026${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

# Определяем пакетный менеджер
detect_pkg_manager

# Автоопределение интерфейсов
echo -e "\n${BLUE}Поиск VLAN интерфейсов...${NC}\n"

# Создаём временный файл
TMPFILE="/tmp/dhcp_ifaces_$$"

# Получаем список VLAN интерфейсов
ip -br addr show type vlan > "$TMPFILE" 2>/dev/null
if [ ! -s "$TMPFILE" ]; then
    ip -br addr show | grep -v "^lo" > "$TMPFILE"
fi

# Считаем количество
TOTAL=0

# Сначала считаем и показываем
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    TOTAL=$((TOTAL + 1))
done < "$TMPFILE"

if [ $TOTAL -eq 0 ]; then
    msg_er "VLAN интерфейсы не найдены"
    rm -f "$TMPFILE"
    exit 1
fi

# Массивы для хранения (используем файлы)
IFACE_FILE="/tmp/dhcp_iface_$$"
IPS_FILE="/tmp/dhcp_ips_$$"
MASKS_FILE="/tmp/dhcp_masks_$$"
GATES_FILE="/tmp/dhcp_gates_$$"
RANGES_FILE="/tmp/dhcp_ranges_$$"
DNS_FILE="/tmp/dhcp_dns_$$"
NETS_FILE="/tmp/dhcp_nets_$$"
VIDS_FILE="/tmp/dhcp_vids_$$"

> "$IFACE_FILE"
> "$IPS_FILE"
> "$MASKS_FILE"
> "$GATES_FILE"
> "$RANGES_FILE"
> "$DNS_FILE"
> "$NETS_FILE"
> "$VIDS_FILE"

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    
    # Определяем VLAN ID из имени интерфейса
    case "$iface" in
        *.*)
            vid=$(echo "$iface" | cut -d'.' -f2 | cut -d'@' -f1)
            ;;
        vlan*)
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
    
    # Определяем параметры по VLAN ID
    case "$vid" in
        100)
            net_name="VLAN100 (SRV-Net)"
            mask="255.255.255.224"
            prefix="27"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.30"
            ;;
        200)
            net_name="VLAN200 (CLI-Net)"
            mask="255.255.255.240"
            prefix="28"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.14"
            ;;
        999)
            net_name="VLAN999 (Management)"
            mask="255.255.255.248"
            prefix="29"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.6"
            ;;
        *)
            net_name="VLAN$vid"
            mask="255.255.255.0"
            prefix="24"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.254"
            ;;
    esac
    
    network="${o1}.${o2}.${o3}.0"
    range="$range_start $range_end"
    dns_ip="${o1}.${o2}.${o3}.1"
    
    # Сохраняем в файлы
    echo "$iface" >> "$IFACE_FILE"
    echo "$ip" >> "$IPS_FILE"
    echo "$mask" >> "$MASKS_FILE"
    echo "$ip" >> "$GATES_FILE"
    echo "$range" >> "$RANGES_FILE"
    echo "$dns_ip" >> "$DNS_FILE"
    echo "$network" >> "$NETS_FILE"
    echo "$vid" >> "$VIDS_FILE"
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface ${YELLOW}→${NC} $ip ${CYAN}($net_name /$prefix)${NC}"
    
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"

# Выбор интерфейса
echo ""
read -r -p "Выберите интерфейс [1-$TOTAL]: " num

case "$num" in
    ''|*[!0-9]*)
        msg_er "Неверный выбор"
        rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE"
        exit 1
        ;;
esac

if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL" ]; then
    msg_er "Неверный выбор (введите 1-$TOTAL)"
    rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE"
    exit 1
fi

# Получаем значения по номеру строки
IFACE=$(sed -n "${num}p" "$IFACE_FILE")
IP=$(sed -n "${num}p" "$IPS_FILE")
MASK=$(sed -n "${num}p" "$MASKS_FILE")
GATE=$(sed -n "${num}p" "$GATES_FILE")
RANGE=$(sed -n "${num}p" "$RANGES_FILE")
DNS_IP=$(sed -n "${num}p" "$DNS_FILE")
NETWORK=$(sed -n "${num}p" "$NETS_FILE")
VID=$(sed -n "${num}p" "$VIDS_FILE")

# Удаляем временные файлы
rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE"

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
msg_in "Установка DHCP сервера..."

case "$PKG_MANAGER" in
    apt-get)
        apt-get update
        apt-get install -y $PKG_NAME
        ;;
    dnf)
        dnf install -y $PKG_NAME
        ;;
    apt)
        apt update
        apt install -y $PKG_NAME
        ;;
    yum)
        yum install -y $PKG_NAME
        ;;
esac

if [ $? -ne 0 ]; then
    msg_er "Ошибка установки пакета"
    exit 1
fi
msg_ok "Пакет установлен: $PKG_NAME"

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

# Показываем конфиг
echo ""
echo -e "${YELLOW}Содержимое конфига:${NC}"
cat /etc/dhcp/dhcpd.conf
echo ""

# Настройка интерфейса в sysconfig
if [ -d /etc/sysconfig ]; then
    echo "DHCPDARGS=\"$IFACE\"" > /etc/sysconfig/dhcpd
    msg_ok "Интерфейс настроен: $IFACE"
fi

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
    exit 1
fi

# Запуск
msg_in "Запуск DHCP сервера..."
systemctl stop $SERVICE_NAME 2>/dev/null
systemctl enable --now $SERVICE_NAME

sleep 2

if systemctl is-active --quiet $SERVICE_NAME; then
    msg_ok "DHCP сервер запущен!"
else
    msg_er "Ошибка запуска"
    systemctl status $SERVICE_NAME --no-pager
    journalctl -u $SERVICE_NAME -n 20 --no-pager
    exit 1
fi

# Итог
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DHCP сервер настроен и запущен!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "Клиент получит IP: ${YELLOW}$RANGE${NC}"
echo -e "Шлюз: ${YELLOW}$GATE${NC}"
echo -e "DNS: ${YELLOW}$DNS_IP${NC}"
echo -e "Суффикс: ${YELLOW}$DNS_SUFFIX${NC}"
