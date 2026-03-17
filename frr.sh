#!/bin/bash
#===============================================================================
# Интерактивный скрипт настройки GRE туннеля и OSPF
# Для маршрутизаторов HQ-RTR и BR-RTR
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Глобальные переменные
CONFIG_DIR="/etc/net/ifaces"
FRR_DAEMONS="/etc/frr/daemons"
LOG_FILE="/var/log/gre-ospf-setup.log"

# Конфигурация (будет заполнена в процессе)
declare -A CONFIG

#===============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#===============================================================================

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null
}

log_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null
}

log_warn() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null
}

log_info() {
    echo -e "${CYAN}[ИНФО]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: скрипт требует прав root!${NC}"
        echo "Запустите: sudo $0"
        exit 1
    fi
}

clear_screen() {
    clear
}

pause() {
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

#===============================================================================
# ФУНКЦИИ ПОЛУЧЕНИЯ ИНФОРМАЦИИ
#===============================================================================

# Получить список всех интерфейсов
get_all_interfaces() {
    ls /sys/class/net/ | grep -v lo | sort
}

# Получить IP адрес интерфейса
get_interface_ip() {
    local iface=$1
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+'
}

# Получить маску интерфейса
get_interface_mask() {
    local iface=$1
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet [\d.]+/\K\d+'
}

# Получить сеть интерфейса
get_interface_network() {
    local iface=$1
    local ip=$(get_interface_ip "$iface")
    local mask=$(get_interface_mask "$iface")
    
    if [[ -n "$ip" && -n "$mask" ]]; then
        # Вычисляем адрес сети используя ipcalc или вручную
        local IFS='.'
        read -ra octets <<< "$ip"
        case $mask in
            24) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/24" ;;
            25) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/25" ;;
            26) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/26" ;;
            27) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/27" ;;
            28) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/28" ;;
            29) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/29" ;;
            30) echo "${octets[0]}.${octets[1]}.${octets[2]}.0/30" ;;
            *)  echo "${octets[0]}.${octets[1]}.${octets[2]}.0/$mask" ;;
        esac
    fi
}

# Проверить, является ли интерфейс WAN (имеет маршрут по умолчанию)
is_wan_interface() {
    local iface=$1
    ip route show default 2>/dev/null | grep -q "$iface"
}

#===============================================================================
# ФУНКЦИИ ОТОБРАЖЕНИЯ
#===============================================================================

# Показать заголовок
show_header() {
    clear_screen
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}        НАСТРОЙКА GRE ТУННЕЛЯ И OSPF                    ${NC}   ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Для маршрутизаторов HQ-RTR и BR-RTR                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Показать все интерфейсы с информацией
show_interfaces_table() {
    echo -e "${BOLD}┌─────────────┬──────────────────┬────────┬────────────────────┬───────┐${NC}"
    echo -e "${BOLD}│  Интерфейс  │     IP-адрес     │ Маска  │       Сеть         │ Тип   │${NC}"
    echo -e "${BOLD}├─────────────┼──────────────────┼────────┼────────────────────┼───────┤${NC}"
    
    for iface in $(get_all_interfaces); do
        local ip=$(get_interface_ip "$iface")
        local mask=$(get_interface_mask "$iface")
        local network=$(get_interface_network "$iface")
        local type="LAN"
        
        is_wan_interface "$iface" && type="WAN"
        
        if [[ -n "$ip" ]]; then
            printf "│ %-11s │ %-16s │ %-6s │ %-18s │ %-5s │\n" "$iface" "$ip" "/$mask" "$network" "$type"
        else
            printf "│ %-11s │ %-16s │ %-6s │ %-18s │ %-5s │\n" "$iface" "нет IP" "-" "-" "$type"
        fi
    done
    
    echo -e "${BOLD}└─────────────┴──────────────────┴────────┴────────────────────┴───────┘${NC}"
    echo ""
}

# Показать текущую конфигурацию
show_current_config() {
    echo ""
    echo -e "${MAGENTA}════════════════════ ТЕКУЩАЯ КОНФИГУРАЦИЯ ══════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Роль маршрутизатора:     ${GREEN}${CONFIG[ROLE]:-не указана}${NC}"
    echo -e "  ${YELLOW}2.${NC} Имя туннеля:             ${GREEN}${CONFIG[TUNNEL_NAME]:-gre1}${NC}"
    echo ""
    echo -e "  ${CYAN}── Настройки туннеля ──${NC}"
    echo -e "  ${YELLOW}3.${NC} Локальный IP (TUNLOCAL):  ${GREEN}${CONFIG[TUNLOCAL]:-не указан}${NC}"
    echo -e "  ${YELLOW}4.${NC} Удалённый IP (TUNREMOTE): ${GREEN}${CONFIG[TUNREMOTE]:-не указан}${NC}"
    echo -e "  ${YELLOW}5.${NC} Интерфейс хоста (HOST):   ${GREEN}${CONFIG[HOST_IFACE]:-не указан}${NC}"
    echo -e "  ${YELLOW}6.${NC} IP-адрес туннеля:         ${GREEN}${CONFIG[TUNNEL_IP]:-не указан}${NC}"
    echo ""
    echo -e "  ${CYAN}── Настройки OSPF ──${NC}"
    echo -e "  ${YELLOW}7.${NC} Ключ аутентификации:      ${GREEN}${CONFIG[OSPF_KEY]:-1245}${NC}"
    echo -e "  ${YELLOW}8.${NC} Локальные сети:           ${GREEN}${CONFIG[LOCAL_NETS]:-не указаны}${NC}"
    echo ""
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

#===============================================================================
# ФУНКЦИИ ВЫБОРА И ВВОДА
#===============================================================================

# Меню выбора из списка
select_from_list() {
    local prompt=$1
    shift
    local options=("$@")
    
    echo -e "${CYAN}$prompt${NC}"
    echo ""
    
    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${YELLOW}$i)${NC} $opt"
        ((i++))
    done
    echo -e "  ${YELLOW}0)${NC} Ввести вручную"
    echo ""
    
    local choice
    while true; do
        read -p "Выберите вариант [0-$((${#options[@]}))]: " choice
        
        if [[ "$choice" == "0" ]]; then
            return 1  # Сигнал для ручного ввода
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
            SELECTED="${options[$((choice-1))]}"
            return 0
        else
            echo -e "${RED}Неверный выбор. Попробуйте снова.${NC}"
        fi
    done
}

# Выбор интерфейса из списка
select_interface() {
    local prompt=$1
    local ifaces=()
    
    for iface in $(get_all_interfaces); do
        local ip=$(get_interface_ip "$iface")
        if [[ -n "$ip" ]]; then
            ifaces+=("$iface (IP: $ip)")
        else
            ifaces+=("$iface (нет IP)")
        fi
    done
    
    if select_from_list "$prompt" "${ifaces[@]}"; then
        # Извлекаем имя интерфейса
        SELECTED_IFACE=$(echo "$SELECTED" | cut -d' ' -f1)
        return 0
    else
        return 1
    fi
}

# Ввод IP адреса с проверкой
read_ip_address() {
    local prompt=$1
    local default=$2
    local ip
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " ip
            ip="${ip:-$default}"
        else
            read -p "$prompt: " ip
        fi
        
        # Проверка формата IP
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            SELECTED_IP="$ip"
            return 0
        else
            echo -e "${RED}Неверный формат IP. Пример: 192.168.1.1${NC}"
        fi
    done
}

# Ввод IP с маской
read_ip_with_mask() {
    local prompt=$1
    local default=$2
    local ip
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " ip
            ip="${ip:-$default}"
        else
            read -p "$prompt: " ip
        fi
        
        # Проверка формата IP/маска
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            SELECTED_IP="$ip"
            return 0
        else
            echo -e "${RED}Неверный формат. Пример: 192.168.1.1/24${NC}"
        fi
    done
}

# Ввод сети OSPF
read_ospf_network() {
    local prompt=$1
    local default=$2
    local network
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " network
            network="${network:-$default}"
        else
            read -p "$prompt: " network
        fi
        
        if [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            SELECTED_NETWORK="$network"
            return 0
        else
            echo -e "${RED}Неверный формат. Пример: 192.168.10.0/26${NC}"
        fi
    done
}

#===============================================================================
# ОСНОВНЫЕ ФУНКЦИИ НАСТРОЙКИ
#===============================================================================

# Выбор роли маршрутизатора
configure_role() {
    show_header
    echo -e "${CYAN}Выберите роль маршрутизатора:${NC}"
    echo ""
    echo -e "  ${YELLOW}1)${NC} HQ-RTR (Главный офис)"
    echo -e "  ${YELLOW}2)${NC} BR-RTR (Филиал)"
    echo ""
    
    local choice
    while true; do
        read -p "Ваш выбор [1-2]: " choice
        
        case $choice in
            1)
                CONFIG[ROLE]="HQ-RTR"
                # Предлагаемые значения для HQ-RTR
                CONFIG[TUNNEL_IP]="172.16.100.2/29"
                break
                ;;
            2)
                CONFIG[ROLE]="BR-RTR"
                # Предлагаемые значения для BR-RTR
                CONFIG[TUNNEL_IP]="172.16.100.1/29"
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор. Введите 1 или 2.${NC}"
                ;;
        esac
    done
    
    log "Выбрана роль: ${CONFIG[ROLE]}"
}

# Настройка имени туннеля
configure_tunnel_name() {
    show_header
    echo -e "${CYAN}Настройка имени туннеля${NC}"
    echo ""
    echo -e "  ${YELLOW}1)${NC} gre1 (рекомендуется)"
    echo -e "  ${YELLOW}2)${NC} gre0"
    echo -e "  ${YELLOW}3)${NC} tun0"
    echo -e "  ${YELLOW}0)${NC} Ввести своё имя"
    echo ""
    
    local choice
    read -p "Выберите вариант [1-3, 0 для ручного ввода]: " choice
    
    case $choice in
        1) CONFIG[TUNNEL_NAME]="gre1" ;;
        2) CONFIG[TUNNEL_NAME]="gre0" ;;
        3) CONFIG[TUNNEL_NAME]="tun0" ;;
        0)
            read -p "Введите имя туннеля: " CONFIG[TUNNEL_NAME]
            ;;
        *) CONFIG[TUNNEL_NAME]="gre1" ;;
    esac
    
    log "Имя туннеля: ${CONFIG[TUNNEL_NAME]}"
}

# Настройка локального IP (TUNLOCAL)
configure_tunlocal() {
    show_header
    echo -e "${CYAN}Настройка локального IP-адреса (TUNLOCAL)${NC}"
    echo ""
    echo -e "Это IP-адрес интерфейса, через который будет проходить туннель.${NC}"
    echo ""
    
    show_interfaces_table
    
    if select_interface "Выберите интерфейс для туннеля"; then
        CONFIG[HOST_IFACE]="$SELECTED_IFACE"
        local ip=$(get_interface_ip "$SELECTED_IFACE")
        
        echo ""
        read_ip_address "Введите локальный IP (TUNLOCAL)" "$ip"
        CONFIG[TUNLOCAL]="$SELECTED_IP"
    else
        echo ""
        read -p "Введите имя интерфейса: " CONFIG[HOST_IFACE]
        read_ip_address "Введите локальный IP (TUNLOCAL)"
        CONFIG[TUNLOCAL]="$SELECTED_IP"
    fi
    
    log "TUNLOCAL: ${CONFIG[TUNLOCAL]}, интерфейс: ${CONFIG[HOST_IFACE]}"
}

# Настройка удалённого IP (TUNREMOTE)
configure_tunremote() {
    show_header
    echo -e "${CYAN}Настройка удалённого IP-адреса (TUNREMOTE)${NC}"
    echo ""
    echo -e "Это IP-адрес удалённого маршрутизатора (на другом конце туннеля).${NC}"
    echo ""
    
    # Предлагаем типичные значения в зависимости от роли
    local suggested=""
    if [[ "${CONFIG[ROLE]}" == "HQ-RTR" ]]; then
        suggested="172.16.5.2"
        echo -e "${YELLOW}Подсказка: для HQ-RTR удалённый IP обычно 172.16.5.2 (BR-RTR)${NC}"
    elif [[ "${CONFIG[ROLE]}" == "BR-RTR" ]]; then
        suggested="172.16.4.2"
        echo -e "${YELLOW}Подсказка: для BR-RTR удалённый IP обычно 172.16.4.2 (HQ-RTR)${NC}"
    fi
    
    echo ""
    read_ip_address "Введите удалённый IP (TUNREMOTE)" "$suggested"
    CONFIG[TUNREMOTE]="$SELECTED_IP"
    
    log "TUNREMOTE: ${CONFIG[TUNREMOTE]}"
}

# Настройка IP туннеля
configure_tunnel_ip() {
    show_header
    echo -e "${CYAN}Настройка IP-адреса туннеля${NC}"
    echo ""
    echo -e "Это IP-адрес самого туннельного интерфейса.${NC}"
    echo ""
    
    local suggested="${CONFIG[TUNNEL_IP]}"
    echo -e "${YELLOW}Подсказка:${NC}"
    echo -e "  HQ-RTR: 172.16.100.2/29"
    echo -e "  BR-RTR: 172.16.100.1/29"
    echo ""
    
    read_ip_with_mask "Введите IP-адрес туннеля" "$suggested"
    CONFIG[TUNNEL_IP]="$SELECTED_IP"
    
    log "IP туннеля: ${CONFIG[TUNNEL_IP]}"
}

# Настройка ключа OSPF
configure_ospf_key() {
    show_header
    echo -e "${CYAN}Настройка ключа аутентификации OSPF${NC}"
    echo ""
    echo -e "Ключ должен быть одинаковым на обоих маршрутизаторах.${NC}"
    echo ""
    
    read -p "Введите ключ аутентификации OSPF [1245]: " CONFIG[OSPF_KEY]
    CONFIG[OSPF_KEY]="${CONFIG[OSPF_KEY]:-1245}"
    
    log "OSPF ключ: ${CONFIG[OSPF_KEY]}"
}

# Настройка локальных сетей для OSPF
configure_local_networks() {
    show_header
    echo -e "${CYAN}Настройка локальных сетей для OSPF${NC}"
    echo ""
    echo -e "Выберите сети, которые будут анонсироваться через OSPF.${NC}"
    echo ""
    
    show_interfaces_table
    
    local networks=()
    local nets_str=""
    
    echo -e "${YELLOW}Автоматическое определение локальных сетей:${NC}"
    echo ""
    
    # Автоматически находим локальные сети
    local i=1
    for iface in $(get_all_interfaces); do
        local ip=$(get_interface_ip "$iface")
        local network=$(get_interface_network "$iface")
        
        # Пропускаем WAN интерфейсы
        if [[ -n "$network" && "$network" =~ ^192\.168\. ]] && ! is_wan_interface "$iface"; then
            echo -e "  ${YELLOW}$i)${NC} $network (интерфейс: $iface)"
            networks+=("$network")
            ((i++))
        fi
    done
    
    echo ""
    echo -e "${YELLOW}0)${NC} Пропустить автоматическое добавление и ввести вручную"
    echo ""
    
    read -p "Добавить все найденные сети? (y/n) [y]: " add_all
    
    if [[ "$add_all" != "n" && "$add_all" != "N" ]]; then
        # Добавляем все найденные сети
        for net in "${networks[@]}"; do
            nets_str+="$net "
        done
    fi
    
    echo ""
    echo -e "${CYAN}Введите дополнительные сети через пробел (или Enter для завершения):${NC}"
    echo -e "Пример: 10.0.0.0/24 172.17.0.0/16"
    read -p "> " extra_nets
    
    nets_str+="$extra_nets"
    
    # Убираем дубликаты и лишние пробелы
    nets_str=$(echo "$nets_str" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    CONFIG[LOCAL_NETS]="$nets_str"
    
    log "Локальные сети: ${CONFIG[LOCAL_NETS]}"
}

# Редактирование отдельного параметра
edit_parameter() {
    local param=$1
    
    case $param in
        1) configure_role ;;
        2) configure_tunnel_name ;;
        3) configure_tunlocal ;;
        4) configure_tunremote ;;
        5) 
            show_header
            echo -e "${CYAN}Выбор интерфейса хоста${NC}"
            echo ""
            show_interfaces_table
            
            if select_interface "Выберите интерфейс"; then
                CONFIG[HOST_IFACE]="$SELECTED_IFACE"
            else
                read -p "Введите имя интерфейса: " CONFIG[HOST_IFACE]
            fi
            ;;
        6) configure_tunnel_ip ;;
        7) configure_ospf_key ;;
        8) configure_local_networks ;;
    esac
}

#===============================================================================
# ФУНКЦИИ ПРИМЕНЕНИЯ КОНФИГУРАЦИИ
#===============================================================================

# Создание файлов конфигурации туннеля
create_tunnel_config() {
    local tunnel_name="${CONFIG[TUNNEL_NAME]}"
    local tunnel_dir="$CONFIG_DIR/$tunnel_name"
    
    log "Создание конфигурации туннеля $tunnel_name..."
    
    # Создаём каталог
    mkdir -p "$tunnel_dir"
    
    # Создаём файл options
    cat > "$tunnel_dir/options" << EOF
TUNLOCAL=${CONFIG[TUNLOCAL]}
TUNREMOTE=${CONFIG[TUNREMOTE]}
TUNTYPE=gre
TYPE=iptun
TUNOPTIONS='ttl 64'
HOST=${CONFIG[HOST_IFACE]}
EOF
    
    log "Файл $tunnel_dir/options создан"
    cat "$tunnel_dir/options"
    echo ""
    
    # Создаём файл ipv4address
    echo "${CONFIG[TUNNEL_IP]}" > "$tunnel_dir/ipv4address"
    log "Файл $tunnel_dir/ipv4address создан"
    
    return 0
}

# Настройка FRR
configure_frr_service() {
    log "Настройка FRR..."
    
    # Включаем автозагрузку
    systemctl enable --now frr
    
    # Проверяем наличие файла
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        log_error "Файл $FRR_DAEMONS не найден!"
        return 1
    fi
    
    # Включаем OSPF
    sed -i 's/^#*ospfd=no/ospfd=yes/' "$FRR_DAEMONS"
    sed -i 's/^ospfd=no/ospfd=yes/' "$FRR_DAEMONS"
    
    log "OSPF демон включён"
    
    # Перезапускаем FRR
    systemctl restart frr
    log "Служба FRR перезапущена"
    
    return 0
}

# Генерация и применение OSPF конфигурации
apply_ospf_config() {
    log "Применение конфигурации OSPF..."
    
    # Создаём временный файл с командами
    local tmp_file=$(mktemp)
    
    cat > "$tmp_file" << 'OSPF_START'
conf t
router ospf
passive interface default
OSPF_START

    # Добавляем сеть туннеля
    echo "network 172.16.100.0/29 area 0" >> "$tmp_file"
    
    # Добавляем локальные сети
    for net in ${CONFIG[LOCAL_NETS]}; do
        echo "network $net area 0" >> "$tmp_file"
    done
    
    cat >> "$tmp_file" << OSPF_END
area 0 authentication
exit
interface ${CONFIG[TUNNEL_NAME]}
no ip ospf passive
ip ospf authentication-key ${CONFIG[OSPF_KEY]}
exit
do wr
end
exit
OSPF_END

    echo -e "\n${CYAN}Сгенерированные команды OSPF:${NC}"
    cat "$tmp_file"
    echo ""
    
    # Применяем через vtysh
    vtysh < "$tmp_file"
    
    rm -f "$tmp_file"
    
    log "Конфигурация OSPF применена"
    
    return 0
}

# Перезапуск сети
restart_network() {
    log "Перезапуск сети..."
    systemctl restart network
    sleep 2
    log "Сеть перезапущена"
}

# Проверка конфигурации
verify_setup() {
    log "Проверка конфигурации..."
    
    echo ""
    echo -e "${CYAN}════════════════════ ПРОВЕРКА КОНФИГУРАЦИИ ══════════════════${NC}"
    
    # Интерфейс туннеля
    echo ""
    echo -e "${YELLOW}1. Состояние туннеля ${CONFIG[TUNNEL_NAME]}:${NC}"
    ip addr show "${CONFIG[TUNNEL_NAME]}" 2>/dev/null || echo -e "   ${RED}Интерфейс не найден${NC}"
    
    # Соседи OSPF
    echo ""
    echo -e "${YELLOW}2. Соседи OSPF:${NC}"
    vtysh -c "show ip ospf neighbor" 2>/dev/null || echo -e "   ${RED}Не удалось получить информацию${NC}"
    
    # Маршруты OSPF
    echo ""
    echo -e "${YELLOW}3. Маршруты OSPF:${NC}"
    vtysh -c "show ip ospf route" 2>/dev/null || echo -e "   ${RED}Не удалось получить информацию${NC}"
    
    # Таблица маршрутизации
    echo ""
    echo -e "${YELLOW}4. Таблица маршрутизации:${NC}"
    ip route show | head -15
    
    # Ping тест
    echo ""
    echo -e "${YELLOW}5. Проверка связности туннеля:${NC}"
    local remote_tunnel_ip=""
    if [[ "${CONFIG[ROLE]}" == "HQ-RTR" ]]; then
        remote_tunnel_ip="172.16.100.1"
    else
        remote_tunnel_ip="172.16.100.2"
    fi
    
    echo "   Ping $remote_tunnel_ip..."
    ping -c 3 "$remote_tunnel_ip" 2>/dev/null || echo -e "   ${RED}Туннель недоступен${NC}"
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

main_menu() {
    while true; do
        show_header
        show_interfaces_table
        show_current_config
        
        echo -e "${CYAN}Меню действий:${NC}"
        echo ""
        echo -e "  ${YELLOW}1)${NC} Полная настройка (пошаговый мастер)"
        echo -e "  ${YELLOW}2)${NC} Редактировать отдельный параметр"
        echo -e "  ${YELLOW}3)${NC} Показать файлы конфигурации"
        echo -e "  ${YELLOW}4)${NC} Применить конфигурацию"
        echo -e "  ${YELLOW}5)${NC} Проверить состояние"
        echo -e "  ${YELLOW}6)${NC} Откатить изменения (удалить туннель)"
        echo ""
        echo -e "  ${RED}0)${NC} Выход"
        echo ""
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                # Полная пошаговая настройка
                configure_role
                pause
                configure_tunnel_name
                pause
                configure_tunlocal
                pause
                configure_tunremote
                pause
                configure_tunnel_ip
                pause
                configure_ospf_key
                pause
                configure_local_networks
                pause
                
                show_header
                show_current_config
                
                echo ""
                read -p "Применить конфигурацию? (y/n): " apply
                
                if [[ "$apply" =~ ^[Yy]$ ]]; then
                    create_tunnel_config
                    configure_frr_service
                    apply_ospf_config
                    restart_network
                    sleep 3
                    verify_setup
                fi
                pause
                ;;
                
            2)
                # Редактирование параметра
                show_header
                show_current_config
                
                echo ""
                read -p "Выберите номер параметра для редактирования [1-8]: " param
                edit_parameter "$param"
                pause
                ;;
                
            3)
                # Показать файлы конфигурации
                show_header
                echo -e "${CYAN}Файлы конфигурации:${NC}"
                echo ""
                
                local tunnel_name="${CONFIG[TUNNEL_NAME]:-gre1}"
                
                if [[ -f "$CONFIG_DIR/$tunnel_name/options" ]]; then
                    echo -e "${YELLOW}=== $CONFIG_DIR/$tunnel_name/options ===${NC}"
                    cat "$CONFIG_DIR/$tunnel_name/options"
                    echo ""
                fi
                
                if [[ -f "$CONFIG_DIR/$tunnel_name/ipv4address" ]]; then
                    echo -e "${YELLOW}=== $CONFIG_DIR/$tunnel_name/ipv4address ===${NC}"
                    cat "$CONFIG_DIR/$tunnel_name/ipv4address"
                    echo ""
                fi
                
                echo -e "${YELLOW}=== OSPF конфигурация (show running-config) ===${NC}"
                vtysh -c "show running-config" 2>/dev/null | grep -A 20 "router ospf"
                
                pause
                ;;
                
            4)
                # Применить конфигурацию
                show_header
                
                if [[ -z "${CONFIG[ROLE]}" ]]; then
                    log_error "Сначала настройте параметры! Используйте пункт 1."
                    pause
                    continue
                fi
                
                show_current_config
                echo ""
                read -p "Подтверждаете применение конфигурации? (y/n): " confirm
                
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    create_tunnel_config
                    configure_frr_service
                    apply_ospf_config
                    restart_network
                    sleep 3
                    verify_setup
                fi
                pause
                ;;
                
            5)
                # Проверить состояние
                show_header
                verify_setup
                pause
                ;;
                
            6)
                # Откат изменений
                show_header
                local tunnel_name="${CONFIG[TUNNEL_NAME]:-gre1}"
                
                echo -e "${RED}ВНИМАНИЕ! Это действие удалит туннель $tunnel_name!${NC}"
                echo ""
                read -p "Вы уверены? (yes/no): " confirm
                
                if [[ "$confirm" == "yes" ]]; then
                    rm -rf "$CONFIG_DIR/$tunnel_name"
                    log "Туннель $tunnel_name удалён"
                    
                    echo ""
                    read -p "Удалить конфигурацию OSPF? (y/n): " del_ospf
                    if [[ "$del_ospf" =~ ^[Yy]$ ]]; then
                        vtysh -c "conf t" -c "no router ospf" -c "end" -c "do wr" 2>/dev/null
                        log "Конфигурация OSPF удалена"
                    fi
                    
                    systemctl restart network
                fi
                pause
                ;;
                
            0)
                echo ""
                log "Выход из скрипта"
                exit 0
                ;;
                
            *)
                echo -e "${RED}Неверный выбор${NC}"
                pause
                ;;
        esac
    done
}

#===============================================================================
# ТОЧКА ВХОДА
#===============================================================================

# Проверка прав
check_root

# Инициализация лога
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null

# Запуск главного меню
main_menu
