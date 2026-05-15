#!/bin/bash
#===============================================================================
# DHCP SERVER SETUP - Версия 4.0
# Полностью автоматическое определение VLAN и сетей
# Добавлено: быстрое добавление клиентов HQ-CLI, HQ-SRV и т.д.
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
NATIVE_LAST_HOST=""

# Предопределённые клиенты для экзамена
# Формат: имя|описание|дефолт_VLAN
PREDEFINED_CLIENTS=(
    "hq-cli|Клиент HQ|20"
    "hq-srv|Сервер HQ|10"
    "br-cli|Клиент BR|20"
    "br-srv|Сервер BR|10"
    "hq-rtr|Роутер HQ|99"
    "br-rtr|Роутер BR|99"
)

# Временные файлы
IFACE_DATA="/tmp/dhcp_ifaces_$$"
VLAN_DATA="/tmp/dhcp_vlans_$$"
NETWORK_DATA="/tmp/dhcp_networks_$$"
HOSTS_DATA="/tmp/dhcp_hosts_$$"
LEASES_BACKUP="/tmp/dhcp_leases_backup_$$"
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
        case "$iface" in
            lo|docker*|veth*|virbr*|br-*|flannel*|cni*|tun*|sit*) continue ;;
        esac
        
        iface_type="VIRTUAL"
        if [[ "$iface" == *"."* ]]; then
            iface_type="VLAN"
        elif [[ "$iface" == "gre"* ]]; then
            iface_type="GRE"
        elif [ -d "/sys/class/net/${iface}/device" ]; then
            iface_type="PHYSICAL"
        fi
        
        iface_status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        iface_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        
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
        
        echo "$iface|$iface_type|$iface_ip|$iface_status" >> "$IFACE_DATA"
    done
    
    log ""
    
    #===========================================================================
    # 2. Определение WAN
    #===========================================================================
    sep
    log "${WHITE}=== 2. Определение WAN ===${NC}"
    sep
    log ""
    
    if [ -n "$DEF_ROUTE_IFACE" ]; then
        WAN_IFACE="$DEF_ROUTE_IFACE"
        WAN_IP=$(ip -4 addr show dev "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}')
        ok "WAN: ${WHITE}$WAN_IFACE${NC} (${WAN_IP:-нет IP})"
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
    # 3. Определение LAN
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
    # 4. Определение VLAN и сетей
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
        local last_host=""
        local range_start=""
        local range_end=""
        
        case "$cidr" in
            29)
                bcast="${o1}.${o2}.${o3}.7"
                last_host="${o1}.${o2}.${o3}.6"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.5"
                ;;
            28)
                bcast="${o1}.${o2}.${o3}.15"
                last_host="${o1}.${o2}.${o3}.14"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.14"
                ;;
            27)
                bcast="${o1}.${o2}.${o3}.31"
                last_host="${o1}.${o2}.${o3}.30"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.30"
                ;;
            26)
                bcast="${o1}.${o2}.${o3}.63"
                last_host="${o1}.${o2}.${o3}.62"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.62"
                ;;
            25)
                bcast="${o1}.${o2}.${o3}.127"
                last_host="${o1}.${o2}.${o3}.126"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.126"
                ;;
            24)
                bcast="${o1}.${o2}.${o3}.255"
                last_host="${o1}.${o2}.${o3}.254"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
                ;;
            *)
                bcast="${o1}.${o2}.${o3}.255"
                last_host="${o1}.${o2}.${o3}.254"
                range_start="${o1}.${o2}.${o3}.$((o4 + 1))"
                range_end="${o1}.${o2}.${o3}.254"
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
                    
                    log "  ${CYAN}VLAN $vid${NC}: $iface -> $network/$cidr (DHCP: $range_start-$range_end)"
                fi
            fi
        fi
    done < "$IFACE_DATA"
    
    #===========================================================================
    # 5. Определение Native
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
            
            ok "Native: $VLAN_PARENT -> $NATIVE_NETWORK/$NATIVE_CIDR (DHCP: $NATIVE_RANGE_START-$NATIVE_RANGE_END)"
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
# ПОКАЗАТЬ ДОСТУПНЫЕ СЕТИ
#===============================================================================

show_available_networks() {
    log ""
    log "${CYAN}=== Доступные сети для DHCP ===${NC}"
    log ""
    
    idx=0
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        idx=$((idx + 1))
        log "  ${GREEN}$idx)${NC} ${MAGENTA}Native${NC} ($VLAN_PARENT) -> $NATIVE_NETWORK/$NATIVE_CIDR"
        log "      DHCP диапазон: $NATIVE_RANGE_START - $NATIVE_RANGE_END"
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            idx=$((idx + 1))
            log "  ${GREEN}$idx)${NC} ${CYAN}VLAN $vid${NC} ($iface) -> $network/$cidr"
            log "      DHCP диапазон: $range_start - $range_end"
        done < "$VLAN_DATA"
    fi
    
    echo "$idx" > /tmp/dhcp_net_count_$$
    log ""
}

#===============================================================================
# ПОЛУЧИТЬ ПАРАМЕТРЫ СЕТИ ПО НОМЕРУ
#===============================================================================

get_network_by_number() {
    local num="$1"
    local current=0
    
    if [ "$NATIVE_EXISTS" = "1" ]; then
        current=$((current + 1))
        if [ "$current" -eq "$num" ]; then
            echo "native|$NATIVE_NETWORK|$NATIVE_MASK|$NATIVE_CIDR|$NATIVE_GW|$NATIVE_RANGE_START|$NATIVE_RANGE_END|$NATIVE_LAST_HOST|$VLAN_PARENT"
            return
        fi
    fi
    
    if [ -s "$VLAN_DATA" ]; then
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            current=$((current + 1))
            if [ "$current" -eq "$num" ]; then
                echo "$vid|$network|$mask|$cidr|$gw|$range_start|$range_end|$last_host|$iface"
                return
            fi
        done < "$VLAN_DATA"
    fi
}

#===============================================================================
# БЫСТРОЕ ДОБАВЛЕНИЕ HQ-CLI
#===============================================================================

quick_add_hq_cli() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}        ${WHITE}БЫСТРОЕ ДОБАВЛЕНИЕ HQ-CLI${NC}                     ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    show_available_networks
    
    NET_COUNT=$(cat /tmp/dhcp_net_count_$$ 2>/dev/null || echo "0")
    
    if [ "$NET_COUNT" -eq 0 ]; then
        err "Нет сетей! Сначала выполните автоопределение."
        return 1
    fi
    
    log "${YELLOW}Выберите VLAN для HQ-CLI (клиентская сеть):${NC}"
    log "  Обычно VLAN 20 (CLI-Net) для клиентов"
    read -p "Номер сети [2]: " net_num
    net_num=${net_num:-2}
    
    if [ "$net_num" -lt 1 ] || [ "$net_num" -gt "$NET_COUNT" ]; then
        err "Неверный номер"
        return 1
    fi
    
    # Получаем параметры сети
    NET_PARAMS=$(get_network_by_number "$net_num")
    
    if [ -z "$NET_PARAMS" ]; then
        err "Не удалось получить параметры сети"
        return 1
    fi
    
    vlan_id=$(echo "$NET_PARAMS" | cut -d'|' -f1)
    network=$(echo "$NET_PARAMS" | cut -d'|' -f2)
    cidr=$(echo "$NET_PARAMS" | cut -d'|' -f4)
    gw=$(echo "$NET_PARAMS" | cut -d'|' -f5)
    range_start=$(echo "$NET_PARAMS" | cut -d'|' -f6)
    iface=$(echo "$NET_PARAMS" | cut -d'|' -f9)
    
    log ""
    ok "Выбрана сеть: ${WHITE}$network/$cidr${NC} (VLAN $vlan_id)"
    
    # MAC-адрес
    log ""
    log "${YELLOW}Введите MAC-адрес HQ-CLI:${NC}"
    log "  Формат: XX:XX:XX:XX:XX:XX"
    log "  Если неизвестен, оставьте пустым для динамического DHCP"
    read -p "MAC [ Enter для динамического ]: " cli_mac
    
    # IP-адрес
    log ""
    log "${YELLOW}Введите IP для HQ-CLI:${NC}"
    log "  Доступный диапазон: $range_start и выше"
    read -p "IP [ Enter для автоматического ]: " cli_ip
    
    if [ -z "$cli_ip" ]; then
        # Берём первый адрес из диапазона
        cli_ip="$range_start"
        ok "Авто-назначен IP: $cli_ip"
    fi
    
    # Имя хоста
    log ""
    log "${YELLOW}Имя хоста:${NC}"
    read -p "Имя [hq-cli]: " cli_name
    cli_name=${cli_name:-hq-cli}
    
    # Сохраняем
    if [ -n "$cli_mac" ]; then
        # Статическая привязка
        echo "$cli_name|$cli_mac|$cli_ip|$iface|$vlan_id|$network" >> "$HOSTS_DATA"
        ok "Добавлена статическая привязка:"
    else
        # Динамический - просто запоминаем что клиент должен быть в этой сети
        echo "$cli_name|dynamic|$cli_ip|$iface|$vlan_id|$network" >> "$HOSTS_DATA"
        ok "Клиент будет получать IP динамически из VLAN $vlan_id"
    fi
    
    log ""
    log "  Имя: ${WHITE}$cli_name${NC}"
    log "  IP: ${WHITE}$cli_ip${NC}"
    [ -n "$cli_mac" ] && log "  MAC: ${WHITE}$cli_mac${NC}"
    log "  Сеть: ${WHITE}$network/$cidr${NC} (VLAN $vlan_id)"
    log ""
    
    # Применяем изменения
    if [ -f "/etc/dhcp/dhcpd.conf" ]; then
        log "${YELLOW}Применить изменения в DHCP?${NC}"
        read -p "Перезапустить DHCP? (y/n) [y]: " apply
        apply=${apply:-y}
        
        if [ "$apply" = "y" ] || [ "$apply" = "Y" ]; then
            apply_dhcp_changes
        fi
    fi
}

#===============================================================================
# ДОБАВЛЕНИЕ ПРОИЗВОЛЬНОГО КЛИЕНТА
#===============================================================================

add_custom_client() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}        ${WHITE}ДОБАВЛЕНИЕ КЛИЕНТА${NC}                             ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    # Показать предопределённые клиенты
    log "${CYAN}Быстрый выбор:${NC}"
    log "  ${GREEN}0)${NC} Произвольный клиент"
    idx=0
    for client in "${PREDEFINED_CLIENTS[@]}"; do
        idx=$((idx + 1))
        cname=$(echo "$client" | cut -d'|' -f1)
        cdesc=$(echo "$client" | cut -d'|' -f2)
        cdefvlan=$(echo "$client" | cut -d'|' -f3)
        log "  ${GREEN}$idx)${NC} $cname - $cdesc (VLAN $cdefvlan по умолчанию)"
    done
    log ""
    
    read -p "Выберите клиента [0]: " client_choice
    client_choice=${client_choice:-0}
    
    if [ "$client_choice" -eq 0 ]; then
        # Произвольный клиент
        read -p "Имя клиента: " cli_name
        if [ -z "$cli_name" ]; then
            err "Имя не указано"
            return 1
        fi
        def_vlan=""
    else
        # Предопределённый клиент
        client_idx=$((client_choice - 1))
        if [ "$client_idx" -ge 0 ] && [ "$client_idx" -lt ${#PREDEFINED_CLIENTS[@]} ]; then
            client_data="${PREDEFINED_CLIENTS[$client_idx]}"
            cli_name=$(echo "$client_data" | cut -d'|' -f1)
            def_vlan=$(echo "$client_data" | cut -d'|' -f3)
            ok "Выбран: $cli_name"
        else
            err "Неверный выбор"
            return 1
        fi
    fi
    
    # Показываем сети
    show_available_networks
    
    NET_COUNT=$(cat /tmp/dhcp_net_count_$$ 2>/dev/null || echo "0")
    
    if [ "$NET_COUNT" -eq 0 ]; then
        err "Нет сетей!"
        return 1
    fi
    
    # Выбор VLAN
    log "${YELLOW}Выберите VLAN для $cli_name:${NC}"
    if [ -n "$def_vlan" ]; then
        read -p "Номер сети [VLAN $def_vlan]: " net_num
    else
        read -p "Номер сети: " net_num
    fi
    
    if [ -z "$net_num" ] && [ -n "$def_vlan" ]; then
        # Ищем VLAN по номеру
        net_num=1
        if [ "$NATIVE_EXISTS" = "1" ]; then
            net_num=$((net_num + 1))
        fi
        if [ -s "$VLAN_DATA" ]; then
            local found=0
            while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
                if [ "$vid" = "$def_vlan" ]; then
                    found=1
                    break
                fi
                net_num=$((net_num + 1))
            done < "$VLAN_DATA"
            [ "$found" -eq 0 ] && net_num=1
        fi
    fi
    
    if [ "$net_num" -lt 1 ] || [ "$net_num" -gt "$NET_COUNT" ]; then
        err "Неверный номер сети"
        return 1
    fi
    
    # Получаем параметры сети
    NET_PARAMS=$(get_network_by_number "$net_num")
    
    vlan_id=$(echo "$NET_PARAMS" | cut -d'|' -f1)
    network=$(echo "$NET_PARAMS" | cut -d'|' -f2)
    cidr=$(echo "$NET_PARAMS" | cut -d'|' -f4)
    gw=$(echo "$NET_PARAMS" | cut -d'|' -f5)
    range_start=$(echo "$NET_PARAMS" | cut -d'|' -f6)
    iface=$(echo "$NET_PARAMS" | cut -d'|' -f9)
    
    ok "Сеть: $network/$cidr (VLAN $vlan_id)"
    
    # MAC
    log ""
    log "${YELLOW}MAC-адрес $cli_name:${NC}"
    log "  Оставьте пустым для динамического DHCP"
    read -p "MAC: " cli_mac
    
    # IP
    log ""
    log "${YELLOW}IP-адрес $cli_name:${NC}"
    log "  Диапазон: $range_start и выше"
    read -p "IP [ Enter для первого свободного ]: " cli_ip
    
    if [ -z "$cli_ip" ]; then
        cli_ip="$range_start"
    fi
    
    # Сохраняем
    if [ -n "$cli_mac" ]; then
        echo "$cli_name|$cli_mac|$cli_ip|$iface|$vlan_id|$network" >> "$HOSTS_DATA"
        ok "$cli_name: статическая привязка $cli_ip ($cli_mac)"
    else
        echo "$cli_name|dynamic|$cli_ip|$iface|$vlan_id|$network" >> "$HOSTS_DATA"
        ok "$cli_name: динамический DHCP в VLAN $vlan_id"
    fi
    
    log ""
}

#===============================================================================
# ПОКАЗАТЬ КЛИЕНТОВ
#===============================================================================

show_clients() {
    log ""
    log "${CYAN}=== Настроенные клиенты ===${NC}"
    log ""
    
    if [ ! -s "$HOSTS_DATA" ]; then
        warn "Нет настроенных клиентов"
        log "  Используйте пункты меню для добавления HQ-CLI и других клиентов"
        return
    fi
    
    printf "  %-12s %-20s %-18s %-12s %-8s\n" "Имя" "MAC" "IP" "Интерфейс" "VLAN"
    echo "  ---------------------------------------------------------------------"
    
    while IFS='|' read -r name mac ip iface vlan network; do
        if [ "$mac" = "dynamic" ]; then
            mac_display="(динамический)"
        else
            mac_display="$mac"
        fi
        printf "  %-12s %-20s %-18s %-12s %-8s\n" "$name" "$mac_display" "$ip" "$iface" "${vlan:-native}"
    done < "$HOSTS_DATA"
    
    log ""
}

#===============================================================================
# УДАЛИТЬ КЛИЕНТА
#===============================================================================

delete_client() {
    log ""
    log "${CYAN}=== Удаление клиента ===${NC}"
    log ""
    
    if [ ! -s "$HOSTS_DATA" ]; then
        warn "Нет клиентов"
        return
    fi
    
    show_clients
    
    read -p "Имя клиента для удаления: " del_name
    
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
# ПРИМЕНИТЬ ИЗМЕНЕНИЯ В DHCP
#===============================================================================

apply_dhcp_changes() {
    log ""
    log "${YELLOW}Применение изменений в DHCP...${NC}"
    
    DHCP_CONF="/etc/dhcp/dhcpd.conf"
    
    if [ ! -f "$DHCP_CONF" ]; then
        err "Конфиг DHCP не найден! Сначала настройте DHCP сервер."
        return 1
    fi
    
    # Бэкап
    cp "$DHCP_CONF" "${DHCP_CONF}.bak" 2>/dev/null
    
    # Удаляем старые host declarations
    sed -i '/^# Static:/,/^}$/d' "$DHCP_CONF" 2>/dev/null
    sed -i '/^host /,/^}$/d' "$DHCP_CONF" 2>/dev/null
    
    # Добавляем статические привязки
    if [ -s "$HOSTS_DATA" ]; then
        while IFS='|' read -r name mac ip iface vlan network; do
            if [ "$mac" != "dynamic" ] && [ -n "$mac" ]; then
                cat >> "$DHCP_CONF" << HOSTDECL

# Static: $name
host $name {
    hardware ethernet $mac;
    fixed-address $ip;
}
HOSTDECL
                ok "  $name -> $ip ($mac)"
            fi
        done < "$HOSTS_DATA"
    fi
    
    # Проверка конфигурации
    log ""
    log "${YELLOW}Проверка конфигурации...${NC}"
    if dhcpd -t -cf "$DHCP_CONF" 2>&1 | grep -q "exiting"; then
        err "Ошибка в конфигурации!"
        dhcpd -t -cf "$DHCP_CONF" 2>&1
        return 1
    fi
    
    ok "Конфигурация валидна"
    
    # Перезапуск
    log ""
    log "${YELLOW}Перезапуск DHCP...${NC}"
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
# НАСТРОЙКА DHCP СЕРВЕРА
#===============================================================================

setup_dhcp() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}НАСТРОЙКА DHCP СЕРВЕРА${NC}                       ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    auto_detect_all
    
    log ""
    read -p "Продолжить? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        warn "Отменено"
        return
    fi
    
    # Установка
    sep
    log "${WHITE}=== Установка DHCP ===${NC}"
    sep
    
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
    
    ok "DHCP установлен"
    
    # Конфигурация
    sep
    log "${WHITE}=== Конфигурация DHCP ===${NC}"
    sep
    
    DHCP_CONF="/etc/dhcp/dhcpd.conf"
    DHCP_ARGS="$VLAN_PARENT"
    
    cat > "$DHCP_CONF" << 'DHCPHEAD'
# DHCP Configuration - Auto-generated
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;
DHCPHEAD
    
    # Статические привязки
    if [ -s "$HOSTS_DATA" ]; then
        while IFS='|' read -r name mac ip iface vlan network; do
            if [ "$mac" != "dynamic" ] && [ -n "$mac" ]; then
                cat >> "$DHCP_CONF" << HOSTDECL

# Static: $name
host $name {
    hardware ethernet $mac;
    fixed-address $ip;
}
HOSTDECL
                ok "  $name -> $ip"
            fi
        done < "$HOSTS_DATA"
    fi
    
    # Native subnet
    if [ "$NATIVE_EXISTS" = "1" ]; then
        cat >> "$DHCP_CONF" << NATIVE_SUBNET

# Native on $VLAN_PARENT
subnet $NATIVE_NETWORK netmask $NATIVE_MASK {
    range $NATIVE_RANGE_START $NATIVE_RANGE_END;
    option routers $NATIVE_GW;
    option subnet-mask $NATIVE_MASK;
    option broadcast-address $NATIVE_BCAST;
    option domain-name "au-team.irpo";
    option domain-name-servers 8.8.8.8, 8.8.4.4;
}
NATIVE_SUBNET
        ok "Native: $NATIVE_NETWORK/$NATIVE_CIDR"
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
        ok "VLAN $vid: $network/$cidr"
        DHCP_ARGS="$DHCP_ARGS $iface"
    done < "$VLAN_DATA"
    
    # Интерфейсы
    if [ -f "/etc/sysconfig/dhcpd" ]; then
        echo "DHCPDARGS=\"$DHCP_ARGS\"" > /etc/sysconfig/dhcpd
    elif [ -f "/etc/default/isc-dhcp-server" ]; then
        echo "INTERFACESv4=\"$DHCP_ARGS\"" > /etc/default/isc-dhcp-server
    fi
    
    ok "Интерфейсы: $DHCP_ARGS"
    
    # Leases
    LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
    LEASE_DIR=$(dirname "$LEASE_FILE")
    [ ! -d "$LEASE_DIR" ] && mkdir -p "$LEASE_DIR"
    [ ! -f "$LEASE_FILE" ] && touch "$LEASE_FILE"
    
    # Проверка
    log ""
    if dhcpd -t -cf "$DHCP_CONF" 2>&1 | grep -q "exiting"; then
        err "Ошибка в конфигурации!"
        return 1
    fi
    ok "Конфигурация валидна"
    
    # IP Forwarding
    sep
    log "${WHITE}=== IP Forwarding ===${NC}"
    sep
    
    SYSCTL_FILE="/etc/sysctl.conf"
    [ -f "/etc/net/sysctl.conf" ] && SYSCTL_FILE="/etc/net/sysctl.conf"
    
    grep -q "net.ipv4.ip_forward" "$SYSCTL_FILE" || echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
    sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
    sysctl -p > /dev/null 2>&1
    
    ok "IP forwarding включён"
    
    # NAT
    if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$VLAN_PARENT" ]; then
        sep
        log "${WHITE}=== NAT ===${NC}"
        sep
        
        [ "$NATIVE_EXISTS" = "1" ] && {
            iptables -t nat -A POSTROUTING -s "$NATIVE_NETWORK/$NATIVE_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$VLAN_PARENT" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$VLAN_PARENT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $NATIVE_NETWORK/$NATIVE_CIDR"
        }
        
        while IFS='|' read -r iface vid network mask cidr gw range_start range_end bcast last_host; do
            iptables -t nat -A POSTROUTING -s "$network/$cidr" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
            iptables -A FORWARD -i "$iface" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -i "$WAN_IFACE" -o "$iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            ok "NAT: $network/$cidr"
        done < "$VLAN_DATA"
        
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    # Запуск
    sep
    log "${WHITE}=== Запуск DHCP ===${NC}"
    sep
    
    systemctl enable dhcpd 2>/dev/null || systemctl enable isc-dhcp-server 2>/dev/null
    systemctl restart dhcpd 2>/dev/null || systemctl restart isc-dhcp-server 2>/dev/null
    sleep 2
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP запущен"
    else
        err "Ошибка запуска DHCP"
    fi
    
    # Итог
    log ""
    log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${GREEN}║${NC}            ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                        ${GREEN}║${NC}"
    log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    show_clients
    
    log "${CYAN}Проверка:${NC}"
    log "  systemctl status dhcpd"
    log "  cat /var/lib/dhcp/dhcpd.leases"
    log ""
}

#===============================================================================
# ПРОВЕРКА DHCP
#===============================================================================

check_dhcp() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}ПРОВЕРКА DHCP${NC}                                ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    sep
    log "${WHITE}=== Статус ===${NC}"
    sep
    
    if systemctl is-active dhcpd >/dev/null 2>&1 || systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        ok "DHCP: ${GREEN}АКТИВЕН${NC}"
    else
        err "DHCP: ${RED}НЕ АКТИВЕН${NC}"
    fi
    
    sep
    log "${WHITE}=== Порты ===${NC}"
    sep
    
    ss -ulnp | grep ":67" 2>/dev/null || warn "Порт 67 не прослушивается"
    
    sep
    log "${WHITE}=== Leases ===${NC}"
    sep
    
    LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
    if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
        ok "Leases: $(grep -c 'lease' $LEASE_FILE 2>/dev/null || echo '0') записей"
        tail -20 "$LEASE_FILE"
    else
        warn "Нет leases"
    fi
    
    show_clients
    
    log ""
}

#===============================================================================
# ОЧИСТКА
#===============================================================================

clean_dhcp() {
    log ""
    log "${YELLOW}Очистка DHCP...${NC}"
    
    systemctl stop dhcpd 2>/dev/null
    systemctl stop isc-dhcp-server 2>/dev/null
    
    rm -f /etc/dhcp/dhcpd.conf 2>/dev/null
    rm -f /var/lib/dhcp/dhcpd.leases 2>/dev/null
    touch /var/lib/dhcp/dhcpd.leases 2>/dev/null
    rm -f "$HOSTS_DATA" 2>/dev/null
    
    ok "Очищено"
    log ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

show_menu() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}              ${WHITE}МЕНЮ DHCP SERVER v4.0${NC}                       ${CYAN}║${NC}"
    log "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    log "${CYAN}║${NC}  ${GREEN}1.${NC} Автоопределение параметров                         ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}2.${NC} Настроить DHCP сервер                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${MAGENTA}3.${NC} ${WHITE}Быстро добавить HQ-CLI${NC}                             ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}4.${NC} Добавить произвольного клиента                      ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}5.${NC} Показать список клиентов                            ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}6.${NC} Удалить клиента                                     ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}7.${NC} Применить изменения в DHCP                          ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}8.${NC} Проверить DHCP                                      ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}9.${NC} Очистить настройки                                  ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${RED}0.${NC} Выход                                               ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
}

# Основной цикл
while true; do
    show_menu
    read -p "Выберите пункт: " choice
    
    case "$choice" in
        1) auto_detect_all ;;
        2) setup_dhcp ;;
        3) quick_add_hq_cli ;;
        4) add_custom_client ;;
        5) show_clients ;;
        6) delete_client ;;
        7) apply_dhcp_changes ;;
        8) check_dhcp ;;
        9) clean_dhcp ;;
        0)
            ok "Выход"
            rm -f "$IFACE_DATA" "$VLAN_DATA" "$NETWORK_DATA" /tmp/dhcp_net_count_$$ 2>/dev/null
            exit 0
            ;;
        *) err "Неверный выбор: $choice" ;;
    esac
    
    log ""
    read -p "Нажмите Enter для продолжения..."
done
