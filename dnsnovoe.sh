#!/bin/bash
################################################################################
# Скрипт настройки DNS сервера (BIND) для ALT Linux Server
# Версия: 3.4 - Исправлено: создание директорий и прав доступа
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

# Установка BIND для ALT Linux
info "Обновление списков пакетов..."
apt-get update || warn "Не удалось обновить списки пакетов"

info "Установка BIND (ALT Linux)..."
apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind || warn "Возможны проблемы с установкой"

# Проверяем наличие named
if ! command -v named &>/dev/null; then
    error "named не найден. BIND не установлен корректно."
fi

success "BIND установлен"

# ============================================================================
# КРИТИЧНО: Создание всех директорий с правильными правами
# ============================================================================
info "Создание директорий с правильными правами..."

# Основные директории BIND
mkdir -p /etc/bind
mkdir -p /var/cache/bind
mkdir -p /var/log/bind
mkdir -p /var/run/named

# Устанавливаем владельца root (так как named запускается от root)
chown -R root:root /etc/bind
chown -R root:root /var/cache/bind
chown -R root:root /var/log/bind
chown -R root:root /var/run/named

# Устанавливаем права
chmod 755 /etc/bind
chmod 755 /var/cache/bind
chmod 755 /var/log/bind
chmod 755 /var/run/named

# Проверяем что директории доступны
info "Проверка директорий..."
if [[ ! -d /var/cache/bind ]]; then
    error "Не удалось создать /var/cache/bind"
fi
if [[ ! -w /var/cache/bind ]]; then
    error "/var/cache/bind недоступен для записи"
fi
success "Директории созданы и доступны"

# Резервное копирование
info "Создание резервных копий..."
[[ -f /etc/named.conf ]] && cp /etc/named.conf /etc/named.conf.bak.$(date +%s)
[[ -f /etc/bind/named.conf ]] && cp /etc/bind/named.conf /etc/bind/named.conf.bak.$(date +%s)

# Создание rndc.key
info "Создание rndc.key..."
cat > /etc/bind/rndc.key << 'RNDEOF'
key "rndc-key" {
    algorithm hmac-sha256;
    secret "placeholder-key";
};
RNDEOF
chmod 644 /etc/bind/rndc.key

# Основной конфигурационный файл named.conf
info "Создание named.conf..."
cat > /etc/named.conf << EOF
// Named configuration for ALT Linux
// Generated: $(date)

options {
    directory "/var/cache/bind";
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

success "Создан /etc/named.conf"

# Прямая зона
info "Создание прямой зоны..."

cat > /etc/bind/db.$DOMAIN << EOF
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

if [[ -n "$ROUTER_IP" ]]; then
    echo "hq-rtr      IN  A       $ROUTER_IP" >> /etc/bind/db.$DOMAIN
fi

echo "hq-srv      IN  A       $SERVER_IP" >> /etc/bind/db.$DOMAIN

if [[ -n "$CLI_IP" ]]; then
    echo "hq-cli      IN  A       $CLI_IP" >> /etc/bind/db.$DOMAIN
fi

if [[ -n "$BR_RTR_IP" ]]; then
    echo "br-rtr      IN  A       $BR_RTR_IP" >> /etc/bind/db.$DOMAIN
fi

if [[ -n "$BR_SRV_IP" ]]; then
    echo "br-srv      IN  A       $BR_SRV_IP" >> /etc/bind/db.$DOMAIN
fi

cat >> /etc/bind/db.$DOMAIN << EOF

docker      IN  A       172.16.4.1
web         IN  A       172.16.5.1

moodle      IN  CNAME   hq-rtr.$DOMAIN.
wiki        IN  CNAME   hq-rtr.$DOMAIN.
ftp         IN  CNAME   hq-srv.$DOMAIN.
mail        IN  CNAME   hq-srv.$DOMAIN.

@           IN  MX  10  hq-srv.$DOMAIN.
EOF

success "Создана прямая зона: /etc/bind/db.$DOMAIN"

# Обратные зоны
info "Создание обратных зон..."

if [[ -n "$ROUTER_IP" ]]; then
    ROUTER_LAST_OCTET=$(echo $ROUTER_IP | cut -d. -f4)
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

$ROUTER_LAST_OCTET       IN  PTR     hq-rtr.$DOMAIN.
2       IN  PTR     hq-srv.$DOMAIN.
EOF
    success "Создана обратная зона 192.168.10"
fi

if [[ -n "$CLI_IP" ]]; then
    CLI_LAST_OCTET=$(echo $CLI_IP | cut -d. -f4)
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

$CLI_LAST_OCTET       IN  PTR     hq-cli.$DOMAIN.
EOF
    success "Создана обратная зона 192.168.20"
fi

# ISP обратные зоны
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

success "Созданы обратные зоны ISP"

# named.conf.local
info "Настройка named.conf.local..."

cat > /etc/bind/named.conf.local << EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-transfer { none; };
};
EOF

if [[ -n "$ROUTER_IP" ]]; then
    cat >> /etc/bind/named.conf.local << EOF

zone "10.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.10";
    allow-transfer { none; };
};
EOF
fi

if [[ -n "$CLI_IP" ]]; then
    cat >> /etc/bind/named.conf.local << EOF

zone "20.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.20";
    allow-transfer { none; };
};
EOF
fi

cat >> /etc/bind/named.conf.local << EOF

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

# Финальная установка прав
chmod -R 755 /etc/bind
chmod 644 /etc/named.conf
chmod 644 /etc/bind/db.* 2>/dev/null || true

# Проверка конфигурации
info "Проверка конфигурации..."
if named-checkconf 2>&1; then
    success "Конфигурация проверена"
else
    warn "Есть предупреждения в конфигурации"
fi

if named-checkzone "$DOMAIN" /etc/bind/db.$DOMAIN 2>&1; then
    success "Прямая зона OK"
fi

# Остановка старых процессов
info "Остановка старых процессов named..."
pkill named 2>/dev/null || true
sleep 2

# ============================================================================
# Запуск named с правильной рабочей директорией
# ============================================================================
info "Запуск named..."

# Переходим в рабочую директорию BIND ПЕРЕД запуском
cd /var/cache/bind

# Создаём пустой лог-файл заранее
touch /var/log/bind/bind.log
chmod 644 /var/log/bind/bind.log

# Запуск named (от root, без chroot)
named -c /etc/named.conf &
NAMED_PID=$!

sleep 3

# Проверка запуска
if pgrep -x named &>/dev/null; then
    success "named запущен (PID: $(pgrep -x named))"
else
    warn "named не запустился, пробуем отладку..."
    named -c /etc/named.conf -g 2>&1 &
    sleep 3
    
    if pgrep -x named &>/dev/null; then
        success "named запущен"
    else
        error "named не запустился. Проверьте конфигурацию вручную."
    fi
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
    success "✓ Внешние DNS работают"
else
    warn "✗ Внешние DNS"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           DNS НАСТРОЕН!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Полезные команды:"
echo "  - Статус:        ps aux | grep named"
echo "  - Тест:          dig @$SERVER_IP hq-srv.$DOMAIN"
echo "  - Лог:           tail -f /var/log/bind/bind.log"
echo "  - Остановка:     pkill named"
echo "  - Запуск:        cd /var/cache/bind && named -c /etc/named.conf &"
echo ""
info "Лог: $LOG_FILE"
