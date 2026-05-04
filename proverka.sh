#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux (DEBUG VERSION)
# С диагностикой ошибок и автоматическим исправлением
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

msg_ok() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
msg_er() { printf "${RED}[✗]${NC} %s\n" "$1"; }
msg_in() { printf "${BLUE}[i]${NC} %s\n" "$1"; }
msg_wrn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }

die() { msg_er "$1"; exit 1; }

# Проверка root
[ "$(id -u)" -ne 0 ] && die "Запустите от root (su -)"

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup - DIAGNOSTIC VERSION${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Параметры
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

# Ввод IP адресов
echo -e "${CYAN}Введите IP адреса устройств:${NC}"
echo ""

read -r -p "HQ-RTR IP [192.168.10.1]: " HQ_RTR_IP
[ -z "$HQ_RTR_IP" ] && HQ_RTR_IP="192.168.10.1"

read -r -p "BR-RTR IP [192.168.20.1]: " BR_RTR_IP
[ -z "$BR_RTR_IP" ] && BR_RTR_IP="192.168.20.1"

read -r -p "HQ-SRV IP (DNS сервер) [192.168.10.2]: " HQ_SRV_IP
[ -z "$HQ_SRV_IP" ] && HQ_SRV_IP="192.168.10.2"

read -r -p "BR-SRV IP [192.168.20.2]: " BR_SRV_IP
[ -z "$BR_SRV_IP" ] && BR_SRV_IP="192.168.20.2"

read -r -p "Docker IP [172.16.10.1]: " DOCKER_IP
[ -z "$DOCKER_IP" ] && DOCKER_IP="172.16.10.1"

read -r -p "Web IP [172.16.20.1]: " WEB_IP
[ -z "$WEB_IP" ] && WEB_IP="172.16.20.1"

DNS_SERVER_IP="$HQ_SRV_IP"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  DNS IP: $DNS_SERVER_IP"
echo -e "  Домен: $DOMAIN"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

#===========================================
# ДИАГНОСТИКА И ИСПРАВЛЕНИЕ
#===========================================

# 1. Проверка и создание пользователя named
echo ""
msg_in "Проверка пользователя named..."
if id "named" >/dev/null 2>&1; then
    msg_ok "Пользователь named существует"
    NAMED_USER="named"
elif id "bind" >/dev/null 2>&1; then
    msg_ok "Пользователь bind существует"
    NAMED_USER="bind"
else
    msg_wrn "Пользователь named/bind не найден, создаём..."
    useradd -r -s /sbin/nologin named 2>/dev/null || useradd -r -s /sbin/nologin bind 2>/dev/null
    NAMED_USER="named"
    msg_ok "Пользователь создан"
fi

# 2. Установка пакета
msg_in "Установка bind..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y bind bind-utils 2>/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y bind bind-utils 2>/dev/null
fi

# Проверка установки
if ! command -v named >/dev/null 2>&1 && [ ! -x /usr/sbin/named ]; then
    die "Пакет bind не установлен! Установите вручную: apt-get install bind"
fi
msg_ok "Bind установлен"

# 3. Создание директорий
msg_in "Создание директорий..."

# Определяем рабочую директорию
NAMED_DIR="/var/named"
if [ ! -d "$NAMED_DIR" ]; then
    mkdir -p "$NAMED_DIR"
fi
mkdir -p "$NAMED_DIR/data"
mkdir -p "$NAMED_DIR/slaves" 2>/dev/null

# Установка прав
chown -R $NAMED_USER:$NAMED_USER "$NAMED_DIR" 2>/dev/null || chown -R root:$NAMED_USER "$NAMED_DIR"
chmod 750 "$NAMED_DIR"
chmod 770 "$NAMED_DIR/data" 2>/dev/null

msg_ok "Директории созданы: $NAMED_DIR"

# 4. Определение обратной зоны
REV_ZONE=$(echo "$HQ_RTR_IP" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
msg_in "Обратная зона: $REV_ZONE"

# 5. Создание named.conf
msg_in "Создание named.conf..."

cat > /etc/named.conf << NAMED_CONF
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
chmod 640 /etc/named.conf

msg_ok "named.conf создан"

# 6. Создание зоны прямого просмотра
msg_in "Создание зоны $DOMAIN..."

SERIAL=$(date +%Y%m%d01)

cat > "$NAMED_DIR/$DOMAIN.zone" << ZONE_EOF
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
ZONE_EOF

chown $NAMED_USER:$NAMED_USER "$NAMED_DIR/$DOMAIN.zone" 2>/dev/null || chown root:$NAMED_USER "$NAMED_DIR/$DOMAIN.zone"
chmod 640 "$NAMED_DIR/$DOMAIN.zone"

msg_ok "Зона создана"

# 7. Создание зоны обратного просмотра
msg_in "Создание обратной зоны..."

HQ_RTR_LAST=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
HQ_SRV_LAST=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)

cat > "$NAMED_DIR/$DOMAIN.rev" << REV_EOF
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
REV_EOF

chown $NAMED_USER:$NAMED_USER "$NAMED_DIR/$DOMAIN.rev" 2>/dev/null || chown root:$NAMED_USER "$NAMED_DIR/$DOMAIN.rev"
chmod 640 "$NAMED_DIR/$DOMAIN.rev"

msg_ok "Обратная зона создана"

#===========================================
# ПРОВЕРКА КОНФИГУРАЦИИ
#===========================================
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}ПРОВЕРКА КОНФИГУРАЦИИ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# Проверка named.conf
msg_in "Проверка named.conf..."
if named-checkconf 2>&1; then
    msg_ok "named.conf валиден"
else
    msg_er "ОШИБКА в named.conf!"
    echo ""
    named-checkconf
    echo ""
    die "Исправьте ошибки в /etc/named.conf"
fi

# Проверка зоны
msg_in "Проверка зоны $DOMAIN..."
if named-checkzone "$DOMAIN" "$NAMED_DIR/$DOMAIN.zone" 2>&1; then
    msg_ok "Зона $DOMAIN валидна"
else
    msg_er "ОШИБКА в зоне!"
    die "Проверьте файл $NAMED_DIR/$DOMAIN.zone"
fi

# Проверка обратной зоны
msg_in "Проверка обратной зоны..."
named-checkzone "$REV_ZONE" "$NAMED_DIR/$DOMAIN.rev" 2>&1 && msg_ok "Обратная зона валидна"

#===========================================
# FIREWALL
#===========================================
echo ""
msg_in "Настройка firewall..."

if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    msg_ok "iptables настроен"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    msg_ok "firewalld настроен"
fi

#===========================================
# ЗАПУСК СЛУЖБЫ
#===========================================
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}ЗАПУСК DNS СЕРВЕРА${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# Определяем имя сервиса
SERVICE_NAME=""
for svc in bind named bind9; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        SERVICE_NAME="$svc"
        break
    fi
done

[ -z "$SERVICE_NAME" ] && SERVICE_NAME="bind"

msg_in "Имя сервиса: $SERVICE_NAME"

# Останавливаем
systemctl stop "$SERVICE_NAME" 2>/dev/null
systemctl stop named 2>/dev/null

# Перезагружаем systemd
systemctl daemon-reload

# Пробуем запустить
msg_in "Запуск через systemctl..."
systemctl start "$SERVICE_NAME" 2>&1
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    msg_ok "DNS сервер запущен через systemctl!"
    systemctl enable "$SERVICE_NAME" 2>/dev/null
else
    msg_wrn "systemctl не сработал, пробуем напрямую..."
    
    # Диагностика
    echo ""
    msg_in "ДИАГНОСТИКА:"
    echo ""
    
    # Проверяем логи
    echo "--- journalctl ---"
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null
    
    echo ""
    echo "--- Проверка файлов ---"
    ls -la /etc/named.conf
    ls -la "$NAMED_DIR/"
    
    echo ""
    echo "--- Прямой запуск ---"
    
    # Ищем бинарник
    NAMED_BIN=""
    for path in /usr/sbin/named /usr/local/sbin/named; do
        if [ -x "$path" ]; then
            NAMED_BIN="$path"
            break
        fi
    done
    
    if [ -n "$NAMED_BIN" ]; then
        # Пробуем с отладкой
        echo "Запуск: $NAMED_BIN -u $NAMED_USER -g"
        $NAMED_BIN -u $NAMED_USER -g &
        sleep 3
        
        if pgrep -x named >/dev/null; then
            msg_ok "named запущен в отладочном режиме!"
        else
            msg_er "named не запустился даже в отладочном режиме"
            echo ""
            echo "Возможные причины:"
            echo "1. Ошибка в конфигурации - проверьте named-checkconf"
            echo "2. Порт 53 занят другой программой"
            echo "3. Недостаточно прав"
            echo ""
            echo "Проверьте:"
            echo "  netstat -tulpn | grep :53"
            echo "  named -u $NAMED_USER -g"
        fi
    fi
fi

#===========================================
# RESOLV.CONF
#===========================================
echo ""
msg_in "Настройка resolv.conf..."

[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null

# Добавляем наш DNS
if ! grep -q "nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null; then
    sed -i "1i\nameserver $DNS_SERVER_IP" /etc/resolv.conf 2>/dev/null || {
        printf "nameserver %s\n" "$DNS_SERVER_IP" > /etc/resolv.conf
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
echo -e "${GREEN}║        ГОТОВО! Проверьте статус DNS сервера                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Команды для проверки:${NC}"
echo -e "  ${YELLOW}systemctl status $SERVICE_NAME${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr.$DOMAIN${NC}"
echo -e "  ${YELLOW}nslookup $HQ_RTR_IP${NC}"
echo -e "  ${YELLOW}dig @$DNS_SERVER_IP hq-srv.$DOMAIN${NC}"
echo ""
echo -e "${CYAN}Если не работает:${NC}"
echo -e "  ${YELLOW}named-checkconf${NC}"
echo -e "  ${YELLOW}journalctl -u $SERVICE_NAME -n 50${NC}"
echo -e "  ${YELLOW}named -u $NAMED_USER -g${NC}  (запуск с отладкой)"
echo ""
