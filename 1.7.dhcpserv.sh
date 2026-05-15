#!/bin/bash
#===============================================================================
# DHCP SERVER SETUP - Версия 2.0
# Полностью автоматическое определение VLAN и сетей
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

LOG_FILE="/var/log/dhcp-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; }
sep() { log "${CYAN}================================================${NC}"; }

#===============================================================================
# ПРОВЕРКА ROOT
#===============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

#===============================================================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#===============================================================================

WAN_IFACE=""
LAN_IFACE=""
VLAN_PARENT=""
declare -a VLAN_LIST
declare -a NETWORKS

# Временные файлы
IFACE_DATA="/tmp/dhcp_ifaces_$$"
VLAN_DATA="/tmp/dhcp_vlans_$$"
NETWORK_DATA="/tmp/dhcp_networks_$$"
> "$IFACE_DATA"
> "$VLAN_DATA"
> "$NETWORK_DATA"

#===============================================================================
# ФУНКЦИЯ АВТООПРЕДЕЛЕНИЯ ВСЕХ ПАРАМЕТРОВ
#===============================================================================

auto_detect_all() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}        ${WHITE}АВТООПРЕДЕЛЕНИЕ ПАРАМЕТРОВ${NC}                   ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    #===========================================================================
    # 1. Сканирование всех интерфейсов
    #===========================================================================
    sep
    log "${WHITE}=== 1. Сканирование интерфейсов ===${NC}"
    sep
    log ""
    
    printf "  %-16s %-10s %-22s %-12s\n" "Интерфейс" "Статус" "IP-адрес" "Тип"
    echo "  -------------------------------------------------------------------"
    
    DEF_ROUTE_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')
    
    for iface in $(ls /sys/class/net/ 2>/dev/null | sort); do
        # Пропускаем системные
        case "$iface" in
            lo|docker*|veth*|virbr*|br-*|flannel*|cni*|tun*|sit*) continue ;;
        esac
        
        # Определяем тип
        iface_type="VIRTUAL"
        if [[ "$iface" == *"."* ]]; then
            iface_type="VLAN"
        elif [[ "$iface" == "gre"* ]]; then
            iface_type="GRE"
        elif [ -d "/sys/class/net/${iface}/device" ]; then
            iface_type="PHYSICAL"
        fi
        
        # Получаем статус и IP
        iface_status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        iface_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        
        # Цветной вывод
        case "$iface_status" in
            up) status_out="${GREEN}UP${NC}" ;;
            *) status_out="${YELLOW}$iface_status${NC}" ;;
        esac
        
        case "$iface_type" in
            PHYSICAL) type_out="${GREEN}PHYSICAL${NC}" ;;
            VLAN) type_out="${CYAN}VLAN${NC}" ;;
            GRE) type_out="${MAGENTA}GRE${NC}" ;;
            *) type_out="${YELLOW}VIRTUAL${NC}" ;;
        esac
        
        [ -z "$iface_ip" ] && iface_ip="---"
        
        printf "  %-16s " "$iface"
        echo -e "$status_out\t$iface_ip\t$type_out"
        
        # Сохраняем данные
        echo "$iface|$iface_type|$iface_ip|$iface_status" >> "$IFACE_DATA"
    done
    
    log ""
    
    #===========================================================================
    # 2. Определение WAN интерфейса
    #===========================================================================
    sep
    log "${WHITE}=== 2. Определение WAN ===${NC}"
    sep
    log ""
    
    # WAN = интерфейс с default route
    if [ -n "$DEF_ROUTE_IFACE" ]; then
        WAN_IFACE="$DEF_ROUTE_IFACE"
        WAN_IP=$(ip -4 addr show dev "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}')
        ok "WAN определён: ${WHITE}$WAN_IFACE${NC} (${WAN_IP:-нет IP})"
    else
        # Ищем интерфейс с публичным IP или первый с IP
        while IFS='|' read -r iface type ip status; do
            if [ "$type" = "PHYSICAL" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
                # Проверяем, не является ли IP частным (LAN)
                if ! echo "$ip" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
                    WAN_IFACE="$iface"
                    WAN_IP="$ip"
                    ok "WAN по публичному IP: ${WHITE}$WAN_IFACE${NC}"
                    break
                fi
            fi
        done < "$IFACE_DATA"
        
        # Если не нашли - берём любой физический с IP
        if [ -z "$WAN_IFACE" ]; then
            while IFS='|' read -r iface type ip status; do
                if [ "$type" = "PHYSICAL" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
                    WAN_IFACE="$iface"
                    WAN_IP="$ip"
                    warn "WAN выбран: ${WHITE}$WAN_IFACE${NC}"
                    break
                fi
            done < "$IFACE_DATA"
        fi
    fi
    
    #===========================================================================
    # 3. Определение LAN интерфейсов
    #===========================================================================
    sep
    log "${WHITE}=== 3. Определение LAN ===${NC}"
    sep
    log ""
    
    # LAN = физические интерфейсы без default route
    LAN_IFACES=""
    while IFS='|' read -r iface type ip status; do
        if [ "$type" = "PHYSICAL" ] && [ "$iface" != "$WAN_IFACE" ]; then
            if [ -n "$LAN_IFACES" ]; then
                LAN_IFACES="$LAN_IFACES $iface"
            else
                LAN_IFACES="$iface"
            fi
            log "  ${GREEN}•${NC} LAN: $iface (${ip:-нет IP})"
        fi
    done < "$IFACE_DATA"
    
    # Определяем parent для VLAN
    if [ -n "$LAN_IFACES" ]; then
        # Ищем интерфейс с VLAN субинтерфейсами
        for lan in $LAN_IFACES; do
            VLAN_COUNT=$(grep -c "^${lan}\." "$IFACE_DATA" 2>/dev/null || echo "0")
            if [ "$VLAN_COUNT" -gt 0 ]; then
                VLAN_PARENT="$lan"
                ok "Parent для VLAN: ${WHITE}$VLAN_PARENT${NC}"
                break
            fi
        done
        
        # Если не нашли по VLAN, берём первый LAN
        if [ -z "$VLAN_PARENT" ]; then
            VLAN_PARENT=$(echo "$LAN_IFACES" | awk '{print $1}')
            ok "Parent выбран: ${WHITE}$VLAN_PARENT${NC}"
        fi
        
        LAN_IFACE="$VLAN_PARENT"
    fi
    
    #===========================================================================
    # 4. Определение VLAN интерфейсов и их сетей
    #===========================================================================
    sep
    log "${WHITE}=== 4. Определение VLAN и сетей ===${NC}"
    sep
    log ""
    
    # Функция конвертации IP/mask в параметры сети
    get_network_params() {
        local ip_mask="$1"
        local ip=$(echo "$ip_mask" | cut -d'/' -f1)
        local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
        
        if [ -z "$ip" ] || [ -z "$cidr" ]; then
            return
        fi
        
        # Вычисляем маску
        local mask=""
        case "$cidr" in
            29) mask="255.255.255.248" ;;
            28) mask="255.255.255.240" ;;
            27) mask="255.255.255.224" ;;
            26) mask="255.255.255.192" ;;
            25) mask="255.255.255.128" ;;
            24) mask="255.255.255.0" ;;
            *) mask="255.255.255.0" ;;
        esac
        
        # Вычисляем сеть
        local o1=$(echo "$ip" | cut -d'.' -f1)
        local o2=$(echo "$ip" | cut -d'.' -f2)
        local o3=$(echo "$ip" | cut -d'.' -f3)
        local o4=$(echo "$ip" | cut -d'.' -f4)
        local network="${o1}.${o2}.${o3}.0"
        
        # Вычисляем broadcast
        local bcast=""
        case "$cidr" in
            29) bcast="${o1}.${o2}.${o3}.7" ;;
            28) bcast="${o1}.${o2}.${o3}.15" ;;
            27) bcast="${o1}.${o2}.${o3}.31" ;;
            26) bcast="${o1}.${o2}.${o3}.63" ;;
            25) bcast="${o1}.${o2}.${o3}.127" ;;
            24) bcast="${o1}.${o2}.${o3}.255" ;;
            *) bcast="${o1}.${o2}.${o3}.255" ;;
        esac
        
        # Диапазон DHCP (исключаем gateway и последние адреса)
        local range_start=""
        local range_end=""
        case "$cidr" in
            29)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.$((o4 + 4))"
                ;;
            28)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.14"
                ;;
            27)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.30"
                ;;
            26)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.62"
                ;;
            25)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.126"
                ;;
            24)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
                ;;
            *)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
                ;;
        esac
        
        echo "$network|$mask|$cidr|$ip|$range_start|$range_end|$bcast"
    }
    
    # Обрабатываем VLAN интерфейсы
    VLAN_FOUND=0
    while IFS='|' read -r iface type ip status; do
        if [ "$type" = "VLAN" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
            # Проверяем что VLAN принадлежит нашему LAN интерфейсу
            parent=$(echo "$iface" | cut -d'.' -f1)
            vid=$(echo "$iface" | cut -d'.' -f2)
            
            if [ "$parent" = "$VLAN_PARENT" ]; then
                VLAN_FOUND=$((VLAN_FOUND + 1))
                
                params=$(get_network_params "$ip")
                if [ -n "$params" ]; then
                    network=$(echo "$params" | cut -d'|' -f1)
                    mask=$(echo "$params" | cut -d'|' -f2)
                    cidr=$(echo "$params" | cut -d'|' -f3)
                    gateway=$(echo "$params" | cut -d'|' -f4)
                    range_start=$(echo "$params" | cut -d'|' -f5)
                    range_end=$(echo "$params" | cut -d'|' -f6)
                    bcast=$(echo "$params" | cut -d'|' -f7)
                    
                    echo "$iface|$vid|$network|$mask|$cidr|$gateway|$range_start|$range_end|$bcast" >> "$VLAN_DATA"
                    echo "$network/$cidr" >> "$NETWORK_DATA"
                    
                    log "  ${CYAN}VLAN $vid${NC}: $iface"
                    log "    Сеть: $network/$cidr"
                    log "    Шлюз: $gateway"
                    log "    DHCP: $range_start - $range_end"
                fi
            fi
        fi
    done < "$IFACE_DATA"
    
    #===========================================================================
    # 5. Определение Native сети (на parent интерфейсе)
    #===========================================================================
    sep
    log "${WHITE}=== 5. Определение Native сети ===${NC}"
    sep
    log ""
    
    PARENT_IP=$(ip -4 addr show dev "$VLAN_PARENT" 2>/dev/null | awk '/inet /{print $2}')
    
    if [ -n "$PARENT_IP" ]; then
        params=$(get_network_params "$PARENT_IP")
        if [ -n "$params" ]; then
            NATIVE_NETWORK=$(echo "$params" | cut -d'|' -f1)
            NATIVE_MASK=$(echo "$params" | cut -d'|' -f2)
            NATIVE_CIDR=$(echo "$params" | cut -d'|' -f3)
            NATIVE_GW=$(echo "$params" | cut -d'|' -f4)
            NATIVE_RANGE_START=$(echo "$params" | cut -d'|' -f5)
            NATIVE_RANGE_END=$(echo "$params" | cut -d'|' -f6)
            NATIVE_BCAST=$(echo "$params" | cut -d'|' -f7)
            
            ok "Native сеть на $VLAN_PARENT:"
            log "  Сеть: $NATIVE_NETWORK/$NATIVE_CIDR"
            log "  Шлюз: $NATIVE_GW"
            log "  DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
            
            NATIVE_EXISTS=1
        else
            warn "Не удалось определить параметры native сети"
            NATIVE_EXISTS=0
        fi
    else
        warn "IP на $VLAN_PARENT не найден"
        NATIVE_EXISTS=0
    fi
    
    #===========================================================================
    # 6. Итоговая сводка
    #===========================================================================
    sep
    log "${WHITE}=== ИТОГО АВТООПРЕДЕЛЕНО ===${NC}"
    sep
    log ""
    
    log "${CYAN}WAN:${NC} ${WHITE}${WAN_IFACE:-не определён}${NC}"
    log "${CYAN}LAN Parent:${NC} ${WHITE}${VLAN_PARENT:-не определён}${NC}"
    log ""
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        log "${MAGENTA}Native (untagged):${NC}"
        log "  $VLAN_PARENT -> $NATIVE_NETWORK/$NATIVE_CIDR"
        log "  DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
        log ""
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        log "${CYAN}Tagged VLAN:${NC}"
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast; do
            log "  $iface (VLAN $vid) -> $network/$cidr"
        done < "$VLAN_DATA"
        log ""
    fi
    
    if [ ! -s "$VLAN_DATA" ] && [ "$NATIVE_EXISTS" != "1" ]; then
        err "Не определено ни одной сети для DHCP!"
        return 1
    fi
    
    return 0
}

#===============================================================================
# ФУНКЦИЯ НАСТРОЙКИ DHCP СЕРВЕРА
#===============================================================================

setup_dhcp() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}НАСТРОЙКА DHCP СЕРВЕРА${NC}                       ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    # Автоопределение
    auto_detect_all
    if [ $? -ne 0 ]; then
        err "Автоопределение не удалось"
        return 1
    fi
    
    # Подтверждение
    log ""
    read -p "Продолжить настройку DHCP? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        warn "Отменено"
        return
    fi
    
    #===========================================================================
    # Установка DHCP
    #===========================================================================
    sep
    log "${WHITE}=== Установка DHCP сервера ===${NC}"
    sep
    log ""
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq dhcp-server 2>/dev/null || apt-get install -y dhcp-server 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q dhcp-server 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q dhcp-server 2>/dev/null
    else
        err "Пакетный менеджер не найден"
        return 1
    fi
    
    ok "DHCP сервер установлен"
    
    #===========================================================================
    # Создание конфигурации DHCP
    #===========================================================================
    sep
    log "${WHITE}=== Создание конфигурации DHCP ===${NC}"
    sep
    log ""
    
    DHCP_CONF="/etc/dhcp/dhcpd.conf"
    DHCP_ARGS="$VLAN_PARENT"
    
    # Начинаем конфиг
    cat > "$DHCP_CONF" << 'DHCPHEAD'
# DHCP Configuration - Auto-generated
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;
DHCPHEAD
    
    # Добавляем native subnet
    if [ "$NATIVE_EXISTS" = "1" ]; then
        cat >> "$DHCP_CONF" << NATIVE_SUBNET

# Native (untagged) on $VLAN_PARENT
subnet $NATIVE_NETWORK netmask $NATIVE_MASK {
    range $NATIVE_RANGE_START $NATIVE_RANGE_END;
    option routers $NATIVE_GW;
    option subnet-mask $NATIVE_MASK;
    option broadcast-address $NATIVE_BCAST;
    option domain-name "au-team.irpo";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
}
NATIVE_SUBNET
        
        ok "Native subnet: $NATIVE_NETWORK/$NATIVE_CIDR"
    fi
    
    # Добавляем VLAN subnets
    while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast; do
        cat >> "$DHCP_CONF" << VLAN_SUBNET

# VLAN $vid on $iface
subnet $network netmask $mask {
    range $range_start $range_end;
    option routers $gw;
    option subnet-mask $mask;
    option broadcast-address $bcast;
    option domain-name "au-team.irpo";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
}
VLAN_SUBNET
        
        ok "VLAN $vid subnet: $network/$cidr"
        DHCP_ARGS="$DHCP_ARGS $iface"
    done < "$VLAN_DATA"
    
    # Настройка интерфейсов для прослушивания
    if [ -f "/etc/sysconfig/dhcpd" ]; then
        echo "DHCPDARGS=\"$DHCP_ARGS\"" > /etc/sysconfig/dhcpd
    elif [ -f "/etc/default/isc-dhcp-server" ]; then
        echo "INTERFACESv4=\"$DHCP_ARGS\"" > /etc/default/isc-dhcp-server
    fi
    
    ok "Интерфейсы DHCP: $DHCP_ARGS"
    
    # Создаём leases файл
    LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
    LEASE_DIR=$(dirname "$LEASE_FILE")
    [ ! -d "$LEASE_DIR" ] && mkdir -p "$LEASE_DIR"
    [ ! -f "$LEASE_FILE" ] && touch "$LEASE_FILE"
    
    # Проверка конфигурации
    log ""
    log "${YELLOW}Проверка конфигурации...${NC}"
    if dhcpd -t -cf "$DHCP_CONF" 2>&1 | grep -q "exiting"; then
        err "Ошибка в конфигурации DHCP!"
        dhcpd -t -cf "$DHCP_CONF" 2>&1
        return 1
    else
        ok "Конфигурация валидна"
    fi
    
    #===========================================================================
    # IP Forwarding
    #===========================================================================
    sep
    log "${WHITE}=== IP Forwarding ===${NC}"
    sep
    
    SYSCTL_FILE="/etc/sysctl.conf"
    [ -f "/etc/net/sysctl.conf" ] && SYSCTL_FILE="/etc/net/sysctl.conf"
    
    if ! grep -q "net.ipv4.ip_forward" "$SYSCTL_FILE"; then
        echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
    else
        sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
    fi
    sysctl -p > /dev/null 2>&1
    
    ok "IP forwarding включён"
    
    #===========================================================================
    # NAT (если есть WAN)
    #===========================================================================
    if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$VLAN_PARENT" ]; then
        sep
        log "${WHITE}=== Настройка NAT ===${NC}"
        sep
        log ""
        
        # NAT для native
        if [ "$NATIVE_EXISTS" = "1" ]; then
            iptables -t nat -A POSTROUTING -s "$NATIVE_NETWORK/$NATIVE_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$VLAN_PARENT" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$VLAN_PARENT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $NATIVE_NETWORK/$NATIVE_CIDR -> $WAN_IFACE"
        fi
        
        # NAT для VLAN
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast; do
            iptables -t nat -A POSTROUTING -s "$network/$cidr" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$iface" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $network/$cidr -> $WAN_IFACE"
        done < "$VLAN_DATA"
        
        # Сохраняем правила
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi
    
    #===========================================================================
    # Запуск DHCP
    #===========================================================================
    sep
    log "${WHITE}=== Запуск DHCP сервера ===${NC}"
    sep
    log ""
    
    systemctl enable dhcpd 2>/dev/null || systemctl enable isc-dhcp-server 2>/dev/null
    systemctl restart dhcpd 2>/dev/null || systemctl restart isc-dhcp-server 2>/dev/null
    
    sleep 2
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP сервер запущен"
    else
        err "Ошибка запуска DHCP"
        journalctl -u dhcpd -n 10 --no-pager 2>/dev/null || \
        journalctl -u isc-dhcp-server -n 10 --no-pager 2>/dev/null
    fi
    
    #===========================================================================
    # Итог
    #===========================================================================
    log ""
    log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${GREEN}║${NC}            ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                        ${GREEN}║${NC}"
    log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    log "${CYAN}Параметры:${NC}"
    log "  WAN: ${WHITE}${WAN_IFACE}${NC}"
    log "  LAN: ${WHITE}${VLAN_PARENT}${NC}"
    log ""
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        log "${MAGENTA}Native (untagged):${NC}"
        log "  $VLAN_PARENT -> $NATIVE_NETWORK/$NATIVE_CIDR"
        log "  DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
        log ""
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        log "${CYAN}Tagged VLAN:${NC}"
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast; do
            log "  $iface (VLAN $vid) -> $network/$cidr"
            log "    DHCP: $range_start - $range_end"
        done < "$VLAN_DATA"
        log ""
    fi
    
    log "${CYAN}Команды проверки:${NC}"
    log "  ${YELLOW}systemctl status dhcpd${NC}"
    log "  ${YELLOW}cat /var/lib/dhcp/dhcpd.leases${NC}"
    log ""
}

#===============================================================================
# ФУНКЦИЯ ПРОВЕРКИ DHCP
#===============================================================================

check_dhcp() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}ПРОВЕРКА DHCP СЕРВЕРА${NC}                        ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    # Статус сервиса
    sep
    log "${WHITE}=== Статус сервиса ===${NC}"
    sep
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP сервер: ${GREEN}АКТИВЕН${NC}"
    else
        err "DHCP сервер: ${RED}НЕ АКТИВЕН${NC}"
    fi
    
    # Прослушиваемые интерфейсы
    sep
    log "${WHITE}=== Прослушиваемые порты ===${NC}"
    sep
    
    ss -ulnp | grep ":67" 2>/dev/null || warn "Нет прослушивания на порту 67"
    
    # Leases
    sep
    log "${WHITE}=== Арендованные адреса ===${NC}"
    sep
    
    LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
    if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
        LEASE_COUNT=$(grep -c "lease" "$LEASE_FILE" 2>/dev/null || echo "0")
        ok "Leases: $LEASE_COUNT записей"
        tail -20 "$LEASE_FILE"
    else
        warn "Нет арендованных адресов"
    fi
    
    log ""
}

#===============================================================================
# ФУНКЦИЯ ОЧИСТКИ
#===============================================================================

clean_dhcp() {
    log ""
    log "${YELLOW}Очистка настроек DHCP...${NC}"
    
    systemctl stop dhcpd 2>/dev/null
    systemctl stop isc-dhcp-server 2>/dev/null
    
    rm -f /etc/dhcp/dhcpd.conf 2>/dev/null
    rm -f /var/lib/dhcp/dhcpd.leases 2>/dev/null
    touch /var/lib/dhcp/dhcpd.leases 2>/dev/null
    
    ok "Настройки DHCP очищены"
    log ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

show_menu() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}              ${WHITE}МЕНЮ DHCP SERVER v2.0${NC}                       ${CYAN}║${NC}"
    log "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    log "${CYAN}║${NC}  ${GREEN}1.${NC} Автоопределение параметров                         ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}2.${NC} Настроить DHCP сервер                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}3.${NC} Проверить DHCP сервер                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}4.${NC} Очистить настройки DHCP                            ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${RED}0.${NC} Выход                                               ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
}

# Основной цикл
while true; do
    show_menu
    read -p "Выберите пункт: " choice
    
    case "$choice" in
        1)
            auto_detect_all
            ;;
        2)
            setup_dhcp
            ;;
        3)
            check_dhcp
            ;;
        4)
            clean_dhcp
            ;;
        0)
            ok "Выход"
            rm -f "$IFACE_DATA" "$VLAN_DATA" "$NETWORK_DATA" 2>/dev/null
            exit 0
            ;;
        *)
            err "Неверный выбор: $choice"
            ;;
    esac
    
    log ""
    read -p "Нажмите Enter для продолжения..."
done
