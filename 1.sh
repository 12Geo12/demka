#!/bin/bash
# ==============================================================================
# Скрипт настройки IP-адресов для ALT Linux через /etc/net/ifaces/
# Поддержка: статический IP, DHCP, VLAN, маршруты
# ==============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"

# Функции вывода
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[WARN]${NC} $1"; }
line() { echo -e "${CYAN}================================================${NC}"; }

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    msg_er "Запустите скрипт от имени root"
    exit 1
fi

# Проверка существования директории ALT Net
if [ ! -d "$IFACES_DIR" ]; then
    msg_er "Директория $IFACES_DIR не найдена."
    msg_in "Этот скрипт предназначен для ALT Linux с /etc/net/ifaces/"
    exit 1
fi

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

# Получение списка физических интерфейсов
get_physical_interfaces() {
    local ifaces=""
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v -E "^(lo|docker|veth|virbr|sit|br-|flannel|cni|tun|tap|bond|gre)"); do
        # Исключаем VLAN интерфейсы (содержат точку)
        if [[ "$iface" != *"."* ]]; then
            ifaces="$ifaces $iface"
        fi
    done
    echo "$ifaces"
}

# Получение IP адреса интерфейса
get_iface_ip() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1
}

# Получение MAC адреса
get_iface_mac() {
    local iface=$1
    if [ -f "/sys/class/net/${iface}/address" ]; then
        cat "/sys/class/net/${iface}/address"
    else
        echo "N/A"
    fi
}

# Получение статуса интерфейса
get_iface_status() {
    local iface=$1
    local state
    if [ -f "/sys/class/net/${iface}/operstate" ]; then
        state=$(cat "/sys/class/net/${iface}/operstate")
        case "$state" in
            up|UP) echo "UP" ;;
            down|DOWN) echo "DOWN" ;;
            *) echo "$state" ;;
        esac
    else
        echo "UNKNOWN"
    fi
}

# Показ интерфейсов
show_interfaces() {
    echo ""
    line
    echo -e "${WHITE}  Доступные сетевые интерфейсы${NC}"
    line
    echo ""
    
    local ifaces=$(get_physical_interfaces)
    
    if [ -z "$ifaces" ]; then
        msg_er "Не найдено подходящих сетевых интерфейсов"
        exit 1
    fi
    
    printf "  %-4s %-16s %-10s %-20s %-20s\n" "№" "Интерфейс" "Статус" "MAC-адрес" "IP-адрес"
    echo "  ------------------------------------------------------------------------"
    
    local i=1
    for iface in $ifaces; do
        local status=$(get_iface_status "$iface")
        local mac=$(get_iface_mac "$iface")
        local ip=$(get_iface_ip "$iface")
        [ -z "$ip" ] && ip="не назначен"
        
        local status_colored
        if [ "$status" = "UP" ]; then
            status_colored="${GREEN}UP${NC}"
        else
            status_colored="${YELLOW}$status${NC}"
        fi
        
        printf "  [%-2d] %-16s " "$i" "$iface"
        echo -e "$status_colored\t\t$mac\t\t$ip"
        
        i=$((i + 1))
    done
    
    echo ""
}

# Выбор интерфейса по номеру
select_interface() {
    local idx=$1
    local ifaces=$(get_physical_interfaces)
    echo "$ifaces" | awk -v n="$idx" '{print $n}'
}

# Проверка валидности IP адреса
validate_ip() {
    local ip=$1
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ "$ip" =~ $regex ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Проверка валидности маски (CIDR)
validate_cidr() {
    local cidr=$1
    if [[ "$cidr" =~ ^[0-9]+$ ]] && [ "$cidr" -ge 0 ] && [ "$cidr" -le 32 ]; then
        return 0
    fi
    return 1
}

# Создание конфигурации статического IP
create_static_config() {
    local iface=$1
    local ip=$2
    local cidr=$3
    local gateway=$4
    local dns1=$5
    local dns2=$6
    
    local iface_dir="$IFACES_DIR/$iface"
    
    echo -e "    ${GREEN}->${NC} Настройка $iface..."
    
    # Создаем директорию
    mkdir -p "$iface_dir"
    
    # Создаем options
    cat > "$iface_dir/options" <<EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
CONFIG_IPV4=yes
EOF

    # Создаем ipv4address
    echo "$ip/$cidr" > "$iface_dir/ipv4address"
    
    # Создаем ipv4route если указан шлюз
    if [ -n "$gateway" ]; then
        echo "default via $gateway" > "$iface_dir/ipv4route"
    fi
    
    # Создаем resolv.conf если указаны DNS
    if [ -n "$dns1" ] || [ -n "$dns2" ]; then
        {
            [ -n "$dns1" ] && echo "nameserver $dns1"
            [ -n "$dns2" ] && echo "nameserver $dns2"
        } > "$iface_dir/resolv.conf"
    fi
    
    echo -e "       IP: ${CYAN}$ip/$cidr${NC}"
    [ -n "$gateway" ] && echo -e "       Шлюз: ${CYAN}$gateway${NC}"
    [ -n "$dns1" ] && echo -e "       DNS: ${CYAN}$dns1${NC}"
    [ -n "$dns2" ] && echo -e "       DNS: ${CYAN}$dns2${NC}"
}

# Создание конфигурации DHCP
create_dhcp_config() {
    local iface=$1
    
    local iface_dir="$IFACES_DIR/$iface"
    
    echo -e "    ${GREEN}->${NC} Настройка $iface (DHCP)..."
    
    # Создаем директорию
    mkdir -p "$iface_dir"
    
    # Создаем options
    cat > "$iface_dir/options" <<EOF
BOOTPROTO=dhcp
TYPE=eth
ONBOOT=yes
DISABLED=no
CONFIG_IPV4=yes
EOF

    # Удаляем старые файлы если есть
    rm -f "$iface_dir/ipv4address" "$iface_dir/ipv4route" 2>/dev/null
    
    echo -e "       Режим: ${CYAN}DHCP${NC}"
}

# Показ текущей конфигурации
show_current_config() {
    local iface=$1
    local iface_dir="$IFACES_DIR/$iface"
    
    echo ""
    echo -e "${CYAN}=== Текущая конфигурация $iface ===${NC}"
    
    if [ -d "$iface_dir" ]; then
        echo ""
        if [ -f "$iface_dir/options" ]; then
            echo -e "${WHITE}options:${NC}"
            cat "$iface_dir/options" | sed 's/^/  /'
        fi
        
        if [ -f "$iface_dir/ipv4address" ]; then
            echo -e "${WHITE}ipv4address:${NC}"
            cat "$iface_dir/ipv4address" | sed 's/^/  /'
        fi
        
        if [ -f "$iface_dir/ipv4route" ]; then
            echo -e "${WHITE}ipv4route:${NC}"
            cat "$iface_dir/ipv4route" | sed 's/^/  /'
        fi
        
        if [ -f "$iface_dir/resolv.conf" ]; then
            echo -e "${WHITE}resolv.conf:${NC}"
            cat "$iface_dir/resolv.conf" | sed 's/^/  /'
        fi
    else
        echo -e "${YELLOW}Конфигурация не найдена${NC}"
    fi
}

# Удаление конфигурации
delete_config() {
    local iface=$1
    local iface_dir="$IFACES_DIR/$iface"
    
    if [ -d "$iface_dir" ]; then
        # Отключаем интерфейс
        ip link set "$iface" down 2>/dev/null
        
        # Удаляем конфигурацию
        rm -rf "$iface_dir"
        msg_ok "Конфигурация $iface удалена"
    else
        msg_wa "Конфигурация для $iface не найдена"
    fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}         ${WHITE}IP Configuration for ALT Linux${NC}                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}           ${YELLOW}Управление /etc/net/ifaces/${NC}                      ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo "Выберите действие:"
echo "  1) Настроить статический IP"
echo "  2) Настроить DHCP"
echo "  3) Показать конфигурацию интерфейса"
echo "  4) Удалить конфигурацию интерфейса"
echo "  5) Показать все интерфейсы"
echo "  6) Выход"
read -p "Ваш выбор [1]: " main_action
main_action=${main_action:-1}

case "$main_action" in
    1)
        # Статический IP
        show_interfaces
        read -p "Выберите номер интерфейса: " iface_idx
        
        IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$IFACE" ]; then
            msg_er "Неверный выбор интерфейса"
            exit 1
        fi
        
        show_current_config "$IFACE"
        
        echo ""
        echo -e "${WHITE}Настройка статического IP для $IFACE${NC}"
        echo ""
        
        # IP адрес
        while true; do
            read -p "Введите IP адрес: " IP_ADDR
            if validate_ip "$IP_ADDR"; then
                break
            else
                msg_er "Некорректный IP адрес"
            fi
        done
        
        # Маска CIDR
        while true; do
            read -p "Введите маску CIDR [24]: " CIDR
            CIDR=${CIDR:-24}
            if validate_cidr "$CIDR"; then
                break
            else
                msg_er "Маска должна быть от 0 до 32"
            fi
        done
        
        # Шлюз
        read -p "Введите шлюз (Enter - пропустить): " GATEWAY
        if [ -n "$GATEWAY" ] && ! validate_ip "$GATEWAY"; then
            msg_wa "Некорректный шлюз, будет пропущен"
            GATEWAY=""
        fi
        
        # DNS
        read -p "Введите DNS1 (Enter - пропустить): " DNS1
        if [ -n "$DNS1" ] && ! validate_ip "$DNS1"; then
            msg_wa "Некорректный DNS1, будет пропущен"
            DNS1=""
        fi
        
        read -p "Введите DNS2 (Enter - пропустить): " DNS2
        if [ -n "$DNS2" ] && ! validate_ip "$DNS2"; then
            msg_wa "Некорректный DNS2, будет пропущен"
            DNS2=""
        fi
        
        # Подтверждение
        echo ""
        echo -e "${CYAN}Конфигурация:${NC}"
        echo "  Интерфейс: $IFACE"
        echo "  IP: $IP_ADDR/$CIDR"
        [ -n "$GATEWAY" ] && echo "  Шлюз: $GATEWAY"
        [ -n "$DNS1" ] && echo "  DNS1: $DNS1"
        [ -n "$DNS2" ] && echo "  DNS2: $DNS2"
        
        read -p "Применить? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            create_static_config "$IFACE" "$IP_ADDR" "$CIDR" "$GATEWAY" "$DNS1" "$DNS2"
            msg_ok "Конфигурация создана"
            
            read -p "Перезапустить сеть? (y/n): " restart
            if [[ "$restart" =~ ^[Yy] ]]; then
                echo "Перезапуск сети..."
                systemctl restart network 2>/dev/null || /etc/init.d/network restart
                msg_ok "Сеть перезапущена"
            fi
        else
            echo "Отменено"
        fi
        ;;
        
    2)
        # DHCP
        show_interfaces
        read -p "Выберите номер интерфейса: " iface_idx
        
        IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$IFACE" ]; then
            msg_er "Неверный выбор интерфейса"
            exit 1
        fi
        
        show_current_config "$IFACE"
        
        read -p "Настроить DHCP для $IFACE? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            create_dhcp_config "$IFACE"
            msg_ok "DHCP настроен"
            
            read -p "Перезапустить сеть? (y/n): " restart
            if [[ "$restart" =~ ^[Yy] ]]; then
                echo "Перезапуск сети..."
                systemctl restart network 2>/dev/null || /etc/init.d/network restart
                msg_ok "Сеть перезапущена"
            fi
        else
            echo "Отменено"
        fi
        ;;
        
    3)
        # Показать конфигурацию
        show_interfaces
        read -p "Выберите номер интерфейса: " iface_idx
        
        IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$IFACE" ]; then
            msg_er "Неверный выбор интерфейса"
            exit 1
        fi
        
        show_current_config "$IFACE"
        ;;
        
    4)
        # Удалить конфигурацию
        show_interfaces
        read -p "Выберите номер интерфейса: " iface_idx
        
        IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$IFACE" ]; then
            msg_er "Неверный выбор интерфейса"
            exit 1
        fi
        
        show_current_config "$IFACE"
        
        read -p "Удалить конфигурацию $IFACE? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            delete_config "$IFACE"
        else
            echo "Отменено"
        fi
        ;;
        
    5)
        # Показать все интерфейсы
        show_interfaces
        
        echo ""
        for iface in $(get_physical_interfaces); do
            show_current_config "$iface"
        done
        ;;
        
    6)
        echo "Выход..."
        exit 0
        ;;
        
    *)
        msg_er "Неверный выбор"
        exit 1
        ;;
esac

echo ""
msg_ok "Готово!"
echo ""
