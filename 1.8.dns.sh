#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - ALT Linux Server
# Версия: 5.0 - Полностью адаптивная версия
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
log_header "ОСНОВНЫЕ ПАРАМЕТРЫ"
echo ""

read -p "Введите домен (например, au-team.irpo): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "Домен не может быть пустым!"
    exit 1
fi

# Автоматически генерируем email и NS hostname на основе домена
NS_HOSTNAME="ns"
ADMIN_EMAIL="hostmaster.${DOMAIN_NAME}"

echo ""
log_header "УСТРОЙСТВА И ИХ IP АДРЕСА"
echo ""
echo "Введите данные для каждого устройства (оставьте пустым если устройство не используется):"
echo ""

# Массив для хранения устройств
declare -A DEVICES
declare -A DEVICE_IPS

# Ввод устройств
read -p "HQ-RTR IP адрес: " HQ_RTR_IP
[ -n "$HQ_RTR_IP" ] && { DEVICES[hq-rtr]="$HQ_RTR_IP"; DEVICE_IPS[$HQ_RTR_IP]="hq-rtr"; }

read -p "BR-RTR IP адрес: " BR_RTR_IP
[ -n "$BR_RTR_IP" ] && { DEVICES[br-rtr]="$BR_RTR_IP"; DEVICE_IPS[$BR_RTR_IP]="br-rtr"; }

read -p "HQ-SRV IP адрес: " HQ_SRV_IP
[ -n "$HQ_SRV_IP" ] && { DEVICES[hq-srv]="$HQ_SRV_IP"; DEVICE_IPS[$HQ_SRV_IP]="hq-srv"; }

read -p "HQ-CLI IP адрес: " HQ_CLI_IP
[ -n "$HQ_CLI_IP" ] && { DEVICES[hq-cli]="$HQ_CLI_IP"; DEVICE_IPS[$HQ_CLI_IP]="hq-cli"; }

read -p "BR-SRV IP адрес: " BR_SRV_IP
[ -n "$BR_SRV_IP" ] && { DEVICES[br-srv]="$BR_SRV_IP"; DEVICE_IPS[$BR_SRV_IP]="br-srv"; }

read -p "ISP docker IP (интерфейс к HQ-RTR, или Enter): " ISP_DOCKER_IP
[ -n "$ISP_DOCKER_IP" ] && { DEVICES[docker]="$ISP_DOCKER_IP"; DEVICE_IPS[$ISP_DOCKER_IP]="docker"; }

read -p "ISP web IP (интерфейс к BR-RTR, или Enter): " ISP_WEB_IP
[ -n "$ISP_WEB_IP" ] && { DEVICES[web]="$ISP_WEB_IP"; DEVICE_IPS[$ISP_WEB_IP]="web"; }

# Проверяем что введено хотя бы одно устройство
if [ ${#DEVICES[@]} -eq 0 ]; then
    log_error "Не введено ни одного IP адреса!"
    exit 1
fi

echo ""
log_header "НАСТРОЙКА DNS СЕРВЕРА"
echo ""

# Спрашиваем какой device является DNS сервером
echo "Какое устройство будет DNS сервером?"
echo "Варианты: ${!DEVICES[@]}"
echo ""
read -p "DNS сервер (оставьте пустым для ${NS_HOSTNAME}.${DOMAIN_NAME} на первом устройстве): " DNS_DEVICE

if [ -z "$DNS_DEVICE" ]; then
    # Используем первое устройство или HQ-SRV
    if [ -n "${DEVICES[hq-srv]}" ]; then
        DNS_DEVICE="hq-srv"
    else
        DNS_DEVICE="${!DEVICES[1]}"
    fi
    DNS_IP="${DEVICES[$DNS_DEVICE]}"
    DNS_FQDN="${NS_HOSTNAME}.${DOMAIN_NAME}"
else
    DNS_IP="${DEVICES[$DNS_DEVICE]}"
    if [ -z "$DNS_IP" ]; then
        log_error "Устройство $DNS_DEVICE не найдено!"
        exit 1
    fi
    DNS_FQDN="${DNS_DEVICE}.${DOMAIN_NAME}"
fi

echo ""
log_header "DNS FORWARDERS"
echo ""
read -p "Первый DNS сервер для пересылки (например, 8.8.8.8): " DNS1
DNS1="${DNS1:-8.8.8.8}"

read -p "Второй DNS сервер для пересылки (например, 8.8.4.4): " DNS2
DNS2="${DNS2:-8.8.4.4}"

echo ""
log_info "Сводка конфигурации:"
echo ""
echo "Домен: $DOMAIN_NAME"
echo "DNS сервер: $DNS_FQDN ($DNS_IP)"
echo "NS hostname: $NS_HOSTNAME"
echo "Admin email: $ADMIN_EMAIL"
echo ""
echo "Устройства:"
for device in "${!DEVICES[@]}"; do
    echo "  $device -> ${DEVICES[$device]}"
done
echo ""
echo "Forwarders: $DNS1, $DNS2"
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
declare -A REVERSE_ZONES
for ip in "${!DEVICE_IPS[@]}"; do
    REV_NET=$(echo $ip | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    REV_LAST=$(echo $ip | awk -F. '{print $4}')
    REVERSE_ZONES[$REV_NET]="${REVERSE_ZONES[$REV_NET]} $REV_LAST"
done

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

cat > /var/lib/bind/etc/named.conf << EOF
//
// BIND Configuration File
// Generated: $(date)
// Domain: ${DOMAIN_NAME}
// DNS Server: ${DNS_FQDN} (${DNS_IP})
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
    
    // Forwarders
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

# Добавляем reverse zones
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

# Loopback zone
cat >> /var/lib/bind/etc/named.conf << EOF
// Local loopback
zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "master/named.loopback";
    allow-update { none; };
};
EOF

ln -sf /var/lib/bind/etc/named.conf /etc/named.conf
chown root:named /var/lib/bind/etc/named.conf
chmod 640 /var/lib/bind/etc/named.conf
log_info "named.conf создан"

# ============================================================================
# FORWARD ZONE (АДАПТИВНАЯ)
# ============================================================================
log_step "Создание forward зоны..."

# Создаем forward зону с адаптивными записями
cat > /var/lib/bind/var/named/master/${DOMAIN_NAME}.db << EOF
\$TTL 1D
@   IN  SOA ${DNS_FQDN}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${DNS_FQDN}.
    IN  MX 10 ${DNS_FQDN}.

; DNS Server A record (ОБЯЗАТЕЛЬНО для работы NS)
${DNS_DEVICE}      IN  A   ${DNS_IP}

; Устройства из конфигурации
EOF

# Добавляем все устройства
for device in "${!DEVICES[@]}"; do
    if [ "$device" != "$DNS_DEVICE" ]; then
        echo "${device}      IN  A   ${DEVICES[$device]}" >> /var/lib/bind/var/named/master/${DOMAIN_NAME}.db
    fi
done

log_info "Forward зона создана"

# ============================================================================
# REVERSE ZONES (АДАПТИВНЫЕ)
# ============================================================================
log_step "Создание reverse зон..."

for REV_ZONE in "${!REVERSE_ZONES[@]}"; do
    LAST_OCTETS="${REVERSE_ZONES[$REV_ZONE]}"
    
    cat > /var/lib/bind/var/named/master/${REV_ZONE}.db << EOF
\$TTL 1D
@   IN  SOA ${DNS_FQDN}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${DNS_FQDN}.

EOF

    # Добавляем PTR записи для всех IP в этой подсети
    for LAST in $LAST_OCTETS; do
        # Находим device для этого IP
        for ip in "${!DEVICE_IPS[@]}"; do
            IP_LAST=$(echo $ip | awk -F. '{print $4}')
            if [ "$IP_LAST" = "$LAST" ]; then
                DEVICE="${DEVICE_IPS[$ip]}"
                echo "${LAST} IN  PTR  ${DEVICE}.${DOMAIN_NAME}." >> /var/lib/bind/var/named/master/${REV_ZONE}.db
            fi
        done
    done
    
    log_info "Reverse зона ${REV_ZONE} создана"
done

# ============================================================================
# LOOPBACK ZONE
# ============================================================================
log_step "Создание loopback зоны..."

cat > /var/lib/bind/var/named/master/named.loopback << EOF
\$TTL 1D
@   IN  SOA ${DNS_FQDN}. ${ADMIN_EMAIL}. (
            ${SERIAL}  ; serial
            1H         ; refresh
            15M        ; retry
            1W         ; expire
            1D )       ; minimum

    IN  NS  ${DNS_FQDN}.
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
if named-checkconf /var/lib/bind/etc/named.conf; then
    log_info "named.conf: OK"
else
    log_error "named.conf: ОШИБКА!"
    exit 1
fi

echo ""
if named-checkzone ${DOMAIN_NAME} /var/lib/bind/var/named/master/${DOMAIN_NAME}.db; then
    log_info "Forward зона: OK"
else
    log_error "Forward зона: ОШИБКА!"
    exit 1
fi

for REV_ZONE in "${!REVERSE_ZONES[@]}"; do
    if named-checkzone ${REV_ZONE} /var/lib/bind/var/named/master/${REV_ZONE}.db; then
        log_info "Reverse зона ${REV_ZONE}: OK"
    else
        log_error "Reverse зона ${REV_ZONE}: ОШИБКА!"
        exit 1
    fi
done

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
    systemctl status bind.service --no-pager -l
    exit 1
fi

# ============================================================================
# ТЕСТИРОВАНИЕ
# ============================================================================
log_header "ТЕСТИРОВАНИЕ"

echo ""
log_info "Forward lookup:"
dig @localhost ${DOMAIN_NAME} +short
dig @localhost ${DNS_FQDN} +short
for device in "${!DEVICES[@]}"; do
    dig @localhost ${device}.${DOMAIN_NAME} +short
done

echo ""
log_info "Reverse lookup:"
for ip in "${!DEVICE_IPS[@]}"; do
    dig @localhost -x ${ip} +short
done

echo ""
log_info "NS record:"
dig @localhost ${DOMAIN_NAME} NS +short

# ============================================================================
# ИТОГИ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА"

echo ""
echo -e "${GREEN}✓ DNS сервер успешно настроен!${NC}"
echo ""
echo "Конфигурация:"
echo "  • Домен: ${DOMAIN_NAME}"
echo "  • DNS сервер: ${DNS_FQDN} (${DNS_IP})"
echo "  • Forwarders: ${DNS1}, ${DNS2}"
echo ""
echo "Созданные записи:"
echo "  • ${DNS_FQDN} -> ${DNS_IP} (NS server)"
for device in "${!DEVICES[@]}"; do
    if [ "$device" != "$DNS_DEVICE" ]; then
        echo "  • ${device}.${DOMAIN_NAME} -> ${DEVICES[$device]}"
    fi
done
echo ""
echo "Файлы:"
echo "  • Конфиг: /var/lib/bind/etc/named.conf"
echo "  • Зоны: /var/lib/bind/var/named/master/"
echo ""
echo "Serial: ${SERIAL}"
echo ""
