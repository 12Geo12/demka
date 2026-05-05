#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script for ALT Linux
# Версия: 2.1 (исправлена установка для ALT Linux)
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

# Определение ОС и установка пакетов
log_step "Определение ОС и установка пакетов..."

if [ -f /etc/altlinux-release ]; then
    OS_VERSION=$(cat /etc/altlinux-release | grep -oP '\d+\.\d+' | head -1)
    log_info "ALT Linux версии: $OS_VERSION"
    
    # Для ALT Linux используем bind (не bind9!)
    log_step "Установка BIND..."
    apt-get update
    apt-get install -y bind bind-utils
    
    SERVICE_NAME="named"
    log_info "Пакеты bind установлены"
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
chown -R named:named /var/named
chmod 750 /var/named

# Генерация rndc ключа
log_step "Генерация rndc ключа..."
if [ ! -f /etc/rndc.key ]; then
    rndc-confgen -a -q
    chown named:named /etc/rndc.key
    chmod 640 /etc/rndc.key
fi

# Создание named.conf
log_step "Создание named.conf..."
REVERSE_NET=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')

cat > /etc/named.conf << EOF
options {
    listen-on port 53 { any; };
    directory "/var/named";
    
    allow-recursion { localhost; 127.0.0.1; $NETWORK_ADDR/$SUBNET_MASK; };
    allow-query { any; };
    
    forwarders {
        $FWD1;
        $FWD2;
    };
    forward only;
    
    dnssec-validation no;
    
    logging {
        channel default_log {
            file "/var/named/data/named.log" versions 3 size 5m;
            severity info;
            print-time yes;
        };
        category default { default_log; };
    };
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

# PTR записи
echo "" >> /var/named/zones/$DOMAIN_NAME.zone
echo "; PTR Records" >> /var/named/zones/$DOMAIN_NAME.zone
for i in "${!HOSTS[@]}"; do
    LAST=$(echo ${IPS[$i]} | awk -F. '{print $4}')
    echo "${HOSTS[$i]}   IN  PTR   $LAST" >> /var/named/zones/$DOMAIN_NAME.zone
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

# Лог файл
touch /var/named/data/named.log
chown named:named /var/named/data/named.log

# Проверка
log_step "Проверка конфигурации..."
named-checkconf /etc/named.conf
named-checkzone $DOMAIN_NAME /var/named/zones/$DOMAIN_NAME.zone
named-checkzone $REVERSE_NET.in-addr.arpa /var/named/zones/$REVERSE_NET.reverse

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

# Запуск
log_step "Запуск BIND..."
mkdir -p /run/named
chown named:named /run/named

systemctl enable named
systemctl restart named
sleep 2

# Статус
echo ""
if systemctl is-active --quiet named; then
    log_info "✓ BIND запущен успешно!"
else
    log_warn "⚠ BIND не запустился. Логи:"
    journalctl -xeu named -n 20 --no-pager
fi

# Тест
echo ""
log_step "Тестирование DNS..."
for i in "${!HOSTS[@]}"; do
    FQDN="${HOSTS[$i]}.$DOMAIN_NAME"
    RESULT=$(dig @localhost $FQDN +short 2>/dev/null)
    if [ "$RESULT" == "${IPS[$i]}" ]; then
        log_info "✓ $FQDN -> $RESULT"
    else
        log_warn "✗ $FQDN -> $RESULT (ожидалось ${IPS[$i]})"
    fi
done

echo ""
log_info "Готово! Команды:"
echo "  systemctl status named"
echo "  tail -f /var/named/data/named.log"
echo "  dig @localhost hq-srv.$DOMAIN_NAME"
