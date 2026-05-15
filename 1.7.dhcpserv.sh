#!/bin/bash
#===============================================================================
# DHCP SERVER SETUP - Версия 3.0
# Полностью автоматическое определение VLAN и сетей
# Добавлено: резервирование IP для клиентов по MAC-адресу
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
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
NATIVE_EXISTS=0
NATIVE_NETWORK=""
NATIVE_MASK=""
NATIVE_CIDR=""
NATIVE_GW=""
NATIVE_RANGE_START=""
NATIVE_RANGE_END=""
NATIVE_BCAST=""

# Временные файлы
IFACE_DATA="/tmp/dhcp_ifaces_$$"
VLAN_DATA="/tmp/dhcp_vlans_$$"
NETWORK_DATA="/tmp/dhcp_networks_$$"
HOSTS_DATA="/tmp/dhcp_hosts_$$"
> "$IFACE_DATA"
> "$VLAN_DATA"
> "$NETWORK_DATA"
> "$HOSTS_DATA"

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
    
    if [ -n "$DEF_ROUTE_IFACE" ]; then
        WAN_IFACE="$DEF_ROUTE_IFACE"
        WAN_IP=$(ip -4 addr show dev "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}')
        ok "WAN определён: ${WHITE}$WAN_IFACE${NC} (${WAN_IP:-нет IP})"
    else
        while IFS='|' read -r iface type ip status; do
            if [ "$type" = "PHYSICAL" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
                if ! echo "$ip" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
                    WAN_IFACE="$iface"
                    WAN_IP="$ip"
                    ok "WAN по публичному IP: ${WHITE}$WAN_IFACE${NC}"
                    break
                fi
            fi
        done < "$IFACE_DATA"
        
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
    
    if [ -n "$LAN_IFACES" ]; then
        for lan in $LAN_IFACES; do
            VLAN_COUNT=$(grep -c "^${lan}\." "$IFACE_DATA" 2>/dev/null || echo "0")
            if [ "$VLAN_COUNT" -gt 0 ]; then
                VLAN_PARENT="$lan"
                ok "Parent для VLAN: ${WHITE}$VLAN_PARENT${NC}"
                break
            fi
        done
        
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
    
    get_network_params() {
        local ip_mask="$1"
        local ip=$(echo "$ip_mask" | cut -d'/' -f1)
        local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
        
        if [ -z "$ip" ] || [ -z "$cidr" ]; then
            return
        fi
        
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
        
        local o1=$(echo "$ip" | cut -d'.' -f1)
        local o2=$(echo "$ip" | cut -d'.' -f2)
        local o3=$(echo "$ip" | cut -d'.' -f3)
        local o4=$(echo "$ip" | cut -d'.' -f4)
        local network="${o1}.${o2}.${o3}.0"
        
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
        
        local range_start=""
        local range_end=""
        local last_host=""
        case "$cidr" in
            29)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.$((o4 + 4))"
                last_host="${o1}.${o2}.${o3}.6"
                ;;
            28)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.14"
                last_host="${o1}.${o2}.${o3}.14"
                ;;
            27)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.30"
                last_host="${o1}.${o2}.${o3}.30"
                ;;
            26)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.62"
                last_host="${o1}.${o2}.${o3}.62"
                ;;
            25)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.126"
                last_host="${o1}.${o2}.${o3}.126"
                ;;
            24)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
                last_host="${o1}.${o2}.${o3}.254"
                ;;
            *)
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
                last_host="${o1}.${o2}.${o3}.254"
                ;;
        esac
        
        echo "$network|$mask|$cidr|$ip|$range_start|$range_end|$bcast|$last_host"
    }
    
    VLAN_FOUND=0
    while IFS='|' read -r iface type ip status; do
        if [ "$type" = "VLAN" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
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
                    last_host=$(echo "$params" | cut -d'|' -f8)
                    
                    echo "$iface|$vid|$network|$mask|$cidr|$gateway|$range_start|$range_end|$bcast|$last_host" >> "$VLAN_DATA"
                    echo "$network/$cidr|$iface|$vid" >> "$NETWORK_DATA"
                    
                    log "  ${CYAN}VLAN $vid${NC}: $iface"
                    log "    Сеть: $network/$cidr"
                    log "    Шлюз: $gateway"
                    log "    DHCP: $range_start - $range_end"
                fi
            fi
        fi
    done < "$IFACE_DATA"
    
    #===========================================================================
    # 5. Определение Native сети
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
            NATIVE_LAST_HOST=$(echo "$params" | cut -d'|' -f8)
            
            ok "Native сеть на $VLAN_PARENT:"
            log "  Сеть: $NATIVE_NETWORK/$NATIVE_CIDR"
            log "  Шлюз: $NATIVE_GW"
            log "  DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
            
            NATIVE_EXISTS=1
            echo "$NATIVE_NETWORK/$NATIVE_CIDR|$VLAN_PARENT|native" >> "$NETWORK_DATA"
        else
            NATIVE_EXISTS=0
        fi
    else
        NATIVE_EXISTS=0
    fi
    
    #===========================================================================
    # 6. Итог
    #===========================================================================
    sep
    log "${WHITE}=== ИТОГО ===${NC}"
    sep
    log ""
    
    log "${CYAN}WAN:${NC} ${WHITE}${WAN_IFACE:-не определён}${NC}"
    log "${CYAN}LAN Parent:${NC} ${WHITE}${VLAN_PARENT:-не определён}${NC}"
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        log "${MAGENTA}Native:${NC} $VLAN_PARENT -> $NATIVE_NETWORK/$NATIVE_CIDR"
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            log "${CYAN}VLAN $vid:${NC} $iface -> $network/$cidr"
        done < "$VLAN_DATA"
    fi
    
    log ""
    return 0
}

#===============================================================================
# ФУНКЦИЯ ПОКАЗАТЬ ДОСТУПНЫЕ СЕТИ
#===============================================================================

show_available_networks() {
    log ""
    log "${CYAN}=== Доступные сети для DHCP ===${NC}"
    log ""
    
    idx=0
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        idx=$((idx + 1))
        log "  ${GREEN}$idx)${NC} ${MAGENTA}Native${NC} ($VLAN_PARENT) -> $NATIVE_NETWORK/$NATIVE_CIDR"
        log "      Шлюз: $NATIVE_GW | DHCP: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            idx=$((idx + 1))
            log "  ${GREEN}$idx)${NC} ${CYAN}VLAN $vid${NC} ($iface) -> $network/$cidr"
            log "      Шлюз: $gw | DHCP: $range_start - $range_end"
        done < "$VLAN_DATA"
    fi
    
    echo "$idx" > /tmp/dhcp_net_count_$$
    log ""
}

#===============================================================================
# ФУНКЦИЯ ДОБАВЛЕНИЯ СТАТИЧЕСКОГО IP КЛИЕНТУ
#===============================================================================

add_static_host() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}        ${WHITE}РЕЗЕРВИРОВАНИЕ IP ДЛЯ КЛИЕНТА${NC}                 ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    # Показываем доступные сети
    show_available_networks
    
    NET_COUNT=$(cat /tmp/dhcp_net_count_$$ 2>/dev/null || echo "0")
    
    if [ "$NET_COUNT" -eq 0 ]; then
        err "Нет доступных сетей! Сначала выполните автоопределение."
        return 1
    fi
    
    # Выбор сети
    log "${YELLOW}Выберите сеть для клиента:${NC}"
    read -p "Номер сети: " net_num
    net_num=${net_num:-1}
    
    if [ "$net_num" -lt 1 ] || [ "$net_num" -gt "$NET_COUNT" ]; then
        err "Неверный номер сети"
        return 1
    fi
    
    # Определяем выбранную сеть
    SELECTED_NETWORK=""
    SELECTED_GW=""
    SELECTED_MASK=""
    SELECTED_IFACE=""
    SELECTED_VLAN=""
    SELECTED_LAST_HOST=""
    
    current=0
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        current=$((current + 1))
        if [ "$current" -eq "$net_num" ]; then
            SELECTED_NETWORK="$NATIVE_NETWORK"
            SELECTED_GW="$NATIVE_GW"
            SELECTED_MASK="$NATIVE_MASK"
            SELECTED_IFACE="$VLAN_PARENT"
            SELECTED_VLAN="native"
            SELECTED_LAST_HOST="$NATIVE_LAST_HOST"
        fi
    fi
    
    if [ -z "$SELECTED_NETWORK" ] && [ -s "$VLAN_DATA" ]; then
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            current=$((current + 1))
            if [ "$current" -eq "$net_num" ]; then
                SELECTED_NETWORK="$network"
                SELECTED_GW="$gw"
                SELECTED_MASK="$mask"
                SELECTED_IFACE="$iface"
                SELECTED_VLAN="$vid"
                SELECTED_LAST_HOST="$last_host"
                break
            fi
        done < "$VLAN_DATA"
    fi
    
    ok "Выбрана сеть: ${WHITE}$SELECTED_NETWORK${NC} (${SELECTED_IFACE})"
    log ""
    
    # Ввод имени клиента
    log "${YELLOW}Введите имя клиента (без пробелов):${NC}"
    read -p "Имя: " host_name
    
    if [ -z "$host_name" ]; then
        err "Имя не указано"
        return 1
    fi
    
    # Ввод MAC-адреса
    log ""
    log "${YELLOW}Введите MAC-адрес клиента:${NC}"
    log "  Формат: XX:XX:XX:XX:XX:XX (например: 00:11:22:33:44:55)"
    read -p "MAC: " host_mac
    
    if [ -z "$host_mac" ]; then
        err "MAC-адрес не указан"
        return 1
    fi
    
    # Проверка формата MAC
    if ! echo "$host_mac" | grep -qE "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"; then
        err "Неверный формат MAC-адреса"
        return 1
    fi
    
    # Ввод IP-адреса
    log ""
    log "${YELLOW}Введите IP-адрес для клиента:${NC}"
    log "  Сеть: $SELECTED_NETWORK/$SELECTED_MASK"
    log "  Шлюз: $SELECTED_GW"
    log "  Доступные адреса (примерно): $SELECTED_GW + 1 до $SELECTED_LAST_HOST"
    read -p "IP-адрес: " host_ip
    
    if [ -z "$host_ip" ]; then
        err "IP-адрес не указан"
        return 1
    fi
    
    # Проверка на дубликат MAC
    if [ -f "$HOSTS_DATA" ] && grep -qi "$host_mac" "$HOSTS_DATA" 2>/dev/null; then
        warn "MAC $host_mac уже есть в списке!"
        read -p "Перезаписать? (y/n): " overwrite
        if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
            log "Отменено"
            return
        fi
        grep -vi "$host_mac" "$HOSTS_DATA" > "${HOSTS_DATA}.tmp"
        mv "${HOSTS_DATA}.tmp" "$HOSTS_DATA"
    fi
    
    # Сохраняем данные
    echo "$host_name|$host_mac|$host_ip|$SELECTED_IFACE|$SELECTED_VLAN|$SELECTED_NETWORK" >> "$HOSTS_DATA"
    
    ok "Клиент добавлен:"
    log "  Имя: ${WHITE}$host_name${NC}"
    log "  MAC: ${WHITE}$host_mac${NC}"
    log "  IP: ${WHITE}$host_ip${NC}"
    log "  Сеть: ${WHITE}$SELECTED_IFACE${NC} (VLAN ${SELECTED_VLAN:-native})"
    log ""
}

#===============================================================================
# ФУНКЦИЯ ПОКАЗАТЬ СПИСОК СТАТИЧЕСКИХ КЛИЕНТОВ
#===============================================================================

show_static_hosts() {
    log ""
    log "${CYAN}=== Зарезервированные адреса ===${NC}"
    log ""
    
    if [ ! -s "$HOSTS_DATA" ]; then
        warn "Нет зарезервированных адресов"
        return
    fi
    
    printf "  %-12s %-20s %-18s %-12s %s\n" "Имя" "MAC" "IP" "Интерфейс" "VLAN"
    echo "  ----------------------------------------------------------------------"
    
    while IFS='|' read -r name mac ip iface vlan network; do
        printf "  %-12s %-20s %-18s %-12s %s\n" "$name" "$mac" "$ip" "$iface" "${vlan:-native}"
    done < "$HOSTS_DATA"
    
    log ""
}

#===============================================================================
# ФУНКЦИЯ УДАЛЕНИЯ СТАТИЧЕСКОГО КЛИЕНТА
#===============================================================================

delete_static_host() {
    log ""
    log "${CYAN}=== Удаление клиента ===${NC}"
    log ""
    
    if [ ! -s "$HOSTS_DATA" ]; then
        warn "Нет зарезервированных адресов"
        return
    fi
    
    show_static_hosts
    
    log "${YELLOW}Введите имя клиента для удаления:${NC}"
    read -p "Имя: " del_name
    
    if [ -z "$del_name" ]; then
        err "Имя не указано"
        return
    fi
    
    if grep -qi "^${del_name}|" "$HOSTS_DATA" 2>/dev/null; then
        grep -vi "^${del_name}|" "$HOSTS_DATA" > "${HOSTS_DATA}.tmp"
        mv "${HOSTS_DATA}.tmp" "$HOSTS_DATA"
        ok "Клиент '$del_name' удалён"
    else
        err "Клиент '$del_name' не найден"
    fi
    
    log ""
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
    
    auto_detect_all
    
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
    
    cat > "$DHCP_CONF" << 'DHCPHEAD'
# DHCP Configuration - Auto-generated
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;
DHCPHEAD
    
    # Добавляем host declarations для статических клиентов
    if [ -s "$HOSTS_DATA" ]; then
        log "${CYAN}Добавление статических привязок...${NC}"
        while IFS='|' read -r name mac ip iface vlan network; do
            cat >> "$DHCP_CONF" << HOSTDECL

# Static: $name ($iface)
host $name {
    hardware ethernet $mac;
    fixed-address $ip;
}
HOSTDECL
            ok "  $name -> $ip ($mac)"
        done < "$HOSTS_DATA"
        log ""
    fi
    
    # Native subnet
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
    
    # VLAN subnets
    while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
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
    
    # Интерфейсы для прослушивания
    if [ -f "/etc/sysconfig/dhcpd" ]; then
        echo "DHCPDARGS=\"$DHCP_ARGS\"" > /etc/sysconfig/dhcpd
    elif [ -f "/etc/default/isc-dhcp-server" ]; then
        echo "INTERFACESv4=\"$DHCP_ARGS\"" > /etc/default/isc-dhcp-server
    fi
    
    ok "Интерфейсы DHCP: $DHCP_ARGS"
    
    # Leases файл
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
    # NAT
    #===========================================================================
    if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$VLAN_PARENT" ]; then
        sep
        log "${WHITE}=== Настройка NAT ===${NC}"
        sep
        log ""
        
        if [ "$NATIVE_EXISTS" = "1" ]; then
            iptables -t nat -A POSTROUTING -s "$NATIVE_NETWORK/$NATIVE_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$VLAN_PARENT" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$VLAN_PARENT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $NATIVE_NETWORK/$NATIVE_CIDR -> $WAN_IFACE"
        fi
        
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            iptables -t nat -A POSTROUTING -s "$network/$cidr" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$iface" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $network/$cidr -> $WAN_IFACE"
        done < "$VLAN_DATA"
        
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
    
    show_static_hosts
    
    log "${CYAN}Команды проверки:${NC}"
    log "  ${YELLOW}systemctl status dhcpd${NC}"
    log "  ${YELLOW}cat /var/lib/dhcp/dhcpd.leases${NC}"
    log "  ${YELLOW}cat /etc/dhcp/dhcpd.conf${NC}"
    log ""
}

#===============================================================================
# ФУНКЦИЯ ПЕРЕЗАПУСКА DHCP С ПРИМЕНЕНИЕМ ИЗМЕНЕНИЙ
#===============================================================================

restart_dhcp() {
    log ""
    log "${YELLOW}Перезапуск DHCP с применением изменений...${NC}"
    
    # Пересоздаём конфиг с текущими hosts
    if [ -s "$HOSTS_DATA" ]; then
        DHCP_CONF="/etc/dhcp/dhcpd.conf"
        
        # Бэкап
        cp "$DHCP_CONF" "${DHCP_CONF}.bak" 2>/dev/null
        
        # Удаляем старые host declarations
        sed -i '/^# Static:/,/^}$/d' "$DHCP_CONF" 2>/dev/null
        sed -i '/^host /,/^}$/d' "$DHCP_CONF" 2>/dev/null
        
        # Добавляем актуальные
        while IFS='|' read -r name mac ip iface vlan network; do
            cat >> "$DHCP_CONF" << HOSTDECL

# Static: $name ($iface)
host $name {
    hardware ethernet $mac;
    fixed-address $ip;
}
HOSTDECL
        done < "$HOSTS_DATA"
        
        ok "Конфигурация обновлена"
    fi
    
    systemctl restart dhcpd 2>/dev/null || systemctl restart isc-dhcp-server 2>/dev/null
    sleep 2
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP сервер перезапущен"
    else
        err "Ошибка перезапуска DHCP"
    fi
    
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
    
    sep
    log "${WHITE}=== Статус сервиса ===${NC}"
    sep
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP сервер: ${GREEN}АКТИВЕН${NC}"
    else
        err "DHCP сервер: ${RED}НЕ АКТИВЕН${NC}"
    fi
    
    sep
    log "${WHITE}=== Прослушиваемые порты ===${NC}"
    sep
    
    ss -ulnp | grep ":67" 2>/dev/null || warn "Нет прослушивания на порту 67"
    
    sep
    log "${WHITE}=== Арендованные адреса ===${NC}"
    sep
    
    LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
    if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
        LEASE_COUNT=$(grep -c "lease" "$LEASE_FILE" 2>/dev/null || echo "0")
        ok "Leases: $LEASE_COUNT записей"
        tail -30 "$LEASE_FILE"
    else
        warn "Нет арендованных адресов"
    fi
    
    show_static_hosts
    
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
    rm -f "$HOSTS_DATA" 2>/dev/null
    
    ok "Настройки DHCP очищены"
    log ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

show_menu() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}              ${WHITE}МЕНЮ DHCP SERVER v3.0${NC}                       ${CYAN}║${NC}"
    log "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    log "${CYAN}║${NC}  ${GREEN}1.${NC} Автоопределение параметров                         ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}2.${NC} Настроить DHCP сервер                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}3.${NC} Выдать IP клиенту по VLAN                           ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}4.${NC} Показать список клиентов                            ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}5.${NC} Удалить клиента                                     ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}6.${NC} Перезапустить DHCP (применить изменения)           ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}7.${NC} Проверить DHCP сервер                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}8.${NC} Очистить настройки DHCP                            ${CYAN}║${NC}"
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
            add_static_host
            ;;
        4)
            show_static_hosts
            ;;
        5)
            delete_static_host
            ;;
        6)
            restart_dhcp
            ;;
        7)
            check_dhcp
            ;;
        8)
            clean_dhcp
            ;;
        0)
            ok "Выход"
            rm -f "$IFACE_DATA" "$VLAN_DATA" "$NETWORK_DATA" /tmp/dhcp_net_count_$$ 2>/dev/null
            exit 0
            ;;
        *)
            err "Неверный выбор: $choice"
            ;;
    esac
    
    log ""
    read -p "Нажмите Enter для продолжения..."
done
