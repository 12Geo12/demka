#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (используйте sudo)."
  exit
fi

clear
echo "========================================"
echo "   ЭКЗАМЕН: АЛЬТ СЕРВЕР (РЕШЕНИЕ ПРОБЛЕМЫ IP)"
echo "========================================"

# ==========================================
# БЛОК 1: НАСТРОЙКА СЕТИ (ИСПРАВЛЕННАЯ)
# ==========================================
echo ""
echo "===== БЛОК 1: Настройка сети ====="

# ВАЖНО: Отключаем NetworkManager, чтобы он не перебивал настройки /etc/net
echo "Останавливаю NetworkManager для применения статических настроек..."
systemctl stop NetworkManager 2>/dev/null
systemctl disable NetworkManager 2>/dev/null

echo "Доступные интерфейсы:"
interfaces=$(ls /sys/class/net | grep -v lo)

select IFACE in $interfaces; do
    if [ -n "$IFACE" ]; then
        echo "Выбран интерфейс: $IFACE"
        break
    else
        echo "Неверный выбор, попробуйте снова."
    fi
done

DIR="/etc/net/ifaces/$IFACE"
mkdir -p $DIR

echo "Тип настройки:"
echo "1 - DHCP"
echo "2 - Статический IP (для задания)"

read -p "Выберите вариант (рекомендуется 2): " mode

if [ "$mode" == "1" ]; then
    # Настройка DHCP
    echo "TYPE=eth" > $DIR/options
    echo "BOOTPROTO=dhcp" >> $DIR/options
    echo "ONBOOT=yes" >> $DIR/options
    # Очистка старых статических файлов
    rm -f $DIR/ipv4route $DIR/ipv4address $DIR/resolv.conf

elif [ "$mode" == "2" ]; then
    # Настройка Static IP
    read -p "Введите IP (пример 192.168.1.10/24): " IP
    read -p "Введите шлюз (route) [Важно]: " GW
    read -p "Введите DNS [напр. 8.8.8.8]: " DNS

    # Запись основных опций
    echo "TYPE=eth" > $DIR/options
    echo "BOOTPROTO=static" >> $DIR/options
    echo "ONBOOT=yes" >> $DIR/options
    # CONFIG_IPV4=yes обычно включен по умолчанию, но на всякий случай
    echo "CONFIG_IPV4=yes" >> $DIR/options

    # Запись адреса
    echo "$IP" > $DIR/ipv4address

    # Запись шлюза
    if [ ! -z "$GW" ]; then
        echo "default via $GW" > $DIR/ipv4route
    else
        rm -f $DIR/ipv4route
    fi

    # Запись DNS
    if [ ! -z "$DNS" ]; then
        echo "nameserver $DNS" > $DIR/resolv.conf
        # Сразу применяем системно, чтобы ping пошел
        echo "nameserver $DNS" > /etc/resolv.conf
    else
        rm -f $DIR/resolv.conf
    fi

else
    echo "Неверный выбор"
    exit 1
fi

# ВАЖНО: Включаем службу network в автозагрузку и перезапускаем её
echo "Включаю сеть в автозагрузку..."
systemctl enable network
echo "Перезапускаю сеть..."
systemctl restart network

# Пауза для поднятия интерфейса
sleep 3
echo "Сеть настроена и сохранена."

# ==========================================
# БЛОК 2: НАСТРОЙКА ПОЛЬЗОВАТЕЛЕЙ
# ==========================================
echo ""
echo "===== БЛОК 2: Настройка пользователей ====="
read -sp "Введите новый пароль для root: " ROOT_PASS
echo
echo "Создание пользователей (Enter - завершение):"
USERS=()
while true; do
    read -p "Логин: " U_NAME
    [ -z "$U_NAME" ] && break
    read -sp "Пароль: " U_PASS
    echo
    USERS+=("$U_NAME:$U_PASS")
done

# Применяем
echo "root:$ROOT_PASS" | chpasswd
for entry in "${USERS[@]}"; do
    u=$(echo "$entry" | cut -d: -f1)
    p=$(echo "$entry" | cut -d: -f2)
    if id "$u" &>/dev/null; then
        echo "Пользователь $u существует. Пароль обновлен."
    else
        useradd -m -s /bin/bash "$u"
    fi
    echo "$u:$p" | chpasswd
done

# ==========================================
# БЛОК 3: NAT И БЛОКИРОВКА
# ==========================================
echo ""
echo "===== БЛОК 3: NAT и Firewall ====="

echo "Включаю пересылку пакетов..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Чтобы forward сохранялся после перезагрузки, лучше раскомментировать в /etc/sysctl.conf
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null
sysctl -p 2>/dev/null

echo "Очистка старых правил..."
iptables -F
iptables -t nat -F
iptables -X

echo "Настройка NAT на интерфейсе $IFACE..."
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

# Политики по умолчанию
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Блокировка сайтов
echo "Введите сайты для блокировки (через пробел): "
read SITES_INPUT
BLOCKED_SITES=($SITES_INPUT)

echo "Применение блокировки..."
for site in "${BLOCKED_SITES[@]}"; do
    echo " -> Блокирую $site"
    
    # Резолвинг IP
    if command -v dig &> /dev/null; then
        IP_LIST=$(dig +short $site | grep -E '^[0-9]')
    else
        IP_LIST=$(nslookup $site 2>/dev/null | grep Address | grep -v '#53' | awk '{print $2}')
    fi

    for ip in $IP_LIST; do
        iptables -A OUTPUT -d $ip -j REJECT
        iptables -A FORWARD -d $ip -j REJECT
    done
    
    # Блокировка по строке (доменное имя)
    iptables -A OUTPUT -p tcp --dport 80 -m string --string "$site" --algo bm -j REJECT
    iptables -A OUTPUT -p tcp --dport 443 -m string --string "$site" --algo bm -j REJECT
done

# Сохранение правил (метод для Альт)
iptables-save > /etc/iptables.rules

# Если есть сервис iptables (часто в Альт), пробуем сохранить и через него
if [ -f /etc/init.d/iptables ]; then
    /etc/init.d/iptables save 2>/dev/null
fi

echo ""
echo "========================================"
echo "   ГОТОВО. НАСТРОЙКИ СОХРАНЕНЫ."
echo "========================================"
echo "1. Служба network включена в автозагрузку."
echo "2. NetworkManager отключен (чтобы не сбивал настройки)."
echo "3. IP, пользователи и Firewall настроены."
