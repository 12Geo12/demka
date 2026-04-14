#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт через sudo!${NC}"
  exit 1
fi

clear
echo "========================================"
echo "  НАСТРОЙКА С БЛОКИРОВКОЙ ПО ДОМЕНАМ   "
echo "========================================"

# --- ШАГ 1: Выбор интерфейса ---
echo ""
echo -e "${GREEN}[1] Выбор сетевого интерфейса${NC}"
echo "Доступные интерфейсы:"
ip -o link show | awk '{print $2}' | tr -d ':' | grep -v lo

read -p "Введите имя интерфейса (например, ens33): " WAN_IF

if ! ip link show "$WAN_IF" &> /dev/null; then
    echo -e "${RED}ОШИБКА: Интерфейс '$WAN_IF' не найден.${NC}"
    exit 1
fi

# --- ШАГ 2: Настройка сети ---
echo ""
echo -e "${GREEN}[2] Настройка IP и шлюза${NC}"
read -p "IP-адрес с маской (192.168.1.10/24): " IP_CIDR
read -p "Шлюз (192.168.1.1): " GATEWAY

if [[ ! "$IP_CIDR" =~ / ]]; then
    echo -e "${RED}Ошибка: Укажите маску в формате CIDR (например, /24)${NC}"
    exit 1
fi

ip addr flush dev "$WAN_IF"
ip addr add "$IP_CIDR" dev "$WAN_IF"
ip link set "$WAN_IF" up
ip route replace default via "$GATEWAY" dev "$WAN_IF"

# Проверка шлюза
echo -e "\n[3] Проверка шлюза..."
if ping -c 2 -W 2 "$GATEWAY" &> /dev/null; then
    echo -e "${GREEN}✓ Шлюз доступен${NC}"
else
    echo -e "${RED}✗ Шлюз не отвечает!${NC}"
    read -p "Продолжить? (Enter)"
fi

# --- ШАГ 4: Настройка DNS ---
echo ""
echo -e "${GREEN}[4] Настройка системного DNS${NC}"
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
# Снимаем защиту если была, и ставим новую
chattr -i /etc/resolv.conf 2>/dev/null
chattr +i /etc/resolv.conf 2>/dev/null

# --- ШАГ 5: Пользователи ---
echo ""
echo -e "${GREEN}[5] Пользователи${NC}"
read -sp "Новый пароль для root: " ROOT_PASS
echo ""
echo "$ROOT_PASS" | chpasswd <<< "root:$ROOT_PASS" 2>/dev/null || echo "$ROOT_PASS" | passwd --stdin root &>/dev/null

echo "Создание пользователей (пустой логин = завершить):"
while true; do
    read -p "Логин: " U_NAME
    [ -z "$U_NAME" ] && break
    read -sp "Пароль: " U_PASS
    echo ""
    useradd -m -s /bin/bash "$U_NAME" 2>/dev/null
    echo "$U_NAME:$U_PASS" | chpasswd
    echo -e "${GREEN}✓ $U_NAME создан${NC}"
done

# --- ШАГ 6: БЛОКИРОВКА ПО ДОМЕНАМ ---
echo ""
echo "========================================"
echo -e "${BLUE}[6] БЛОКИРОВКА САЙТОВ ПО ДОМЕНАМ${NC}"
echo "========================================"
echo "Выберите метод блокировки:"
echo "1) /etc/hosts — просто, только для этой машины"
echo "2) dnsmasq — надёжно, работает для всей сети (рекомендуется)"
echo "3) iptables string — только HTTP, не рекомендуется"
echo ""
read -p "Выберите метод (1/2/3) или нажмите Enter для пропуска: " BLOCK_METHOD

BLOCKED_DOMAINS=()

if [[ "$BLOCK_METHOD" =~ ^[123]$ ]]; then
    echo "Введите домены через пробел (пример: vk.com ok.ru twitter.com)"
    read -p "Домены для блокировки: " DOMAINS_INPUT
    BLOCKED_DOMAINS=($DOMAINS_INPUT)
fi

# === МЕТОД 1: /etc/hosts ===
if [[ "$BLOCK_METHOD" == "1" && ${#BLOCKED_DOMAINS[@]} -gt 0 ]]; then
    echo -e "\n${GREEN}Применяю блокировку через /etc/hosts...${NC}"
    
    # Бэкап
    cp /etc/hosts /etc/hosts.bak 2>/dev/null
    
    # Добавляем домены в конец файла
    for domain in "${BLOCKED_DOMAINS[@]}"; do
        # Проверяем, нет ли уже такой записи
        if ! grep -q "127.0.0.1[[:space:]]*$domain" /etc/hosts; then
            echo "127.0.0.1 $domain" >> /etc/hosts
            echo "127.0.0.1 www.$domain" >> /etc/hosts  # Блокируем и www-версию
            echo -e "  ${GREEN}✓ Заблокирован: $domain${NC}"
        else
            echo -e "${YELLOW}  ! $domain уже в блоке${NC}"
        fi
    done
    echo -e "${GREEN}Готово! Домены перенаправлены на 127.0.0.1${NC}"
fi

# === МЕТОД 2: dnsmasq (DNS sinkhole) ===
if [[ "$BLOCK_METHOD" == "2" ]]; then
    echo -e "\n${GREEN}Настройка dnsmasq для блокировки доменов...${NC}"
    
    # Установка dnsmasq если нет
    if ! command -v dnsmasq &> /dev/null; then
        echo "Установка dnsmasq..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y dnsmasq
        elif command -v yum &> /dev/null; then
            yum install -y dnsmasq
        elif command -v dnf &> /dev/null; then
            dnf install -y dnsmasq
        else
            echo -e "${RED}Не удалось установить dnsmasq автоматически.${NC}"
            echo "Установите его вручную: apt install dnsmasq (Debian) или yum install dnsmasq (CentOS)"
        fi
    fi
    
    # Создаём конфигурационный файл для блокировок
    BLOCK_CONF="/etc/dnsmasq.d/01-blocklist.conf"
    echo "" > "$BLOCK_CONF"  # Очищаем или создаём
    
    for domain in "${BLOCKED_DOMAINS[@]}"; do
        echo "address=/$domain/127.0.0.1" >> "$BLOCK_CONF"
        echo "address=/www.$domain/127.0.0.1" >> "$BLOCK_CONF"
        echo -e "  ${GREEN}✓ Добавлен в блок: $domain${NC}"
    done
    
    # Настраиваем dnsmasq как основной DNS
    if [ -f /etc/dnsmasq.conf ]; then
        # Резервная копия
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null
        # Добавляем базовые настройки если их нет
        grep -q "^port=53" /etc/dnsmasq.conf || echo "port=53" >> /etc/dnsmasq.conf
        grep -q "^bind-interfaces" /etc/dnsmasq.conf || echo "bind-interfaces" >> /etc/dnsmasq.conf
        grep -q "^listen-address=127.0.0.1" /etc/dnsmasq.conf || echo "listen-address=127.0.0.1" >> /etc/dnsmasq.conf
        # Если машина — шлюз для других, слушаем и на внешнем интерфейсе
        grep -q "^listen-address=$GATEWAY" /etc/dnsmasq.conf || echo "listen-address=$GATEWAY" >> /etc/dnsmasq.conf 2>/dev/null
    fi
    
    # Перезапускаем dnsmasq
    systemctl enable dnsmasq --now 2>/dev/null || service dnsmasq restart 2>/dev/null
    
    # Меняем системный DNS на локальный
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF
    chattr +i /etc/resolv.conf 2>/dev/null
    
    echo -e "${GREEN}✓ dnsmasq настроен. Запросы к заблокированным доменам будут возвращать 127.0.0.1${NC}"
    echo -e "${YELLOW}Подсказка: Чтобы другие устройства использовали эту блокировку, укажите им IP этой машины как DNS-сервер.${NC}"
fi

# === МЕТОД 3: iptables string (только HTTP, для справки) ===
if [[ "$BLOCK_METHOD" == "3" && ${#BLOCKED_DOMAINS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}ВНИМАНИЕ: Этот метод работает ТОЛЬКО для незашифрованного HTTP!${NC}"
    echo "Для HTTPS (95% сайтов) он бесполезен."
    read -p "Продолжить всё равно? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        # Проверяем поддержку модуля string
        if ! iptables -m string --help &> /dev/null; then
            echo -e "${RED}Модуль 'string' не поддерживается вашим ядром/iptables.${NC}"
        else
            for domain in "${BLOCKED_DOMAINS[@]}"; do
                # Блокируем по строке "Host: domain" в HTTP-заголовках
                iptables -A OUTPUT -p tcp --dport 80 -m string --string "Host: $domain" --algo bm -j REJECT
                iptables -A FORWARD -p tcp --dport 80 -m string --string "Host: $domain" --algo bm -j REJECT
                echo -e "  ${YELLOW}✓ Добавлено правило для $domain (только HTTP)${NC}"
            done
        fi
    fi
fi

# --- ШАГ 7: IPTABLES (NAT + базовый фаервол) ---
echo ""
echo "========================================"
echo "    НАСТРОЙКА IPTABLES (NAT + Firewall)"
echo "========================================"

echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 &>/dev/null

# Очистка
iptables -F
iptables -X
iptables -t nat -F

# Политики
iptables -P INPUT DROP
iptables -P FORWARD DROP  
iptables -P OUTPUT ACCEPT

# Разрешения
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT

# Если используется dnsmasq — разрешаем DNS
if [[ "$BLOCK_METHOD" == "2" ]]; then
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT
fi

# NAT
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# FORWARD правила
iptables -A FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -o "$WAN_IF" -j ACCEPT

# Сохранение
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables.rules
    echo -e "${GREEN}✓ Правила iptables сохранены в /etc/iptables.rules${NC}"
fi

# --- ФИНАЛ ---
echo ""
echo "========================================"
echo -e "${GREEN}✅ НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
echo "========================================"
echo "Проверки:"
echo "  • ping 8.8.8.8          # проверка интернета"
echo "  • ping google.com       # проверка DNS"
if [[ "$BLOCK_METHOD" == "1" ]]; then
    echo "  • curl http://vk.com      # должен не грузиться (блокировка /etc/hosts)"
elif [[ "$BLOCK_METHOD" == "2" ]]; then
    echo "  • nslookup vk.com         # должен вернуть 127.0.0.1"
fi
echo ""
echo -e "${YELLOW}Важно: После перезагрузки правила iptables нужно загрузить вручную:"
echo "  iptables-restore < /etc/iptables.rules${NC}"
