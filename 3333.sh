#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (используйте sudo)."
  exit
fi

clear
echo "========================================"
echo "   ЭКЗАМЕН: АЛЬТ СЕРВЕР (ПОЛНАЯ ВЕРСИЯ)"
echo "========================================"

# ==========================================
# БЛОК 1: НАСТРОЙКА СЕТИ (ВАША ЛОГИКА ИЗ 1.1.ipnet.sh)
# ==========================================
echo ""
echo "===== Настройка сети ====="

echo "Доступные интерфейсы:"
interfaces=$(ls /sys/class/net | grep -v lo)

select IFACE in $interfaces
do
    if [ -n "$IFACE" ]; then
        break
    else
        echo "Неверный выбор"
    fi
done

DIR="/etc/net/ifaces/$IFACE"
# Создаем директорию для интерфейса, если её нет
mkdir -p $DIR

echo "Выбран интерфейс: $IFACE"

echo "Тип настройки:"
echo "1 - DHCP"
echo "2 - Статический IP"

read -p "Выберите вариант (2 - для экзамена): " mode

if [ "$mode" == "1" ]; then

    echo "TYPE=eth" > $DIR/options
    echo "BOOTPROTO=dhcp" >> $DIR/options
    echo "ONBOOT=yes" >> $DIR/options

    echo "DHCP=yes" > $DIR/ipv4address
    # Удаляем старые статические файлы
    rm -f $DIR/ipv4route $DIR/ipv4address

elif [ "$mode" == "2" ]; then

    read -p "Введите IP (пример 192.168.56.100/24): " IP
    read -p "Введите шлюз (route) [Важно]: " GW
    read -p "Введите DNS [пример 8.8.8.8]: " DNS

    echo "TYPE=eth" > $DIR/options
    echo "BOOTPROTO=static" >> $DIR/options
    echo "ONBOOT=yes" >> $DIR/options
    
    # ВАЖНО: Добавляем автоматическую загрузку правил iptables
    if ! grep -q "RESTORIPTABLES=yes" $DIR/options; then
        echo "RESTORIPTABLES=yes" >> $DIR/options
    fi

    echo "$IP" > $DIR/ipv4address

    # если указан шлюз
    if [ ! -z "$GW" ]; then
        echo "default via $GW" > $DIR/ipv4route
    fi

    # если указан DNS
    if [ ! -z "$DNS" ]; then
        echo "nameserver $DNS" > $DIR/resolv.conf
        # Сразу применяем DNS для текущей сессии
        echo "nameserver $DNS" > /etc/resolv.conf
    fi

else
    echo "Неверный выбор"
    exit 1
fi

echo "Перезапуск сети..."
systemctl restart network

# Небольшая пауза для инициализации
sleep 2

# ==========================================
# БЛОК 2: НАСТРОЙКА ПОЛЬЗОВАТЕЛЕЙ
# ==========================================
echo ""
echo "===== Настройка пользователей ====="

read -sp "Введите пароль для root: " ROOT_PASS
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

# Применяем пользователей
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
# БЛОК 3: НАСТРОЙКА NAT И FIREWALL
# ==========================================
echo ""
echo "===== Настройка NAT и Блокировка ====="

# 1. Включаем NAT
echo "Включаю пересылку пакетов..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# 2. Настраиваем sysctl для сохранения forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null

# 3. Очищаем правила (чтобы не было дублей)
iptables -F
iptables -t nat -F
iptables -X

# 4. Настраиваем NAT
# Определяем интерфейс для NAT. 
# Если настроили через ваш скрипт, интерфейс $IFACE уже в сети.
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

# Разрешаем трафик
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 5. Блокировка сайтов
echo "Введите сайты для блокировки (через пробел): "
read SITES_INPUT
BLOCKED_SITES=($SITES_INPUT)

echo "Применение блокировки..."
for site in "${BLOCKED_SITES[@]}"; do
    echo " -> Блокирую $site"
    
    # Способ 1: /etc/hosts (блокировка по имени на самой машине)
    echo "127.0.0.1 $site" >> /etc/hosts
    
    # Способ 2: IP Блокировка (для сетевых клиентов)
    # Используем nslookup вместо dig для совместимости
    IP_LIST=$(nslookup $site 2>/dev/null | grep Address | grep -v '#53' | awk '{print $2}')
    
    for ip in $IP_LIST; do
        if [[ $ip =~ ^[0-9] ]]; then
            iptables -A FORWARD -d $ip -j REJECT
        fi
    done
done

# Сохраняем правила (для системы)
iptables-save > /etc/iptables.rules

echo ""
echo "========================================"
echo "   ГОТОВО"
echo "========================================"
echo "1. IP адрес СОХРАНЯЕТСЯ после перезагрузки (через /etc/net/ifaces)."
echo "2. Правила Firewall СОХРАНЯЮТСЯ (через RESTORIPTABLES=yes)."
echo "3. NAT, Пользователи и Блокировка настроены."
