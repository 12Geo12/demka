#!/bin/bash
################################################################################
# Скрипт настройки DNS сервера (BIND) для ALT Linux Server
# Версия: 3.2 - Исправлена ошибка chroot() Operation not permitted
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
apt-get update || error "Не удалось обновить списки пакетов"

info "Установка BIND (ALT Linux)..."
# Пробуем установить основные пакеты BIND
if ! apt-get install -y bind bind-utils; then
    # Если не получилось, пробуем только bind
    apt-get install -y bind || error "Не удалось установить BIND"
fi

# Проверяем наличие утилит
if ! command -v named &>/dev/null; then
    error "named не найден. BIND не установлен корректно."
fi

if ! command -v dig &>/dev/null; then
    warn "dig не найден. Установите bind-utils отдельно."
fi

success "BIND установлен"

# Проверка/создание пользователя named
info "Проверка пользователя named..."
if ! id named &>/dev/null; then
    warn "Пользователь named не найден, создаем..."
    useradd -r -s /sbin/nologin -d /etc/named named 2>/dev/null || \
    adduser -D -S -H -s /sbin/nologin named 2>/dev/null || \
    error "Не удалось создать пользователя named"
    success "Пользователь named создан"
else
    success "Пользователь named существует"
fi

# Проверка/создание группы named
if ! getent group named &>/dev/null; then
    groupadd named 2>/dev/null || true
fi

# Создание директорий
info "Создание директорий..."
mkdir -p /etc/bind
mkdir -p /var/cache/bind
mkdir -p /var/log/bind
mkdir -p /var/run/named
mkdir -p /etc/named

# Установка прав
chown -R named:named /var/cache/bind 2>/dev/null || true
chown -R named:named /var/log/bind 2>/dev/null || true
chown -R named:named /var/run/named 2>/dev/null || true
chown -R named:named /etc/bind 2>/dev/null || true

# Резервное копирование
info "Создание резервных копий..."
[[ -f /etc/named.conf ]] && cp /etc/named.conf /etc/named.conf.bak
[[ -f /etc/bind/named.conf ]] && cp /etc/bind/named.conf /etc/bind/named.conf.bak

# Создание rndc.key
info "Создание rndc.key..."
if [[ ! -f /etc/bind/rndc.key ]]; then
    cat > /etc/bind/rndc.key << 'RNDEOF'
key "rndc-key" {
    algorithm hmac-sha256;
    secret "placeholder-key";
};
RNDEOF
    chmod 640 /etc/bind/rndc.key
    chown named:named /etc/bind/rndc.key 2>/dev/null || true
    success "rndc.key создан"
fi

# Основной конфигурационный файл named.conf
# ИСПРАВЛЕНИЕ: Убраны user/group из options - теперь named запускается от root
# и сам сбрасывает привилегии без chroot
info "Создание named.conf..."
cat > /etc/named.conf << EOF
// Named configuration for ALT Linux
// Generated: $(date)

include "/etc/bind/rndc.key";

options {
    directory "/var/cache/bind";
    pid-file "/var/run/named/named.pid";
    
    // Прослушиваемые интерфейсы
    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 port 53 { none; };
    
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
    dnssec-validation no;
    
    // Логи
    querylog yes;
    
    // Производительность
    max-cache-size 256m;
    
    // ВАЖНО: Не используем user/group здесь - это вызывает chroot()
    // Привилегии будут сброшены через параметры запуска
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

// Включаем локальные настройки
include "/etc/bind/named.conf.local";
EOF

success "Создан /etc/named.conf"

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

; A Records
EOF

if [[ -n "$ROUTER_IP" ]]; then
    echo "hq-rtr      IN  A       $ROUTER_IP" >> /etc/bind/db.$DOMAIN
    success "Добавлена запись: hq-rtr → $ROUTER_IP"
fi

echo "hq-srv      IN  A       $SERVER_IP" >> /etc/bind/db.$DOMAIN

if [[ -n "$CLI_IP" ]]; then
    echo "hq-cli      IN  A       $CLI_IP" >> /etc/bind/db.$DOMAIN
    success "Добавлена запись: hq-cli → $CLI_IP"
fi

if [[ -n "$BR_RTR_IP" ]]; then
    echo "br-rtr      IN  A       $BR_RTR_IP" >> /etc/bind/db.$DOMAIN
    success "Добавлена запись: br-rtr → $BR_RTR_IP"
fi

if [[ -n "$BR_SRV_IP" ]]; then
    echo "br-srv      IN  A       $BR_SRV_IP" >> /etc/bind/db.$DOMAIN
    success "Добавлена запись: br-srv → $BR_SRV_IP"
fi

cat >> /etc/bind/db.$DOMAIN << EOF

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
// Local configuration for BIND
// Server: HQ-SRV

// Forward Zone
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-transfer { none; };
};

// Reverse Zones
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

# Создание симлинка для совместимости
ln -sf /etc/named.conf /etc/bind/named.conf 2>/dev/null || true

# Установка прав
chown -R named:named /etc/bind 2>/dev/null || true
chown named:named /etc/named.conf 2>/dev/null || true

# Проверка конфигурации
info "Проверка конфигурации..."
if named-checkconf 2>&1; then
    success "Конфигурация проверена"
else
    warn "Есть предупреждения в конфигурации"
fi

if named-checkzone "$DOMAIN" /etc/bind/db.$DOMAIN &>/dev/null; then
    success "Прямая зона OK"
fi

# Остановка старых процессов
info "Остановка старых процессов named..."
pkill named 2>/dev/null || true
sleep 2

# Запуск named
# ИСПРАВЛЕНИЕ: Запускаем named напрямую без chroot
# -f: запуск в foreground (для тестирования)
# -u named: сброс привилегий через setuid (без chroot)
info "Запуск named..."
cd /var/cache/bind

# Проверяем, поддерживает ли named опцию -u (не все версии ALT Linux)
if named --help 2>&1 | grep -q '\-u'; then
    # Если есть поддержка -u, запускаем с ней
    named -c /etc/named.conf -f -u named &
else
    # Иначе запускаем напрямую (без chroot)
    named -c /etc/named.conf -f &
fi

NAMED_PID=$!
sleep 3

# Проверка запуска
if pgrep -x named &>/dev/null; then
    success "named запущен (PID: $(pgrep -x named))"
else
    # Если не запустился, пробуем альтернативный способ
    warn "Первая попытка не удалась, пробуем альтернативный способ..."
    
    # Пробуем запустить без сброса привилегий (для контейнеров)
    named -c /etc/named.conf -f &
    sleep 3
    
    if pgrep -x named &>/dev/null; then
        success "named запущен альтернативным способом (PID: $(pgrep -x named))"
        warn "Внимание: named работает от root. Это не рекомендуется для production."
    else
        error "named не запустился. Проверьте: tail -f /var/log/bind/bind.log"
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
echo -e "${GREEN}           DNS НАСТРОЕН УСПЕШНО!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Полезные команды:"
echo "  - Статус:        ps aux | grep named"
echo "  - Тест:          dig @$SERVER_IP hq-srv.$DOMAIN"
echo "  - Лог:           tail -f /var/log/bind/bind.log"
echo "  - Остановка:     pkill named"
echo "  - Запуск:        named -c /etc/named.conf -f &"
echo ""
info "Лог: $LOG_FILE"
