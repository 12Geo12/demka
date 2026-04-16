#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Запустите через sudo."
  exit
fi

clear
echo "========================================"
echo "   ЭКЗАМЕН: АЛЬТ СЕРВЕР (УСИЛЕННАЯ БЛОКИРОВКА)"
echo "========================================"

# --- БЛОК 1: СЕТЬ ---
echo ""
echo "===== БЛОК 1: Настройка сети ====="

# Отключаем NetworkManager для чистоты эксперимента
systemctl stop NetworkManager 2>/dev/null
systemctl disable NetworkManager 2>/dev/null

echo "Доступные интерфейсы:"
select IFACE in $(ls /sys/class/net | grep -v lo); do
    [ -n "$IFACE" ] && break
done

DIR="/etc/net/ifaces/$IFACE"
mkdir -p $DIR

read -p "IP (напр. 192.168.1.10/24): " IP
read -p "Шлюз (напр. 192.168.1.1): " GW
read -p "DNS (напр. 8.8.8.8): " DNS

echo "TYPE=eth" > $DIR/options
echo "BOOTPROTO=static" >> $DIR/options
echo "ONBOOT=yes" >> $DIR/options
echo "CONFIG_IPV4=yes" >> $DIR/options
echo "$IP" > $DIR/ipv4address
[ ! -z "$GW" ] && echo "default via $GW" > $DIR/ipv4route
[ ! -z "$DNS" ] && echo "nameserver $DNS" > $DIR/resolv.conf

systemctl enable network
systemctl restart network
sleep 3
echo "nameserver $DNS" > /etc/resolv.conf

# --- БЛОК 2: ПОЛЬЗОВАТЕЛИ ---
echo ""
echo "===== БЛОК 2: Пользователи ====="
read -sp "Пароль root: " P_ROOT
echo
echo "root:$P_ROOT" | chpasswd

read -p "Логин 1 (Enter если нет): " U1
[ ! -z "$U1" ] && read -sp "Пароль $U1: " P1 && echo && useradd -m $U1 && echo "$U1:$P1" | chpasswd
read -p "Логин 2 (Enter если нет): " U2
[ ! -z "$U2" ] && read -sp "Пароль $U2: " P2 && echo && useradd -m $U2 && echo "$U2:$P2" | chpasswd

# --- БЛОК 3: FIREWALL И БЛОКИРОВКА ---
echo ""
echo "===== БЛОК 3: Блокировка сайтов (Улучшенная) ====="

# 1. Загружаем модули для работы со строками (КРИТИЧНО ВАЖНО)
modprobe xt_string
modprobe nf_conntrack

echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# Очистка
iptables -F
iptables -t nat -F
iptables -X

# NAT
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

# Политики
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

read -p "Введите сайты для блокировки (через пробел, напр. ya.ru vk.com): " SITES_INPUT
BLOCKED_SITES=($SITES_INPUT)

echo "Начинаю блокировку..."
for site in "${BLOCKED_SITES[@]}"; do
    echo " -> Блокирую $site ..."
    
    # СПОСОБ 1: Резолвинг IP и блокировка по IP
    # Используем более надежные методы получения IP
    SITE_IPS=$(dig +short $site | grep -E '^[0-9]')
    
    if [ -z "$SITE_IPS" ]; then
        # Если dig не сработал, пробуем getent (бывает в Alt)
        SITE_IPS=$(getent hosts $site | awk '{print $1}')
    fi

    if [ ! -z "$SITE_IPS" ]; then
        for ip in $SITE_IPS; do
            echo "    [+] Найден IP: $ip -> БЛОКИРУЮ"
            iptables -A OUTPUT -d $ip -j REJECT
            iptables -A FORWARD -d $ip -j REJECT
        done
    else
        echo "    [!] Не удалось определить IP для $site"
    fi

    # СПОСОБ 2: Блокировка по имени (String Match)
    # Блокируем HTTP и HTTPS пакеты, содержащие имя сайта
    # Работает лучше, если модуль загружен (сделано выше)
    iptables -A OUTPUT -p tcp --dport 80 -m string --string "$site" --algo bm -j REJECT --reject-with tcp-reset
    iptables -A OUTPUT -p tcp --dport 443 -m string --string "$site" --algo bm -j REJECT --reject-with tcp-reset
    
    # СПОСОБ 3: Блокировка DNS запросов к этому домену
    # Если система не узнает IP, она и не зайдет.
    # Блокируем UDP пакеты на порт 53 (DNS), содержащие имя сайта
    iptables -A OUTPUT -p udp --dport 53 -m string --string "$site" --algo bm -j DROP
done

# Сохранение
iptables-save > /etc/iptables.rules

echo ""
echo "========================================"
echo "   ГОТОВО"
echo "========================================"
echo "Проверьте блокировку командой:"
echo "ping ya.ru"
echo "curl ya.ru"
