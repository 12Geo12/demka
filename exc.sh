#!/bin/bash

# ==========================================
# НАСТРОЙКИ (МЕНЯЙТЕ ЗДЕСЬ)
# ==========================================

# 1. Сетевые интерфейсы
# WAN_IF - это интерфейс, через который идет интернет (смотрит в мир/роутер)
# В VMware это обычно eth0 или ens33, если NAT настроен на самой машине.
# Если машина стоит за роутером, выберите интерфейс с шлюзом.
WAN_IF="eth0" 

# LAN_IF - это интерфейс, если нужно раздавать интернет внутрь (для простоты оставьте как WAN_IF)
LAN_IF="eth0"

# 2. IP, Маска и Шлюз (Из вашего задания "как на рабочей станции")
# ВНИМАНИЕ: Скрипт задает статический IP. Если у вас DHCP, закомментируйте блок настройки IP ниже.
IP_ADDR="192.168.1.100"
NETMASK="255.255.255.0"
GATEWAY="192.168.1.1"

# 3. Пользователи и пароли (Из вашего задания)
USERS=(
    "alt1:Pass1"
    "alt2:Pass2"
)
ROOT_PASS="Root123"

# 4. Список запрещенных сайтов (DNS имена)
BLOCKED_SITES=(
    "twitter.com"
    "tiktok.com"
)

# ==========================================
# ВЫПОЛНЕНИЕ СКРИПТА
# ==========================================

echo "--- Начало настройки экзаменационного задания ---"

# 1. Настройка сетевого интерфейса
echo "[1] Настройка IP-адреса ($IP_ADDR) и шлюза ($GATEWAY)..."
# Команда ifconfig может требовать установки net-tools, используем ip (базовый инструмент)
ip addr flush dev $WAN_IF
ip addr add $IP_ADDR/$NETMASK dev $WAN_IF
ip link set $WAN_IF up

# Настройка шлюза по умолчанию
ip route replace default via $GATEWAY

# Настройка DNS (чтобы resolving работал до блокировки)
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

echo "Сеть настроена. Проверьте ping 8.8.8.8."

# 2. Настройка NAT (Masquerading)
echo "[2] Включение NAT (MASQUERADE) для выхода в интернет..."
# Включаем пересылку пакетов
echo 1 > /proc/sys/net/ipv4/ip_forward

# Очистка старых правил NAT
iptables -t nat -F POSTROUTING

# Правило: Все, что уходит через WAN_IF, маскируется под его IP
iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE

# Разрешаем форвардинг установленных соединений
iptables -A FORWARD -i $WAN_IF -o $WAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $WAN_IF -o $WAN_IF -j ACCEPT

echo "NAT настроен."

# 3. Создание пользователей
echo "[3] Создание пользователей и смена пароля root..."

# Смена пароля root
echo "root:$ROOT_PASS" | chpasswd

# Создание обычных пользователей
for user_entry in "${USERS[@]}"; do
    username=$(echo "$user_entry" | cut -d: -f1)
    password=$(echo "$user_entry" | cut -d: -f2)
    
    if id "$username" &>/dev/null; then
        echo "Пользователь $username уже существует. Обновляем пароль..."
        echo "$username:$password" | chpasswd
    else
        echo "Создаем пользователя $username..."
        useradd -m -s /bin/bash "$username"
        echo "$username:$password" | chpasswd
    fi
done

echo "Пользователи созданы."

# 4. Настройка Firewall (Блокировка сайтов)
echo "[4] Настройка iptables для блокировки DNS-имен..."

# Очистка цепочки OUTPUT (для исходящих)
iptables -F OUTPUT

# Разрешаем локальный трафик и Established
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Разрешаем DNS запросы сами по себе (иначе мы не узнаем IP сайта для блокировки)
# Но в задании часто требуют запретить доступ САМИМ сайтам. 
# Логика: Разрешаем DNS запросы, но блокируем соединение к IP этих сайтов.

# Логика блокировки сайтов:
# Чтобы заблокировать сайт по имени, нам нужно его IP. 
# Но iptables не работает с доменами динамически в момент запроса легко без доп. софта.
# Стандартный способ для экзамена: Резолвим IP сейчас и блокируем их.

for site in "${BLOCKED_SITES[@]}"; do
    echo "Обработка сайта: $site"
    # Получаем IP адреса сайта
    IPS=$(dig +short $site | grep -E '^[0-9]')
    
    if [ -z "$IPS" ]; then
        echo "  Не удалось получить IP для $site. Проверьте интернет."
    else
        for ip in $IPS; do
            echo "  Блокируем IP $ip (сайт $site)"
            iptables -A OUTPUT -d $ip -j REJECT
            # Также блокируем доступ через NAT, если кто-то идет через эту машину как шлюз
            iptables -A FORWARD -d $ip -j REJECT 
        done
    fi
done

# Разрешаем всё остальное (интернет должен работать)
iptables -A OUTPUT -j ACCEPT
iptables -A FORWARD -j ACCEPT

echo "Брандмауэр настроен."

# 5. Сохранение правил
echo "[5] Сохранение правил iptables..."
# В Альт Сервер (как и в CentOS/RedHat) используется service iptables save
if command -v service &> /dev/null; then
    service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
fi
# Для устойчивости сохраняем и так
iptables-save > /etc/iptables.rules

echo "--- Скрипт завершен ---"
echo "Пользователи: alt1, alt2, root"
echo "Пароли проверьте по заданию."
echo "Заблокированные сайты: ${BLOCKED_SITES[*]}"
