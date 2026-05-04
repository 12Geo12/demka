#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux (AUTO VERSION)
# Настройка DNS сервера на HQ-SRV с автоматическим определением IP
#
# Задание 10:
# - Основной DNS-сервер на HQ-SRV
# - Разрешение имён в адреса и обратно
# - DNS сервер пересылки: 77.88.8.8
#
# АВТОМАТИЧЕСКОЕ ОПРЕДЕЛЕНИЕ:
# - IP адреса устройств из схемы сети
# - Определение текущего сервера по IP
# - Автоматическая настройка всех записей
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Параметры по умолчанию
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

#===============================================================================
# БАЗА ДАННЫХ IP АДРЕСОВ ИЗ СХЕМЫ СЕТИ
#===============================================================================
# Формат: "имя IP_адрес PTR_флаг маска описание"
# PTR_флаг: yes/no - создавать ли PTR запись

declare -A NETWORK_DEVICES=(
    # Маршрутизаторы
    ["hq-rtr"]="192.168.10.1 yes 24 HQ-RTR маршрутизатор HQ"
    ["br-rtr"]="192.168.20.1 no 24 BR-RTR маршрутизатор BR"
    
    # Серверы
    ["hq-srv"]="192.168.10.2 yes 24 HQ-SRV сервер HQ (DNS)"
    ["br-srv"]="192.168.20.2 no 24 BR-SRV сервер BR"
    
    # ISP интерфейсы
    ["docker"]="172.16.10.1 no 24 ISP интерфейс к HQ-RTR"
    ["web"]="172.16.20.1 no 24 ISP интерфейс к BR-RTR"
    
    # Nameserver (добавляется автоматически)
    ["ns1"]="auto yes 24 DNS сервер"
)

# Подсети для обратных зон
declare -A REVERSE_ZONES=(
    ["192.168.10"]="hq-network"
    ["192.168.20"]="br-network"
    ["172.16.10"]="isp-hq"
    ["172.16.20"]="isp-br"
)

# Вывод сообщений
msg_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
msg_er() { echo -e "${RED}[✗]${NC} $1"; }
msg_in() { echo -e "${BLUE}[i]${NC} $1"; }
msg_wrn() { echo -e "${YELLOW}[!]${NC} $1"; }
msg_auto() { echo -e "${MAGENTA}[⚡]${NC} $1"; }

# Обработка ошибок с выходом
die() {
    msg_er "$1"
    exit 1
}

# Проверка root
if [ "$EUID" -ne 0 ]; then
    die "Запустите от root (su -)"
fi

# Определение пакетного менеджера
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    else
        die "Пакетный менеджер не найден"
    fi
}

# Автоматическое определение IP адресов на сервере
auto_detect_ips() {
    msg_in "Автоматическое определение IP адресов..."
    echo ""
    
    declare -a FOUND_IPS
    declare -a FOUND_IFACES
    
    # Получаем все IP адреса кроме loopback
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        iface=$(echo "$line" | awk '{print $1}')
        ip_full=$(echo "$line" | awk '{print $3}')
        [ -z "$ip_full" ] && continue
        
        ip=$(echo "$ip_full" | cut -d'/' -f1)
        iface_clean=$(echo "$iface" | cut -d'@' -f1)
        
        FOUND_IPS+=("$ip")
        FOUND_IFACES+=("$iface_clean")
        
    done < <(ip -br addr show | grep -v "^lo")
    
    if [ ${#FOUND_IPS[@]} -eq 0 ]; then
        die "IP адреса не найдены"
    fi
    
    # Определяем тип сервера по IP
    DETECTED_SERVER=""
    DETECTED_SERVER_IP=""
    
    for i in "${!FOUND_IPS[@]}"; do
        ip="${FOUND_IPS[$i]}"
        
        # Проверяем совпадение с известными устройствами
        for device in "${!NETWORK_DEVICES[@]}"; do
            device_ip=$(echo "${NETWORK_DEVICES[$device]}" | awk '{print $1}')
            if [ "$ip" = "$device_ip" ]; then
                DETECTED_SERVER="$device"
                DETECTED_SERVER_IP="$ip"
                break 2
            fi
        done
    done
    
    # Показываем найденные IP
    echo -e "${CYAN}Обнаруженные IP адреса:${NC}"
    for i in "${!FOUND_IPS[@]}"; do
        ip="${FOUND_IPS[$i]}"
        iface="${FOUND_IFACES[$i]}"
        
        # Проверяем, является ли этот IP известным устройством
        device_name=""
        for dev in "${!NETWORK_DEVICES[@]}"; do
            dev_ip=$(echo "${NETWORK_DEVICES[$dev]}" | awk '{print $1}')
            if [ "$ip" = "$dev_ip" ]; then
                device_name="$dev"
                break
            fi
        done
        
        if [ -n "$device_name" ]; then
            echo -e "  ${GREEN}✓${NC} $iface: ${YELLOW}$ip${NC} ${MAGENTA}[$device_name]${NC}"
        else
            echo -e "  ${GREEN}✓${NC} $iface: ${YELLOW}$ip${NC}"
        fi
    done
    echo ""
    
    # Если сервер определён
    if [ -n "$DETECTED_SERVER" ]; then
        msg_auto "Определён сервер: ${YELLOW}${DETECTED_SERVER}${NC} (${DETECTED_SERVER_IP})"
        return 0
    else
        msg_wrn "Сервер не определён автоматически"
        return 1
    fi
}

# Автоматический выбор DNS сервера
select_dns_server() {
    # Если это HQ-SRV - он будет DNS сервером
    if [ "$DETECTED_SERVER" = "hq-srv" ]; then
        DNS_SERVER_IP="$DETECTED_SERVER_IP"
        DNS_SERVER_IFACE=""
        
        # Находим интерфейс
        for i in "${!FOUND_IPS[@]}"; do
            if [ "${FOUND_IPS[$i]}" = "$DNS_SERVER_IP" ]; then
                DNS_SERVER_IFACE="${FOUND_IFACES[$i]}"
                break
            fi
        done
        
        msg_auto "DNS сервер будет настроен на этом устройстве: ${YELLOW}$DNS_SERVER_IP${NC}"
        return 0
    else
        # Скрипт запущен не на HQ-SRV
        msg_wrn "Этот скрипт должен запускаться на HQ-SRV!"
        msg_wrn "Определён сервер: $DETECTED_SERVER"
        msg_wrn "DNS сервер должен быть на hq-srv (192.168.10.2)"
        
        # Предлагаем выбрать IP вручную
        echo ""
        msg_in "Доступные IP для выбора:"
        for i in "${!FOUND_IPS[@]}"; do
            echo -e "  ${GREEN}[$((i+1))]${NC} ${FOUND_IFACES[$i]}: ${YELLOW}${FOUND_IPS[$i]}${NC}"
        done
        
        read -r -p "Выберите IP для DNS сервера [1-${#FOUND_IPS[@]}]: " num
        
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#FOUND_IPS[@]} ]; then
            DNS_SERVER_IP="${FOUND_IPS[$((num-1))]}"
            DNS_SERVER_IFACE="${FOUND_IFACES[$((num-1))]}"
        else
            die "Неверный выбор"
        fi
    fi
}

# Генерация DNS записей
generate_dns_entries() {
    msg_in "Генерация DNS записей из базы данных..."
    echo ""
    
    DNS_ENTRIES=()
    PTR_ENTRIES_HQ=()
    PTR_ENTRIES_BR=()
    
    for device in "${!NETWORK_DEVICES[@]}"; do
        data="${NETWORK_DEVICES[$device]}"
        ip=$(echo "$data" | awk '{print $1}')
        has_ptr=$(echo "$data" | awk '{print $2}')
        desc=$(echo "$data" | cut -d' ' -f4-)
        
        # Пропускаем ns1 - он добавится с IP сервера
        if [ "$device" = "ns1" ]; then
            continue
        fi
        
        DNS_ENTRIES+=("$device $ip")
        
        if [ "$has_ptr" = "yes" ]; then
            # Определяем к какой сети принадлежит для обратной зоны
            net=$(echo "$ip" | cut -d'.' -f1-3)
            if [ "$net" = "192.168.10" ]; then
                PTR_ENTRIES_HQ+=("$device $ip")
            elif [ "$net" = "192.168.20" ]; then
                PTR_ENTRIES_BR+=("$device $ip")
            fi
        fi
        
        echo -e "  ${GREEN}✓${NC} $device.$DOMAIN ${YELLOW}→${NC} $ip ${CYAN}$desc${NC}"
    done
    
    # Добавляем ns1 с IP DNS сервера
    DNS_ENTRIES+=("ns1 $DNS_SERVER_IP")
    echo -e "  ${GREEN}✓${NC} ns1.$DOMAIN ${YELLOW}→${NC} $DNS_SERVER_IP ${CYAN}DNS сервер${NC}"
    
    echo ""
    msg_ok "Всего A-записей: ${#DNS_ENTRIES[@]}"
    msg_ok "PTR записей HQ сети: ${#PTR_ENTRIES_HQ[@]}"
    msg_ok "PTR записей BR сети: ${#PTR_ENTRIES_BR[@]}"
}

# Парсинг аргументов
AUTO_MODE=true
MANUAL_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--manual)
            AUTO_MODE=false
            shift
            ;;
        -c|--confirm)
            MANUAL_CONFIRM=true
            shift
            ;;
        -h|--help)
            echo "Использование: $0 [OPTIONS]"
            echo ""
            echo "Опции:"
            echo "  -m, --manual    Ручной режим (выбор IP вручную)"
            echo "  -c, --confirm   Требовать подтверждение перед выполнением"
            echo "  -h, --help      Показать справку"
            echo ""
            echo "По умолчанию скрипт работает автоматически:"
            echo "  - Определяет IP адреса из схемы сети"
            echo "  - Находит HQ-SRV и настраивает DNS на нём"
            echo "  - Создаёт все записи автоматически"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Начало работы
clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup for Demo2026 - AUTO MODE${NC}"
echo -e "${CYAN}║${NC} ${GREEN}Автоматическое определение IP адресов${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

detect_pkg_manager
msg_ok "Пакетный менеджер: $PKG_MANAGER"

# Автоопределение
auto_detect_ips
select_dns_server

# Генерация записей
generate_dns_entries

# Параметры
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS сервера:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  IP сервера:     ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:          ${YELLOW}$DOMAIN${NC}"
echo -e "  DNS пересылки:  ${YELLOW}$FORWARDER${NC}"
echo -e "  Обратная зона:  ${YELLOW}192.168.10.in-addr.arpa${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

if [ "$MANUAL_CONFIRM" = true ] || [ "$AUTO_MODE" = false ]; then
    echo ""
    read -r -p "Применить настройки? (y/n): " confirm
    case "$confirm" in
        [Yy]*) ;;
        *) msg_in "Отменено"; exit 0 ;;
    esac
fi

#===========================================
# УСТАНОВКА И НАСТРОЙКА
#===========================================
echo ""
msg_in "Установка DNS сервера..."

case "$PKG_MANAGER" in
    apt-get)
        apt-get update -qq 2>/dev/null
        apt-get install -y $PKG_NAME || die "Ошибка установки"
        ;;
    dnf)
        dnf install -y $PKG_NAME || die "Ошибка установки"
        ;;
    yum)
        yum install -y $PKG_NAME || die "Ошибка установки"
        ;;
esac

msg_ok "Пакет установлен: $PKG_NAME"

# Создание директорий
echo ""
msg_in "Создание директорий..."

mkdir -p /var/named/data || die "Не удалось создать /var/named/data"
chown -R $NAMED_USER:$NAMED_USER /var/named 2>/dev/null || chown -R root:$NAMED_USER /var/named
chmod 775 /var/named /var/named/data

msg_ok "Директории созданы"

# Создание named.conf
msg_in "Создание конфигурации..."

cat > /etc/named.conf << EOF
// DNS Server for Demo2026 - Auto-generated
// Server: $DETECTED_SERVER
// Generated: $(date)

options {
    listen-on port 53 { 127.0.0.1; $DNS_SERVER_IP; };
    listen-on-v6 port 53 { ::1; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    recursing-file  "/var/named/data/named.recursing";
    secroots-file   "/var/named/data/named.secroots";
    
    allow-query     { any; };
    allow-recursion { any; };
    
    recursion yes;
    dnssec-enable no;
    dnssec-validation no;
    
    forwarders { $FORWARDER; };
    forward only;
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

// Зона прямого просмотра
zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.zone";
    allow-update { none; };
};

// Зона обратного просмотра HQ сети
zone "10.168.192.in-addr.arpa" IN {
    type master;
    file "$DOMAIN.rev";
    allow-update { none; };
};
EOF

msg_ok "named.conf создан"

# Зона прямого просмотра
msg_in "Создание зоны прямого просмотра..."

SERIAL=$(date +%Y%m%d01)
ZONE_FILE="/var/named/$DOMAIN.zone"

cat > "$ZONE_FILE" << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL      ; Serial
        3600         ; Refresh
        1800         ; Retry
        604800       ; Expire
        86400        ; Minimum
)

@       IN  NS      ns1.$DOMAIN.
ns1     IN  A       $DNS_SERVER_IP

EOF

# Добавляем все A-записи
for entry in "${DNS_ENTRIES[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    ip=$(echo "$entry" | awk '{print $2}')
    echo "$name    IN  A       $ip" >> "$ZONE_FILE"
done

msg_ok "Зона создана: $ZONE_FILE"

# Зона обратного просмотра
msg_in "Создание зоны обратного просмотра..."

REV_FILE="/var/named/$DOMAIN.rev"

cat > "$REV_FILE" << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL      ; Serial
        3600         ; Refresh
        1800         ; Retry
        604800       ; Expire
        86400        ; Minimum
)

@       IN  NS      ns1.$DOMAIN.

EOF

# PTR записи для HQ сети
for entry in "${PTR_ENTRIES_HQ[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    ip=$(echo "$entry" | awk '{print $2}')
    last_octet=$(echo "$ip" | cut -d'.' -f4)
    echo "$last_octet     IN  PTR     $name.$DOMAIN." >> "$REV_FILE"
done

msg_ok "Зона обратного просмотра создана: $REV_FILE"

# Права
chown $NAMED_USER:$NAMED_USER "$ZONE_FILE" "$REV_FILE" 2>/dev/null || chown root:$NAMED_USER "$ZONE_FILE" "$REV_FILE"
chown root:$NAMED_USER /etc/named.conf 2>/dev/null
chmod 640 "$ZONE_FILE" "$REV_FILE" /etc/named.conf

# Проверка конфигурации
echo ""
msg_in "Проверка конфигурации..."

if ! named-checkconf 2>&1; then
    die "Ошибки в named.conf"
fi
msg_ok "named.conf валиден"

if ! named-checkzone "$DOMAIN" "$ZONE_FILE" 2>&1; then
    die "Ошибки в зоне $DOMAIN"
fi
msg_ok "Зона $DOMAIN валидна"

named-checkzone "10.168.192.in-addr.arpa" "$REV_FILE" 2>&1 && msg_ok "Зона обратного просмотра валидна"

# Firewall
echo ""
msg_in "Настройка firewall..."

if command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft 'add chain inet filter input { type filter hook input priority 0 ; }' 2>/dev/null
    nft add rule inet filter input tcp dport 53 accept 2>/dev/null
    nft add rule inet filter input udp dport 53 accept 2>/dev/null
    msg_ok "Firewall (nftables)"
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 53 -j ACCEPT
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT
    msg_ok "Firewall (iptables)"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    msg_ok "Firewall (firewalld)"
fi

# Запуск
echo ""
msg_in "Запуск DNS сервера..."

systemctl stop $SERVICE_NAME 2>/dev/null
systemctl enable $SERVICE_NAME 2>/dev/null
systemctl start $SERVICE_NAME

sleep 3

if ! systemctl is-active --quiet $SERVICE_NAME; then
    msg_er "Ошибка запуска!"
    systemctl status $SERVICE_NAME --no-pager
    journalctl -u $SERVICE_NAME -n 20 --no-pager
    die "DNS сервер не запущен"
fi

msg_ok "DNS сервер запущен!"

# resolv.conf
msg_in "Настройка resolv.conf..."

[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s)

if ! grep -q "nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null; then
    sed -i "1i\nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null || echo "nameserver $DNS_SERVER_IP" > /etc/resolv.conf
fi

if ! grep -q "search.*$DOMAIN" /etc/resolv.conf 2>/dev/null; then
    echo "search $DOMAIN" >> /etc/resolv.conf
fi

msg_ok "resolv.conf настроен"

# ИТОГ
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        DNS СЕРВЕР УСПЕШНО НАСТРОЕН!                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Параметры:${NC}"
echo -e "  IP сервера:     ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:          ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:      ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${CYAN}A-записи:${NC}"
for entry in "${DNS_ENTRIES[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    ip=$(echo "$entry" | awk '{print $2}')
    printf "  %-12s → %s\n" "$name.$DOMAIN" "$ip"
done
echo ""
echo -e "${CYAN}PTR-записи (HQ сеть):${NC}"
for entry in "${PTR_ENTRIES_HQ[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    ip=$(echo "$entry" | awk '{print $2}')
    printf "  %-15s → %s.$DOMAIN\n" "$ip" "$name"
done
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup 192.168.10.1 $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
