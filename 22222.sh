#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Запустите через sudo."
  exit
fi

echo "========================================"
echo "   ПОЛНАЯ ОЧИСТКА И НАСТРОЙКА"
echo "========================================"

# --- ШАГ 1: ГЛУБОКАЯ ОЧИСТКА ---
echo ""
echo "ШАГ 1: Очистка всех старых правил блокировки..."

# 1. Сброс iptables
iptables -F
iptables -t nat -F
iptables -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 2. Очистка /etc/hosts (Удаляем ВСЕ лишние перенаправления на 127.0.0.1, кроме localhost)
echo "Очистка файла /etc/hosts от старых блокировок..."
# Резервное копирование
cp /etc/hosts /etc/hosts.bak
# Удаляем строки, начинающиеся с 127.0.0.1, если там НЕТ слова localhost
sed -i '/^127\.0\.0\.1/!b; /localhost/!d' /etc/hosts

# --- ШАГ 2: СЕТЬ ---
echo ""
echo "ШАГ 2: Настройка сети"
systemctl stop NetworkManager 2>/dev/null
systemctl disable NetworkManager 2>/dev/null

echo "Интерфейсы:"
ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
read -p "Имя интерфейса (ens33): " IFACE

read -p "Шлюз (Gateway): " GW
read -p "IP адрес (напр. 192.168.56.101/24): " IP
read -p "DNS (8.8.8.8): " DNS

DIR="/etc/net/ifaces/$IFACE"
mkdir -p $DIR

echo "TYPE=eth" > $DIR/options
echo "BOOTPROTO=static" >> $DIR/options
echo "ONBOOT=yes" >> $DIR/options
echo "CONFIG_IPV4=yes" >> $DIR/options
echo "$IP" > $DIR/ipv4address
echo "default via $GW" > $DIR/ipv4route
echo "nameserver $DNS" > $DIR/resolv.conf

systemctl enable network
systemctl restart network
sleep 2
echo "nameserver $DNS" > /etc/resolv.conf

# --- ШАГ 3: NAT ---
echo "ШАГ 3: NAT"
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

# --- ШАГ 4: ПОЛЬЗОВАТЕЛИ ---
echo ""
echo "ШАГ 4: Пользователи"
read -sp "Пароль root: " P_ROOT
echo
echo "root:$P_ROOT" | chpasswd

add_u() {
    if id "$1" &>/dev/null; then echo "$1:$2" | chpasswd; 
    else useradd -m -s /bin/bash "$1" && echo "$1:$2" | chpasswd; fi
}

read -p "Логин 1: " U1
[ ! -z "$U1" ] && read -sp "Пароль: " P1 && echo && add_u "$U1" "$P1"
read -p "Логин 2: " U2
[ ! -z "$U2" ] && read -sp "Пароль: " P2 && echo && add_u "$U2" "$P2"

# --- ШАГ 5: БЛОКИРОВКА ---
echo ""
echo "ШАГ 5: Блокировка сайтов"
read -p "Введите ТОЛЬКО те сайты, которые нужно заблокировать (через пробел): " SITES_INPUT

# Если ввели пустую строку - блокируем тестовые, чтобы проверить работу
if [ -z "$SITES_INPUT" ]; then
    echo "Сайты не указаны, ничего не блокирую (интернет должен быть везде)."
else
    BLOCKED_SITES=($SITES_INPUT)
    for site in "${BLOCKED_SITES[@]}"; do
        echo "Блокирую: $site"
        echo "127.0.0.1 $site" >> /etc/hosts
        
        # Резолвим IP для форварда
        IP_S=$(nslookup $site 2>/dev/null | grep -A 1 'Name:' | tail -n 1 | awk '{print $2}')
        if [[ $IP_S =~ ^[0-9] ]]; then
            iptables -A FORWARD -d $IP_S -j REJECT
        fi
    done
fi

iptables-save > /etc/iptables.rules

echo ""
echo "ГОТОВО."
echo "Теперь ping должен проходить на все сайты, кроме тех, что вы ввели."
