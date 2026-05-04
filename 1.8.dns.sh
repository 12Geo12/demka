#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux (POSIX COMPATIBLE)
# Настройка DNS сервера на HQ-SRV с автоматическим определением IP
#
# ВНИМАНИЕ: Запускать через bash, не через sh!
#   bash ./1.8.dns-fixed.sh
#
# Задание 10:
# - Основной DNS-сервер на HQ-SRV
# - Разрешение имён в адреса и обратно (A + PTR)
# - DNS сервер пересылки: 77.88.8.8
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Параметры
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"
DNS_SERVER_IP=""
DETECTED_SERVER=""

# DNS записи из таблицы 3 (без hq-cli)
# Формат: "имя:IP:PTR_флаг"
DNS_RECORDS="
hq-rtr:192.168.10.1:yes
br-rtr:192.168.20.1:no
hq-srv:192.168.10.2:yes
br-srv:192.168.20.2:no
docker:172.16.10.1:no
web:172.16.20.1:no
"

# Сообщения
msg_ok() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
msg_er() { printf "${RED}[✗]${NC} %s\n" "$1"; }
msg_in() { printf "${BLUE}[i]${NC} %s\n" "$1"; }
msg_wrn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
msg_auto() { printf "${MAGENTA}[⚡]${NC} %s\n" "$1"; }

die() {
    msg_er "$1"
    exit 1
}

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    die "Запустите от root (su -)"
fi

# Проверка bash
if [ -z "$BASH_VERSION" ]; then
    die "Запустите через bash: bash $0"
fi

# Определение пакетного менеджера
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        die "Пакетный менеджер не найден"
    fi
    PKG_NAME="bind"
    SERVICE_NAME="named"
    NAMED_USER="named"
}

# Автоматическое определение IP адресов
auto_detect_ips() {
    msg_in "Автоматическое определение IP адресов..."
    echo ""
    
    TMPFILE="/tmp/dns_ips_$$"
    ip -br addr show 2>/dev/null | grep -v "^lo" > "$TMPFILE"
    
    if [ ! -s "$TMPFILE" ]; then
        rm -f "$TMPFILE"
        die "IP адреса не найдены"
    fi
    
    echo -e "${CYAN}Обнаруженные IP адреса:${NC}"
    
    idx=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        iface=$(echo "$line" | awk '{print $1}')
        ip_full=$(echo "$line" | awk '{print $3}')
        [ -z "$ip_full" ] && continue
        
        ip=$(echo "$ip_full" | cut -d'/' -f1)
        iface_clean=$(echo "$iface" | cut -d'@' -f1)
        
        # Проверяем, является ли IP известным устройством
        device_name=""
        case "$ip" in
            192.168.10.1) device_name="hq-rtr" ;;
            192.168.20.1) device_name="br-rtr" ;;
            192.168.10.2) device_name="hq-srv" ;;
            192.168.20.2) device_name="br-srv" ;;
            172.16.10.1) device_name="docker" ;;
            172.16.20.1) device_name="web" ;;
        esac
        
        if [ -n "$device_name" ]; then
            echo -e "  ${GREEN}✓${NC} $iface_clean: ${YELLOW}$ip${NC} ${MAGENTA}[$device_name]${NC}"
            DETECTED_SERVER="$device_name"
        else
            echo -e "  ${GREEN}✓${NC} $iface_clean: ${YELLOW}$ip${NC}"
        fi
        
        idx=$((idx + 1))
    done < "$TMPFILE"
    
    rm -f "$TMPFILE"
    echo ""
    
    if [ -n "$DETECTED_SERVER" ]; then
        msg_auto "Определён сервер: ${YELLOW}${DETECTED_SERVER}${NC}"
    fi
}

# Выбор DNS сервера
select_dns_server() {
    # Получаем IP текущего сервера
    case "$DETECTED_SERVER" in
        hq-srv)
            DNS_SERVER_IP="192.168.10.2"
            msg_auto "DNS сервер будет настроен на этом устройстве: ${YELLOW}$DNS_SERVER_IP${NC}"
            ;;
        hq-rtr)
            DNS_SERVER_IP="192.168.10.1"
            msg_wrn "Скрипт запущен на HQ-RTR, но DNS должен быть на HQ-SRV!"
            msg_in "Настраиваем DNS на HQ-RTR (IP: $DNS_SERVER_IP)"
            ;;
        br-rtr)
            DNS_SERVER_IP="192.168.20.1"
            msg_wrn "Скрипт запущен на BR-RTR, но DNS должен быть на HQ-SRV!"
            ;;
        br-srv)
            DNS_SERVER_IP="192.168.20.2"
            msg_wrn "Скрипт запущен на BR-SRV, но DNS должен быть на HQ-SRV!"
            ;;
        *)
            # Пытаемся найти подходящий IP
            FOUND_IP=$(ip -br addr show 2>/dev/null | grep -v "^lo" | head -1 | awk '{print $3}' | cut -d'/' -f1)
            if [ -n "$FOUND_IP" ]; then
                DNS_SERVER_IP="$FOUND_IP"
                msg_in "Используем первый найденный IP: ${YELLOW}$DNS_SERVER_IP${NC}"
            else
                die "Не удалось определить IP адрес"
            fi
            ;;
    esac
}

# Парсинг аргументов
AUTO_MODE=true

for arg in "$@"; do
    case "$arg" in
        -m|--manual) AUTO_MODE=false ;;
        -h|--help)
            echo "Использование: bash $0 [OPTIONS]"
            echo ""
            echo "Опции:"
            echo "  -m, --manual    Ручной режим"
            echo "  -h, --help      Справка"
            exit 0
            ;;
    esac
done

# Начало
clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup for Demo2026${NC}"
echo -e "${CYAN}║${NC} ${GREEN}Автоматическое определение IP адресов${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

detect_pkg_manager
msg_ok "Пакетный менеджер: $PKG_MANAGER"

auto_detect_ips
select_dns_server

# Показ параметров
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  IP сервера:     ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:          ${YELLOW}$DOMAIN${NC}"
echo -e "  DNS пересылки:  ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${YELLOW}DNS записи (Таблица 3):${NC}"
echo -e "  hq-rtr.$DOMAIN  → 192.168.10.1  (PTR)"
echo -e "  br-rtr.$DOMAIN  → 192.168.20.1"
echo -e "  hq-srv.$DOMAIN  → 192.168.10.2  (PTR)"
echo -e "  br-srv.$DOMAIN  → 192.168.20.2"
echo -e "  docker.$DOMAIN  → 172.16.10.1"
echo -e "  web.$DOMAIN     → 172.16.20.1"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"

if [ "$AUTO_MODE" = false ]; then
    echo ""
    read -r -p "Применить? (y/n): " confirm
    case "$confirm" in
        [Yy]*) ;;
        *) msg_in "Отменено"; exit 0 ;;
    esac
fi

# Установка
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

# Создание директорий (КРИТИЧЕСКИ ВАЖНО!)
echo ""
msg_in "Создание директорий..."

mkdir -p /var/named/data || die "Не удалось создать /var/named/data"
chown -R $NAMED_USER:$NAMED_USER /var/named 2>/dev/null || chown -R root:$NAMED_USER /var/named
chmod 775 /var/named /var/named/data

msg_ok "Директории созданы"

# Создание named.conf
msg_in "Создание named.conf..."

cat > /etc/named.conf << NAMED_CONF
// DNS Server for Demo2026
// Generated: $(date)

options {
    listen-on port 53 { 127.0.0.1; $DNS_SERVER_IP; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    allow-query     { any; };
    recursion yes;
    dnssec-enable no;
    dnssec-validation no;
    
    forwarders { $FORWARDER; };
};

zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.zone";
    allow-update { none; };
};

zone "10.168.192.in-addr.arpa" IN {
    type master;
    file "$DOMAIN.rev";
    allow-update { none; };
};
NAMED_CONF

msg_ok "named.conf создан"

# Зона прямого просмотра
msg_in "Создание зоны прямого просмотра..."

SERIAL=$(date +%Y%m%d01)
ZONE_FILE="/var/named/$DOMAIN.zone"

cat > "$ZONE_FILE" << ZONE_EOF
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

hq-rtr  IN  A       192.168.10.1
br-rtr  IN  A       192.168.20.1
hq-srv  IN  A       192.168.10.2
br-srv  IN  A       192.168.20.2
docker  IN  A       172.16.10.1
web     IN  A       172.16.20.1
ZONE_EOF

msg_ok "Зона создана: $ZONE_FILE"

# Зона обратного просмотра
msg_in "Создание зоны обратного просмотра..."

REV_FILE="/var/named/$DOMAIN.rev"

cat > "$REV_FILE" << REV_EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL      ; Serial
        3600         ; Refresh
        1800         ; Retry
        604800       ; Expire
        86400        ; Minimum
)

@       IN  NS      ns1.$DOMAIN.

1       IN  PTR     hq-rtr.$DOMAIN.
2       IN  PTR     hq-srv.$DOMAIN.
REV_EOF

msg_ok "Зона обратного просмотра создана: $REV_FILE"

# Права
chown $NAMED_USER:$NAMED_USER "$ZONE_FILE" "$REV_FILE" 2>/dev/null || chown root:$NAMED_USER "$ZONE_FILE" "$REV_FILE"
chown root:$NAMED_USER /etc/named.conf 2>/dev/null
chmod 640 "$ZONE_FILE" "$REV_FILE" /etc/named.conf

msg_ok "Права установлены"

# Проверка конфигурации
echo ""
msg_in "Проверка конфигурации..."

if ! named-checkconf 2>&1; then
    die "Ошибки в named.conf"
fi
msg_ok "named.conf валиден"

if ! named-checkzone "$DOMAIN" "$ZONE_FILE" 2>&1; then
    die "Ошибки в зоне"
fi
msg_ok "Зона $DOMAIN валидна"

named-checkzone "10.168.192.in-addr.arpa" "$REV_FILE" 2>&1 && msg_ok "Зона обратного просмотра валидна"

# Firewall
echo ""
msg_in "Настройка firewall..."

if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 53 -j ACCEPT
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT
    msg_ok "Firewall (iptables)"
elif command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft 'add chain inet filter input { type filter hook input priority 0 ; }' 2>/dev/null
    nft add rule inet filter input tcp dport 53 accept 2>/dev/null
    nft add rule inet filter input udp dport 53 accept 2>/dev/null
    msg_ok "Firewall (nftables)"
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

if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null
fi

# Добавляем локальный DNS в начало
if ! grep -q "nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null; then
    sed -i "1i\nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null || {
        echo "nameserver $DNS_SERVER_IP" > /etc/resolv.conf
    }
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
echo -e "${CYAN}IP сервера:${NC}     ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "${CYAN}Домен:${NC}          ${YELLOW}$DOMAIN${NC}"
echo -e "${CYAN}Пересылка:${NC}      ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${CYAN}A-записи:${NC}"
echo -e "  hq-rtr.$DOMAIN  → 192.168.10.1"
echo -e "  br-rtr.$DOMAIN  → 192.168.20.1"
echo -e "  hq-srv.$DOMAIN  → 192.168.10.2"
echo -e "  br-srv.$DOMAIN  → 192.168.20.2"
echo -e "  docker.$DOMAIN  → 172.16.10.1"
echo -e "  web.$DOMAIN     → 172.16.20.1"
echo ""
echo -e "${CYAN}PTR-записи:${NC}"
echo -e "  192.168.10.1 → hq-rtr.$DOMAIN"
echo -e "  192.168.10.2 → hq-srv.$DOMAIN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup 192.168.10.1 $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
