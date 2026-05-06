#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script for Demo-2026 (Исправленная версия для chroot)
# Версия: 4.1 (исправлены проверки named-checkconf и named-checkzone)
# ============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    log_error "Запустите скрипт от имени root!"
    exit 1
fi

# ============================================================================
# Определение ОС и установка пакетов
# ============================================================================
log_step "Определение ОС и установка BIND..."

if [ -f /etc/altlinux-release ]; then
    OS_VERSION=$(cat /etc/altlinux-release | grep -oP '\d+\.\d+' | head -1)
    log_info "Обнаружен ALT Linux версии: $OS_VERSION"
    apt-get update
    apt-get install -y bind bind-utils
    log_info "BIND установлен успешно"
else
    log_error "Поддерживается только ALT Linux"
    exit 1
fi

# ============================================================================
# Переменные для chroot
# ============================================================================
CHROOT_DIR="/var/lib/bind"
CHROOT_ETC="${CHROOT_DIR}/etc"        # /etc внутри chroot
CHROOT_VAR="${CHROOT_DIR}/var/named"  # /var/named внутри chroot

# ============================================================================
# Автоопределение сети и интерактивный ввод
# ============================================================================
log_step "Автоопределение параметров сети..."
echo ""

# Автоопределение локального IP
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
log_info "Обнаружен локальный IP: $LOCAL_IP"

# Определение подсети
SUBNET=$(echo "$LOCAL_IP" | cut -d'.' -f1-3)
log_info "Подсеть: $SUBNET.x"

# Определение имени хоста
HOSTNAME=$(hostname)
log_info "Имя хоста: $HOSTNAME"

echo ""
echo "============================================"
echo " Настройка DNS сервера"
echo "============================================"
echo ""

# Ввод IP-адресов устройств
read -p "IP-адрес HQ-RTR [$SUBNET.1]: " HQ_RTR_IP
HQ_RTR_IP=${HQ_RTR_IP:-"$SUBNET.1"}

read -p "IP-адрес HQ-SRV [$LOCAL_IP]: " HQ_SRV_IP
HQ_SRV_IP=${HQ_SRV_IP:-"$LOCAL_IP"}

read -p "IP-адрес BR-RTR: " BR_RTR_IP
while [ -z "$BR_RTR_IP" ]; do
    log_error "BR-RTR IP обязателен!"
    read -p "IP-адрес BR-RTR: " BR_RTR_IP
done

read -p "IP-адрес BR-SRV: " BR_SRV_IP
while [ -z "$BR_SRV_IP" ]; do
    log_error "BR-SRV IP обязателен!"
    read -p "IP-адрес BR-SRV: " BR_SRV_IP
done

read -p "IP-адрес Docker (внешний): " DOCKER_IP
while [ -z "$DOCKER_IP" ]; do
    log_error "Docker IP обязателен!"
    read -p "IP-адрес Docker: " DOCKER_IP
done

read -p "IP-адрес WEB (внешний): " WEB_IP
while [ -z "$WEB_IP" ]; do
    log_error "WEB IP обязателен!"
    read -p "IP-адрес WEB: " WEB_IP
done

# Доменное имя
read -p "Доменное имя [au-team.irpo]: " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-"au-team.irpo"}

# Выбор DNS-серверов пересылки
echo ""
log_info "Выбор DNS-серверов пересылки (forwarders):"
echo "1) Яндекс DNS (77.88.8.8, 77.88.8.1)"
echo "2) Яндекс DNS альтернативные (77.88.8.7, 77.88.8.3)"
echo "3) Google DNS (8.8.8.8, 8.8.4.4)"
echo "4) Cloudflare (1.1.1.1, 1.0.0.1)"

read -p "Выбор [1]: " FWD_CHOICE
FWD_CHOICE=${FWD_CHOICE:-1}

case $FWD_CHOICE in
    1) FWD1="77.88.8.8"; FWD2="77.88.8.1" ;;
    2) FWD1="77.88.8.7"; FWD2="77.88.8.3" ;;
    3) FWD1="8.8.8.8"; FWD2="8.8.4.4" ;;
    4) FWD1="1.1.1.1"; FWD2="1.0.0.1" ;;
    *) FWD1="77.88.8.8"; FWD2="77.88.8.1" ;;
esac

# Сводка
echo ""
echo "============================================"
echo " Сводка конфигурации"
echo "============================================"
echo " Домен: $DOMAIN_NAME"
echo " HQ-RTR: $HQ_RTR_IP"
echo " HQ-SRV: $HQ_SRV_IP"
echo " BR-RTR: $BR_RTR_IP"
echo " BR-SRV: $BR_SRV_IP"
echo " Docker: $DOCKER_IP"
echo " WEB: $WEB_IP"
echo " Forwarders: $FWD1, $FWD2"
echo "============================================"
echo ""

read -p "Всё верно? Продолжить? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено пользователем"
    exit 1
fi

# ============================================================================
# Создание структуры директорий в chroot-окружении
# ============================================================================
log_step "Создание структуры директорий в chroot-окружении..."

# Остановка сервисов перед изменениями
systemctl stop named 2>/dev/null || true
systemctl stop bind 2>/dev/null || true

# Создание директорий в /var/lib/bind (chroot-окружении)
mkdir -p ${CHROOT_ETC}
mkdir -p ${CHROOT_VAR}
mkdir -p ${CHROOT_VAR}/master
mkdir -p ${CHROOT_VAR}/data
mkdir -p ${CHROOT_VAR}/dynamic
mkdir -p ${CHROOT_VAR}/slaves

# КРИТИЧНО: Установка владельца и прав в chroot
chown -R named:named ${CHROOT_DIR}
chmod 750 ${CHROOT_VAR}
chmod 750 ${CHROOT_VAR}/master
chmod 750 ${CHROOT_VAR}/data
chmod 750 ${CHROOT_VAR}/dynamic

log_info "Директории в chroot созданы"

# ============================================================================
# Генерация rndc ключа
# ============================================================================
log_step "Генерация rndc ключа..."

if [ ! -f /etc/rndc.key ]; then
    rndc-confgen -a -q 2>/dev/null || true
fi

if [ -f /etc/rndc.key ]; then
    chown root:named /etc/rndc.key
    chmod 640 /etc/rndc.key
    log_info "rndc.key создан"
fi

# ============================================================================
# Создание named.conf в chroot-окружении
# ============================================================================
log_step "Создание ${CHROOT_ETC}/named.conf..."

# Определение обратной зоны
REV_ZONE=$(echo "$SUBNET" | awk -F. '{print $3"."$2"."$1}')

cat > ${CHROOT_ETC}/named.conf << EOF
// DNS Configuration for $DOMAIN_NAME
// Generated by setup script for chroot environment

options {
    listen-on port 53 { 127.0.0.1; $HQ_SRV_IP; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    dump-file "data/cache_dump.db";
    statistics-file "data/named_stats.txt";
    memstatistics-file "data/named_mem_stats.txt";
    allow-query { any; };
    allow-recursion { any; };
    forwarders { $FWD1; $FWD2; };
    recursion yes;
    dnssec-validation no;
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

include "/etc/rndc.key";

controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

// Прямая зона
zone "$DOMAIN_NAME" IN {
    type master;
    file "master/$DOMAIN_NAME.db";
    allow-update { none; };
};

// Обратная зона
zone "$REV_ZONE.in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_rev.db";
    allow-update { none; };
};

// Стандартные зоны
zone "localhost" IN {
    type master;
    file "named.localhost";
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "named.loopback";
};

zone "." IN {
    type hint;
    file "named.root";
};

EOF

chown root:named ${CHROOT_ETC}/named.conf
chmod 640 ${CHROOT_ETC}/named.conf

log_info "named.conf создан в chroot"

# ============================================================================
# Создание файла прямой зоны
# ============================================================================
log_step "Создание прямой зоны в chroot..."

SERIAL=$(date +%Y%m%d01)

cat > ${CHROOT_VAR}/master/$DOMAIN_NAME.db << EOF
\$TTL 86400
@ IN SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL ; Serial
    3600 ; Refresh
    1800 ; Retry
    604800 ; Expire
    86400 ; Minimum TTL
)

; NS запись
@ IN NS hq-srv.$DOMAIN_NAME.

; A записи согласно Таблице 3
hq-rtr IN A $HQ_RTR_IP
br-rtr IN A $BR_RTR_IP
hq-srv IN A $HQ_SRV_IP
br-srv IN A $BR_SRV_IP
docker IN A $DOCKER_IP
web IN A $WEB_IP

EOF

# КРИТИЧНО: Владелец root:named как в задании!
chown root:named ${CHROOT_VAR}/master/$DOMAIN_NAME.db
chmod 0640 ${CHROOT_VAR}/master/$DOMAIN_NAME.db

log_info "Файл прямой зоны создан: ${CHROOT_VAR}/master/$DOMAIN_NAME.db"

# ============================================================================
# Создание файла обратной зоны
# ============================================================================
log_step "Создание обратной зоны в chroot..."

# Последние октеты IP-адресов для PTR записей
HQ_RTR_PTR=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)
HQ_SRV_PTR=$(echo "$HQ_SRV_IP" | cut -d'.' -f4)

cat > ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db << EOF
\$TTL 86400
@ IN SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL ; Serial
    3600 ; Refresh
    1800 ; Retry
    604800 ; Expire
    86400 ; Minimum TTL
)

; NS запись
@ IN NS hq-srv.$DOMAIN_NAME.

; PTR записи для HQ-RTR и HQ-SRV (Таблица 3)
$HQ_RTR_PTR IN PTR hq-rtr.$DOMAIN_NAME.
$HQ_SRV_PTR IN PTR hq-srv.$DOMAIN_NAME.

EOF

# КРИТИЧНО: Владелец root:named как в задании!
chown root:named ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db
chmod 0640 ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db

log_info "Файл обратной зоны создан: ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db"

# ============================================================================
# Создание стандартных зон в chroot
# ============================================================================
log_step "Создание стандартных зон в chroot..."

# named.localhost
if [ ! -f ${CHROOT_VAR}/named.localhost ]; then
    cat > ${CHROOT_VAR}/named.localhost << 'EOF'
$TTL 1D
@ IN SOA @ root.localhost. (
    1 ; Serial
    1H ; Refresh
    15M ; Retry
    1W ; Expire
    1D ; Minimum
)
    NS @
    A 127.0.0.1
EOF
fi

# named.loopback
if [ ! -f ${CHROOT_VAR}/named.loopback ]; then
    cat > ${CHROOT_VAR}/named.loopback << 'EOF'
$TTL 1D
@ IN SOA @ root.localhost. (
    1 ; Serial
    1H ; Refresh
    15M ; Retry
    1W ; Expire
    1D ; Minimum
)
    NS @
    PTR localhost.
EOF
fi

# named.root (корневые серверы)
if [ ! -f ${CHROOT_VAR}/named.root ]; then
    cat > ${CHROOT_VAR}/named.root << 'EOF'
. 3600000 NS a.root-servers.net.
a.root-servers.net. 3600000 A 198.41.0.4
. 3600000 NS b.root-servers.net.
b.root-servers.net. 3600000 A 199.9.14.201
. 3600000 NS c.root-servers.net.
c.root-servers.net. 3600000 A 192.33.4.12
. 3600000 NS d.root-servers.net.
d.root-servers.net. 3600000 A 199.7.91.13
. 3600000 NS e.root-servers.net.
e.root-servers.net. 3600000 A 192.203.230.10
. 3600000 NS f.root-servers.net.
f.root-servers.net. 3600000 A 192.5.5.241
EOF
fi

chown named:named ${CHROOT_VAR}/named.localhost
chown named:named ${CHROOT_VAR}/named.loopback
chown named:named ${CHROOT_VAR}/named.root

log_info "Стандартные зоны созданы в chroot"

# ============================================================================
# Финальные права доступа в chroot
# ============================================================================
log_step "Установка финальных прав в chroot..."

# Убеждаемся что named может писать в data и dynamic
chown named:named ${CHROOT_VAR}/data
chown named:named ${CHROOT_VAR}/dynamic
chmod 750 ${CHROOT_VAR}/data
chmod 750 ${CHROOT_VAR}/dynamic

# Создаём файл лога
touch ${CHROOT_VAR}/data/named.run 2>/dev/null || true
chown named:named ${CHROOT_VAR}/data/named.run 2>/dev/null || true

log_info "Права в chroot установлены"

# ============================================================================
# Обновление chroot (критически важно!)
# ============================================================================
log_step "Обновление chroot-окружения..."
update_chrooted named || true
log_info "Chroot-окружение обновлено"

# ============================================================================
# ПРОВЕРКА КОНФИГУРАЦИИ (ИСПРАВЛЕНО!)
# ============================================================================
log_step "Проверка конфигурации..."
echo ""

echo "=== named-checkconf ==="
# ИСПРАВЛЕНИЕ: разделяем chroot dir и путь внутри chroot
if named-checkconf -t ${CHROOT_DIR} /etc/named.conf; then
    log_info "Конфигурация валидна!"
else
    log_error "Ошибка в named.conf!"
    exit 1
fi

echo ""
echo "=== named-checkzone (прямая зона) ==="
# ИСПРАВЛЕНИЕ: правильный синтаксис для chroot
named-checkzone -t ${CHROOT_DIR} $DOMAIN_NAME /var/named/master/$DOMAIN_NAME.db

echo ""
echo "=== named-checkzone (обратная зона) ==="
# ИСПРАВЛЕНИЕ: правильный синтаксис для chroot
named-checkzone -t ${CHROOT_DIR} $REV_ZONE.in-addr.arpa /var/named/master/${DOMAIN_NAME}_rev.db

# ============================================================================
# Настройка firewall
# ============================================================================
log_step "Настройка firewall..."

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_info "Firewalld настроен"
fi

# iptables правила
iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

log_info "Firewall настроен"

# ============================================================================
# Настройка resolv.conf
# ============================================================================
log_step "Настройка /etc/resolv.conf..."

cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true

cat > /etc/resolv.conf << EOF
# DNS configuration for $DOMAIN_NAME
search $DOMAIN_NAME
nameserver 127.0.0.1
EOF

log_info "resolv.conf настроен"

# ============================================================================
# Запуск BIND
# ============================================================================
log_step "Запуск BIND..."

# Определяем имя сервиса
if systemctl list-unit-files | grep -q '^named.service'; then
    SERVICE="named"
elif systemctl list-unit-files | grep -q '^bind.service'; then
    SERVICE="bind"
else
    SERVICE="named"
fi

log_info "Используем сервис: $SERVICE"

# Включаем и запускаем
systemctl enable $SERVICE
systemctl restart $SERVICE
sleep 3

# Проверка статуса
echo ""
if systemctl is-active --quiet $SERVICE; then
    log_info "✓ BIND запущен успешно!"
else
    log_error "✗ BIND не запустился!"
    log_info "Диагностика:"
    systemctl status $SERVICE
    journalctl -xeu $SERVICE -n 20 --no-pager
    exit 1
fi

# ============================================================================
# Тестирование DNS
# ============================================================================
echo ""
log_step "Тестирование DNS..."
echo ""

# Тест прямого разрешения
log_info "Прямое разрешение:"
for host in hq-rtr br-rtr hq-srv br-srv docker web; do
    RESULT=$(dig @localhost $host.$DOMAIN_NAME +short 2>/dev/null)
    if [ -n "$RESULT" ]; then
        log_info "✓ $host.$DOMAIN_NAME -> $RESULT"
    else
        log_warn "✗ $host.$DOMAIN_NAME -> не найден"
    fi
done

# Тест обратного разрешения
echo ""
log_info "Обратное разрешение:"
for ip in $HQ_RTR_IP $HQ_SRV_IP; do
    RESULT=$(dig @localhost -x $ip +short 2>/dev/null)
    if [ -n "$RESULT" ]; then
        log_info "✓ $ip -> $RESULT"
    else
        log_warn "✗ $ip -> не найден"
    fi
done

# ============================================================================
# Завершение
# ============================================================================
echo ""
echo "============================================"
echo " Настройка DNS завершена!"
echo "============================================"
echo ""
echo "Полезные команды:"
echo "  systemctl status $SERVICE"
echo "  named-checkconf -t ${CHROOT_DIR} /etc/named.conf"
echo "  dig @localhost hq-srv.$DOMAIN_NAME"
echo "  dig @localhost -x $HQ_SRV_IP"
echo "  rndc status"
echo ""

log_info "Готово!"
