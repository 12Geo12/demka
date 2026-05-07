#!/bin/bash
# ==============================================================================
# DHCP SETUP - VLAN + NATIVE EDITION
# ==============================================================================
# Топология: HQ-RTR (ens37) ──── прямое соединение ──── HQ-SRV (ens33)
# Одна сеть (native) раздаётся на основном интерфейсе — SRV получает IP напрямую
# Остальные сети идут через VLAN субинтерфейсы
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
echo "       DHCP SETUP - VLAN + NATIVE (SRV получает IP напрямую)"
echo "========================================================================"
echo -e "${NC}"

# ============================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
# ============================================================
echo -e "${WHITE}[AUTO] Определение интерфейсов...${NC}"
echo "------------------------------------------------------------------------"

ALL_IFACES=$(ls /sys/class/net/ | grep -v lo)

declare -a WAN_IFACES
declare -a LAN_IFACES
declare -a VLAN_IFACES
declare -a GRE_IFACES

for iface in $ALL_IFACES; do
    [ "$iface" = "lo" ] && continue

    if [[ "$iface" == gre* ]] || [[ "$iface" == tun* ]]; then
        GRE_IFACES+=("$iface")
        continue
    fi

    if [[ "$iface" == *.* ]]; then
        VLAN_IFACES+=("$iface")
        continue
    fi

    IP=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}')
    STATUS=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null)

    if [[ "$iface" == ens33 ]] || [[ "$iface" == eth0 ]]; then
        if [ -n "$IP" ]; then
            WAN_IFACES+=("$iface ($IP)")
        else
            WAN_IFACES+=("$iface (no IP)")
        fi
    elif [[ "$iface" == ens37 ]] || [[ "$iface" == eth1 ]] || [[ "$iface" == ens38 ]]; then
        if [ -n "$IP" ]; then
            LAN_IFACES+=("$iface ($IP)")
        else
            LAN_IFACES+=("$iface (no IP)")
        fi
    else
        if [ -n "$IP" ]; then
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
echo -e "${WHITE}[AUTO] Выбор LAN интерфейса (parent)...${NC}"
echo "------------------------------------------------------------------------"

LAN_IFACE=""

for iface in "${LAN_IFACES[@]}"; do
    if [[ "$iface" == ens37* ]]; then
        LAN_IFACE="ens37"
        break
    fi
done

if [ -z "$LAN_IFACE" ]; then
    for iface in "${LAN_IFACES[@]}"; do
        if [[ "$iface" == eth1* ]]; then
            LAN_IFACE="eth1"
            break
        fi
    done
fi

if [ -z "$LAN_IFACE" ]; then
    for iface in "${LAN_IFACES[@]}"; do
        if [[ "$iface" == *"(no IP)"* ]]; then
            LAN_IFACE=$(echo "$iface" | cut -d' ' -f1)
            break
        fi
    done
fi

if [ -z "$LAN_IFACE" ] && [ ${#LAN_IFACES[@]} -gt 0 ]; then
    LAN_IFACE=$(echo "${LAN_IFACES[0]}" | cut -d' ' -f1)
fi

if [ -z "$LAN_IFACE" ]; then
    for iface in $ALL_IFACES; do
        if [[ "$iface" != "lo" ]] && [[ "$iface" != *.* ]] && [[ "$iface" != gre* ]]; then
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
# ВЫБОР СЕТЕЙ
# ============================================================
echo ""
echo -e "${WHITE}Выберите сети (можно несколько, через пробел):${NC}"
echo "  Первая выбранная сеть = NATIVE (раздаётся на основном интерфейсе)"
echo "  Остальные сети = VLAN (раздаются через субинтерфейсы)"
echo ""
echo "  10) SRV-Net  (192.168.10.0/26) - для серверов"
echo "  20) CLI-Net  (192.168.20.0/28) - для клиентов"
echo "  99) Mgmt     (192.168.99.0/29) - для управления"
echo ""
echo -e "${YELLOW}Пример: 10 20 99  (VLAN 10 = native, 20 и 99 = tagged VLAN)${NC}"
echo ""
read -p "Ввод [10 20]: " VLAN_INPUT
VLAN_INPUT=${VLAN_INPUT:-"10 20"}

# Парсим выбранные VLAN
declare -a VLAN_ORDER=()
declare -A SELECTED_VLANS

for v in $VLAN_INPUT; do
    case "$v" in
        10)
            if [ -z "${SELECTED_VLANS[10]+x}" ]; then
                VLAN_ORDER+=("10")
                SELECTED_VLANS[10]="SRV-Net"
            fi
            ;;
        20)
            if [ -z "${SELECTED_VLANS[20]+x}" ]; then
                VLAN_ORDER+=("20")
                SELECTED_VLANS[20]="CLI-Net"
            fi
            ;;
        99)
            if [ -z "${SELECTED_VLANS[99]+x}" ]; then
                VLAN_ORDER+=("99")
                SELECTED_VLANS[99]="Mgmt"
            fi
            ;;
        *)
            echo -e "${YELLOW}Внимание: VLAN $v неизвестен, пропускается${NC}"
            ;;
    esac
done

if [ ${#VLAN_ORDER[@]} -eq 0 ]; then
    echo -e "${RED}Не выбрано ни одной сети. Использую 10 и 20${NC}"
    VLAN_ORDER=("10" "20")
    SELECTED_VLANS[10]="SRV-Net"
    SELECTED_VLANS[20]="CLI-Net"
fi

# Первая выбранная VLAN = NATIVE (untagged, на parent интерфейсе)
NATIVE_VID="${VLAN_ORDER[0]}"
NATIVE_NAME="${SELECTED_VLANS[$NATIVE_VID]}"

echo ""
echo -e "${GREEN}Выбраны сети:${NC}"
echo -e "  ${MAGENTA}>>> NATIVE (untagged) VLAN $NATIVE_VID -> ${NATIVE_NAME}${MAGENTA}"
echo -e "     (вешается на $LAN_IFACE, SRV получит IP напрямую)${NC}"
for i in "${!VLAN_ORDER[@]}"; do
    vid="${VLAN_ORDER[$i]}"
    if [ "$i" -eq 0 ]; then continue; fi
    echo -e "      VLAN $vid -> ${SELECTED_VLANS[$vid]} (tagged, ${LAN_IFACE}.${vid})"
done

# ============================================================
# VLAN НЕ УДАЛЯЮТСЯ — только показываем
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Проверка существующих VLAN на $LAN_IFACE (без удаления)...${NC}"
echo "------------------------------------------------------------------------"

VLAN_EXISTING=0
for vlan_dir in /etc/net/ifaces/${LAN_IFACE}.*; do
    if [ -d "$vlan_dir" ]; then
        vlan_name=$(basename "$vlan_dir")
        echo -e "  ${GREEN}Обнаружен VLAN: $vlan_name (оставляем)${NC}"
        VLAN_EXISTING=$((VLAN_EXISTING + 1))
    fi
done

for vlan_link in $(ip link show | grep -oP "${LAN_IFACE}\.\d+"); do
    if [ ! -d "/etc/net/ifaces/$vlan_link" ]; then
        echo -e "  ${YELLOW}VLAN $vlan_link в ядре без конфига (оставляем)${NC}"
    fi
done

if [ $VLAN_EXISTING -eq 0 ]; then
    echo -e "  ${YELLOW}Существующих VLAN не обнаружено${NC}"
else
    echo -e "  ${GREEN}Найдено VLAN: $VLAN_EXISTING (сохранены)${NC}"
fi

# ============================================================
# ФУНКЦИЯ: параметры сети по VLAN ID
# ============================================================
get_vlan_params() {
    local VID=$1
    case "$VID" in
        10)
            echo "SRV-Net 192.168.10.0 255.255.255.192 26 192.168.10.1 192.168.10.10 192.168.10.60 192.168.10.63"
            ;;
        20)
            echo "CLI-Net 192.168.20.0 255.255.255.240 28 192.168.20.1 192.168.20.5 192.168.20.14 192.168.20.15"
            ;;
        99)
            echo "Mgmt 192.168.99.0 255.255.255.248 29 192.168.99.1 192.168.99.2 192.168.99.6 192.168.99.7"
            ;;
    esac
}

# ============================================================
# НАСТРОЙКА NATIVE СЕТИ НА PARENT ИНТЕРФЕЙСЕ
# ============================================================
NATIVE_PARAMS=$(get_vlan_params "$NATIVE_VID")
NATIVE_NET_NAME=$(echo "$NATIVE_PARAMS" | awk '{print $1}')
NATIVE_NETWORK=$(echo "$NATIVE_PARAMS" | awk '{print $2}')
NATIVE_NETMASK=$(echo "$NATIVE_PARAMS" | awk '{print $3}')
NATIVE_CIDR=$(echo "$NATIVE_PARAMS" | awk '{print $4}')
NATIVE_GATEWAY=$(echo "$NATIVE_PARAMS" | awk '{print $5}')
NATIVE_RANGE_START=$(echo "$NATIVE_PARAMS" | awk '{print $6}')
NATIVE_RANGE_END=$(echo "$NATIVE_PARAMS" | awk '{print $7}')
NATIVE_BROADCAST=$(echo "$NATIVE_PARAMS" | awk '{print $8}')

echo ""
echo -e "${WHITE}[AUTO] Настройка $LAN_IFACE -> NATIVE VLAN $NATIVE_VID (${NATIVE_NAME})${NC}"
echo "------------------------------------------------------------------------"

IFACE_DIR="/etc/net/ifaces/$LAN_IFACE"
mkdir -p "$IFACE_DIR"

# Parent интерфейс — с IP от native VLAN
cat > "$IFACE_DIR/options" << EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
EOF

echo "$NATIVE_GATEWAY/$NATIVE_CIDR" > "$IFACE_DIR/ipv4address"
rm -f "$IFACE_DIR/ipv4route"

# Применяем немедленно
ip addr flush dev "$LAN_IFACE" 2>/dev/null
ip addr add "$NATIVE_GATEWAY/$NATIVE_CIDR" dev "$LAN_IFACE" 2>/dev/null
ip link set "$LAN_IFACE" up

if ip addr show "$LAN_IFACE" | grep -q "$NATIVE_GATEWAY"; then
    echo -e "${GREEN}$LAN_IFACE настроен: $NATIVE_GATEWAY/$NATIVE_CIDR (NATIVE: ${NATIVE_NAME})${NC}"
else
    echo -e "${RED}Ошибка настройки IP на $LAN_IFACE${NC}"
fi

# ============================================================
# ФУНКЦИЯ: создание VLAN субинтерфейса
# ============================================================
create_vlan_interface() {
    local VID=$1
    local VLAN_NAME=$2
    local NETWORK=$3
    local NETMASK=$4
    local CIDR=$5
    local GATEWAY=$6
    local RANGE_START=$7
    local RANGE_END=$8
    local BROADCAST=$9

    local VIF="${LAN_IFACE}.${VID}"
    local VIF_DIR="/etc/net/ifaces/$VIF"

    echo ""
    echo -e "${WHITE}[VLAN $VID] Настройка $VIF -> ${VLAN_NAME}${NC}"
    echo "------------------------------------------------------------------------"

    if [ -d "$VIF_DIR" ]; then
        echo -e "  ${YELLOW}Конфиг $VIF уже существует — пропускаем (не удаляем)${NC}"
    else
        mkdir -p "$VIF_DIR"
        cat > "$VIF_DIR/options" << EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
EOF
        echo -e "  ${GREEN}Конфиг $VIF_DIR/options создан${NC}"
    fi

    echo "$GATEWAY/$CIDR" > "$VIF_DIR/ipv4address"
    rm -f "$VIF_DIR/ipv4route"

    if ! ip link show "$VIF" &>/dev/null; then
        echo -e "  ${WHITE}Создание VLAN $VIF (802.1Q, vid $VID)...${NC}"
        ip link add link "$LAN_IFACE" name "$VIF" type vlan id "$VID"
        ip link set "$VIF" up
    else
        echo -e "  ${GREEN}VLAN $VIF уже существует${NC}"
    fi

    ip addr flush dev "$VIF" 2>/dev/null
    ip addr add "$GATEWAY/$CIDR" dev "$VIF" 2>/dev/null
    ip link set "$VIF" up

    if ip addr show "$VIF" | grep -q "$GATEWAY"; then
        echo -e "  ${GREEN}IP на $VIF: $GATEWAY/$CIDR${NC}"
    else
        echo -e "  ${RED}Ошибка настройки IP на $VIF${NC}"
    fi
}

# ============================================================
# СОЗДАНИЕ VLAN СУБИНТЕРФЕЙСОВ (для НЕ-native VLAN)
# ============================================================
DHCP_IFACE_LIST="$LAN_IFACE"
DHCP_CONF_SUBNETS=""

for i in "${!VLAN_ORDER[@]}"; do
    vid="${VLAN_ORDER[$i]}"

    # Пропускаем native VLAN — она уже на parent
    if [ "$i" -eq 0 ]; then
        continue
    fi

    VNAME="${SELECTED_VLANS[$vid]}"
    PARAMS=$(get_vlan_params "$vid")

    V_NET_NAME=$(echo "$PARAMS" | awk '{print $1}')
    V_NETWORK=$(echo "$PARAMS" | awk '{print $2}')
    V_NETMASK=$(echo "$PARAMS" | awk '{print $3}')
    V_CIDR=$(echo "$PARAMS" | awk '{print $4}')
    V_GATEWAY=$(echo "$PARAMS" | awk '{print $5}')
    V_RANGE_START=$(echo "$PARAMS" | awk '{print $6}')
    V_RANGE_END=$(echo "$PARAMS" | awk '{print $7}')
    V_BROADCAST=$(echo "$PARAMS" | awk '{print $8}')

    create_vlan_interface "$vid" "$V_NET_NAME" "$V_NETWORK" "$V_NETMASK" "$V_CIDR" "$V_GATEWAY" "$V_RANGE_START" "$V_RANGE_END" "$V_BROADCAST"

    DHCP_IFACE_LIST="$DHCP_IFACE_LIST ${LAN_IFACE}.${vid}"

    DHCP_CONF_SUBNETS="${DHCP_CONF_SUBNETS}
# VLAN $vid - $V_NET_NAME (${LAN_IFACE}.${vid})
subnet $V_NETWORK netmask $V_NETMASK {
    range $V_RANGE_START $V_RANGE_END;
    option routers $V_GATEWAY;
    option subnet-mask $V_NETMASK;
    option broadcast-address $V_BROADCAST;
    option domain-name \"au-team.irpo\";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
    default-lease-time 600;
    max-lease-time 7200;
}
"
done

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

# NATIVE subnet ПЕРВЫМ (чтобы приоритет на parent интерфейсе)
cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP Configuration for Demo2026 Exam
# Native + VLAN Edition
# Parent: $LAN_IFACE -> NATIVE VLAN $NATIVE_VID (${NATIVE_NAME})

default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;

# NATIVE (untagged) - VLAN $NATIVE_VID - ${NATIVE_NAME}
# Раздаётся на $LAN_IFACE — SRV получает IP напрямую
subnet $NATIVE_NETWORK netmask $NATIVE_NETMASK {
    range $NATIVE_RANGE_START $NATIVE_RANGE_END;
    option routers $NATIVE_GATEWAY;
    option subnet-mask $NATIVE_NETMASK;
    option broadcast-address $NATIVE_BROADCAST;
    option domain-name "au-team.irpo";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
    default-lease-time 600;
    max-lease-time 7200;
}
$DHCP_CONF_SUBNETS
EOF

echo -e "${GREEN}/etc/dhcp/dhcpd.conf создан${NC}"

# Слушаем на parent + все VLAN субинтерфейсы
cat > /etc/sysconfig/dhcpd << EOF
DHCPDARGS="$DHCP_IFACE_LIST"
EOF

echo -e "${GREEN}/etc/sysconfig/dhcpd: DHCPDARGS=\"$DHCP_IFACE_LIST\"${NC}"

# Создаём leases-файл если отсутствует
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
LEASE_DIR=$(dirname "$LEASE_FILE")
if [ ! -d "$LEASE_DIR" ]; then
    mkdir -p "$LEASE_DIR"
fi
if [ ! -f "$LEASE_FILE" ]; then
    touch "$LEASE_FILE"
    echo -e "${GREEN}Создан leases-файл: $LEASE_FILE${NC}"
fi

# Проверяем конфиг перед запуском
echo -e "${WHITE}[AUTO] Проверка конфигурации DHCP...${NC}"
dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка в dhcpd.conf! Смотрите выше.${NC}"
else
    echo -e "${GREEN}Конфигурация DHCP валидна${NC}"
fi

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
# NAT (для всех сетей, если есть WAN)
# ============================================================
if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$LAN_IFACE" ]; then
    echo ""
    echo -e "${WHITE}[AUTO] Настройка NAT ($WAN_IFACE)...${NC}"
    echo "------------------------------------------------------------------------"

    # NAT для native сети (на parent интерфейсе)
    iptables -t nat -D POSTROUTING -s "$NATIVE_NETWORK/$NATIVE_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -s "$NATIVE_NETWORK/$NATIVE_CIDR" -o "$WAN_IFACE" -j MASQUERADE
    iptables -D FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -D FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo -e "  ${GREEN}NAT: $LAN_IFACE ($NATIVE_NETWORK/$NATIVE_CIDR) -> $WAN_IFACE${NC}"

    # NAT для VLAN субинтерфейсов
    for i in "${!VLAN_ORDER[@]}"; do
        vid="${VLAN_ORDER[$i]}"
        [ "$i" -eq 0 ] && continue

        PARAMS=$(get_vlan_params "$vid")
        V_NETWORK=$(echo "$PARAMS" | awk '{print $2}')
        V_CIDR=$(echo "$PARAMS" | awk '{print $4}')
        VIF="${LAN_IFACE}.${vid}"

        iptables -t nat -D POSTROUTING -s "$V_NETWORK/$V_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
        iptables -t nat -A POSTROUTING -s "$V_NETWORK/$V_CIDR" -o "$WAN_IFACE" -j MASQUERADE
        iptables -D FORWARD -i "$VIF" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
        iptables -A FORWARD -i "$VIF" -o "$WAN_IFACE" -j ACCEPT
        iptables -D FORWARD -i "$WAN_IFACE" -o "$VIF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -A FORWARD -i "$WAN_IFACE" -o "$VIF" -m state --state ESTABLISHED,RELATED -j ACCEPT

        echo -e "  ${GREEN}NAT: $VIF ($V_NETWORK/$V_CIDR) -> $WAN_IFACE${NC}"
    done

    if [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
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
echo -e "${WHITE}                      РЕЗУЛЬТАТ (NATIVE + VLAN)${NC}"
echo -e "${CYAN}========================================================================${NC}"

echo ""
echo -e "${WHITE}Интерфейсы:${NC}"
ip -brief addr show | grep -E "($LAN_IFACE\b|$LAN_IFACE\.[0-9]+|$WAN_IFACE)"

echo ""
echo -e "${WHITE}DHCP сервер:${NC}"
if systemctl is-active dhcpd &>/dev/null; then
    echo -e "  Статус: ${GREEN}АКТИВЕН${NC}"
    echo -e "  Слушает на: ${CYAN}$DHCP_IFACE_LIST${NC}"
    ss -ulnp | grep ":67"
else
    echo -e "  Статус: ${RED}ОШИБКА${NC}"
    journalctl -u dhcpd -n 10 --no-pager
fi

echo ""
echo -e "${WHITE}Конфигурация:${NC}"
echo -e "  ${MAGENTA}NATIVE (untagged):${NC}"
echo "    $LAN_IFACE -> VLAN $NATIVE_VID (${NATIVE_NAME})"
echo "    IP: $NATIVE_GATEWAY/$NATIVE_CIDR  |  DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
echo -e "    ${YELLOW}HQ-SRV получит IP по DHCP напрямую на ens33${NC}"

# Показываем VLAN субинтерфейсы
for i in "${!VLAN_ORDER[@]}"; do
    vid="${VLAN_ORDER[$i]}"
    [ "$i" -eq 0 ] && continue
    PARAMS=$(get_vlan_params "$vid")
    V_NET_NAME=$(echo "$PARAMS" | awk '{print $1}')
    V_NETWORK=$(echo "$PARAMS" | awk '{print $2}')
    V_CIDR=$(echo "$PARAMS" | awk '{print $4}')
    V_GATEWAY=$(echo "$PARAMS" | awk '{print $5}')
    V_RANGE_START=$(echo "$PARAMS" | awk '{print $6}')
    V_RANGE_END=$(echo "$PARAMS" | awk '{print $7}')
    echo -e "  ${CYAN}VLAN $vid (tagged):${NC}"
    echo "    ${LAN_IFACE}.${vid} -> ${V_NET_NAME}"
    echo "    IP: $V_GATEWAY/$V_CIDR  |  DHCP: $V_RANGE_START - $V_RANGE_END"
done

echo "  Домен: au-team.irpo"
[ -n "$WAN_IFACE" ] && echo "  NAT: все сети -> $WAN_IFACE"

echo ""
echo -e "${CYAN}========================================================================${NC}"
echo -e "${WHITE}                         ГОТОВО!${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo ""
echo "На HQ-SRV для получения IP (только основной интерфейс ens33):"
echo ""
echo "  mkdir -p /etc/net/ifaces/ens33"
echo "  echo 'BOOTPROTO=dhcp' > /etc/net/ifaces/ens33/options"
echo "  echo 'TYPE=eth' >> /etc/net/ifaces/ens33/options"
echo "  echo 'ONBOOT=yes' >> /etc/net/ifaces/ens33/options"
echo "  systemctl restart network"
echo ""
echo -e "${GREEN}HQ-SRV получит IP из ${NATIVE_NAME} ($NATIVE_RANGE_START - $NATIVE_RANGE_END)${NC}"
echo ""
