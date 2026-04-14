#!/bin/bash

# Проверка на запуск от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (используйте sudo)."
  exit
fi

echo "=================================================="
echo "   СКРИПТ НАСТРОЙКИ ДЛЯ ЭКЗАМЕНА (ПМ.03 Вариант 13)"
echo "=================================================="
echo ""

# --- 1. НАСТРОЙКА СЕТИ ---
echo "[ШАГ 1] Настройка сетевого интерфейса"
echo "Список доступных интерфейсов:"
ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'

read -p "Введите имя интерфейса (например, eth0 или ens33): " IFACE
read -p "Введите IP-адрес (например, 192.168.1.100/24): " IP_CIDR
read -p "Введите Шлюз (Gateway, например, 192.168.1.1): " GATEWAY
read -p "Введите DNS (например, 8.8.8.8): " DNS_SERVER

# --- 2. НАСТРОЙКА ПАРОЛЯ ROOT ---
echo ""
echo "[ШАГ 2] Настройка пароля суперпользователя (root)"
read -sp "Введите новый пароль для root: " ROOT_PASS
echo

# --- 3. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЕЙ ---
echo ""
echo "[ШАГ 3] Создание пользователей"
echo "Вводите пользователей по одному. Оставьте имя пустым и нажмите Enter, чтобы завершить."

USERS=()
while true; do
    read -p "Введите имя логина (или Enter для завершения): " USERNAME
    if [ -z "$USERNAME" ]; then
        break
    fi
    read -sp "Введите пароль для пользователя $USERNAME: " USER_PASS
    echo
    USERS+=("$USERNAME:$USER_PASS")
done

# --- 4. БЛОКИРОВКА САЙТОВ ---
echo ""
echo "[ШАГ 4] Блокировка DNS-имен (Firewall)"
echo "Введите сайты для блокировки через пробел (например: twitter.com tiktok.com vk.com)"
read -p "Сайты для блокировки: " SITES_INPUT

# Преобразуем строку в массив
BLOCKED_SITES=($SITES_INPUT)

# --- ПРИМЕНЕНИЕ НАСТРОЕК ---
echo ""
echo "=================================================="
echo "   ПРИМЕНЕНИЕ НАСТРОЕК..."
echo "=================================================="

# 1. Применяем настройки сети
echo "Настраиваю IP: $IP_CIDR на $IFACE..."
ip addr flush dev $IFACE
ip addr add $IP_CIDR dev $IFACE
ip link set $IFACE up

echo "Настраиваю шлюз: $GATEWAY..."
ip route replace default via $GATEWAY

echo "Настраиваю DNS: $DNS_SERVER..."
echo "nameserver $DNS_SERVER" > /etc/resolv.conf

# Проверка доступа в интернет (чтобы dig работал)
echo "Проверяю связь с внешним миром (ping 8.8.8.8)..."
if ping -c 2 -W 2 8.8.8.8 > /dev/null; then
    echo "Интернет доступен. Отлично!"
else
    echo "ВНИМАНИЕ: Интернет (ping 8.8.8.8) недоступен. Блокировка по доменам может не сработать, но правила применятся."
fi

# 2. Настраиваем NAT (Masquerade)
echo "Включаю NAT и пересылку пакетов..."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
iptables -A FORWARD -i $IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -o $IFACE -j ACCEPT

# 3. Меняем пароль root
echo "Устанавливаю пароль root..."
echo "root:$ROOT_PASS" | chpasswd

# 4. Создаем пользователей
echo "Создаю учетные записи..."
for user_entry in "${USERS[@]}"; do
    u_name=$(echo "$user_entry" | cut -d: -f1)
    u_pass=$(echo "$user_entry" | cut -d: -f2)
    
    if id "$u_name" &>/dev/null; then
        echo " - Пользователь $u_name уже существует. Пароль обновлен."
        echo "$u_name:$u_pass" | chpasswd
    else
        echo " - Создан пользователь $u_name."
        useradd -m -s /bin/bash "$u_name"
        echo "$u_name:$u_pass" | chpasswd
    fi
done

# 5. Настраиваем Firewall (Блокировка)
echo "Настраиваю блокировку сайтов..."
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Разрешаем DNS (чтобы резолвить адреса)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

if [ ${#BLOCKED_SITES[@]} -gt 0 ]; then
    for site in "${BLOCKED_SITES[@]}"; do
        echo " -> Обрабатываю блокировку: $site"
        # Получаем IP сайта
        # Используем nslookup или dig. dig точнее, но проверим наличие
        if command -v dig &> /dev/null; then
            IPS=$(dig +short $site | grep -E '^[0-9]')
        elif command -v nslookup &> /dev/null; then
            IPS=$(nslookup $site | grep -A 1 'Name:' | tail -n 1 | awk '{print $2}')
        else
            IPS=""
        fi

        if [ -z "$IPS" ]; then
            echo "    [!] Не удалось определить IP для $site. Возможно, нет интернета."
        else
            for ip in $IPS; do
                echo "    [+] Блокирую IP: $ip"
                iptables -A OUTPUT -d $ip -j REJECT
                iptables -A FORWARD -d $ip -j REJECT
            done
        fi
    done
fi

# Разрешаем весь остальной трафик
iptables -A OUTPUT -j ACCEPT
iptables -A FORWARD -j ACCEPT

# 6. Сохраняем правила
echo "Сохраняю правила iptables..."
iptables-save > /etc/iptables.rules
# Пытаемся сохранить для системы (команда может отличаться в разных версиях Альт, но saving в файл работает везде)
if [ -f /etc/sysconfig/iptables ]; then
    iptables-save > /etc/sysconfig/iptables
fi

echo ""
echo "=================================================="
echo "   НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!"
echo "=================================================="
echo "Интерфейс: $IFACE ($IP_CIDR)"
echo "Шлюз: $GATEWAY"
echo "Пользователи созданы: ${#USERS[@]} шт."
echo "Заблокировано сайтов: ${#BLOCKED_SITES[@]} шт."
echo ""
echo "Проверьте настройки командой: ip a"
