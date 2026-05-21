#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - ALT Linux Server Edition
# Исправленная версия для работы с bind.service
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

log_header "DNS Infrastructure Setup Script - ALT Linux"

# ============================================================================
# ОЧИСТКА СТАРЫХ КОНФИГУРАЦИЙ
# ============================================================================
log_step "=== ОЧИСТКА СТАРЫХ КОНФИГУРАЦИЙ ==="
echo ""
log_warn "ВНИМАНИЕ: Будут удалены все старые конфигурации DNS!"
read -p "Продолжить очистку? [y/N]: " clean_confirm

if [[ ! "$clean_confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено пользователем"
    exit 1
fi

systemctl stop named 2>/dev/null || true
systemctl stop bind 2>/dev/null || true

rm -rf /var/lib/bind/etc/named.conf 2>/dev/null || true
rm -rf /var/lib/bind/var/named/master/*.db 2>/dev/null || true
rm -rf /etc/named.conf.bak 2>/dev/null || true
rm -f /etc/named.conf 2>/dev/null || true
rm -rf /var/named/master/*.db 2>/dev/null || true
rm -rf /var/named/data/* 2>/dev/null || true
rm -rf /var/named/dynamic/* 2>/dev/null || true

log_info "Очистка завершена"

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Установка BIND..."

if [ -f /etc/altlinux-release ]; then
    apt-get update || true
    apt-get install -y bind bind-utils
    log_info "BIND установлен"
else
    log_error "Только ALT Linux поддерживается"
    exit 1
fi

# ============================================================================
# АВТООПРЕДЕЛЕНИЕ IP
# ============================================================================
log_step "Автоопределение сетевых параметров..."
echo ""

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
log_header "НАСТРОЙКА DNS"
echo ""
echo "Текущий IP: $LOCAL_IP"
echo ""
read -p "Введите IP адрес сервера (или нажмите Enter для использования текущего): " CUSTOM_IP
DNS_IP="${CUSTOM_IP:-$LOCAL_IP}"

read -p "Введите домен (например, au-team.irpo): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "Домен не может быть пустым!"
    exit 1
fi

read -p "Введите email администратора (например, admin.${DOMAIN_NAME}): " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin.${DOMAIN_NAME}}"

read -p "Введите hostname для NS записи (например, ns): " NS_HOSTNAME
NS_HOSTNAME="${NS_HOSTNAME:-ns}"

echo ""
log_info "DNS IP: $DNS_IP"
log_info "Домен: $DOMAIN_NAME"
log_info "Email: $ADMIN_EMAIL"
log_info "NS Hostname: $NS_HOSTNAME"
echo ""
read -p "Продолжить настройку? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено пользователем"
    exit 1
fi

# ============================================================================
# ГЕНЕРАЦИЯ КОНФИГУРАЦИИ
# ============================================================================
log_step "Создание конфигурации named.conf..."

# Создаем директорию
mkdir -p /var/named/master
mkdir -p /var/named/data
mkdir -p /var/named/dynamic

# Генерируем serial
SERIAL=$(date +%Y%m%d01)

# Создаем named.conf БЕЗ chroot
cat > /etc/named.conf << EOF
//
// BIND Configuration File
// Generated: $(date)
//

options {
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file "/var/named/data/named.secroots";
    recursing-file "/var/named/data/named.recursing";
    
    listen-on port 53 { any; };
    listen-on-v6 port 53 { any; };
    
    allow-query { any; };
    recursion yes;
    
    dnssec-validation no;
    
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
    
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

// Forward zone for ${DOMAIN_NAME}
zone "${DOMAIN_NAME}" IN {
    type master;
    file "master/${DOMAIN_NAME}.db";
    allow-update { none; };
};

// Reverse zone for ${DNS_IP}
zone "$(echo $DNS_IP | cut -d. -f3).$(echo $DNS_IP | cut -d. -f2).$(echo $DNS_IP | cut -d. -f1).in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_rev.db";
    allow-update { none; };
};

// Local loopback reverse zone
zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "master/named.loopback";
    allow-update { none; };
};
EOF

log_info "named.conf создан"

# ============================================================================
# СОЗДАНИЕ ФАЙЛА ZONE (FORWARD)
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

log_info "Forward зона создана: /var/named/master/${DOMAIN_NAME}.db"

# ============================================================================
# СОЗДАНИЕ ФАЙЛА REVERSE ZONE
# ============================================================================
log_step "Создание reverse зоны..."

REVERSE_NET="$(echo $DNS_IP | cut -d. -f1-3 | awk -F. '{print $3"."$2"."$1}')"

cat > /var/named/master/${DOMAIN_NAME}_rev.db << EOF
\$TTL 1D
@   IN  SOA ${NS_HOSTNAME}.${DOMAIN_NAME}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${NS_HOSTNAME}.${DOMAIN_NAME}.
    
$(echo $DNS_IP | cut -d. -f4) IN  PTR ${NS_HOSTNAME}.${DOMAIN_NAME}.
$(echo $DNS_IP | cut -d. -f4) IN  PTR ${DOMAIN_NAME}.
EOF

log_info "Reverse зона создана: /var/named/master/${DOMAIN_NAME}_rev.db"

# ============================================================================
# СОЗДАНИЕ LOOPBACK ZONE (ИСПРАВЛЕНО!)
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

log_info "Loopback зона создана: /var/named/master/named.loopback"

# ============================================================================
# УСТАНОВКА ПРАВ ДОСТУПА (КРИТИЧНО!)
# ============================================================================
log_step "Установка прав доступа..."

chown -R named:named /var/named/master
chown -R named:named /var/named/data
chown -R named:named /var/named/dynamic

chmod 640 /var/named/master/*.db
chmod 750 /var/named/master
chmod 750 /var/named/data
chmod 750 /var/named/dynamic

log_info "Права доступа установлены"

# ============================================================================
# ПРОВЕРКА КОНФИГУРАЦИИ
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
# НАСТРОЙКА FIREWALL
# ============================================================================
log_step "Настройка firewall..."

if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=dns || true
    firewall-cmd --reload || true
    log_info "Firewall настроен (firewalld)"
elif command -v ufw &> /dev/null; then
    ufw allow 53/tcp || true
    ufw allow 53/udp || true
    log_info "Firewall настроен (ufw)"
else
    log_warn "Firewall не обнаружен или не настроен"
fi

# ============================================================================
# ЗАПУСК СЛУЖБЫ
# ============================================================================
log_step "Запуск BIND..."

systemctl daemon-reload
systemctl enable bind.service
systemctl restart bind.service

sleep 2

# Проверка статуса
if systemctl is-active --quiet bind.service; then
    log_info "BIND успешно запущен!"
else
    log_error "BIND не запустился!"
    log_error "Проверьте логи: journalctl -xeu bind.service"
    systemctl status bind.service --no-pager
    exit 1
fi

# ============================================================================
# ТЕСТИРОВАНИЕ
# ============================================================================
log_header "ТЕСТИРОВАНИЕ DNS"

echo ""
log_info "Тестирование forward зоны..."
dig @localhost ${DOMAIN_NAME} +short

echo ""
log_info "Тестирование reverse зоны..."
dig @localhost -x ${DNS_IP} +short

echo ""
log_info "Проверка NS записи..."
dig @localhost ${DOMAIN_NAME} NS +short

echo ""
log_info "Проверка статуса службы..."
systemctl status bind.service --no-pager | head -10

# ============================================================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА"

echo ""
echo -e "${GREEN}DNS сервер успешно настроен!${NC}"
echo ""
echo "Основные файлы:"
echo "  - Конфигурация: /etc/named.conf"
echo "  - Forward зона: /var/named/master/${DOMAIN_NAME}.db"
echo "  - Reverse зона: /var/named/master/${DOMAIN_NAME}_rev.db"
echo "  - Loopback зона: /var/named/master/named.loopback"
echo ""
echo "Полезные команды:"
echo "  - Проверка статуса: systemctl status bind.service"
echo "  - Просмотр логов: journalctl -xeu bind.service"
echo "  - Перезапуск: systemctl restart bind.service"
echo "  - Тестирование: dig @localhost ${DOMAIN_NAME}"
echo ""
echo "Serial: ${SERIAL}"
echo ""
