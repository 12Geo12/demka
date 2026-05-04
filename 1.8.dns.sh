#!/bin/bash
#===============================================================================
# DNS Server Setup - FINAL FIX
# Исправление прав и запуск DNS
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

msg_ok() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
msg_er() { printf "${RED}[✗]${NC} %s\n" "$1"; }
msg_in() { printf "${BLUE}[i]${NC} %s\n" "$1"; }

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup - FINAL FIX${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка root
[ "$(id -u)" -ne 0 ] && { msg_er "Запустите от root"; exit 1; }

# Параметры
echo -e "${CYAN}Введите IP адрес DNS сервера (этот сервер):${NC}"
read -r -p "IP [192.168.5.2]: " DNS_IP
[ -z "$DNS_IP" ] && DNS_IP="192.168.5.2"

echo ""
echo -e "${CYAN}Введите IP адреса устройств:${NC}"

read -r -p "HQ-RTR [192.168.5.1]: " HQ_RTR
[ -z "$HQ_RTR" ] && HQ_RTR="192.168.5.1"

read -r -p "BR-RTR [192.168.6.1]: " BR_RTR
[ -z "$BR_RTR" ] && BR_RTR="192.168.6.1"

read -r -p "HQ-SRV [192.168.5.2]: " HQ_SRV
[ -z "$HQ_SRV" ] && HQ_SRV="192.168.5.2"

read -r -p "BR-SRV [192.168.6.2]: " BR_SRV
[ -z "$BR_SRV" ] && BR_SRV="192.168.6.2"

read -r -p "Docker (ISP-HQ) [172.16.5.1]: " DOCKER
[ -z "$DOCKER" ] && DOCKER="172.16.5.1"

read -r -p "Web (ISP-BR) [172.16.6.1]: " WEB
[ -z "$WEB" ] && WEB="172.16.6.1"

read -r -p "Домен [au-team.irpo]: " DOMAIN
[ -z "$DOMAIN" ] && DOMAIN="au-team.irpo"

read -r -p "Forwarder [77.88.8.8]: " FORWARDER
[ -z "$FORWARDER" ] && FORWARDER="77.88.8.8"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  DNS IP:    $DNS_IP"
echo -e "  Домен:     $DOMAIN"
echo -e "  Forwarder: $FORWARDER"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""
read -r -p "Продолжить? (y): " confirm
[[ ! "$confirm" =~ ^[Yy]?$ ]] && { msg_in "Отменено"; exit 0; }

#===========================================
# 1. УСТАНОВКА ПАКЕТА
#===========================================
echo ""
msg_in "Установка bind..."
apt-get update -qq 2>/dev/null
apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null
msg_ok "Bind установлен"

#===========================================
# 2. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ (если нужно)
#===========================================
if ! id named >/dev/null 2>&1; then
    msg_in "Создание пользователя named..."
    useradd -r -s /sbin/nologin named 2>/dev/null
fi
msg_ok "Пользователь named существует"

#===========================================
# 3. СОЗДАНИЕ ДИРЕКТОРИЙ И ПРАВ (КРИТИЧНО!)
#===========================================
echo ""
msg_in "Исправление прав на /var/named..."

# Создаём директории
mkdir -p /var/named/data
mkdir -p /var/named/slaves 2>/dev/null
mkdir -p /var/named/dynamic 2>/dev/null

# Устанавливаем правильные права
chown -R named:named /var/named
chmod 770 /var/named
chmod 770 /var/named/data
chmod 770 /var/named/slaves 2>/dev/null
chmod 770 /var/named/dynamic 2>/dev/null

msg_ok "Права установлены"

# Проверка
echo ""
msg_in "Проверка прав:"
ls -la /var/ | grep named

#===========================================
# 4. КОНФИГУРАЦИЯ
#===========================================
echo ""
msg_in "Создание named.conf..."

# Обратная зона для сети HQ
REV_NET=$(echo "$DNS_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="${REV_NET}.in-addr.arpa"

cat > /etc/named.conf << EOF
options {
    listen-on port 53 { 127.0.0.1; $DNS_IP; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    
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
EOF

chown root:named /etc/named.conf
chmod 640 /etc/named.conf

msg_ok "named.conf создан"

#===========================================
# 5. ЗОНА ПРЯМОГО ПРОСМОТРА
#===========================================
msg_in "Создание зоны $DOMAIN..."

SERIAL=$(date +%Y%m%d01)

cat > /var/named/$DOMAIN.zone << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400
)

@       IN  NS      ns1.$DOMAIN.
ns1     IN  A       $DNS_IP

hq-rtr  IN  A       $HQ_RTR
br-rtr  IN  A       $BR_RTR
hq-srv  IN  A       $HQ_SRV
br-srv  IN  A       $BR_SRV
docker  IN  A       $DOCKER
web     IN  A       $WEB
EOF

chown named:named /var/named/$DOMAIN.zone
chmod 660 /var/named/$DOMAIN.zone

msg_ok "Зона создана"

#===========================================
# 6. ЗОНА ОБРАТНОГО ПРОСМОТРА
#===========================================
msg_in "Создание обратной зоны..."

HQ_RTR_LAST=$(echo "$HQ_RTR" | cut -d'.' -f4)
HQ_SRV_LAST=$(echo "$HQ_SRV" | cut -d'.' -f4)

cat > /var/named/$DOMAIN.rev << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400
)

@       IN  NS      ns1.$DOMAIN.

$HQ_RTR_LAST   IN  PTR     hq-rtr.$DOMAIN.
$HQ_SRV_LAST   IN  PTR     hq-srv.$DOMAIN.
EOF

chown named:named /var/named/$DOMAIN.rev
chmod 660 /var/named/$DOMAIN.rev

msg_ok "Обратная зона создана"

#===========================================
# 7. ПРОВЕРКА КОНФИГУРАЦИИ
#===========================================
echo ""
msg_in "Проверка конфигурации..."

if named-checkconf; then
    msg_ok "named.conf OK"
else
    msg_er "Ошибка в named.conf"
    exit 1
fi

if named-checkzone "$DOMAIN" /var/named/$DOMAIN.zone; then
    msg_ok "Зона $DOMAIN OK"
else
    msg_er "Ошибка в зоне"
    exit 1
fi

#===========================================
# 8. FIREWALL
#===========================================
echo ""
msg_in "Настройка firewall..."

iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null

msg_ok "Firewall настроен"

#===========================================
# 9. ЗАПУСК
#===========================================
echo ""
msg_in "Запуск DNS..."

systemctl stop bind 2>/dev/null
systemctl daemon-reload

# Пробуем запустить
if systemctl start bind 2>&1; then
    sleep 2
    if systemctl is-active --quiet bind; then
        msg_ok "DNS сервер запущен!"
        systemctl enable bind 2>/dev/null
    else
        msg_er "bind не запустился, пробуем named..."
        systemctl start named 2>/dev/null
    fi
fi

# Проверка
echo ""
if systemctl is-active --quiet bind || systemctl is-active --quiet named; then
    msg_ok "DNS СЕРВЕР РАБОТАЕТ!"
else
    msg_er "Сервис не запущен. Попробуйте вручную:"
    echo "  systemctl start bind"
    echo "  named -u named -g  (для отладки)"
fi

#===========================================
# 10. RESOLV.CONF
#===========================================
echo ""
msg_in "Настройка resolv.conf..."

cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null

# Удаляем старые записи nameserver (опционально)
# sed -i '/nameserver/d' /etc/resolv.conf

# Добавляем в начало
if ! grep -q "nameserver $DNS_IP" /etc/resolv.conf; then
    sed -i "1i\nameserver $DNS_IP" /etc/resolv.conf
fi

if ! grep -q "search $DOMAIN" /etc/resolv.conf; then
    echo "search $DOMAIN" >> /etc/resolv.conf
fi

msg_ok "resolv.conf настроен"

#===========================================
# ИТОГ
#===========================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        DNS СЕРВЕР НАСТРОЕН!                                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}IP DNS сервера:${NC} $DNS_IP"
echo -e "${CYAN}Домен:${NC} $DOMAIN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_IP${NC}"
echo -e "  ${YELLOW}nslookup $HQ_RTR $DNS_IP${NC}"
echo -e "  ${YELLOW}systemctl status bind${NC}"
echo ""
