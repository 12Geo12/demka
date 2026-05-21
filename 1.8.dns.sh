#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - ALT Linux Server
# Версия: 3.0 - Полностью рабочая версия с учетом chroot
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

log_header "DNS Infrastructure Setup - ALT Linux Server"

# ============================================================================
# ОЧИСТКА СТАРЫХ КОНФИГУРАЦИЙ
# ============================================================================
log_step "Очистка старых конфигураций..."

systemctl stop bind.service 2>/dev/null || true
systemctl stop named.service 2>/dev/null || true

# Очищаем ВСЕ старые конфиги
rm -rf /etc/named.conf
rm -rf /var/lib/bind/etc/named.conf
rm -rf /var/lib/bind/var/named/master/*.db 2>/dev/null || true
rm -rf /var/named/master/*.db 2>/dev/null || true
rm -rf /var/named/data/* 2>/dev/null || true
rm -rf /var/named/dynamic/* 2>/dev/null || true

# Создаем необходимые директории (В CHROOT!)
mkdir -p /var/lib/bind/var/named/master
mkdir -p /var/lib/bind/var/named/data
mkdir -p /var/lib/bind/var/named/dynamic
mkdir -p /var/lib/bind/etc

log_info "Очистка завершена"

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Проверка установки BIND..."

if ! rpm -q bind &>/dev/null; then
    log_info "Установка BIND..."
    apt-get update || true
    apt-get install -y bind bind-utils
    log_info "BIND установлен"
else
    log_info "BIND уже установлен"
fi

# ============================================================================
# ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
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
read -p "Продолжить настройку? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено пользователем"
    exit 1
fi

# ============================================================================
# ГЕНЕРАЦИЯ SERIAL
# ============================================================================
SERIAL=$(date +%Y%m%d01)
log_info "Serial: $SERIAL"

# ============================================================================
# НАСТРОЙКА CHROOT
# ============================================================================
log_step "Настройка chroot окружения..."

# В ALT Linux оставляем chroot как есть (стандартная конфигурация)
cat > /etc/sysconfig/bind << 'EOF'
# BIND Configuration for ALT Linux
# Используем стандартное chroot окружение
CHROOT="-t /var/lib/bind"
OPTIONS="-u named"
EOF

log_info "Chroot настроен: /var/lib/bind"

# ============================================================================
# СОЗДАНИЕ named.conf (В CHROOT!)
# ============================================================================
log_step "Создание конфигурации named.conf..."

# Создаем конфиг В CHROOT окружении
cat > /var/lib/bind/etc/named.conf << EOF
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

# Создаем симлинк /etc/named.conf -> /var/lib/bind/etc/named.conf
ln -sf /var/lib/bind/etc/named.conf /etc/named.conf

# Устанавливаем права
chown root:named /var/lib/bind/etc/named.conf
chmod 640 /var/lib/bind/etc/named.conf

log_info "named.conf создан в chroot"

# ============================================================================
# FORWARD ZONE
# ============================================================================
log_step "Создание forward зоны..."

cat > /var/lib/bind/var/named/master/${DOMAIN_NAME}.db << EOF
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

cat > /var/lib/bind/var/named/master/${DOMAIN_NAME}_rev.db << EOF
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

cat > /var/lib/bind/var/named/master/named.loopback << EOF
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

# Права для chroot окружения
chown -R named:named /var/lib/bind/var/named
chmod 750 /var/lib/bind/var/named
chmod 750 /var/lib/bind/var/named/master
chmod 750 /var/lib/bind/var/named/data
chmod 750 /var/lib/bind/var/named/dynamic
chmod 640 /var/lib/bind/var/named/master/*.db

# Права для etc
chown root:named /var/lib/bind/etc/named.conf
chmod 640 /var/lib/bind/etc/named.conf

log_info "Права доступа установлены"

# ============================================================================
# ПРОВЕРКИ КОНФИГУРАЦИИ
# ============================================================================
log_step "Проверка конфигурации..."

echo ""
log_info "Проверка named.conf..."
if named-checkconf /var/lib/bind/etc/named.conf; then
    log_info "named.conf: OK"
else
    log_error "named.conf: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка forward зоны..."
if named-checkzone ${DOMAIN_NAME} /var/lib/bind/var/named/master/${DOMAIN_NAME}.db; then
    log_info "Forward зона: OK"
else
    log_error "Forward зона: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка reverse зоны..."
if named-checkzone ${REVERSE_NET}.in-addr.arpa /var/lib/bind/var/named/master/${DOMAIN_NAME}_rev.db; then
    log_info "Reverse зона: OK"
else
    log_error "Reverse зона: ОШИБКА!"
    exit 1
fi

echo ""
log_info "Проверка loopback зоны..."
if named-checkzone 1.0.0.127.in-addr.arpa /var/lib/bind/var/named/master/named.loopback; then
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
    log_warn "Firewall не настроен (не обнаружен)"
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
log_header "ТЕСТИРОВАНИЕ DNS"

echo ""
log_info "Forward lookup (${DOMAIN_NAME}):"
dig @localhost ${DOMAIN_NAME} +short 2>/dev/null || echo "  (dig не доступен)"

echo ""
log_info "Reverse lookup (${DNS_IP}):"
dig @localhost -x ${DNS_IP} +short 2>/dev/null || echo "  (dig не доступен)"

echo ""
log_info "NS record:"
dig @localhost ${DOMAIN_NAME} NS +short 2>/dev/null || echo "  (dig не доступен)"

echo ""
log_info "Статус службы:"
systemctl status bind.service --no-pager | grep -E "(Active|Loaded)" || true

# ============================================================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА"

echo ""
echo -e "${GREEN}✓ DNS сервер успешно настроен!${NC}"
echo ""
echo "Основные файлы:"
echo "  • Конфиг:     /var/lib/bind/etc/named.conf"
echo "  • Симлинк:    /etc/named.conf -> /var/lib/bind/etc/named.conf"
echo "  • Forward:    /var/lib/bind/var/named/master/${DOMAIN_NAME}.db"
echo "  • Reverse:    /var/lib/bind/var/named/master/${DOMAIN_NAME}_rev.db"
echo "  • Loopback:   /var/lib/bind/var/named/master/named.loopback"
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
echo -e "${YELLOW}ВАЖНО: В ALT Linux используется chroot окружение!${NC}"
echo "Все файлы находятся в /var/lib/bind/"
echo ""
