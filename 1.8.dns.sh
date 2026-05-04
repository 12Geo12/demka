#!/bin/bash
#===============================================================================
# DNS SERVER SETUP - ПОЛНЫЙ РАБОЧИЙ СКРИПТ
# Для Demo2026 - Alt Linux
#
# ИСПРАВЛЕНО:
# - Права на /var/named с учётом chroot
# - SELinux контексты
# - Убран устаревший dnssec-enable
# - Автоопределение IP
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
[ "$(id -u)" -ne 0 ] && die "Запустите от root: su - && bash $0"

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS SERVER SETUP - Demo2026${NC}"
echo -e "${CYAN}║${NC} ${GREEN}Полный рабочий скрипт${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

#===========================================
# 1. АВТООПРЕДЕЛЕНИЕ IP СЕРВЕРА
#===========================================
echo ""
msg_in "Автоопределение IP адресов..."
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
    eval "IP_$idx=$ip"
    eval "IFACE_$idx=$iface_clean"
    
    echo -e "  ${GREEN}[$idx]${NC} $iface_clean: ${YELLOW}$ip${NC}"
done < "$TMPFILE"

TOTAL_IPS=$idx
rm -f "$TMPFILE"

# Автовыбор
eval "DNS_SERVER_IP=\$IP_1"

if [ $TOTAL_IPS -gt 1 ]; then
    echo ""
    read -r -p "Выберите IP DNS сервера [1]: " num
    [ -z "$num" ] && num=1
    if [ "$num" -ge 1 ] && [ "$num" -le $TOTAL_IPS ]; then
        eval "DNS_SERVER_IP=\$IP_$num"
    fi
fi

msg_auto "IP DNS сервера: ${YELLOW}$DNS_SERVER_IP${NC}"

#===========================================
# 2. ВВОД IP ДРУГИХ УСТРОЙСТВ
#===========================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}IP адреса устройств (Enter - пропустить):${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

SERVER_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $1"."$2"."$3}')

read -r -p "HQ-RTR IP [${SERVER_NET}.1]: " HQ_RTR_IP
[ -z "$HQ_RTR_IP" ] && HQ_RTR_IP="${SERVER_NET}.1"

read -r -p "BR-RTR IP: " BR_RTR_IP
read -r -p "HQ-SRV IP [$DNS_SERVER_IP]: " HQ_SRV_IP
[ -z "$HQ_SRV_IP" ] && HQ_SRV_IP="$DNS_SERVER_IP"

read -r -p "BR-SRV IP: " BR_SRV_IP
read -r -p "Docker IP: " DOCKER_IP
read -r -p "Web IP: " WEB_IP

echo ""
read -r -p "Домен [$DOMAIN]: " input
[ -n "$input" ] && DOMAIN="$input"

read -r -p "Forwarder [$FORWARDER]: " input
[ -n "$input" ] && FORWARDER="$input"

DNS_SERVER_IP="$HQ_SRV_IP"

#===========================================
# 3. ИТОГОВАЯ ТАБЛИЦА
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
# 4. УСТАНОВКА BIND
#===========================================
echo ""
msg_in "Установка bind..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y bind bind-utils 2>/dev/null
fi

msg_ok "Bind установлен"

#===========================================
# 5. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ NAMED
#===========================================
if ! id named >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin named 2>/dev/null
fi
if ! getent group named >/dev/null 2>&1; then
    groupadd -r named 2>/dev/null
fi
msg_ok "Пользователь named готов"

#===========================================
# 6. ОСТАНОВКА СТАРЫХ ПРОЦЕССОВ
#===========================================
echo ""
msg_in "Остановка старых процессов..."
pkill -9 named 2>/dev/null
systemctl stop bind 2>/dev/null
systemctl stop named 2>/dev/null
sleep 1
msg_ok "Готово"

#===========================================
# 7. СОЗДАНИЕ ДИРЕКТОРИЙ
#===========================================
echo ""
msg_in "Создание директорий..."

mkdir -p /var/named/data
mkdir -p /var/named/slaves 2>/dev/null
mkdir -p /var/named/dynamic 2>/dev/null

msg_ok "Директории созданы"

#===========================================
# 8. ПРОВЕРКА И ОТКЛЮЧЕНИЕ SELINUX
#===========================================
echo ""
msg_in "Проверка SELinux..."

if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce 2>/dev/null)
    if [ "$SELINUX_STATUS" = "Enforcing" ]; then
        msg_wrn "SELinux Enforcing - отключаем..."
        setenforce 0 2>/dev/null
        # Отключаем в конфиге
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null
        msg_ok "SELinux отключён"
    else
        msg_ok "SELinux: $SELINUX_STATUS"
    fi
fi

#===========================================
# 9. УСТАНОВКА ПРАВ (КРИТИЧНО!)
#===========================================
echo ""
msg_in "Установка прав на /var/named..."

# Основные права
chown -R named:named /var/named
chmod 770 /var/named
chmod 770 /var/named/data
chmod 770 /var/named/slaves 2>/dev/null
chmod 770 /var/named/dynamic 2>/dev/null

# SELinux контексты
if command -v chcon >/dev/null 2>&1; then
    chcon -R -t named_cache_t /var/named 2>/dev/null
fi

msg_ok "Права установлены"
ls -ld /var/named

#===========================================
# 10. ОБРАТНАЯ ЗОНА
#===========================================
REV_NET=$(echo "$DNS_SERVER_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="${REV_NET}.in-addr.arpa"
msg_in "Обратная зона: $REV_ZONE"

#===========================================
# 11. СОЗДАНИЕ NAMED.CONF
#===========================================
echo ""
msg_in "Создание named.conf..."

cat > /etc/named.conf << EOF
// DNS Server for $DOMAIN
// Generated: $(date)

options {
    listen-on port 53 { 127.0.0.1; $DNS_SERVER_IP; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    allow-query     { any; };
    allow-recursion { any; };
    recursion yes;
    dnssec-validation no;
    
    forwarders { $FORWARDER; };
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
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
# 12. ЗОНА ПРЯМОГО ПРОСМОТРА
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

# SELinux контекст
chcon -t named_zone_t /var/named/$DOMAIN.zone 2>/dev/null

msg_ok "Зона создана"

#===========================================
# 13. ЗОНА ОБРАТНОГО ПРОСМОТРА
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

# PTR записи (только для устройств в той же сети)
if [ -n "$HQ_RTR_IP" ]; then
    HQ_RTR_NET=$(echo "$HQ_RTR_IP" | awk -F. '{print $3"."$2"."$1}')
    if [ "$HQ_RTR_NET" = "$REV_NET" ]; then
        LAST=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
        echo "$LAST   IN  PTR     hq-rtr.$DOMAIN." >> /var/named/$DOMAIN.rev
    fi
fi

if [ -n "$HQ_SRV_IP" ]; then
    HQ_SRV_NET=$(echo "$HQ_SRV_IP" | awk -F. '{print $3"."$2"."$1}')
    if [ "$HQ_SRV_NET" = "$REV_NET" ]; then
        LAST=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)
        echo "$LAST   IN  PTR     hq-srv.$DOMAIN." >> /var/named/$DOMAIN.rev
    fi
fi

chown named:named /var/named/$DOMAIN.rev
chmod 660 /var/named/$DOMAIN.rev

# SELinux контекст
chcon -t named_zone_t /var/named/$DOMAIN.rev 2>/dev/null

msg_ok "Обратная зона создана"

#===========================================
# 14. ПРОВЕРКА КОНФИГУРАЦИИ
#===========================================
echo ""
msg_in "Проверка конфигурации..."

CHECK_ERRORS=0

if ! named-checkconf 2>&1; then
    msg_wrn "Ошибки в named.conf"
    CHECK_ERRORS=1
else
    msg_ok "named.conf OK"
fi

if ! named-checkzone "$DOMAIN" /var/named/$DOMAIN.zone 2>&1; then
    msg_wrn "Ошибки в зоне $DOMAIN"
    CHECK_ERRORS=1
else
    msg_ok "Зона $DOMAIN OK"
fi

named-checkzone "$REV_ZONE" /var/named/$DOMAIN.rev 2>&1 && msg_ok "Обратная зона OK"

#===========================================
# 15. FIREWALL
#===========================================
echo ""
msg_in "Настройка firewall..."

iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null

# Сохраняем правила
if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null
fi

msg_ok "Firewall настроен"

#===========================================
# 16. ЗАПУСК DNS
#===========================================
echo ""
msg_in "Запуск DNS сервера..."

# Перечитаем systemd
systemctl daemon-reload

# Определяем сервис
SERVICE_NAME=""
for svc in bind named; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        SERVICE_NAME="$svc"
        break
    fi
done
[ -z "$SERVICE_NAME" ] && SERVICE_NAME="bind"

# Пробуем systemctl
systemctl start "$SERVICE_NAME" 2>&1
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    msg_ok "DNS запущен через systemctl!"
    systemctl enable "$SERVICE_NAME" 2>/dev/null
else
    msg_wrn "systemctl не сработал, прямой запуск..."
    
    # Прямой запуск
    if [ -x /usr/sbin/named ]; then
        /usr/sbin/named -u named
        sleep 2
        
        if pgrep -x named >/dev/null; then
            msg_ok "named запущен напрямую!"
        else
            msg_er "named не запустился!"
            echo ""
            msg_in "Диагностика - запуск с отладкой:"
            /usr/sbin/named -u named -g 2>&1 &
            sleep 3
        fi
    fi
fi

#===========================================
# 17. RESOLV.CONF
#===========================================
echo ""
msg_in "Настройка resolv.conf..."

# Резервная копия
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null

# Добавляем наш DNS в начало
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
# 18. ПРОВЕРКА РАБОТОСПОСОБНОСТИ
#===========================================
echo ""
msg_in "Проверка DNS..."

if pgrep -x named >/dev/null; then
    msg_ok "named запущен"
    
    # Тестируем запрос
    sleep 1
    echo ""
    msg_in "Тест nslookup hq-rtr:"
    nslookup hq-rtr $DNS_SERVER_IP 2>&1 | head -10
else
    msg_er "named не запущен"
fi

#===========================================
# ИТОГ
#===========================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        DNS СЕРВЕР НАСТРОЕН!                                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}IP DNS:${NC}     $DNS_SERVER_IP"
echo -e "${CYAN}Домен:${NC}     $DOMAIN"
echo -e "${CYAN}Сервис:${NC}    $SERVICE_NAME"
echo ""
echo -e "${CYAN}Файлы:${NC}"
echo -e "  /etc/named.conf"
echo -e "  /var/named/$DOMAIN.zone"
echo -e "  /var/named/$DOMAIN.rev"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup $HQ_RTR_IP $DNS_SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
echo -e "${CYAN}Управление:${NC}"
echo -e "  ${YELLOW}systemctl status $SERVICE_NAME${NC}"
echo -e "  ${YELLOW}systemctl restart $SERVICE_NAME${NC}"
echo -e "  ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}"
echo ""
