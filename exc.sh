#!/bin/bash

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт через sudo!"
  exit
fi

clear
echo "========================================"
echo "    ИСПРАВЛЕННЫЙ СКРИПТ НАСТРОЙКИ"
echo "========================================"

# --- ШАГ 1: Выбор интерфейса ---
echo ""
echo "[1] ВАЖНО: Выберите интерфейс для ИНТЕРНЕТА"
echo "Список активных интерфейсов:"
ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'

echo ""
echo "Если вы в VMware и интернет работает через NAT,"
echo "обычно это интерфейс с самым низким номером (eth0 или ens33)."
read -p "Введите имя интерфейса (например, ens33): " WAN_IF

# Проверка, что интерфейс существует
if ! ip link show "$WAN_IF" &> /dev/null; then
    echo "ОШИБКА: Интерфейс $WAN_IF не найден. Перезапустите скрипт и введите верное имя."
    exit 1
fi

# --- ШАГ 2: Настройка IP и Шлюза ---
echo ""
echo "[2] Настройка IP-адреса и Шлюза"
echo "Внимание: Шлюз должен быть доступен, иначе интернета не будет!"
read -p "Введите IP-адрес с маской (пример: 192.168.1.100/24): " IP_CIDR
read -p "Введите Шлюз/Gateway (пример: 192.168.1.1): " GATEWAY

# Настраиваем IP
ip addr flush dev $WAN_IF
ip addr add $IP_CIDR dev $WAN_IF
ip link set $WAN_IF up

# Настраиваем маршрут
echo "Пробую добавить маршрут по умолчанию..."
ip route replace default via $GATEWAY dev $WAN_IF

# --- ШАГ 3: ПРОВЕРКА ШЛЮЗА ---
echo ""
echo "[3] Проверка связи с шлюзом ($GATEWAY)..."
if ping -c 2 -W 2 $GATEWAY > /dev/null; then
    echo "УСПЕХ: Шлюз доступен. Интернет должен работать."
else
    echo ""
    echo "!!! ВНИМАНИЕ: Шлюз ($GATEWAY) НЕ ДОСТУПЕН !!!"
    echo "На скриншоте была именно эта ошибка."
    echo "Возможные причины:"
    echo "1. Вы ввели неверный IP шлюза."
    echo "2. В VMware сетевой адаптер не в режиме NAT."
    echo "3. IP адрес машины находится в другой подсети, чем шлюз."
    echo ""
    read -p "Нажмите Enter, чтобы продолжить всё равно (интернет может не работать)... "
fi

# --- ШАГ 4: Настройка DNS ---
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# --- ШАГ 5: Пользователи и Пароли ---
echo ""
echo "[4] Настройка пользователей"
read -sp "Новый пароль для root: " ROOT_PASS
echo
echo "Создание пользователей (Enter - завершить):"
USERS=()
while true; do
    read -p "Логин: " U_NAME
    [ -z "$U_NAME" ] && break
    read -sp "Пароль для $U_NAME: " U_PASS
    echo
    USERS+=("$U_NAME:$U_PASS")
done

# --- ШАГ 6: Блокировка сайтов ---
echo ""
echo "[5] Блокировка сайтов (через пробел)"
read -p "Сайты (напр. twitter.com tiktok.com): " SITES_INPUT
BLOCKED_SITES=($SITES_INPUT)

# --- ШАГ 7: ПРИМЕНЕНИЕ НАСТРОЕК (NAT + FIREWALL) ---
echo ""
echo "========================================"
echo "ПРИМЕНЕНИЕ ПРАВИЛ IPTABLES И NAT..."
echo "========================================"

# 1. Включаем Forwarding (для NAT)
echo 1 > /proc/sys/net/ipv4/ip_forward

# 2. Полная очистка правил
iptables -F
iptables -X
iptables -t nat -F

# 3. НАСТРОЙКА NAT (САМОЕ ГЛАВНОЕ)
# Разрешаем трафик на самой машине
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
# Разрешаем SSH (если нужно, иначе можете закрыть)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Разрешаем исходящий трафик (OUTPUT) по умолчанию
iptables -P OUTPUT ACCEPT

# НАСТРОЙКА МАСКАРАДИНГА (NAT)
# Это правило позволяет пакетам уходить в интернет, заменяя их IP на IP интерфейса
iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE

# Разрешаем пересылку (FORWARD) пакетов
iptables -A FORWARD -i $WAN_IF -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -o $WAN_IF -j ACCEPT

# 4. БЛОКИРОВКА САЙТОВ
# Мы блокируем ДОСТУП к IP этих сайтов в цепочке OUTPUT
if [ ${#BLOCKED_SITES[@]} -gt 0 ]; then
    echo "Блокируем сайты..."
    for site in "${BLOCKED_SITES[@]}"; do
        # Получаем IP
        # dig есть не везде, используем getent, если есть, иначе nslookup
        if command -v dig &> /dev/null; then
            SITE_IP=$(dig +short $site | grep -E '^[0-9]' | head -n 1)
        else
            SITE_IP=$(nslookup $site 2>/dev/null | grep -A 1 'Name:' | tail -n 1 | awk '{print $2}')
        fi

        if [ -n "$SITE_IP" ]; then
            echo "  Блокирую $site -> IP $SITE_IP"
            iptables -A OUTPUT -d $SITE_IP -j REJECT
            # Блокируем и FORWARD, если машина используется как шлюз для других
            iptables -A FORWARD -d $SITE_IP -j REJECT
        else
            echo "  Не могу найти IP для $site (проверьте интернет)"
        fi
    done
fi

# Сохранение
iptables-save > /etc/iptables.rules

echo ""
echo "========================================"
echo "ГОТОВО."
echo "========================================"
echo "Проверьте интернет: ping 8.8.8.8"
echo "Проверьте шлюз: ping $GATEWAY"
