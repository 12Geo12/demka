#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script - EXAM READY VERSION
# Версия: 7.0 (ALL NETWORKS + FIREWALL)
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

log_header "DNS Infrastructure Setup Script (Exam Version)"

# ============================================================================
# ОЧИСТКА
# ============================================================================
log_step "=== ОЧИСТКА СТАРЫХ КОНФИГУРАЦИЙ ==="
echo ""
log_warn "ВНИМАНИЕ: Будут удалены все старые конфигурации DNS!"
read -p "Продолжить очистку? [y/N]: " clean_confirm
if [[ "$clean_confirm" =~ ^[Yy]$ ]]; then
    systemctl stop named 2>/dev/null || true
    systemctl stop bind 2>/dev/null || true
    
    rm -rf /var/lib/bind/etc/named.conf 2>/dev/null || true
    rm -rf /var/lib/bind/var/named/master/*.db 2>/dev/null || true
    rm -rf /var/lib/bind/var/named/data/* 2>/dev/null || true
    rm -rf /var/lib/bind/var/named/dynamic/* 2>/dev/null || true
    rm -f /etc/named.conf 2>/dev/null || true
    rm -f /etc/rndc.key 2>/dev/null || true
    
    log_info "Очистка завершена"
else
    log_error "Отменено пользователем"
    exit 1
fi

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Установка BIND..."

if [ -f /etc/altlinux-release ]; then
    apt-get update
    apt-get install -y bind bind-utils
    log_info "BIND установлен"
else
    log_error "Только ALT Linux поддерживается"
    exit 1
fi

# ============================================================================
# ПЕРЕМЕННЫЕ
# ============================================================================
CHROOT_DIR="/var/lib/bind"
CHROOT_ETC="${CHROOT_DIR}/etc"
CHROOT_VAR="${CHROOT_DIR}/var/named"

# ============================================================================
# АВТООПРЕДЕЛЕНИЕ IP
# ============================================================================
log_step "Автоопределение сетевых параметров..."
echo ""

LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d{1,3}(\.\d{1,3}){3}' | grep -v '127.0.0.1' | head -1)

if [ -z "$LOCAL_IP" ]; then
    log_error "Не удалось определить IP-адрес!"
    exit 1
fi

log_info "Обнаружен IP: $LOCAL_IP"

# Разбираем IP на октеты
IP_OCT1=$(echo "$LOCAL_IP" | cut -d'.' -f1)
IP_OCT2=$(echo "$LOCAL_IP" | cut -d'.' -f2)
IP_OCT3=$(echo "$LOCAL_IP" | cut -d'.' -f3)
IP_OCT4=$(echo "$LOCAL_IP" | cut -d'.' -f4)

log_info "Октеты IP: $IP_OCT1.$IP_OCT2.$IP_OCT3.$IP_OCT4"

SUBNET="${IP_OCT1}.${IP_OCT2}.${IP_OCT3}"
log_info "Локальная подсеть: ${SUBNET}.0/24"

# Обратная зона для ЛОКАЛЬНОЙ подсети
REV_ZONE="${IP_OCT3}.${IP_OCT2}.${IP_OCT1}"
log_info "Обратная зона: ${REV_ZONE}.in-addr.arpa"

HOSTNAME=$(hostname)
log_info "Имя хоста: $HOSTNAME"

# ============================================================================
# КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ (ДЛЯ ЭКЗАМЕНА)
# ============================================================================
log_header "Конфигурация DNS"
echo ""

# Стандартные значения для экзамена
DEFAULT_HQ_RTR="192.168.4.2"
DEFAULT_HQ_SRV="$LOCAL_IP"  # Текущий IP машины (HQ-SRV)
DEFAULT_BR_RTR="192.168.5.2"
DEFAULT_BR_SRV="192.168.6.2"
DEFAULT_DOCKER="172.16.5.1"
DEFAULT_WEB="172.16.6.1"
DEFAULT_DOMAIN="au-team.irpo"

read -p "Использовать стандартные значения для экзамена? [y/N]: " exam_choice

if [[ "$exam_choice" =~ ^[Yy]$ ]]; then
    log_info "ЭКЗАМЕНАЦИОННЫЙ РЕЖИМ"
    
    HQ_RTR_IP="$DEFAULT_HQ_RTR"
    HQ_SRV_IP="$DEFAULT_HQ_SRV"
    BR_RTR_IP="$DEFAULT_BR_RTR"
    BR_SRV_IP="$DEFAULT_BR_SRV"
    DOCKER_IP="$DEFAULT_DOCKER"
    WEB_IP="$DEFAULT_WEB"
    DOMAIN_NAME="$DEFAULT_DOMAIN"
    FWD1="77.88.8.8"
    FWD2="77.88.8.1"
    
    log_info "IP-адреса:"
    echo "   HQ-RTR: $HQ_RTR_IP (сеть 192.168.4.x)"
    echo "   HQ-SRV: $HQ_SRV_IP (сеть ${SUBNET}.x)"
    echo "   BR-RTR: $BR_RTR_IP (сеть 192.168.5.x)"
    echo "   BR-SRV: $BR_SRV_IP (сеть 192.168.6.x)"
    echo "   Docker: $DOCKER_IP (сеть 172.16.5.x)"
    echo "   WEB:    $WEB_IP (сеть 172.16.6.x)"
else
    log_info "РУЧНОЙ РЕЖИМ"
    
    read -p "IP HQ-RTR [$DEFAULT_HQ_RTR]: " HQ_RTR_IP
    HQ_RTR_IP=${HQ_RTR_IP:-"$DEFAULT_HQ_RTR"}
    
    read -p "IP HQ-SRV [$DEFAULT_HQ_SRV]: " HQ_SRV_IP
    HQ_SRV_IP=${HQ_SRV_IP:-"$DEFAULT_HQ_SRV"}
    
    read -p "IP BR-RTR [$DEFAULT_BR_RTR]: " BR_RTR_IP
    BR_RTR_IP=${BR_RTR_IP:-"$DEFAULT_BR_RTR"}
    
    read -p "IP BR-SRV [$DEFAULT_BR_SRV]: " BR_SRV_IP
    BR_SRV_IP=${BR_SRV_IP:-"$DEFAULT_BR_SRV"}
    
    read -p "IP Docker [$DEFAULT_DOCKER]: " DOCKER_IP
    DOCKER_IP=${DOCKER_IP:-"$DEFAULT_DOCKER"}
    
    read -p "IP WEB [$DEFAULT_WEB]: " WEB_IP
    WEB_IP=${WEB_IP:-"$DEFAULT_WEB"}
    
    read -p "Домен [$DEFAULT_DOMAIN]: " DOMAIN_NAME
    DOMAIN_NAME=${DOMAIN_NAME:-"$DEFAULT_DOMAIN"}
    
    echo ""
    log_info "Forwarders:"
    echo "1) Яндекс (77.88.8.8, 77.88.8.1)"
    echo "2) Google (8.8.8.8, 8.8.4.4)"
    read -p "Выбор [1]: " fwd_choice
    case $fwd_choice in
        2) FWD1="8.8.8.8"; FWD2="8.8.4.4" ;;
        *) FWD1="77.88.8.8"; FWD2="77.88.8.1" ;;
    esac
fi

# ============================================================================
# ВЫЧИСЛЕНИЕ ВСЕХ ОБРАТНЫХ ЗОН
# ============================================================================
# Извлекаем сети для всех устройств
HQ_RTR_NET=$(echo "$HQ_RTR_IP" | cut -d'.' -f1-3)
HQ_RTR_OCT1=$(echo "$HQ_RTR_NET" | cut -d'.' -f1)
HQ_RTR_OCT2=$(echo "$HQ_RTR_NET" | cut -d'.' -f2)
HQ_RTR_OCT3=$(echo "$HQ_RTR_NET" | cut -d'.' -f3)
HQ_RTR_REV="${HQ_RTR_OCT3}.${HQ_RTR_OCT2}.${HQ_RTR_OCT1}"

BR_RTR_NET=$(echo "$BR_RTR_IP" | cut -d'.' -f1-3)
BR_RTR_OCT1=$(echo "$BR_RTR_NET" | cut -d'.' -f1)
BR_RTR_OCT2=$(echo "$BR_RTR_NET" | cut -d'.' -f2)
BR_RTR_OCT3=$(echo "$BR_RTR_NET" | cut -d'.' -f3)
BR_RTR_REV="${BR_RTR_OCT3}.${BR_RTR_OCT2}.${BR_RTR_OCT1}"

BR_SRV_NET=$(echo "$BR_SRV_IP" | cut -d'.' -f1-3)
BR_SRV_OCT1=$(echo "$BR_SRV_NET" | cut -d'.' -f1)
BR_SRV_OCT2=$(echo "$BR_SRV_NET" | cut -d'.' -f2)
BR_SRV_OCT3=$(echo "$BR_SRV_NET" | cut -d'.' -f3)
BR_SRV_REV="${BR_SRV_OCT3}.${BR_SRV_OCT2}.${BR_SRV_OCT1}"

log_info "Обратные зоны:"
echo "   Локальная (${SUBNET}.x): ${REV_ZONE}.in-addr.arpa"
echo "   HQ-RTR (${HQ_RTR_NET}.x): ${HQ_RTR_REV}.in-addr.arpa"
echo "   BR-RTR (${BR_RTR_NET}.x): ${BR_RTR_REV}.in-addr.arpa"
echo "   BR-SRV (${BR_SRV_NET}.x): ${BR_SRV_REV}.in-addr.arpa"

# ============================================================================
# СВОДКА
# ============================================================================
log_header "Итоговая конфигурация"
echo "Домен:         $DOMAIN_NAME"
echo "HQ-RTR:        $HQ_RTR_IP"
echo "HQ-SRV:        $HQ_SRV_IP"
echo "BR-RTR:        $BR_RTR_IP"
echo "BR-SRV:        $BR_SRV_IP"
echo "Docker:        $DOCKER_IP"
echo "WEB:           $WEB_IP"
echo "Forwarders:    $FWD1, $FWD2"
echo ""

read -p "Продолжить? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_error "Отменено"
    exit 1
fi

# ============================================================================
# СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================================================
log_step "Создание структуры директорий..."

mkdir -p ${CHROOT_ETC}
mkdir -p ${CHROOT_VAR}/{master,data,dynamic,slaves}

chown -R named:named ${CHROOT_DIR}
chmod 750 ${CHROOT_VAR}
chmod 750 ${CHROOT_VAR}/master
chmod 750 ${CHROOT_VAR}/data
chmod 750 ${CHROOT_VAR}/dynamic

log_info "Директории созданы"

# ============================================================================
# RNDC KEY
# ============================================================================
log_step "Генерация rndc ключа..."

if [ ! -f /etc/rndc.key ]; then
    rndc-confgen -a -q 2>/dev/null || true
fi

if [ -f /etc/rndc.key ]; then
    chown root:named /etc/rndc.key
    chmod 640 /etc/rndc.key
    cp /etc/rndc.key ${CHROOT_ETC}/rndc.key
    chown named:named ${CHROOT_ETC}/rndc.key
    chmod 640 ${CHROOT_ETC}/rndc.key
    log_info "rndc.key создан"
fi

# ============================================================================
# NAMED.CONF (СО ВСЕМИ ОБРАТНЫМИ ЗОНАМИ)
# ============================================================================
log_step "Создание named.conf..."

cat > ${CHROOT_ETC}/named.conf << EOF
// DNS Configuration for $DOMAIN_NAME
// Exam Ready - All reverse zones included

options {
    listen-on port 53 { 127.0.0.1; $HQ_SRV_IP; any; };
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

// Обратная зона - ЛОКАЛЬНАЯ СЕТЬ
zone "${REV_ZONE}.in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_rev.db";
    allow-update { none; };
};

// Обратная зона - HQ-RTR (192.168.4.x)
zone "${HQ_RTR_REV}.in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_hq_rtr_rev.db";
    allow-update { none; };
};

// Обратная зона - BR-RTR (192.168.5.x)
zone "${BR_RTR_REV}.in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_br_rtr_rev.db";
    allow-update { none; };
};

// Обратная зона - BR-SRV (192.168.6.x)
zone "${BR_SRV_REV}.in-addr.arpa" IN {
    type master;
    file "master/${DOMAIN_NAME}_br_srv_rev.db";
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

ln -sf ${CHROOT_ETC}/named.conf /etc/named.conf
ln -sf ${CHROOT_ETC}/rndc.key /etc/rndc.key

log_info "named.conf создан со всеми обратными зонами"

# ============================================================================
# ПРЯМАЯ ЗОНА
# ============================================================================
log_step "Создание прямой зоны..."

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

@ IN NS hq-srv.$DOMAIN_NAME.

hq-rtr IN A $HQ_RTR_IP
br-rtr IN A $BR_RTR_IP
hq-srv IN A $HQ_SRV_IP
br-srv IN A $BR_SRV_IP
docker IN A $DOCKER_IP
web IN A $WEB_IP
EOF

chown root:named ${CHROOT_VAR}/master/$DOMAIN_NAME.db
chmod 0640 ${CHROOT_VAR}/master/$DOMAIN_NAME.db

log_info "Прямая зона создана"

# ============================================================================
# ОБРАТНАЯ ЗОНА - ЛОКАЛЬНАЯ
# ============================================================================
log_step "Создание обратной зоны (локальная)..."

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

@ IN NS hq-srv.$DOMAIN_NAME.

$HQ_SRV_PTR IN PTR hq-srv.$DOMAIN_NAME.
EOF

chown root:named ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db
chmod 0640 ${CHROOT_VAR}/master/${DOMAIN_NAME}_rev.db

log_info "Локальная обратная зона создана"

# ============================================================================
# ОБРАТНАЯ ЗОНА - HQ-RTR
# ============================================================================
log_step "Создание обратной зоны (HQ-RTR)..."

HQ_RTR_PTR=$(echo "$HQ_RTR_IP" | cut -d'.' -f4)

cat > ${CHROOT_VAR}/master/${DOMAIN_NAME}_hq_rtr_rev.db << EOF
\$TTL 86400
@ IN SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL ; Serial
    3600 ; Refresh
    1800 ; Retry
    604800 ; Expire
    86400 ; Minimum TTL
)

@ IN NS hq-srv.$DOMAIN_NAME.

$HQ_RTR_PTR IN PTR hq-rtr.$DOMAIN_NAME.
EOF

chown root:named ${CHROOT_VAR}/master/${DOMAIN_NAME}_hq_rtr_rev.db
chmod 0640 ${CHROOT_VAR}/master/${DOMAIN_NAME}_hq_rtr_rev.db

log_info "Обратная зона HQ-RTR создана"

# ============================================================================
# ОБРАТНАЯ ЗОНА - BR-RTR
# ============================================================================
log_step "Создание обратной зоны (BR-RTR)..."

BR_RTR_PTR=$(echo "$BR_RTR_IP" | cut -d'.' -f4)

cat > ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_rtr_rev.db << EOF
\$TTL 86400
@ IN SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL ; Serial
    3600 ; Refresh
    1800 ; Retry
    604800 ; Expire
    86400 ; Minimum TTL
)

@ IN NS hq-srv.$DOMAIN_NAME.

$BR_RTR_PTR IN PTR br-rtr.$DOMAIN_NAME.
EOF

chown root:named ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_rtr_rev.db
chmod 0640 ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_rtr_rev.db

log_info "Обратная зона BR-RTR создана"

# ============================================================================
# ОБРАТНАЯ ЗОНА - BR-SRV
# ============================================================================
log_step "Создание обратной зоны (BR-SRV)..."

BR_SRV_PTR=$(echo "$BR_SRV_IP" | cut -d'.' -f4)

cat > ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_srv_rev.db << EOF
\$TTL 86400
@ IN SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL ; Serial
    3600 ; Refresh
    1800 ; Retry
    604800 ; Expire
    86400 ; Minimum TTL
)

@ IN NS hq-srv.$DOMAIN_NAME.

$BR_SRV_PTR IN PTR br-srv.$DOMAIN_NAME.
EOF

chown root:named ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_srv_rev.db
chmod 0640 ${CHROOT_VAR}/master/${DOMAIN_NAME}_br_srv_rev.db

log_info "Обратная зона BR-SRV создана"

# ============================================================================
# СТАНДАРТНЫЕ ЗОНЫ
# ============================================================================
log_step "Создание стандартных зон..."

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

log_info "Стандартные зоны созданы"

# ============================================================================
# ПРАВА ДОСТУПА
# ============================================================================
log_step "Установка прав доступа..."

chown named:named ${CHROOT_VAR}/data
chown named:named ${CHROOT_VAR}/dynamic
chmod 750 ${CHROOT_VAR}/data
chmod 750 ${CHROOT_VAR}/dynamic

touch ${CHROOT_VAR}/data/named.run 2>/dev/null || true
chown named:named ${CHROOT_VAR}/data/named.run 2>/dev/null || true

log_info "Права установлены"

# ============================================================================
# ОБНОВЛЕНИЕ CHROOT
# ============================================================================
log_step "Обновление chroot..."
update_chrooted named || true
log_info "Chroot обновлен"

# ============================================================================
# НАСТРОЙКА FIREWALL
# ============================================================================
log_step "Открытие портов firewall..."

# Открываем UDP порт 53
iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || {
    iptables -I INPUT -p udp --dport 53 -j ACCEPT
    log_info "Открыт UDP порт 53"
}

# Открываем TCP порт 53
iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || {
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT
    log_info "Открыт TCP порт 53"
}

# Сохраняем правила
if command -v service &> /dev/null; then
    service iptables save 2>/dev/null || true
    log_info "Правила firewall сохранены"
fi

log_info "Firewall настроен"

# ============================================================================
# RESOLV.CONF
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
# ПРОВЕРКА КОНФИГУРАЦИИ
# ============================================================================
log_step "Проверка конфигурации..."
echo ""

echo "=== named-checkconf ==="
if named-checkconf -t ${CHROOT_DIR} /etc/named.conf; then
    log_info "✓ named.conf валиден!"
else
    log_error "✗ Ошибка в named.conf!"
    cat ${CHROOT_ETC}/named.conf
    exit 1
fi

echo ""
echo "=== named-checkzone (прямая зона) ==="
named-checkzone -t ${CHROOT_DIR} $DOMAIN_NAME /var/named/master/$DOMAIN_NAME.db

echo ""
echo "=== named-checkzone (обратные зоны) ==="
named-checkzone -t ${CHROOT_DIR} ${REV_ZONE}.in-addr.arpa /var/named/master/${DOMAIN_NAME}_rev.db
named-checkzone -t ${CHROOT_DIR} ${HQ_RTR_REV}.in-addr.arpa /var/named/master/${DOMAIN_NAME}_hq_rtr_rev.db
named-checkzone -t ${CHROOT_DIR} ${BR_RTR_REV}.in-addr.arpa /var/named/master/${DOMAIN_NAME}_br_rtr_rev.db
named-checkzone -t ${CHROOT_DIR} ${BR_SRV_REV}.in-addr.arpa /var/named/master/${DOMAIN_NAME}_br_srv_rev.db

log_info "✓ Все зоны валидны!"

# ============================================================================
# ЗАПУСК BIND
# ============================================================================
log_step "Запуск BIND..."

if systemctl list-unit-files | grep -q '^named.service'; then
    SERVICE="named"
elif systemctl list-unit-files | grep -q '^bind.service'; then
    SERVICE="bind"
else
    SERVICE="named"
fi

log_info "Сервис: $SERVICE"

systemctl enable $SERVICE
systemctl restart $SERVICE
sleep 3

echo ""
if systemctl is-active --quiet $SERVICE; then
    log_info "✓ BIND запущен!"
else
    log_error "✗ BIND не запустился!"
    systemctl status $SERVICE
    journalctl -xeu $SERVICE -n 20 --no-pager
    exit 1
fi

# ============================================================================
# ТЕСТИРОВАНИЕ
# ============================================================================
log_step "Тестирование DNS..."
echo ""

log_info "Прямое разрешение:"
for host in hq-rtr br-rtr hq-srv br-srv docker web; do
    RESULT=$(dig @localhost $host.$DOMAIN_NAME +short 2>/dev/null)
    if [ -n "$RESULT" ]; then
        log_info "✓ $host.$DOMAIN_NAME -> $RESULT"
    else
        log_warn "✗ $host.$DOMAIN_NAME -> не найден"
    fi
done

echo ""
log_info "Обратное разрешение:"
for ip in $HQ_RTR_IP $HQ_SRV_IP $BR_RTR_IP $BR_SRV_IP; do
    RESULT=$(dig @localhost -x $ip +short 2>/dev/null)
    if [ -n "$RESULT" ]; then
        log_info "✓ $ip -> $RESULT"
    else
        log_warn "✗ $ip -> не найден"
    fi
done

# ============================================================================
# ИТОГИ
# ============================================================================
log_header "НАСТРОЙКА ЗАВЕРШЕНА!"

echo "✅ DNS сервер настроен и работает!"
echo ""
echo "📋 КОНФИГУРАЦИЯ:"
echo "   Домен:           $DOMAIN_NAME"
echo "   DNS сервер:      $HQ_SRV_IP"
echo "   Forwarders:      $FWD1, $FWD2"
echo ""
echo " ФАЙЛЫ:"
echo "   Главный конфиг:  /var/lib/bind/etc/named.conf"
echo "   Прямая зона:     /var/lib/bind/var/named/master/$DOMAIN_NAME.db"
echo "   Обратные зоны:   /var/lib/bind/var/named/master/*_rev.db"
echo ""
echo "🔥 FIREWALL:"
echo "   ✅ UDP порт 53 открыт"
echo "   ✅ TCP порт 53 открыт"
echo ""
echo "🔧 КОМАНДЫ:"
echo "   systemctl status $SERVICE"
echo "   dig @localhost hq-srv.$DOMAIN_NAME +short"
echo "   dig @192.168.10.10 hq-rtr.$DOMAIN_NAME +short (с другой машины)"
echo ""
echo "📝 DNS ЗАПИСИ:"
echo "   hq-rtr.$DOMAIN_NAME -> $HQ_RTR_IP"
echo "   hq-srv.$DOMAIN_NAME -> $HQ_SRV_IP"
echo "   br-rtr.$DOMAIN_NAME -> $BR_RTR_IP"
echo "   br-srv.$DOMAIN_NAME -> $BR_SRV_IP"
echo "   docker.$DOMAIN_NAME -> $DOCKER_IP"
echo "   web.$DOMAIN_NAME    -> $WEB_IP"
echo ""
echo "🔄 ОБРАТНЫЕ ЗОНЫ:"
echo "   ${REV_ZONE}.in-addr.arpa (локальная)"
echo "   ${HQ_RTR_REV}.in-addr.arpa (HQ-RTR)"
echo "   ${BR_RTR_REV}.in-addr.arpa (BR-RTR)"
echo "   ${BR_SRV_REV}.in-addr.arpa (BR-SRV)"
echo ""

log_info "Готово к экзамену!"
