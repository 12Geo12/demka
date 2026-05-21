#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - ALT Linux Server
# Полная версия с интерактивной настройкой всех параметров
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
# ОЧИСТКА
# ============================================================================
log_step "Очистка старых конфигураций..."

systemctl stop bind.service 2>/dev/null || true

rm -rf /var/lib/bind/etc/named.conf
rm -rf /var/lib/bind/var/named/master/*.db 2>/dev/null || true
rm -rf /var/named/master/*.db 2>/dev/null || true

mkdir -p /var/lib/bind/var/named/master
mkdir -p /var/lib/bind/var/named/data
mkdir -p /var/lib/bind/var/named/dynamic
mkdir -p /var/lib/bind/etc

log_info "Очистка завершена"

# ============================================================================
# УСТАНОВКА BIND
# ============================================================================
log_step "Проверка BIND..."

if ! rpm -q bind &>/dev/null; then
    log_info "Установка BIND..."
    apt-get update || true
    apt-get install -y bind bind-utils
fi

log_info "BIND установлен"

# ============================================================================
# ВВОД ПАРАМЕТРОВ
# ============================================================================
log_header "ВВОД ПАРАМЕТРОВ DNS"
echo ""

# Домен
read -p "Введите домен (например, au-team.irpo): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "Домен не может быть пустым!"
    exit 1
fi

# Email администратора
read -p "Введите email администратора (например, admin.${DOMAIN_NAME}): " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin.${DOMAIN_NAME}}"

# Hostname для NS
read -p "Введите hostname для NS записи (например, ns): " NS_HOSTNAME
NS_HOSTNAME="${NS_HOSTNAME:-ns}"

echo ""
log_header "IP АДРЕСА УСТРОЙСТВ (из Таблицы 3)"
echo ""
echo "Введите IP адреса для каждого устройства:"
echo ""

# HQ-RTR
read -p "HQ-RTR IP адрес: " HQ_RTR_IP
if [ -z "$HQ_RTR_IP" ]; then
    log_error "IP адрес HQ-RTR обязателен!"
    exit 1
fi

# BR-RTR
read -p "BR-RTR IP адрес: " BR_RTR_IP
if [ -z "$BR_RTR_IP" ]; then
    log_error "IP адрес BR-RTR обязателен!"
    exit 1
fi

# HQ-SRV
read -p "HQ-SRV IP адрес: " HQ_SRV_IP
if [ -z "$HQ_SRV_IP" ]; then
    log_error "IP адрес HQ-SRV обязателен!"
    exit 1
fi

# HQ-CLI
read -p "HQ-CLI IP адрес: " HQ_CLI_IP
if [ -z "$HQ_CLI_IP" ]; then
    log_error "IP адрес HQ-CLI обязателен!"
    exit 1
fi

# BR-SRV
read -p "BR-SRV IP адрес: " BR_SRV_IP
if [ -z "$BR_SRV_IP" ]; then
    log_error "IP адрес BR-SRV обязателен!"
    exit 1
fi

# ISP docker (интерфейс к HQ-RTR)
read -p "ISP docker IP адрес (интерфейс к HQ-RTR): " ISP_DOCKER_IP
if [ -z "$ISP_DOCKER_IP" ]; then
    log_warn "ISP docker IP не указан, будет пропущен"
fi

# ISP web (интерфейс к BR-RTR)
read -p "ISP web IP адрес (интерфейс к BR-RTR): " ISP_WEB_IP
if [ -z "$ISP_WEB_IP" ]; then
    log_warn "ISP web IP не указан, будет пропущен"
fi

echo ""
log_header "DNS FORWARDERS"
echo ""
echo "Введите публичные DNS серверы для пересылки запросов:"
echo "Можно использовать: 8.8.8.8, 8.8.4.4, 77.88.8.7, 77.88.8.3"
echo ""

read -p "Первый DNS сервер (например, 8.8.8.8): " DNS1
DNS1="${DNS1:-8.8.8.8}"

read -p "Второй DNS сервер (например, 8.8.4.4): " DNS2
DNS2="${DNS2:-8.8.4.4}"

echo ""
log_info "Проверка введенных данных:"
echo ""
echo "Домен: $DOMAIN_NAME"
echo "Email: $ADMIN_EMAIL"
echo "NS Hostname: $NS_HOSTNAME"
echo ""
echo "Устройства:"
echo "  HQ-RTR:  $HQ_RTR_IP"
echo "  BR-RTR:  $BR_RTR_IP"
echo "  HQ-SRV:  $HQ_SRV_IP"
echo "  HQ-CLI:  $HQ_CLI_IP"
echo "  BR-SRV:  $BR_SRV_IP"
[ -n "$ISP_DOCKER_IP" ] && echo "  ISP docker: $ISP_DOCKER_IP"
[ -n "$ISP_WEB_IP" ] && echo "  ISP web: $ISP_WEB_IP"
echo ""
echo "DNS Forwarders:"
echo "  Primary:   $DNS1"
echo "  Secondary: $DNS2"
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

# ============================================================================
# ОПРЕДЕЛЕНИЕ REVERSE ZONES
# ============================================================================
# Извлекаем подсети для reverse зон
HQ_RTR_REV=$(echo $HQ_RTR_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
HQ_RTR_LAST=$(echo $HQ_RTR_IP | awk -F. '{print $4}')

HQ_SRV_REV=$(echo $HQ_SRV_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
HQ_SRV_LAST=$(echo $HQ_SRV_IP | awk -F. '{print $4}')

HQ_CLI_REV=$(echo $HQ_CLI_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
HQ_CLI_LAST=$(echo $HQ_CLI_IP | awk -F. '{print $4}')

BR_RTR_REV=$(echo $BR_RTR_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
BR_RTR_LAST=$(echo $BR_RTR_IP | awk -F. '{print $4}')

BR_SRV_REV=$(echo $BR_SRV_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
BR_SRV_LAST=$(echo $BR_SRV_IP | awk -F. '{print $4}')

# Собираем уникальные reverse зоны
declare -A REVERSE_ZONES
REVERSE_ZONES[$HQ_RTR_REV]="$HQ_RTR_LAST"
REVERSE_ZONES[$HQ_SRV_REV]="$HQ_SRV_LAST"
REVERSE_ZONES[$HQ_CLI_REV]="$HQ_CLI_LAST"
[ -n "$ISP_DOCKER_IP" ] && {
    ISP_DOCKER_REV=$(echo $ISP_DOCKER_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    ISP_DOCKER_LAST=$(echo $ISP_DOCKER_IP | awk -F. '{print $4}')
    REVERSE_ZONES[$ISP_DOCKER_REV]="$ISP_DOCKER_LAST"
}
[ -n "$ISP_WEB_IP" ] && {
    ISP_WEB_REV=$(echo $ISP_WEB_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    ISP_WEB_LAST=$(echo $ISP_WEB_IP | awk -F. '{print $4}')
    REVERSE_ZONES[$ISP_WEB_REV]="$ISP_WEB_LAST"
}

# ============================================================================
# НАСТРОЙКА CHROOT
# ============================================================================
log_step "Настройка chroot окружения..."

cat > /etc/sysconfig/bind << 'EOF'
# BIND Configuration for ALT Linux
CHROOT="-t /var/lib/bind"
OPTIONS="-u named"
EOF

log_info "Chroot настроен"

# ============================================================================
# СОЗДАНИЕ named.conf
# ============================================================================
log_step "Создание конфигурации named.conf..."

# Начинаем создавать конфиг
cat > /var/lib/bind/etc/named.conf << EOF
//
// BIND Configuration File
// Generated: $(date)
// Domain: ${DOMAIN_NAME}
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
        ${DNS1};
        ${DNS2};
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

EOF

# Добавляем reverse zones в конфиг
for REV_ZONE in "${!REVERSE_ZONES[@]}"; do
    cat >> /var/lib/bind/etc/named.conf << EOF
// Reverse zone: ${REV_ZONE}
zone "${REV_ZONE}" IN {
    type master;
    file "master/${REV_ZONE}.db";
    allow-update { none; };
};

EOF
done

# Добавляем loopback zone
cat >> /var/lib/bind/etc/named.conf << EOF
// Local loopback
zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "master/named.loopback";
    allow-update { none; };
};
EOF

# Создаем симлинк
ln -sf /var/lib/bind/etc/named.conf /etc/named.conf
chown root:named /var/lib/bind/etc/named.conf
chmod 640 /var/lib/bind/etc/named.conf

log_info "named.conf создан"

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
    
; Из Таблицы 3 - устройства
hq-rtr      IN  A   ${HQ_RTR_IP}
br-rtr      IN  A   ${BR_RTR_IP}
hq-srv      IN  A   ${HQ_SRV_IP}
hq-cli      IN  A   ${HQ_CLI_IP}
br-srv      IN  A   ${BR_SRV_IP}
EOF

# Добавляем ISP записи если указаны
[ -n "$ISP_DOCKER_IP" ] && echo "docker      IN  A   ${ISP_DOCKER_IP}" >> /var/lib/bind/var/named/master/${DOMAIN_NAME}.db
[ -n "$ISP_WEB_IP" ] && echo "web         IN  A   ${ISP_WEB_IP}" >> /var/lib/bind/var/named/master/${DOMAIN_NAME}.db

log_info "Forward зона создана"

# ============================================================================
# REVERSE ZONES
# ============================================================================
log_step "Создание reverse зон..."

for REV_ZONE in "${!REVERSE_ZONES[@]}"; do
    LAST_OCTET="${REVERSE_ZONES[$REV_ZONE]}"
    
    # Определяем имя хоста для этого IP
    HOSTNAME=""
    [ "$LAST_OCTET" = "$HQ_RTR_LAST" ] && HOSTNAME="hq-rtr"
    [ "$LAST_OCTET" = "$HQ_SRV_LAST" ] && HOSTNAME="hq-srv"
    [ "$LAST_OCTET" = "$HQ_CLI_LAST" ] && HOSTNAME="hq-cli"
    [ "$LAST_OCTET" = "$BR_RTR_LAST" ] && HOSTNAME="br-rtr"
    [ "$LAST_OCTET" = "$BR_SRV_LAST" ] && HOSTNAME="br-srv"
    [ -n "$ISP_DOCKER_IP" ] && [ "$LAST_OCTET" = "$(echo $ISP_DOCKER_IP | awk -F. '{print $4}')" ] && HOSTNAME="docker"
    [ -n "$ISP_WEB_IP" ] && [ "$LAST_OCTET" = "$(echo $ISP_WEB_IP | awk -F. '{print $4}')" ] && HOSTNAME="web"
    
    cat > /var/lib/bind/var/named/master/${REV_ZONE}.db << EOF
\$TTL 1D
@   IN  SOA ${NS_HOSTNAME}.${DOMAIN_NAME}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${NS_HOSTNAME}.${DOMAIN_NAME}.
    
${LAST_OCTET} IN  PTR ${HOSTNAME}.${DOMAIN_NAME}.
EOF

    log_info "Reverse зона ${REV_ZONE} создана"
done

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
# ПРАВА ДОСТУПА
# ============================================================================
log_step "Установка прав доступа..."

chown -R named:named /var/lib/bind/var/named
chmod 750 /var/lib/bind/var/named
chmod 750 /var/lib/bind/var/named/master
chmod 750 /var/lib/bind/var/named/data
chmod 750 /var/lib/bind/var/named/dynamic
chmod 640 /var/lib/bind/var/named/master/*.db

chown root:named /var/lib/bind/etc/named.conf
chmod 640 /var/lib/bind/etc/named.conf

log_info "Права доступа установлены"

# ============================================================================
# ПРОВЕРКИ
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

# Проверяем reverse зоны
for REV_ZONE in "${!REVERSE_ZONES[@]}"; do
    echo ""
    log_info "Проверка reverse зоны ${REV_ZONE}..."
    if named-checkzone ${REV_ZONE} /var/lib/bind/var/named/master/${REV_ZONE}.db; then
        log_info "Reverse зона ${REV_ZONE}: OK"
    else
        log_error "Reverse зона ${REV_ZONE}: ОШИБКА!"
        exit 1
    fi
done

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
    log_error "Проверьте логи: journalctl -xeu bind.service -n 50 --no-pager"
    systemctl status bind.service --no-pager -l
    exit 1
fi

# ============================================================================
# ТЕСТИРОВАНИЕ
# ============================================================================
log_header "ТЕСТИРОВАНИЕ"

echo ""
log_info "Тестирование forward зоны:"
dig @localhost ${DOMAIN_NAME} +short
dig @localhost hq-rtr.${DOMAIN_NAME} +short
dig @localhost hq-srv.${DOMAIN_NAME} +short

echo ""
log_info "Тестирование reverse зоны:"
dig @localhost -x ${HQ_SRV_IP} +short

echo ""
log_info "Статус службы:"
systemctl status bind.service --no-pager | grep -E "(Active|Loaded)" || true

# ============================================================================
# ИТОГИ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА"

echo ""
echo -e "${GREEN}✓ DNS сервер успешно настроен!${NC}"
echo ""
echo "Основные файлы:"
echo "  • Конфиг:     /var/lib/bind/etc/named.conf"
echo "  • Симлинк:    /etc/named.conf"
echo "  • Forward:    /var/lib/bind/var/named/master/${DOMAIN_NAME}.db"
echo "  • Reverse:    /var/lib/bind/var/named/master/*.db"
echo ""
echo "Созданные DNS записи (из Таблицы 3):"
echo "  • hq-rtr.${DOMAIN_NAME}   -> ${HQ_RTR_IP}"
echo "  • br-rtr.${DOMAIN_NAME}   -> ${BR_RTR_IP}"
echo "  • hq-srv.${DOMAIN_NAME}   -> ${HQ_SRV_IP}"
echo "  • hq-cli.${DOMAIN_NAME}   -> ${HQ_CLI_IP}"
echo "  • br-srv.${DOMAIN_NAME}   -> ${BR_SRV_IP}"
[ -n "$ISP_DOCKER_IP" ] && echo "  • docker.${DOMAIN_NAME}   -> ${ISP_DOCKER_IP}"
[ -n "$ISP_WEB_IP" ] && echo "  • web.${DOMAIN_NAME}      -> ${ISP_WEB_IP}"
echo ""
echo "DNS Forwarders:"
echo "  • Primary:   ${DNS1}"
echo "  • Secondary: ${DNS2}"
echo ""
echo "Команды управления:"
echo "  • Статус:     systemctl status bind.service"
echo "  • Рестарт:    systemctl restart bind.service"
echo "  • Логи:       journalctl -xeu bind.service -f"
echo ""
echo "Тестирование:"
echo "  • dig @localhost hq-rtr.${DOMAIN_NAME}"
echo "  • dig @localhost -x ${HQ_SRV_IP}"
echo "  • nslookup hq-srv.${DOMAIN_NAME} localhost"
echo ""
echo "Serial: ${SERIAL}"
echo ""
