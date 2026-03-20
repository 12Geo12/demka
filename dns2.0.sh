#!/bin/bash
# Исправленный скрипт настройки DHCP для ALT Linux
# Решает проблему с пустым списком интерфейсов

if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт от имени root"
   exit 1
fi

echo "=== Настройка DHCP сервера ==="
echo ""

# Функция для получения IP адреса интерфейса
get_ip() {
    ip -4 addr show dev "$1" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
}

# Функция для проверки состояния (UP/DOWN)
get_state() {
    cat /sys/class/net/"$1"/operstate 2>/dev/null
}

# 1. Поиск интерфейсов через /sys (самый надежный способ)
echo "Поиск доступных интерфейсов..."
ALL_IFACES=($(ls /sys/class/net))
VALID_IFACES=()

for iface in "${ALL_IFACES[@]}"; do
    # Пропускаем loopback
    if [[ "$iface" == "lo" ]]; then continue; fi
    
    IP_ADDR=$(get_ip "$iface")
    STATE=$(get_state "$iface")

    # Логирование для отладки (покажет, что скрипт видит)
    # echo " -> Проверка $iface: State=$STATE, IP=$IP_ADDR" 

    # Если интерфейс включен (UP) и имеет IP адрес
    if [[ -n "$IP_ADDR" ]]; then
        VALID_IFACES+=("$iface ($IP_ADDR)")
    fi
done

if [ ${#VALID_IFACES[@]} -eq 0 ]; then
    echo "*****************************************************"
    echo "ОШИБКА: Не найдено интерфейсов с IP-адресами!"
    echo "*****************************************************"
    echo ""
    echo "Ваша сеть не настроена. Список всех найденных интерфейсов:"
    for iface in "${ALL_IFACES[@]}"; do
        STATE=$(get_state "$iface")
        IP=$(get_ip "$iface")
        echo " - $iface (Статус: $STATE, IP: ${IP:-'Отсутствует'})"
    done
    echo ""
    echo "Сначала настройте сеть (назначьте IP адреса) через:"
    echo "  nmtui   (NetworkManager Text UI)"
    echo "  или отредактируйте файлы в /etc/net/ifaces/"
    exit 1
fi

echo "Выберите интерфейс, на котором будет работать DHCP (локальная сеть):"
PS3="Введите номер интерфейса: "
select item in "${VALID_IFACES[@]}" "Выход"; do
    if [[ "$item" == "Выход" ]]; then exit 0; fi
    if [[ -n "$item" ]]; then
        LAN_IFACE=$(echo "$item" | cut -d' ' -f1)
        LAN_IP=$(echo "$item" | cut -d'(' -f2 | tr -d ')')
        break
    else
        echo "Неверный выбор, попробуйте еще раз."
    fi
done

echo ""
echo "Выбран интерфейс: $LAN_IFACE"
echo "IP адрес: $LAN_IP"

# Определение подсети
O1=$(echo $LAN_IP | cut -d. -f1)
O2=$(echo $LAN_IP | cut -d. -f2)
O3=$(echo $LAN_IP | cut -d. -f3)
SUBNET="${O1}.${O2}.${O3}"

echo "Определена подсеть: $SUBNET.0"
read -p "Введите начало диапазона выдачи (последний октет, напр. 10): " START
read -p "Введите конец диапазона выдачи (последний октет, напр. 50): " END
read -p "Шлюз по умолчанию (нажмите Enter, чтобы использовать $LAN_IP): " ROUTER
ROUTER=${ROUTER:-$LAN_IP}

# Задаем домен (если еще не задан)
read -p "Имя домена (напр. au-team.irpo): " DOMAIN

echo ""
echo "=== Генерация конфигурации ==="
echo "Интерфейс: $LAN_IFACE"
echo "Сеть: $SUBNET.0"
echo "Диапазон: $SUBNET.$START - $SUBNET.$END"

# Установка
echo "Установка пакета dhcp-server..."
apt-get update > /dev/null 2>&1
apt-get install dhcp-server -y > /dev/null 2>&1

# Создание конфига
cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
 authoritative;

subnet $SUBNET.0 netmask 255.255.255.0 {
  range $SUBNET.$START $SUBNET.$END;
  option domain-name-servers $LAN_IP;
  option domain-name "$DOMAIN";
  option routers $ROUTER;
  option broadcast-address $SUBNET.255;
}
EOF

# Указываем интерфейс для прослушивания
echo "$LAN_IFACE" > /etc/dhcp/dhcpd.interfaces

# Настройка службы
systemctl stop dhcpd 2>/dev/null
systemctl enable dhcpd

echo ""
echo "=== Проверка конфигурации ==="
dhcpd -t -cf /etc/dhcp/dhcpd.conf

if [ $? -eq 0 ]; then
    echo "Конфигурация верна. Запуск службы..."
    systemctl start dhcpd
    systemctl status dhcpd --no-pager
    echo "Готово!"
else
    echo "ОШИБКА в конфигурации! Проверьте вводимые данные."
fi
