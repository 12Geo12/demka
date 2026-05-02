#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026 - Alt Linux (Автоопределение маски)
# Автоматически определяет параметры сети по IP интерфейса
#===============================================================================

#--- Цвета --------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

#--- Константы ----------------------------------------------------------------
DNS_SUFFIX="au-team.irpo"

#--- Функции ------------------------------------------------------------------
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
line() { echo -e "${CYAN}================================================${NC}"; }

# Функция преобразования префикса в маску
prefix_to_mask() {
    local prefix=$1
    case "$prefix" in
        24) echo "255.255.255.0" ;;
        25) echo "255.255.255.128" ;;
        26) echo "255.255.255.192" ;;
        27) echo "255.255.255.224" ;;
        28) echo "255.255.255.240" ;;
        29) echo "255.255.255.248" ;;
        30) echo "255.255.255.252" ;;
        *)  echo "255.255.255.0" ;;
    esac
}

# Функция расчёта диапазона DHCP по префиксу
calc_dhcp_range() {
    local ip=$1
    local prefix=$2
    
    # Разбираем IP на октеты
    local o1=$(echo "$ip" | cut -d'.' -f1)
    local o2=$(echo "$ip" | cut -d'.' -f2)
    local o3=$(echo "$ip" | cut -d'.' -f3)
    local o4=$(echo "$ip" | cut -d'.' -f4)
    
    # Определяем диапазон по префиксу
    # Диапазон: от .2 до (последний адрес сети - 1)
    case "$prefix" in
        24) last=254 ;;
        25) last=126 ;;
        26) last=62 ;;
        27) last=30 ;;
        28) last=14 ;;
        29) last=6 ;;
        30) last=2 ;;
        *)  last=254 ;;
    esac
    
    echo "${o1}.${o2}.${o3}.2 ${o1}.${o2}.${o3}.${last}"
}

# Функция определения шлюза (обычно .1 в сети)
calc_gateway() {
    local ip=$1
    
    local o1=$(echo "$ip" | cut -d'.' -f1)
    local o2=$(echo "$ip" | cut -d'.' -f2)
    local o3=$(echo "$ip" | cut -d'.' -f3)
    
    # Шлюз - первый адрес в сети (.1)
    echo "${o1}.${o2}.${o3}.1"
}

# Функция определения сети
calc_network() {
    local ip=$1
    local o1=$(echo "$ip" | cut -d'.' -f1)
    local o2=$(echo "$ip" | cut -d'.' -f2)
    local o3=$(echo "$ip" | cut -d'.' -f3)
    
    echo "${o1}.${o2}.${o3}.0"
}

#--- Проверка root ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root: su -"
    exit 1
fi

#--- Заголовок ----------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     DHCP Server Setup - Auto Detection Version       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

#===============================================================================
# ЭТАП 1: Пакетный менеджер
#===============================================================================
line
echo -e "${WHITE}ЭТАП 1: Определение пакетного менеджера${NC}"
line
echo ""

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
else
    PKG_MANAGER="yum"
    PKG_NAME="dhcp"
    SERVICE_NAME="dhcpd"
fi

msg_ok "Пакетный менеджер: ${YELLOW}$PKG_MANAGER${NC}"

#===============================================================================
# ЭТАП 2: Автообнаружение интерфейсов
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 2: Автообнаружение интерфейсов${NC}"
line
echo ""

echo -e "${CYAN}>>> ip -br addr show${NC}"
echo ""
ip -br addr show 2>/dev/null
echo ""

# Временные файлы
IFACE_FILE="/tmp/dhcp_iface_$$"
IPS_FILE="/tmp/dhcp_ips_$$"
PREFIX_FILE="/tmp/dhcp_prefix_$$"
MASK_FILE="/tmp/dhcp_mask_$$"
GATE_FILE="/tmp/dhcp_gate_$$"
RANGE_FILE="/tmp/dhcp_range_$$"
NET_FILE="/tmp/dhcp_net_$$"
DNS_FILE="/tmp/dhcp_dns_$$"

> "$IFACE_FILE"
> "$IPS_FILE"
> "$PREFIX_FILE"
> "$MASK_FILE"
> "$GATE_FILE"
> "$RANGE_FILE"
> "$NET_FILE"
> "$DNS_FILE"

echo -e "${CYAN}Обнаруженные интерфейсы с IP:${NC}"
echo ""

idx=0
for iface in $(ip -br addr show 2>/dev/null | grep -v "^lo" | awk '{print $1}'); do
    # Получаем IP с префиксом
    ip_with_prefix=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    
    [ -z "$ip_with_prefix" ] && continue
    
    # Разбираем IP и префикс
    ip=$(echo "$ip_with_prefix" | cut -d'/' -f1)
    prefix=$(echo "$ip_with_prefix" | cut -d'/' -f2)
    
    # Автоматически вычисляем параметры
    mask=$(prefix_to_mask "$prefix")
    range=$(calc_dhcp_range "$ip" "$prefix")
    gateway=$(calc_gateway "$ip")
    network=$(calc_network "$ip")
    dns="$gateway"  # DNS = шлюз (роутер)
    
    # Определяем VLAN ID из имени (если есть)
    case "$iface" in
        *.*)
            vid=$(echo "$iface" | cut -d'.' -f2)
            ;;
        vlan*)
            vid=$(echo "$iface" | sed 's/vlan//')
            ;;
        *)
            vid="-"
            ;;
    esac
    
    # Сохраняем
    echo "$iface" >> "$IFACE_FILE"
    echo "$ip" >> "$IPS_FILE"
    echo "$prefix" >> "$PREFIX_FILE"
    echo "$mask" >> "$MASK_FILE"
    echo "$gateway" >> "$GATE_FILE"
    echo "$range" >> "$RANGE_FILE"
    echo "$network" >> "$NET_FILE"
    echo "$dns" >> "$DNS_FILE"
    
    printf "  ${GREEN}[%2d]${NC} %-18s ${YELLOW}%-18s${NC} /${prefix}  VLAN: ${CYAN}%s${NC}\n" \
        "$((idx+1))" "$iface" "$ip_with_prefix" "$vid"
    echo -e "       Маска: ${WHITE}$mask${NC}  Диапазон: ${WHITE}$range${NC}  Шлюз: ${WHITE}$gateway${NC}"
    echo ""
    
    idx=$((idx + 1))
done

TOTAL=$idx

if [ $TOTAL -eq 0 ]; then
    msg_er "Интерфейсы с IP не найдены"
    exit 1
fi

#===============================================================================
# ЭТАП 3: Выбор интерфейса
#===============================================================================
line
echo -e "${WHITE}Выбор интерфейса${NC}"
line
echo ""

echo -e "${YELLOW}Выберите интерфейс [1-$TOTAL] или 'all' для всех:${NC}"
read -r -p "> " selection

if [ "$selection" = "all" ]; then
    SELECTED_ALL=1
    msg_in "Будут настроены все $TOTAL интерфейсов"
    SELECTED_IFACES=$(cat "$IFACE_FILE" | tr '\n' ' ')
else
    if ! echo "$selection" | grep -qE '^[0-9]+$'; then
        msg_er "Неверный ввод"
        rm -f "$IFACE_FILE" "$IPS_FILE" "$PREFIX_FILE" "$MASK_FILE" "$GATE_FILE" "$RANGE_FILE" "$NET_FILE" "$DNS_FILE"
        exit 1
    fi
    
    if [ "$selection" -lt 1 ] || [ "$selection" -gt "$TOTAL" ]; then
        msg_er "Выберите от 1 до $TOTAL"
        rm -f "$IFACE_FILE" "$IPS_FILE" "$PREFIX_FILE" "$MASK_FILE" "$GATE_FILE" "$RANGE_FILE" "$NET_FILE" "$DNS_FILE"
        exit 1
    fi
    SELECTED_ALL=0
    SELECTED_IFACES=$(sed -n "${selection}p" "$IFACE_FILE")
fi

#===============================================================================
# ЭТАП 4: Показ параметров
#===============================================================================
echo ""
line
echo -e "${WHITE}Параметры DHCP (автоопределение):${NC}"
line
echo ""

show_params() {
    local num=$1
    local IFACE=$(sed -n "${num}p" "$IFACE_FILE")
    local IP=$(sed -n "${num}p" "$IPS_FILE")
    local PREFIX=$(sed -n "${num}p" "$PREFIX_FILE")
    local MASK=$(sed -n "${num}p" "$MASK_FILE")
    local GATE=$(sed -n "${num}p" "$GATE_FILE")
    local RANGE=$(sed -n "${num}p" "$RANGE_FILE")
    local NETWORK=$(sed -n "${num}p" "$NET_FILE")
    local DNS=$(sed -n "${num}p" "$DNS_FILE")
    
    echo -e "${CYAN}  Интерфейс:${NC}    $IFACE"
    echo -e "${CYAN}  IP адрес:${NC}    $IP /${PREFIX}"
    echo -e "${CYAN}  Сеть:${NC}         $NETWORK"
    echo -e "${CYAN}  Маска:${NC}        $MASK (авто)"
    echo -e "${CYAN}  Шлюз:${NC}         $GATE (авто)"
    echo -e "${CYAN}  Диапазон:${NC}     $RANGE (авто)"
    echo -e "${CYAN}  DNS:${NC}          $DNS"
    echo -e "${CYAN}  Суффикс:${NC}      $DNS_SUFFIX"
    echo ""
}

if [ "$SELECTED_ALL" = "1" ]; then
    i=1
    while [ $i -le $TOTAL ]; do
        echo -e "${WHITE}[$i]${NC}"
        show_params "$i"
        i=$((i + 1))
    done
else
    show_params "$selection"
fi

echo -e "${YELLOW}Применить? (y/n):${NC}"
read -r -p "> " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    msg_in "Отменено"
    rm -f "$IFACE_FILE" "$IPS_FILE" "$PREFIX_FILE" "$MASK_FILE" "$GATE_FILE" "$RANGE_FILE" "$NET_FILE" "$DNS_FILE"
    exit 0
fi

#===============================================================================
# ЭТАП 5: Установка пакета
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 3: Установка DHCP${NC}"
line
echo ""

if rpm -q $PKG_NAME >/dev/null 2>&1 || dpkg -l $PKG_NAME >/dev/null 2>&1; then
    msg_ok "Пакет $PKG_NAME уже установлен"
else
    msg_in "Установка $PKG_NAME..."
    case "$PKG_MANAGER" in
        apt-get) apt-get update && apt-get install -y $PKG_NAME ;;
        dnf) dnf install -y $PKG_NAME ;;
        apt) apt update && apt install -y $PKG_NAME ;;
        yum) yum install -y $PKG_NAME ;;
    esac
fi

echo ""
echo -e "${CYAN}>>> dhcpd --version${NC}"
dhcpd --version 2>&1 | head -3

#===============================================================================
# ЭТАП 6: Создание конфигурации
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 4: Создание конфигурации${NC}"
line
echo ""

# Бэкап
if [ -f /etc/dhcp/dhcpd.conf ]; then
    cp /etc/dhcp/dhcpd.conf "/etc/dhcp/dhcpd.conf.bak.$(date +%Y%m%d%H%M%S)"
    msg_ok "Резервная копия создана"
fi

# Создаём конфиг
msg_in "Создание /etc/dhcp/dhcpd.conf..."

cat > /etc/dhcp/dhcpd.conf << 'HEADER'
# =============================================================================
# DHCP Server Configuration - Demo2026
# Автоматически сгенерировано
# =============================================================================

authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

option domain-name "au-team.irpo";

HEADER

# Функция генерации subnet блока
generate_subnet() {
    local num=$1
    local IFACE=$(sed -n "${num}p" "$IFACE_FILE")
    local NETWORK=$(sed -n "${num}p" "$NET_FILE")
    local MASK=$(sed -n "${num}p" "$MASK_FILE")
    local RANGE=$(sed -n "${num}p" "$RANGE_FILE")
    local GATE=$(sed -n "${num}p" "$GATE_FILE")
    local DNS=$(sed -n "${num}p" "$DNS_FILE")
    local PREFIX=$(sed -n "${num}p" "$PREFIX_FILE")
    
    echo "# Interface $IFACE (/${PREFIX})"
    echo "subnet $NETWORK netmask $MASK {"
    echo "    range $RANGE;"
    echo "    option domain-name-servers $DNS;"
    echo "    option domain-name \"$DNS_SUFFIX\";"
    echo "    option routers $GATE;"
    echo "    default-lease-time 600;"
    echo "    max-lease-time 7200;"
    echo "}"
    echo ""
}

# Добавляем подсети
if [ "$SELECTED_ALL" = "1" ]; then
    i=1
    while [ $i -le $TOTAL ]; do
        generate_subnet "$i" >> /etc/dhcp/dhcpd.conf
        i=$((i + 1))
    done
else
    generate_subnet "$selection" >> /etc/dhcp/dhcpd.conf
fi

msg_ok "Конфигурация создана"

echo ""
line
echo -e "${WHITE}Содержимое /etc/dhcp/dhcpd.conf:${NC}"
line
echo ""
cat /etc/dhcp/dhcpd.conf

#===============================================================================
# ЭТАП 7: Интерфейсы для DHCP
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 5: Интерфейсы${NC}"
line
echo ""

if [ -d /etc/sysconfig ]; then
    cat > /etc/sysconfig/dhcpd << EOF
# DHCP Server Arguments
DHCPDARGS="$SELECTED_IFACES"
EOF
    msg_ok "Интерфейсы: /etc/sysconfig/dhcpd"
    echo ""
    echo -e "${CYAN}>>> cat /etc/sysconfig/dhcpd${NC}"
    cat /etc/sysconfig/dhcpd
elif [ -f /etc/default/isc-dhcp-server ]; then
    cat > /etc/default/isc-dhcp-server << EOF
INTERFACESv4="$SELECTED_IFACES"
INTERFACESv6=""
EOF
    msg_ok "Интерфейсы: /etc/default/isc-dhcp-server"
fi

#===============================================================================
# ЭТАП 8: Firewall
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 6: Firewall${NC}"
line
echo ""

msg_in "Настройка firewall..."

if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
    msg_ok "iptables: порты 67,68 открыты"
elif command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null
    nft add rule inet filter input udp dport 67-68 accept 2>/dev/null
    msg_ok "nftables: порты 67,68 открыты"
fi

#===============================================================================
# ЭТАП 9: Проверка конфигурации
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 7: Проверка${NC}"
line
echo ""

msg_in "Валидация конфигурации..."
echo ""
echo -e "${CYAN}>>> dhcpd -t -cf /etc/dhcp/dhcpd.conf${NC}"
echo ""

if dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1; then
    msg_ok "Конфигурация валидна!"
else
    msg_er "Ошибка в конфигурации!"
    exit 1
fi

#===============================================================================
# ЭТАП 10: Запуск
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 8: Запуск DHCP${NC}"
line
echo ""

msg_in "Запуск сервиса..."
systemctl stop $SERVICE_NAME 2>/dev/null
systemctl enable --now $SERVICE_NAME 2>&1

sleep 2

echo ""
echo -e "${CYAN}>>> systemctl status $SERVICE_NAME --no-pager${NC}"
echo ""
systemctl status $SERVICE_NAME --no-pager 2>&1 | head -15

if systemctl is-active --quiet $SERVICE_NAME; then
    msg_ok "DHCP сервер ${GREEN}РАБОТАЕТ!${NC}"
else
    msg_er "Сервис не запущен!"
    journalctl -u $SERVICE_NAME -n 20 --no-pager
    exit 1
fi

#===============================================================================
# ЭТАП 11: Диагностика
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 9: Диагностика${NC}"
line
echo ""

echo -e "${CYAN}>>> ss -ulnp | grep :67${NC}"
ss -ulnp 2>/dev/null | grep ':67' || netstat -ulnp 2>/dev/null | grep ':67'
echo ""

echo -e "${CYAN}>>> ps aux | grep dhcpd | grep -v grep${NC}"
ps aux 2>/dev/null | grep dhcpd | grep -v grep | head -3

#===============================================================================
# Очистка
#===============================================================================
rm -f "$IFACE_FILE" "$IPS_FILE" "$PREFIX_FILE" "$MASK_FILE" "$GATE_FILE" "$RANGE_FILE" "$NET_FILE" "$DNS_FILE"

#===============================================================================
# ИТОГ
#===============================================================================
echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║            DHCP УСПЕШНО НАСТРОЕН!                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${WHITE}Интерфейсы:${NC} $SELECTED_IFACES"
echo ""
echo -e "${WHITE}Проверка на клиенте:${NC}"
echo -e "  ${YELLOW}dhclient -v <интерфейс>${NC}"
echo -e "  ${YELLOW}ip addr show${NC}"
echo -e "  ${YELLOW}cat /etc/resolv.conf${NC}"
echo -e "  ${YELLOW}ping <шлюз>${NC}"
echo ""
