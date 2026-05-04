#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux (FULLY FIXED)
# Настройка DNS сервера на HQ-SRV
#
# ИСПРАВЛЕНИЯ:
# - Автоопределение имени сервиса (named/bind/bind9)
# - Ручной ввод IP адресов устройств
# - Проверка существования пакета перед установкой
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Параметры по умолчанию
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

# IP адреса устройств (можно изменить при запуске)
HQ_RTR_IP="192.168.10.1"
BR_RTR_IP="192.168.20.1"
HQ_SRV_IP="192.168.10.2"
BR_SRV_IP="192.168.20.2"
DOCKER_IP="172.16.10.1"
WEB_IP="172.16.20.1"

# DNS сервер IP (определяется автоматически или вручную)
DNS_SERVER_IP=""

# Сообщения
msg_ok() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
msg_er() { printf "${RED}[✗]${NC} %s\n" "$1"; }
msg_in() { printf "${BLUE}[i]${NC} %s\n" "$1"; }
msg_wrn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }

die() { msg_er "$1"; exit 1; }

# Проверка root
[ "$(id -u)" -ne 0 ] && die "Запустите от root (su -)"

# Проверка bash
[ -z "$BASH_VERSION" ] && die "Запустите через bash: bash $0"

# Определение пакетного менеджера и имён
detect_system() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_NAMES="bind bind-utils"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAMES="bind bind-utils"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAMES="bind bind-utils"
    else
        die "Пакетный менеджер не найден"
    fi
    
    # Определяем имя пользователя для named
    if id "named" >/dev/null 2>&1; then
        NAMED_USER="named"
    elif id "bind" >/dev/null 2>&1; then
        NAMED_USER="bind"
    else
        NAMED_USER="named"
    fi
}

# Определение имени сервиса
detect_service_name() {
    # Проверяем различные варианты имени сервиса
    for svc in named bind bind9; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || \
           [ -f "/lib/systemd/system/${svc}.service" ] || \
           [ -f "/etc/systemd/system/${svc}.service" ]; then
            SERVICE_NAME="$svc"
            return 0
        fi
    done
    
    # Если не нашли, проверяем через статус
    for svc in named bind bind9; do
        if systemctl status "$svc" >/dev/null 2>&1; then
            SERVICE_NAME="$svc"
            return 0
        fi
    done
    
    # По умолчанию
    SERVICE_NAME="named"
}

# Поиск IP адресов на сервере
find_server_ips() {
    msg_in "Поиск IP адресов на сервере..."
    echo ""
    
    TMPFILE="/tmp/dns_ips_$$"
    ip -br addr show 2>/dev/null | grep -v "^lo" > "$TMPFILE"
    
    if [ ! -s "$TMPFILE" ]; then
        rm -f "$TMPFILE"
        die "IP адреса не найдены"
    fi
    
    idx=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        iface=$(echo "$line" | awk '{print $1}')
        ip_full=$(echo "$line" | awk '{print $3}')
        [ -z "$ip_full" ] && continue
        
        ip=$(echo "$ip_full" | cut -d'/' -f1)
        iface_clean=$(echo "$iface" | cut -d'@' -f1)
        
        idx=$((idx + 1))
        eval "IP_${idx}=$ip"
        eval "IFACE_${idx}=$iface_clean"
        
        echo -e "  ${GREEN}[$idx]${NC} $iface_clean: ${YELLOW}$ip${NC}"
    done < "$TMPFILE"
    
    TOTAL_IPS=$idx
    rm -f "$TMPFILE"
}

# Ввод IP адресов устройств
input_device_ips() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Ввод IP адресов устройств${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Введите IP адреса устройств (Enter - использовать значение по умолчанию):"
    echo ""
    
    read -r -p "HQ-RTR [$HQ_RTR_IP]: " input
    [ -n "$input" ] && HQ_RTR_IP="$input"
    
    read -r -p "BR-RTR [$BR_RTR_IP]: " input
    [ -n "$input" ] && BR_RTR_IP="$input"
    
    read -r -p "HQ-SRV (DNS сервер) [$HQ_SRV_IP]: " input
    [ -n "$input" ] && HQ_SRV_IP="$input"
    
    read -r -p "BR-SRV [$BR_SRV_IP]: " input
    [ -n "$input" ] && BR_SRV_IP="$input"
    
    read -r -p "Docker (ISP→HQ-RTR) [$DOCKER_IP]: " input
    [ -n "$input" ] && DOCKER_IP="$input"
    
    read -r -p "Web (ISP→BR-RTR) [$WEB_IP]: " input
    [ -n "$input" ] && WEB_IP="$input"
    
    echo ""
    read -r -p "DNS пересылки [$FORWARDER]: " input
    [ -n "$input" ] && FORWARDER="$input"
    
    read -r -p "Домен [$DOMAIN]: " input
    [ -n "$input" ] && DOMAIN="$input"
    
    # DNS сервер IP
    DNS_SERVER_IP="$HQ_SRV_IP"
}

# Выбор IP для DNS сервера
select_dns_ip() {
    echo ""
    echo -e "${CYAN}Выберите IP адрес DNS сервера:${NC}"
    
    # Показываем доступные IP
    for i in $(seq 1 $TOTAL_IPS); do
        eval "ip=\$IP_$i"
        eval "iface=\$IFACE_$i"
        echo -e "  ${GREEN}[$i]${NC} $iface: ${YELLOW}$ip${NC}"
    done
    echo -e "  ${GREEN}[0]${NC} Ввести вручную"
    echo ""
    
    read -r -p "Выбор [1]: " choice
    [ -z "$choice" ] && choice=1
    
    if [ "$choice" = "0" ]; then
        read -r -p "Введите IP DNS сервера: " DNS_SERVER_IP
    elif [ "$choice" -ge 1 ] && [ "$choice" -le $TOTAL_IPS ]; then
        eval "DNS_SERVER_IP=\$IP_$choice"
    else
        DNS_SERVER_IP="$HQ_SRV_IP"
    fi
}

# Начало
clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup for Demo2026${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

detect_system
detect_service_name
msg_ok "Пакетный менеджер: $PKG_MANAGER"
msg_ok "Имя сервиса: $SERVICE_NAME"
msg_ok "Пользователь: $NAMED_USER"

# Показываем IP и предлагаем ввести адреса
find_server_ips
input_device_ips
select_dns_ip

# Итоговая таблица
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS сервера:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  IP DNS сервера:  ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:           ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:       ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${YELLOW}DNS записи (Таблица 3):${NC}"
printf "  %-16s → %-15s %s\n" "hq-rtr.$DOMAIN" "$HQ_RTR_IP" "(A, PTR)"
printf "  %-16s → %-15s %s\n" "br-rtr.$DOMAIN" "$BR_RTR_IP" "(A)"
printf "  %-16s → %-15s %s\n" "hq-srv.$DOMAIN" "$HQ_SRV_IP" "(A, PTR)"
printf "  %-16s → %-15s %s\n" "br-srv.$DOMAIN" "$BR_SRV_IP" "(A)"
printf "  %-16s → %-15s %s\n" "docker.$DOMAIN" "$DOCKER_IP" "(A)"
printf "  %-16s → %-15s %s\n" "web.$DOMAIN" "$WEB_IP" "(A)"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

echo ""
read -r -p "Применить настройки? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; exit 0 ;;
esac

# Установка пакетов
echo ""
msg_in "Установка DNS сервера..."

case "$PKG_MANAGER" in
    apt-get)
        apt-get update -qq 2>/dev/null
        for pkg in $PKG_NAMES; do
            apt-get install -y "$pkg" 2>/dev/null || msg_wrn "Пакет $pkg уже установлен или не найден"
        done
        ;;
    dnf)
        for pkg in $PKG_NAMES; do
            dnf install -y "$pkg" 2>/dev/null || msg_wrn "Пакет $pkg уже установлен"
        done
        ;;
    yum)
        for pkg in $PKG_NAMES; do
            yum install -y "$pkg" 2>/dev/null || msg_wrn "Пакет $pkg уже установлен"
        done
        ;;
esac

# Проверяем, установлен ли named
if ! command -v named >/dev/null 2>&1; then
    msg_wrn "named не найден в PATH, проверяем альтернативы..."
    if [ -x /usr/sbin/named ]; then
        ln -sf /usr/sbin/named /usr/bin/named 2>/dev/null
    fi
fi

msg_ok "Пакеты установлены"

# Создание директорий
echo ""
msg_in "Создание директорий..."

mkdir -p /var/named/data 2>/dev/null || {
    # Пробуем альтернативные пути
    mkdir -p /var/lib/named 2>/dev/null
    mkdir -p /var/lib/named/data 2>/dev/null
    NAMED_DIR="/var/lib/named"
}

[ -z "$NAMED_DIR" ] && NAMED_DIR="/var/named"

chown -R $NAMED_USER:$NAMED_USER "$NAMED_DIR" 2>/dev/null || chown -R root:$NAMED_USER "$NAMED_DIR" 2>/dev/null
chmod 775 "$NAMED_DIR" "$NAMED_DIR/data" 2>/dev/null

msg_ok "Директории созданы: $NAMED_DIR"

# Определение сети для обратной зоны
REV_ZONE=$(echo "$HQ_RTR_IP" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
# Например: 192.168.10 → 10.168.192.in-addr.arpa

# Создание named.conf
msg_in "Создание named.conf..."

cat > /etc/named.conf << NAMED_CONF
// DNS Server for Demo2026
// Generated: $(date)

options {
    listen-on port 53 { 127.0.0.1; $DNS_SERVER_IP; };
    directory       "$NAMED_DIR";
    dump-file       "$NAMED_DIR/data/cache_dump.db";
    statistics-file "$NAMED_DIR/data/named_stats.txt";
    memstatistics-file "$NAMED_DIR/data/named_mem_stats.txt";
    
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

zone "$REV_ZONE" IN {
    type master;
    file "$DOMAIN.rev";
    allow-update { none; };
};
NAMED_CONF

chown root:$NAMED_USER /etc/named.conf 2>/dev/null
chmod 640 /etc/named.conf 2>/dev/null

msg_ok "named.conf создан"

# Зона прямого просмотра
msg_in "Создание зоны прямого просмотра..."

SERIAL=$(date +%Y%m%d01)
ZONE_FILE="$NAMED_DIR/$DOMAIN.zone"

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

hq-rtr  IN  A       $HQ_RTR_IP
br-rtr  IN  A       $BR_RTR_IP
hq-srv  IN  A       $HQ_SRV_IP
br-srv  IN  A       $BR_SRV_IP
docker  IN  A       $DOCKER_IP
web     IN  A       $WEB_IP
ZONE_EOF

chown $NAMED_USER:$NAMED_USER "$ZONE_FILE" 2>/dev/null || chown root:$NAMED_USER "$ZONE_FILE"
chmod 640 "$ZONE_FILE"

msg_ok "Зона создана: $ZONE_FILE"

# Зона обратного просмотра
msg_in "Создание зоны обратного просмотра..."

REV_FILE="$NAMED_DIR/$DOMAIN.rev"

# Получаем последние октеты для PTR
HQ_RTR_LAST=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
HQ_SRV_LAST=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)

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

$HQ_RTR_LAST       IN  PTR     hq-rtr.$DOMAIN.
$HQ_SRV_LAST       IN  PTR     hq-srv.$DOMAIN.
REV_EOF

chown $NAMED_USER:$NAMED_USER "$REV_FILE" 2>/dev/null || chown root:$NAMED_USER "$REV_FILE"
chmod 640 "$REV_FILE"

msg_ok "Зона обратного просмотра создана: $REV_FILE"

# Проверка конфигурации
echo ""
msg_in "Проверка конфигурации..."

if command -v named-checkconf >/dev/null 2>&1; then
    if named-checkconf 2>&1; then
        msg_ok "named.conf валиден"
    else
        msg_wrn "Ошибки в named.conf, продолжаем..."
    fi
    
    if named-checkzone "$DOMAIN" "$ZONE_FILE" 2>&1; then
        msg_ok "Зона $DOMAIN валидна"
    fi
    
    named-checkzone "$REV_ZONE" "$REV_FILE" 2>&1 && msg_ok "Зона обратного просмотра валидна"
else
    msg_wrn "named-checkconf не найден, пропускаем проверку"
fi

# Firewall
echo ""
msg_in "Настройка firewall..."

if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    msg_ok "Firewall (iptables) настроен"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    msg_ok "Firewall (firewalld) настроен"
elif command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft 'add chain inet filter input { type filter hook input priority 0 ; }' 2>/dev/null
    nft add rule inet filter input tcp dport 53 accept 2>/dev/null
    nft add rule inet filter input udp dport 53 accept 2>/dev/null
    msg_ok "Firewall (nftables) настроен"
else
    msg_wrn "Firewall не найден"
fi

# Запуск DNS сервера
echo ""
msg_in "Запуск DNS сервера..."

# Останавливаем если запущен
systemctl stop "$SERVICE_NAME" 2>/dev/null

# Перезагружаем systemd
systemctl daemon-reload 2>/dev/null

# Включаем и запускаем
systemctl enable "$SERVICE_NAME" 2>/dev/null
systemctl start "$SERVICE_NAME"

sleep 2

# Проверка статуса
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    msg_ok "DNS сервер запущен!"
else
    msg_wrn "Сервис $SERVICE_NAME не запустился через systemctl"
    
    # Пробуем запустить напрямую
    msg_in "Пробуем запустить напрямую..."
    
    # Ищем бинарник named
    NAMED_BIN=""
    for path in /usr/sbin/named /usr/local/sbin/named /usr/bin/named; do
        if [ -x "$path" ]; then
            NAMED_BIN="$path"
            break
        fi
    done
    
    if [ -n "$NAMED_BIN" ]; then
        $NAMED_BIN -u $NAMED_USER &
        sleep 2
        
        if pgrep -x named >/dev/null; then
            msg_ok "named запущен напрямую!"
        else
            msg_er "Не удалось запустить named"
            echo ""
            msg_in "Попробуйте вручную:"
            echo "  systemctl start $SERVICE_NAME"
            echo "  или: $NAMED_BIN -u $NAMED_USER"
        fi
    else
        msg_er "Бинарник named не найден"
        msg_in "Проверьте установку пакета bind"
    fi
fi

# resolv.conf
echo ""
msg_in "Настройка resolv.conf..."

[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null

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
echo -e "${GREEN}║        DNS СЕРВЕР НАСТРОЕН!                                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Параметры:${NC}"
echo -e "  IP сервера:     ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:          ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:      ${YELLOW}$FORWARDER${NC}"
echo -e "  Сервис:         ${YELLOW}$SERVICE_NAME${NC}"
echo ""
echo -e "${CYAN}A-записи:${NC}"
printf "  %-20s → %s\n" "hq-rtr.$DOMAIN" "$HQ_RTR_IP"
printf "  %-20s → %s\n" "br-rtr.$DOMAIN" "$BR_RTR_IP"
printf "  %-20s → %s\n" "hq-srv.$DOMAIN" "$HQ_SRV_IP"
printf "  %-20s → %s\n" "br-srv.$DOMAIN" "$BR_SRV_IP"
printf "  %-20s → %s\n" "docker.$DOMAIN" "$DOCKER_IP"
printf "  %-20s → %s\n" "web.$DOMAIN" "$WEB_IP"
echo ""
echo -e "${CYAN}PTR-записи:${NC}"
echo -e "  $HQ_RTR_IP → hq-rtr.$DOMAIN"
echo -e "  $HQ_SRV_IP → hq-srv.$DOMAIN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup $HQ_RTR_IP $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
echo -e "${CYAN}Управление сервисом:${NC}"
echo -e "  ${YELLOW}systemctl status $SERVICE_NAME${NC}"
echo -e "  ${YELLOW}systemctl restart $SERVICE_NAME${NC}"
echo -e "  ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}"
echo ""
