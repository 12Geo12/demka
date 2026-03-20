#!/bin/bash
# Скрипт настройки DHCP сервера для ALT Linux (Задание 9)
# Исправляет проблему с определением VLAN и виртуальных интерфейсов

if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт от имени root"
   exit 1
fi

echo "=== Настройка DHCP сервера ==="
echo ""

# 1. Поиск активных интерфейсов с IP-адресами
# Фильтруем: ищем интерфейсы с инетом, исключая lo (127.0.0.1) и несуществующие
echo "Поиск доступных интерфейсов..."
MAPFILE=($(ip -4 addr show | grep -oP '(?<=\d:\s)[a-z0-9\.]+(?=:)' | sort -u | uniq))
ACTIVE_IFACES=()

for iface in "${MAPFILE[@]}"; do
    # Проверяем, есть ли у интерфейса IP (не loopback) и интерфейс UP
    STATE=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
    IP_ADDR=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    # Пропускаем интерфейсы без состояния, loopback и без IP
    if [[ "$STATE" == *"UP"* && -n "$IP_ADDR" && "$iface" != "lo" ]]; then
        ACTIVE_IFACES+=("$iface:$IP_ADDR")
    fi
done

if [ ${#ACTIVE_IFACES[@]} -lt 1 ]; then
    echo "Ошибка: Не найдено активных интерфейсов с IP-адресами."
    echo "Проверьте настройки сети (ip a)."
    exit 1
fi

echo "Найдены активные интерфейсы:"
PS3="Выберите интерфейс для ЛОКАЛЬНОЙ СЕТИ (где будет раздаваться DHCP): "
select item in "${ACTIVE_IFACES[@]}" "Выход"; do
    if [[ "$item" == "Выход" ]]; then exit 0; fi
    if [[ -n "$item" ]]; then
        LAN_IFACE=$(echo "$item" | cut -d: -f1)
        LAN_IP=$(echo "$item" | cut -d: -f2)
        break
    fi
done

echo ""
echo "Выбран интерфейс: $LAN_IFACE ($LAN_IP)"

# Определение подсети автоматически
IFS='.' read -r o1 o2 o3 o4 <<< "$LAN_IP"
SUBNET="${o1}.${o2}.${o3}"
# Простой расчет маски (предполагаем /24)
MASK="255.255.255.0"
ROUTER_IP="$LAN_IP"
DNS_IP="$LAN_IP"

echo "Определена подсеть: $SUBNET.0/$MASK"
echo ""

# 2. Ввод параметров пула
echo "=== Настройка пула адресов ==="
read -p "Начало диапазона (последний октет, например 10): " RANGE_START
read -p "Конец диапазона (последний октет, например 50): " RANGE_END

read -p "Имя домена (например, au-team.irpo): " DOMAIN_NAME
read -p "Адрес шлюза (по умолчанию $ROUTER_IP): " CONF_ROUTER
ROUTER_IP=${CONF_ROUTER:-$ROUTER_IP}

read -p "DNS сервер (по умолчанию $DNS_IP): " CONF_DNS
DNS_IP=${CONF_DNS:-$DNS_IP}

echo ""
echo "=== Параметры DHCP ==="
echo "Интерфейс: $LAN_IFACE"
echo "Сеть:      $SUBNET.0"
echo "Диапазон:  $SUBNET.$RANGE_START - $SUBNET.$RANGE_END"
echo "Шлюз:      $ROUTER_IP"
echo "DNS:       $DNS_IP"
echo "Домен:     $DOMAIN_NAME"
read -p "Продолжить? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo "Отмена."
    exit 0
fi

# 3. Установка и конфигурация
echo ""
echo "[1/3] Установка dhcpd..."
apt-get update > /dev/null 2>&1
apt-get install dhcp-server -y > /dev/null 2>&1

echo "[2/3] Создание конфигурации /etc/dhcp/dhcpd.conf..."
# Создаем конфиг с правильными кавычками
cat > /etc/dhcp/dhcpd.conf <<EOF
# DNS Update settings
ddns-update-style interim;
ignore client-updates;

# Локальная подсеть
subnet $SUBNET.0 netmask $MASK {
    option routers $ROUTER_IP;
    option subnet-mask $MASK;
    option domain-name "$DOMAIN_NAME";
    option domain-name-servers $DNS_IP;
    
    # Диапазон выдачи
    range $SUBNET.$RANGE_START $SUBNET.$RANGE_END;
    
    default-lease-time 3600;
    max-lease-time 7200;
}
EOF

# Настройка файла интерфейсов
echo "$LAN_IFACE" > /etc/dhcp/dhcpd.interfaces

echo "[3/3] Включение и запуск службы..."
systemctl enable --now dhcpd

sleep 2
echo ""
echo "=== Проверка состояния ==="
systemctl status dhcpd --no-pager

echo ""
if systemctl is-active --quiet dhcpd; then
    echo "Успех: DHCP сервер запущен и слушает на интерфейсе $LAN_IFACE."
    echo "Проверить выдачу адреса можно командой на клиенте: dhclient -v <интерфейс>"
else
    echo "Ошибка: Сервер не запустился. Проверьте 'journalctl -xeu dhcpd'."
fi
