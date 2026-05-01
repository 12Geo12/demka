#!/bin/bash
# ==============================================================================
# Улучшенный скрипт настройки VLAN для ALT Linux
# - Надёжное получение статуса и MAC интерфейсов
# - Проверка существующих VLAN
# - Меню: создать/показать/удалить VLAN
# - Работающие цвета
# ==============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then 
    echo -e "${RED}Ошибка: Запустите скрипт от имени root${NC}"
    exit 1
fi

# Проверка существования директории ALT Net
if [ ! -d "$IFACES_DIR" ]; then
    echo -e "${RED}Ошибка: Директория $IFACES_DIR не найдена.${NC}"
    echo "Этот скрипт предназначен для ALT Linux."
    exit 1
fi

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

# Расчет маски по количеству хостов
calculate_cidr() {
    local hosts=$1
    local bits=0
    
    # Защита от некорректных значений
    if [ "$hosts" -lt 1 ]; then
        hosts=1
    fi
    if [ "$hosts" -gt 254 ]; then
        hosts=254
    fi
    
    # Вычисляем необходимое количество бит для хостов
    while [ $(( (1 << bits) - 2 )) -lt "$hosts" ]; do
        bits=$((bits + 1))
        if [ $bits -gt 30 ]; then
            bits=30
            break
        fi
    done
    
    echo $((32 - bits))
}

# Надёжное получение статуса интерфейса
get_iface_status() {
    local iface=$1
    local state
    
    # Получаем состояние из /sys/class/net
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

# Надёжное получение MAC-адреса
get_iface_mac() {
    local iface=$1
    
    # Получаем MAC из /sys/class/net
    if [ -f "/sys/class/net/${iface}/address" ]; then
        cat "/sys/class/net/${iface}/address"
    else
        echo "N/A"
    fi
}

# Получение IP адреса интерфейса
get_iface_ip() {
    local iface=$1
    
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1
}

# Показать существующие VLAN
show_existing_vlans() {
    local iface=$1
    local found=0
    
    echo ""
    echo -e "${CYAN}=== Существующие VLAN на интерфейсе $iface ===${NC}"
    
    # Проверяем /etc/net/ifaces
    for dir in "$IFACES_DIR"/${iface}.*; do
        if [ -d "$dir" ]; then
            found=1
            local vlan_name=$(basename "$dir")
            local vlan_ip=$(cat "$dir/ipv4address" 2>/dev/null || echo "не назначен")
            local vlan_id=$(grep "^VID=" "$dir/options" 2>/dev/null | cut -d= -f2 || echo "?")
            
            # Статус интерфейса
            local status=$(get_iface_status "$vlan_name")
            local status_out
            if [ "$status" = "UP" ]; then
                status_out="${GREEN}UP${NC}"
            else
                status_out="${YELLOW}$status${NC}"
            fi
            
            printf "  %-20s VLAN ID: %-5s IP: %-20s Статус: " "$vlan_name" "$vlan_id" "$vlan_ip"
            echo -e "$status_out"
        fi
    done
    
    # Также проверяем активные интерфейсы
    local active_vlans=$(ip -o link show 2>/dev/null | grep -E "${iface}\." | awk -F': ' '{print $2}')
    for v in $active_vlans; do
        if [ ! -d "$IFACES_DIR/$v" ]; then
            found=1
            local vlan_ip=$(get_iface_ip "$v")
            local status=$(get_iface_status "$v")
            local status_out
            if [ "$status" = "UP" ]; then
                status_out="${GREEN}UP${NC}"
            else
                status_out="${YELLOW}$status${NC}"
            fi
            printf "  %-20s %s%-10s%s IP: %-20s Статус: " "$v" "${YELLOW}" "(без конфига)" "${NC}" "$vlan_ip"
            echo -e "$status_out"
        fi
    done
    
    if [ $found -eq 0 ]; then
        echo -e "  ${YELLOW}VLAN не найдены${NC}"
    fi
}

# Создание конфига VLAN
create_vlan_config() {
    local vlan_name=$1
    local vlan_id=$2
    local iface=$3
    local network_octet=$4
    local hosts=$5
    local base_net=$6
    
    local cidr=$(calculate_cidr "$hosts")
    local vlan_iface_name="${iface}.${vlan_id}"
    local vlan_dir="$IFACES_DIR/${vlan_iface_name}"
    local network_ip="${base_net}.${network_octet}.0"
    
    # Формируем IP адрес (.1 для шлюза)
    local ip_address="${base_net}.${network_octet}.1/${cidr}"
    local full_network="${network_ip}/${cidr}"
    
    echo -e "    ${GREEN}->${NC} Создание $vlan_iface_name ($vlan_name)..."
    
    # 1. Создаем директорию
    mkdir -p "$vlan_dir"
    
    # 2. Создаем конфиг options
    cat > "$vlan_dir/options" <<EOF
BOOTPROTO=static
TYPE=vlan
ONBOOT=yes
HOST=${iface}
VID=${vlan_id}
DISABLED=no
CONFIG_IPV4=yes
EOF

    # 3. Создаем ipv4address
    echo "$ip_address" > "$vlan_dir/ipv4address"
    
    echo -e "       Сеть: ${CYAN}$full_network${NC}, IP: ${CYAN}$ip_address${NC}"
}

# Удаление VLAN
delete_vlan() {
    local vlan_iface=$1
    local vlan_dir="$IFACES_DIR/$vlan_iface"
    
    echo -e "${YELLOW}Удаление VLAN $vlan_iface...${NC}"
    
    # 1. Останавливаем интерфейс
    ip link set "$vlan_iface" down 2>/dev/null
    
    # 2. Удаляем из системы
    ip link del "$vlan_iface" 2>/dev/null
    
    # 3. Удаляем конфигурацию
    if [ -d "$vlan_dir" ]; then
        rm -rf "$vlan_dir"
        echo -e "${GREEN}[OK]${NC} Конфигурация $vlan_dir удалена"
    fi
    
    echo -e "${GREEN}[OK]${NC} VLAN $vlan_iface удалён"
}

# Получение списка интерфейсов
get_iface_list() {
    ls /sys/class/net/ 2>/dev/null | grep -v -E "^(lo|docker|veth|virbr|sit|br-|flannel|cni|tun|tap|bond|gre)"
}

# Показ интерфейсов
show_interfaces() {
    echo ""
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${WHITE}  Обнаружение сетевых интерфейсов системы${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""
    
    local ifaces=$(get_iface_list)
    
    if [ -z "$ifaces" ]; then
        echo -e "${RED}Ошибка: Не найдено подходящих сетевых интерфейсов.${NC}"
        exit 1
    fi
    
    # Выводим список
    echo "Обнаружены следующие сетевые интерфейсы:"
    echo ""
    printf "  %-4s %-16s %-10s %-20s %-20s\n" "№" "Интерфейс" "Статус" "MAC-адрес" "IP-адрес"
    echo "  ------------------------------------------------------------------------"
    
    local i=1
    for iface in $ifaces; do
        local status=$(get_iface_status "$iface")
        local mac=$(get_iface_mac "$iface")
        local ip=$(get_iface_ip "$iface")
        [ -z "$ip" ] && ip="не назначен"
        
        # Цвет статуса
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
    echo -e "  ${GREEN}UP${NC} = интерфейс активен, ${YELLOW}DOWN${NC} = интерфейс неактивен"
    echo ""
}

# Выбор интерфейса по номеру
select_interface() {
    local idx=$1
    local ifaces=$(get_iface_list)
    echo "$ifaces" | sed -n "${idx}p"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}         ${WHITE}VLAN Configuration for ALT Linux${NC}                  ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo "Выберите действие:"
echo "  1) Создать VLAN"
echo "  2) Показать существующие VLAN"
echo "  3) Удалить VLAN"
echo "  4) Выход"
read -p "Ваш выбор [1]: " main_action
main_action=${main_action:-1}

case "$main_action" in
    2)
        # Показать VLAN
        show_interfaces
        read -p "Выберите номер интерфейса: " iface_idx
        
        PHYS_IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$PHYS_IFACE" ]; then
            echo -e "${RED}Ошибка: Неверный выбор интерфейса${NC}"
            exit 1
        fi
        
        show_existing_vlans "$PHYS_IFACE"
        exit 0
        ;;
    3)
        # Удалить VLAN
        show_interfaces
        read -p "Выберите номер физического интерфейса: " iface_idx
        
        PHYS_IFACE=$(select_interface "$iface_idx")
        
        if [ -z "$PHYS_IFACE" ]; then
            echo -e "${RED}Ошибка: Неверный выбор интерфейса${NC}"
            exit 1
        fi
        
        show_existing_vlans "$PHYS_IFACE"
        echo ""
        read -p "Введите имя VLAN для удаления (например, ${PHYS_IFACE}.10): " vlan_to_delete
        
        if [ -z "$vlan_to_delete" ]; then
            echo -e "${RED}Ошибка: Не указано имя VLAN${NC}"
            exit 1
        fi
        
        read -p "Подтвердите удаление $vlan_to_delete? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            delete_vlan "$vlan_to_delete"
        else
            echo "Отменено"
        fi
        exit 0
        ;;
    4)
        echo "Выход..."
        exit 0
        ;;
esac

# ==============================================================================
# СОЗДАНИЕ VLAN
# ==============================================================================

show_interfaces

# Запрос выбора интерфейса
IFACE_COUNT=$(get_iface_list | wc -w)

while true; do
    read -p "Введите номер интерфейса для настройки VLAN [1]: " SELECTION
    SELECTION=${SELECTION:-1}
    
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$IFACE_COUNT" ]; then
        PHYS_IFACE=$(select_interface "$SELECTION")
        break
    else
        echo -e "${RED}Ошибка: введите число от 1 до $IFACE_COUNT${NC}"
    fi
done

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${WHITE}  Выбран интерфейс: ${CYAN}$PHYS_IFACE${NC}"
echo -e "${GREEN}========================================================${NC}"

# Показываем существующие VLAN на интерфейсе
show_existing_vlans "$PHYS_IFACE"

# Общие параметры
echo ""
read -p "Введите первые два октета сети [192.168]: " BASE_NETWORK_INPUT
BASE_NETWORK=${BASE_NETWORK_INPUT:-192.168}

# Убедимся, что физический интерфейс имеет корректный конфиг
PHYS_DIR="$IFACES_DIR/${PHYS_IFACE}"
if [ ! -d "$PHYS_DIR" ]; then
    echo -e "${YELLOW}Создание конфигурации для $PHYS_IFACE...${NC}"
    mkdir -p "$PHYS_DIR"
    cat > "$PHYS_DIR/options" <<EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
EOF
fi

# Ввод данных по VLAN
echo ""
read -p "Сколько VLAN нужно создать? [2]: " VLAN_COUNT
VLAN_COUNT=${VLAN_COUNT:-2}

# Проверка корректности
if ! [[ "$VLAN_COUNT" =~ ^[0-9]+$ ]] || [ "$VLAN_COUNT" -lt 1 ]; then
    echo -e "${RED}Ошибка: некорректное количество VLAN${NC}"
    exit 1
fi

# Временный файл для хранения данных VLAN
VLANS_FILE=$(mktemp)

echo ""
echo -e "${CYAN}--------------------------------------------------------${NC}"
echo -e "${WHITE}  Настройка параметров для $VLAN_COUNT VLAN(s)${NC}"
echo -e "${CYAN}--------------------------------------------------------${NC}"

i=1
while [ "$i" -le "$VLAN_COUNT" ]; do
    echo ""
    echo -e "${MAGENTA}--- VLAN #$i ---${NC}"
    
    # ID VLAN
    while true; do
        read -p "VLAN ID (1-4094): " V_ID
        if [[ "$V_ID" =~ ^[0-9]+$ ]] && [ "$V_ID" -ge 1 ] && [ "$V_ID" -le 4094 ]; then
            # Проверяем, не занят ли VLAN ID
            if [ -d "$IFACES_DIR/${PHYS_IFACE}.${V_ID}" ]; then
                echo -e "${YELLOW}Внимание: VLAN ID $V_ID уже существует на этом интерфейсе!${NC}"
                read -p "Использовать другой ID? (y/n) [y]: " change_id
                if [[ "$change_id" != "n" ]]; then
                    continue
                fi
            fi
            break
        else
            echo -e "${RED}Ошибка: VLAN ID должен быть числом от 1 до 4094${NC}"
        fi
    done

    # Третий октет подсети
    default_octet=$((i * 10))
    while true; do
        read -p "3-й октет подсети (для ${BASE_NETWORK}.X.0) [$default_octet]: " V_OCTET
        V_OCTET=${V_OCTET:-$default_octet}
        if [[ "$V_OCTET" =~ ^[0-9]+$ ]] && [ "$V_OCTET" -ge 0 ] && [ "$V_OCTET" -le 255 ]; then
            break
        else
            echo -e "${RED}Ошибка: Октет должен быть числом от 0 до 255${NC}"
        fi
    done

    # Кол-во хостов
    read -p "Требуемое кол-во хостов [254]: " V_HOSTS
    V_HOSTS=${V_HOSTS:-254}

    # Сохраняем данные (имя автоматически VLAN_N)
    V_NAME="VLAN_$i"
    echo "${V_NAME}|${V_ID}|${V_OCTET}|${V_HOSTS}" >> "$VLANS_FILE"
    
    i=$((i + 1))
done

# ==============================================================================
# ПОДТВЕРЖДЕНИЕ
# ==============================================================================

echo ""
echo -e "${CYAN}========================================================${NC}"
echo -e "${WHITE}  Проверка конфигурации перед применением${NC}"
echo -e "${CYAN}========================================================${NC}"
echo "Физический интерфейс: $PHYS_IFACE"
echo "Базовая сеть: $BASE_NETWORK.0.0"
echo ""

printf "%-5s %-15s %-10s %-20s %-10s\n" "№" "Название" "VLAN ID" "Сеть" "Хостов"
echo "-----------------------------------------------------------"

i=1
while IFS='|' read -r v_name v_id v_octet v_hosts; do
    cidr=$(calculate_cidr "$v_hosts")
    printf "%-5s %-15s %-10s %-20s %-10s\n" \
        "#$i" \
        "$v_name" \
        "$v_id" \
        "${BASE_NETWORK}.${v_octet}.0/${cidr}" \
        "$v_hosts"
    i=$((i + 1))
done < "$VLANS_FILE"

echo ""
read -p "Продолжить настройку? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Настройка отменена."
    rm -f "$VLANS_FILE"
    exit 0
fi

# ==============================================================================
# ПРИМЕНЕНИЕ НАСТРОЕК
# ==============================================================================

echo ""
echo -e "${CYAN}Применение настроек...${NC}"
echo "------------------------------------------------"

while IFS='|' read -r v_name v_id v_octet v_hosts; do
    create_vlan_config "$v_name" "$v_id" "$PHYS_IFACE" "$v_octet" "$v_hosts" "$BASE_NETWORK"
done < "$VLANS_FILE"

rm -f "$VLANS_FILE"

echo ""
echo "------------------------------------------------"
echo -e "${GREEN}Конфигурация завершена!${NC}"

# Перезапуск сети
read -p "Перезапустить сетевую службу сейчас? (y/n): " RESTART_NET

if [[ "$RESTART_NET" =~ ^[Yy] ]]; then
    echo "Перезапуск службы сети..."
    if command -v systemctl > /dev/null 2>&1; then
        systemctl restart network
    else
        /etc/init.d/network restart
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK] Сеть перезагружена успешно.${NC}"
    else
        echo -e "${YELLOW}[!] Произошла ошибка при перезагрузке.${NC}"
    fi
fi

# Итоговый вывод
echo ""
echo -e "${CYAN}========================================================${NC}"
echo -e "${WHITE}  Итоговый список интерфейсов${NC}"
echo -e "${CYAN}========================================================${NC}"

# Показываем физический интерфейс и созданные VLAN
echo -e "${WHITE}Физический интерфейс:${NC}"
ip -brief addr show "$PHYS_IFACE" 2>/dev/null || ip addr show "$PHYS_IFACE"

echo ""
echo -e "${WHITE}Созданные VLAN:${NC}"
for dir in "$IFACES_DIR"/${PHYS_IFACE}.*; do
    if [ -d "$dir" ]; then
        vlan_name=$(basename "$dir")
        ip -brief addr show "$vlan_name" 2>/dev/null || echo "$vlan_name - не активен"
    fi
done

echo ""
echo -e "${GREEN}Готово!${NC}"
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo "  ip link show              - показать все интерфейсы"
echo "  ip addr show ${PHYS_IFACE}    - показать IP физического интерфейса"
echo "  ip -brief addr            - краткий список IP адресов"
echo ""
