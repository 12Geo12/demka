#!/bin/bash
#===============================================================================
# DNS Server Setup - POSIX COMPATIBLE
# Без process substitution - работает везде
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

DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

#===========================================
# АВТООПРЕДЕЛЕНИЕ IP АДРЕСОВ (POSIX совместимо)
#===========================================
echo ""
msg_in "Автоопределение IP адресов сервера..."
echo ""

TMPFILE="/tmp/dns_ips_$$"
ip -br addr show 2>/dev/null | grep -v "^lo" > "$TMPFILE"

if [ ! -s "$TMPFILE" ]; then
    rm -f "$TMPFILE"
    die "IP адреса не найдены"
fi

# Показываем найденные IP
idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    iface_clean=$(echo "$iface" | cut -d'@' -f1)
    
    idx=$((idx + 1))
    echo -e "  ${GREEN}[$idx]${NC} $iface_clean: ${YELLOW}$ip${NC}"
    
    # Сохраняем в переменные
    eval "IP_$idx=$ip"
    
done < "$TMPFILE"

TOTAL_IPS=$idx
rm -f "$TMPFILE"

if [ $TOTAL_IPS -eq 0 ]; then
    die "IP адреса не найдены"
fi

echo ""

# Автовыбор первого IP
eval "DNS_SERVER_IP=\$IP_1"

# Если IP несколько, предлагаем выбор
if [ $TOTAL_IPS -gt 1 ]; then
    msg_in "Найдено несколько IP. Выберите IP DNS сервера:"
    read -r -p "Номер [1]: " num
    [ -z "$num" ] && num=1
    
    if [ "$num" -ge 1 ] && [ "$num" -le $TOTAL_IPS ]; then
        eval "DNS_SERVER_IP=\$IP_$num"
    fi
fi

msg_auto "Выбран IP: ${YELLOW}$DNS_SERVER_IP${NC}"

#===========================================
# ВВОД IP ДРУГИХ УСТРОЙСТВ
#===========================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Введите IP адреса устройств:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# Определяем сеть сервера
SERVER_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $1"."$2"."$3}')
DEFAULT_HQ_RTR="${SERVER_NET}.1"

read -r -p "HQ-RTR IP [$DEFAULT_HQ_RTR]: " HQ_RTR_IP
[ -z "$HQ_RTR_IP" ] && HQ_RTR_IP="$DEFAULT_HQ_RTR"

read -r -p "BR-RTR IP: " BR_RTR_IP
[ -z "$BR_RTR_IP" ] && msg_wrn "BR-RTR IP не указан, записи не будет"

read -r -p "HQ-SRV IP (DNS) [$DNS_SERVER_IP]: " HQ_SRV_IP
[ -z "$HQ_SRV_IP" ] && HQ_SRV_IP="$DNS_SERVER_IP"

read -r -p "BR-SRV IP: " BR_SRV_IP
[ -z "$BR_SRV_IP" ] && msg_wrn "BR-SRV IP не указан"

read -r -p "Docker/ISP-HQ IP: " DOCKER_IP
[ -z "$DOCKER_IP" ] && msg_wrn "Docker IP не указан"

read -r -p "Web/ISP-BR IP: " WEB_IP
[ -z "$WEB_IP" ] && msg_wrn "Web IP не указан"

# DNS сервер = HQ-SRV
DNS_SERVER_IP="$HQ_SRV_IP"

echo ""
read -r -p "Домен [$DOMAIN]: " input
[ -n "$input" ] && DOMAIN="$input"

read -r -p "Forwarder [$FORWARDER]: " input
[ -n "$input" ] && FORWARDER="$input"

#===========================================
# ИТОГ
#===========================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры:${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  DNS сервер:  ${YELLOW}$DNS_SERVER_IP${NC}"
echo -e "  Домен:       ${YELLOW}$DOMAIN${NC}"
echo -e "  Forwarder:   ${YELLOW}$FORWARDER${NC}"
echo ""
echo -e "${YELLOW}Записи:${NC}"
[ -n "$HQ_RTR_IP" ] && echo -e "  hq-rtr  → $HQ_RTR_IP (A,PTR)"
[ -n "$BR_RTR_IP" ] && echo -e "  br-rtr  → $BR_RTR_IP (A)"
[ -n "$HQ_SRV_IP" ] && echo -e "  hq-srv  → $HQ_SRV_IP (A,PTR)"
[ -n "$BR_SRV_IP" ] && echo -e "  br-srv  → $BR_SRV_IP (A)"
[ -n "$DOCKER_IP" ] && echo -e "  docker  → $DOCKER_IP (A)"
[ -n "$WEB_IP" ] && echo -e "  web     → $WEB_IP (A)"
echo ""

read -r -p "Применить? (y): " confirm
[[ ! "$confirm" =~ ^[Yy]?$ ]] && { msg_in "Отменено"; exit 0; }

#===========================================
# УСТАНОВКА
#===========================================
echo ""
msg_in "Установка bind..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null
fi

msg_ok "Bind установлен"

#===========================================
# ПОЛЬЗОВАТЕЛЬ NAMED
#===========================================
if ! id named >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin named 2>/dev/null
fi

if ! getent group named >/dev/null 2>&1; then
    groupadd -r named 2>/dev/null
fi

msg_ok "Пользователь named готов"

#===========================================
# ДИРЕКТОРИИ И ПРАВА
#===========================================
echo ""
msg_in "Создание директорий..."

mkdir -p /var/named/data
mkdir -p /var/named/slaves 2>/dev/null

# ПРАВА - КРИТИЧНО!
chown -R named:named /var/named
chmod 770 /var/named
chmod 770 /var/named/data
chmod 770 /var/named/slaves 2>/dev/null

msg_ok "Директории созданы"
ls -ld /var/named

#===========================================
# ОБРАТНАЯ ЗОНА
#===========================================
REV_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="${REV_NET}.in-addr.arpa"

msg_in "Обратная зона: $REV_ZONE"

#===========================================
# NAMED.CONF
#===========================================
msg_in "Создание named.conf..."

cat > /etc/named.conf << EOF
options {
    listen-on port 53 { 127.0.0.1; $DNS_SERVER_IP; };
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
# ЗОНА ПРЯМОГО ПРОСМОТРА
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
EOF

# Добавляем записи
[ -n "$HQ_RTR_IP" ] && echo "hq-rtr  IN  A       $HQ_RTR_IP" >> /var/named/$DOMAIN.zone
[ -n "$BR_RTR_IP" ] && echo "br-rtr  IN  A       $BR_RTR_IP" >> /var/named/$DOMAIN.zone
[ -n "$HQ_SRV_IP" ] && echo "hq-srv  IN  A       $HQ_SRV_IP" >> /var/named/$DOMAIN.zone
[ -n "$BR_SRV_IP" ] && echo "br-srv  IN  A       $BR_SRV_IP" >> /var/named/$DOMAIN.zone
[ -n "$DOCKER_IP" ] && echo "docker  IN  A       $DOCKER_IP" >> /var/named/$DOMAIN.zone
[ -n "$WEB_IP" ] && echo "web     IN  A       $WEB_IP" >> /var/named/$DOMAIN.zone

chown named:named /var/named/$DOMAIN.zone
chmod 660 /var/named/$DOMAIN.zone

msg_ok "Зона создана"

#===========================================
# ЗОНА ОБРАТНОГО ПРОСМОТРА
#===========================================
msg_in "Создание обратной зоны..."

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
EOF

# PTR записи для HQ_RTR и HQ_SRV (в той же сети что DNS сервер)
if [ -n "$HQ_RTR_IP" ]; then
    HQ_RTR_LAST=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
    # Проверяем что IP в той же сети
    HQ_RTR_NET=$(echo "$HQ_RTR_IP" | awk -F. '{print $3"."$2"."$1}')
    if [ "$HQ_RTR_NET" = "$REV_NET" ]; then
        echo "$HQ_RTR_LAST   IN  PTR     hq-rtr.$DOMAIN." >> /var/named/$DOMAIN.rev
    fi
fi

if [ -n "$HQ_SRV_IP" ]; then
    HQ_SRV_LAST=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)
    HQ_SRV_NET=$(echo "$HQ_SRV_IP" | awk -F. '{print $3"."$2"."$1}')
    if [ "$HQ_SRV_NET" = "$REV_NET" ]; then
        echo "$HQ_SRV_LAST   IN  PTR     hq-srv.$DOMAIN." >> /var/named/$DOMAIN.rev
    fi
fi

chown named:named /var/named/$DOMAIN.rev
chmod 660 /var/named/$DOMAIN.rev

msg_ok "Обратная зона создана"

#===========================================
# ПРОВЕРКА
#===========================================
echo ""
msg_in "Проверка конфигурации..."

if named-checkconf 2>&1; then
    msg_ok "named.conf OK"
else
    msg_er "Ошибка в named.conf:"
    named-checkconf
    die "Исправьте ошибку"
fi

named-checkzone "$DOMAIN" /var/named/$DOMAIN.zone 2>&1 && msg_ok "Зона $DOMAIN OK"
named-checkzone "$REV_ZONE" /var/named/$DOMAIN.rev 2>&1 && msg_ok "Обратная зона OK"

#===========================================
# FIREWALL
#===========================================
echo ""
msg_in "Настройка firewall..."

iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null

msg_ok "Firewall настроен"

#===========================================
# ЗАПУСК
#===========================================
echo ""
msg_in "Запуск DNS..."

systemctl stop bind 2>/dev/null
systemctl stop named 2>/dev/null
systemctl daemon-reload

# Определяем сервис
SERVICE_NAME="bind"
if systemctl list-unit-files named.service >/dev/null 2>&1; then
    SERVICE_NAME="named"
fi

msg_in "Сервис: $SERVICE_NAME"

systemctl start "$SERVICE_NAME" 2>&1
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    msg_ok "DNS сервер запущен!"
    systemctl enable "$SERVICE_NAME" 2>/dev/null
else
    msg_wrn "systemctl не сработал, пробуем напрямую..."
    
    if [ -x /usr/sbin/named ]; then
        /usr/sbin/named -u named &
        sleep 2
        
        if pgrep -x named >/dev/null; then
            msg_ok "named запущен!"
        else
            msg_er "named не запустился. Запустите вручную:"
            echo "  /usr/sbin/named -u named -g"
        fi
    fi
fi

#===========================================
# RESOLV.CONF
#===========================================
echo ""
msg_in "Настройка resolv.conf..."

cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null

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
echo -e "${GREEN}║        DNS СЕРВЕР НАСТРОЕН!                                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}IP:${NC} $DNS_SERVER_IP"
echo -e "${CYAN}Домен:${NC} $DOMAIN"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}systemctl status $SERVICE_NAME${NC}"
echo ""
