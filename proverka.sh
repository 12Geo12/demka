#!/bin/bash
# ==============================================================================
# DHCP SETUP - ПРЯМОЕ СОЕДИНЕНИЕ HQ-RTR ↔ HQ-SRV (БЕЗ КОММУТАТОРА)
# ==============================================================================
# Топология: HQ-RTR (ens37) ──── LAN Segment ──── HQ-SRV (ens33)
# Автоматическое определение интерфейсов
# ==============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: Запустите от имени root${NC}"
    exit 1
fi

clear
echo -e "${CYAN}"
echo "========================================================================"
echo "       DHCP SETUP - Автоматическая настройка (без коммутатора)"
echo "========================================================================"
echo -e "${NC}"

# ============================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
# ============================================================
echo -e "${WHITE}[AUTO] Определение интерфейсов...${NC}"
echo "------------------------------------------------------------------------"

# Получаем все интерфейсы
ALL_IFACES=$(ls /sys/class/net/ | grep -v lo)

# Массивы для классификации
declare -a WAN_IFACES
declare -a LAN_IFACES
declare -a VLAN_IFACES
declare -a GRE_IFACES

# Классификация интерфейсов
for iface in $ALL_IFACES; do
    # Пропускаем loopback
    [ "$iface" = "lo" ] && continue
    
    # GRE туннели
    if [[ "$iface" == gre* ]] || [[ "$iface" == tun* ]]; then
        GRE_IFACES+=("$iface")
        continue
    fi
    
    # VLAN интерфейсы
    if [[ "$iface" == *.* ]]; then
        VLAN_IFACES+=("$iface")
        continue
    fi
    
    # Проверяем есть ли IP
    IP=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}')
    STATUS=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null)
    
    # Определяем тип по имени и наличию IP
    if [[ "$iface" == ens33 ]] || [[ "$iface" == eth0 ]]; then
        # ens33 или eth0 - обычно WAN (интернет)
        if [ -n "$IP" ]; then
            WAN_IFACES+=("$iface ($IP)")
        else
            WAN_IFACES+=("$iface (no IP)")
        fi
    elif [[ "$iface" == ens37 ]] || [[ "$iface" == eth1 ]] || [[ "$iface" == ens38 ]]; then
        # ens37, eth1, ens38 - обычно LAN
        if [ -n "$IP" ]; then
            LAN_IFACES+=("$iface ($IP)")
        else
            LAN_IFACES+=("$iface (no IP)")
        fi
    else
        # Остальные - проверяем по наличию внешнего IP
        if [ -n "$IP" ]; then
            # Проверяем, это внешняя сеть или внутренняя
            if echo "$IP" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
                LAN_IFACES+=("$iface ($IP)")
            else
                WAN_IFACES+=("$iface ($IP)")
            fi
        else
            LAN_IFACES+=("$iface (no IP)")
        fi
    fi
done

# Вывод результатов
echo ""
echo -e "${WHITE}Обнаруженные интерфейсы:${NC}"
echo ""

if [ ${#WAN_IFACES[@]} -gt 0 ]; then
    echo -e "  ${CYAN}WAN (интернет):${NC}"
    for iface in "${WAN_IFACES[@]}"; do
        echo "    - $iface"
    done
fi

if [ ${#LAN_IFACES[@]} -gt 0 ]; then
    echo -e "  ${GREEN}LAN (локальная сеть):${NC}"
    for iface in "${LAN_IFACES[@]}"; do
        echo "    - $iface"
    done
fi

if [ ${#VLAN_IFACES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}VLAN:${NC}"
    for iface in "${VLAN_IFACES[@]}"; do
        echo "    - $iface"
    done
fi

if [ ${#GRE_IFACES[@]} -gt 0 ]; then
    echo -e "  ${MAGENTA}GRE/Tunnel:${NC}"
    for iface in "${GRE_IFACES[@]}"; do
        echo "    - $iface"
    done
fi

# ============================================================
# АВТОВЫБОР LAN ИНТЕРФЕЙСА
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Выбор LAN интерфейса...${NC}"
echo "------------------------------------------------------------------------"

# Приоритет выбора LAN интерфейса
LAN_IFACE=""

# 1. Сначала ищем ens37
for iface in "${LAN_IFACES[@]}"; do
    if [[ "$iface" == ens37* ]]; then
        LAN_IFACE="ens37"
        break
    fi
done

# 2. Если не нашли, ищем eth1
if [ -z "$LAN_IFACE" ]; then
    for iface in "${LAN_IFACES[@]}"; do
        if [[ "$iface" == eth1* ]]; then
            LAN_IFACE="eth1"
            break
        fi
    done
fi

# 3. Если не нашли, берём первый LAN без IP (предпочтительно для настройки)
if [ -z "$LAN_IFACE" ]; then
    for iface in "${LAN_IFACES[@]}"; do
        if [[ "$iface" == *"(no IP)"* ]]; then
            LAN_IFACE=$(echo "$iface" | cut -d' ' -f1)
            break
        fi
    done
fi

# 4. Если всё ещё не нашли, берём первый LAN
if [ -z "$LAN_IFACE" ] && [ ${#LAN_IFACES[@]} -gt 0 ]; then
    LAN_IFACE=$(echo "${LAN_IFACES[0]}" | cut -d' ' -f1)
fi

# 5. Последний вариант - ищем любой интерфейс кроме WAN
if [ -z "$LAN_IFACE" ]; then
    for iface in $ALL_IFACES; do
        if [[ "$iface" != "lo" ]] && [[ "$iface" != *.* ]] && [[ "$iface" != gre* ]]; then
            # Проверяем, не это ли WAN (ens33 с внешним IP)
            if [[ "$iface" != "ens33" ]]; then
                LAN_IFACE="$iface"
                break
            fi
        fi
    done
fi

if [ -z "$LAN_IFACE" ]; then
    echo -e "${RED}Не удалось определить LAN интерфейс!${NC}"
    echo ""
    read -p "Введите имя интерфейса вручную: " LAN_IFACE
fi

echo -e "${GREEN}Выбран LAN интерфейс: $LAN_IFACE${NC}"

# ============================================================
# АВТОВЫБОР WAN ИНТЕРФЕЙСА
# ============================================================
WAN_IFACE=""
for iface in "${WAN_IFACES[@]}"; do
    if [[ "$iface" == ens33* ]]; then
        WAN_IFACE="ens33"
        break
    fi
done

if [ -z "$WAN_IFACE" ]; then
    for iface in "${WAN_IFACES[@]}"; do
        WAN_IFACE=$(echo "$iface" | cut -d' ' -f1)
        break
    done
fi

if [ -n "$WAN_IFACE" ]; then
    echo -e "${CYAN}WAN интерфейс: $WAN_IFACE${NC}"
fi

# ============================================================
# ВЫБОР СЕТИ
# ============================================================
echo ""
echo -e "${WHITE}Выберите сеть для DHCP:${NC}"
echo "  1) SRV-Net  (192.168.10.0/26) - для серверов [по умолчанию]"
echo "  2) CLI-Net  (192.168.20.0/28) - для клиентов"
echo "  3) Mgmt     (192.168.99.0/29) - для управления"
echo ""
read -p "Ваш выбор [1]: " NET_CHOICE
NET_CHOICE=${NET_CHOICE:-1}

case "$NET_CHOICE" in
    1)
        NETWORK="192.168.10.0"
        NETMASK="255.255.255.192"
        CIDR="26"
        GATEWAY="192.168.10.1"
        BROADCAST="192.168.10.63"
        RANGE_START="192.168.10.10"
        RANGE_END="192.168.10.60"
        NETWORK_NAME="SRV-Net"
        ;;
    2)
        NETWORK="192.168.20.0"
        NETMASK="255.255.255.240"
        CIDR="28"
        GATEWAY="192.168.20.1"
        BROADCAST="192.168.20.15"
        RANGE_START="192.168.20.5"
        RANGE_END="192.168.20.14"
        NETWORK_NAME="CLI-Net"
        ;;
    3)
        NETWORK="192.168.99.0"
        NETMASK="255.255.255.248"
        CIDR="29"
        GATEWAY="192.168.99.1"
        BROADCAST="192.168.99.7"
        RANGE_START="192.168.99.2"
        RANGE_END="192.168.99.6"
        NETWORK_NAME="Mgmt"
        ;;
    *)
        echo -e "${RED}Неверный выбор, используется SRV-Net${NC}"
        NETWORK="192.168.10.0"
        NETMASK="255.255.255.192"
        CIDR="26"
        GATEWAY="192.168.10.1"
        BROADCAST="192.168.10.63"
        RANGE_START="192.168.10.10"
        RANGE_END="192.168.10.60"
        NETWORK_NAME="SRV-Net"
        ;;
esac

echo ""
echo -e "${GREEN}Выбрана сеть: $NETWORK_NAME ($NETWORK/$CIDR)${NC}"
echo "  Шлюз: $GATEWAY"
echo "  DHCP диапазон: $RANGE_START - $RANGE_END"

# ============================================================
# ОЧИСТКА VLAN
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Проверка VLAN на $LAN_IFACE...${NC}"
echo "------------------------------------------------------------------------"

VLAN_REMOVED=0
for vlan_dir in /etc/net/ifaces/${LAN_IFACE}.*; do
    if [ -d "$vlan_dir" ]; then
        vlan_name=$(basename "$vlan_dir")
        echo -e "  ${YELLOW}Удаление VLAN: $vlan_name${NC}"
        
        ip link set "$vlan_name" down 2>/dev/null
        ip link del "$vlan_name" 2>/dev/null
        rm -rf "$vlan_dir"
        
        VLAN_REMOVED=$((VLAN_REMOVED + 1))
    fi
done

if [ $VLAN_REMOVED -eq 0 ]; then
    echo -e "  ${GREEN}VLAN не найдены${NC}"
else
    echo -e "  ${GREEN}Удалено VLAN: $VLAN_REMOVED${NC}"
fi

# ============================================================
# НАСТРОЙКА IP
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Настройка IP на $LAN_IFACE...${NC}"
echo "------------------------------------------------------------------------"

IFACE_DIR="/etc/net/ifaces/$LAN_IFACE"
mkdir -p "$IFACE_DIR"

# options
cat > "$IFACE_DIR/options" << EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
EOF

# ipv4address
echo "$GATEWAY/$CIDR" > "$IFACE_DIR/ipv4address"

# Удаляем маршрут если есть
rm -f "$IFACE_DIR/ipv4route"

# Применяем немедленно
ip addr flush dev "$LAN_IFACE" 2>/dev/null
ip addr add "$GATEWAY/$CIDR" dev "$LAN_IFACE" 2>/dev/null
ip link set "$LAN_IFACE" up

# Проверка
if ip addr show "$LAN_IFACE" | grep -q "$GATEWAY"; then
    echo -e "${GREEN}IP настроен: $GATEWAY/$CIDR${NC}"
else
    echo -e "${RED}Ошибка настройки IP${NC}"
fi

# ============================================================
# УСТАНОВКА DHCP
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Установка DHCP сервера...${NC}"
echo "------------------------------------------------------------------------"

if ! rpm -q dhcp-server &>/dev/null; then
    apt-get update -qq
    apt-get install -y dhcp-server
    echo -e "${GREEN}DHCP сервер установлен${NC}"
else
    echo -e "${GREEN}DHCP сервер уже установлен${NC}"
fi

# ============================================================
# КОНФИГУРАЦИЯ DHCP
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Создание конфигурации DHCP...${NC}"
echo "------------------------------------------------------------------------"

cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP Configuration for Demo2026 Exam
# Автоматическая настройка - прямое соединение
# Сеть: $NETWORK_NAME
# Интерфейс: $LAN_IFACE

default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;

# $NETWORK_NAME
subnet $NETWORK netmask $NETMASK {
    range $RANGE_START $RANGE_END;
    option routers $GATEWAY;
    option subnet-mask $NETMASK;
    option broadcast-address $BROADCAST;
    option domain-name "au-team.irpo";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

echo -e "${GREEN}/etc/dhcp/dhcpd.conf создан${NC}"

# Интерфейсы
cat > /etc/sysconfig/dhcpd << EOF
DHCPDARGS="$LAN_IFACE"
EOF

echo -e "${GREEN}/etc/sysconfig/dhcpd: DHCPDARGS=\"$LAN_IFACE\"${NC}"

# ============================================================
# IP FORWARDING
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Включение IP forwarding...${NC}"
echo "------------------------------------------------------------------------"

SYSCTL_FILE="/etc/sysctl.conf"
[ -f "/etc/net/sysctl.conf" ] && SYSCTL_FILE="/etc/net/sysctl.conf"

if ! grep -q "net.ipv4.ip_forward" "$SYSCTL_FILE"; then
    echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
else
    sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
fi
sysctl -p > /dev/null 2>&1

echo -e "${GREEN}IP forwarding включён${NC}"

# ============================================================
# NAT (если есть WAN)
# ============================================================
if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$LAN_IFACE" ]; then
    echo ""
    echo -e "${WHITE}[AUTO] Настройка NAT ($LAN_IFACE -> $WAN_IFACE)...${NC}"
    echo "------------------------------------------------------------------------"
    
    # Очищаем старые правила NAT для этой сети
    iptables -t nat -D POSTROUTING -s "$NETWORK/$CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
    
    # Добавляем новое правило
    iptables -t nat -A POSTROUTING -s "$NETWORK/$CIDR" -o "$WAN_IFACE" -j MASQUERADE
    
    # Forward
    iptables -D FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -D FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Сохраняем
    if [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
    
    echo -e "${GREEN}NAT настроен: $NETWORK/$CIDR -> $WAN_IFACE${NC}"
fi

# ============================================================
# ЗАПУСК DHCP
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Запуск DHCP сервера...${NC}"
echo "------------------------------------------------------------------------"

systemctl enable dhcpd 2>/dev/null
systemctl restart dhcpd 2>/dev/null

sleep 2

# ============================================================
# ИТОГИ
# ============================================================
echo ""
echo -e "${CYAN}========================================================================${NC}"
echo -e "${WHITE}                           РЕЗУЛЬТАТ${NC}"
echo -e "${CYAN}========================================================================${NC}"

echo ""
echo -e "${WHITE}Интерфейсы:${NC}"
ip -brief addr show | grep -E "($LAN_IFACE|$WAN_IFACE)"

echo ""
echo -e "${WHITE}DHCP сервер:${NC}"
if systemctl is-active dhcpd &>/dev/null; then
    echo -e "  Статус: ${GREEN}АКТИВЕН${NC}"
    ss -ulnp | grep ":67"
else
    echo -e "  Статус: ${RED}ОШИБКА${NC}"
    journalctl -u dhcpd -n 5 --no-pager
fi

echo ""
echo -e "${WHITE}Конфигурация:${NC}"
echo "  LAN интерфейс: $LAN_IFACE"
echo "  IP адрес: $GATEWAY/$CIDR"
echo "  Сеть: $NETWORK_NAME ($NETWORK/$CIDR)"
echo "  DHCP диапазон: $RANGE_START - $RANGE_END"
echo "  Домен: au-team.irpo"

[ -n "$WAN_IFACE" ] && echo "  NAT: $LAN_IFACE -> $WAN_IFACE"

echo ""
echo -e "${CYAN}========================================================================${NC}"
echo -e "${WHITE}                    ГОТОВО!${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo ""
echo "На HQ-SRV выполните:"
echo ""
echo "  mkdir -p /etc/net/ifaces/ens33"
echo "  echo 'BOOTPROTO=dhcp' > /etc/net/ifaces/ens33/options"
echo "  echo 'TYPE=eth' >> /etc/net/ifaces/ens33/options"
echo "  echo 'ONBOOT=yes' >> /etc/net/ifaces/ens33/options"
echo "  systemctl restart network"
echo ""
