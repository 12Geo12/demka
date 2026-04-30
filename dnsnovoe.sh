#!/bin/bash
################################################################################
# Скрипт настройки DNS сервера (BIND) для ALT Linux Server
# Версия: 4.0 - Используем /var/lib/bind вместо /var/cache/bind
################################################################################

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/dns-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
error() { log "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    error "Требуется root (используйте sudo)"
fi

clear
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Настройка DNS сервера на HQ-SRV (ALT Linux)          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Ввод параметров
read -p "Доменное имя [au-team.irpo]: " DOMAIN
DOMAIN=${DOMAIN:-au-team.irpo}

read -p "IP этого сервера [192.168.10.2]: " SERVER_IP
SERVER_IP=${SERVER_IP:-192.168.10.2}

read -p "IP HQ-RTR (оставьте пустым, если не нужно): " ROUTER_IP
ROUTER_IP=${ROUTER_IP:-}

read -p "IP HQ-CLI (оставьте пустым, если не нужно): " CLI_IP
CLI_IP=${CLI_IP:-}

read -p "IP BR-RTR (оставьте пустым, если не нужно): " BR_RTR_IP
BR_RTR_IP=${BR_RTR_IP:-}

read -p "IP BR-SRV (оставьте пустым, если не нужно): " BR_SRV_IP
BR_SRV_IP=${BR_SRV_IP:-}

echo ""
info "Настройка DNS-форвардеров (внешние DNS):"
read -p "Первичный форвардер [77.88.8.8]: " FORWARDER1
FORWARDER1=${FORWARDER1:-77.88.8.8}

read -p "Вторичный форвардер [77.88.8.3]: " FORWARDER2
FORWARDER2=${FORWARDER2:-77.88.8.3}

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "Параметры конфигурации:"
echo "  Домен:           $DOMAIN"
echo "  IP сервера:      $SERVER_IP"
[[ -n "$ROUTER_IP" ]] && echo "  HQ-RTR:          $ROUTER_IP"
[[ -n "$CLI_IP" ]] && echo "  HQ-CLI:          $CLI_IP"
[[ -n "$BR_RTR_IP" ]] && echo "  BR-RTR:          $BR_RTR_IP"
[[ -n "$BR_SRV_IP" ]] && echo "  BR-SRV:          $BR_SRV_IP"
echo "  Forwarder 1:     $FORWARDER1"
echo "  Forwarder 2:     $FORWARDER2"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

read -p "Продолжить? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    error "Отменено"
fi

# Установка BIND
info "Установка BIND..."
apt-get update
apt-get install -y bind bind-utils || apt-get install -y bind

if ! command -v named &>/dev/null; then
    error "named не найден"
fi
success "BIND установлен"

# ============================================================================
# ВАЖНО: Создаём директории ПЕРЕД конфигурацией
# Используем /var/lib/bind - стандартный путь для ALT Linux
# ============================================================================
info "Создание директорий..."

# Создаём все нужные директории
mkdir -p /etc/bind
mkdir -p /var/lib/bind
mkdir -p /var/lib/bind/zones
mkdir -p /var/log/bind
mkdir -p /var/run/named

# Устанавливаем права root (named запускается от root)
chown -R root:root /etc/bind
chown -R root:root /var/lib/bind
chown -R root:root /var/log/bind
chown -R root:root /var/run/named

chmod 755 /etc/bind
chmod 755 /var/lib/bind
chmod 755 /var/lib/bind/zones
chmod 755 /var/log/bind
chmod 755 /var/run/named

# Проверяем что директории доступны
ls -la /var/lib/bind
touch /var/lib/bind/test_write && rm /var/lib/bind/test_write
success "Директории созданы"

# Резервное копирование
[[ -f /etc/named.conf ]] && cp /etc/named.conf /etc/named.conf.bak

# ============================================================================
# Конфигурация named.conf - используем /var/lib/bind
# ============================================================================
info "Создание named.conf..."

cat > /etc/named.conf << EOF
// BIND Configuration for ALT Linux
// Generated: $(date)

options {
    // ИСПОЛЬЗУЕМ /var/lib/bind вместо /var/cache/bind
    directory "/var/lib/bind";
    pid-file "/var/run/named/named.pid";
    
    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 port 53 { none; };
    
    allow-query { any; };
    recursion yes;
    allow-recursion { any; };
    
    forwarders {
        $FORWARDER1;
        $FORWARDER2;
    };
    forward only;
    
    dnssec-validation no;
};

logging {
    channel default_log {
        file "/var/log/bind/bind.log" versions 3 size 5m;
        severity info;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default { default_log; };
};

include "/etc/bind/named.conf.local";
EOF

success "named.conf создан"

# ============================================================================
# Создание зон
# ============================================================================
info "Создание зон..."

# Прямая зона
cat > /var/lib/bind/zones/db.$DOMAIN << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

EOF

[[ -n "$ROUTER_IP" ]] && echo "hq-rtr      IN  A       $ROUTER_IP" >> /var/lib/bind/zones/db.$DOMAIN
echo "hq-srv      IN  A       $SERVER_IP" >> /var/lib/bind/zones/db.$DOMAIN
[[ -n "$CLI_IP" ]] && echo "hq-cli      IN  A       $CLI_IP" >> /var/lib/bind/zones/db.$DOMAIN
[[ -n "$BR_RTR_IP" ]] && echo "br-rtr      IN  A       $BR_RTR_IP" >> /var/lib/bind/zones/db.$DOMAIN
[[ -n "$BR_SRV_IP" ]] && echo "br-srv      IN  A       $BR_SRV_IP" >> /var/lib/bind/zones/db.$DOMAIN

cat >> /var/lib/bind/zones/db.$DOMAIN << EOF

docker      IN  A       172.16.4.1
web         IN  A       172.16.5.1
moodle      IN  CNAME   hq-rtr.$DOMAIN.
wiki        IN  CNAME   hq-rtr.$DOMAIN.
ftp         IN  CNAME   hq-srv.$DOMAIN.
mail        IN  CNAME   hq-srv.$DOMAIN.
@           IN  MX  10  hq-srv.$DOMAIN.
EOF

chmod 644 /var/lib/bind/zones/db.$DOMAIN
success "Прямая зона создана"

# Обратные зоны
if [[ -n "$ROUTER_IP" ]]; then
    ROUTER_LAST=$(echo $ROUTER_IP | cut -d. -f4)
    cat > /var/lib/bind/zones/db.192.168.10 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)
@       IN  NS      hq-srv.$DOMAIN.
$ROUTER_LAST       IN  PTR     hq-rtr.$DOMAIN.
2       IN  PTR     hq-srv.$DOMAIN.
EOF
    chmod 644 /var/lib/bind/zones/db.192.168.10
fi

if [[ -n "$CLI_IP" ]]; then
    CLI_LAST=$(echo $CLI_IP | cut -d. -f4)
    cat > /var/lib/bind/zones/db.192.168.20 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)
@       IN  NS      hq-srv.$DOMAIN.
$CLI_LAST       IN  PTR     hq-cli.$DOMAIN.
EOF
    chmod 644 /var/lib/bind/zones/db.192.168.20
fi

# ISP зоны
cat > /var/lib/bind/zones/db.172.16.4 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. ($(date +%Y%m%d)01 3600 1800 604800 86400)
@       IN  NS      hq-srv.$DOMAIN.
1       IN  PTR     docker.$DOMAIN.
EOF

cat > /var/lib/bind/zones/db.172.16.5 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. ($(date +%Y%m%d)01 3600 1800 604800 86400)
@       IN  NS      hq-srv.$DOMAIN.
1       IN  PTR     web.$DOMAIN.
EOF

chmod 644 /var/lib/bind/zones/db.*
success "Зоны созданы"

# ============================================================================
# named.conf.local
# ============================================================================
cat > /etc/bind/named.conf.local << EOF
zone "$DOMAIN" {
    type master;
    file "/var/lib/bind/zones/db.$DOMAIN";
    allow-transfer { none; };
};
EOF

[[ -n "$ROUTER_IP" ]] && cat >> /etc/bind/named.conf.local << EOF
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.192.168.10";
    allow-transfer { none; };
};
EOF

[[ -n "$CLI_IP" ]] && cat >> /etc/bind/named.conf.local << EOF
zone "20.168.192.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.192.168.20";
    allow-transfer { none; };
};
EOF

cat >> /etc/bind/named.conf.local << EOF
zone "4.16.172.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.172.16.4";
    allow-transfer { none; };
};
zone "5.16.172.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.172.16.5";
    allow-transfer { none; };
};
EOF

chmod 644 /etc/bind/named.conf.local
success "named.conf.local создан"

# ============================================================================
# Проверка конфигурации
# ============================================================================
info "Проверка конфигурации..."
named-checkconf
named-checkzone "$DOMAIN" /var/lib/bind/zones/db.$DOMAIN

# ============================================================================
# Запуск named
# ============================================================================
info "Остановка старых процессов..."
pkill named 2>/dev/null || true
sleep 2

info "Запуск named..."
touch /var/log/bind/bind.log
chmod 644 /var/log/bind/bind.log

# Переходим в рабочую директорию
cd /var/lib/bind

# Запускаем named
named -c /etc/named.conf &
sleep 3

if pgrep -x named &>/dev/null; then
    success "named запущен (PID: $(pgrep -x named))"
else
    error "named не запустился. Выполните: cd /var/lib/bind && named -c /etc/named.conf -g"
fi

# ============================================================================
# Тестирование
# ============================================================================
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}           ТЕСТИРОВАНИЕ DNS${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

dig @$SERVER_IP hq-srv.$DOMAIN +short && success "✓ Прямое разрешение работает" || warn "✗ Прямое разрешение"
[[ -n "$ROUTER_IP" ]] && dig -x $ROUTER_IP @$SERVER_IP +short && success "✓ Обратное разрешение работает"
dig @$SERVER_IP ya.ru +short && success "✓ Внешние DNS работают" || warn "✗ Внешние DNS"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           DNS НАСТРОЕН УСПЕШНО!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Команды:"
echo "  Статус:   ps aux | grep named"
echo "  Тест:     dig @$SERVER_IP hq-srv.$DOMAIN"
echo "  Лог:      tail -f /var/log/bind/bind.log"
echo "  Стоп:     pkill named"
echo "  Старт:    cd /var/lib/bind && named -c /etc/named.conf &"
