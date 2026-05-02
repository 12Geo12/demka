#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux
# Настройка DNS сервера на HQ-SRV
#
# Задание 10:
# - Основной DNS-сервер на HQ-SRV
# - Разрешение имён в адреса и обратно
# - DNS сервер пересылки: 77.88.8.8
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

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
        PKG_NAME="bind"
        SERVICE_NAME="named"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAME="bind"
        SERVICE_NAME="named"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAME="bind"
        SERVICE_NAME="named"
    else
        msg_er "Пакетный менеджер не найден"
        exit 1
    fi
}

# Очистка экрана
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup for Demo2026${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

detect_pkg_manager
msg_ok "Пакетный менеджер: $PKG_MANAGER"

# Получаем IP адрес сервера
echo -e "\n${BLUE}Поиск IP адресов...${NC}\n"

SERVER_IP=""
INTERFACE=""

TMPFILE="/tmp/dns_ifaces_$$"
ip -br addr show | grep -v "^lo" > "$TMPFILE"

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    
    # Очищаем имя интерфейса
    iface_clean=$(echo "$iface" | cut -d'@' -f1)
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface_clean ${YELLOW}→${NC} $ip"
    
    echo "$iface_clean" >> /tmp/dns_iface_$$
    echo "$ip" >> /tmp/dns_ip_$$
    
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"

TOTAL=$idx

if [ $TOTAL -eq 0 ]; then
    msg_er "IP адреса не найдены"
    rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$
    exit 1
fi

# Выбор интерфейса
echo ""
read -r -p "Выберите IP для DNS сервера [1-$TOTAL]: " num

case "$num" in
    ''|*[!0-9]*)
        msg_er "Неверный выбор"
        rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$
        exit 1
        ;;
esac

if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL" ]; then
    msg_er "Неверный выбор"
    rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$
    exit 1
fi

SERVER_IP=$(sed -n "${num}p" /tmp/dns_ip_$$)
INTERFACE=$(sed -n "${num}p" /tmp/dns_iface_$$)
rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$

# Ввод домена
echo ""
read -r -p "Домен [$DOMAIN]: " input_domain
DOMAIN="${input_domain:-$DOMAIN}"

read -r -p "DNS пересылки [$FORWARDER]: " input_fwd
FORWARDER="${input_fwd:-$FORWARDER}"

# Ввод записей DNS
echo ""
echo -e "${CYAN}Введите DNS записи (имя IP):${NC}"
echo -e "${YELLOW}Пример: hq-rtr 192.168.10.1${NC}"
echo -e "${YELLOW}Пустая строка - завершить ввод${NC}"
echo ""

DNS_ENTRIES=""
while true; do
    read -r -p "Запись: " entry
    [ -z "$entry" ] && break
    DNS_ENTRIES="$DNS_ENTRIES$entry\n"
done

# Показ параметров
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  IP сервера:    ${YELLOW}$SERVER_IP${NC}"
echo -e "  Интерфейс:     ${YELLOW}$INTERFACE${NC}"
echo -e "  Домен:         ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:     ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${YELLOW}Записи:${NC}"
echo -e "$DNS_ENTRIES"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"

echo ""
read -r -p "Применить? (y/n): " confirm
case "$confirm" in
    [Yy]*) ;;
    *) msg_in "Отменено"; exit 0 ;;
esac

# Установка пакета
echo ""
msg_in "Установка DNS сервера..."

case "$PKG_MANAGER" in
    apt-get)
        apt-get update
        apt-get install -y $PKG_NAME
        ;;
    dnf)
        dnf install -y $PKG_NAME
        ;;
    yum)
        yum install -y $PKG_NAME
        ;;
esac

if [ $? -ne 0 ]; then
    msg_er "Ошибка установки"
    exit 1
fi
msg_ok "Пакет установлен: $PKG_NAME"

# Создание named.conf
msg_in "Создание конфигурации..."

cat > /etc/named.conf << EOF
// DNS Server for Demo2026
options {
    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    recursing-file  "/var/named/data/named.recursing";
    secroots-file   "/var/named/data/named.secroots";
    
    allow-query     { any; };
    recursion yes;
    dnssec-enable no;
    dnssec-validation no;
    
    // Пересылка запросов
    forwarders { $FORWARDER; };
};

// Зона прямого просмотра
zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.zone";
    allow-update { none; };
};

// Зона обратного просмотра
zone "in-addr.arpa" IN {
    type master;
    file "reverse.zone";
    allow-update { none; };
};
EOF

msg_ok "named.conf создан"

# Создание зоны прямого просмотра
msg_in "Создание зоны прямого просмотра..."

# Получаем IP сети для SOA
o1=$(echo "$SERVER_IP" | cut -d'.' -f1)
o2=$(echo "$SERVER_IP" | cut -d'.' -f2)
o3=$(echo "$SERVER_IP" | cut -d'.' -f3)

cat > /var/named/$DOMAIN.zone << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        2026010101  ; Serial
        3600        ; Refresh
        1800        ; Retry
        604800      ; Expire
        86400       ; Minimum TTL
)

@       IN  NS      ns1.$DOMAIN.
ns1     IN  A       $SERVER_IP

EOF

# Добавляем записи из ввода
echo "$DNS_ENTRIES" | while read -r entry; do
    [ -z "$entry" ] && continue
    
    name=$(echo "$entry" | awk '{print $1}')
    addr=$(echo "$entry" | awk '{print $2}')
    
    if [ -n "$name" ] && [ -n "$addr" ]; then
        echo "$name    IN  A       $addr" >> /var/named/$DOMAIN.zone
    fi
done

msg_ok "Зона $DOMAIN создана"

# Создание зоны обратного просмотра
msg_in "Создание зоны обратного просмотра..."

cat > /var/named/reverse.zone << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        2026010101  ; Serial
        3600        ; Refresh
        1800        ; Retry
        604800      ; Expire
        86400       ; Minimum TTL
)

@       IN  NS      ns1.$DOMAIN.

EOF

# Добавляем PTR записи
echo "$DNS_ENTRIES" | while read -r entry; do
    [ -z "$entry" ] && continue
    
    name=$(echo "$entry" | awk '{print $1}')
    addr=$(echo "$entry" | awk '{print $2}')
    
    if [ -n "$name" ] && [ -n "$addr" ]; then
        last_octet=$(echo "$addr" | cut -d'.' -f4)
        echo "$last_octet     IN  PTR     $name.$DOMAIN." >> /var/named/reverse.zone
    fi
done

msg_ok "Зона обратного просмотра создана"

# Права на файлы
chown named:named /var/named/$DOMAIN.zone 2>/dev/null
chown named:named /var/named/reverse.zone 2>/dev/null
chown root:named /etc/named.conf 2>/dev/null

# Firewall
msg_in "Настройка firewall..."
if command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null
    nft add rule inet filter input tcp dport 53 accept 2>/dev/null
    nft add rule inet filter input udp dport 53 accept 2>/dev/null
    msg_ok "Firewall (nftables)"
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    msg_ok "Firewall (iptables)"
fi

# Проверка конфигурации
msg_in "Проверка конфигурации..."
if named-checkconf; then
    msg_ok "Конфигурация валидна"
else
    msg_er "Ошибка в конфигурации"
    exit 1
fi

if named-checkzone $DOMAIN /var/named/$DOMAIN.zone; then
    msg_ok "Зона $DOMAIN валидна"
else
    msg_er "Ошибка в зоне"
    exit 1
fi

# Запуск
msg_in "Запуск DNS сервера..."
systemctl stop $SERVICE_NAME 2>/dev/null
systemctl enable --now $SERVICE_NAME

sleep 2

if systemctl is-active --quiet $SERVICE_NAME; then
    msg_ok "DNS сервер запущен!"
else
    msg_er "Ошибка запуска"
    systemctl status $SERVICE_NAME --no-pager
    journalctl -u $SERVICE_NAME -n 20 --no-pager
    exit 1
fi

# Итог
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DNS сервер настроен и запущен!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  IP сервера:    ${YELLOW}$SERVER_IP${NC}"
echo -e "  Домен:         ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:     ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$SERVER_IP hq-rtr.$DOMAIN${NC}"
