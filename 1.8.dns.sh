#!/bin/bash
# ============================================================================
# Скрипт настройки DNS сервера (BIND) для домена au-team.irpo
# ВЕРСИЯ ДЛЯ ALT LINUX
# ОБНОВЛЁННАЯ ВЕРСИЯ v2.0
# ============================================================================

set -e
set -o pipefail

# ============================================================================
# ОБРАБОТКА СИГНАЛОВ
# ============================================================================
cleanup() {
    log_error "Скрипт прерван! Выполняю очистку..."
    # Восстанавливаем resolv.conf если есть бэкап
    if [ -f /etc/resolv.conf.backup.$$ ]; then
        mv /etc/resolv.conf.backup.$$ /etc/resolv.conf 2>/dev/null || true
    fi
    exit 130
}

trap cleanup INT TERM

# ============================================================================
# ПРОВЕРКА ПРАВ ROOT
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[ОШИБКА]\033[0m Этот скрипт требует прав root!"
    echo "Запустите: sudo bash $0"
    exit 1
fi

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Функции вывода
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }

# ============================================================================
# ФУНКЦИЯ ВАЛИДАЦИИ IP-АДРЕСА
# ============================================================================
validate_ip() {
    local ip=$1
    local valid_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if ! [[ $ip =~ $valid_regex ]]; then
        return 1
    fi
    
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if ((octet < 0 || octet > 255)); then
            return 1
        fi
    done
    
    return 0
}

# ============================================================================
# ФУНКЦИЯ ГЕНЕРАЦИИ УНИКАЛЬНОГО SERIAL
# ============================================================================
generate_serial() {
    local base_date=$(date +%Y%m%d)
    local counter=1
    
    # Если файл существует, проверяем serial
    if [ -f "$1" ]; then
        local old_serial=$(grep -oP 'SOA.*?\(\s*\K[0-9]+' "$1" 2>/dev/null | head -1)
        if [[ "$old_serial" == ${base_date}* ]]; then
            # Тот же день - инкрементируем
            counter=$((10#${old_serial: -2} + 1))
            [ $counter -gt 99 ] && counter=99
        fi
    fi
    
    printf "%s%02d" "$base_date" "$counter"
}

# ============================================================================
# ФУНКЦИЯ ОПРЕДЕЛЕНИЯ ПУТЕЙ BIND ДЛЯ ALT LINUX
# ============================================================================
detect_bind_paths() {
    log_info "Определение путей BIND..."
    
    # Определяем основной конфиг
    if [ -f /etc/named.conf ]; then
        NAMED_CONF="/etc/named.conf"
        CHROOT_ETC="/etc"
    elif [ -f /etc/bind/named.conf ]; then
        NAMED_CONF="/etc/bind/named.conf"
        CHROOT_ETC="/etc/bind"
    elif [ -d /etc/named ]; then
        NAMED_CONF="/etc/named/named.conf"
        CHROOT_ETC="/etc/named"
    else
        # Создаём стандартную структуру ALT Linux
        NAMED_CONF="/etc/named.conf"
        CHROOT_ETC="/etc"
    fi
    
    # Определяем директорию зон
    if [ -d /var/named ]; then
        CHROOT="/var/named"
    elif [ -d /var/lib/named ]; then
        CHROOT="/var/lib/named"
    elif [ -d /var/lib/bind ]; then
        CHROOT="/var/lib/bind"
    else
        CHROOT="/var/named"
    fi
    
    log_info "Конфиг: $NAMED_CONF"
    log_info "Зоны: $CHROOT"
    log_info "CHROOT_ETC: $CHROOT_ETC"
}

# ============================================================================
# ФУНКЦИЯ ОПРЕДЕЛЕНИЯ ПАКЕТНОГО МЕНЕДЖЕРА
# ============================================================================
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        # Проверяем, это ALT Linux или Debian/Ubuntu
        if [ -f /etc/altlinux-release ] || rpm -q apt &>/dev/null 2>&1; then
            PKG_MGR="apt-get"
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update"
            log_info "Обнаружен ALT Linux (apt-get)"
        else
            PKG_MGR="apt-get"
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update"
            log_info "Обнаружен Debian/Ubuntu (apt-get)"
        fi
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache"
        log_info "Обнаружен Fedora/RHEL8+ (dnf)"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
        log_info "Обнаружен CentOS/RHEL7 (yum)"
    else
        log_error "Пакетный менеджер не найден!"
        exit 1
    fi
}

# ============================================================================
# ОПРЕДЕЛЕНИЕ ЛОКАЛЬНОГО IP
# ============================================================================
detect_local_ip() {
    LOCAL_IP=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)
    
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    fi
    
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -z "$LOCAL_IP" ]; then
        log_warn "Не удалось автоматически определить IP адрес"
        LOCAL_IP="192.168.1.10"
    fi
    
    # Формируем дефолтный IP для HQ-SRV
    DEFAULT_HQ_SRV=$(echo "$LOCAL_IP" | awk -F'.' '{print $1"."$2"."$3".10"}')
}

# ============================================================================
# НАЧАЛО КОНФИГУРАЦИИ
# ============================================================================
log_step "Запуск настройки DNS сервера BIND"
echo ""

detect_bind_paths
detect_package_manager
detect_local_ip

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================
log_step "Конфигурация DNS"
echo ""

DEFAULT_HQ_RTR="192.168.4.2"
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
else
    log_info "РУЧНОЙ РЕЖИМ"
    
    # HQ-RTR с валидацией
    while true; do
        read -p "IP HQ-RTR [$DEFAULT_HQ_RTR]: " HQ_RTR_IP
        HQ_RTR_IP=${HQ_RTR_IP:-"$DEFAULT_HQ_RTR"}
        if validate_ip "$HQ_RTR_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: 192.168.4.2"
        fi
    done
    
    # HQ-SRV с валидацией
    while true; do
        read -p "IP HQ-SRV [$DEFAULT_HQ_SRV]: " HQ_SRV_IP
        HQ_SRV_IP=${HQ_SRV_IP:-"$DEFAULT_HQ_SRV"}
        if validate_ip "$HQ_SRV_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: $DEFAULT_HQ_SRV"
        fi
    done
    
    # BR-RTR с валидацией
    while true; do
        read -p "IP BR-RTR [$DEFAULT_BR_RTR]: " BR_RTR_IP
        BR_RTR_IP=${BR_RTR_IP:-"$DEFAULT_BR_RTR"}
        if validate_ip "$BR_RTR_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: 192.168.5.2"
        fi
    done
    
    # BR-SRV с валидацией
    while true; do
        read -p "IP BR-SRV [$DEFAULT_BR_SRV]: " BR_SRV_IP
        BR_SRV_IP=${BR_SRV_IP:-"$DEFAULT_BR_SRV"}
        if validate_ip "$BR_SRV_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: 192.168.6.2"
        fi
    done
    
    # Docker с валидацией
    while true; do
        read -p "IP Docker [$DEFAULT_DOCKER]: " DOCKER_IP
        DOCKER_IP=${DOCKER_IP:-"$DEFAULT_DOCKER"}
        if validate_ip "$DOCKER_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: 172.16.5.1"
        fi
    done
    
    # WEB с валидацией
    while true; do
        read -p "IP WEB [$DEFAULT_WEB]: " WEB_IP
        WEB_IP=${WEB_IP:-"$DEFAULT_WEB"}
        if validate_ip "$WEB_IP"; then
            break
        else
            log_error "Неверный формат IP-адреса! Пример: 172.16.6.1"
        fi
    done
    
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

# Генерируем обратные зоны
REV_ZONE=$(echo "$HQ_SRV_IP" | awk -F'.' '{print $3"."$2"."$1}')
HQ_RTR_REV=$(echo "$HQ_RTR_IP" | awk -F'.' '{print $3"."$2"."$1}')
BR_RTR_REV=$(echo "$BR_RTR_IP" | awk -F'.' '{print $3"."$2"."$1}')
BR_SRV_REV=$(echo "$BR_SRV_IP" | awk -F'.' '{print $3"."$2"."$1}')

# Вывод конфигурации
echo ""
log_step "Итоговая конфигурация"
echo "=============================================="
echo "Домен: $DOMAIN_NAME"
echo "HQ-RTR: $HQ_RTR_IP"
echo "HQ-SRV: $HQ_SRV_IP"
echo "BR-RTR: $BR_RTR_IP"
echo "BR-SRV: $BR_SRV_IP"
echo "Docker: $DOCKER_IP"
echo "WEB: $WEB_IP"
echo "Forwarders: $FWD1, $FWD2"
echo "=============================================="
echo ""

read -p "Продолжить? [Y/n]: " continue_choice
if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
    log_warn "Отменено пользователем"
    exit 0
fi

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Установка пакетов..."

$PKG_UPDATE || log_warn "Обновление репозиториев завершилось с предупреждением"

log_info "Установка BIND и firewalld..."
$PKG_INSTALL bind bind-utils firewalld || {
    # Пробуем альтернативные названия пакетов
    log_warn "Пробую альтернативные названия пакетов..."
    $PKG_INSTALL bind9 bind9utils firewalld 2>/dev/null || {
        log_error "Ошибка установки пакетов!"
        exit 1
    }
}

log_success "Пакеты установлены"

# ============================================================================
# СОЗДАНИЕ СТРУКТУРЫ ДИРЕКТОРИЙ
# ============================================================================
log_step "Создание структуры директорий..."

mkdir -p ${CHROOT}/master
mkdir -p ${CHROOT}/data
mkdir -p ${CHROOT}/dynamic
mkdir -p ${CHROOT}/slaves
mkdir -p ${CHROOT_ETC}

log_success "Директории созданы"

# ============================================================================
# ГЕНЕРАЦИЯ КЛЮЧЕЙ
# ============================================================================
log_step "Генерация rndc ключа..."

if command -v rndc-confgen &> /dev/null; then
    if ! rndc-confgen -a -r /dev/urandom &>/dev/null; then
        log_warn "rndc-confgen не сработал, создаю вручную..."
        cat > /etc/rndc.key << EOF
key "rndc-key" {
    algorithm hmac-sha256;
    secret "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)";
};
EOF
        chmod 640 /etc/rndc.key
    fi
else
    log_warn "rndc-confgen не найден, создаю ключ вручную..."
    cat > /etc/rndc.key << EOF
key "rndc-key" {
    algorithm hmac-sha256;
    secret "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)";
};
EOF
    chmod 640 /etc/rndc.key
fi

log_success "rndc.key создан"
cp /etc/rndc.key ${CHROOT}/etc/rndc.key 2>/dev/null || true

# ============================================================================
# ЗАГРУЗКА NAMED.ROOT
# ============================================================================
log_step "Загрузка корневых DNS серверов..."

NAMED_ROOT="${CHROOT}/named.root"
if command -v curl &> /dev/null; then
    if curl -sS --connect-timeout 10 https://www.internic.net/domain/named.root -o "$NAMED_ROOT" 2>/dev/null; then
        log_success "named.root загружен из Интернета"
    else
        log_warn "Не удалось загрузить named.root, использую минимальную версию"
        cat > "$NAMED_ROOT" << 'EOF'
.                        3600000      NS    a.root-servers.net.
a.root-servers.net.      3600000      A     198.41.0.4
.                        3600000      NS    b.root-servers.net.
b.root-servers.net.      3600000      A     199.9.14.201
.                        3600000      NS    c.root-servers.net.
c.root-servers.net.      3600000      A     192.33.4.12
.                        3600000      NS    d.root-servers.net.
d.root-servers.net.      3600000      A     199.7.91.13
.                        3600000      NS    e.root-servers.net.
e.root-servers.net.      3600000      A     192.203.230.10
.                        3600000      NS    f.root-servers.net.
f.root-servers.net.      3600000      A     192.5.5.241
.                        3600000      NS    g.root-servers.net.
g.root-servers.net.      3600000      A     192.112.36.4
.                        3600000      NS    h.root-servers.net.
h.root-servers.net.      3600000      A     198.97.190.53
.                        3600000      NS    i.root-servers.net.
i.root-servers.net.      3600000      A     192.36.148.17
.                        3600000      NS    j.root-servers.net.
j.root-servers.net.      3600000      A     192.58.128.30
.                        3600000      NS    k.root-servers.net.
k.root-servers.net.      3600000      A     193.0.14.129
.                        3600000      NS    l.root-servers.net.
l.root-servers.net.      3600000      A     199.7.83.42
.                        3600000      NS    m.root-servers.net.
m.root-servers.net.      3600000      A     202.12.27.33
EOF
    fi
else
    log_warn "curl не найден, использую встроенный named.root"
    cat > "$NAMED_ROOT" << 'EOF'
.                        3600000      NS    a.root-servers.net.
a.root-servers.net.      3600000      A     198.41.0.4
.                        3600000      NS    b.root-servers.net.
b.root-servers.net.      3600000      A     199.9.14.201
EOF
fi

# ============================================================================
# СОЗДАНИЕ NAMED.CONF С ПРОВЕРКОЙ НА ДУБЛИРОВАНИЕ ЗОН
# ============================================================================
log_step "Создание named.conf..."

# Резервное копирование существующего конфига
if [ -f "$NAMED_CONF" ]; then
    cp "$NAMED_CONF" "${NAMED_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
    log_info "Создана резервная копия: ${NAMED_CONF}.backup.*"
fi

# Создаем массив для отслеживания уникальных зон
declare -A REVERSE_ZONES_ADDED

# Генерируем serial
SERIAL=$(generate_serial "${CHROOT}/master/${DOMAIN_NAME}.db")

cat > ${CHROOT_ETC}/named.conf << EOF
// DNS Configuration for $DOMAIN_NAME
// Generated: $(date)
// Hostname: $(hostname)

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
    
    // Ограничение размера кэша
    max-cache-size 256M;
    max-cache-ttl 604800;
    max-ncache-ttl 10800;
};

logging {
    channel default_debug {
        file "data/named.run" versions 3 size 5m;
        severity dynamic;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    
    channel default_log {
        file "data/named.log" versions 3 size 5m;
        severity info;
        print-time yes;
    };
    
    category default { default_log; };
    category queries { default_log; };
};

include "/etc/rndc.key";

controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

zone "$DOMAIN_NAME" IN {
    type master;
    file "master/$DOMAIN_NAME.db";
    allow-update { none; };
};

EOF

# Функция для добавления уникальных обратных зон
add_reverse_zone() {
    local zone_name=$1
    local zone_file=$2
    local zone_desc=$3
    
    # Проверяем на дублирование
    if [[ -n "${REVERSE_ZONES_ADDED[$zone_name]}" ]]; then
        log_warn "Пропускаем дублирующуюся зону: ${zone_name}.in-addr.arpa ($zone_desc)"
        return
    fi
    
    # Добавляем зону
    REVERSE_ZONES_ADDED[$zone_name]=1
    
    cat >> ${CHROOT_ETC}/named.conf << EOF

zone "${zone_name}.in-addr.arpa" IN {
    type master;
    file "master/${zone_file}";
    allow-update { none; };
};
EOF
    log_info "Добавлена обратная зона: ${zone_name}.in-addr.arpa ($zone_desc)"
}

# Добавляем обратные зоны с проверкой на дублирование
add_reverse_zone "$REV_ZONE" "${DOMAIN_NAME}_rev.db" "Локальная сеть (HQ-SRV)"
add_reverse_zone "$HQ_RTR_REV" "${DOMAIN_NAME}_hq_rtr_rev.db" "HQ-RTR"
add_reverse_zone "$BR_RTR_REV" "${DOMAIN_NAME}_br_rtr_rev.db" "BR-RTR"
add_reverse_zone "$BR_SRV_REV" "${DOMAIN_NAME}_br_srv_rev.db" "BR-SRV"

# Добавляем стандартные зоны
cat >> ${CHROOT_ETC}/named.conf << EOF

zone "localhost" IN {
    type master;
    file "named.localhost";
    allow-update { none; };
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "named.loopback";
    allow-update { none; };
};

zone "." IN {
    type hint;
    file "named.root";
};
EOF

# Если конфиг отличается от /etc/named.conf, создаём симлинк или копию
if [ "$NAMED_CONF" != "${CHROOT_ETC}/named.conf" ] && [ ! -L "$NAMED_CONF" ]; then
    cp ${CHROOT_ETC}/named.conf "$NAMED_CONF"
    log_info "Конфиг скопирован в $NAMED_CONF"
fi

log_success "named.conf создан"

# ============================================================================
# СОЗДАНИЕ ПРЯМОЙ ЗОНЫ
# ============================================================================
log_step "Создание прямой зоны..."

cat > ${CHROOT}/master/$DOMAIN_NAME.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL      ; Serial
    3600         ; Refresh
    1800         ; Retry
    604800       ; Expire
    86400        ; Minimum TTL
)

@       IN  NS      hq-srv.$DOMAIN_NAME.

hq-rtr  IN  A       $HQ_RTR_IP
br-rtr  IN  A       $BR_RTR_IP
hq-srv  IN  A       $HQ_SRV_IP
br-srv  IN  A       $BR_SRV_IP
docker  IN  A       $DOCKER_IP
web     IN  A       $WEB_IP

; Алиасы
ns      IN  CNAME   hq-srv
www     IN  CNAME   web
EOF

log_success "Прямая зона создана (Serial: $SERIAL)"

# ============================================================================
# СОЗДАНИЕ ОБРАТНЫХ ЗОН
# ============================================================================
log_step "Создание обратных зон..."

# Локальная обратная зона
cat > ${CHROOT}/master/${DOMAIN_NAME}_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL      ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$HQ_SRV_IP" | awk -F'.' '{print $4}')   IN  PTR hq-srv.$DOMAIN_NAME.
EOF

log_success "Обратная зона (локальная) создана"

# Обратная зона HQ-RTR
cat > ${CHROOT}/master/${DOMAIN_NAME}_hq_rtr_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL      ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$HQ_RTR_IP" | awk -F'.' '{print $4}')   IN  PTR hq-rtr.$DOMAIN_NAME.
EOF

log_success "Обратная зона (HQ-RTR) создана"

# Обратная зона BR-RTR
cat > ${CHROOT}/master/${DOMAIN_NAME}_br_rtr_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL      ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$BR_RTR_IP" | awk -F'.' '{print $4}')   IN  PTR br-rtr.$DOMAIN_NAME.
EOF

log_success "Обратная зона (BR-RTR) создана"

# Обратная зона BR-SRV
cat > ${CHROOT}/master/${DOMAIN_NAME}_br_srv_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $SERIAL      ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$BR_SRV_IP" | awk -F'.' '{print $4}')   IN  PTR br-srv.$DOMAIN_NAME.
EOF

log_success "Обратная зона (BR-SRV) создана"

# ============================================================================
# СОЗДАНИЕ СТАНДАРТНЫХ ЗОН
# ============================================================================
log_step "Создание стандартных зон..."

cat > ${CHROOT}/named.localhost << EOF
\$TTL 1D
@   IN SOA @ rname.invalid. (
    0   ; serial
    1D  ; refresh
    1H  ; retry
    1W  ; expire
    3H  ; minimum
)
    NS  @
    A   127.0.0.1
    AAAA    ::1
EOF

cat > ${CHROOT}/named.loopback << EOF
\$TTL 1D
@   IN SOA @ rname.invalid. (
    0   ; serial
    1D  ; refresh
    1H  ; retry
    1W  ; expire
    3H  ; minimum
)
    NS  @
    PTR localhost.
EOF

log_success "Стандартные зоны созданы"

# ============================================================================
# УСТАНОВКА ПРАВ ДОСТУПА
# ============================================================================
log_step "Установка прав доступа..."

# Определяем пользователя для BIND
if id "named" &>/dev/null; then
    BIND_USER="named"
elif id "bind" &>/dev/null; then
    BIND_USER="bind"
else
    BIND_USER="named"
fi

log_info "Пользователь BIND: $BIND_USER"

chown -R root:named ${CHROOT} 2>/dev/null || chown -R root:root ${CHROOT}
chmod -R 755 ${CHROOT}
chmod 775 ${CHROOT}/data ${CHROOT}/dynamic ${CHROOT}/slaves 2>/dev/null || true

# Конфигурационные файлы
chown root:named ${CHROOT_ETC}/named.conf 2>/dev/null || true
chmod 640 ${CHROOT_ETC}/named.conf

# Файлы зон
chown -R root:named ${CHROOT}/master 2>/dev/null || true
chmod -R 644 ${CHROOT}/master/* 2>/dev/null || true

log_success "Права установлены"

# ============================================================================
# НАСТРОЙКА FIREWALL
# ============================================================================
log_step "Настройка firewall..."

if command -v firewall-cmd &> /dev/null; then
    systemctl enable firewalld 2>/dev/null || true
    systemctl start firewalld 2>/dev/null || true
    
    firewall-cmd --permanent --add-service=dns 2>/dev/null || \
    firewall-cmd --permanent --add-port=53/udp 2>/dev/null || \
    firewall-cmd --permanent --add-port=53/tcp 2>/dev/null || true
    
    firewall-cmd --reload 2>/dev/null || true
    log_success "Firewall настроен"
else
    log_warn "firewalld не установлен, пропускаю настройку firewall"
    
    # Пробуем iptables
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        log_info "iptables правила добавлены"
    fi
fi

# ============================================================================
# НАСТРОЙКА /ETC/RESOLV.CONF
# ============================================================================
log_step "Настройка /etc/resolv.conf..."

# Резервное копирование с уникальным именем
cp /etc/resolv.conf /etc/resolv.conf.backup.$$ 2>/dev/null || true

# Проверяем, не настроен ли уже
if ! grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    # Создаём новый resolv.conf
    cat > /etc/resolv.conf << EOF
# Configured by DNS setup script
nameserver 127.0.0.1
search $DOMAIN_NAME
EOF
    log_success "resolv.conf настроен"
else
    log_info "resolv.conf уже содержит 127.0.0.1"
    
    # Добавляем search если нет
    if ! grep -q "search $DOMAIN_NAME" /etc/resolv.conf 2>/dev/null; then
        echo "search $DOMAIN_NAME" >> /etc/resolv.conf
        log_info "Добавлен search $DOMAIN_NAME"
    fi
fi

# Удаляем временный бэкап
rm -f /etc/resolv.conf.backup.$$ 2>/dev/null || true

# ============================================================================
# ПРОВЕРКА КОНФИГУРАЦИИ
# ============================================================================
log_step "Проверка конфигурации..."

echo ""
echo "=== named-checkconf ==="
if named-checkconf ${CHROOT_ETC}/named.conf 2>&1; then
    log_success "named.conf валиден"
else
    log_error "Ошибка в named.conf!"
    named-checkconf ${CHROOT_ETC}/named.conf 2>&1
fi

echo ""
echo "=== named-checkzone (прямая зона) ==="
if named-checkzone $DOMAIN_NAME ${CHROOT}/master/$DOMAIN_NAME.db 2>&1; then
    log_success "Прямая зона валидна"
else
    log_error "Ошибка в прямой зоне!"
fi

# ============================================================================
# ЗАПУСК BIND
# ============================================================================
log_step "Запуск BIND..."

# Проверяем установлен ли BIND
if ! command -v named &> /dev/null; then
    log_error "BIND не установлен!"
    exit 1
fi

# Определяем имя службы
SERVICE=""
if systemctl list-unit-files 2>/dev/null | grep -q '^named.service'; then
    SERVICE="named"
elif systemctl list-unit-files 2>/dev/null | grep -q '^bind9.service'; then
    SERVICE="bind9"
elif systemctl list-unit-files 2>/dev/null | grep -q '^bind.service'; then
    SERVICE="bind"
else
    # Ищем по имени исполняемого файла
    if [ -f /lib/systemd/system/named.service ]; then
        SERVICE="named"
    elif [ -f /lib/systemd/system/bind9.service ]; then
        SERVICE="bind9"
    elif [ -f /lib/systemd/system/bind.service ]; then
        SERVICE="bind"
    else
        log_warn "Служба BIND не найдена автоматически"
        read -p "Введите имя службы BIND [named]: " SERVICE
        SERVICE=${SERVICE:-named}
    fi
fi

log_info "Сервис: $SERVICE"

# Очищаем возможные оверрайды
rm -rf /etc/systemd/system/bind.service.d/ 2>/dev/null || true
rm -rf /etc/systemd/system/bind9.service.d/ 2>/dev/null || true
rm -rf /etc/systemd/system/named.service.d/ 2>/dev/null || true

systemctl daemon-reload

# Останавливаем службу если запущена
systemctl stop $SERVICE 2>/dev/null || true

# Запускаем
systemctl enable $SERVICE
systemctl start $SERVICE

echo ""
log_info "Ожидание запуска службы..."
sleep 3

# Проверяем статус
if systemctl is-active --quiet $SERVICE; then
    log_success "BIND запущен!"
else
    log_error "BIND не запустился!"
    log_error "Проверьте логи:"
    journalctl -u $SERVICE --no-pager -n 50
    systemctl status $SERVICE --no-pager
    exit 1
fi

# ============================================================================
# ФИНАЛЬНАЯ ПРОВЕРКА
# ============================================================================
echo ""
log_step "Финальная проверка..."

sleep 2

echo ""
echo "=== Тест DNS (локальный IP) ==="
if dig @$HQ_SRV_IP $DOMAIN_NAME +short 2>/dev/null | grep -q .; then
    log_success "DNS отвечает на $HQ_SRV_IP"
    echo "  hq-srv.$DOMAIN_NAME: $(dig @$HQ_SRV_IP hq-srv.$DOMAIN_NAME +short 2>/dev/null || echo 'N/A')"
    echo "  hq-rtr.$DOMAIN_NAME: $(dig @$HQ_SRV_IP hq-rtr.$DOMAIN_NAME +short 2>/dev/null || echo 'N/A')"
    echo "  br-srv.$DOMAIN_NAME: $(dig @$HQ_SRV_IP br-srv.$DOMAIN_NAME +short 2>/dev/null || echo 'N/A')"
else
    log_warn "DNS не отвечает на $HQ_SRV_IP (проверьте firewall)"
fi

echo ""
echo "=== Тест localhost ==="
if dig @127.0.0.1 $DOMAIN_NAME +short 2>/dev/null | grep -q .; then
    log_success "DNS отвечает на localhost"
else
    log_warn "DNS не отвечает на localhost"
fi

echo ""
echo "=== Тест обратного DNS ==="
REV_RESULT=$(dig @$HQ_SRV_IP -x $HQ_SRV_IP +short 2>/dev/null)
if [ -n "$REV_RESULT" ]; then
    log_success "Обратный DNS работает: $REV_RESULT"
else
    log_warn "Обратный DNS не работает"
fi

# ============================================================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================================================
echo ""
echo "=============================================="
log_success "НАСТРОЙКА DNS ЗАВЕРШЕНА!"
echo "=============================================="
echo ""
echo "Домен: $DOMAIN_NAME"
echo "DNS сервер: $HQ_SRV_IP"
echo ""
echo "Хосты:"
echo "  hq-rtr.$DOMAIN_NAME -> $HQ_RTR_IP"
echo "  hq-srv.$DOMAIN_NAME -> $HQ_SRV_IP"
echo "  br-rtr.$DOMAIN_NAME -> $BR_RTR_IP"
echo "  br-srv.$DOMAIN_NAME -> $BR_SRV_IP"
echo "  docker.$DOMAIN_NAME -> $DOCKER_IP"
echo "  web.$DOMAIN_NAME -> $WEB_IP"
echo ""
echo "Файлы конфигурации:"
echo "  Конфиг: $NAMED_CONF"
echo "  Зоны: ${CHROOT}/master/"
echo "  Логи: ${CHROOT}/data/"
echo ""
echo "Команды для проверки:"
echo "  dig @$HQ_SRV_IP $DOMAIN_NAME"
echo "  nslookup hq-srv.$DOMAIN_NAME"
echo "  ping hq-srv.$DOMAIN_NAME"
echo ""
echo "Управление службой:"
echo "  systemctl status $SERVICE"
echo "  systemctl restart $SERVICE"
echo "  journalctl -u $SERVICE -f"
echo ""
log_success "Удачи на экзамене!"
echo ""
