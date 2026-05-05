#!/bin/bash
# ============================================================================
# DNS Setup для Demo 2026 - Структура /etc/bind/
# По мотивам github.com/stepanovs2005/Demo2026
# ============================================================================

set -e
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }
err() { echo -e "${RED}[!]${NC} $1"; }

[ "$EUID" -ne 0 ] && { err "Запуск от root"; exit 1; }

log "Установка BIND..."
apt-get update && apt-get install -y bind bind-utils

log "Создание структуры..."
mkdir -p /etc/bind/zones
cd /etc/bind

# ================= rndc ключ =================
log "Генерация rndc ключа..."
rm -f /etc/rndc.key /etc/bind/rndc.key
rndc-confgen -a
[ -f /etc/rndc.key ] && {
    cp /etc/rndc.key /etc/bind/rndc.key
    chmod 640 /etc/rndc.key /etc/bind/rndc.key
    chown root:named /etc/rndc.key /etc/bind/rndc.key
}

# ================= ВВОД ДАННЫХ =================
log "Введите параметры:"
MY_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
read -p "IP HQ-SRV [$MY_IP]: " IP && IP=${IP:-$MY_IP}
read -p "Домен [au-team.irpo]: " DOMAIN && DOMAIN=${DOMAIN:-au-team.irpo}
read -p "Сеть (192.168.10): " NET && NET=${NET:-192.168.10}
FWD_IP=$(echo $NET | sed 's/\.[0-9]*$/.254')
read -p "IP шлюза [$FWD_IP]: " FWD && FWD=${FWD:-$FWD_IP}

# Хосты
declare -A HOSTS
log "Хосты (имя:ip), пусто - готово:"
while true; do
    read -p "  (hq-cli:192.168.10.10): " entry
    [ -z "$entry" ] && break
    name="${entry%%:*}"
    ip="${entry##*:}"
    [ -n "$name" ] && [ -n "$ip" ] && HOSTS["$name"]="$ip"
done

# ================= options.conf =================
log "Создание options.conf..."
cat > /etc/bind/options.conf << EOF
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    pid-file "/run/named/named.pid";
    
    allow-query { any; };
    allow-recursion { any; };
    
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
    forward only;
    
    dnssec-validation no;
};
EOF

# ================= local.conf =================
log "Создание local.conf..."
cat > /etc/bind/local.conf << EOF
// Прямая зона
zone "$DOMAIN" IN {
    type master;
    file "/etc/bind/db.$DOMAIN";
};

// Обратная зона
zone "${NET}.in-addr.arpa" IN {
    type master;
    file "/etc/bind/db.$NET";
};

// Стандартные зоны
zone "localhost" IN {
    type master;
    file "/etc/bind/db.local";
};
EOF

# ================= Прямая зона =================
log "Создание прямой зоны..."
SERIAL=$(date +%Y%m%d01)
cat > /etc/bind/db.$DOMAIN << EOF
; Зона $DOMAIN
; Сгенерировано $(date)
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400 )

    IN  NS      hq-srv.$DOMAIN.
    IN  MX  10  hq-srv.$DOMAIN.

; Серверы
hq-srv    IN  A   $IP

EOF

# Добавляем хосты
for name in "${!HOSTS[@]}"; do
    echo "$name    IN  A   ${HOSTS[$name]}" >> /etc/bind/db.$DOMAIN
done

# ================= Обратная зона =================
log "Создание обратной зоны..."
cat > /etc/bind/db.$NET << EOF
; Обратная зона ${NET}.in-addr.arpa
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400 )

    IN  NS      hq-srv.$DOMAIN.

EOF

# PTR для HQ-SRV
LAST=$(echo $IP | awk -F. '{print $4}')
echo "$LAST    IN  PTR   hq-srv.$DOMAIN." >> /etc/bind/db.$NET

# PTR для хостов
for name in "${!HOSTS[@]}"; do
    LAST=$(echo ${HOSTS[$name]} | awk -F. '{print $4}')
    echo "$LAST    IN  PTR   $name.$DOMAIN." >> /etc/bind/db.$NET
done

# ================= Стандартная зона localhost =================
[ ! -f /etc/bind/db.local ] && cat > /etc/bind/db.local << 'EOF'
$TTL 86400
@   IN  SOA localhost root.localhost. (
        1
        3600
        1800
        604800
        86400 )
    IN  NS      localhost.
    IN  A       127.0.0.1
EOF

# ================= Права =================
log "Настройка прав..."
chown -R root:named /etc/bind
chmod 640 /etc/bind/*
chown named:named /var/named
chmod 750 /var/named

# Создаем файлы для записи
mkdir -p /var/named/{data,dynamic,slaves}
touch /var/named/data/named.log
chown -R named:named /var/named

# ================= named.conf =================
log "Создание /etc/named.conf..."
cat > /etc/named.conf << 'EOF'
include "/etc/bind/options.conf";
include "/etc/bind/rndc.conf";
include "/etc/bind/local.conf";
EOF

# ================= Проверка =================
log "Проверка конфигурации..."
if named-checkconf; then
    log "✓ named.conf OK"
else
    err "Ошибка в конфиге!"
    exit 1
fi

named-checkzone $DOMAIN /etc/bind/db.$DOMAIN >/dev/null 2>&1 && log "✓ Прямая зона OK"
named-checkzone ${NET}.in-addr.arpa /etc/bind/db.$NET >/dev/null 2>&1 && log "✓ Обратная зона OK"

# ================= Firewall =================
log "Открываем порт 53..."
iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 53 -j ACCEPT

# ================= Отключаем безопасность =================
setenforce 0 2>/dev/null || true

# ================= Запуск =================
log "Запуск BIND..."
systemctl daemon-reload
systemctl enable bind
systemctl restart bind
sleep 2

if systemctl is-active --quiet bind; then
    log "✓ DNS-сервер запущен!"
    echo ""
    log "Тестирование:"
    echo "  hq-srv.$DOMAIN -> $(dig @localhost hq-srv.$DOMAIN +short 2>/dev/null)"
    for name in "${!HOSTS[@]}"; do
        echo "  $name.$DOMAIN -> $(dig @localhost $name.$DOMAIN +short 2>/dev/null)"
    done
    echo ""
    log "Обратное разрешение:"
    echo "  $IP -> $(dig @localhost -x $IP +short 2>/dev/null)"
else
    err "Не удалось запустить"
    journalctl -u bind -n 15 --no-pager
fi

echo ""
log "Готово!"
echo "Команды:"
echo "  systemctl status bind"
echo "  nslookup hq-srv.$DOMAIN 127.0.0.1"
echo "  tail -f /var/named/data/named.log"
