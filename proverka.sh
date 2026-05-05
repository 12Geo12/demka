#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script for ALT Linux
# Версия: 3.0 (с проверками и исправлением ошибок)
# ============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_error "Запускайте от root"
    exit 1
fi

# Функция проверки команды
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "Команда $1 не найдена"
        return 1
    fi
    return 0
}

# Определение ОС и установка пакетов
log_step "Определение ОС и установка пакетов..."

if [ -f /etc/altlinux-release ]; then
    OS_VERSION=$(cat /etc/altlinux-release | grep -oP '\d+\.\d+' | head -1)
    log_info "ALT Linux версии: $OS_VERSION"
    
    log_step "Установка BIND..."
    apt-get update
    
    # Проверяем установлен ли bind
    if ! rpm -q bind &>/dev/null; then
        apt-get install -y bind bind-utils
        log_info "Пакеты bind установлены"
    else
        log_info "BIND уже установлен"
    fi
else
    log_error "Поддерживается только ALT Linux"
    exit 1
fi

# Интерактивный ввод
log_step "Ввод параметров сети"
echo ""

# Автоопределение IP
DEFAULT_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
read -p "IP-адрес HQ-SRV [$DEFAULT_IP]: " HQ_IP
HQ_IP=${HQ_IP:-$DEFAULT_IP}

# Автоопределение сети
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
read -p "Сетевой интерфейс [$DEFAULT_IFACE]: " NETWORK_IFACE
NETWORK_IFACE=${NETWORK_IFACE:-$DEFAULT_IFACE}

DEFAULT_NET=$(ip addr show $NETWORK_IFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')
read -p "Сетевой адрес (например, 192.168.1.0) [$DEFAULT_NET]: " NETWORK_ADDR
NETWORK_ADDR=${NETWORK_ADDR:-$DEFAULT_NET}

DEFAULT_MASK=$(ip addr show $NETWORK_IFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f2)
read -p "Маска подсети (CIDR, например 24) [$DEFAULT_MASK]: " SUBNET_MASK
SUBNET_MASK=${SUBNET_MASK:-$DEFAULT_MASK}

read -p "Доменное имя (например, au-team.irpo): " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-au-team.irpo}

echo ""
log_info "Настройка forwarders"
echo "1) Яндекс DNS (77.88.8.8, 77.88.8.1)"
echo "2) Google DNS (8.8.8.8, 8.8.4.4)"
echo "3) Cloudflare (1.1.1.1)"
echo "4) Свои"
read -p "Выбор [1]: " FWD_CHOICE
FWD_CHOICE=${FWD_CHOICE:-1}

case $FWD_CHOICE in
    1) FWD1="77.88.8.8"; FWD2="77.88.8.1" ;;
    2) FWD1="8.8.8.8"; FWD2="8.8.4.4" ;;
    3) FWD1="1.1.1.1"; FWD2="1.0.0.1" ;;
    4) read -p "Primary DNS: " FWD1; read -p "Secondary DNS: " FWD2 ;;
    *) FWD1="77.88.8.8"; FWD2="77.88.8.1" ;;
esac

echo ""
log_info "Добавление хостов согласно Таблице 3"
log_info "Устройства: HQ-RTR, BR-RTR, HQ-SRV, HQ-CLI, BR-SRV, ISP"

# Массивы для хостов
declare -a HOSTS
declare -a IPS

# HQ-SRV (текущий сервер)
log_info "HQ-SRV: $HQ_IP"
HOSTS+=("hq-srv")
IPS+=("$HQ_IP")

# HQ-RTR
read -p "IP-адрес HQ-RTR: " ip
if [ -n "$ip" ]; then
    HOSTS+=("hq-rtr")
    IPS+=("$ip")
fi

# BR-RTR
read -p "IP-адрес BR-RTR: " ip
if [ -n "$ip" ]; then
    HOSTS+=("br-rtr")
    IPS+=("$ip")
fi

# HQ-CLI
read -p "IP-адрес HQ-CLI: " ip
if [ -n "$ip" ]; then
    HOSTS+=("hq-cli")
    IPS+=("$ip")
fi

# BR-SRV
read -p "IP-адрес BR-SRV: " ip
if [ -n "$ip" ]; then
    HOSTS+=("br-srv")
    IPS+=("$ip")
fi

# ISP интерфейсы
read -p "IP-адрес ISP (к HQ-RTR): " ip
if [ -n "$ip" ]; then
    HOSTS+=("docker")
    IPS+=("$ip")
fi

read -p "IP-адрес ISP (к BR-RTR): " ip
if [ -n "$ip" ]; then
    HOSTS+=("web")
    IPS+=("$ip")
fi

echo ""
log_step "Сводка:"
echo "  Сервер: hq-srv.$DOMAIN_NAME ($HQ_IP)"
echo "  Сеть: $NETWORK_ADDR/$SUBNET_MASK"
echo "  Forwarders: $FWD1, $FWD2"
echo "  Хостов: ${#HOSTS[@]}"

read -p "Продолжить? [y/N]: " confirm
[[ ! $confirm =~ ^[Yy]$ ]] && exit 1

# Создание директорий
log_step "Создание структуры..."
mkdir -p /var/named/{data,dynamic,slaves,zones}

# КРИТИЧЕСКАЯ ПРОВЕРКА: права на /var/named
log_step "Проверка прав доступа..."
chmod 770 /var/named
chown named:named /var/named
chmod 770 /var/named/{data,dynamic,slaves,zones}
chown named:named /var/named/{data,dynamic,slaves,zones}

# Проверка что named может писать
if [ ! -w /var/named ]; then
    log_error "/var/named не доступен для записи!"
    exit 1
fi
log_info "Права доступа настроены корректно"

# Генерация rndc ключа
log_step "Генерация rndc ключа..."

# Удаляем старые ключи если есть
rm -f /etc/rndc.key /etc/bind/rndc.key

# Генерируем новый
rndc-confgen -a 

# Копируем в оба места
if [ -f /etc/rndc.key ]; then
    cp /etc/rndc.key /etc/bind/rndc.key
    chmod 640 /etc/rndc.key /etc/bind/rndc.key
    chown root:named /etc/rndc.key /etc/bind/rndc.key
    
    # ПРОВЕРКА: ключ должен содержать secret и algorithm
    if grep -q "secret" /etc/rndc.key && grep -q "algorithm" /etc/rndc.key; then
        log_info "rndc ключ сгенерирован и проверен"
    else
        log_error "rndc ключ сгенерирован некорректно!"
        cat /etc/rndc.key
        exit 1
    fi
else
    log_error "Не удалось создать rndc ключ!"
    exit 1
fi

# Создание named.conf
log_step "Создание named.conf..."
REVERSE_NET=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')

# Определяем где создавать конфиг
if [ -d /etc/bind ]; then
    NAMED_CONF="/etc/named.conf"
    OPTIONS_CONF="/etc/bind/options.conf"
    LOCAL_CONF="/etc/bind/local.conf"
    
    # Создаем основной конфиг
    cat > $NAMED_CONF << EOF
include "/etc/bind/options.conf";
include "/etc/bind/rndc.conf";
include "/etc/bind/local.conf";
EOF
    log_info "Создан /etc/named.conf (ALT Linux структура)"
    
    # Создаем options.conf
    cat > $OPTIONS_CONF << EOF
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { any; };
    directory "/var/named";
    pid-file "/run/named/named.pid";
    
    allow-recursion { localhost; 127.0.0.1; $NETWORK_ADDR/$SUBNET_MASK; };
    allow-query { any; };
    
    forwarders {
        $FWD1;
        $FWD2;
    };
    forward only;
    
    dnssec-validation no;
    
    // Логирование
    logging {
        channel default_log {
            file "/var/named/data/named.log" versions 3 size 5m;
            severity info;
            print-time yes;
        };
        category default { default_log; };
    };
};
EOF
    log_info "Создан /etc/bind/options.conf"
    
    # Создаем local.conf
    cat > $LOCAL_CONF << EOF
// Зоны
zone "$DOMAIN_NAME" IN {
    type master;
    file "/var/named/zones/$DOMAIN_NAME.zone";
    allow-update { none; };
};

zone "$REVERSE_NET.in-addr.arpa" IN {
    type master;
    file "/var/named/zones/$REVERSE_NET.reverse";
    allow-update { none; };
};

// Стандартные зоны
zone "localhost" IN {
    type master;
    file "/var/named/named.localhost";
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "/var/named/named.loopback";
};
EOF
    log_info "Создан /etc/bind/local.conf"
else
    # Стандартная структура
    cat > /etc/named.conf << EOF
options {
    listen-on port 53 { any; };
    directory "/var/named";
    pid-file "/run/named/named.pid";
    
    allow-recursion { localhost; 127.0.0.1; $NETWORK_ADDR/$SUBNET_MASK; };
    allow-query { any; };
    
    forwarders {
        $FWD1;
        $FWD2;
    };
    forward only;
    
    dnssec-validation no;
};

logging {
    channel default_log {
        file "/var/named/data/named.log" versions 3 size 5m;
        severity info;
        print-time yes;
    };
    category default { default_log; };
};

include "/etc/rndc.key";

controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

zone "$DOMAIN_NAME" IN {
    type master;
    file "zones/$DOMAIN_NAME.zone";
    allow-update { none; };
};

zone "$REVERSE_NET.in-addr.arpa" IN {
    type master;
    file "zones/$REVERSE_NET.reverse";
    allow-update { none; };
};

zone "localhost" IN {
    type master;
    file "named.localhost";
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "named.loopback";
};
EOF
fi

# Создание прямой зоны
log_step "Создание зоны прямого разрешения..."
SERIAL=$(date +%Y%m%d01)

cat > /var/named/zones/$DOMAIN_NAME.zone << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
        $SERIAL
        3600
        1800
        604800
        86400 )

@       IN  NS      hq-srv.$DOMAIN_NAME.

EOF

# Добавление хостов
for i in "${!HOSTS[@]}"; do
    echo "${HOSTS[$i]}   IN  A   ${IPS[$i]}" >> /var/named/zones/$DOMAIN_NAME.zone
done

chown named:named /var/named/zones/$DOMAIN_NAME.zone
chmod 640 /var/named/zones/$DOMAIN_NAME.zone

# Создание обратной зоны
log_step "Создание зоны обратного разрешения..."
cat > /var/named/zones/$REVERSE_NET.reverse << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN_NAME. root.$DOMAIN_NAME. (
        $SERIAL
        3600
        1800
        604800
        86400 )

@       IN  NS      hq-srv.$DOMAIN_NAME.

EOF

# Добавление PTR записей
for i in "${!HOSTS[@]}"; do
    LAST=$(echo ${IPS[$i]} | awk -F. '{print $4}')
    echo "$LAST   IN  PTR   ${HOSTS[$i]}.$DOMAIN_NAME." >> /var/named/zones/$REVERSE_NET.reverse
done

chown named:named /var/named/zones/$REVERSE_NET.reverse
chmod 640 /var/named/zones/$REVERSE_NET.reverse

# Стандартные зоны
log_step "Создание стандартных зон..."
[ ! -f /var/named/named.localhost ] && cat > /var/named/named.localhost << 'EOF'
$TTL 1D
@   IN SOA @ root.localhost. ( 1 1H 15M 1W 1D )
    NS  @
    A   127.0.0.1
EOF

[ ! -f /var/named/named.loopback ] && cat > /var/named/named.loopback << 'EOF'
$TTL 1D
@   IN SOA @ root.localhost. ( 1 1H 15M 1W 1D )
    NS  @
    PTR localhost.
EOF

chown named:named /var/named/named.localhost /var/named/named.loopback

# Лог файл и файлы для managed-keys
log_step "Создание файлов логов..."
touch /var/named/data/named.log
touch /var/named/managed-keys.bind
touch /var/named/managed-keys.bind.jnl

chown named:named /var/named/data/named.log
chown named:named /var/named/managed-keys.bind*
chmod 660 /var/named/managed-keys.bind*
chmod 640 /var/named/data/named.log

# ПРОВЕРКА: валидация конфигурации
log_step "Проверка конфигурации..."
if named-checkconf; then
    log_info "Конфигурация проверена успешно"
else
    log_error "Ошибка в конфигурации!"
    named-checkconf 2>&1
    exit 1
fi

# ПРОВЕРКА: валидация зон
for zone_file in /var/named/zones/*.zone /var/named/zones/*.reverse; do
    if [ -f "$zone_file" ]; then
        if named-checkzone $(basename $zone_file) $zone_file > /dev/null 2>&1; then
            log_info "Зона $(basename $zone_file) проверена"
        else
            log_warn "Зона $(basename $zone_file) имеет ошибки"
            named-checkzone $(basename $zone_file) $zone_file 2>&1 | head -5
        fi
    fi
done

# Firewall
log_step "Настройка firewall..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=dns 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT

# Отключаем SELinux/AppArmor если мешают
log_step "Проверка безопасности..."
if command -v setenforce &>/dev/null; then
    setenforce 0 2>/dev/null || log_warn "Не удалось отключить SELinux"
fi

if command -v aa-complain &>/dev/null; then
    aa-complain /usr/sbin/named 2>/dev/null || true
fi

# Создание директории для PID
log_step "Подготовка к запуску..."
mkdir -p /run/named
chown named:named /run/named

# Проверяем service файл
if [ ! -f /etc/systemd/system/named.service ]; then
    cat > /etc/systemd/system/named.service << 'EOF'
[Unit]
Description=BIND DNS Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/named -c /etc/named.conf
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/run/named/named.pid
Restart=on-failure
User=named
Group=named

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "Service файл создан"
fi

# Запуск
log_step "Запуск BIND..."
systemctl enable named 2>/dev/null || true

# Пробуем запустить
if systemctl restart named 2>/dev/null; then
    sleep 3
    
    if systemctl is-active --quiet named; then
        log_info "✓ BIND запущен успешно!"
    else
        log_warn "⚠ BIND не запустился. Пробуем диагностику..."
        journalctl -u named -n 20 --no-pager
    fi
else
    log_error "✗ Не удалось запустить BIND"
    journalctl -u named -n 30 --no-pager
fi

# Тест
echo ""
log_step "Тестирование DNS..."
sleep 2

for i in "${!HOSTS[@]}"; do
    FQDN="${HOSTS[$i]}.$DOMAIN_NAME"
    RESULT=$(dig @localhost $FQDN +short 2>/dev/null)
    if [ "$RESULT" == "${IPS[$i]}" ]; then
        log_info "✓ $FQDN -> $RESULT"
    else
        log_warn "✗ $FQDN -> $RESULT (ожидалось ${IPS[$i]})"
    fi
done

# Обратное разрешение
echo ""
log_step "Тестирование обратного разрешения..."
for i in "${!HOSTS[@]}"; do
    RESULT=$(dig @localhost -x ${IPS[$i]} +short 2>/dev/null)
    if echo "$RESULT" | grep -q "${HOSTS[$i]}.$DOMAIN_NAME"; then
        log_info "✓ ${IPS[$i]} -> ${HOSTS[$i]}.$DOMAIN_NAME"
    else
        log_warn "✗ ${IPS[$i]} -> $RESULT"
    fi
done

echo ""
log_info "Готово! Команды:"
echo "  systemctl status named"
echo "  tail -f /var/named/data/named.log"
echo "  dig @localhost hq-srv.$DOMAIN_NAME"
echo "  rndc status"
