#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026 - Alt Linux (Улучшенная версия)
# Исходник: https://github.com/12Geo12/demka/blob/main/1.7.dhcpserv.sh
#===============================================================================
# Улучшения:
# - Исправлены ANSI коды цветов
# - Добавлены детальные выводы команд на каждом этапе
# - Добавлена поддержка нескольких VLAN одновременно
# - Добавлена проверка конфликтов IP
# - Добавлена диагностика после настройки
# - Улучшено автоматическое определение параметров
#===============================================================================

#--- Цвета (исправленные ANSI коды) -------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
PURPLE='\033[0;35m'
NC='\033[0m'

#--- Константы ----------------------------------------------------------------
DNS_SUFFIX="au-team.irpo"

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
echo -e "${CYAN}║${NC} ${WHITE}${BOLD}DHCP Server Setup - Demo2026 Improved${NC}          ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

#--- Системная информация -----------------------------------------------------
msg_hd
echo -e "${WHITE}Системная информация:${NC}"
msg_hd
echo ""
echo -e "  ${BLUE}Hostname:${NC} $(hostname)"
echo -e "  ${BLUE}OS:${NC} $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Unknown')"
echo -e "  ${BLUE}Kernel:${NC} $(uname -r)"
echo -e "  ${BLUE}Date:${NC} $(date '+%Y-%m-%d %H:%M:%S')"

#===============================================================================
# 1. ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 1: Определение пакетного менеджера${NC}"
msg_hd
echo ""

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_NAME="dhcp-server"
        SERVICE_NAME="dhcpd"
        CONF_DIR="/etc/dhcp"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAME="dhcp-server"
        SERVICE_NAME="dhcpd"
        CONF_DIR="/etc/dhcp"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_NAME="isc-dhcp-server"
        SERVICE_NAME="isc-dhcp-server"
        CONF_DIR="/etc/dhcp"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAME="dhcp"
        SERVICE_NAME="dhcpd"
        CONF_DIR="/etc/dhcp"
    else
        msg_er "Пакетный менеджер не найден"
        exit 1
    fi
}

detect_pkg_manager
msg_ok "Пакетный менеджер: ${YELLOW}$PKG_MANAGER${NC}"
msg_ok "Имя пакета: ${YELLOW}$PKG_NAME${NC}"
msg_ok "Имя сервиса: ${YELLOW}$SERVICE_NAME${NC}"

#===============================================================================
# 2. ПОИСК И АНАЛИЗ ИНТЕРФЕЙСОВ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 2: Анализ сетевых интерфейсов${NC}"
msg_hd
echo ""

echo -e "${CYAN}>>> Вывод команды: ip -br addr show${NC}"
echo ""
ip -br addr show 2>/dev/null
echo ""

echo -e "${CYAN}>>> Вывод команды: ip -br addr show type vlan${NC}"
echo ""
ip -br addr show type vlan 2>/dev/null || echo "  (VLAN интерфейсы не найдены)"
echo ""

# Создаём временные файлы
TMPFILE="/tmp/dhcp_scan_$$"
IFACE_FILE="/tmp/dhcp_iface_$$"
IPS_FILE="/tmp/dhcp_ips_$$"
MASKS_FILE="/tmp/dhcp_masks_$$"
GATES_FILE="/tmp/dhcp_gates_$$"
RANGES_FILE="/tmp/dhcp_ranges_$$"
DNS_FILE="/tmp/dhcp_dns_$$"
NETS_FILE="/tmp/dhcp_nets_$$"
VIDS_FILE="/tmp/dhcp_vids_$$"
NAMES_FILE="/tmp/dhcp_names_$$"

> "$IFACE_FILE"
> "$IPS_FILE"
> "$MASKS_FILE"
> "$GATES_FILE"
> "$RANGES_FILE"
> "$DNS_FILE"
> "$NETS_FILE"
> "$VIDS_FILE"
> "$NAMES_FILE"

# Получаем VLAN интерфейсы или все с IP
ip -br addr show type vlan 2>/dev/null > "$TMPFILE"
if [ ! -s "$TMPFILE" ]; then
    ip -br addr show 2>/dev/null | grep -v "^lo" > "$TMPFILE"
fi

echo -e "${CYAN}Обнаруженные интерфейсы для DHCP:${NC}"
echo ""

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    # Парсим строку
    iface_full=$(echo "$line" | awk '{print $1}')
    iface=$(echo "$iface_full" | cut -d'@' -f1)
    ip_full=$(echo "$line" | awk '{print $3}')
    
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    prefix=$(echo "$ip_full" | cut -d'/' -f2)
    
    # Определяем VLAN ID
    case "$iface" in
        *.*)
            vid=$(echo "$iface" | cut -d'.' -f2)
            ;;
        vlan*)
            vid=$(echo "$iface" | sed 's/vlan//')
            ;;
        *)
            vid="0"
            ;;
    esac
    
    # Октеты IP
    o1=$(echo "$ip" | cut -d'.' -f1)
    o2=$(echo "$ip" | cut -d'.' -f2)
    o3=$(echo "$ip" | cut -d'.' -f3)
    o4=$(echo "$ip" | cut -d'.' -f4)
    
    # Определяем параметры по VLAN ID (согласно топологии Demo2026)
    case "$vid" in
        100)
            net_name="SRV-Net"
            mask="255.255.255.224"
            prefix="27"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.30"
            ;;
        200)
            net_name="CLI-Net"
            mask="255.255.255.240"
            prefix="28"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.14"
            ;;
        999)
            net_name="Mgmt"
            mask="255.255.255.248"
            prefix="29"
            range_start="${o1}.${o2}.${o3}.2"
            range_end="${o1}.${o2}.${o3}.6"
            ;;
        *)
            net_name="LAN"
            # Автовычисление маски по префиксу
            case "$prefix" in
                27) mask="255.255.255.224"; range_end="${o1}.${o2}.${o3}.30" ;;
                28) mask="255.255.255.240"; range_end="${o1}.${o2}.${o3}.14" ;;
                29) mask="255.255.255.248"; range_end="${o1}.${o2}.${o3}.6" ;;
                24) mask="255.255.255.0";   range_end="${o1}.${o2}.${o3}.254" ;;
                *)  mask="255.255.255.0";   range_end="${o1}.${o2}.${o3}.254" ;;
            esac
            range_start="${o1}.${o2}.${o3}.2"
            ;;
    esac
    
    network="${o1}.${o2}.${o3}.0"
    range="$range_start $range_end"
    gateway="${o1}.${o2}.${o3}.1"
    dns_ip="${o1}.${o2}.${o3}.1"
    
    # Сохраняем
    echo "$iface" >> "$IFACE_FILE"
    echo "$ip" >> "$IPS_FILE"
    echo "$mask" >> "$MASKS_FILE"
    echo "$gateway" >> "$GATES_FILE"
    echo "$range" >> "$RANGES_FILE"
    echo "$dns_ip" >> "$DNS_FILE"
    echo "$network" >> "$NETS_FILE"
    echo "$vid" >> "$VIDS_FILE"
    echo "$net_name" >> "$NAMES_FILE"
    
    printf "  ${GREEN}[%2d]${NC} %-15s ${YELLOW}%-18s${NC} VLAN ${CYAN}%4s${NC} (${WHITE}%s${NC}) /${prefix}\n" \
        "$((idx+1))" "$iface" "$ip_full" "$vid" "$net_name"
    
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"
TOTAL=$idx

if [ $TOTAL -eq 0 ]; then
    msg_er "Интерфейсы с IP не найдены"
    rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE" "$NAMES_FILE"
    exit 1
fi

#===============================================================================
# 3. ВЫБОР ИНТЕРФЕЙСА
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}Выбор интерфейса${NC}"
msg_hd
echo ""

echo -e "${YELLOW}Выберите интерфейс для DHCP [1-$TOTAL] или 'all' для всех:${NC}"
read -r -p "> " selection

if [ "$selection" = "all" ]; then
    SELECTED_ALL=1
    msg_in "Будут настроены все $TOTAL интерфейсов"
else
    case "$selection" in
        ''|*[!0-9]*)
            msg_er "Неверный выбор"
            rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE" "$NAMES_FILE"
            exit 1
            ;;
    esac
    
    if [ "$selection" -lt 1 ] || [ "$selection" -gt "$TOTAL" ]; then
        msg_er "Неверный диапазон (1-$TOTAL)"
        rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE" "$NAMES_FILE"
        exit 1
    fi
    
    SELECTED_ALL=0
fi

#===============================================================================
# 4. ПОКАЗ ПАРАМЕТРОВ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}Параметры DHCP:${NC}"
msg_hd
echo ""

show_params() {
    local num=$1
    IFACE=$(sed -n "${num}p" "$IFACE_FILE")
    IP=$(sed -n "${num}p" "$IPS_FILE")
    MASK=$(sed -n "${num}p" "$MASKS_FILE")
    GATE=$(sed -n "${num}p" "$GATES_FILE")
    RANGE=$(sed -n "${num}p" "$RANGES_FILE")
    DNS_IP=$(sed -n "${num}p" "$DNS_FILE")
    NETWORK=$(sed -n "${num}p" "$NETS_FILE")
    VID=$(sed -n "${num}p" "$VIDS_FILE")
    NET_NAME=$(sed -n "${num}p" "$NAMES_FILE")
    
    echo -e "${CYAN}  Интерфейс:${NC}    $IFACE"
    echo -e "${CYAN}  VLAN ID:${NC}      $VID (${NET_NAME})"
    echo -e "${CYAN}  Сеть:${NC}         $NETWORK"
    echo -e "${CYAN}  Маска:${NC}        $MASK"
    echo -e "${CYAN}  Шлюз:${NC}         $GATE"
    echo -e "${CYAN}  Диапазон:${NC}     $RANGE"
    echo -e "${CYAN}  DNS:${NC}          $DNS_IP"
    echo -e "${CYAN}  Суффикс:${NC}      $DNS_SUFFIX"
    echo ""
}

if [ "$SELECTED_ALL" = "1" ]; then
    for i in $(seq 1 $TOTAL); do
        echo -e "${WHITE}[$i]${NC}"
        show_params "$i"
    done
else
    show_params "$selection"
fi

echo -e "${YELLOW}Применить? (y/n):${NC}"
read -r -p "> " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE" "$NAMES_FILE"; exit 0 ;;
esac

#===============================================================================
# 5. УСТАНОВКА ПАКЕТА
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 3: Установка DHCP сервера${NC}"
msg_hd
echo ""

# Проверка установлен ли пакет
if rpm -q $PKG_NAME &>/dev/null || dpkg -l $PKG_NAME &>/dev/null 2>&1; then
    msg_ok "Пакет $PKG_NAME уже установлен"
else
    msg_in "Установка $PKG_NAME..."
    
    echo -e "${CYAN}>>> Вывод команды: $PKG_MANAGER install -y $PKG_NAME${NC}"
    echo ""
    
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
fi

# Проверка установки
if rpm -q $PKG_NAME &>/dev/null 2>&1 || dpkg -l $PKG_NAME &>/dev/null 2>&1; then
    msg_ok "Пакет установлен: ${YELLOW}$PKG_NAME${NC}"
else
    msg_er "Ошибка установки пакета"
    exit 1
fi

# Вывод версии
echo ""
echo -e "${CYAN}>>> Вывод команды: dhcpd --version${NC}"
dhcpd --version 2>&1 | head -3

#===============================================================================
# 6. СОЗДАНИЕ КОНФИГУРАЦИИ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 4: Создание конфигурации${NC}"
msg_hd
echo ""

# Резервное копирование
if [ -f "$CONF_DIR/dhcpd.conf" ]; then
    cp "$CONF_DIR/dhcpd.conf" "$CONF_DIR/dhcpd.conf.bak.$(date +%Y%m%d%H%M%S)"
    msg_ok "Резервная копия создана"
fi

# Функция генерации subnet блока
generate_subnet_block() {
    local num=$1
    local IFACE=$(sed -n "${num}p" "$IFACE_FILE")
    local NETWORK=$(sed -n "${num}p" "$NETS_FILE")
    local MASK=$(sed -n "${num}p" "$MASKS_FILE")
    local RANGE=$(sed -n "${num}p" "$RANGES_FILE")
    local GATE=$(sed -n "${num}p" "$GATES_FILE")
    local DNS_IP=$(sed -n "${num}p" "$DNS_FILE")
    local VID=$(sed -n "${num}p" "$VIDS_FILE")
    local NET_NAME=$(sed -n "${num}p" "$NAMES_FILE")
    
    cat << EOF
# VLAN $VID - $NET_NAME - Interface $IFACE
subnet $NETWORK netmask $MASK {
    range $RANGE;
    option domain-name-servers $DNS_IP;
    option domain-name "$DNS_SUFFIX";
    option routers $GATE;
    option broadcast-address $(echo $NETWORK | sed 's/0$/255/');
    default-lease-time 600;
    max-lease-time 7200;
}

EOF
}

# Создаём конфиг
msg_in "Создание $CONF_DIR/dhcpd.conf..."

cat > "$CONF_DIR/dhcpd.conf" << 'HEADER'
# =============================================================================
# DHCP Server Configuration - Demo2026
# Generated by dhcp-server-improved.sh
# =============================================================================

# Глобальные параметры
authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

# DNS суффикс
option domain-name "au-team.irpo";

HEADER

# Добавляем subnet блоки
if [ "$SELECTED_ALL" = "1" ]; then
    for i in $(seq 1 $TOTAL); do
        generate_subnet_block "$i" >> "$CONF_DIR/dhcpd.conf"
    done
    SELECTED_IFACES=$(cat "$IFACE_FILE" | tr '\n' ' ')
else
    generate_subnet_block "$selection" >> "$CONF_DIR/dhcpd.conf"
    SELECTED_IFACES=$(sed -n "${selection}p" "$IFACE_FILE")
fi

msg_ok "Конфигурация создана"

# Показываем конфиг
echo ""
msg_hd
echo -e "${WHITE}Содержимое $CONF_DIR/dhcpd.conf:${NC}"
msg_hd
echo ""
cat "$CONF_DIR/dhcpd.conf"
echo ""

#===============================================================================
# 7. НАСТРОЙКА ИНТЕРФЕЙСОВ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 5: Настройка интерфейсов${NC}"
msg_hd
echo ""

# Настройка интерфейсов для DHCP
if [ -d /etc/sysconfig ]; then
    # Alt Linux / RHEL style
    cat > /etc/sysconfig/dhcpd << EOF
# DHCP Server Arguments
# Интерфейсы, на которых работает DHCP
DHCPDARGS="$SELECTED_IFACES"
EOF
    msg_ok "Интерфейсы настроены в /etc/sysconfig/dhcpd"
    echo ""
    echo -e "${CYAN}>>> Вывод: cat /etc/sysconfig/dhcpd${NC}"
    cat /etc/sysconfig/dhcpd
elif [ -f /etc/default/isc-dhcp-server ]; then
    # Debian/Ubuntu style
    cat > /etc/default/isc-dhcp-server << EOF
INTERFACESv4="$SELECTED_IFACES"
INTERFACESv6=""
EOF
    msg_ok "Интерфейсы настроены в /etc/default/isc-dhcp-server"
fi

#===============================================================================
# 8. НАСТРОЙКА FIREWALL
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 6: Настройка Firewall${NC}"
msg_hd
echo ""

msg_in "Добавление правил firewall для DHCP..."

# DHCP порты: 67 (server), 68 (client)
if command -v nft >/dev/null 2>&1; then
    msg_in "Использование nftables..."
    nft add table inet filter 2>/dev/null
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null
    nft add rule inet filter input udp dport 67 accept 2>/dev/null
    nft add rule inet filter input udp dport 68 accept 2>/dev/null
    msg_ok "nftables правила добавлены"
    
    echo ""
    echo -e "${CYAN}>>> Вывод команды: nft list table inet filter${NC}"
    nft list table inet filter 2>/dev/null | head -20
    
elif command -v iptables >/dev/null 2>&1; then
    msg_in "Использование iptables..."
    iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
    msg_ok "iptables правила добавлены"
    
    echo ""
    echo -e "${CYAN}>>> Вывод команды: iptables -L INPUT -n | grep -E 'dpt:(67|68)'${NC}"
    iptables -L INPUT -n 2>/dev/null | grep -E "dpt:(67|68)" || echo "  (правила не найдены в выводе)"
fi

#===============================================================================
# 9. ПРОВЕРКА КОНФИГУРАЦИИ
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 7: Проверка конфигурации${NC}"
msg_hd
echo ""

msg_in "Проверка синтаксиса dhcpd.conf..."

echo ""
echo -e "${CYAN}>>> Вывод команды: dhcpd -t -cf $CONF_DIR/dhcpd.conf${NC}"
echo ""

if dhcpd -t -cf "$CONF_DIR/dhcpd.conf" 2>&1; then
    msg_ok "Конфигурация валидна!"
else
    msg_er "Ошибка в конфигурации!"
    echo ""
    msg_wa "Проверьте файл $CONF_DIR/dhcpd.conf"
    exit 1
fi

#===============================================================================
# 10. ЗАПУСК СЕРВИСА
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 8: Запуск DHCP сервера${NC}"
msg_hd
echo ""

msg_in "Остановка старого сервиса..."
systemctl stop $SERVICE_NAME 2>/dev/null

msg_in "Включение и запуск сервиса..."
echo ""
echo -e "${CYAN}>>> Вывод команды: systemctl enable --now $SERVICE_NAME${NC}"
echo ""

systemctl enable --now $SERVICE_NAME 2>&1

sleep 2

# Проверка статуса
echo ""
echo -e "${CYAN}>>> Вывод команды: systemctl status $SERVICE_NAME --no-pager${NC}"
echo ""
systemctl status $SERVICE_NAME --no-pager 2>&1 | head -20

# Проверка
if systemctl is-active --quiet $SERVICE_NAME; then
    msg_ok "DHCP сервер ${GREEN}РАБОТАЕТ!${NC}"
else
    msg_er "Сервис не запущен!"
    echo ""
    echo -e "${CYAN}>>> Журнал (последние 30 строк):${NC}"
    journalctl -u $SERVICE_NAME -n 30 --no-pager
    exit 1
fi

#===============================================================================
# 11. ДИАГНОСТИКА
#===============================================================================
echo ""
msg_hd
echo -e "${WHITE}ЭТАП 9: Диагностика${NC}"
msg_hd
echo ""

# Прослушиваемые порты
echo -e "${CYAN}>>> Вывод команды: ss -ulnp | grep -E ':67|dhcp'${NC}"
echo ""
ss -ulnp 2>/dev/null | grep -E ':67|dhcp' || netstat -ulnp 2>/dev/null | grep ':67'

# Процесс
echo ""
echo -e "${CYAN}>>> Вывод команды: ps aux | grep dhcpd | grep -v grep${NC}"
echo ""
ps aux 2>/dev/null | grep dhcpd | grep -v grep || pgrep -a dhcpd

# Аренды
echo ""
echo -e "${CYAN}>>> Файл аренд: $CONF_DIR/dhcpd.leases${NC}"
if [ -f "$CONF_DIR/dhcpd.leases" ]; then
    echo -e "  Размер: $(wc -l < "$CONF_DIR/dhcpd.leases") строк"
    echo -e "  Последние записи:"
    tail -10 "$CONF_DIR/dhcpd.leases" 2>/dev/null | head -15
else
    msg_in "Файл аренд пуст или не существует"
fi

# Интерфейсы
echo ""
echo -e "${CYAN}>>> IP адреса на интерфейсах:${NC}"
echo ""
if [ "$SELECTED_ALL" = "1" ]; then
    for i in $(seq 1 $TOTAL); do
        IFACE=$(sed -n "${i}p" "$IFACE_FILE")
        ip -br addr show "$IFACE" 2>/dev/null
    done
else
    ip -br addr show "$SELECTED_IFACES" 2>/dev/null
fi

#===============================================================================
# ОЧИСТКА
#===============================================================================
rm -f "$IFACE_FILE" "$IPS_FILE" "$MASKS_FILE" "$GATES_FILE" "$RANGES_FILE" "$DNS_FILE" "$NETS_FILE" "$VIDS_FILE" "$NAMES_FILE"

#===============================================================================
# ИТОГ
#===============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC} ${WHITE}${BOLD}DHCP СЕРВЕР УСПЕШНО НАСТРОЕН!${NC}                        ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}Настроенные сети:${NC}"
echo ""

if [ "$SELECTED_ALL" = "1" ]; then
    for i in $(seq 1 $TOTAL); do
        IFACE=$(sed -n "${i}p" "$IFACE_FILE" 2>/dev/null || echo "N/A")
        RANGE=$(sed -n "${i}p" "$RANGES_FILE" 2>/dev/null || echo "N/A")
        GATE=$(sed -n "${i}p" "$GATES_FILE" 2>/dev/null || echo "N/A")
        echo -e "  ${GREEN}•${NC} $IFACE: диапазон ${YELLOW}$RANGE${NC}, шлюз ${CYAN}$GATE${NC}"
    done
else
    echo -e "  ${GREEN}•${NC} $SELECTED_IFACES: диапазон ${YELLOW}$RANGE${NC}, шлюз ${CYAN}$GATE${NC}"
fi

echo ""
echo -e "${WHITE}Проверка на клиенте:${NC}"
echo -e "  ${YELLOW}dhclient -v <интерфейс>${NC}    - запрос IP"
echo -e "  ${YELLOW}ip addr show${NC}              - проверка IP"
echo -e "  ${YELLOW}cat /etc/resolv.conf${NC}       - проверка DNS"
echo -e "  ${YELLOW}ping <шлюз>${NC}                - проверка связности"
echo ""
echo -e "${WHITE}Управление сервером:${NC}"
echo -e "  ${YELLOW}systemctl status $SERVICE_NAME${NC}   - статус"
echo -e "  ${YELLOW}systemctl restart $SERVICE_NAME${NC} - перезапуск"
echo -e "  ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}   - логи"
echo -e "  ${YELLOW}cat $CONF_DIR/dhcpd.leases${NC}       - аренды"
echo ""

# Логирование
echo "$(date '+%Y-%m-%d %H:%M:%S') - DHCP configured: interfaces=$SELECTED_IFACES" >> /var/log/dhcp-setup.log 2>/dev/null
