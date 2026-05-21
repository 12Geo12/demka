#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - ALT Linux Server (FIXED VERSION)
# Версия: 2.0 - Исправлена работа с chroot и правами доступа
# ============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_header() { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}============================================${NC}\n"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_error "Запустите скрипт от имени root!"
    exit 1
fi

log_header "DNS Infrastructure Setup - ALT Linux (FIXED)"

# ============================================================================
# ОЧИСТКА
# ============================================================================
log_step "Очистка старых конфигураций..."

systemctl stop bind.service 2>/dev/null || true
systemctl stop named.service 2>/dev/null || true

# Очищаем ВСЕ конфигурации
rm -rf /etc/named.conf
rm -rf /var/lib/bind/etc/named.conf
rm -rf /var/lib/bind/var/named/master/*.db
rm -rf /var/named/master/*.db
rm -rf /var/named/data/*
rm -rf /var/named/dynamic/*

# Создаем директории
mkdir -p /var/named/master
mkdir -p /var/named/data
mkdir -p /var/named/dynamic
mkdir -p /var/lib/bind/etc
mkdir -p /var/lib/bind/var/named/master
mkdir -p /var/lib/bind/var/named/data

log_info "Очистка завершена"

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Проверка установки BIND..."

if ! rpm -q bind &>/dev/null; then
    log_info "Установка BIND..."
    apt-get update || true
    apt-get install -y bind bind-utils
fi

log_info "BIND установлен"

# ============================================================================
# ОПРЕДЕЛЕНИЕ ПАРАМЕТРОВ
# ============================================================================
log_step "Определение сетевых параметров..."

LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)

if [ -z "$LOCAL_IP" ]; then
    log_error "Не удалось определить IP-адрес!"
    exit 1
fi

log_info "Обнаружен IP: $LOCAL_IP"

# ============================================================================
# ВВОД ПАРАМЕТРОВ
# ============================================================================
echo ""
log_header "НАСТРОЙКА DNS СЕРВЕРА"
echo ""
echo "Текущий IP: $LOCAL_IP"
echo ""
read -p "Введите IP адрес сервера (или нажмите Enter): " CUSTOM_IP
DNS_IP="${CUSTOM_IP:-$LOCAL_IP}"

read -p "Введите домен (например, au-team.irpo): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "Домен не может быть пустым!"
    exit 1
fi

read -p "Введите email администратора (например, admin.${DOMAIN_NAME}): " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin.${DOMAIN_NAME}}"

read -p "Введите hostname для NS (например, ns): " NS_HOSTNAME
NS_HOSTNAME="${NS_HOSTNAME:-ns}"

echo ""
log_info "DNS IP: $DNS_IP"
log_info "Домен: $DOMAIN_NAME"
log_info "Email: $ADMIN_EMAIL"
log_info "NS Hostname: $NS_HOSTNAME"
echo ""
read -p "Продолжить? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено"
    exit 1
fi

# ============================================================================
# ГЕНЕРАЦИЯ SERIAL
# ============================================================================
SERIAL=$(date +%Y%m%d01)
log_info "Serial: $SERIAL"

# ============================================================================
# ОТКЛЮЧЕНИЕ CHROOT (ВАЖНО!)
# ============================================================================
log_step "Отключение chroot для BIND..."

# Создаем или модифицируем /etc/sysconfig/bind
cat > /etc/sysconfig/bind << 'EOF'
# BIND Configuration
# Отключаем chroot для упрощения работы
CHROOT=""
OPTIONS="-u named"
EOF

log_info "CHROOT отключен"

# ============================================================================
# СОЗДАНИЕ named.conf (БЕЗ CHROOT)
# ============================================================================
log_step "Создание /etc/named.conf..."

# Удаляем возможные симлинки
rm -f /etc/named.conf
rm -f /var/lib/bind/etc/named.conf

# Создаем основной конфиг
cat > /etc/named.conf << EOF
//
// BIND Configuration File
// Generated: $(date)
// Домен: ${DOMAIN_NAME}
//

options {
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    listen-on port 53 { any; };
    listen-on-v6 port 53 { any; };
    
    allow-query { any; };
    recursion yes;
    
    // Forwarders (публичные DNS)
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
    
    dnssec-validation no;
    
    max-cache-size 256m;
};

logging {
    channel default_log {
        file "/var/named/data/named.log" versions 3 size 5m;
        severity info;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default { default_log; };
};

// Forward zone: ${DOMAIN_NAME}
zone "${DOMAIN_NAME}" IN {
    type master;
    file "master/${DOMAIN_NAME}.db";
    allow-update { none; };
};

// Reverse zone для ${DNS_IP}
zone "$(echo $DNS_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')" IN {
    type master;
    file "master/${DOMAIN_NAME}_rev.db";
    allow-update { none; };
};

// Local loopback
zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "master/named.loopback";
    allow-update { none; };
};
EOF

# Устанавливаем правильные права
chown root:named /etc/named.conf
chmod 640 /etc/named.conf

log_info "/etc/named.conf создан"

# ============================================================================
# FORWARD ZONE
# ============================================================================
log_step "Создание forward зоны..."

cat > /var/named/master/${DOMAIN_NAME}.db << EOF
\$TTL 1D
@   IN  SOA ${NS_HOSTNAME}.${DOMAIN_NAME}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${NS_HOSTNAME}.${DOMAIN_NAME}.
    IN  MX 10 ${NS_HOSTNAME}.${DOMAIN_NAME}.
    
${NS_HOSTNAME}    IN  A   ${DNS_IP}
@                 IN  A   ${DNS_IP}
www               IN  A   ${DNS_IP}
ftp               IN  A   ${DNS_IP}
mail              IN  A   ${DNS_IP}
EOF

log_info "Forward зона создана"

# ============================================================================
# REVERSE ZONE
# ============================================================================
log_step "Создание reverse зоны..."

REVERSE_NET="$(echo $DNS_IP | awk -F. '{print $3"."$2"."$1}')"
LAST_OCTET="$(echo $DNS_IP | awk -F. '{print $4}')"

cat > /var/named/master/${DOMAIN_NAME}_rev.db << EOF
\$TTL 1D
@   IN  SOA ${NS_HOSTNAME}.${DOMAIN_NAME}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${NS_HOSTNAME}.${DOMAIN_NAME}.
    
${LAST_OCTET} IN  PTR ${NS_HOSTNAME}.${DOMAIN_NAME}.
${LAST_OCTET} IN  PTR ${DOMAIN_NAME}.
EOF

log_info "Reverse зона создана"

# ============================================================================
# LOOPBACK ZONE
# ============================================================================
log_step "Создание loopback зоны..."

cat > /var/named/master/named.loopback << EOF
\$TTL 1D
@   IN  SOA ${NS_HOSTNAME}.${DOMAIN_NAME}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${NS_HOSTNAME}.${DOMAIN_NAME}.
1   IN  PTR localhost.
EOF

log_info "Loopback зона создана"

# ============================================================================
# ПРАВА ДОСТУПА (КРИТИЧНО!)
# ============================================================================
log_step "Установка прав доступа..."

# Для /var/named
chown -R named:named /var/named
chmod 750 /var/named
chmod 750 /var/named/master
chmod 750 /var/named/data
chmod 750 /var/named/dynamic
chmod 640 /var/named/master/*.db

# Для /var/lib/bind (если нужно)
chown -R named:named /var/lib/bind/var/named 2>/dev/null || true
chmod 750 /var/lib/bind/var/named 2>/dev/null || true
chmod 750 /var/lib/bind/var/named/master 2>/dev/null || true
chmod 640 /var/lib/bind/var/named/master/*.db 2>/dev/null || true

log_info "Права установлены"

# ============================================================================
# ПРОВЕРКИ
# ============================================================================
log_step "Проверка конфигурации..."

echo ""
log_info "Проверка named.conf..."
if named-checkconf /etc/named.conf; then
    log_info "named.conf: OK"
else
    log_error "named.conf: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка forward зоны..."
if named-checkzone ${DOMAIN_NAME} /var/named/master/${DOMAIN_NAME}.db; then
    log_info "Forward зона: OK"
else
    log_error "Forward зона: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка reverse зоны..."
if named-checkzone ${REVERSE_NET}.in-addr.arpa /var/named/master/${DOMAIN_NAME}_rev.db; then
    log_info "Reverse зона: OK"
else
    log_error "Reverse зона: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка loopback зоны..."
if named-checkzone 1.0.0.127.in-addr.arpa /var/named/master/named.loopback; then
    log_info "Loopback зона: OK"
else
    log_error "Loopback зона: ОШИБКА!"
    exit 1
fi

# ============================================================================
# FIREWALL
# ============================================================================
log_step "Настройка firewall..."

if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_info "Firewall настроен (firewalld)"
elif command -v ufw &> /dev/null; then
    ufw allow 53/tcp 2>/dev/null || true
    ufw allow 53/udp 2>/dev/null || true
    log_info "Firewall настроен (ufw)"
else
    log_warn "Firewall не настроен"
fi

# ============================================================================
# ЗАПУСК СЛУЖБЫ
# ============================================================================
log_step "Запуск BIND..."

systemctl daemon-reload
systemctl enable bind.service
systemctl restart bind.service

sleep 3

if systemctl is-active --quiet bind.service; then
    log_info "✓ BIND успешно запущен!"
else
    log_error "✗ BIND не запустился!"
    log_error "Проверьте логи:"
    log_error "  journalctl -xeu bind.service -n 50 --no-pager"
    echo ""
    systemctl status bind.service --no-pager -l
    exit 1
fi

# ============================================================================
# ТЕСТИРОВАНИЕ
# ============================================================================
log_header "ТЕСТИРОВАНИЕ"

echo ""
log_info "Forward lookup (${DOMAIN_NAME}):"
dig @localhost ${DOMAIN_NAME} +short || echo "  (dig не доступен)"

echo ""
log_info "Reverse lookup (${DNS_IP}):"
dig @localhost -x ${DNS_IP} +short || echo "  (dig не доступен)"

echo ""
log_info "NS record:"
dig @localhost ${DOMAIN_NAME} NS +short || echo "  (dig не доступен)"

echo ""
log_info "Статус службы:"
systemctl status bind.service --no-pager | grep -E "(Active|Loaded)" || true

# ============================================================================
# ИТОГИ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА"

echo ""
echo -e "${GREEN}✓ DNS сервер настроен успешно!${NC}"
echo ""
echo "Основные файлы:"
echo "  • Конфиг:     /etc/named.conf"
echo "  • Forward:    /var/named/master/${DOMAIN_NAME}.db"
echo "  • Reverse:    /var/named/master/${DOMAIN_NAME}_rev.db"
echo "  • Loopback:   /var/named/master/named.loopback"
echo ""
echo "Команды управления:"
echo "  • Статус:     systemctl status bind.service"
echo "  • Старт:      systemctl start bind.service"
echo "  • Стоп:       systemctl stop bind.service"
echo "  • Рестарт:    systemctl restart bind.service"
echo "  • Логи:       journalctl -xeu bind.service -f"
echo ""
echo "Тестирование:"
echo "  • dig @localhost ${DOMAIN_NAME}"
echo "  • dig @localhost -x ${DNS_IP}"
echo "  • nslookup ${DOMAIN_NAME} localhost"
echo ""
echo "Serial: ${SERIAL}"
echo ""
