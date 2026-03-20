#!/bin/bash
#===============================================================================
# ИСПРАВЛЕННЫЙ СКРИПТ НАСТРОЙКИ FRR (FIXED)
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Файлы конфигурации
FRR_DAEMONS="/etc/frr/daemons"
INTERFACES_DIR="/etc/net/ifaces"

# Глобальные переменные
ROUTER_ROLE=""
ROUTER_ID=""
GRE_INTERFACE="gre1"
GRE_IP=""
GRE_NETWORK="172.16.100.0/29"
EXTERNAL_INTERFACE=""
OSPF_PASSWORD="P@ssw0rd"
NETWORKS=()

# Функции вывода
print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_err() { echo -e "${RED}[ОШИБКА]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "Запустите скрипт от имени root (sudo)."
        exit 1
    fi
}

# Проверка и установка ipcalc
check_dependencies() {
    if ! command -v ipcalc &> /dev/null; then
        print_msg "Утилита ipcalc не найдена. Устанавливаем..."
        apt-get update >/dev/null 2>&1
        apt-get install -y ipcalc >/dev/null 2>&1
        if ! command -v ipcalc &> /dev/null; then
            print_err "Не удалось установить ipcalc. Установите вручную: apt-get install ipcalc"
            exit 1
        fi
        print_ok "ipcalc установлен."
    fi
}

get_hostname() { hostname -s 2>/dev/null || hostname; }

detect_router_role() {
    local hn=$(get_hostname | tr '[:upper:]' '[:lower:]')
    case $hn in
        *hq-rtr*|*hq_rtr*) echo "HQ-RTR" ;;
        *br-rtr*|*br_rtr*) echo "BR-RTR" ;;
        *isp*) echo "ISP" ;;
        *) echo "" ;;
    esac
}

get_interface_ip() {
    ip -4 addr show dev "$1" 2>/dev/null | grep -oP 'inet \K[\d.]+'
}

get_interface_prefix() {
    ip -4 addr show dev "$1" 2>/dev/null | grep -oP 'inet [\d./]+' | grep -oP '/\d+'
}

# Исправленная функция получения сети
get_interface_network() {
    local iface=$1
    local ip=$(get_interface_ip "$iface")
    local prefix=$(get_interface_prefix "$iface")
    
    if [[ -z "$ip" || -z "$prefix" ]]; then return; fi
    
    # Используем ipcalc для получения сети (Network)
    ipcalc -n "$ip$prefix" 2>/dev/null | grep -i network | awk '{print $2}'
}

get_all_interfaces() {
    ls /sys/class/net/ 2>/dev/null | grep -v "^lo$"
}

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ
#===============================================================================

configure_gre() {
    clear
    echo -e "${CYAN}=== НАСТРОЙКА GRE ТУННЕЛЯ ===${NC}"
    
    # 1. Выбор внешнего интерфейса
    print_msg "Доступные интерфейсы:"
    local ifaces=($(get_all_interfaces))
    local i=1
    for iface in "${ifaces[@]}"; do
        local ip=$(get_interface_ip "$iface")
        echo "  $i) $iface ($ip)"
        ((i++))
    done
    
    read -p "Выберите номер ВНЕШНЕГО интерфейса (через который идет туннель): " choice
    local idx=$((choice - 1))
    EXTERNAL_INTERFACE="${ifaces[$idx]}"
    local local_wan_ip=$(get_interface_ip "$EXTERNAL_INTERFACE")
    
    print_ok "Выбран внешний интерфейс: $EXTERNAL_INTERFACE ($local_wan_ip)"

    # 2. Настройка параметров туннеля
    local remote_ip=""
    local gre_local_ip=""

    if [[ "$ROUTER_ROLE" == "HQ-RTR" ]]; then
        gre_local_ip="172.16.100.1/29"
        print_msg "Это HQ-RTR. IP туннеля: $gre_local_ip"
        read -p "Введите ВНЕШНИЙ IP удаленного маршрутизатора (BR-RTR): " remote_ip
    else
        gre_local_ip="172.16.100.2/29"
        print_msg "Это BR-RTR. IP туннеля: $gre_local_ip"
        read -p "Введите ВНЕШНИЙ IP удаленного маршрутизатора (HQ-RTR): " remote_ip
    fi

    read -p "Локальный IP туннеля [$gre_local_ip]: " user_gre_ip
    GRE_IP="${user_gre_ip:-$gre_local_ip}"

    # 3. Создание туннеля
    print_msg "Создание интерфейса $GRE_INTERFACE..."
    ip tunnel add $GRE_INTERFACE mode gre local $local_wan_ip remote $remote_ip ttl 64 2>/dev/null
    ip addr add $GRE_IP dev $GRE_INTERFACE
    ip link set $GRE_INTERFACE up
    print_ok "Туннель поднят."

    # 4. Сохранение конфигурации (ALT Linux)
    local iface_dir="$INTERFACES_DIR/$GRE_INTERFACE"
    mkdir -p "$iface_dir"
    
    cat > "$iface_dir/options" <<EOF
BOOTPROTO=static
TYPE=iptun
TUNLOCAL=$local_wan_ip
TUNREMOTE=$remote_ip
TUNTYPE=gre
TUNOPTIONS='ttl 64'
HOST=$EXTERNAL_INTERFACE
ONBOOT=yes
DISABLED=no
EOF
    echo "$GRE_IP" > "$iface_dir/ipv4address"
    print_ok "Конфигурация сохранена."
}

#===============================================================================
# ВЫБОР СЕТЕЙ ДЛЯ OSPF
#===============================================================================

select_networks_ospf() {
    clear
    echo -e "${CYAN}=== ВЫБОР СЕТЕЙ ДЛЯ OSPF ===${NC}"
    print_warn "Сеть туннеля ($GRE_NETWORK) будет добавлена АВТОМАТИЧЕСКИ."
    print_msg "Выберите ВНУТРЕННИЕ сети для анонсирования:"
    echo "----------------------------------------------------------------"
    
    NETWORKS=()
    local all_ifaces=($(get_all_interfaces))
    local i=1
    declare -A map_iface

    for iface in "${all_ifaces[@]}"; do
        # Пропускаем lo, GRE и внешний интерфейс
        if [[ "$iface" == "lo" ]] || [[ "$iface" == "$GRE_INTERFACE" ]] || [[ "$iface" == "$EXTERNAL_INTERFACE" ]]; then
            continue
        fi

        local net=$(get_interface_network "$iface")
        local ip=$(get_interface_ip "$iface")
        
        # Если сеть определилась
        if [[ -n "$net" ]]; then
            printf "  ${GREEN}%2s)${NC} %-10s %-18s (IP: %s)\n" "$i" "$iface" "$net" "$ip"
            map_iface[$i]="$net"
            ((i++))
        elif [[ -n "$ip" ]]; then
            # Если ipcalc не справился, предлагаем ввести вручную
            printf "  ${YELLOW}%2s)${NC} %-10s %-18s (IP: %s) - ввести вручную?\n" "$i" "$iface" "???" "$ip"
            map_iface[$i]="MANUAL_$iface"
            ((i++))
        fi
    done
    
    # Если список пуст
    if [[ ${#map_iface[@]} -eq 0 ]]; then
        print_err "Не найдено сетей. Введите сеть вручную (например, 172.16.1.0/24):"
        read -p "Сеть: " manual_net
        NETWORKS+=("$manual_net")
    else
        echo "----------------------------------------------------------------"
        print_msg "Введите номера сетей через пробел (например: 1 2)"
        read -p "Ваш выбор: " choices

        for c in $choices; do
            local val="${map_iface[$c]}"
            if [[ "$val" =~ ^MANUAL_ ]]; then
                read -p "Введите сеть для интерфейса ${val##*_} (CIDR): " manual_net
                NETWORKS+=("$manual_net")
            elif [[ -n "$val" ]]; then
                NETWORKS+=("$val")
            fi
        done
    fi

    # Добавляем сеть туннеля
    NETWORKS+=("$GRE_NETWORK")
    
    print_ok "Итоговый список сетей для OSPF:"
    for n in "${NETWORKS[@]}"; do echo "  - $n"; done
}

#===============================================================================
# КОНФИГУРАЦИЯ FRR
#===============================================================================

install_and_config_frr() {
    print_msg "Установка FRR..."
    apt-get update >/dev/null 2>&1
    apt-get install -y frr >/dev/null 2>&1 || { print_err "Не удалось установить FRR"; exit 1; }
    print_ok "FRR установлен"

    sed -i 's/^ospfd=no/ospfd=yes/' $FRR_DAEMONS
    sed -i 's/^bgpd=no/bgpd=yes/' $FRR_DAEMONS
    
    systemctl enable --now frr
    sleep 2
}

apply_ospf_config() {
    print_msg "Применение конфигурации OSPF..."
    
    local cmds="configure terminal\n"
    cmds+="router ospf\n"
    cmds+="ospf router-id $ROUTER_ID\n"
    cmds+="passive-interface default\n"
    
    for net in "${NETWORKS[@]}"; do
        cmds+="network $net area 0\n"
    done
    
    cmds+="area 0 authentication\n"
    cmds+="exit\n"
    
    cmds+="interface $GRE_INTERFACE\n"
    cmds+="no ip ospf passive\n"
    cmds+="ip ospf authentication\n"
    cmds+="ip ospf authentication-key $OSPF_PASSWORD\n"
    cmds+="exit\n"
    cmds+="exit\n"
    cmds+="write\n"

    echo -e "$cmds" | vtysh
    print_ok "OSPF настроен."
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    check_root
    check_dependencies  # Проверяем ipcalc при запуске
    
    clear
    echo -e "${CYAN}########################################"
    echo "#   НАСТРОЙКА FRR (OSPF/BGP) ALT LINUX  #"
    echo - "########################################${NC}"
    
    # Определение роли
    ROUTER_ROLE=$(detect_router_role)
    if [[ -z "$ROUTER_ROLE" ]]; then
        print_err "Не удалось определить роль роутера по имени хоста."
        echo "Выберите роль:"
        echo "1) HQ-RTR"
        echo "2) BR-RTR"
        read -p "Ваш выбор: " role_sel
        case $role_sel in
            1) ROUTER_ROLE="HQ-RTR" ;;
            2) ROUTER_ROLE="BR-RTR" ;;
        esac
    fi
    print_ok "Роль: $ROUTER_ROLE"

    # Router ID
    if [[ "$ROUTER_ROLE" == "HQ-RTR" ]]; then ROUTER_ID="10.10.10.1"; else ROUTER_ID="10.10.10.2"; fi
    read -p "Router ID [$ROUTER_ID]: " user_rid
    ROUTER_ID="${user_rid:-$ROUTER_ID}"

    configure_gre
    select_networks_ospf
    
    read -p "Пароль OSPF [P@ssw0rd]: " pass
    OSPF_PASSWORD="${pass:-P@ssw0rd}"

    install_and_config_frr
    apply_ospf_config

    echo ""
    print_ok "Готово! Проверка: vtysh -c 'show ip ospf neighbor'"
}

main "$@"
