#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт через sudo!${NC}"
  exit 1
fi

# Проверка необходимых утилит
for cmd in ip ping iptables dig nslookup; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}Предупреждение: Утилита $cmd не найдена. Некоторые функции могут не работать.${NC}"
    fi
done

clear
echo "========================================"
echo "    ИСПРАВЛЕННЫЙ СКРИПТ НАСТРОЙКИ Linux"
echo "========================================"

# --- ШАГ 1: Выбор интерфейса ---
echo ""
echo -e "${GREEN}[1] Выбор сетевого интерфейса для ИНТЕРНЕТА${NC}"
echo "Доступные интерфейсы:"
ip -o link show | awk '{print $2}' | tr -d ':' | grep -v lo

echo ""
echo "Подсказка: В VMware NAT обычно использует eth0 или ens33."
read -p "Введите имя интерфейса (например, ens33): " WAN_IF

# Проверка существования интерфейса
if ! ip link show "$WAN_IF" &> /dev/null; then
    echo -e "${RED}ОШИБКА: Интерфейс '$WAN_IF' не найден в системе.${NC}"
    exit 1
fi

# --- ШАГ 2: Настройка IP и Шлюза ---
echo ""
echo -e "${GREEN}[2] Настройка статического IP и Шлюза${NC}"
echo "Пример IP: 192.168.1.10/24"
echo "Пример Шлюза: 192.168.1.1"

read -p "Введите IP-адрес с маской (CIDR): " IP_CIDR
read -p "Введите IP Шлюза (Gateway): " GATEWAY

# Простая валидация (проверка на наличие символа / для CIDR)
if [[ ! "$IP_CIDR" =~ / ]]; then
    echo -e "${RED}Ошибка: IP адрес должен быть указан с маской (например, 192.168.1.10/24).${NC}"
    exit 1
fi

echo "Применяю настройки сети..."
# Очищаем старые адреса
ip addr flush dev "$WAN_IF"
# Добавляем новый адрес
ip addr add "$IP_CIDR" dev "$WAN_IF"
# Поднимаем интерфейс
ip link set "$WAN_IF" up
# Добавляем маршрут по умолчанию
ip route replace default via "$GATEWAY" dev "$WAN_IF"

echo -e "${GREEN}Сетевые настройки применены.${NC}"

# --- ШАГ 3: ПРОВЕРКА СВЯЗИ ---
echo ""
echo -e "${GREEN}[3] Проверка связи со шлюзом ($GATEWAY)...${NC}"
if ping -c 2 -W 2 "$GATEWAY" > /dev/null 2>&1; then
    echo -e "${GREEN}УСПЕХ: Шлюз пингуется.${NC}"
else
    echo -e "${RED}!!! ВНИМАНИЕ: Шлюз ($GATEWAY) НЕ ОТВЕЧАЕТ !!!${NC}"
    echo "Возможные причины:"
    echo "1. Неверный IP шлюза."
    echo "2. VMWare Network Adapter выключен или не в режиме NAT/Bridge."
    echo "3. Ваш IP адрес не из той же подсети, что и шлюз."
    read -p "Нажмите Enter, чтобы продолжить (интернет может не работать)..."
fi

# --- ШАГ 4: Настройка DNS ---
echo ""
echo -e "${GREEN}[4] Настройка DNS (Google Public DNS)${NC}"
# Сохраняем старый resolv.conf на всякий случай
cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Защита от перезаписи DHCP-клиентом (опционально, требует прав root)
chattr +i /etc/resolv.conf 2>/dev/null
echo "DNS настроены. Файл защищен от изменения атрибутами."

# --- ШАГ 5: Пользователи ---
echo ""
echo -e "${GREEN}[5] Управление пользователями${NC}"
read -sp "Введите новый пароль для root: " ROOT_PASS
echo ""
echo "$ROOT_PASS" | passwd --stdin root &> /dev/null || echo "$ROOT_PASS" | chpasswd <<< "root:$ROOT_PASS"
echo -e "${GREEN}Пароль root обновлен.${NC}"

echo "Создание новых пользователей (оставьте поле логина пустым для завершения):"
while true; do
    read -p "Логин нового пользователя: " U_NAME
    [ -z "$U_NAME" ] && break
    
    if id "$U_NAME" &>/dev/null; then
        echo -e "${YELLOW}Пользователь $U_NAME уже существует. Пропуск.${NC}"
        continue
    fi

    read -sp "Пароль для $U_NAME: " U_PASS
    echo ""
    
    useradd -m -s /bin/bash "$U_NAME"
    echo "$U_NAME:$U_PASS" | chpasswd
    echo -e "${GREEN}Пользователь $U_NAME создан.${NC}"
done

# --- ШАГ 6: Блокировка сайтов ---
echo ""
echo -e "${GREEN}[6] Блокировка сайтов${NC}"
echo "Введите домены через пробел (например: vk.com ok.ru)"
read -p "Сайты для блокировки: " SITES_INPUT

BLOCKED_SITES=($SITES_INPUT)
BLOCKED_IPS=()

if [ ${#BLOCKED_SITES[@]} -gt 0 ]; then
    echo "Резолвим домены в IP..."
    for site in "${BLOCKED_SITES[@]}"; do
        # Получаем все IPv4 адреса для домена
        IPS=$(dig +short A "$site" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        
        if [ -z "$IPS" ]; then
            # Пробуем nslookup если dig не сработал
            IPS=$(nslookup "$site" 2>/dev/null | grep -A 1 "Name:" | tail -n 1 | awk '{print $2}')
        fi

        if [ -n "$IPS" ]; then
            for ip in $IPS; do
                BLOCKED_IPS+=("$ip")
                echo "  -> $site разрешен в $ip"
            done
        else
            echo -e "${YELLOW}  Не удалось получить IP для $site${NC}"
        fi
    done
fi

# --- ШАГ 7: IPTABLES (FIREWALL & NAT) ---
echo ""
echo "========================================"
echo "    ПРИМЕНЕНИЕ ПРАВИЛ FIREWALL          "
echo "========================================"

# 1. Включаем форвардинг пакетов
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 &>/dev/null

# 2. Очищаем старые правила
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# 3. Политики по умолчанию (DROP для входящих и форварда, ACCEPT для исходящих)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# 4. Разрешаем локальный трафик и установленные соединения
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 5. Разрешаем SSH (порт 22), ICMP (ping)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT

# 6. НАСТРОЙКА NAT (MASQUERADE)
# Позволяет машинам за этим сервером выходить в интернет
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# 7. Правила FORWARD (для работы шлюза)
# Разрешаем проход трафика из внутренней сети в интернет и обратно
iptables -A FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -o "$WAN_IF" -j ACCEPT

# 8. БЛОКИРОВКА САЙТОВ
if [ ${#BLOCKED_IPS[@]} -gt 0 ]; then
    echo "Применяю блокировку IP..."
    # Удаляем дубликаты IP
    UNIQUE_IPS=($(echo "${BLOCKED_IPS[@]}" | tr ' ' '\n' | sort -u))
    
    for ip in "${UNIQUE_IPS[@]}"; do
        iptables -A OUTPUT -d "$ip" -j REJECT --reject-with icmp-net-unreachable
        iptables -A FORWARD -d "$ip" -j REJECT --reject-with icmp-net-unreachable
    done
    echo -e "${GREEN}Блокировка применена.${NC}"
fi

# 9. Сохранение правил
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables.rules
    echo "Правила сохранены в /etc/iptables.rules"
    
    # Для Debian/Ubuntu можно активировать автозагрузку правил (требует пакета iptables-persistent)
    # Для CentOS/RHEL нужно включить службу iptables
    echo "Чтобы правила сохранялись после перезагрузки, установите iptables-persistent (Debian) или сохраните сервис (CentOS)."
fi

echo ""
echo "========================================"
echo -e "${GREEN}НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo "========================================"
echo "Проверьте интернет: ping 8.8.8.8"
echo "Проверьте DNS: ping google.com"
