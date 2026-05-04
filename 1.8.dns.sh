#!/bin/bash
#===============================================================================
# DNS Server Setup - AUTO DETECT IP
# Автоматическое определение IP адресов из текущего сервера
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

msg_ok() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
msg_er() { printf "${RED}[✗]${NC} %s\n" "$1"; }
msg_in() { printf "${BLUE}[i]${NC} %s\n" "$1"; }
msg_wrn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
msg_auto() { printf "${MAGENTA}[⚡]${NC} %s\n" "$1"; }

die() { msg_er "$1"; exit 1; }

# Проверка root
[ "$(id -u)" -ne 0 ] && die "Запустите от root (su -)"

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup - AUTO DETECT${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

# Параметры по умолчанию
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

#===========================================
# АВТООПРЕДЕЛЕНИЕ IP АДРЕСОВ
#===========================================
echo ""
msg_in "Автоопределение IP адресов сервера..."
echo ""

# Получаем все IP адреса сервера
declare -a ALL_IPS
declare -a ALL_IFACES

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    iface_clean=$(echo "$iface" | cut -d'@' -f1)
    
    ALL_IPS+=("$ip")
    ALL_IFACES+=("$iface_clean")
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface_clean: ${YELLOW}$ip${NC}"
    
    idx=$((idx + 1))
done < <(ip -br addr show 2>/dev/null | grep -v "^lo")

TOTAL_IPS=$idx

if [ $TOTAL_IPS -eq 0 ]; then
    die "IP адреса не найдены"
fi

echo ""

# Определяем DNS сервер IP
# HQ-SRV обычно имеет IP из внутренней сети офиса
DNS_SERVER_IP=""

# Автовыбор: берём первый IP из приватной сети
for ip in "${ALL_IPS[@]}"; do
    case "$ip" in
        192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            DNS_SERVER_IP="$ip"
            break
            ;;
    esac
done

# Если не нашли приватный, берём первый
if [ -z "$DNS_SERVER_IP" ] && [ $TOTAL_IPS -gt 0 ]; then
    DNS_SERVER_IP="${ALL_IPS[0]}"
fi

msg_auto "Определён IP этого сервера: ${YELLOW}$DNS_SERVER_IP${NC}"

#===========================================
# ОПРЕДЕЛЕНИЕ СЕТИ И ДРУГИХ УСТРОЙСТВ
#===========================================
echo ""
msg_in "Определение параметров сети..."

# Определяем сеть сервера
SERVER_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $1"."$2"."$3}')
SERVER_NET_FULL=$(echo "$DNS_SERVER_IP" | awk -F. '{print $1"."$2}')

# Автоматически определяем вероятные IP других устройств на основе сети
# Считаем что маршрутизатор - .1 в той же сети
HQ_RTR_IP="${SERVER_NET}.1"

# Определяем имя сервера по IP
case "$DNS_SERVER_IP" in
    *.6.2|*.6.*)
        SERVER_NAME="hq-srv"
        # HQ сеть = .6.x
        HQ_NET_PREFIX=$(echo "$DNS_SERVER_IP" | awk -F. '{print $1"."$2}')
        HQ_RTR_IP="${HQ_NET_PREFIX}.5.1"
        BR_RTR_IP="${HQ_NET_PREFIX}.5.2"
        HQ_SRV_IP="$DNS_SERVER_IP"
        BR_SRV_IP="${HQ_NET_PREFIX}.6.2"
        ;;
    *.5.*|*.4.*)
        SERVER_NAME="hq-rtr или br-rtr"
        HQ_RTR_IP="${SERVER_NET}.1"
        ;;
    *)
        SERVER_NAME="hq-srv"
        HQ_RTR_IP="${SERVER_NET}.1"
        HQ_SRV_IP="$DNS_SERVER_IP"
        ;;
esac

msg_auto "Этот сервер определён как: ${YELLOW}$SERVER_NAME${NC}"

#===========================================
# ВВОСД ДАННЫХ ДРУГИХ УСТРОЙСТВ
#===========================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Введите IP адреса других устройств:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

read -r -p "HQ-RTR IP [$HQ_RTR_IP]: " input
[ -n "$input" ] && HQ_RTR_IP="$input"

read -r -p "BR-RTR IP [192.168.5.2]: " input
[ -n "$input" ] && BR_RTR_IP="$input"
[ -z "${BR_RTR_IP}" ] && BR_RTR_IP="192.168.5.2"

read -r -p "HQ-SRV IP [$DNS_SERVER_IP]: " input
[ -n "$input" ] && HQ_SRV_IP="$input"
[ -z "${HQ_SRV_IP}" ] && HQ_SRV_IP="$DNS_SERVER_IP"

read -r -p "BR-SRV IP [192.168.6.2]: " input
[ -n "$input" ] && BR_SRV_IP="$input"
[ -z "${BR_SRV_IP}" ] && BR_SRV_IP="192.168.6.2"

read -r -p "Docker/ISP-HQ IP [172.16.4.1]: " input
[ -n "$input" ] && DOCKER_IP="$input"
[ -z "${DOCKER_IP}" ] && DOCKER_IP="172.16.4.1"

read -r -p "Web/ISP-BR IP [172.16.5.1]: " input
[ -n "$input" ] && WEB_IP="$input"
[ -z "${WEB_IP}" ] && WEB_IP="172.16.5.1"

echo ""
read -r -p "Домен [$DOMAIN]: " input
[ -n "$input" ] && DOMAIN="$input"

read -r -p "Forwarder [$FORWARDER]: " input
[ -n "$input" ] && FORWARDER="$input"

# DNS сервер IP
DNS_SERVER_IP="$HQ_SRV_IP"

#===========================================
# ИТОГОВАЯ ТАБЛИЦА
#===========================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS сервера:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  IP DNS сервера:  ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:           ${YELLOW}$DOMAIN${NC}"
echo -e "  Forwarder:       ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${YELLOW}DNS записи:${NC}"
printf "  %-18s → %-15s %s\n" "hq-rtr.$DOMAIN" "$HQ_RTR_IP" "(A,PTR)"
printf "  %-18s → %-15s %s\n" "br-rtr.$DOMAIN" "$BR_RTR_IP" "(A)"
printf "  %-18s → %-15s %s\n" "hq-srv.$DOMAIN" "$HQ_SRV_IP" "(A,PTR)"
printf "  %-18s → %-15s %s\n" "br-srv.$DOMAIN" "$BR_SRV_IP" "(A)"
printf "  %-18s → %-15s %s\n" "docker.$DOMAIN" "$DOCKER_IP" "(A)"
printf "  %-18s → %-15s %s\n" "web.$DOMAIN" "$WEB_IP" "(A)"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

echo ""
read -r -p "Применить? (y): " confirm
[[ ! "$confirm" =~ ^[Yy]?$ ]] && { msg_in "Отменено"; exit 0; }

#===========================================
# 1. УСТАНОВКА BIND
#===========================================
echo ""
msg_in "Установка bind..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null
fi

msg_ok "Bind установлен"

#===========================================
# 2. ПОЛЬЗОВАТЕЛЬ NAMED
#===========================================
if ! id named >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin named 2>/dev/null
fi

# Проверяем группу
if ! getent group named >/dev/null 2>&1; then
    groupadd -r named 2>/dev/null
fi

msg_ok "Пользователь named готов"

#===========================================
# 3. ДИРЕКТОРИИ И ПРАВА (КРИТИЧНО!)
#===========================================
echo ""
msg_in "Создание директорий и установка прав..."

mkdir -p /var/named/data
mkdir -p /var/named/slaves 2>/dev/null

# КРИТИЧНО: правильные права!
chown -R named:named /var/named
chmod 770 /var/named
chmod 770 /var/named/data
chmod 770 /var/named/slaves 2>/dev/null

# Дополнительные проверки
if [ -d /var/named ]; then
    msg_ok "Права на /var/named установлены"
    ls -ld /var/named
else
    die "Не удалось создать /var/named"
fi

#===========================================
# 4. ОБРАТНАЯ ЗОНА
#===========================================
# Определяем сеть для обратной зоны по IP DNS сервера
REV_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="${REV_NET}.in-addr.arpa"

msg_in "Обратная зона: $REV_ZONE"

#===========================================
# 5. NAMED.CONF
#===========================================
msg_in "Создание named.conf..."

cat > /etc/named.conf << EOF
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
# 6. ЗОНА ПРЯМОГО ПРОСМОТРА
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
ns1     IN  A       $DNS_SERVER_IP

hq-rtr  IN  A       $HQ_RTR_IP
br-rtr  IN  A       $BR_RTR_IP
hq-srv  IN  A       $HQ_SRV_IP
br-srv  IN  A       $BR_SRV_IP
docker  IN  A       $DOCKER_IP
web     IN  A       $WEB_IP
EOF

chown named:named /var/named/$DOMAIN.zone
chmod 660 /var/named/$DOMAIN.zone

msg_ok "Зона создана"

#===========================================
# 7. ЗОНА ОБРАТНОГО ПРОСМОТРА
#===========================================
msg_in "Создание обратной зоны..."

HQ_RTR_LAST=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
HQ_SRV_LAST=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)

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
# 8. ПРОВЕРКА
#===========================================
echo ""
msg_in "Проверка конфигурации..."

if named-checkconf 2>&1; then
    msg_ok "named.conf OK"
else
    msg_er "Ошибка в named.conf!"
    named-checkconf
    die "Исправьте ошибки"
fi

if named-checkzone "$DOMAIN" /var/named/$DOMAIN.zone 2>&1; then
    msg_ok "Зона $DOMAIN OK"
else
    die "Ошибка в зоне"
fi

named-checkzone "$REV_ZONE" /var/named/$DOMAIN.rev 2>&1 && msg_ok "Обратная зона OK"

#===========================================
# 9. FIREWALL
#===========================================
echo ""
msg_in "Настройка firewall..."

iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null

msg_ok "Firewall настроен"

#===========================================
# 10. ЗАПУСК
#===========================================
echo ""
msg_in "Запуск DNS сервера..."

# Останавливаем
systemctl stop bind 2>/dev/null
systemctl stop named 2>/dev/null

# Перечитываем
systemctl daemon-reload

# Определяем имя сервиса
SERVICE_NAME=""
for svc in bind named; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        SERVICE_NAME="$svc"
        break
    fi
done

[ -z "$SERVICE_NAME" ] && SERVICE_NAME="bind"

msg_in "Сервис: $SERVICE_NAME"

# Запускаем
systemctl start "$SERVICE_NAME" 2>&1
sleep 2

# Проверяем
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    msg_ok "DNS сервер запущен!"
    systemctl enable "$SERVICE_NAME" 2>/dev/null
else
    msg_wrn "systemctl не сработал, пробуем напрямую..."
    
    # Находим бинарник
    if [ -x /usr/sbin/named ]; then
        /usr/sbin/named -u named &
        sleep 2
        
        if pgrep -x named >/dev/null; then
            msg_ok "named запущен напрямую!"
        else
            msg_er "named не запустился"
            echo ""
            msg_in "Запустите вручную для диагностики:"
            echo "  /usr/sbin/named -u named -g"
            exit 1
        fi
    fi
fi

#===========================================
# 11. RESOLV.CONF
#===========================================
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

#===========================================
# ИТОГ
#===========================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        DNS СЕРВЕР УСПЕШНО НАСТРОЕН!                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}IP DNS:${NC} $DNS_SERVER_IP"
echo -e "${CYAN}Домен:${NC} $DOMAIN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup $HQ_RTR_IP $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
