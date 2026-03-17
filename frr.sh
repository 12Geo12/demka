#!/bin/bash
#===============================================================================
# Скрипт автоматической настройки GRE туннеля и OSPF
# Для маршрутизаторов HQ-RTR и BR-RTR
# Поддержка: Alt Linux / ОС на базе /etc/net/ifaces/
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Лог-файл
LOG_FILE="/var/log/gre-ospf-setup.log"

# Функция логирования
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${CYAN}[ИНФО]${NC} $1" | tee -a "$LOG_FILE"
}

# Функция проверки прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Функция определения внешнего интерфейса (подключенного к WAN)
detect_wan_interface() {
    log_info "Определение WAN интерфейса..."
    
    # Получаем список интерфейсов с маршрутами по умолчанию
    local wan_ifaces=$(ip route show default | awk '{print $5}' | sort -u)
    
    if [[ -z "$wan_ifaces" ]]; then
        log_warn "Не найден маршрут по умолчанию. Пытаюсь определить по другим признакам..."
        # Ищем интерфейсы с публичными IP или в диапазонах 172.16.x.x
        for iface in $(ls /sys/class/net/ | grep -v lo); do
            local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
            if [[ -n "$ip" ]]; then
                # Проверяем, это не локальный диапазон (192.168.x.x обычно LAN)
                if [[ "$ip" =~ ^172\.16\.[4-5]\. ]]; then
                    echo "$iface"
                    return
                fi
            fi
        done
    else
        echo "$wan_ifaces" | head -1
        return
    fi
    
    echo ""
}

# Функция получения IP-адреса интерфейса
get_interface_ip() {
    local iface=$1
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+(?=/|\s)'
}

# Функция получения маски интерфейса
get_interface_mask() {
    local iface=$1
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet [\d.]+/\K\d+'
}

# Функция получения сети интерфейса
get_interface_network() {
    local iface=$1
    local ip=$(get_interface_ip "$iface")
    local mask=$(get_interface_mask "$iface")
    
    if [[ -n "$ip" && -n "$mask" ]]; then
        # Вычисляем адрес сети
        local IFS='.'
        read -ra ip_parts <<< "$ip"
        
        if [[ $mask -eq 24 ]]; then
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        elif [[ $mask -eq 26 ]]; then
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        elif [[ $mask -eq 27 ]]; then
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        elif [[ $mask -eq 28 ]]; then
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        elif [[ $mask -eq 29 ]]; then
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        else
            echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.0/$mask"
        fi
    fi
}

# Функция отображения всех интерфейсов
show_interfaces() {
    log_info "Обнаруженные интерфейсы:"
    echo ""
    printf "${BLUE}%-15s %-18s %-10s %-20s${NC}\n" "Интерфейс" "IP-адрес" "Маска" "Сеть"
    printf "${BLUE}%-15s %-18s %-10s %-20s${NC}\n" "---------" "----------" "-----" "----"
    
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        local ip=$(get_interface_ip "$iface")
        local mask=$(get_interface_mask "$iface")
        local network=$(get_interface_network "$iface")
        
        if [[ -n "$ip" ]]; then
            printf "%-15s %-18s %-10s %-20s\n" "$iface" "$ip" "/$mask" "$network"
        fi
    done
    echo ""
}

# Функция определения роли маршрутизатора (HQ-RTR или BR-RTR)
detect_router_role() {
    local hostname=$(hostname)
    
    if [[ "$hostname" =~ [Hh][Qq] ]]; then
        echo "HQ-RTR"
    elif [[ "$hostname" =~ [Bb][Rr] ]]; then
        echo "BR-RTR"
    else
        echo "UNKNOWN"
    fi
}

# Функция определения IP-адресов для туннеля
detect_tunnel_ips() {
    local role=$1
    
    if [[ "$role" == "HQ-RTR" ]]; then
        # HQ-RTR: ищем IP в диапазоне 172.16.4.x
        for iface in $(ls /sys/class/net/ | grep -v lo); do
            local ip=$(get_interface_ip "$iface")
            if [[ "$ip" =~ ^172\.16\.4\. ]]; then
                TUNLOCAL="$ip"
                TUNLOCAL_IFACE="$iface"
            elif [[ "$ip" =~ ^172\.16\.5\. ]]; then
                TUNREMOTE="$ip"
            fi
        done
        
        # Если не нашли, предполагаем удалённый адрес
        if [[ -n "$TUNLOCAL" && -z "$TUNREMOTE" ]]; then
            # Определяем последний октет удалённого IP (обычно .2)
            TUNREMOTE="172.16.5.2"
        fi
        
        # IP туннеля для HQ-RTR
        TUNNEL_IP="172.16.100.2/29"
        
    elif [[ "$role" == "BR-RTR" ]]; then
        # BR-RTR: ищем IP в диапазоне 172.16.5.x
        for iface in $(ls /sys/class/net/ | grep -v lo); do
            local ip=$(get_interface_ip "$iface")
            if [[ "$ip" =~ ^172\.16\.5\. ]]; then
                TUNLOCAL="$ip"
                TUNLOCAL_IFACE="$iface"
            elif [[ "$ip" =~ ^172\.16\.4\. ]]; then
                TUNREMOTE="$ip"
            fi
        done
        
        # Если не нашли, предполагаем удалённый адрес
        if [[ -n "$TUNLOCAL" && -z "$TUNREMOTE" ]]; then
            TUNREMOTE="172.16.4.2"
        fi
        
        # IP туннеля для BR-RTR
        TUNNEL_IP="172.16.100.1/29"
    fi
}

# Функция обнаружения локальных сетей
detect_local_networks() {
    local role=$1
    LOCAL_NETWORKS=()
    
    for iface in $(ls /sys/class/net/ | grep -v lo | grep -v "$TUNLOCAL_IFACE"); do
        local network=$(get_interface_network "$iface")
        local ip=$(get_interface_ip "$iface")
        
        # Пропускаем WAN интерфейсы (те, у которых маршрут по умолчанию)
        local is_default=$(ip route show default | grep -c "$iface")
        
        # Добавляем только сети 192.168.x.x
        if [[ "$network" =~ ^192\.168\. && $is_default -eq 0 ]]; then
            LOCAL_NETWORKS+=("$network")
            LOCAL_IFACES+=("$iface")
        fi
    done
}

# Функция создания GRE туннеля
create_gre_tunnel() {
    local tunnel_name=${1:-"gre1"}
    
    log "Создание GRE туннеля $tunnel_name..."
    
    # Создаём каталог для интерфейса
    if [[ -d "/etc/net/ifaces/$tunnel_name" ]]; then
        log_warn "Каталог /etc/net/ifaces/$tunnel_name уже существует. Удаляем..."
        rm -rf "/etc/net/ifaces/$tunnel_name"
    fi
    
    mkdir -p "/etc/net/ifaces/$tunnel_name"
    
    # Создаём файл options
    cat > "/etc/net/ifaces/$tunnel_name/options" << EOF
TUNLOCAL=$TUNLOCAL
TUNREMOTE=$TUNREMOTE
TUNTYPE=gre
TYPE=iptun
TUNOPTIONS='ttl 64'
HOST=$TUNLOCAL_IFACE
EOF
    
    log "Файл options создан:"
    cat "/etc/net/ifaces/$tunnel_name/options"
    
    # Создаём файл ipv4address
    echo "$TUNNEL_IP" > "/etc/net/ifaces/$tunnel_name/ipv4address"
    
    log "IP-адрес туннеля: $TUNNEL_IP"
}

# Функция настройки FRR
configure_frr() {
    log "Настройка FRR..."
    
    # Включаем автозагрузку FRR
    systemctl enable --now frr
    
    # Проверяем наличие файла daemons
    if [[ ! -f "/etc/frr/daemons" ]]; then
        log_error "Файл /etc/frr/daemons не найден!"
        return 1
    fi
    
    # Включаем OSPFD
    sed -i 's/^#*ospfd=no/ospfd=yes/' /etc/frr/daemons
    sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
    
    log "OSPF демон включён в /etc/frr/daemons"
    
    # Перезапускаем FRR
    systemctl restart frr
    log "Служба FRR перезапущена"
}

# Функция генерации команд OSPF
generate_ospf_commands() {
    local role=$1
    local ospf_key=${2:-"1245"}
    local tunnel_name=${3:-"gre1"}
    
    log "Генерация команд OSPF для $role..."
    
    # Базовые команды OSPF
    OSPF_COMMANDS=(
        "conf t"
        "router ospf"
        "passive interface default"
        "network 172.16.100.0/29 area 0"
    )
    
    # Добавляем локальные сети
    for network in "${LOCAL_NETWORKS[@]}"; do
        OSPF_COMMANDS+=("network $network area 0")
    done
    
    OSPF_COMMANDS+=("area 0 authentication")
    OSPF_COMMANDS+=("exit")
    OSPF_COMMANDS+=("interface $tunnel_name")
    OSPF_COMMANDS+=("no ip ospf passive")
    OSPF_COMMANDS+=("ip ospf authentication-key $ospf_key")
    OSPF_COMMANDS+=("exit")
    OSPF_COMMANDS+=("do wr")
    OSPF_COMMANDS+=("end")
    OSPF_COMMANDS+=("exit")
    
    log "Сгенерированные команды OSPF:"
    for cmd in "${OSPF_COMMANDS[@]}"; do
        echo "  $cmd"
    done
}

# Функция применения настроек OSPF через vtysh
apply_ospf_config() {
    local ospf_key=$1
    local tunnel_name=$2
    
    log "Применение конфигурации OSPF..."
    
    # Создаём временный файл с командами
    local tmp_file=$(mktemp)
    
    echo "conf t" >> "$tmp_file"
    echo "router ospf" >> "$tmp_file"
    echo "passive interface default" >> "$tmp_file"
    echo "network 172.16.100.0/29 area 0" >> "$tmp_file"
    
    for network in "${LOCAL_NETWORKS[@]}"; do
        echo "network $network area 0" >> "$tmp_file"
    done
    
    echo "area 0 authentication" >> "$tmp_file"
    echo "exit" >> "$tmp_file"
    echo "interface $tunnel_name" >> "$tmp_file"
    echo "no ip ospf passive" >> "$tmp_file"
    echo "ip ospf authentication-key $ospf_key" >> "$tmp_file"
    echo "exit" >> "$tmp_file"
    echo "do wr" >> "$tmp_file"
    echo "end" >> "$tmp_file"
    echo "exit" >> "$tmp_file"
    
    # Применяем через vtysh
    vtysh < "$tmp_file"
    
    rm -f "$tmp_file"
    
    log "Конфигурация OSPF применена"
}

# Функция проверки настроек
verify_configuration() {
    log "Проверка конфигурации..."
    
    echo ""
    log_info "=== Состояние интерфейсов ==="
    ip addr show | grep -E "^[0-9]+:|inet " | head -20
    
    echo ""
    log_info "=== Состояние туннеля ==="
    ip addr show gre1 2>/dev/null || log_warn "Интерфейс gre1 не найден"
    
    echo ""
    log_info "=== Соседи OSPF ==="
    vtysh -c "show ip ospf neighbor" 2>/dev/null || log_warn "Не удалось получить информацию о соседях OSPF"
    
    echo ""
    log_info "=== Маршруты OSPF ==="
    vtysh -c "show ip ospf route" 2>/dev/null || log_warn "Не удалось получить маршруты OSPF"
    
    echo ""
    log_info "=== Таблица маршрутизации ==="
    ip route show | head -20
}

# Функция интерактивной настройки
interactive_setup() {
    clear
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN}  Настройка GRE туннеля и OSPF${NC}"
    echo -e "${CYAN}=======================================${NC}"
    echo ""
    
    # Показываем интерфейсы
    show_interfaces
    
    # Определяем роль маршрутизатора
    local detected_role=$(detect_router_role)
    
    echo -e "${YELLOW}Определённая роль маршрутизатора: ${GREEN}$detected_role${NC}"
    echo ""
    
    read -p "Подтвердите роль (HQ-RTR/BR-RTR) [$detected_role]: " user_role
    ROUTER_ROLE="${user_role:-$detected_role}"
    
    echo ""
    log_info "Выбранная роль: $ROUTER_ROLE"
    
    # Получаем данные для туннеля
    detect_tunnel_ips "$ROUTER_ROLE"
    
    echo ""
    echo -e "${CYAN}=== Настройки туннеля ===${NC}"
    echo "Локальный IP (TUNLOCAL): $TUNLOCAL"
    echo "Интерфейс: $TUNLOCAL_IFACE"
    echo "Удалённый IP (TUNREMOTE): $TUNREMOTE"
    echo "IP туннеля: $TUNNEL_IP"
    echo ""
    
    read -p "Введите локальный IP для туннеля [$TUNLOCAL]: " user_tunlocal
    TUNLOCAL="${user_tunlocal:-$TUNLOCAL}"
    
    read -p "Введите удалённый IP для туннеля [$TUNREMOTE]: " user_tunremote
    TUNREMOTE="${user_tunremote:-$TUNREMOTE}"
    
    read -p "Введите интерфейс для привязки туннеля [$TUNLOCAL_IFACE]: " user_iface
    TUNLOCAL_IFACE="${user_iface:-$TUNLOCAL_IFACE}"
    
    read -p "Введите IP-адрес туннеля [$TUNNEL_IP]: " user_tunnel_ip
    TUNNEL_IP="${user_tunnel_ip:-$TUNNEL_IP}"
    
    # Получаем локальные сети
    detect_local_networks "$ROUTER_ROLE"
    
    echo ""
    echo -e "${CYAN}=== Обнаруженные локальные сети ===${NC}"
    for i in "${!LOCAL_NETWORKS[@]}"; do
        echo "  $((i+1)). ${LOCAL_NETWORKS[$i]} (интерфейс: ${LOCAL_IFACES[$i]})"
    done
    
    echo ""
    read -p "Добавить дополнительные сети? (через пробел, например 10.0.0.0/24): " extra_networks
    for net in $extra_networks; do
        LOCAL_NETWORKS+=("$net")
    done
    
    # Ключ аутентификации
    echo ""
    read -p "Введите ключ аутентификации OSPF [1245]: " ospf_key
    OSPF_KEY="${ospf_key:-1245}"
    
    # Имя туннеля
    read -p "Введите имя туннеля [gre1]: " tunnel_name
    TUNNEL_NAME="${tunnel_name:-gre1}"
    
    # Подтверждение
    echo ""
    echo -e "${YELLOW}=== Итоговая конфигурация ===${NC}"
    echo "Роль: $ROUTER_ROLE"
    echo "Туннель: $TUNNEL_NAME"
    echo "TUNLOCAL: $TUNLOCAL"
    echo "TUNREMOTE: $TUNREMOTE"
    echo "HOST интерфейс: $TUNLOCAL_IFACE"
    echo "IP туннеля: $TUNNEL_IP"
    echo "OSPF ключ: $OSPF_KEY"
    echo "Локальные сети:"
    for network in "${LOCAL_NETWORKS[@]}"; do
        echo "  - $network"
    done
    echo ""
    
    read -p "Применить конфигурацию? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Применяем настройки
        create_gre_tunnel "$TUNNEL_NAME"
        configure_frr
        generate_ospf_commands "$ROUTER_ROLE" "$OSPF_KEY" "$TUNNEL_NAME"
        apply_ospf_config "$OSPF_KEY" "$TUNNEL_NAME"
        
        # Перезапускаем сеть
        log "Перезапуск сети..."
        systemctl restart network
        
        # Проверяем
        sleep 3
        verify_configuration
        
        log "Настройка завершена!"
    else
        log_warn "Настройка отменена пользователем"
    fi
}

# Функция автоматической настройки (без интерактивного режима)
auto_setup() {
    local role=$1
    local ospf_key=${2:-"1245"}
    local tunnel_name=${3:-"gre1"}
    
    log "Автоматическая настройка для роли: $role"
    
    ROUTER_ROLE="$role"
    detect_tunnel_ips "$role"
    detect_local_networks "$role"
    OSPF_KEY="$ospf_key"
    TUNNEL_NAME="$tunnel_name"
    
    # Проверяем, что все необходимые данные получены
    if [[ -z "$TUNLOCAL" || -z "$TUNREMOTE" || -z "$TUNNEL_IP" ]]; then
        log_error "Не удалось автоматически определить настройки туннеля"
        log_info "Используйте интерактивный режим: $0 --interactive"
        exit 1
    fi
    
    log "Конфигурация:"
    log "  Роль: $ROUTER_ROLE"
    log "  TUNLOCAL: $TUNLOCAL"
    log "  TUNREMOTE: $TUNREMOTE"
    log "  IP туннеля: $TUNNEL_IP"
    log "  Ключ OSPF: $OSPF_KEY"
    
    create_gre_tunnel "$TUNNEL_NAME"
    configure_frr
    apply_ospf_config "$OSPF_KEY" "$TUNNEL_NAME"
    
    log "Перезапуск сети..."
    systemctl restart network
    
    sleep 3
    verify_configuration
    
    log "Автоматическая настройка завершена!"
}

# Функция отображения справки
show_help() {
    echo -e "${CYAN}Использование:${NC}"
    echo "  $0 [опции]"
    echo ""
    echo -e "${CYAN}Опции:${NC}"
    echo "  -i, --interactive    Интерактивный режим настройки"
    echo "  -a, --auto           Автоматическая настройка"
    echo "  -r, --role ROLE      Указать роль (HQ-RTR или BR-RTR)"
    echo "  -k, --key KEY        Ключ аутентификации OSPF (по умолчанию: 1245)"
    echo "  -t, --tunnel NAME    Имя туннеля (по умолчанию: gre1)"
    echo "  -s, --show           Показать информацию об интерфейсах"
    echo "  -v, --verify         Проверить текущую конфигурацию"
    echo "  -h, --help           Показать эту справку"
    echo ""
    echo -e "${CYAN}Примеры:${NC}"
    echo "  $0 -i                    # Интерактивный режим"
    echo "  $0 -a -r HQ-RTR          # Автонастройка для HQ-RTR"
    echo "  $0 -a -r BR-RTR -k mykey # Автонастройка для BR-RTR с ключом mykey"
    echo "  $0 -s                    # Показать интерфейсы"
    echo "  $0 -v                    # Проверить конфигурацию"
}

# Основная функция
main() {
    local mode=""
    local role=""
    local key="1245"
    local tunnel="gre1"
    
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interactive)
                mode="interactive"
                shift
                ;;
            -a|--auto)
                mode="auto"
                shift
                ;;
            -r|--role)
                role="$2"
                shift 2
                ;;
            -k|--key)
                key="$2"
                shift 2
                ;;
            -t|--tunnel)
                tunnel="$2"
                shift 2
                ;;
            -s|--show)
                mode="show"
                shift
                ;;
            -v|--verify)
                mode="verify"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Неизвестная опция: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Проверка прав root
    check_root
    
    case $mode in
        interactive)
            interactive_setup
            ;;
        auto)
            if [[ -z "$role" ]]; then
                role=$(detect_router_role)
                if [[ "$role" == "UNKNOWN" ]]; then
                    log_error "Не удалось определить роль маршрутизатора. Укажите с помощью -r HQ-RTR или -r BR-RTR"
                    exit 1
                fi
            fi
            auto_setup "$role" "$key" "$tunnel"
            ;;
        show)
            show_interfaces
            ;;
        verify)
            verify_configuration
            ;;
        *)
            show_help
            ;;
    esac
}

# Запуск
main "$@"
