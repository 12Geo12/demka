#!/bin/bash
#===============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (Free Range Routing) ДЛЯ ALT LINUX
# На основе решения Demo2026 - Сетевое и системное администрирование
#
# Поддерживает:
#   • OSPF - динамическая маршрутизация между офисами (HQ-RTR ↔ BR-RTR)
#   • BGP  - получение маршрута по умолчанию от провайдера (ISP)
#
# Репозиторий: github.com/stepanovs2005/Demo2026
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Файлы
LOG_FILE="/var/log/frr-setup.log"
REPORT_FILE="/root/frr-config-report.txt"
INTERFACES_DIR="/etc/net/ifaces"

# Глобальные переменные
CONFIG_MODE=""           # ospf, bgp, both
ROUTER_ROLE=""           # HQ-RTR, BR-RTR, ISP
ROUTER_ID=""
GRE_INTERFACE=""
GRE_IP=""
GRE_NETWORK=""
GRE_REMOTE_IP=""
GRE_LOCAL_IP=""
GRE_KEY=""
OSPF_PASSWORD=""
BGP_AS_LOCAL=""
BGP_AS_REMOTE=""
BGP_NEIGHBOR_IP=""
NETWORKS=()
CREATE_GRE=false
EXTERNAL_INTERFACE=""
EXTERNAL_IP=""

#===============================================================================
# ФУНКЦИИ ВЫВОДА
#===============================================================================

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                               ║"
    echo "║          FRR (Free Range Routing) - АВТОМАТИЧЕСКАЯ НАСТРОЙКА                 ║"
    echo "║                    На основе решения Demo2026                                 ║"
    echo "║                                                                               ║"
    echo "║   Поддерживаемые протоколы:                                                   ║"
    echo "║   • OSPF - маршрутизация между офисами через GRE туннель                      ║"
    echo "║   • BGP  - получение default route от провайдера                              ║"
    echo "║                                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_menu() {
    echo -e "${MAGENTA}►${NC} $1"
}

print_option() {
    echo -e "  ${GREEN}$1)${NC} $2"
}

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

show_progress() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}[%c]${NC} $message" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r"
}

#===============================================================================
# ФУНКЦИИ ОПРЕДЕЛЕНИЯ СИСТЕМЫ
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен от имени root"
        print_info "Используйте: sudo $0"
        exit 1
    fi
}

check_alt_linux() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" == "altlinux" || "$ID" == "alt" ]]; then
            print_success "Обнаружена ALT Linux: $PRETTY_NAME"
            return 0
        fi
    fi
    print_warning "Внимание: Скрипт оптимизирован для ALT Linux"
    read -p "Продолжить? (y/n): " continue_choice
    [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]] && exit 0
}

get_hostname() {
    hostname -f 2>/dev/null || hostname
}

detect_router_role() {
    local hostname=$(get_hostname | tr '[:upper:]' '[:lower:]')
    
    if [[ "$hostname" =~ "hq-rtr" || "$hostname" =~ "hq_rtr" ]]; then
        echo "HQ-RTR"
    elif [[ "$hostname" =~ "br-rtr" || "$hostname" =~ "br_rtr" ]]; then
        echo "BR-RTR"
    elif [[ "$hostname" =~ "isp" ]]; then
        echo "ISP"
    else
        echo ""
    fi
}

#===============================================================================
# ФУНКЦИИ ОПРЕДЕЛЕНИЯ ИНТЕРФЕЙСОВ
#===============================================================================

get_all_interfaces() {
    ls /sys/class/net/ 2>/dev/null | grep -v "^lo$"
}

get_physical_interfaces() {
    for iface in $(get_all_interfaces); do
        if [[ ! "$iface" =~ ^gre[0-9]+$ ]] && \
           [[ ! "$iface" =~ ^tun[0-9]+$ ]] && \
           [[ ! "$iface" =~ ^vlan ]] && \
           [[ ! "$iface" =~ ^br- ]] && \
           [[ ! "$iface" =~ ^veth ]]; then
            echo "$iface"
        fi
    done
}

get_vlan_interfaces() {
    for iface in $(get_all_interfaces); do
        if [[ "$iface" =~ \. ]]; then
            echo "$iface"
        fi
    done
}

get_gre_interfaces() {
    for iface in $(get_all_interfaces); do
        if [[ "$iface" =~ ^gre[0-9]+$ ]] || [[ "$iface" =~ ^tun[0-9]+$ ]]; then
            echo "$iface"
        fi
    done
}

get_interface_ip() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+(?=/)'
}

get_interface_cidr() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet [\d./]+' | grep -oP '/\d+'
}

get_interface_network() {
    local iface=$1
    local ip_cidr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet [\d./]+')
    
    if [[ -n "$ip_cidr" ]]; then
        local ip=$(echo "$ip_cidr" | grep -oP '[\d.]+(?=/)')
        local cidr=$(echo "$ip_cidr" | grep -oP '(?<=/)\d+')
        
        if [[ -n "$ip" && -n "$cidr" ]]; then
            # Вычисляем адрес сети
            local IFS='.'
            read -ra ip_parts <<< "$ip"
            local ip_num=$((ip_parts[0] << 24 | ip_parts[1] << 16 | ip_parts[2] << 8 | ip_parts[3]))
            local mask_bits=$((32 - cidr))
            local mask_num=$(((0xFFFFFFFF << mask_bits) & 0xFFFFFFFF))
            local network_num=$((ip_num & mask_num))
            
            echo "$((network_num >> 24 & 0xFF)).$((network_num >> 16 & 0xFF)).$((network_num >> 8 & 0xFF)).$((network_num & 0xFF))/$cidr"
        fi
    fi
}

check_interface_exists() {
    ip link show "$1" &>/dev/null
    return $?
}

list_interfaces_with_details() {
    print_section "Обнаруженные сетевые интерфейсы"
    
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} %-12s %-18s %-22s %-15s ${CYAN}│${NC}\n" "Интерфейс" "IP-адрес" "Сеть" "Тип"
    echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    
    for iface in $(get_all_interfaces); do
        local ip=$(get_interface_ip "$iface")
        local network=$(get_interface_network "$iface")
        local iface_type="Физический"
        
        if [[ "$iface" =~ ^gre[0-9]+$ ]]; then
            iface_type="GRE туннель"
        elif [[ "$iface" =~ ^tun[0-9]+$ ]]; then
            iface_type="IP туннель"
        elif [[ "$iface" =~ \. ]]; then
            iface_type="VLAN"
        fi
        
        if [[ -n "$ip" ]]; then
            printf "${CYAN}│${NC} %-12s %-18s %-22s %-15s ${CYAN}│${NC}\n" "$iface" "$ip" "${network:-N/A}" "$iface_type"
        fi
    done
    
    echo -e "${CYAN}└────────────────────────────────────────────────────────────────────────────┘${NC}"
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

show_main_menu() {
    print_section "ГЛАВНОЕ МЕНЮ"
    
    echo -e "${WHITE}Выберите режим настройки:${NC}\n"
    print_option "1" "OSPF - Динамическая маршрутизация между офисами (HQ-RTR ↔ BR-RTR)"
    print_option "2" "BGP  - Получение маршрута по умолчанию от провайдера (ISP)"
    print_option "3" "Полная настройка (OSPF + BGP)"
    print_option "4" "Проверка текущей конфигурации FRR"
    print_option "5" "Удаление конфигурации FRR (сброс)"
    print_option "0" "Выход"
    echo ""
    
    local valid_choice=false
    while [[ "$valid_choice" == false ]]; do
        read -p "Ваш выбор [0]: " choice
        [[ "$choice" == "" ]] && choice="0"
        
        case $choice in
            1)
                CONFIG_MODE="ospf"
                valid_choice=true
                ;;
            2)
                CONFIG_MODE="bgp"
                valid_choice=true
                ;;
            3)
                CONFIG_MODE="both"
                valid_choice=true
                ;;
            4)
                check_frr_status
                exit 0
                ;;
            5)
                reset_frr_config
                exit 0
                ;;
            0)
                print_info "Выход из скрипта"
                exit 0
                ;;
            *)
                print_error "Неверный выбор. Введите число от 0 до 5."
                ;;
        esac
    done
    
    log_message "Выбран режим: $CONFIG_MODE"
}

#===============================================================================
# ВЫБОР РОЛИ МАРШРУТИЗАТОРА
#===============================================================================

select_router_role() {
    print_section "ВЫБОР РОЛИ МАРШРУТИЗАТОРА"
    
    # Автоматическое определение
    local detected_role=$(detect_router_role)
    
    if [[ -n "$detected_role" ]]; then
        print_info "Автоматически определена роль: ${GREEN}$detected_role${NC}"
        read -p "Использовать эту роль? (y/n) [y]: " use_detected
        [[ "$use_detected" == "" ]] && use_detected="y"
        
        if [[ "$use_detected" == "y" || "$use_detected" == "Y" ]]; then
            ROUTER_ROLE="$detected_role"
            print_success "Выбрана роль: $ROUTER_ROLE"
            log_message "Роль маршрутизатора: $ROUTER_ROLE"
            return 0
        fi
    fi
    
    # Ручной выбор
    echo -e "${WHITE}Выберите роль данного маршрутизатора:${NC}\n"
    
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        print_option "1" "HQ-RTR (Маршрутизатор главного офиса)"
        print_option "2" "BR-RTR (Маршрутизатор филиала)"
    fi
    
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        print_option "3" "ISP  (Интернет-провайдер)"
        print_option "4" "RTR-COD (ЦОД - центр обработки данных)"
    fi
    echo ""
    
    local valid_choice=false
    while [[ "$valid_choice" == false ]]; do
        read -p "Ваш выбор: " role_choice
        
        case $role_choice in
            1)
                ROUTER_ROLE="HQ-RTR"
                valid_choice=true
                ;;
            2)
                ROUTER_ROLE="BR-RTR"
                valid_choice=true
                ;;
            3)
                ROUTER_ROLE="ISP"
                valid_choice=true
                ;;
            4)
                ROUTER_ROLE="RTR-COD"
                valid_choice=true
                ;;
            *)
                print_error "Неверный выбор."
                ;;
        esac
    done
    
    print_success "Выбрана роль: $ROUTER_ROLE"
    log_message "Роль маршрутизатора: $ROUTER_ROLE"
}

#===============================================================================
# НАСТРОЙКА OSPF
#===============================================================================

select_gre_interface() {
    print_section "НАСТРОЙКА GRE ТУННЕЛЯ"
    
    # Поиск существующих GRE интерфейсов
    local gre_ifaces=($(get_gre_interfaces))
    
    if [[ ${#gre_ifaces[@]} -gt 0 ]]; then
        print_success "Обнаружены GRE интерфейсы: ${gre_ifaces[*]}"
        echo ""
        
        for i in "${!gre_ifaces[@]}"; do
            local iface="${gre_ifaces[$i]}"
            local ip=$(get_interface_ip "$iface")
            echo "  $((i+1))) $iface - IP: ${ip:-не настроен}"
        done
        echo "  $(( ${#gre_ifaces[@]} + 1 ))) Создать новый GRE туннель"
        echo ""
        
        read -p "Выберите интерфейс или создайте новый [1]: " gre_choice
        [[ "$gre_choice" == "" ]] && gre_choice="1"
        
        if [[ $gre_choice -le ${#gre_ifaces[@]} ]]; then
            GRE_INTERFACE="${gre_ifaces[$((gre_choice-1))]}"
            GRE_IP=$(get_interface_ip "$GRE_INTERFACE")
            GRE_NETWORK=$(get_interface_network "$GRE_INTERFACE")
            CREATE_GRE=false
            print_success "Выбран существующий GRE интерфейс: $GRE_INTERFACE"
            return 0
        fi
    fi
    
    # Создание нового GRE туннеля
    create_gre_tunnel_interactive
}

create_gre_tunnel_interactive() {
    print_info "Создание нового GRE туннеля"
    echo ""
    
    # Шаг 1: Имя интерфейса
    local default_iface="gre1"
    print_menu "Шаг 1: Имя интерфейса GRE туннеля"
    echo "  Рекомендуемое: $default_iface"
    read -p "  Имя интерфейса [$default_iface]: " input_iface
    GRE_INTERFACE="${input_iface:-$default_iface}"
    
    # Проверка на существование
    if check_interface_exists "$GRE_INTERFACE"; then
        print_error "Интерфейс $GRE_INTERFACE уже существует!"
        return 1
    fi
    
    echo ""
    
    # Шаг 2: Выбор внешнего интерфейса
    print_menu "Шаг 2: Выберите внешний интерфейс (для туннеля)"
    
    local phys_ifaces=($(get_physical_interfaces))
    for i in "${!phys_ifaces[@]}"; do
        local iface="${phys_ifaces[$i]}"
        local ip=$(get_interface_ip "$iface")
        echo "  $((i+1))) $iface - $ip"
    done
    echo ""
    
    read -p "  Номер интерфейса [1]: " ext_choice
    [[ "$ext_choice" == "" ]] && ext_choice="1"
    
    EXTERNAL_INTERFACE="${phys_ifaces[$((ext_choice-1))]}"
    GRE_LOCAL_IP=$(get_interface_ip "$EXTERNAL_INTERFACE")
    EXTERNAL_IP="$GRE_LOCAL_IP"
    
    print_success "Выбран внешний интерфейс: $EXTERNAL_INTERFACE ($GRE_LOCAL_IP)"
    echo ""
    
    # Шаг 3: Удалённый IP
    print_menu "Шаг 3: IP-адрес удалённого маршрутизатора"
    
    local suggested_remote=""
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_remote="172.16.5.2"
            print_info "Подсказка: Для HQ-RTR укажите внешний IP маршрутизатора BR-RTR"
            ;;
        "BR-RTR")
            suggested_remote="172.16.4.2"
            print_info "Подсказка: Для BR-RTR укажите внешний IP маршрутизатора HQ-RTR"
            ;;
    esac
    
    read -p "  Удалённый IP-адрес [$suggested_remote]: " input_remote
    GRE_REMOTE_IP="${input_remote:-$suggested_remote}"
    echo ""
    
    # Шаг 4: Внутренний IP туннеля
    print_menu "Шаг 4: Внутренний IP-адрес GRE туннеля"
    
    local suggested_gre_ip=""
    local suggested_gre_network=""
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_gre_ip="172.16.100.2/29"
            suggested_gre_network="172.16.100.0/29"
            print_info "Подсказка: Для HQ-RTR обычно используется 172.16.100.2/29"
            ;;
        "BR-RTR")
            suggested_gre_ip="172.16.100.1/29"
            suggested_gre_network="172.16.100.0/29"
            print_info "Подсказка: Для BR-RTR обычно используется 172.16.100.1/29"
            ;;
    esac
    
    read -p "  Внутренний IP туннеля [$suggested_gre_ip]: " input_gre_ip
    GRE_IP="${input_gre_ip:-$suggested_gre_ip}"
    
    # Извлекаем сеть
    if [[ "$GRE_IP" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+$ ]]; then
        local base=${BASH_REMATCH[1]}
        local cidr=$(echo "$GRE_IP" | grep -oP '/\d+')
        GRE_NETWORK="${base}.0${cidr}"
    else
        GRE_NETWORK="$suggested_gre_network"
    fi
    
    echo ""
    
    # Шаг 5: Ключ туннеля
    print_menu "Шаг 5: Ключ GRE туннеля (опционально)"
    echo "  Ключ обеспечивает дополнительную идентификацию туннеля"
    read -p "  Ключ туннеля (Enter - без ключа): " GRE_KEY
    echo ""
    
    # Подтверждение
    print_section "ПАРАМЕТРЫ GRE ТУННЕЛЯ"
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Имя интерфейса" "$GRE_INTERFACE"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Локальный внешний IP" "$GRE_LOCAL_IP"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Удалённый внешний IP" "$GRE_REMOTE_IP"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Внутренний IP туннеля" "$GRE_IP"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Ключ туннеля" "${GRE_KEY:-не задан}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
    
    read -p "Создать GRE туннель? (y/n) [y]: " confirm
    [[ "$confirm" == "" ]] && confirm="y"
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        create_gre_tunnel
        CREATE_GRE=true
        return $?
    else
        print_warning "Создание GRE туннеля отменено"
        return 1
    fi
}

create_gre_tunnel() {
    print_section "СОЗДАНИЕ GRE ТУННЕЛЯ"
    
    # Создание через ip command
    print_info "Создание интерфейса $GRE_INTERFACE..."
    
    local tunnel_cmd="ip tunnel add $GRE_INTERFACE mode gre local $GRE_LOCAL_IP remote $GRE_REMOTE_IP"
    [[ -n "$GRE_KEY" ]] && tunnel_cmd+=" key $GRE_KEY"
    
    if ! eval "$tunnel_cmd"; then
        print_error "Не удалось создать GRE интерфейс"
        return 1
    fi
    
    print_success "GRE интерфейс создан"
    
    # Настройка IP
    print_info "Настройка IP адреса..."
    ip addr add "$GRE_IP" dev "$GRE_INTERFACE"
    ip link set "$GRE_INTERFACE" up
    
    print_success "GRE туннель активирован"
    
    # Постоянная конфигурация для ALT Linux
    print_info "Создание постоянной конфигурации..."
    create_gre_permanent_config_alt
    
    log_message "GRE туннель создан: $GRE_INTERFACE ($GRE_LOCAL_IP <-> $GRE_REMOTE_IP)"
    return 0
}

create_gre_permanent_config_alt() {
    # Создание директории для интерфейса
    local iface_dir="$INTERFACES_DIR/$GRE_INTERFACE"
    mkdir -p "$iface_dir"
    
    # Файл options для ALT Linux
    cat > "$iface_dir/options" << EOF
BOOTPROTO=static
TYPE=iptun
TUNLOCAL=$GRE_LOCAL_IP
TUNREMOTE=$GRE_REMOTE_IP
TUNTYPE=gre
TUNOPTIONS='ttl 64'
HOST=$EXTERNAL_INTERFACE
ONBOOT=yes
DISABLED=no
EOF
    
    # Файл с IP адресом
    echo "$GRE_IP" > "$iface_dir/ipv4address"
    
    print_success "Конфигурация сохранена в $iface_dir"
}

select_networks_ospf() {
    print_section "ВЫБОР СЕТЕЙ ДЛЯ OSPF"
    
    print_info "Выберите сети, которые будут анонсироваться через OSPF"
    print_warning "Сеть GRE туннеля ($GRE_NETWORK) будет добавлена автоматически"
    echo ""
    
    NETWORKS=()
    
    # Получаем все сети
    declare -a network_list
    declare -a iface_list
    
    echo -e "${CYAN}Доступные сети:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    
    local i=1
    for iface in $(get_all_interfaces); do
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" == "$GRE_INTERFACE" ]] && continue
        
        local network=$(get_interface_network "$iface")
        local ip=$(get_interface_ip "$iface")
        
        if [[ -n "$network" ]]; then
            network_list+=("$network")
            iface_list+=("$iface")
            echo "  $i) $network (интерфейс: $iface)"
            ((i++))
        fi
    done
    
    echo ""
    echo -e "${YELLOW}Режим выбора:${NC}"
    print_option "1" "Автоматический (все сети кроме внешних)"
    print_option "2" "Ручной выбор"
    print_option "3" "Пропустить (только сеть туннеля)"
    echo ""
    
    read -p "Выберите режим [1]: " mode_choice
    [[ "$mode_choice" == "" ]] && mode_choice="1"
    
    case $mode_choice in
        1)
            # Автоматический выбор всех сетей
            for net in "${network_list[@]}"; do
                NETWORKS+=("$net")
            done
            print_success "Автоматически выбрано сетей: ${#NETWORKS[@]}"
            ;;
        2)
            # Ручной выбор
            print_info "Введите номера сетей через запятую (например: 1,2,3)"
            read -p "Выбор: " selection
            
            IFS=',' read -ra selections <<< "$selection"
            for idx in "${selections[@]}"; do
                idx=$(echo "$idx" | tr -d ' ')
                if [[ $idx -ge 1 && $idx -le ${#network_list[@]} ]]; then
                    NETWORKS+=("${network_list[$((idx-1))]}")
                fi
            done
            print_success "Выбрано сетей: ${#NETWORKS[@]}"
            ;;
        3)
            print_info "Сети не выбраны (только туннель)"
            ;;
    esac
    
    # Добавляем сеть GRE туннеля
    if [[ -n "$GRE_NETWORK" ]]; then
        NETWORKS+=("$GRE_NETWORK")
        print_info "Добавлена сеть GRE туннеля: $GRE_NETWORK"
    fi
    
    # Отображение итогового списка
    echo ""
    print_info "Итоговый список сетей для OSPF:"
    for net in "${NETWORKS[@]}"; do
        echo "  • $net"
    done
}

select_router_id() {
    print_section "НАСТРОЙКА ROUTER ID"
    
    local suggested_id=""
    
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_id="10.10.10.1"
            print_info "Рекомендуемый Router ID для HQ-RTR: $suggested_id"
            ;;
        "BR-RTR")
            suggested_id="10.10.10.2"
            print_info "Рекомендуемый Router ID для BR-RTR: $suggested_id"
            ;;
        "ISP")
            suggested_id="100.100.100.100"
            print_info "Рекомендуемый Router ID для ISP: $suggested_id"
            ;;
        "RTR-COD")
            suggested_id="178.207.179.4"
            print_info "Рекомендуемый Router ID для RTR-COD: $suggested_id"
            ;;
        *)
            # Используем первый доступный IP
            for iface in $(get_physical_interfaces); do
                local ip=$(get_interface_ip "$iface")
                if [[ -n "$ip" ]]; then
                    suggested_id="$ip"
                    break
                fi
            done
            ;;
    esac
    
    read -p "Router ID [$suggested_id]: " input_id
    ROUTER_ID="${input_id:-$suggested_id}"
    
    print_success "Router ID установлен: $ROUTER_ID"
    log_message "Router ID: $ROUTER_ID"
}

select_ospf_password() {
    print_section "АУТЕНТИФИКАЦИЯ OSPF"
    
    print_warning "По условию задания аутентификация OSPF обязательна!"
    echo ""
    
    local default_pass="P@ssw0rd"
    read -p "Пароль для OSPF аутентификации [$default_pass]: " input_pass
    OSPF_PASSWORD="${input_pass:-$default_pass}"
    
    print_success "Пароль OSPF установлен"
    log_message "Пароль OSPF настроен"
}

#===============================================================================
# НАСТРОЙКА BGP
#===============================================================================

configure_bgp_interactive() {
    print_section "НАСТРОЙКА BGP"
    
    # Номер автономной системы
    print_menu "Шаг 1: Номер автономной системы (AS)"
    
    local suggested_as=""
    case $ROUTER_ROLE in
        "ISP")
            suggested_as="31133"
            print_info "AS провайдера (ISP): $suggested_as"
            ;;
        "RTR-COD")
            suggested_as="64500"
            print_info "AS клиента (RTR-COD): $suggested_as (приватная AS)"
            ;;
        "HQ-RTR"|"BR-RTR")
            suggested_as="64501"
            print_info "AS офиса: $suggested_as (приватная AS)"
            ;;
    esac
    
    read -p "Номер локальной AS [$suggested_as]: " input_as
    BGP_AS_LOCAL="${input_as:-$suggested_as}"
    echo ""
    
    # AS соседа
    print_menu "Шаг 2: Номер AS соседа"
    
    local suggested_remote_as=""
    case $ROUTER_ROLE in
        "ISP")
            suggested_remote_as="64500"
            print_info "AS соседа (клиента): $suggested_remote_as"
            ;;
        "RTR-COD"|"HQ-RTR"|"BR-RTR")
            suggested_remote_as="31133"
            print_info "AS провайдера: $suggested_remote_as"
            ;;
    esac
    
    read -p "Номер AS соседа [$suggested_remote_as]: " input_remote_as
    BGP_AS_REMOTE="${input_remote_as:-$suggested_remote_as}"
    echo ""
    
    # IP соседа
    print_menu "Шаг 3: IP-адрес BGP соседа"
    
    local suggested_neighbor=""
    case $ROUTER_ROLE in
        "ISP")
            suggested_neighbor="178.207.179.4"
            print_info "IP соседа (клиента): $suggested_neighbor"
            ;;
        "RTR-COD")
            suggested_neighbor="178.207.179.1"
            print_info "IP провайдера: $suggested_neighbor"
            ;;
    esac
    
    read -p "IP-адрес соседа [$suggested_neighbor]: " input_neighbor
    BGP_NEIGHBOR_IP="${input_neighbor:-$suggested_neighbor}"
    echo ""
    
    # Router ID
    if [[ -z "$ROUTER_ID" ]]; then
        select_router_id
    fi
    
    # Подтверждение
    print_section "ПАРАМЕТРЫ BGP"
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Локальная AS" "$BGP_AS_LOCAL"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "AS соседа" "$BGP_AS_REMOTE"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "IP соседа" "$BGP_NEIGHBOR_IP"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Router ID" "$ROUTER_ID"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
    
    read -p "Применить настройки BGP? (y/n) [y]: " confirm
    [[ "$confirm" == "" ]] && confirm="y"
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Настройка BGP отменена"
        return 1
    fi
    
    return 0
}

#===============================================================================
# УСТАНОВКА И НАСТРОЙКА FRR
#===============================================================================

install_frr() {
    print_section "УСТАНОВКА FRR"
    
    # Проверка установки
    if rpm -q frr &>/dev/null; then
        print_success "FRR уже установлен: $(rpm -q frr)"
        return 0
    fi
    
    print_info "Установка пакета FRR..."
    
    apt-get update &>/dev/null
    
    if apt-get install -y frr; then
        print_success "FRR успешно установлен"
        log_message "FRR установлен"
    else
        print_error "Не удалось установить FRR"
        return 1
    fi
}

configure_frr_daemons() {
    print_section "НАСТРОЙКА ДЕМОНОВ FRR"
    
    local daemons_file="/etc/frr/daemons"
    
    if [[ ! -f "$daemons_file" ]]; then
        print_error "Файл $daemons_file не найден"
        return 1
    fi
    
    # Резервное копирование
    cp "$daemons_file" "${daemons_file}.bak.$(date +%Y%m%d%H%M%S)"
    
    # Включаем нужные демоны
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        print_info "Включение OSPF демона (ospfd)..."
        sed -i 's/^ospfd=no/ospfd=yes/' "$daemons_file"
        sed -i 's/^#ospfd=yes/ospfd=yes/' "$daemons_file"
        
        # Если не включилось, добавляем
        if ! grep -q "^ospfd=yes" "$daemons_file"; then
            echo "ospfd=yes" >> "$daemons_file"
        fi
        print_success "OSPFD включен"
    fi
    
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        print_info "Включение BGP демона (bgpd)..."
        sed -i 's/^bgpd=no/bgpd=yes/' "$daemons_file"
        sed -i 's/^#bgpd=yes/bgpd=yes/' "$daemons_file"
        
        # Если не включилось, добавляем
        if ! grep -q "^bgpd=yes" "$daemons_file"; then
            echo "bgpd=yes" >> "$daemons_file"
        fi
        print_success "BGPD включен"
    fi
    
    log_message "Демоны настроены: $CONFIG_MODE"
}

configure_frr_service() {
    print_section "ЗАПУСК СЛУЖБЫ FRR"
    
    systemctl enable frr &>/dev/null
    systemctl restart frr
    
    sleep 2
    
    if systemctl is-active --quiet frr; then
        print_success "Служба FRR активна"
        log_message "Служба FRR запущена"
    else
        print_error "Служба FRR не запущена"
        systemctl status frr --no-pager
        return 1
    fi
}

configure_ospf_vtysh() {
    print_section "НАСТРОЙКА OSPF ЧЕРЕЗ VTYSH"
    
    print_info "Генерация конфигурации OSPF..."
    
    # Формируем команды
    local vtysh_cmds="configure terminal\n"
    vtysh_cmds+="router ospf\n"
    vtysh_cmds+="ospf router-id $ROUTER_ID\n"
    
    # Пассивные интерфейсы по умолчанию
    vtysh_cmds+="passive-interface default\n"
    
    # Добавляем сети
    for net in "${NETWORKS[@]}"; do
        vtysh_cmds+="network $net area 0\n"
    done
    
    # Аутентификация области
    vtysh_cmds+="area 0 authentication\n"
    vtysh_cmds+="exit\n"
    
    # Настройка интерфейса GRE
    if [[ -n "$GRE_INTERFACE" ]]; then
        vtysh_cmds+="interface $GRE_INTERFACE\n"
        vtysh_cmds+="no ip ospf passive\n"
        vtysh_cmds+="ip ospf authentication\n"
        vtysh_cmds+="ip ospf authentication-key $OSPF_PASSWORD\n"
        vtysh_cmds+="exit\n"
    fi
    
    vtysh_cmds+="exit\n"
    vtysh_cmds+="write\n"
    
    # Применяем
    print_info "Применение конфигурации OSPF..."
    echo -e "$vtysh_cmds" | vtysh
    
    if [[ $? -eq 0 ]]; then
        print_success "OSPF конфигурация применена"
        log_message "OSPF настроен: Router ID=$ROUTER_ID, сетей=${#NETWORKS[@]}"
    else
        print_error "Ошибка при настройке OSPF"
        return 1
    fi
}

configure_bgp_vtysh() {
    print_section "НАСТРОЙКА BGP ЧЕРЕЗ VTYSH"
    
    print_info "Генерация конфигурации BGP..."
    
    # Формируем команды
    local vtysh_cmds="configure terminal\n"
    vtysh_cmds+="router bgp $BGP_AS_LOCAL\n"
    vtysh_cmds+="bgp router-id $ROUTER_ID\n"
    vtysh_cmds+="neighbor $BGP_NEIGHBOR_IP remote-as $BGP_AS_REMOTE\n"
    
    # Для ISP - анонсируем default route
    if [[ "$ROUTER_ROLE" == "ISP" ]]; then
        vtysh_cmds+="address-family ipv4 unicast\n"
        vtysh_cmds+="neighbor $BGP_NEIGHBOR_IP default-originate\n"
        vtysh_cmds+="exit-address-family\n"
    fi
    
    vtysh_cmds+="exit\n"
    vtysh_cmds+="exit\n"
    vtysh_cmds+="write\n"
    
    # Применяем
    print_info "Применение конфигурации BGP..."
    echo -e "$vtysh_cmds" | vtysh
    
    if [[ $? -eq 0 ]]; then
        print_success "BGP конфигурация применена"
        log_message "BGP настроен: AS=$BGP_AS_LOCAL, neighbor=$BGP_NEIGHBOR_IP"
    else
        print_error "Ошибка при настройке BGP"
        return 1
    fi
}

#===============================================================================
# ПРОВЕРКА И ВЕРИФИКАЦИЯ
#===============================================================================

verify_ospf() {
    print_section "ПРОВЕРКА OSPF"
    
    echo -e "${CYAN}Текущая конфигурация FRR:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show running-config" 2>/dev/null | head -50
    echo "..."
    echo ""
    
    echo -e "${CYAN}Соседи OSPF:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip ospf neighbor" 2>/dev/null
    echo ""
    
    echo -e "${CYAN}Маршруты OSPF:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip ospf route" 2>/dev/null
    echo ""
    
    echo -e "${CYAN}Информация об OSPF:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip ospf" 2>/dev/null
}

verify_bgp() {
    print_section "ПРОВЕРКА BGP"
    
    echo -e "${CYAN}BGP Summary:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip bgp summary" 2>/dev/null
    echo ""
    
    echo -e "${CYAN}Таблица BGP:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip bgp" 2>/dev/null
    echo ""
    
    echo -e "${CYAN}Маршруты BGP:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    vtysh -c "show ip route bgp" 2>/dev/null
}

check_frr_status() {
    print_section "СТАТУС FRR"
    
    # Проверка службы
    echo -e "${CYAN}Состояние службы:${NC}"
    systemctl status frr --no-pager -l
    echo ""
    
    # Проверка демонов
    echo -e "${CYAN}Активные демоны:${NC}"
    for daemon in zebra ospfd bgpd ripd isisd; do
        if pgrep -x "$daemon" &>/dev/null; then
            echo -e "  ${GREEN}●${NC} $daemon - запущен"
        else
            echo -e "  ${RED}○${NC} $daemon - остановлен"
        fi
    done
    echo ""
    
    # Текущая конфигурация
    echo -e "${CYAN}Текущая конфигурация:${NC}"
    vtysh -c "show running-config" 2>/dev/null
}

reset_frr_config() {
    print_section "СБРОС КОНФИГУРАЦИИ FRR"
    
    print_warning "Это действие удалит всю конфигурацию FRR!"
    read -p "Продолжить? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        print_info "Операция отменена"
        return 0
    fi
    
    # Остановка службы
    print_info "Остановка FRR..."
    systemctl stop frr
    
    # Сброс конфигурации
    print_info "Удаление конфигурации..."
    rm -f /etc/frr/frr.conf
    rm -f /etc/frr/zebra.conf
    rm -f /etc/frr/ospfd.conf
    rm -f /etc/frr/bgpd.conf
    
    # Отключение демонов
    sed -i 's/^ospfd=yes/ospfd=no/' /etc/frr/daemons
    sed -i 's/^bgpd=yes/bgpd=no/' /etc/frr/daemons
    
    # Запуск
    systemctl start frr
    
    print_success "Конфигурация FRR сброшена"
    log_message "Конфигурация FRR сброшена"
}

#===============================================================================
# ГЕНЕРАЦИЯ ОТЧЁТА
#===============================================================================

generate_report() {
    print_section "ГЕНЕРАЦИЯ ОТЧЁТА"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(get_hostname)
    local frr_version=$(vtysh -c "show version" 2>/dev/null | head -1)
    
    local report="
═══════════════════════════════════════════════════════════════════════════════
                         ОТЧЁТ О НАСТРОЙКЕ FRR
                    Free Range Routing - ALT Linux
═══════════════════════════════════════════════════════════════════════════════

Дата и время: $timestamp
Имя хоста: $hostname

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. ОБЩИЕ СВЕДЕНИЯ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Роль маршрутизатора: $ROUTER_ROLE
Режим настройки: $CONFIG_MODE
Версия FRR: $frr_version
Router ID: $ROUTER_ID
"
    
    # OSPF секция
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        report+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2. НАСТРОЙКА GRE ТУННЕЛЯ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Интерфейс GRE: $GRE_INTERFACE
IP-адрес GRE: $GRE_IP
Сеть GRE туннеля: $GRE_NETWORK
Локальный внешний IP: ${GRE_LOCAL_IP:-N/A}
Удалённый внешний IP: ${GRE_REMOTE_IP:-N/A}
Ключ туннеля: ${GRE_KEY:-не задан}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3. НАСТРОЙКА OSPF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Протокол: OSPFv2 (Open Shortest Path First)
Тип протокола: Link State
Номер области (Area): 0 (Backbone)
Пароль аутентификации: $OSPF_PASSWORD

Анонсируемые сети:
"
        for net in "${NETWORKS[@]}"; do
            report+="  • $net\n"
        done
    fi
    
    # BGP секция
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        report+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4. НАСТРОЙКА BGP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Номер локальной AS: $BGP_AS_LOCAL
Номер AS соседа: $BGP_AS_REMOTE
IP-адрес соседа: $BGP_NEIGHBOR_IP
"
    fi
    
    # Конфигурация FRR
    report+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5. КОНФИГУРАЦИЯ FRR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"
    report+=$(vtysh -c "show running-config" 2>/dev/null)
    
    report+="

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
6. КОМАНДЫ ПРОВЕРКИ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# OSPF:
vtysh -c \"show ip ospf neighbor\"
vtysh -c \"show ip ospf route\"
vtysh -c \"show ip route ospf\"

# BGP:
vtysh -c \"show ip bgp summary\"
vtysh -c \"show ip bgp\"
vtysh -c \"show ip route bgp\"

# Проверка связности:
ping <IP_удалённой_сети>

═══════════════════════════════════════════════════════════════════════════════
"
    
    # Сохранение
    echo -e "$report" > "$REPORT_FILE"
    print_success "Отчёт сохранён: $REPORT_FILE"
    
    # HTML версия
    generate_html_report
    
    log_message "Отчёт сохранён: $REPORT_FILE"
}

generate_html_report() {
    local html_file="/root/frr-config-report.html"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(get_hostname)
    local frr_config=$(vtysh -c "show running-config" 2>/dev/null)
    
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Отчёт FRR - $ROUTER_ROLE</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; max-width: 1000px; margin: 0 auto; padding: 20px; background: #f5f5f5; }
        .header { background: linear-gradient(135deg, #1a5276, #2980b9); color: white; padding: 30px; border-radius: 10px; margin-bottom: 20px; }
        .header h1 { margin: 0; }
        .section { background: white; border-radius: 10px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .section h2 { color: #1a5276; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .info-grid { display: grid; grid-template-columns: 200px 1fr; gap: 10px; }
        .info-label { font-weight: bold; color: #2c3e50; }
        pre { background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 5px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Отчёт о настройке FRR</h1>
        <p>$ROUTER_ROLE - $timestamp</p>
    </div>
    
    <div class="section">
        <h2>1. Общие сведения</h2>
        <div class="info-grid">
            <div class="info-label">Имя хоста:</div><div>$hostname</div>
            <div class="info-label">Роль:</div><div>$ROUTER_ROLE</div>
            <div class="info-label">Router ID:</div><div>$ROUTER_ID</div>
            <div class="info-label">Режим:</div><div>$CONFIG_MODE</div>
        </div>
    </div>
    
    <div class="section">
        <h2>2. Конфигурация FRR</h2>
        <pre>$frr_config</pre>
    </div>
    
    <div class="section">
        <h2>3. Команды проверки</h2>
        <pre>
# OSPF:
vtysh -c "show ip ospf neighbor"
vtysh -c "show ip ospf route"

# BGP:
vtysh -c "show ip bgp summary"
vtysh -c "show ip route bgp"
        </pre>
    </div>
</body>
</html>
EOF
    
    print_success "HTML отчёт: $html_file"
}

#===============================================================================
# СВОДКА И ПОДТВЕРЖДЕНИЕ
#===============================================================================

show_summary() {
    print_section "СВОДКА КОНФИГУРАЦИИ"
    
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Режим настройки" "$CONFIG_MODE"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Роль маршрутизатора" "$ROUTER_ROLE"
    printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Router ID" "$ROUTER_ID"
    
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "GRE интерфейс" "$GRE_INTERFACE"
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "GRE IP-адрес" "$GRE_IP"
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Пароль OSPF" "$OSPF_PASSWORD"
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Количество сетей" "${#NETWORKS[@]}"
    fi
    
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "Локальная AS" "$BGP_AS_LOCAL"
        printf "${CYAN}│${NC} %-28s │ %-28s ${CYAN}│${NC}\n" "IP BGP соседа" "$BGP_NEIGHBOR_IP"
    fi
    
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
}

confirm_and_apply() {
    echo ""
    read -p "Применить конфигурацию? (y/n) [y]: " confirm
    [[ "$confirm" == "" ]] && confirm="y"
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Настройка отменена"
        exit 0
    fi
}

#===============================================================================
# ОСНОВНАЯ ФУНКЦИЯ
#===============================================================================

main() {
    # Инициализация
    print_header
    check_root
    check_alt_linux
    
    # Отображение интерфейсов
    list_interfaces_with_details
    
    # Главное меню
    show_main_menu
    
    # Выбор роли
    select_router_role
    
    # Настройка OSPF
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        select_gre_interface
        select_networks_ospf
        select_ospf_password
    fi
    
    # Настройка BGP
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        configure_bgp_interactive
    fi
    
    # Router ID (если ещё не задан)
    if [[ -z "$ROUTER_ID" ]]; then
        select_router_id
    fi
    
    # Сводка и подтверждение
    show_summary
    confirm_and_apply
    
    # Установка FRR
    install_frr
    configure_frr_daemons
    configure_frr_service
    
    # Пауза для инициализации
    print_info "Ожидание инициализации FRR..."
    sleep 3
    
    # Применение конфигурации
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        configure_ospf_vtysh
    fi
    
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        configure_bgp_vtysh
    fi
    
    # Верификация
    if [[ "$CONFIG_MODE" == "ospf" || "$CONFIG_MODE" == "both" ]]; then
        verify_ospf
    fi
    
    if [[ "$CONFIG_MODE" == "bgp" || "$CONFIG_MODE" == "both" ]]; then
        verify_bgp
    fi
    
    # Отчёт
    generate_report
    
    # Финал
    print_section "НАСТРОЙКА ЗАВЕРШЕНА"
    print_success "FRR успешно настроен!"
    echo ""
    print_info "Отчёты сохранены:"
    echo "  • Текстовый: $REPORT_FILE"
    echo "  • HTML: /root/frr-config-report.html"
    echo ""
    print_info "Полезные команды:"
    echo "  vtysh -c 'show ip ospf neighbor'   # Соседи OSPF"
    echo "  vtysh -c 'show ip bgp summary'     # Статус BGP"
    echo "  vtysh -c 'show ip route'           # Таблица маршрутизации"
    echo ""
}

#===============================================================================
# ЗАПУСК
#===============================================================================

main "$@"
