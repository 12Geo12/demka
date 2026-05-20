#!/bin/bash
# ============================================================================
# Скрипт настройки DNS сервера (BIND) для домена au-team.irpo
# ИСПРАВЛЕНА ВЕРСИЯ - устранено дублирование зон и добавлена валидация
# ============================================================================

set -e

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

# ============================================================================
# ФУНКЦИЯ ВАЛИДАЦИИ IP-АДРЕСА (НОВАЯ)
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
# КОНФИГУРАЦИЯ
# ============================================================================
log_step "Конфигурация DNS"
echo ""

# Определяем локальный IP
LOCAL_IP=$(hostname -I | awk '{print $1}' | awk -F'.' '{print $1"."$2"."$3".10"}')

DEFAULT_HQ_RTR="192.168.4.2"
DEFAULT_HQ_SRV="$LOCAL_IP"
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
            log_error "Неверный формат IP-адреса! Пример: 192.168.4.1"
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

# ============================================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================================
log_step "Установка пакетов..."
yum install -y bind bind-utils firewalld

# ============================================================================
# СОЗДАНИЕ СТРУКТУРЫ ДИРЕКТОРИЙ
# ============================================================================
log_step "Создание структуры директорий..."

CHROOT=/var/named
CHROOT_ETC=/etc/named
mkdir -p ${CHROOT}/master
mkdir -p ${CHROOT}/data
mkdir -p ${CHROOT}/dynamic
mkdir -p ${CHROOT}/slaves
mkdir -p ${CHROOT_ETC}

log_info "Директории созданы"

# ============================================================================
# ГЕНЕРАЦИЯ КЛЮЧЕЙ
# ============================================================================
log_step "Генерация rndc ключа..."

if ! rndc-confgen -a -r /dev/urandom &>/dev/null; then
    log_warn "rndc-confgen не сработал, создам вручную..."
    cat > /etc/rndc.key << EOF
key "rndc-key" {
    algorithm hmac-sha256;
    secret "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)";
};
EOF
    chmod 640 /etc/rndc.key
fi

log_info "rndc.key создан вручную"
cp /etc/rndc.key ${CHROOT}/etc/rndc.key 2>/dev/null || true

# ============================================================================
# СОЗДАНИЕ NAMED.CONF С ПРОВЕРКОЙ НА ДУБЛИРОВАНИЕ ЗОН (ИСПРАВЛЕНО)
# ============================================================================
log_step "Создание named.conf..."

# Создаем массив для отслеживания уникальных зон
declare -A REVERSE_ZONES_ADDED

cat > ${CHROOT_ETC}/named.conf << EOF
// DNS Configuration for $DOMAIN_NAME
// Generated: $(date)

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

log_info "named.conf создан"

# ============================================================================
# СОЗДАНИЕ ПРЯМОЙ ЗОНЫ
# ============================================================================
log_step "Создание прямой зоны..."

cat > ${CHROOT}/master/$DOMAIN_NAME.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $(date +%Y%m%d01) ; Serial
    3600        ; Refresh
    1800        ; Retry
    604800      ; Expire
    86400       ; Minimum TTL
)

@       IN  NS      hq-srv.$DOMAIN_NAME.

hq-rtr  IN  A       $HQ_RTR_IP
br-rtr  IN  A       $BR_RTR_IP
hq-srv  IN  A       $HQ_SRV_IP
br-srv  IN  A       $BR_SRV_IP
docker  IN  A       $DOCKER_IP
web     IN  A       $WEB_IP
EOF

log_info "Прямая зона создана"

# ============================================================================
# СОЗДАНИЕ ОБРАТНЫХ ЗОН
# ============================================================================
log_step "Создание обратных зон..."

# Локальная обратная зона
cat > ${CHROOT}/master/${DOMAIN_NAME}_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $(date +%Y%m%d01) ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$HQ_SRV_IP" | awk -F'.' '{print $4}')   IN  PTR hq-srv.$DOMAIN_NAME.
EOF

log_info "Обратная зона (локальная) создана"

# Обратная зона HQ-RTR
cat > ${CHROOT}/master/${DOMAIN_NAME}_hq_rtr_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $(date +%Y%m%d01) ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$HQ_RTR_IP" | awk -F'.' '{print $4}')   IN  PTR hq-rtr.$DOMAIN_NAME.
EOF

log_info "Обратная зона (HQ-RTR) создана"

# Обратная зона BR-RTR
cat > ${CHROOT}/master/${DOMAIN_NAME}_br_rtr_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $(date +%Y%m%d01) ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$BR_RTR_IP" | awk -F'.' '{print $4}')   IN  PTR br-rtr.$DOMAIN_NAME.
EOF

log_info "Обратная зона (BR-RTR) создана"

# Обратная зона BR-SRV
cat > ${CHROOT}/master/${DOMAIN_NAME}_br_srv_rev.db << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
    $(date +%Y%m%d01) ; Serial
    3600
    1800
    604800
    86400
)

@   IN  NS  hq-srv.$DOMAIN_NAME.
$(echo "$BR_SRV_IP" | awk -F'.' '{print $4}')   IN  PTR br-srv.$DOMAIN_NAME.
EOF

log_info "Обратная зона (BR-SRV) создана"

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

cat > ${CHROOT}/named.root << EOF
.                        3600000      NS    A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
EOF

log_info "Стандартные зоны созданы"

# ============================================================================
# УСТАНОВКА ПРАВ ДОСТУПА
# ============================================================================
log_step "Установка прав доступа..."

chown -R root:named ${CHROOT}
chmod -R 750 ${CHROOT}
chown root:named ${CHROOT_ETC}/named.conf
chmod 640 ${CHROOT_ETC}/named.conf

log_info "Права установлены"

# ============================================================================
# НАСТРОЙКА FIREWALL
# ============================================================================
log_step "Настройка firewall..."

systemctl enable firewalld
systemctl start firewalld

firewall-cmd --permanent --add-service=dns >/dev/null 2>&1 || true
firewall-cmd --permanent --add-port=53/udp >/dev/null 2>&1 || true
firewall-cmd --permanent --add-port=53/tcp >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true

log_info "Firewall настроен"

# ============================================================================
# НАСТРОЙКА /ETC/RESOLV.CONF
# ============================================================================
log_step "Настройка /etc/resolv.conf..."

if ! grep -q "127.0.0.1" /etc/resolv.conf; then
    cp /etc/resolv.conf /etc/resolv.conf.backup
    echo "nameserver 127.0.0.1" | cat - /etc/resolv.conf > /tmp/resolv.conf.new
    echo "search $DOMAIN_NAME" >> /tmp/resolv.conf.new
    mv /tmp/resolv.conf.new /etc/resolv.conf
    log_info "resolv.conf настроен"
else
    log_info "resolv.conf уже содержит 127.0.0.1"
fi

# ============================================================================
# ПРОВЕРКА КОНФИГУРАЦИИ
# ============================================================================
log_step "Проверка конфигурации..."

echo ""
echo "=== named-checkconf ==="
if named-checkconf ${CHROOT_ETC}/named.conf 2>&1; then
    log_info "✓ named.conf валиден"
else
    log_error "✗ Ошибка в named.conf!"
    named-checkconf ${CHROOT_ETC}/named.conf 2>&1
fi

echo ""
echo "=== named-checkzone (прямая зона) ==="
if named-checkzone $DOMAIN_NAME ${CHROOT}/master/$DOMAIN_NAME.db 2>&1; then
    log_info "✓ Прямая зона валидна"
else
    log_error "✗ Ошибка в прямой зоне!"
fi

# ============================================================================
# ЗАПУСК BIND С УЛУЧШЕННОЙ ПРОВЕРКОЙ (ИСПРАВЛЕНО)
# ============================================================================
log_step "Запуск BIND..."

# Проверяем установлен ли BIND
if ! command -v named &> /dev/null; then
    log_error "BIND не установлен!"
    exit 1
fi

# Определяем имя службы
if systemctl list-unit-files 2>/dev/null | grep -q '^named.service'; then
    SERVICE="named"
elif systemctl list-unit-files 2>/dev/null | grep -q '^bind9.service'; then
    SERVICE="bind9"
elif systemctl list-unit-files 2>/dev/null | grep -q '^bind.service'; then
    SERVICE="bind"
else
    log_error "Служба BIND не найдена!"
    exit 1
fi

log_info "Сервис: $SERVICE"

# Очищаем возможные оверрайды
rm -rf /etc/systemd/system/bind.service.d/ 2>/dev/null || true
rm -rf /etc/systemd/system/bind9.service.d/ 2>/dev/null || true
rm -rf /etc/systemd/system/named.service.d/ 2>/dev/null || true

systemctl daemon-reload

systemctl enable $SERVICE
systemctl restart $SERVICE
sleep 3

echo ""
if systemctl is-active --quiet $SERVICE; then
    log_info "✓ BIND запущен!"
else
    log_error "✗ BIND не запустился!"
    log_error "Проверьте логи:"
    journalctl -u $SERVICE --no-pager | tail -30
    exit 1
fi

# ============================================================================
# ФИНАЛЬНАЯ ПРОВЕРКА
# ============================================================================
echo ""
log_step "Финальная проверка..."

sleep 2

echo ""
echo "=== Тест DNS ==="
if dig @$HQ_SRV_IP $DOMAIN_NAME +short >/dev/null 2>&1; then
    log_info "✓ DNS отвечает на $HQ_SRV_IP"
    echo "  hq-srv.$DOMAIN_NAME: $(dig @$HQ_SRV_IP hq-srv.$DOMAIN_NAME +short 2>/dev/null || echo 'N/A')"
else
    log_warn "✗ DNS не отвечает на $HQ_SRV_IP"
fi

echo ""
echo "=== Тест localhost ==="
if dig @127.0.0.1 $DOMAIN_NAME +short >/dev/null 2>&1; then
    log_info "✓ DNS отвечает на localhost"
else
    log_warn "✗ DNS не отвечает на localhost"
fi

# ============================================================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================================================
echo ""
echo "=============================================="
log_info "НАСТРОЙКА DNS ЗАВЕРШЕНА!"
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
echo "Команды для проверки:"
echo "  dig @$HQ_SRV_IP $DOMAIN_NAME"
echo "  nslookup hq-srv.$DOMAIN_NAME $HQ_SRV_IP"
echo "  ping hq-srv.$DOMAIN_NAME"
echo ""
log_info "Удачи на экзамене! 🚀"
echo ""
