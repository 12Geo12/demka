#!/bin/bash
# ==============================================================================
# DHCP SETUP - VLAN EDITION (DHCP раздаётся по VLAN)
# ==============================================================================
# Топология: HQ-RTR (ens37) ──── VLAN ──── HQ-SRV (ens33)
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
echo "       DHCP SETUP - VLAN EDITION (DHCP по VLAN)"
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
echo -e "${WHITE}[AUTO] Выбор LAN интерфейса (parent для VLAN)...${NC}"
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

echo -e "${GREEN}Выбран LAN интерфейс (parent): $LAN_IFACE${NC}"

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
# ВЫБОР СЕТЕЙ / VLAN (несколько одновременно)
# ============================================================
echo ""
echo -e "${WHITE}Выберите сети для VLAN (можно несколько, через пробел):${NC}"
echo "  10) SRV-Net  (192.168.10.0/26) - для серверов"
echo "  20) CLI-Net  (192.168.20.0/28) - для клиентов"
echo "  99) Mgmt     (192.168.99.0/29) - для управления"
echo ""
echo -e "${YELLOW}Пример: 10 20 99${NC}"
echo -e "${YELLOW}Пример: 10 20${NC}"
echo ""
read -p "Ввод [10 20]: " VLAN_INPUT
VLAN_INPUT=${VLAN_INPUT:-"10 20"}

# Парсим выбранные VLAN
declare -A SELECTED_VLANS
for v in $VLAN_INPUT; do
    case "$v" in
        10)
            SELECTED_VLANS[10]="SRV-Net"
            ;;
        20)
            SELECTED_VLANS[20]="CLI-Net"
            ;;
        99)
            SELECTED_VLANS[99]="Mgmt"
            ;;
        *)
            echo -e "${YELLOW}Внимание: VLAN $v неизвестен, пропускается${NC}"
            ;;
    esac
done

if [ ${#SELECTED_VLANS[@]} -eq 0 ]; then
    echo -e "${RED}Не выбрано ни одной сети. Использую VLAN 10 и 20${NC}"
    SELECTED_VLANS[10]="SRV-Net"
    SELECTED_VLANS[20]="CLI-Net"
fi

echo ""
echo -e "${GREEN}Выбраны VLAN:${NC}"
for vid in $(echo "${!SELECTED_VLANS[@]}" | tr ' ' '\n' | sort -n); do
    echo "    VLAN $vid  ->  ${SELECTED_VLANS[$vid]}"
done

# ============================================================
# VLAN НЕ УДАЛЯЮТСЯ — только показываем существующие
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Проверка существующих VLAN на $LAN_IFACE (без удаления)...${NC}"
echo "------------------------------------------------------------------------"

VLAN_EXISTING=0
for vlan_dir in /etc/net/ifaces/${LAN_IFACE}.*; do
    if [ -d "$vlan_dir" ]; then
        vlan_name=$(basename "$vlan_dir")
        echo -e "  ${GREEN}Обнаружен существующий VLAN: $vlan_name (оставляем)${NC}"
        VLAN_EXISTING=$((VLAN_EXISTING + 1))
    fi
done

# Также проверяем VLAN в ядре
for vlan_link in $(ip link show | grep -oP "${LAN_IFACE}\.\d+"); do
    if [ ! -d "/etc/net/ifaces/$vlan_link" ]; then
        echo -e "  ${YELLOW}VLAN $vlan_link найден в ядре, но нет конфига (оставляем)${NC}"
    fi
done

if [ $VLAN_EXISTING -eq 0 ]; then
    echo -e "  ${YELLOW}Существующих VLAN не обнаружено — создадим новые${NC}"
else
    echo -e "  ${GREEN}Найдено VLAN: $VLAN_EXISTING (сохранены)${NC}"
fi

# ============================================================
# ФУНКЦИЯ: создание/проверка VLAN субинтерфейса
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

    # Проверяем, существует ли уже VLAN
    if [ -d "$VIF_DIR" ]; then
        echo -e "  ${YELLOW}Конфиг $VIF уже существует — пропускаем создание (не удаляем)${NC}"
    else
        # Создаём конфигурационную директорию
        mkdir -p "$VIF_DIR"

        # options
        cat > "$VIF_DIR/options" << EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
EOF

        echo -e "  ${GREEN}Конфиг $VIF_DIR/options создан${NC}"
    fi

    # Пишем IP-адрес (перезаписываем для актуальности)
    echo "$GATEWAY/$CIDR" > "$VIF_DIR/ipv4address"

    # Удаляем маршруты если есть
    rm -f "$VIF_DIR/ipv4route"

    # Создаём VLAN линк в ядре (если ещё нет)
    if ! ip link show "$VIF" &>/dev/null; then
        echo -e "  ${WHITE}Создание VLAN-интерфейса $VIF (802.1Q, vid $VID)...${NC}"
        ip link add link "$LAN_IFACE" name "$VIF" type vlan id "$VID"
        ip link set "$VIF" up
    else
        echo -e "  ${GREEN}VLAN-интерфейс $VIF уже существует в ядре${NC}"
    fi

    # Применяем IP немедленно
    ip addr flush dev "$VIF" 2>/dev/null
    ip addr add "$GATEWAY/$CIDR" dev "$VIF" 2>/dev/null
    ip link set "$VIF" up

    # Проверка
    if ip addr show "$VIF" | grep -q "$GATEWAY"; then
        echo -e "  ${GREEN}IP настроен на $VIF: $GATEWAY/$CIDR${NC}"
    else
        echo -e "  ${RED}Ошибка настройки IP на $VIF${NC}"
    fi

    echo -e "  ${GREEN}VLAN $VID (${VLAN_NAME}) -> $GATEWAY/$CIDR${NC}"
}

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
# СОЗДАНИЕ VLAN СУБИНТЕРФЕЙСОВ
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Создание/проверка VLAN субинтерфейсов...${NC}"
echo "------------------------------------------------------------------------"

DHCP_IFACE_LIST=""    # список интерфейсов для DHCPDARGS
DHCP_CONF_SUBNETS=""  # блоки subnet для dhcpd.conf

for vid in $(echo "${!SELECTED_VLANS[@]}" | tr ' ' '\n' | sort -n); do
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

    # Собираем список интерфейсов для DHCP
    if [ -n "$DHCP_IFACE_LIST" ]; then
        DHCP_IFACE_LIST="$DHCP_IFACE_LIST ${LAN_IFACE}.${vid}"
    else
        DHCP_IFACE_LIST="${LAN_IFACE}.${vid}"
    fi

    # Собираем блок subnet для DHCP
    DHCP_CONF_SUBNETS="${DHCP_CONF_SUBNETS}
# VLAN $vid - $V_NET_NAME (${LAN_IFACE}.${vid})
subnet $V_NETWORK netmask $V_NETMASK {
    interface ${LAN_IFACE}.${vid};
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
# НАСТРОЙКА PARENT ИНТЕРФЕЙСА (без IP — только L2 trunk)
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Настройка parent интерфейса $LAN_IFACE (trunk)...${NC}"
echo "------------------------------------------------------------------------"

IFACE_DIR="/etc/net/ifaces/$LAN_IFACE"
mkdir -p "$IFACE_DIR"

# Parent интерфейс — без IP, работает как trunk
cat > "$IFACE_DIR/options" << EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
EOF

# Убираем IP с parent (он будет только на субинтерфейсах)
rm -f "$IFACE_DIR/ipv4address"
> "$IFACE_DIR/ipv4address" 2>/dev/null || true

# Поднять parent
ip addr flush dev "$LAN_IFACE" 2>/dev/null
ip link set "$LAN_IFACE" up

echo -e "${GREEN}Parent $LAN_IFACE поднят (trunk, без IP)${NC}"

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
# КОНФИГУРАЦИЯ DHCP (по VLAN)
# ============================================================
echo ""
echo -e "${WHITE}[AUTO] Создание конфигурации DHCP (по VLAN)...${NC}"
echo "------------------------------------------------------------------------"

cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP Configuration for Demo2026 Exam
# VLAN EDITION - DHCP раздаётся по VLAN
# Parent интерфейс: $LAN_IFACE
# VLAN: $VLAN_INPUT

default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;
$DHCP_CONF_SUBNETS
EOF

echo -e "${GREEN}/etc/dhcp/dhcpd.conf создан (с subnet для каждого VLAN)${NC}"

# Интерфейсы — слушаем все VLAN субинтерфейсы
cat > /etc/sysconfig/dhcpd << EOF
DHCPDARGS="$DHCP_IFACE_LIST"
EOF

echo -e "${GREEN}/etc/sysconfig/dhcpd: DHCPDARGS=\"$DHCP_IFACE_LIST\"${NC}"

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
# NAT для каждого VLAN (если есть WAN)
# ============================================================
if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$LAN_IFACE" ]; then
    echo ""
    echo -e "${WHITE}[AUTO] Настройка NAT для каждого VLAN ($WAN_IFACE)...${NC}"
    echo "------------------------------------------------------------------------"

    for vid in $(echo "${!SELECTED_VLANS[@]}" | tr ' ' '\n' | sort -n); do
        PARAMS=$(get_vlan_params "$vid")
        V_NETWORK=$(echo "$PARAMS" | awk '{print $2}')
        V_CIDR=$(echo "$PARAMS" | awk '{print $4}')
        VIF="${LAN_IFACE}.${vid}"

        # Очищаем старые правила
        iptables -t nat -D POSTROUTING -s "$V_NETWORK/$V_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null

        # Добавляем новое правило
        iptables -t nat -A POSTROUTING -s "$V_NETWORK/$V_CIDR" -o "$WAN_IFACE" -j MASQUERADE

        # Forward
        iptables -D FORWARD -i "$VIF" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
        iptables -A FORWARD -i "$VIF" -o "$WAN_IFACE" -j ACCEPT
        iptables -D FORWARD -i "$WAN_IFACE" -o "$VIF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -A FORWARD -i "$WAN_IFACE" -o "$VIF" -m state --state ESTABLISHED,RELATED -j ACCEPT

        echo -e "  ${GREEN}NAT: $VIF ($V_NETWORK/$V_CIDR) -> $WAN_IFACE${NC}"
    done

    # Сохраняем
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
echo -e "${WHITE}                      РЕЗУЛЬТАТ (VLAN EDITION)${NC}"
echo -e "${CYAN}========================================================================${NC}"

echo ""
echo -e "${WHITE}VLAN интерфейсы:${NC}"
for vid in $(echo "${!SELECTED_VLANS[@]}" | tr ' ' '\n' | sort -n); do
    ip -brief addr show "${LAN_IFACE}.${vid}" 2>/dev/null
done

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
echo -e "${WHITE}Конфигурация VLAN:${NC}"
echo "  Parent интерфейс: $LAN_IFACE (trunk, без IP)"
for vid in $(echo "${!SELECTED_VLANS[@]}" | tr ' ' '\n' | sort -n); do
    PARAMS=$(get_vlan_params "$vid")
    V_NET_NAME=$(echo "$PARAMS" | awk '{print $1}')
    V_NETWORK=$(echo "$PARAMS" | awk '{print $2}')
    V_CIDR=$(echo "$PARAMS" | awk '{print $4}')
    V_GATEWAY=$(echo "$PARAMS" | awk '{print $5}')
    V_RANGE_START=$(echo "$PARAMS" | awk '{print $6}')
    V_RANGE_END=$(echo "$PARAMS" | awk '{print $7}')
    echo "  VLAN $vid  ${LAN_IFACE}.${vid}  ->  ${V_NET_NAME} ($V_NETWORK/$V_CIDR)"
    echo "    IP: $V_GATEWAY  |  DHCP: $V_RANGE_START - $V_RANGE_END"
done

echo "  Домен: au-team.irpo"
[ -n "$WAN_IFACE" ] && echo "  NAT: все VLAN -> $WAN_IFACE"

echo ""
echo -e "${YELLOW}ВНИМАНИЕ: VLAN не удаляются. При повторном запуске существующие VLAN будут пропущены.${NC}"

echo ""
echo -e "${CYAN}========================================================================${NC}"
echo -e "${WHITE}                         ГОТОВО!${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo ""
echo "На HQ-SRV для получения IP по DHCP (пример для VLAN 10):"
echo ""
echo "  # Установите пакет vlan если нужно:"
echo "  apt-get install -y vlan"
echo ""
echo "  # Создайте VLAN интерфейс:"
echo "  ip link add link ens33 name ens33.10 type vlan id 10"
echo "  ip link set ens33.10 up"
echo ""
echo "  # Получите IP по DHCP:"
echo "  mkdir -p /etc/net/ifaces/ens33.10"
echo "  echo 'BOOTPROTO=dhcp' > /etc/net/ifaces/ens33.10/options"
echo "  echo 'TYPE=eth' >> /etc/net/ifaces/ens33.10/options"
echo "  echo 'ONBOOT=yes' >> /etc/net/ifaces/ens33.10/options"
echo "  systemctl restart network"
echo ""
