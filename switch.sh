#!/bin/bash
#===============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR ДЛЯ ALT LINUX (УПРОЩЕННАЯ ВЕРСИЯ)
# Исправлена логика выбора сетей для OSPF
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Вспомогательные функции
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

get_interface_network() {
    # Возвращает сеть в формате CIDR (например, 192.168.1.0/24)
    ip -4 addr show dev "$1" 2>/dev/null | grep -oP 'inet \K[\d./]+' | xargs -I {} ipcalc -n {} | grep Network | awk '{print $2}'
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
    print_msg "Доступные физические интерфейсы:"
    local ifaces=($(get_all_interfaces))
    local i=1
    for iface in "${ifaces[@]}"; do
        local ip=$(get_interface_ip "$iface")
        echo "  $i) $iface ($ip)"
        ((i++))
    done
    
    read -p "Выберите номер ВНЕШНЕГО интерфейса (для туннеля): " choice
    local idx=$((choice - 1))
    EXTERNAL_INTERFACE="${ifaces[$idx]}"
    local local_wan_ip=$(get_interface_ip "$EXTERNAL_INTERFACE")
    
    print_ok "Выбран внешний интерфейс: $EXTERNAL_INTERFACE ($local_wan_ip)"

    # 2. Настройка параметров туннеля
    local remote_ip=""
    local gre_local_ip=""

    if [[ "$ROUTER_ROLE" == "HQ-RTR" ]]; then
        gre_local_ip="172.16.100.1/29"
        print_msg "Это HQ-RTR. Рекомендуемый IP туннеля: $gre_local_ip"
        read -p "Введите ВНЕШНИЙ IP удаленного маршрутизатора (BR-RTR): " remote_ip
    else
        gre_local_ip="172.16.100.2/29"
        print_msg "Это BR-RTR. Рекомендуемый IP туннеля: $gre_local_ip"
        read -p "Введите ВНЕШНИЙ IP удаленного маршрутизатора (HQ-RTR): " remote_ip
    fi

    read -p "Локальный IP туннеля [$gre_local_ip]: " user_gre_ip
    GRE_IP="${user_gre_ip:-$gre_local_ip}"

    # 3. Создание туннеля "на лету" (для текущей сессии)
    print_msg "Создание интерфейса $GRE_INTERFACE..."
    ip tunnel add $GRE_INTERFACE mode gre local $local_wan_ip remote $remote_ip ttl 64
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
    print_ok "Конфигурация сохранена в $iface_dir"
}

#===============================================================================
# ВЫБОР СЕТЕЙ ДЛЯ OSPF (ИСПРАВЛЕННАЯ ЛОГИКА)
#===============================================================================

select_networks_ospf() {
    clear
    echo -e "${CYAN}=== ВЫБОР СЕТЕЙ ДЛЯ OSPF ===${NC}"
    print_warn "Сеть туннеля ($GRE_NETWORK) будет добавлена АВТОМАТИЧЕСКИ."
    print_msg "Выберите ВНУТРЕННИЕ сети, которые нужно анонсировать:"
    echo "----------------------------------------------------------------"
    
    NETWORKS=()
    local all_ifaces=($(get_all_interfaces))
    local i=1
    declare -a map_iface

    for iface in "${all_ifaces[@]}"; do
        # Пропускаем lo, сам GRE интерфейс и ВНЕШНИЙ интерфейс
        if [[ "$iface" == "lo" ]] || [[ "$iface" == "$GRE_INTERFACE" ]] || [[ "$iface" == "$EXTERNAL_INTERFACE" ]]; then
            continue
        fi

        local net=$(get_interface_network "$iface")
        local ip=$(get_interface_ip "$iface")
        
        if [[ -n "$net" ]]; then
            printf "  ${GREEN}%2s)${NC} %-10s %-18s (IP: %s)\n" "$i" "$iface" "$net" "$ip"
            map_iface[$i]="$net"
            ((i++))
        fi
    done
    
    if [[ ${#map_iface[@]} -eq 0 ]]; then
        print_err "Не найдено доступных внутренних сетей!"
        exit 1
    fi

    echo "----------------------------------------------------------------"
    print_msg "Введите номера сетей через пробел (например: 1 2 3)"
    read -p "Ваш выбор: " choices

    for c in $choices; do
        if [[ -n "${map_iface[$c]}" ]]; then
            NETWORKS+=("${map_iface[$c]}")
        fi
    done

    # Добавляем сеть туннеля принудительно
    NETWORKS+=("$GRE_NETWORK")
    
    print_ok "Выбраны сети:"
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

    # Включаем демоны
    sed -i 's/^ospfd=no/ospfd=yes/' $FRR_DAEMONS
    sed -i 's/^bgpd=no/bgpd=yes/' $FRR_DAEMONS
    
    # Запуск службы
    systemctl enable --now frr
    sleep 2
}

apply_ospf_config() {
    print_msg "Применение конфигурации OSPF..."
    
    # Формируем конфиг
    local cmds="configure terminal\n"
    cmds+="router ospf\n"
    cmds+="ospf router-id $ROUTER_ID\n"
    cmds+="passive-interface default\n" # Все интерфейсы пассивные по умолчанию
    
    # Добавляем выбранные сети
    for net in "${NETWORKS[@]}"; do
        cmds+="network $net area 0\n"
    done
    
    cmds+="area 0 authentication\n"
    cmds+="exit\n"
    
    # Отключаем пассивный режим для GRE (чтобы маршрутизаторы общались)
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
# ГЛАВНОЕ МЕНЮ
#===============================================================================

main() {
    check_root
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
    print_ok "Роль определена: $ROUTER_ROLE"

    # Настройка Router ID
    if [[ "$ROUTER_ROLE" == "HQ-RTR" ]]; then
        ROUTER_ID="10.10.10.1"
    else
        ROUTER_ID="10.10.10.2"
    fi
    read -p "Router ID [$ROUTER_ID]: " user_rid
    ROUTER_ID="${user_rid:-$ROUTER_ID}"

    # Основные шаги
    configure_gre
    select_networks_ospf
    
    # Пароль OSPF
    read -p "Пароль для аутентификации OSPF [P@ssw0rd]: " pass
    OSPF_PASSWORD="${pass:-P@ssw0rd}"

    # Установка и применение
    install_and_config_frr
    apply_ospf_config

    echo ""
    print_ok "Настройка завершена!"
    echo "Проверка состояния:"
    echo "  vtysh -c 'show ip ospf neighbor'"
    echo "  ping <IP удаленного туннеля>"
}

main "$@"
