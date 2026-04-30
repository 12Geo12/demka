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

# Установка BIND (попытка разных имен пакетов для ALT Linux)
info "Установка BIND..."
apt-get update || error "Не удалось обновить списки пакетов"

# Пробуем разные имена пакетов для BIND
if apt-cache search ^bind9$ | grep -q bind9; then
    BIND_PACKAGE="bind9 bind9utils dnsutils"
    BIND_SERVICE="bind9"
elif apt-cache search ^named$ | grep -q named; then
    BIND_PACKAGE="named bind-utils"
    BIND_SERVICE="named"
elif apt-cache search ^bind$ | grep -q "^bind "; then
    BIND_PACKAGE="bind bind-utils"
    BIND_SERVICE="named"
else
    error "Не найдено подходящего пакета BIND. Установите вручную."
fi

info "Установка пакетов: $BIND_PACKAGE"
apt-get install -y $BIND_PACKAGE || error "Не удалось установить $BIND_PACKAGE"

# Определяем имя службы
if systemctl list-unit-files | grep -q named.service; then
    BIND_SERVICE="named"
elif systemctl list-unit-files | grep -q bind9.service; then
    BIND_SERVICE="bind9"
fi

info "Используемая служба: $BIND_SERVICE"

# Резервное копирование
info "Создание резервных копий..."
[[ -f /etc/bind/named.conf.options ]] && cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak
[[ -f /etc/bind/named.conf.local ]] && cp /etc/bind/named.conf.local /etc/bind/named.conf.local.bak
[[ -f /etc/named.conf ]] && cp /etc/named.conf /etc/named.conf.bak

# Настройка named.conf.options (или named.conf для ALT)
info "Настройка конфигурации..."

# Проверяем структуру каталогов
if [[ -d /etc/bind ]]; then
    CONF_DIR="/etc/bind"
    NAMED_CONF="$CONF_DIR/named.conf.options"
elif [[ -f /etc/named.conf ]]; then
    CONF_DIR="/etc"
    NAMED_CONF="/etc/named.conf"
else
    error "Не найдена директория конфигурации BIND"
fi

# Создаем options.conf
cat > $CONF_DIR/named.conf.options << EOF
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

success "Создан $CONF_DIR/named.conf.options"

# Прямая зона - динамическое создание записей
info "Создание прямой зоны..."

# Начинаем файл зоны
cat > $CONF_DIR/db.$DOMAIN << EOF
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

; A Records - Servers and Routers (только указанные IP)
EOF

# Добавляем записи только если IP указан
if [[ -n "$ROUTER_IP" ]]; then
    echo "hq-rtr      IN  A       $ROUTER_IP" >> $CONF_DIR/db.$DOMAIN
    success "Добавлена запись: hq-rtr → $ROUTER_IP"
fi

echo "hq-srv      IN  A       $SERVER_IP" >> $CONF_DIR/db.$DOMAIN

if [[ -n "$CLI_IP" ]]; then
    echo "hq-cli      IN  A       $CLI_IP" >> $CONF_DIR/db.$DOMAIN
    success "Добавлена запись: hq-cli → $CLI_IP"
fi

if [[ -n "$BR_RTR_IP" ]]; then
    echo "br-rtr      IN  A       $BR_RTR_IP" >> $CONF_DIR/db.$DOMAIN
    success "Добавлена запись: br-rtr → $BR_RTR_IP"
fi

if [[ -n "$BR_SRV_IP" ]]; then
    echo "br-srv      IN  A       $BR_SRV_IP" >> $CONF_DIR/db.$DOMAIN
    success "Добавлена запись: br-srv → $BR_SRV_IP"
fi

# Добавляем ISP записи
cat >> $CONF_DIR/db.$DOMAIN << EOF

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

success "Создана прямая зона: $CONF_DIR/db.$DOMAIN"

# Обратные зоны (только если IP указаны)
info "Создание обратных зон..."

# Обратная зона для HQ-RTR (192.168.10.0)
if [[ -n "$ROUTER_IP" ]]; then
    ROUTER_LAST_OCTET=$(echo $ROUTER_IP | cut -d. -f4)
    ROUTER_NET=$(echo $ROUTER_IP | cut -d. -f1-3 | tr '.' '.')
    cat > $CONF_DIR/db.192.168.10 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

$ROUTER_LAST_OCTET       IN  PTR     hq-rtr.$DOMAIN.
2       IN  PTR     hq-srv.$DOMAIN.
EOF
    success "Создана обратная зона 192.168.10"
fi

# Обратная зона для HQ-CLI (192.168.20.0)
if [[ -n "$CLI_IP" ]]; then
    CLI_LAST_OCTET=$(echo $CLI_IP | cut -d. -f4)
    cat > $CONF_DIR/db.192.168.20 << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $(date +%Y%m%d)01
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

$CLI_LAST_OCTET       IN  PTR     hq-cli.$DOMAIN.
EOF
    success "Создана обратная зона 192.168.20"
fi

# Обратная зона ISP 172.16.4.0
cat > $CONF_DIR/db.172.16.4 << EOF
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
cat > $CONF_DIR/db.172.16.5 << EOF
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

success "Созданы обратные зоны ISP"

# named.conf.local
info "Настройка named.conf.local..."

# Начинаем файл
cat > $CONF_DIR/named.conf.local << EOF
// Local configuration for BIND9
// Server: HQ-SRV

include "/etc/bind/zones.rfc1918";

// Forward Zone
zone "$DOMAIN" {
    type master;
    file "$CONF_DIR/db.$DOMAIN";
    allow-transfer { none; };
};

// Reverse Zones (только указанные)
EOF

# Добавляем обратные зоны только если IP указаны
if [[ -n "$ROUTER_IP" ]]; then
    cat >> $CONF_DIR/named.conf.local << EOF

zone "10.168.192.in-addr.arpa" {
    type master;
    file "$CONF_DIR/db.192.168.10";
    allow-transfer { none; };
};
EOF
fi

if [[ -n "$CLI_IP" ]]; then
    cat >> $CONF_DIR/named.conf.local << EOF

zone "20.168.192.in-addr.arpa" {
    type master;
    file "$CONF_DIR/db.192.168.20";
    allow-transfer { none; };
};
EOF
fi

# ISP обратные зоны
cat >> $CONF_DIR/named.conf.local << EOF

zone "4.16.172.in-addr.arpa" {
    type master;
    file "$CONF_DIR/db.172.16.4";
    allow-transfer { none; };
};

zone "5.16.172.in-addr.arpa" {
    type master;
    file "$CONF_DIR/db.172.16.5";
    allow-transfer { none; };
};
EOF

success "Настроен $CONF_DIR/named.conf.local"

# Директория для логов
mkdir -p /var/log/bind
chown bind:bind /var/log/bind 2>/dev/null || chown named:named /var/log/bind 2>/dev/null || true

# Проверка
info "Проверка конфигурации..."
if named-checkconf &>/dev/null; then
    success "Конфигурация BIND проверена"
else
    warn "Предупреждение в конфигурации (проверьте вручную)"
    named-checkconf 2>&1 | head -5 || true
fi

# Проверка зон
if named-checkzone "$DOMAIN" $CONF_DIR/db.$DOMAIN &>/dev/null; then
    success "Прямая зона OK"
else
    warn "Прямая зона: проверка"
fi

# Запуск службы
info "Запуск $BIND_SERVICE..."
systemctl restart $BIND_SERVICE || error "Не удалось запустить $BIND_SERVICE"
systemctl enable $BIND_SERVICE

sleep 2
if systemctl is-active --quiet $BIND_SERVICE; then
    success "$BIND_SERVICE запущен и работает"
else
    error "$BIND_SERVICE не запустился. Проверьте лог: journalctl -u $BIND_SERVICE"
fi

# Тестирование
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}           ТЕСТИРОВАНИЕ DNS${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

sleep 1
if dig @$SERVER_IP hq-srv.$DOMAIN +short &>/dev/null; then
    IP=$(dig @$SERVER_IP hq-srv.$DOMAIN +short)
    success "✓ Прямое разрешение: hq-srv.$DOMAIN → $IP"
else
    warn "✗ Прямое разрешение"
fi

if [[ -n "$ROUTER_IP" ]]; then
    if dig -x $ROUTER_IP @$SERVER_IP +short &>/dev/null; then
        PTR=$(dig -x $ROUTER_IP @$SERVER_IP +short)
        success "✓ Обратное разрешение: $ROUTER_IP → $PTR"
    else
        warn "✗ Обратное разрешение"
    fi
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
echo "  - Статус:      systemctl status $BIND_SERVICE"
echo "  - Тест:        dig @$SERVER_IP hq-srv.$DOMAIN"
echo "  - Лог:         tail -f /var/log/bind/bind.log"
echo ""
info "Лог: $LOG_FILE"
