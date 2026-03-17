#!/bin/bash
#===============================================================================
# Скрипт настройки OSPF динамической маршрутизации для ALT Linux
# Задание 7: Обеспечение динамической маршрутизации между офисами
# Включает: создание GRE туннеля (если не существует) + настройка OSPF
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Файлы
LOG_FILE="/var/log/ospf-setup.log"
REPORT_FILE="/root/ospf-config-report.txt"
INTERFACES_FILE="/etc/net/interfaces"

# Глобальные переменные
ROUTER_ROLE=""
ROUTER_ID=""
GRE_INTERFACE=""
GRE_IP=""
GRE_NETWORK=""
GRE_REMOTE_IP=""
GRE_LOCAL_IP=""
GRE_KEY=""
OSPF_PASSWORD=""
NETWORKS=()
CREATE_GRE=false

#===============================================================================
# Функции вывода
#===============================================================================

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║     НАСТРОЙКА OSPF ДИНАМИЧЕСКОЙ МАРШРУТИЗАЦИИ - ALT LINUX           ║"
    echo "║                  Задание 7: Link State Protocol                      ║"
    echo "║                                                                      ║"
    echo "║   Функции скрипта:                                                   ║"
    echo "║   • Создание GRE туннеля (если не существует)                        ║"
    echo "║   • Настройка OSPF с аутентификацией                                 ║"
    echo "║   • Автоматическое определение сетей                                 ║"
    echo "║   • Генерация отчёта                                                 ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
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

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

#===============================================================================
# Функции определения системы
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен от имени root"
        exit 1
    fi
}

check_alt_linux() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "altlinux" && "$ID" != "alt" ]]; then
            print_warning "Обнаружена система: $PRETTY_NAME"
            print_warning "Скрипт оптимизирован для ALT Linux"
            read -p "Продолжить? (y/n): " continue_choice
            [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]] && exit 0
        else
            print_success "Обнаружена ALT Linux: $PRETTY_NAME"
        fi
    else
        print_warning "Не удалось определить ОС"
    fi
}

get_hostname() {
    hostname -f 2>/dev/null || hostname
}

#===============================================================================
# Функции определения интерфейсов и IP-адресов
#===============================================================================

get_all_interfaces() {
    ls /sys/class/net/ | grep -v "^lo$"
}

get_external_interfaces() {
    # Возвращаем интерфейсы, которые НЕ являются GRE/TUN
    for iface in $(get_all_interfaces); do
        if [[ ! "$iface" =~ ^gre[0-9]+$ ]] && [[ ! "$iface" =~ ^tun[0-9]+$ ]]; then
            echo "$iface"
        fi
    done
}

get_interface_ip() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+'
}

get_interface_network() {
    local iface=$1
    local ip_info=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet [\d./]+')
    if [[ -n "$ip_info" ]]; then
        local ip=$(echo "$ip_info" | grep -oP '[\d.]+(?=/)')
        local cidr=$(echo "$ip_info" | grep -oP '(?<=/)\d+')
        if [[ -n "$ip" && -n "$cidr" ]]; then
            # Вычисляем сеть
            local mask=$((32 - cidr))
            local ip_parts=(${ip//./ })
            local ip_num=$((ip_parts[0] << 24 | ip_parts[1] << 16 | ip_parts[2] << 8 | ip_parts[3]))
            local mask_num=$(((0xFFFFFFFF << mask) & 0xFFFFFFFF))
            local network_num=$((ip_num & mask_num))
            echo "$((network_num >> 24 & 0xFF)).$((network_num >> 16 & 0xFF)).$((network_num >> 8 & 0xFF)).$((network_num & 0xFF))/$cidr"
        fi
    fi
}

get_interface_mask() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=/)\d+'
}

find_gre_interface() {
    for iface in $(get_all_interfaces); do
        if [[ "$iface" =~ ^gre[0-9]+$ ]] || [[ "$iface" =~ ^tun[0-9]+$ ]]; then
            echo "$iface"
            return 0
        fi
    done
    return 1
}

check_gre_exists() {
    local iface=$1
    ip link show "$iface" &>/dev/null
    return $?
}

list_interfaces_with_details() {
    print_section "Обнаруженные сетевые интерфейсы"
    echo -e "${CYAN}Интерфейс\tIP-адрес\t\tСеть${NC}"
    echo "────────────────────────────────────────────────────────────────────"
    
    for iface in $(get_all_interfaces); do
        local ip=$(get_interface_ip "$iface")
        local network=$(get_interface_network "$iface")
        if [[ -n "$ip" ]]; then
            local iface_type=""
            if [[ "$iface" =~ ^gre[0-9]+$ ]]; then
                iface_type=" (GRE)"
            elif [[ "$iface" =~ ^tun[0-9]+$ ]]; then
                iface_type=" (TUN)"
            fi
            printf "%-12s\t%-16s\t%s%s\n" "$iface" "$ip" "$network" "$iface_type"
        fi
    done
    echo ""
}

#===============================================================================
# Функции создания GRE туннеля
#===============================================================================

create_gre_tunnel_interactive() {
    print_section "Создание GRE туннеля"
    
    echo -e "${YELLOW}GRE туннель не обнаружен. Необходимо его создать.${NC}"
    echo ""
    
    # Имя интерфейса
    local default_iface="gre1"
    print_menu "Шаг 1: Имя интерфейса GRE туннеля"
    echo "  Рекомендуемое имя: $default_iface"
    read -p "  Имя интерфейса [$default_iface]: " input_iface
    GRE_INTERFACE="${input_iface:-$default_iface}"
    
    # Проверяем, не существует ли уже такой интерфейс
    if check_gre_exists "$GRE_INTERFACE"; then
        print_error "Интерфейс $GRE_INTERFACE уже существует!"
        return 1
    fi
    
    echo ""
    print_menu "Шаг 2: Локальный внешний IP-адрес"
    echo "  Доступные внешние интерфейсы:"
    local i=1
    declare -A iface_map
    for iface in $(get_external_interfaces); do
        local ip=$(get_interface_ip "$iface")
        if [[ -n "$ip" ]]; then
            echo "    $i) $iface - $ip"
            iface_map[$i]="$ip|$iface"
            ((i++))
        fi
    done
    
    local default_local_ip=""
    if [[ ${#iface_map[@]} -gt 0 ]]; then
        default_local_ip=$(echo "${iface_map[1]}" | cut -d'|' -f1)
    fi
    
    read -p "  Локальный внешний IP [$default_local_ip]: " input_local
    GRE_LOCAL_IP="${input_local:-$default_local_ip}"
    
    echo ""
    print_menu "Шаг 3: Удалённый внешний IP-адрес (маршрутизатор другого офиса)"
    
    # Предлагаем типичные IP в зависимости от роли
    local suggested_remote=""
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_remote="172.16.2.1"
            echo "  Подсказка: Для HQ-RTR удалённый IP обычно BR-RTR (например: 172.16.2.1)"
            ;;
        "BR-RTR")
            suggested_remote="172.16.1.1"
            echo "  Подсказка: Для BR-RTR удалённый IP обычно HQ-RTR (например: 172.16.1.1)"
            ;;
    esac
    
    read -p "  Удалённый внешний IP [$suggested_remote]: " input_remote
    GRE_REMOTE_IP="${input_remote:-$suggested_remote}"
    
    echo ""
    print_menu "Шаг 4: Внутренний IP-адрес GRE туннеля"
    
    # Предлагаем IP на основе роли
    local suggested_gre_ip=""
    local suggested_gre_network=""
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_gre_ip="10.10.0.1/30"
            suggested_gre_network="10.10.0.0/30"
            echo "  Подсказка: Для HQ-RTR обычно используется 10.10.0.1/30"
            ;;
        "BR-RTR")
            suggested_gre_ip="10.10.0.2/30"
            suggested_gre_network="10.10.0.0/30"
            echo "  Подсказка: Для BR-RTR обычно используется 10.10.0.2/30"
            ;;
    esac
    
    read -p "  Внутренний IP GRE туннеля [$suggested_gre_ip]: " input_gre_ip
    GRE_IP="${input_gre_ip:-$suggested_gre_ip}"
    
    # Извлекаем сеть из IP
    if [[ "$GRE_IP" =~ / ]]; then
        GRE_NETWORK=$(echo "$GRE_IP" | sed 's/\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\..*/\1.\2.\3.0\/30/')
    else
        GRE_NETWORK="${suggested_gre_network}"
    fi
    
    echo ""
    print_menu "Шаг 5: Ключ GRE туннеля (опционально)"
    echo "  Ключ обеспечивает дополнительную защиту туннеля"
    read -p "  Ключ туннеля (оставьте пустым если не требуется): " GRE_KEY
    
    # Подтверждение
    echo ""
    print_section "Параметры GRE туннеля"
    echo -e "${CYAN}"
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│                    КОНФИГУРАЦИЯ GRE ТУННЕЛЯ                     │"
    echo "├─────────────────────────────────────────────────────────────────┤"
    printf "│ %-30s │ %-30s │\n" "Имя интерфейса" "$GRE_INTERFACE"
    printf "│ %-30s │ %-30s │\n" "Локальный внешний IP" "$GRE_LOCAL_IP"
    printf "│ %-30s │ %-30s │\n" "Удалённый внешний IP" "$GRE_REMOTE_IP"
    printf "│ %-30s │ %-30s │\n" "Внутренний IP туннеля" "$GRE_IP"
    printf "│ %-30s │ %-30s │\n" "Ключ туннеля" "${GRE_KEY:-не задан}"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    
    read -p "Создать GRE туннель с этими параметрами? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Создание GRE туннеля отменено"
        return 1
    fi
    
    # Создание туннеля
    create_gre_tunnel
    
    return $?
}

create_gre_tunnel() {
    print_section "Создание GRE туннеля"
    
    print_info "Создание интерфейса $GRE_INTERFACE..."
    
    # Метод 1: Через ip command (временно, до перезагрузки)
    local ip_cmd="ip tunnel add $GRE_INTERFACE mode gre local $GRE_LOCAL_IP remote $GRE_REMOTE_IP"
    if [[ -n "$GRE_KEY" ]]; then
        ip_cmd+=" key $GRE_KEY"
    fi
    
    if eval "$ip_cmd"; then
        print_success "GRE интерфейс создан"
    else
        print_error "Не удалось создать GRE интерфейс"
        return 1
    fi
    
    # Устанавливаем IP адрес
    print_info "Настройка IP адреса..."
    ip addr add "$GRE_IP" dev "$GRE_INTERFACE"
    ip link set "$GRE_INTERFACE" up
    
    if check_gre_exists "$GRE_INTERFACE"; then
        print_success "GRE туннель активирован"
        
        # Показать статус
        ip addr show "$GRE_INTERFACE"
    else
        print_error "Не удалось активировать GRE туннель"
        return 1
    fi
    
    # Метод 2: Постоянная конфигурация через /etc/net/interfaces
    print_info "Создание постоянной конфигурации..."
    create_gre_permanent_config
    
    log_message "GRE туннель создан: $GRE_INTERFACE"
    CREATE_GRE=true
    
    return 0
}

create_gre_permanent_config() {
    # Резервное копирование
    cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    
    # Формируем конфигурацию для ALT Linux /etc/net/interfaces
    local gre_config="
# GRE Tunnel - added by ospf-setup script
iface $GRE_INTERFACE inet static
    address ${GRE_IP%/*}
    netmask 255.255.255.252
    pre-up ip tunnel add $GRE_INTERFACE mode gre local $GRE_LOCAL_IP remote $GRE_REMOTE_IP"
    
    if [[ -n "$GRE_KEY" ]]; then
        gre_config+=" key $GRE_KEY"
    fi
    
    gre_config+="
    post-down ip tunnel del $GRE_INTERFACE
"
    
    # Добавляем в файл
    echo "$gre_config" >> "$INTERFACES_FILE"
    
    print_success "Постоянная конфигурация добавлена в $INTERFACES_FILE"
    
    # Также создаём systemd сервис для восстановления после перезагрузки
    create_gre_systemd_service
}

create_gre_systemd_service() {
    local service_file="/etc/systemd/system/gre-tunnel.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=GRE Tunnel $GRE_INTERFACE
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ip tunnel add $GRE_INTERFACE mode gre local $GRE_LOCAL_IP remote $GRE_REMOTE_IP ${GRE_KEY:+key $GRE_KEY}
ExecStart=/usr/bin/ip addr add $GRE_IP dev $GRE_INTERFACE
ExecStart=/usr/bin/ip link set $GRE_INTERFACE up
ExecStop=/usr/bin/ip tunnel del $GRE_INTERFACE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gre-tunnel.service
    
    print_success "Systemd сервис для GRE туннеля создан и включён"
}

select_gre_interface() {
    print_section "Выбор GRE туннеля"
    
    # Автоматический поиск GRE интерфейса
    local auto_gre=$(find_gre_interface)
    
    if [[ -n "$auto_gre" ]]; then
        print_success "Обнаружен существующий GRE интерфейс: $auto_gre"
        GRE_INTERFACE="$auto_gre"
        GRE_IP=$(get_interface_ip "$GRE_INTERFACE")
        GRE_NETWORK=$(get_interface_network "$GRE_INTERFACE")
        
        echo -e "\nДетали GRE туннеля:"
        echo "  Интерфейс: $GRE_INTERFACE"
        echo "  IP-адрес: $GRE_IP"
        echo "  Сеть: $GRE_NETWORK"
        
        read -p "Использовать этот интерфейс? (y/n) [y]: " use_auto
        [[ "$use_auto" == "" ]] && use_auto="y"
        
        if [[ "$use_auto" == "y" || "$use_auto" == "Y" ]]; then
            print_success "Выбран GRE интерфейс: $GRE_INTERFACE"
            CREATE_GRE=false
            return 0
        fi
    fi
    
    # GRE не найден - предлагаем создать
    print_warning "GRE интерфейс не обнаружен"
    echo ""
    echo "Доступные действия:"
    echo "  1) Создать новый GRE туннель"
    echo "  2) Указать имя существующего интерфейса вручную"
    echo "  3) Отмена"
    echo ""
    
    read -p "Выберите действие [1]: " action
    [[ "$action" == "" ]] && action="1"
    
    case $action in
        1)
            create_gre_tunnel_interactive
            return $?
            ;;
        2)
            read -p "Введите имя интерфейса (например, gre1): " GRE_INTERFACE
            if check_gre_exists "$GRE_INTERFACE"; then
                GRE_IP=$(get_interface_ip "$GRE_INTERFACE")
                GRE_NETWORK=$(get_interface_network "$GRE_INTERFACE")
                print_success "Выбран интерфейс: $GRE_INTERFACE"
                CREATE_GRE=false
                return 0
            else
                print_error "Интерфейс $GRE_INTERFACE не существует"
                return 1
            fi
            ;;
        3)
            print_warning "Отмена настройки"
            exit 0
            ;;
        *)
            print_error "Неверный выбор"
            return 1
            ;;
    esac
}

#===============================================================================
# Интерактивные функции выбора
#===============================================================================

select_router_role() {
    print_section "Выбор роли маршрутизатора"
    
    echo "Выберите роль данного маршрутизатора:"
    echo -e "  ${GREEN}1)${NC} HQ-RTR (Маршрутизатор главного офиса)"
    echo -e "  ${GREEN}2)${NC} BR-RTR (Маршрутизатор филиала)"
    echo ""
    
    local valid_choice=false
    while [[ "$valid_choice" == false ]]; do
        read -p "Ваш выбор [1]: " role_choice
        [[ "$role_choice" == "" ]] && role_choice="1"
        
        case $role_choice in
            1)
                ROUTER_ROLE="HQ-RTR"
                valid_choice=true
                ;;
            2)
                ROUTER_ROLE="BR-RTR"
                valid_choice=true
                ;;
            *)
                print_error "Неверный выбор. Введите 1 или 2."
                ;;
        esac
    done
    
    print_success "Выбрана роль: $ROUTER_ROLE"
    log_message "Выбрана роль: $ROUTER_ROLE"
}

select_networks() {
    print_section "Выбор сетей для OSPF"
    print_info "Выберите сети, которые будут анонсироваться через OSPF"
    print_warning "GRE туннель будет добавлен автоматически"
    echo ""
    
    NETWORKS=()
    local interfaces=($(get_all_interfaces))
    
    echo "Доступные сети:"
    echo "────────────────────────────────────────────────────────────────────"
    
    local network_list=()
    local i=1
    
    for iface in "${interfaces[@]}"; do
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" == "$GRE_INTERFACE" ]] && continue  # GRE добавим позже
        
        local network=$(get_interface_network "$iface")
        local ip=$(get_interface_ip "$iface")
        
        if [[ -n "$network" ]]; then
            network_list+=("$network|$iface|$ip")
            echo "  $i) $network (интерфейс: $iface, IP: $ip)"
            ((i++))
        fi
    done
    
    echo ""
    echo -e "${YELLOW}Автоматический выбор сетей на основе роли $ROUTER_ROLE${NC}"
    read -p "Использовать автоматический выбор? (y/n) [y]: " auto_select
    [[ "$auto_select" == "" ]] && auto_select="y"
    
    if [[ "$auto_select" == "y" || "$auto_select" == "Y" ]]; then
        # Автоматически выбираем все сети кроме внешних
        for net_info in "${network_list[@]}"; do
            local network=$(echo "$net_info" | cut -d'|' -f1)
            NETWORKS+=("$network")
        done
        print_success "Автоматически выбраны сети: ${NETWORKS[*]}"
    else
        # Ручной выбор
        print_info "Введите номера сетей через запятую (например: 1,2,3) или 'all' для всех:"
        read -p "Выбор: " selection
        
        if [[ "$selection" == "all" ]]; then
            for net_info in "${network_list[@]}"; do
                NETWORKS+=("$(echo "$net_info" | cut -d'|' -f1)")
            done
        else
            IFS=',' read -ra selections <<< "$selection"
            for idx in "${selections[@]}"; do
                idx=$(echo "$idx" | tr -d ' ')
                if [[ $idx -ge 1 && $idx -le ${#network_list[@]} ]]; then
                    NETWORKS+=("$(echo "${network_list[$((idx-1))]}" | cut -d'|' -f1)")
                fi
            done
        fi
    fi
    
    # Добавляем сеть GRE туннеля
    if [[ -n "$GRE_NETWORK" ]]; then
        NETWORKS+=("$GRE_NETWORK")
        print_info "Добавлена сеть GRE туннеля: $GRE_NETWORK"
    fi
    
    print_success "Итого сетей для OSPF: ${#NETWORKS[@]}"
    for net in "${NETWORKS[@]}"; do
        echo "  - $net"
    done
}

select_router_id() {
    print_section "Настройка Router ID"
    
    # Предлагаем IP на основе роли
    local suggested_id=""
    case $ROUTER_ROLE in
        "HQ-RTR")
            suggested_id="172.16.1.1"
            ;;
        "BR-RTR")
            suggested_id="172.16.2.1"
            ;;
    esac
    
    echo "Рекомендуемый Router ID для $ROUTER_ROLE: $suggested_id"
    read -p "Router ID [$suggested_id]: " input_id
    ROUTER_ID="${input_id:-$suggested_id}"
    
    print_success "Router ID установлен: $ROUTER_ID"
    log_message "Router ID: $ROUTER_ID"
}

select_ospf_password() {
    print_section "Настройка аутентификации OSPF"
    print_warning "Аутентификация обязательна для защиты OSPF"
    echo ""
    
    local default_pass="P@ssw0rd"
    read -p "Пароль для OSPF аутентификации [$default_pass]: " input_pass
    OSPF_PASSWORD="${input_pass:-$default_pass}"
    
    print_success "Пароль OSPF установлен"
    log_message "Пароль OSPF настроен"
}

#===============================================================================
# Функции установки и настройки FRR
#===============================================================================

install_frr() {
    print_section "Установка FRR (Free Range Routing)"
    
    # Проверяем, установлен ли FRR
    if rpm -q frr &>/dev/null; then
        print_success "FRR уже установлен: $(rpm -q frr)"
        return 0
    fi
    
    print_info "Установка FRR..."
    
    # Обновление репозиториев и установка
    apt-get update
    
    if apt-get install -y frr; then
        print_success "FRR успешно установлен"
        log_message "FRR установлен"
    else
        print_error "Не удалось установить FRR"
        return 1
    fi
}

configure_frr_daemons() {
    print_section "Настройка демонов FRR"
    
    local daemons_file="/etc/frr/daemons"
    
    # Проверяем наличие файла
    if [[ ! -f "$daemons_file" ]]; then
        print_error "Файл $daemons_file не найден"
        return 1
    fi
    
    # Включаем OSPF
    print_info "Включение OSPF демона..."
    sed -i 's/^ospfd=no/ospfd=yes/' "$daemons_file"
    sed -i 's/^#ospfd=yes/ospfd=yes/' "$daemons_file"
    
    # Проверяем результат
    if grep -q "^ospfd=yes" "$daemons_file"; then
        print_success "OSPF демон включен"
        log_message "ospfd=yes в $daemons_file"
    else
        print_warning "Не удалось включить OSPF, добавляем вручную..."
        echo "ospfd=yes" >> "$daemons_file"
    fi
}

configure_frr_service() {
    print_section "Настройка службы FRR"
    
    # Включаем и запускаем службу
    systemctl enable frr
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

configure_ospf() {
    print_section "Настройка OSPF"
    
    print_info "Генерация конфигурации OSPF..."
    
    # Формируем команды для vtysh
    local vtysh_commands="
configure terminal
router ospf
ospf router-id $ROUTER_ID
"
    
    # Добавляем сети
    for net in "${NETWORKS[@]}"; do
        vtysh_commands+="network $net area 0
"
    done
    
    # Добавляем аутентификацию
    vtysh_commands+="area 0 authentication
exit
interface $GRE_INTERFACE
ip ospf authentication
ip ospf authentication-key $OSPF_PASSWORD
ip ospf network broadcast
no ip ospf passive
exit
exit
write
"
    
    # Применяем конфигурацию
    print_info "Применение конфигурации..."
    echo "$vtysh_commands" | vtysh
    
    if [[ $? -eq 0 ]]; then
        print_success "OSPF конфигурация применена"
        log_message "OSPF настроен с Router ID: $ROUTER_ID"
    else
        print_error "Ошибка при применении OSPF конфигурации"
        return 1
    fi
}

verify_ospf() {
    print_section "Проверка OSPF"
    
    print_info "Текущая конфигурация FRR:"
    echo "────────────────────────────────────────────────────────────────────"
    vtysh -c "show running-config" 2>/dev/null
    echo "────────────────────────────────────────────────────────────────────"
    
    echo ""
    print_info "Проверка соседей OSPF:"
    vtysh -c "show ip ospf neighbor" 2>/dev/null
    
    echo ""
    print_info "Таблица маршрутов OSPF:"
    vtysh -c "show ip ospf route" 2>/dev/null
    
    echo ""
    print_info "Информация об OSPF:"
    vtysh -c "show ip ospf" 2>/dev/null
}

#===============================================================================
# Генерация отчёта
#===============================================================================

generate_report() {
    print_section "Генерация отчёта"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(get_hostname)
    local frr_version=$(vtysh -c "show version" 2>/dev/null | head -1)
    
    local report_content="
═══════════════════════════════════════════════════════════════════════════════
                         ОТЧЁТ О НАСТРОЙКЕ OSPF
                    Динамическая маршрутизация между офисами
═══════════════════════════════════════════════════════════════════════════════

Дата и время: $timestamp
Имя хоста: $hostname

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. ОБЩИЕ СВЕДЕНИЯ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Роль маршрутизатора: $ROUTER_ROLE
Версия FRR: $frr_version
Router ID: $ROUTER_ID

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2. НАСТРОЙКА GRE ТУННЕЛЯ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Интерфейс GRE: $GRE_INTERFACE
IP-адрес GRE: $GRE_IP
Сеть GRE туннеля: $GRE_NETWORK
Локальный внешний IP: ${GRE_LOCAL_IP:-N/A}
Удалённый внешний IP: ${GRE_REMOTE_IP:-N/A}
Ключ туннеля: ${GRE_KEY:-не задан}
GRE создан скриптом: $CREATE_GRE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3. НАСТРОЙКА OSPF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Протокол: OSPFv2 (Open Shortest Path First)
Тип протокола: Link State
Номер области (Area): 0 (Backbone)

Анонсируемые сети:
"
    
    for net in "${NETWORKS[@]}"; do
        report_content+="  • $net
"
    done
    
    report_content+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4. ЗАЩИТА ПРОТОКОЛА OSPF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Тип аутентификации: Simple Password (Type 1)
Пароль: $OSPF_PASSWORD
Применено на интерфейсе: $GRE_INTERFACE

Команды настройки аутентификации:
  router ospf
    area 0 authentication
  interface $GRE_INTERFACE
    ip ospf authentication
    ip ospf authentication-key $OSPF_PASSWORD

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5. КОНФИГУРАЦИЯ FRR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"
    
    # Получаем текущую конфигурацию
    local frr_config=$(vtysh -c "show running-config" 2>/dev/null)
    report_content+="$frr_config

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
6. СОСЕДИ OSPF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"
    
    local ospf_neighbors=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)
    report_content+="$ospf_neighbors

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
7. МАРШРУТЫ OSPF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"
    
    local ospf_routes=$(vtysh -c "show ip ospf route" 2>/dev/null)
    report_content+="$ospf_routes

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
8. ПРИМЕЧАНИЯ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

• OSPF настроен только на GRE интерфейсе (динамическая маршрутизация через туннель)
• Аутентификация обеспечивает защиту от несанкционированных маршрутизаторов
• Маршрутизаторы обмениваются маршрутами только через защищённый туннель
• Passive интерфейсы не участвуют в OSPF (только анонсируют сети)

Для проверки связности выполните:
  ping <IP_адрес_удалённой_сети>

Для просмотра состояния OSPF:
  vtysh -c \"show ip ospf neighbor\"
  vtysh -c \"show ip ospf route\"
  vtysh -c \"show ip route ospf\"

═══════════════════════════════════════════════════════════════════════════════
                          КОНЕЦ ОТЧЁТА
═══════════════════════════════════════════════════════════════════════════════
"
    
    # Сохраняем отчёт
    echo "$report_content" > "$REPORT_FILE"
    print_success "Отчёт сохранён: $REPORT_FILE"
    log_message "Отчёт сохранён в $REPORT_FILE"
    
    # Также создаём HTML версию отчёта
    generate_html_report
}

generate_html_report() {
    local html_file="/root/ospf-config-report.html"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(get_hostname)
    local frr_config=$(vtysh -c "show running-config" 2>/dev/null)
    local ospf_neighbors=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)
    
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Отчёт о настройке OSPF - $ROUTER_ROLE</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            max-width: 1000px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
            color: #333;
        }
        .header {
            background: linear-gradient(135deg, #1a5276, #2980b9);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 20px;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 28px;
        }
        .header p {
            margin: 10px 0 0 0;
            opacity: 0.9;
        }
        .section {
            background: white;
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .section h2 {
            color: #1a5276;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
            margin-top: 0;
        }
        .info-grid {
            display: grid;
            grid-template-columns: 200px 1fr;
            gap: 10px;
        }
        .info-label {
            font-weight: bold;
            color: #2c3e50;
        }
        .info-value {
            color: #555;
        }
        .network-list {
            list-style: none;
            padding: 0;
        }
        .network-list li {
            padding: 8px 15px;
            background: #ecf0f1;
            margin: 5px 0;
            border-radius: 5px;
            border-left: 4px solid #3498db;
        }
        pre {
            background: #2c3e50;
            color: #ecf0f1;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-size: 13px;
        }
        .status-ok {
            color: #27ae60;
            font-weight: bold;
        }
        .warning {
            background: #fcf8e3;
            border: 1px solid #faebcc;
            padding: 15px;
            border-radius: 5px;
            color: #8a6d3b;
        }
        .footer {
            text-align: center;
            color: #7f8c8d;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Отчёт о настройке OSPF</h1>
        <p>Динамическая маршрутизация между офисами</p>
    </div>
    
    <div class="section">
        <h2>1. Общие сведения</h2>
        <div class="info-grid">
            <div class="info-label">Дата и время:</div>
            <div class="info-value">$timestamp</div>
            <div class="info-label">Имя хоста:</div>
            <div class="info-value">$hostname</div>
            <div class="info-label">Роль маршрутизатора:</div>
            <div class="info-value">$ROUTER_ROLE</div>
            <div class="info-label">Router ID:</div>
            <div class="info-value">$ROUTER_ID</div>
        </div>
    </div>
    
    <div class="section">
        <h2>2. Настройка GRE туннеля</h2>
        <div class="info-grid">
            <div class="info-label">Интерфейс:</div>
            <div class="info-value">$GRE_INTERFACE</div>
            <div class="info-label">IP-адрес:</div>
            <div class="info-value">$GRE_IP</div>
            <div class="info-label">Сеть туннеля:</div>
            <div class="info-value">$GRE_NETWORK</div>
            <div class="info-label">Локальный внешний IP:</div>
            <div class="info-value">${GRE_LOCAL_IP:-N/A}</div>
            <div class="info-label">Удалённый внешний IP:</div>
            <div class="info-value">${GRE_REMOTE_IP:-N/A}</div>
            <div class="info-label">Ключ туннеля:</div>
            <div class="info-value">${GRE_KEY:-не задан}</div>
        </div>
    </div>
    
    <div class="section">
        <h2>3. Настройка OSPF</h2>
        <div class="info-grid">
            <div class="info-label">Протокол:</div>
            <div class="info-value">OSPFv2 (Open Shortest Path First)</div>
            <div class="info-label">Тип протокола:</div>
            <div class="info-value">Link State</div>
            <div class="info-label">Область (Area):</div>
            <div class="info-value">0 (Backbone)</div>
        </div>
        <h3>Анонсируемые сети:</h3>
        <ul class="network-list">
EOF
    
    for net in "${NETWORKS[@]}"; do
        echo "            <li>$net</li>" >> "$html_file"
    done
    
    cat >> "$html_file" << EOF
        </ul>
    </div>
    
    <div class="section">
        <h2>4. Защита протокола OSPF</h2>
        <div class="info-grid">
            <div class="info-label">Тип аутентификации:</div>
            <div class="info-value">Simple Password (Type 1)</div>
            <div class="info-label">Пароль:</div>
            <div class="info-value">$OSPF_PASSWORD</div>
            <div class="info-label">Интерфейс:</div>
            <div class="info-value">$GRE_INTERFACE</div>
        </div>
        <div class="warning">
            <strong>Важно:</strong> Аутентификация обеспечивает защиту от подключения 
            несанкционированных маршрутизаторов к OSPF домену.
        </div>
    </div>
    
    <div class="section">
        <h2>5. Конфигурация FRR</h2>
        <pre>$frr_config</pre>
    </div>
    
    <div class="section">
        <h2>6. Соседи OSPF</h2>
        <pre>$ospf_neighbors</pre>
    </div>
    
    <div class="section">
        <h2>7. Команды проверки</h2>
        <pre># Проверка соседей OSPF
vtysh -c "show ip ospf neighbor"

# Просмотр маршрутов OSPF
vtysh -c "show ip ospf route"

# Таблица маршрутизации
vtysh -c "show ip route ospf"

# Проверка связности
ping &lt;IP_удалённой_сети&gt;</pre>
    </div>
    
    <div class="footer">
        <p>Отчёт сгенерирован автоматически скриптом настройки OSPF</p>
    </div>
</body>
</html>
EOF
    
    print_success "HTML отчёт сохранён: $html_file"
}

#===============================================================================
# Отображение сводки
#===============================================================================

show_summary() {
    print_section "СВОДКА НАСТРОЙКИ"
    
    echo -e "${CYAN}"
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│                    ПАРАМЕТРЫ КОНФИГУРАЦИИ                       │"
    echo "├─────────────────────────────────────────────────────────────────┤"
    printf "│ %-30s │ %-30s │\n" "Роль маршрутизатора" "$ROUTER_ROLE"
    printf "│ %-30s │ %-30s │\n" "Router ID" "$ROUTER_ID"
    printf "│ %-30s │ %-30s │\n" "GRE интерфейс" "$GRE_INTERFACE"
    printf "│ %-30s │ %-30s │\n" "GRE IP-адрес" "$GRE_IP"
    printf "│ %-30s │ %-30s │\n" "Локальный внешний IP" "${GRE_LOCAL_IP:-существует}"
    printf "│ %-30s │ %-30s │\n" "Удалённый внешний IP" "${GRE_REMOTE_IP:-существует}"
    printf "│ %-30s │ %-30s │\n" "Ключ GRE туннеля" "${GRE_KEY:-не задан}"
    printf "│ %-30s │ %-30s │\n" "Пароль OSPF" "$OSPF_PASSWORD"
    printf "│ %-30s │ %-30s │\n" "Количество сетей" "${#NETWORKS[@]}"
    echo "├─────────────────────────────────────────────────────────────────┤"
    echo "│ СЕТИ ДЛЯ АНОНСИРОВАНИЯ:                                         │"
    for net in "${NETWORKS[@]}"; do
        printf "│   %-60s │\n" "$net"
    done
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
}

confirm_and_apply() {
    print_section "Подтверждение"
    
    read -p "Применить конфигурацию? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Настройка отменена пользователем"
        exit 0
    fi
}

#===============================================================================
# Основная функция
#===============================================================================

main() {
    # Инициализация
    print_header
    check_root
    check_alt_linux
    
    # Отображение информации об интерфейсах
    list_interfaces_with_details
    
    # Интерактивный выбор параметров
    select_router_role
    select_gre_interface  # Включает создание GRE если не существует
    select_networks
    select_router_id
    select_ospf_password
    
    # Отображение сводки
    show_summary
    
    # Подтверждение
    confirm_and_apply
    
    # Установка и настройка
    install_frr
    configure_frr_daemons
    configure_frr_service
    
    # Пауза для инициализации FRR
    print_info "Ожидание инициализации FRR..."
    sleep 3
    
    configure_ospf
    
    # Проверка
    verify_ospf
    
    # Генерация отчёта
    generate_report
    
    # Финальное сообщение
    print_section "НАСТРОЙКА ЗАВЕРШЕНА"
    print_success "OSPF динамическая маршрутизация настроена!"
    echo ""
    print_info "Отчёты сохранены:"
    echo "  - Текстовый: $REPORT_FILE"
    echo "  - HTML: /root/ospf-config-report.html"
    echo ""
    print_warning "Проверьте связность между офисами:"
    echo "  ping <IP_адрес_удалённой_сети>"
    echo ""
    print_info "Полезные команды:"
    echo "  vtysh -c 'show ip ospf neighbor'   # Соседи OSPF"
    echo "  vtysh -c 'show ip ospf route'      # Маршруты OSPF"
    echo "  vtysh -c 'show ip route ospf'      # Таблица маршрутизации"
    echo "  ip tunnel show                     # Статус GRE туннеля"
}

#===============================================================================
# Запуск
#===============================================================================

main "$@"

