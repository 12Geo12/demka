#!/bin/bash

# ==============================================================================
# Скрипт настройки VLAN для ALT Linux (Интерактивный выбор интерфейса и кол-ва VLAN)
# ==============================================================================

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите скрипт от имени root (sudo ./setup_vlans.sh)"
  exit 1
fi

# Проверка существования директории ALT Net
if [ ! -d "/etc/net/ifaces" ]; then
    echo "Ошибка: Директория /etc/net/ifaces не найдена."
    echo "Этот скрипт предназначен для ALT Linux."
    exit 1
fi

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

# Расчет маски по количеству хостов
calculate_cidr() {
    local hosts=$1
    local bits=1
    while (( (1 << bits) - 2 < hosts )); do
        ((bits++))
    done
    echo $((32 - bits))
}

# Создание конфига VLAN
create_vlan_config() {
    local vlan_name=$1      # Имя/Описание
    local vlan_id=$2        # Номер VLAN
    local iface=$3          # Физический интерфейс
    local network_octet=$4  # Третий октет
    local hosts=$5          # Кол-во хостов
    local base_net=$6       # Базовая сеть (192.168)
    
    local cidr=$(calculate_cidr $hosts)
    local vlan_iface_name="${iface}.${vlan_id}"
    local vlan_dir="/etc/net/ifaces/${vlan_iface_name}"
    local network_ip="${base_net}.${network_octet}.0"
    local ip_address="${network_ip%.*}.2/$cidr" # IP сервера (.2)
    local full_network="${network_ip}/${cidr}"
    
    echo "    -> Создание $vlan_iface_name ($vlan_name)..."
    
    # 1. Создаем директорию
    mkdir -p "$vlan_dir"
    
    # 2. Создаем корректный конфиг options (перезаписываем, если есть)
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
    
    echo "       Сеть: $full_network, IP: $ip_address"
}

# ==============================================================================
# ВЫБОР ФИЗИЧЕСКОГО ИНТЕРФЕЙСА
# ==============================================================================

echo "========================================================"
echo "  Поиск доступных интерфейсов"
echo "========================================================"

# Получаем список интерфейсов, исключая lo, docker, veth, virbr
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "^(lo|docker|veth|virbr|sit)")

if [ ${#IFACES[@]} -eq 0 ]; then
    echo "Ошибка: Не найдено подходящих сетевых интерфейсов."
    exit 1
fi

# Выводим список
echo "Доступные интерфейсы:"
for i in "${!IFACES[@]}"; do
    # Получаем статус UP/DOWN и MAC для наглядности
    STATUS=$(ip -o link show "${IFACES[$i]}" | awk '{print $9}')
    MAC=$(ip -o link show "${IFACES[$i]}" | awk '{print $17}')
    printf "  [%d] %s (Status: %s, MAC: %s)\n" "$((i+1))" "${IFACES[$i]}" "$STATUS" "$MAC"
done

# Запрос выбора
while true; do
    read -p "Выберите номер интерфейса для настройки: " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le ${#IFACES[@]} ]; then
        PHYS_IFACE="${IFACES[$((SELECTION-1))]}"
        break
    else
        echo "Неверный ввод. Пожалуйста, введите число от 1 до ${#IFACES[@]}."
    fi
done

echo "Выбран интерфейс: $PHYS_IFACE"

# ==============================================================================
# ОБЩИЕ ПАРАМЕТРЫ
# ==============================================================================

read -p "Введите первые два октета сети [192.168]: " BASE_NETWORK_INPUT
BASE_NETWORK=${BASE_NETWORK_INPUT:-192.168}

# Убедимся, что физический интерфейс имеет корректный конфиг
PHYS_DIR="/etc/net/ifaces/${PHYS_IFACE}"
if [ ! -d "$PHYS_DIR" ]; then
    mkdir -p "$PHYS_DIR"
    cat > "$PHYS_DIR/options" <<EOF
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
EOF
fi

# ==============================================================================
# ВВОД ДАННЫХ ПО VLAN
# ==============================================================================

echo ""
read -p "Сколько VLAN нужно создать? [2]: " VLAN_COUNT
VLAN_COUNT=${VLAN_COUNT:-2}

# Массивы для хранения данных
declare -a VLANS_ID
declare -a VLANS_NAME
declare -a VLANS_HOSTS
declare -a VLANS_OCTET

echo ""
echo "--------------------------------------------------------"
echo "  Настройка параметров для $VLAN_COUNT VLAN(s)"
echo "--------------------------------------------------------"

for (( i=1; i<=VLAN_COUNT; i++ )); do
    echo ""
    echo "--- VLAN #$i ---"
    
    # Имя/Описание
    read -p "Название/Описание (например, Office): " V_NAME
    
    # ID VLAN
    while true; do
        read -p "VLAN ID (число): " V_ID
        if [[ "$V_ID" =~ ^[0-9]+$ ]] && [ "$V_ID" -ge 1 ] && [ "$V_ID" -le 4094 ]; then
            break
        else
            echo "Ошибка: VLAN ID должен быть числом от 1 до 4094."
        fi
    done

    # Третий октет подсети
    while true; do
        read -p "3-й октет подсети (для ${BASE_NETWORK}.X.0) [${i}0]: " V_OCTET
        V_OCTET=${V_OCTET:-$((i*10))}
        if [[ "$V_OCTET" =~ ^[0-9]+$ ]] && [ "$V_OCTET" -ge 0 ] && [ "$V_OCTET" -le 255 ]; then
            break
        else
            echo "Ошибка: Октет должен быть числом от 0 до 255."
        fi
    done

    # Кол-во хостов
    read -p "Требуемое кол-во хостов [254]: " V_HOSTS
    V_HOSTS=${V_HOSTS:-254}

    # Сохраняем данные
    VLANS_NAME+=("$V_NAME")
    VLANS_ID+=("$V_ID")
    VLANS_OCTET+=("$V_OCTET")
    VLANS_HOSTS+=("$V_HOSTS")
done

# ==============================================================================
# ПОДТВЕРЖДЕНИЕ
# ==============================================================================

echo ""
echo "========================================================"
echo "  Проверка конфигурации перед применением"
echo "========================================================"
echo "Физический интерфейс: $PHYS_IFACE"
echo "Базовая сеть: $BASE_NETWORK.0.0"
echo ""

printf "%-5s %-15s %-10s %-15s %-10s\n" "ID" "Название" "VLAN ID" "Сеть" "Хостов"
echo "-----------------------------------------------------------"

for (( i=0; i<VLAN_COUNT; i++ )); do
    cidr=$(calculate_cidr ${VLANS_HOSTS[$i]})
    printf "%-5s %-15s %-10s %-15s %-10s\n" \
        "#$((i+1))" \
        "${VLANS_NAME[$i]}" \
        "${VLANS_ID[$i]}" \
        "${BASE_NETWORK}.${VLANS_OCTET[$i]}.0/${cidr}" \
        "${VLANS_HOSTS[$i]}"
done

echo ""
read -p "Продолжить настройку? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Настройка отменена."
    exit 0
fi

# ==============================================================================
# ПРИМЕНЕНИЕ НАСТРОЕК
# ==============================================================================

echo ""
echo "Применение настроек..."
echo "------------------------------------------------"

for (( i=0; i<VLAN_COUNT; i++ )); do
    create_vlan_config "${VLANS_NAME[$i]}" "${VLANS_ID[$i]}" "$PHYS_IFACE" "${VLANS_OCTET[$i]}" "${VLANS_HOSTS[$i]}" "$BASE_NETWORK"
done

echo ""
echo "------------------------------------------------"
echo "Конфигурация завершена!"
echo ""

# Перезапуск сети
read -p "Перезапустить сетевую службу сейчас? (y/n): " RESTART_NET

if [[ "$RESTART_NET" =~ ^[Yy]$ ]]; then
    echo "Перезапуск службы сети..."
    if command -v systemctl &> /dev/null; then
        systemctl restart network
    else
        /etc/init.d/network restart
    fi
    
    if [ $? -eq 0 ]; then
        echo "✓ Сеть перезагружена успешно."
    else
        echo "⚠ Произошла ошибка при перезагрузке."
    fi
fi

# Итоговый вывод
echo ""
echo "========================================================"
echo "  Итоговый список интерфейсов"
echo "========================================================"
# Показываем физический интерфейс и созданные VLAN
ip -brief addr show | grep -E "$PHYS_IFACE|${PHYS_IFACE}\."

echo ""
echo "Готово!"
