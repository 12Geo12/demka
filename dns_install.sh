#!/bin/bash
# Скрипт настройки DNS сервера BIND на ALT Linux

echo "=== Настройка DNS сервера ==="
echo ""

# Автоматическое определение IP адреса
DNS_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
echo "Определён IP адрес: $DNS_IP"
echo ""

read -p "Имя домена: " DOMAIN
read -p "Forwarder DNS 1: " FORWARDER1
read -p "Forwarder DNS 2: " FORWARDER2

# Определение обратной зоны
OCTET1=$(echo $DNS_IP | cut -d. -f1)
OCTET2=$(echo $DNS_IP | cut -d. -f2)
OCTET3=$(echo $DNS_IP | cut -d. -f3)
REVERSE_ZONE="${OCTET3}.${OCTET2}.${OCTET1}.in-addr.arpa"

echo ""
echo "=== Ввод A-записей ==="
echo "Формат: имя IP (например: hq-srv 192.168.100.1)"
echo "Пустая строка - завершить ввод"
echo ""

A_RECORDS=""
while true; do
    read -p "A-запись: " name ip
    if [[ -z "$name" ]]; then
        break
    fi
    if [[ -n "$name" && -n "$ip" ]]; then
        A_RECORDS="$A_RECORDS$name $ip"$'\n'
        echo "  Добавлено: $name -> $ip"
    fi
done

echo ""
echo "=== Ввод CNAME-записей ==="
echo "Формат: имя target (например: moodle hq-srv)"
echo "Пустая строка - завершить ввод"
echo ""

CNAME_RECORDS=""
while true; do
    read -p "CNAME-запись: " name target
    if [[ -z "$name" ]]; then
        break
    fi
    if [[ -n "$name" && -n "$target" ]]; then
        CNAME_RECORDS="$CNAME_RECORDS$name $target"$'\n'
        echo "  Добавлено: $name -> $target"
    fi
done

echo ""
echo "=== Ввод PTR-записей ==="
echo "Формат: IP_октет FQDN (например: 1 hq-srv.au-team.irpo)"
echo "Пустая строка - завершить ввод"
echo ""

PTR_RECORDS=""
while true; do
    read -p "PTR-запись: " octet fqdn
    if [[ -z "$octet" ]]; then
        break
    fi
    if [[ -n "$octet" && -n "$fqdn" ]]; then
        PTR_RECORDS="$PTR_RECORDS$octet $fqdn"$'\n'
        echo "  Добавлено: $octet -> $fqdn"
    fi
done

echo ""
echo "=== Параметры ==="
echo "DNS IP:      $DNS_IP"
echo "Домен:       $DOMAIN"
echo "Forwarders:  $FORWARDER1, $FORWARDER2"
echo "Обратная зона: $REVERSE_ZONE"
echo ""
echo "A-записи:"
echo "$A_RECORDS"
echo "CNAME-записи:"
echo "$CNAME_RECORDS"
echo "PTR-записи:"
echo "$PTR_RECORDS"

read -p "Продолжить? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Отменено"
    exit 0
fi

echo ""
echo "Установка BIND..."
apt-get update && apt-get install bind -y

echo "Остановка BIND..."
systemctl stop bind 2>/dev/null

echo "Создание директорий..."
mkdir -p /var/lib/bind/etc/zone

echo "Настройка options.conf..."
cat > /var/lib/bind/etc/options.conf <<EOF
listen-on { $DNS_IP; 127.0.0.1; };
listen-on-v6 { none; };
forwarders { $FORWARDER1; $FORWARDER2; };
allow-query { any; };
recursion yes;
EOF

echo "Настройка зон в rfc1912.conf..."
cat > /var/lib/bind/etc/rfc1912.conf <<EOF
zone "$DOMAIN" {
    type master;
    file "zone/$DOMAIN";
};

zone "$REVERSE_ZONE" {
    type master;
    file "zone/$REVERSE_ZONE";
};
EOF

echo "Создание прямой зоны..."
SERIAL=$(date +%Y%m%d01)
cat > /var/lib/bind/etc/zone/$DOMAIN <<EOF
\$TTL 86400
@ IN SOA ns1.$DOMAIN. root.$DOMAIN. (
    $SERIAL ; Serial
    3H         ; Refresh
    15M        ; Retry
    1W         ; Expire
    1D )       ; Minimum

@        IN NS      ns1.$DOMAIN.
@        IN A       $DNS_IP
ns1      IN A       $DNS_IP
EOF

while read name ip; do
    if [[ -n "$name" && -n "$ip" ]]; then
        echo "$name   IN A       $ip" >> /var/lib/bind/etc/zone/$DOMAIN
    fi
done <<< "$A_RECORDS"

while read name target; do
    if [[ -n "$name" && -n "$target" ]]; then
        echo "$name   IN CNAME   $target" >> /var/lib/bind/etc/zone/$DOMAIN
    fi
done <<< "$CNAME_RECORDS"

echo "Создание обратной зоны..."
LAST_OCTET=$(echo $DNS_IP | cut -d. -f4)
cat > /var/lib/bind/etc/zone/$REVERSE_ZONE <<EOF
\$TTL 86400
@ IN SOA ns1.$DOMAIN. root.$DOMAIN. (
    $SERIAL ; Serial
    3H         ; Refresh
    15M        ; Retry
    1W         ; Expire
    1D )       ; Minimum

@       IN NS   ns1.$DOMAIN.
$LAST_OCTET       IN PTR  ns1.$DOMAIN.
EOF

while read octet fqdn; do
    if [[ -n "$octet" && -n "$fqdn" ]]; then
        echo "$octet       IN PTR  $fqdn." >> /var/lib/bind/etc/zone/$REVERSE_ZONE
    fi
done <<< "$PTR_RECORDS"

echo "Генерация rndc.key..."
mkdir -p /etc/bind
rndc-confgen > /etc/bind/rndc.key
sed -i '6,$d' /etc/bind/rndc.key

echo "Установка прав..."
chown -R named:named /var/lib/bind/etc/zone

echo "Проверка конфигурации..."
named-checkconf 2>&1
named-checkzone $DOMAIN /var/lib/bind/etc/zone/$DOMAIN 2>&1
named-checkzone $REVERSE_ZONE /var/lib/bind/etc/zone/$REVERSE_ZONE 2>&1

echo "Запуск BIND..."
systemctl enable --now bind

echo ""
echo "DNS сервер настроен"
echo "Проверка: host ns1.$DOMAIN"
