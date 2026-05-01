#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}         ${WHITE}Настройка DHCP сервера для VLAN${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

echo -e "${CYAN}Установка пакетов...${NC}"
apt-get update -y > /dev/null 2>&1
apt-get install -y dhcp-server ipcalc > /dev/null 2>&1

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}  Выбор VLAN интерфейса для DHCP${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Массивы для интерфейсов
INTERFACES=()
IPS=()
VLAN_IDS=()

# Получение интерфейсов (включая VLAN)
get_interfaces() {
    echo -e "${WHITE}Доступные сетевые интерфейсы:${NC}"
    echo "------------------------------------------------------------"
    printf "%-4s %-18s %-10s %-18s %-10s\n" "№" "Интерфейс" "VLAN ID" "IP адрес" "Статус"
    echo "------------------------------------------------------------"
    
    local INDEX=1
    local TMPFILE=$(mktemp)
    
    ip -4 -o addr show 2>/dev/null > "$TMPFILE"
    
    while IFS= read -r line; do
        local iface=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
        local ip_cidr=$(echo "$line" | awk '{print $4}')
        local ip=$(echo "$ip_cidr" | cut -d/ -f1)
        
        # Пропускаем lo
        [ "$iface" = "lo" ] && continue
        
        # Определяем VLAN ID
        local vlan_id="-"
        if [[ "$iface" =~ \.([0-9]+)$ ]]; then
            vlan_id="${BASH_REMATCH[1]}"
        fi
        
        # Получаем статус
        local status
        if [ -f "/sys/class/net/${iface}/operstate" ]; then
            status=$(cat "/sys/class/net/${iface}/operstate")
        else
            status="unknown"
        fi
        status=$(echo "$status" | tr '[:lower:]' '[:upper:]')
        
        if [ -n "$ip" ]; then
            INTERFACES+=("$iface")
            IPS+=("$ip")
            VLAN_IDS+=("$vlan_id")
            
            # Цвет статуса
            local status_out
            if [ "$status" = "UP" ]; then
                status_out="${GREEN}UP${NC}"
            else
                status_out="${YELLOW}$status${NC}"
            fi
            
            # Выделяем VLAN интерфейсы
            if [ "$vlan_id" != "-" ]; then
                printf "${MAGENTA}%2d)${NC} %-18s ${CYAN}%-10s${NC} %-18s %b\n" "$INDEX" "$iface" "VLAN $vlan_id" "$ip" "$status_out"
            else
                printf "%2d) %-18s %-10s %-18s %b\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status_out"
            fi
            INDEX=$((INDEX + 1))
        fi
    done < "$TMPFILE"
    
    rm -f "$TMPFILE"
    echo ""
}

# Выбор интерфейса
select_interface() {
    local prompt="$1"
    local selected_index

    while true; do
        read -p "$prompt" selection

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [ "$selection" -ge 1 ] && [ "$selection" -le ${#INTERFACES[@]} ]; then
                selected_index=$((selection - 1))
                SELECTED_IFACE="${INTERFACES[$selected_index]}"
                SELECTED_IP="${IPS[$selected_index]}"
                SELECTED_VLAN="${VLAN_IDS[$selected_index]}"
                echo -e "${GREEN}Выбран: $SELECTED_IFACE ($SELECTED_IP)${NC}"
                if [ "$SELECTED_VLAN" != "-" ]; then
                    echo -e "${CYAN}Это VLAN $SELECTED_VLAN интерфейс${NC}"
                fi
                echo ""
                return 0
            else
                echo -e "${RED}Ошибка: введите число от 1 до ${#INTERFACES[@]}${NC}"
            fi
        else
            echo -e "${RED}Ошибка: неверный ввод${NC}"
        fi
    done
}

# Получение параметров сети
get_network_info() {
    local iface=$1

    local CIDR=$(ip -4 -o addr show "$iface" | awk '{print $4}')
    local IP=$(echo "$CIDR" | cut -d/ -f1)

    # Используем ipcalc для получения параметров сети
    local NETWORK=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Network:" | awk '{print $2}' | cut -d/ -f1)
    local NETMASK=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Netmask:" | awk '{print $2}')
    local BROADCAST=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Broadcast:" | awk '{print $2}')

    # Диапазон DHCP (оставляем место для шлюза и других устройств)
    local START=$(echo "$NETWORK" | awk -F. '{print $1"."$2"."$3"."$4+10}')
    local END=$(echo "$BROADCAST" | awk -F. '{print $1"."$2"."$3"."$4-5}')

    echo "$NETWORK $NETMASK $BROADCAST $START $END $IP"
}

# --- Запуск ---
get_interfaces

if [ ${#INTERFACES[@]} -lt 1 ]; then
    echo -e "${RED}Ошибка: нет интерфейсов с IP адресом${NC}"
    exit 1
fi

# Спрашиваем количество интерфейсов
echo -e "${WHITE}Сколько VLAN (интерфейсов) настроить для DHCP?${NC}"
read -p "Введите число [1]: " IFACE_COUNT
IFACE_COUNT=${IFACE_COUNT:-1}

# Проверка
if ! [[ "$IFACE_COUNT" =~ ^[0-9]+$ ]] || [ "$IFACE_COUNT" -lt 1 ]; then
    echo -e "${RED}Ошибка: некорректное число${NC}"
    exit 1
fi

if [ "$IFACE_COUNT" -gt ${#INTERFACES[@]} ]; then
    echo -e "${RED}Ошибка: нельзя выбрать больше интерфейсов (${#INTERFACES[@]})${NC}"
    exit 1
fi

# Массив для выбранных интерфейсов
SELECTED_IFACES=()
SELECTED_IPS=()
SELECTED_VLANS=()

# Выбор интерфейсов
i=1
while [ $i -le $IFACE_COUNT ]; do
    select_interface "Выберите интерфейс #$i: "
    
    # Проверка на дубликаты
    already_selected=0
    for prev_iface in "${SELECTED_IFACES[@]}"; do
        if [ "$prev_iface" = "$SELECTED_IFACE" ]; then
            already_selected=1
            break
        fi
    done
    
    if [ $already_selected -eq 1 ]; then
        echo -e "${RED}Ошибка: этот интерфейс уже выбран${NC}"
        continue
    fi
    
    SELECTED_IFACES+=("$SELECTED_IFACE")
    SELECTED_IPS+=("$SELECTED_IP")
    SELECTED_VLANS+=("$SELECTED_VLAN")
    i=$((i + 1))
done

echo -e "${GREEN}Выбранные интерфейсы:${NC} ${SELECTED_IFACES[*]}"
echo ""

# =====================================================
# НАСТРОЙКА DNS И СУФФИКСА
# =====================================================

echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}  Настройка DNS параметров${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# DNS сервер
echo -e "${WHITE}Укажите IP адрес DNS сервера${NC}"
echo "(например, HQ-SRV: 192.168.10.2)"
read -p "DNS сервер [8.8.8.8]: " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-8.8.8.8}

# Вторичный DNS
read -p "Вторичный DNS сервер (Enter для пропуска): " DNS_SERVER_2

# DNS суффикс
echo ""
echo -e "${WHITE}Укажите DNS суффикс (доменное имя)${NC}"
echo "(например: au-team.irpo)"
read -p "DNS суффикс [au-team.irpo]: " DNS_SUFFIX
DNS_SUFFIX=${DNS_SUFFIX:-au-team.irpo}

echo ""
echo -e "${GREEN}DNS сервер: $DNS_SERVER${NC}"
[ -n "$DNS_SERVER_2" ] && echo -e "${GREEN}Вторичный DNS: $DNS_SERVER_2${NC}"
echo -e "${GREEN}DNS суффикс: $DNS_SUFFIX${NC}"
echo ""

# =====================================================
# ПАРАМЕТРЫ СЕТИ
# =====================================================

# Получаем параметры сети для каждого интерфейса
NETWORKS=()

echo -e "${WHITE}Определение параметров сети...${NC}"
echo ""

for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=($(get_network_info "$iface"))
    NETWORKS+=("${NET_INFO[*]}")
    
    echo -e "${CYAN}$iface${NC} -> Сеть: ${NET_INFO[0]} / ${NET_INFO[1]}"
    echo "   Шлюз: ${NET_INFO[5]}"
    echo "   DHCP диапазон: ${NET_INFO[3]} - ${NET_INFO[4]}"
    echo "   Broadcast: ${NET_INFO[2]}"
    echo ""
done

# Подтверждение
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  ПРОВЕРЬТЕ НАСТРОЙКИ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo -e "${WHITE}VLAN интерфейсы:${NC} ${SELECTED_IFACES[*]}"
echo -e "${WHITE}DNS сервер:${NC} $DNS_SERVER"
[ -n "$DNS_SERVER_2" ] && echo -e "${WHITE}Вторичный DNS:${NC} $DNS_SERVER_2"
echo -e "${WHITE}DNS суффикс:${NC} $DNS_SUFFIX"
echo ""
echo -e "${YELLOW}ВАЖНО! Клиенты должны быть подключены к тем же VLAN${NC}"
echo ""
read -p "Продолжить настройку? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Отменено"
    exit 0
fi

# =====================================================
# СОЗДАНИЕ КОНФИГУРАЦИИ DHCP
# =====================================================

echo ""
echo -e "${CYAN}Создание /etc/dhcp/dhcpd.conf...${NC}"

cat > /etc/dhcp/dhcpd.conf <<EOF
# DHCP Configuration for VLAN networks
# Generated by auto-config script
# $(date)

ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
authoritative;

# DNS параметры
option domain-name "$DNS_SUFFIX";
option domain-name-servers $DNS_SERVER$([ -n "$DNS_SERVER_2" ] && echo ", $DNS_SERVER_2");

EOF

# Добавляем подсети
idx=0
for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=(${NETWORKS[$idx]})
    vlan_id="${SELECTED_VLANS[$idx]}"
    gateway="${NET_INFO[5]}"
    
    # Комментарий с VLAN ID
    if [ "$vlan_id" != "-" ]; then
        echo "" >> /etc/dhcp/dhcpd.conf
        echo "# VLAN $vlan_id - $iface" >> /etc/dhcp/dhcpd.conf
    fi
    
    cat >> /etc/dhcp/dhcpd.conf <<EOF

# Network for $iface (VLAN $vlan_id)
subnet ${NET_INFO[0]} netmask ${NET_INFO[1]} {
  range ${NET_INFO[3]} ${NET_INFO[4]};
  option routers ${gateway};
  option broadcast-address ${NET_INFO[2]};
  option domain-name "$DNS_SUFFIX";
  option domain-name-servers $DNS_SERVER$([ -n "$DNS_SERVER_2" ] && echo ", $DNS_SERVER_2");
  default-lease-time 600;
  max-lease-time 7200;
}

EOF
    idx=$((idx + 1))
done

# Интерфейсы DHCP
IFACES_STR="${SELECTED_IFACES[*]}"
echo -e "${CYAN}Настройка /etc/sysconfig/dhcpd...${NC}"

cat > /etc/sysconfig/dhcpd <<EOF
# DHCP Server Arguments
# VLAN Interfaces: $IFACES_STR
DHCPDARGS="$IFACES_STR"
EOF

# Включение маршрутизации
echo -e "${CYAN}Включение IP forwarding...${NC}"
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# Открытие портов DHCP в firewall
echo -e "${CYAN}Настройка firewall для DHCP...${NC}"
iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --sport 67 --dport 68 -j ACCEPT 2>/dev/null

# Сохранение правил iptables
if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null
fi

# Перезапуск
echo -e "${CYAN}Перезапуск DHCP...${NC}"
systemctl enable dhcpd > /dev/null 2>&1
systemctl restart dhcpd

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] DHCP сервер запущен${NC}"
else
    echo -e "${RED}[ERROR] Не удалось запустить DHCP сервер${NC}"
    echo "Проверьте: journalctl -u dhcpd -n 50"
    exit 1
fi

# =====================================================
# ИТОГОВЫЙ ВЫВОД
# =====================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}         ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                        ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${WHITE}Параметры DHCP:${NC}"
echo "----------------------------------------"
echo -e "VLAN интерфейсы: ${CYAN}${SELECTED_IFACES[*]}${NC}"
echo -e "DNS сервер:      ${CYAN}$DNS_SERVER${NC}"
[ -n "$DNS_SERVER_2" ] && echo -e "Вторичный DNS:   ${CYAN}$DNS_SERVER_2${NC}"
echo -e "DNS суффикс:     ${CYAN}$DNS_SUFFIX${NC}"
echo "----------------------------------------"
echo ""

# Показываем конфигурацию подсетей
echo -e "${WHITE}Настроенные подсети:${NC}"
echo "----------------------------------------"
idx=0
for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=(${NETWORKS[$idx]})
    vlan_id="${SELECTED_VLANS[$idx]}"
    echo -e "${CYAN}VLAN $vlan_id${NC} ($iface):"
    echo "  Сеть:      ${NET_INFO[0]}/${NET_INFO[1]}"
    echo "  Шлюз:      ${NET_INFO[5]}"
    echo "  Диапазон:  ${NET_INFO[3]} - ${NET_INFO[4]}"
    echo ""
    idx=$((idx + 1))
done

# Статус
echo -e "${WHITE}Статус службы:${NC}"
systemctl status dhcpd --no-pager 2>/dev/null | head -10

# =====================================================
# ИНСТРУКЦИЯ ПО ПОДКЛЮЧЕНИЮ КЛИЕНТОВ
# =====================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}       ${WHITE}КАК ПОДКЛЮЧИТЬ КЛИЕНТОВ К VLAN${NC}             ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Вариант 1: VMware LAN Segments (рекомендуется)${NC}"
echo "  1. VMware -> Edit -> Virtual Network Editor"
echo "  2. Создайте LAN Segment для каждого VLAN"
echo "  3. Подключите клиентскую ВМ к нужному сегменту"
echo "  4. На клиенте: dhcpcd"
echo ""

echo -e "${YELLOW}Вариант 2: VLAN tagging на клиенте${NC}"
echo "  На клиенте выполните:"
echo ""
for vlan_id in "${SELECTED_VLANS[@]}"; do
    if [ "$vlan_id" != "-" ]; then
        echo -e "  ${GREEN}# Для VLAN $vlan_id:${NC}"
        echo "  ip link add link ens33 name ens33.$vlan_id type vlan id $vlan_id"
        echo "  ip link set ens33.$vlan_id up"
        echo "  dhcpcd ens33.$vlan_id"
        echo ""
    fi
done

echo -e "${YELLOW}Вариант 3: Через управляемый коммутатор${NC}"
echo "  Настройте access port в нужной VLAN"
echo ""

echo -e "${CYAN}Полезные команды:${NC}"
echo "  systemctl status dhcpd       - статус службы"
echo "  journalctl -u dhcpd -f       - логи в реальном времени"
echo "  dhcp-lease-list              - список выданных адресов"
echo "  cat /etc/dhcp/dhcpd.conf     - конфигурация"
echo ""
