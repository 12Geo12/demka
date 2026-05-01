#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}        Настройка NAT${NC}"
echo -e "${CYAN}========================================${NC}"

# Вопрос об очистке NAT таблицы
echo ""
echo "Очистить существующие правила NAT перед настройкой?"
select CLEAR_NAT in "Да" "Нет"
do
    case $CLEAR_NAT in
        "Да")
            echo -e "${YELLOW}Очистка NAT таблицы...${NC}"
            iptables -t nat -F
            iptables -F FORWARD
            iptables -t mangle -F
            echo -e "${GREEN}NAT таблица и FORWARD цепочка очищены.${NC}"
            break
            ;;
        "Нет")
            echo -e "${GREEN}Сохраняем существующие правила NAT.${NC}"
            break
            ;;
        *)
            echo "Выберите 1 или 2"
            ;;
    esac
done

echo ""
echo -e "${CYAN}===== Выберите WAN интерфейс =====${NC}"

# Получаем список всех интерфейсов кроме loopback
all_interfaces=$(ls /sys/class/net | grep -v lo)

echo -e "${WHITE}Доступные интерфейсы:${NC}"
echo ""

idx=1
for iface in $all_interfaces; do
    ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    
    # Цвет статуса
    if [ "$status" = "up" ]; then
        status_out="${GREEN}UP${NC}"
    else
        status_out="${YELLOW}$status${NC}"
    fi
    
    printf "  %2d) %-15s [%s] IP: %s\n" "$idx" "$iface" "$status_out" "$ip"
    idx=$((idx + 1))
done

echo ""
select WAN in $all_interfaces
do
    [ -n "$WAN" ] && break
done

echo -e "${GREEN}WAN интерфейс: $WAN${NC}"

# Автоматически определяем LAN интерфейсы (все кроме WAN и lo)
LAN_INTERFACES=()
for iface in $all_interfaces; do
    if [ "$iface" != "$WAN" ]; then
        LAN_INTERFACES+=("$iface")
    fi
done

# Проверяем, есть ли LAN интерфейсы
if [ ${#LAN_INTERFACES[@]} -eq 0 ]; then
    echo -e "${RED}Ошибка: Не найдено LAN интерфейсов!${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}===== Автоматически определены LAN интерфейсы =====${NC}"
for i in "${!LAN_INTERFACES[@]}"; do
    echo "LAN$((i+1)): ${LAN_INTERFACES[$i]}"
done

echo ""
echo -e "${CYAN}Определение сетей...${NC}"

# Массивы для хранения сетей
declare -a LAN_NETS

for i in "${!LAN_INTERFACES[@]}"; do
    iface="${LAN_INTERFACES[$i]}"
    net=$(ip -o -f inet addr show "$iface" 2>/dev/null | awk '{print $4}')
    
    if [ -z "$net" ]; then
        echo -e "${YELLOW}Предупреждение: Интерфейс $iface не имеет IPv4 адреса, пропускаем...${NC}"
        continue
    fi
    
    LAN_NETS+=("$net")
    echo -e "${GREEN}Сеть $iface: $net${NC}"
done

# Проверяем, есть ли сети для настройки
if [ ${#LAN_NETS[@]} -eq 0 ]; then
    echo -e "${RED}Ошибка: Ни один LAN интерфейс не имеет IPv4 адреса!${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}Включение IP forwarding...${NC}"

SYSCTL_FILE="/etc/sysctl.conf"
if [ -f /etc/net/sysctl.conf ]; then
    SYSCTL_FILE="/etc/net/sysctl.conf"
fi

if ! grep -q "net.ipv4.ip_forward" "$SYSCTL_FILE"; then
    echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
else
    sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
fi

sysctl -p > /dev/null 2>&1
echo -e "${GREEN}IP forwarding включен.${NC}"

echo ""
echo -e "${CYAN}Настройка NAT (MASQUERADE)...${NC}"

# Настройка MASQUERADE для каждой сети
for i in "${!LAN_INTERFACES[@]}"; do
    iface="${LAN_INTERFACES[$i]}"
    net="${LAN_NETS[$i]}"
    
    if [ -n "$net" ]; then
        echo -e "  ${GREEN}NAT для $iface ($net) -> $WAN${NC}"
        iptables -t nat -A POSTROUTING -o "$WAN" -s "$net" -j MASQUERADE
    fi
done

echo ""
echo -e "${CYAN}Настройка FORWARD цепочки...${NC}"

# 1. Разрешаем уже установленные соединения (Важно для обратного трафика!)
echo -e "  ${GREEN}Разрешение ESTABLISHED,RELATED соединений...${NC}"
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 2. Разрешаем forwarding из LAN в WAN
for i in "${!LAN_INTERFACES[@]}"; do
    iface="${LAN_INTERFACES[$i]}"
    net="${LAN_NETS[$i]}"
    
    if [ -n "$net" ]; then
        echo -e "  ${GREEN}FORWARD: $iface -> $WAN${NC}"
        iptables -A FORWARD -i "$iface" -o "$WAN" -s "$net" -j ACCEPT
    fi
done

# 3. Разрешаем forwarding из WAN в LAN (для ответного трафика)
for i in "${!LAN_INTERFACES[@]}"; do
    iface="${LAN_INTERFACES[$i]}"
    
    echo -e "  ${GREEN}FORWARD: $WAN -> $iface (ответный трафик)${NC}"
    iptables -A FORWARD -i "$WAN" -o "$iface" -j ACCEPT
done

# 4. Разрешаем forwarding между LAN интерфейсами (VLAN <-> VLAN)
if [ ${#LAN_INTERFACES[@]} -gt 1 ]; then
    echo ""
    echo -e "${CYAN}Настройка пересылки между LAN интерфейсами...${NC}"
    for i in "${!LAN_INTERFACES[@]}"; do
        for j in "${!LAN_INTERFACES[@]}"; do
            if [ $i -ne $j ]; then
                iface1="${LAN_INTERFACES[$i]}"
                iface2="${LAN_INTERFACES[$j]}"
                echo -e "  ${GREEN}FORWARD: $iface1 <-> $iface2${NC}"
                iptables -A FORWARD -i "$iface1" -o "$iface2" -j ACCEPT
            fi
        done
    done
fi

# 5. Политика по умолчанию (опционально - можно оставить ACCEPT)
# iptables -P FORWARD DROP

echo ""
echo -e "${CYAN}Сохранение правил...${NC}"

# Проверяем наличие директории для сохранения
if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables
    echo -e "${GREEN}Правила сохранены в /etc/sysconfig/iptables${NC}"
elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
    echo -e "${GREEN}Правила сохранены в /etc/iptables/rules.v4${NC}"
else
    # Создаём директорию если нет
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    echo -e "${GREEN}Правила сохранены в /etc/sysconfig/iptables${NC}"
fi

# Перезапуск сервиса iptables если доступен
if systemctl list-unit-files 2>/dev/null | grep -q "^iptables.service"; then
    systemctl enable iptables --now 2>/dev/null
    systemctl restart iptables 2>/dev/null
    echo -e "${GREEN}Сервис iptables перезапущен${NC}"
fi

echo ""
echo -e "${CYAN}===== NAT таблица =====${NC}"
iptables -t nat -L -n -v --line-numbers

echo ""
echo -e "${CYAN}===== FORWARD цепочка =====${NC}"
iptables -L FORWARD -n -v --line-numbers

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}        ИТОГОВАЯ КОНФИГУРАЦИЯ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${WHITE}WAN интерфейс:${NC} $WAN"
echo -e "${WHITE}LAN интерфейсы:${NC} ${LAN_INTERFACES[*]}"
echo -e "${WHITE}Количество LAN сетей:${NC} ${#LAN_NETS[@]}"
echo ""
echo -e "${CYAN}Проверка интернета:${NC}"
echo "  ping 8.8.8.8  - проверить связь"
echo "  ping google.com - проверить DNS"
echo ""
echo -e "${GREEN}Готово!${NC}"
