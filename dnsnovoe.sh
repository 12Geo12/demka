#!/bin/bash
################################################################################
# Скрипт настройки DNS сервера (BIND9) для ALT Server
# Сервер: HQ-SRV (DNS сервер)
# Проект: Demo2026 - au-team.irpo
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
echo -e "${BLUE}║      Настройка DNS сервера на HQ-SRV                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Ввод параметров
read -p "Доменное имя [au-team.irpo]: " DOMAIN
DOMAIN=${DOMAIN:-au-team.irpo}

read -p "IP этого сервера [192.168.10.2]: " SERVER_IP
SERVER_IP=${SERVER_IP:-192.168.10.2}

read -p "IP HQ-RTR [192.168.10.1]: " ROUTER_IP
ROUTER_IP=${ROUTER_IP:-192.168.10.1}

read -p "IP HQ-CLI [192.168.20.2]: " CLI_IP
CLI_IP=${CLI_IP:-192.168.20.2}

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
echo "  Forwarder 1:     $FORWARDER1"
echo "  Forwarder 2:     $FORWARDER2"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

read -p "Продолжить? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    error "Отменено"
fi

# Установка
info "Установка BIND9..."
apt-get update
apt-get install -y bind9 bind9utils dnsutils

# Резервное копирование
info "Создание резервных копий..."
[[ -f /etc/bind/named.conf.options ]] && cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak
[[ -f /etc/bind/named.conf.local ]] && cp /etc/bind/named.conf.local /etc/bind/named.conf.local.bak

# Настройка named.conf.options
info "Настройка named.conf.options..."
cat > /etc/bind/named.conf.options << EOF
options {
    directory "/var/cache/bind";
    
    // Прослушиваемые интерфейсы
    listen-on { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 { none; };
    
    // Разрешенные для запросов
    allow-query { any; };
    
    // Рекурсия
    recursion yes;
    allow-recursion { any; };
    
    // DNS Forwarders
    forwarders {
        $FORWARDER1;
        $FORWARDER2;
    };
    
    forward only;
    
    // DNSSEC
    dnssec-validation auto;
    
    // Логи
    querylog yes;
    
    // Производительность
    max-cache-size 256m;
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
EOF

success "Создан /etc/bind/named.conf.options"

# Прямая зона
info "Создание прямой зоны..."
cat > /etc/bind/db.$DOMAIN << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01  ; Serial
        3600               ; Refresh
        1800               ; Retry
        604800             ; Expire
        86400              ; Minimum TTL
)

; Name Servers
@       IN  NS      hq-srv.$DOMAIN.

; A Records - Servers and Routers
hq-rtr      IN  A       $ROUTER_IP
hq-srv      IN  A       $SERVER_IP
hq-cli      IN  A       $CLI_IP
br-rtr      IN  A       192.168.30.1
br-srv      IN  A       192.168.30.2

; ISP Interfaces
docker      IN  A       172.16.4.1
web         IN  A       172.16.5.1

; CNAME Records
moodle      IN  CNAME   hq-rtr.$DOMAIN.
wiki        IN  CNAME   hq-rtr.$DOMAIN.
ftp         IN  CNAME   hq-srv.$DOMAIN.
mail        IN  CNAME   hq-srv.$DOMAIN.

; MX Record
@           IN  MX  10  hq-srv.$DOMAIN.

; TXT Record
@           IN  TXT     "v=spf1 mx -all"
EOF

success "Создана прямая зона: /etc/bind/db.$DOMAIN"

# Обратная зона 192.168.10.0/26
info "Создание обратных зон..."
cat > /etc/bind/db.192.168.10 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

1       IN  PTR     hq-rtr.$DOMAIN.
2       IN  PTR     hq-srv.$DOMAIN.
EOF

# Обратная зона 192.168.20.0/28
cat > /etc/bind/db.192.168.20 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

2       IN  PTR     hq-cli.$DOMAIN.
EOF

# Обратная зона ISP 172.16.4.0
cat > /etc/bind/db.172.16.4 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

1       IN  PTR     docker.$DOMAIN.
EOF

# Обратная зона ISP 172.16.5.0
cat > /etc/bind/db.172.16.5 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

1       IN  PTR     web.$DOMAIN.
EOF

success "Созданы обратные зоны"

# named.conf.local
info "Настройка named.conf.local..."
cat > /etc/bind/named.conf.local << EOF
// Local configuration for BIND9
// Server: HQ-SRV

include "/etc/bind/zones.rfc1918";

// Forward Zone
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-transfer { none; };
};

// Reverse Zones
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.10";
    allow-transfer { none; };
};

zone "20.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.20";
    allow-transfer { none; };
};

zone "4.16.172.in-addr.arpa" {
    type master;
    file "/etc/bind/db.172.16.4";
    allow-transfer { none; };
};

zone "5.16.172.in-addr.arpa" {
    type master;
    file "/etc/bind/db.172.16.5";
    allow-transfer { none; };
};
EOF

success "Настроен /etc/bind/named.conf.local"

# Директория для логов
mkdir -p /var/log/bind
chown bind:bind /var/log/bind

# Проверка
info "Проверка конфигурации..."
if named-checkconf &>/dev/null; then
    success "Конфигурация BIND проверена"
else
    error "Ошибка в конфигурации BIND"
fi

named-checkzone "$DOMAIN" /etc/bind/db.$DOMAIN &>/dev/null && success "Прямая зона OK"
named-checkzone "10.168.192.in-addr.arpa" /etc/bind/db.192.168.10 &>/dev/null && success "Обратная зона 10 OK"
named-checkzone "20.168.192.in-addr.arpa" /etc/bind/db.192.168.20 &>/dev/null && success "Обратная зона 20 OK"

# Запуск
info "Запуск BIND9..."
systemctl restart bind9
systemctl enable bind9

sleep 2
if systemctl is-active --quiet bind9; then
    success "BIND9 запущен и работает"
else
    error "BIND9 не запустился"
fi

# Тестирование
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}           ТЕСТИРОВАНИЕ DNS${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

sleep 1
if dig @$SERVER_IP hq-rtr.$DOMAIN +short &>/dev/null; then
    IP=$(dig @$SERVER_IP hq-rtr.$DOMAIN +short)
    success "✓ Прямое разрешение: hq-rtr.$DOMAIN → $IP"
else
    warn "✗ Прямое разрешение"
fi

if dig -x $ROUTER_IP @$SERVER_IP +short &>/dev/null; then
    PTR=$(dig -x $ROUTER_IP @$SERVER_IP +short)
    success "✓ Обратное разрешение: $ROUTER_IP → $PTR"
else
    warn "✗ Обратное разрешение"
fi

if dig @$SERVER_IP ya.ru +short &>/dev/null; then
    success "✓ Внешние DNS (forwarders) работают"
else
    warn "✗ Внешние DNS"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           DNS НАСТРОЕН УСПЕШНО!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Полезные команды:"
echo "  - Статус:      systemctl status bind9"
echo "  - Тест:        dig @$SERVER_IP hq-srv.$DOMAIN"
echo "  - Лог:         tail -f /var/log/bind/bind.log"
echo ""
info "Лог: $LOG_FILE"
