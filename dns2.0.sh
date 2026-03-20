#!/bin/bash
# Исправленный скрипт настройки DNS (BIND) для ALT Linux
# Решает проблему с определением интерфейсов и VLAN

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт нужно запускать от имени root"
   exit 1
fi

echo "=== Настройка DNS сервера BIND ==="
echo ""

# 1. Надежное определение IP адреса
# Ищем первый физический интерфейс (начинается с 'e', например ens33, eth0), 
# исключаем VLAN (содержат точку) и Loopback.
IFACE=$(ip -br link show | grep -E '^e[tn][hs][0-9]+' | grep -v '\.' | awk '{print $1}' | head -1)

if [[ -z "$IFACE" ]]; then
    echo "Ошибка: Не удалось определить физический интерфейс."
    echo "Доступные интерфейсы:"
    ip -br link show
    read -p "Введите имя интерфейса вручную (например, ens33): " IFACE
fi

# Получаем IP выбранного интерфейса
DNS_IP=$(ip -4 addr show dev "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [[ -z "$DNS_IP" ]]; then
    echo "Ошибка: На интерфейсе $IFACE нет IP-адреса."
    exit 1
fi

echo "Используемый интерфейс: $IFACE"
echo "Определён IP адрес:     $DNS_IP"
echo ""

# 2. Ввод основных данных
# В заданиях часто используется домен au-team.irpo или类似ное
read -p "Имя домена (например, au-team.irpo): " DOMAIN
read -p "Forwarder DNS 1 (например, 8.8.8.8 или IP шлюза): " FORWARDER1
read -p "Forwarder DNS 2 (необязательно): " FORWARDER2

# Вычисление имени обратной зоны
OCTET1=$(echo "$DNS_IP" | cut -d. -f1)
OCTET2=$(echo "$DNS_IP" | cut -d. -f2)
OCTET3=$(echo "$DNS_IP" | cut -d. -f3)
REVERSE_ZONE="${OCTET3}.${OCTET2}.${OCTET1}.in-addr.arpa"

# 3. Ввод записей
echo ""
echo "=== Ввод A-записей (Имя хоста -> IP) ==="
echo "Формат: имя IP (пример: hq-srv 192.168.1.10)"
echo "Оставьте пустую строку для завершения."

# Массивы для хранения записей (нужно для корректного вывода в файл)
declare -a A_NAMES
declare -a A_IPS

while true; do
    read -p "A-запись: " input
    if [[ -z "$input" ]]; then break; fi
    # Разбиваем ввод на имя и IP
    name=$(echo "$input" | awk '{print $1}')
    ip=$(echo "$input" | awk '{print $2}')
    if [[ -n "$name" && -n "$ip" ]]; then
        A_NAMES+=("$name")
        A_IPS+=("$ip")
        echo "  -> Добавлено: $name ($ip)"
    fi
done

echo ""
echo "=== Ввод CNAME-записей (Псевдонимы) ==="
echo "Формат: псевдоним реальное_имя (пример: www hq-srv)"
echo "Оставьте пустую строку для завершения."

declare -a CNAME_ALIAS
declare -a CNAME_TARGET

while true; do
    read -p "CNAME: " input
    if [[ -z "$input" ]]; then break; fi
    alias_name=$(echo "$input" | awk '{print $1}')
    target_name=$(echo "$input" | awk '{print $2}')
    if [[ -n "$alias_name" && -n "$target_name" ]]; then
        CNAME_ALIAS+=("$alias_name")
        CNAME_TARGET+=("$target_name")
        echo "  -> Добавлено: $alias_name -> $target_name"
    fi
done

# 4. Подтверждение
echo ""
echo "=== Проверка перед применением ==="
echo "Домен:       $DOMAIN"
echo "DNS IP:      $DNS_IP"
echo "Обратная зона: $REVERSE_ZONE"
echo "A-записей:   ${#A_NAMES[@]}"
echo "CNAME:       ${#CNAME_ALIAS[@]}"
read -p "Все верно? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo "Отмена операции."
    exit 0
fi

# 5. Установка и настройка
echo ""
echo "[1/6] Установка пакетов..."
apt-get update > /dev/null 2>&1
apt-get install bind -y > /dev/null 2>&1

echo "[2/6] Остановка службы для настройки..."
systemctl stop bind 2>/dev/null

echo "[3/6] Создание файлов конфигурации..."
mkdir -p /var/lib/bind/etc/zone

# Настройка options.conf
cat > /var/lib/bind/etc/options.conf <<EOF
listen-on { $DNS_IP; 127.0.0.1; };
listen-on-v6 { none; };
forwarders { $FORWARDER1; $FORWARDER2; };
allow-query { any; };
recursion yes;
EOF

# Настройка зон
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

echo "[4/6] Генерация файлов зон..."
SERIAL=$(date +%Y%m%d01)
LAST_OCTET=$(echo "$DNS_IP" | cut -d. -f4)

# Прямая зона
cat > /var/lib/bind/etc/zone/$DOMAIN <<EOF
\$TTL 86400
@ IN SOA ns1.$DOMAIN. root.$DOMAIN. (
    $SERIAL ; Serial
    3H      ; Refresh
    15M     ; Retry
    1W      ; Expire
    1D )    ; Minimum

@        IN NS      ns1.$DOMAIN.
@        IN A       $DNS_IP
ns1      IN A       $DNS_IP
EOF

# Добавление A-записей в файл зоны
for i in "${!A_NAMES[@]}"; do
    echo "${A_NAMES[$i]}   IN A       ${A_IPS[$i]}" >> /var/lib/bind/etc/zone/$DOMAIN
done

# Добавление CNAME
for i in "${!CNAME_ALIAS[@]}"; do
    echo "${CNAME_ALIAS[$i]}   IN CNAME   ${CNAME_TARGET[$i]}" >> /var/lib/bind/etc/zone/$DOMAIN
done

# Обратная зона
cat > /var/lib/bind/etc/zone/$REVERSE_ZONE <<EOF
\$TTL 86400
@ IN SOA ns1.$DOMAIN. root.$DOMAIN. (
    $SERIAL ; Serial
    3H      ; Refresh
    15M     ; Retry
    1W      ; Expire
    1D )    ; Minimum

@       IN NS   ns1.$DOMAIN.
 $LAST_OCTET       IN PTR  ns1.$DOMAIN.
EOF

# Добавление PTR записей (если A-записи в этой же подсети)
for i in "${!A_NAMES[@]}"; do
    # Проверяем, совпадает ли подсеть
    REC_SUBNET=$(echo "${A_IPS[$i]}" | cut -d. -f1-3)
    CUR_SUBNET=$(echo "$DNS_IP" | cut -d. -f1-3)
    if [[ "$REC_SUBNET" == "$CUR_SUBNET" ]]; then
        OCTET=$(echo "${A_IPS[$i]}" | cut -d. -f4)
        echo "$OCTET       IN PTR  ${A_NAMES[$i]}.$DOMAIN." >> /var/lib/bind/etc/zone/$REVERSE_ZONE
    fi
done

echo "[5/6] Настройка прав и ключей..."
mkdir -p /etc/bind
rndc-confgen > /etc/bind/rndc.key
sed -i '6,$d' /etc/bind/rndc.key
chown -R named:named /var/lib/bind/etc/zone

echo "[6/6] Проверка и запуск..."
# Вывод проверок для наглядности
echo "--- Проверка конфигурации ---"
named-checkconf
named-checkzone "$DOMAIN" /var/lib/bind/etc/zone/$DOMAIN
named-checkzone "$REVERSE_ZONE" /var/lib/bind/etc/zone/$REVERSE_ZONE
echo "----------------------------"

systemctl enable --now bind

echo ""
echo "=== Готово! ==="
echo "Проверка работы DNS:"
sleep 2
host ns1.$DOMAIN 127.0.0.1
