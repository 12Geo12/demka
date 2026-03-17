#!/bin/bash

#==============================================================================
# Скрипт для настройки OSPF на GRE туннеле
# Оптимизирован для ALT Linux
# Версия: 2.0
#==============================================================================

set -o pipefail

#--- Конфигурация -------------------------------------------------------------
REPORT_FILE="/root/ospf_setup_report_$(date +%Y%m%d_%H%M%S).txt"
LOG_FILE="/var/log/ospf_setup.log"
FRR_DAEMONS_FILE="/etc/frr/daemons"
FRR_CONF_FILE="/etc/frr/frr.conf"

# Цветовые коды для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

#--- Функции ------------------------------------------------------------------

# Вывод с цветом и запись в отчет
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        STEP)  echo -e "\n${BOLD}${BLUE}=== $message ===${NC}" ;;
        *)     echo -e "$message" ;;
    esac
    
    # Запись в отчет (без цветовых кодов)
    echo "[$timestamp] [$level] $message" >> "$REPORT_FILE"
}

# Вывод разделителя
print_separator() {
    echo "----------------------------------------" | tee -a "$REPORT_FILE"
}

# Проверка успешности выполнения команды
check_command() {
    if [ $? -ne 0 ]; then
        log ERROR "$1"
        return 1
    fi
    return 0
}

# Безопасное получение IP адреса интерфейса
get_interface_ip() {
    local iface="$1"
    local ip=""
    
    # Метод 1: через ip command (стандартный)
    ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
    
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi
    
    # Метод 2: через ifconfig (альтернатива)
    if command -v ifconfig &>/dev/null; then
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi
    
    return 1
}

# Получение основного IP адреса системы
get_main_ip() {
    local ip=""
    
    # Список интерфейсов для проверки (приоритетный порядок)
    local interfaces=("ens33" "ens192" "eth0" "enp0s3" "enp1s0" "ens3" "ens4")
    
    for iface in "${interfaces[@]}"; do
        ip=$(get_interface_ip "$iface")
        if [ -n "$ip" ]; then
            echo "$ip:$iface"
            return 0
        fi
    done
    
    # Если ни один из известных интерфейсов не найден, ищем любой с IP
    ip=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d'/' -f1 | head -1)
    local iface=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {print $NF}' | head -1)
    
    if [ -n "$ip" ]; then
        echo "$ip:$iface"
        return 0
    fi
    
    return 1
}

# Проверка существования интерфейса
interface_exists() {
    ip link show "$1" &>/dev/null
}

# Определение дистрибутива Linux
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/altlinux-release ]; then
        echo "altlinux"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# Установка пакета в зависимости от дистрибутива
install_package() {
    local package="$1"
    local distro=$(detect_distro)
    
    log INFO "Установка пакета $package (дистрибутив: $distro)"
    
    case "$distro" in
        altlinux|alt)
            apt-get update >> "$REPORT_FILE" 2>&1
            apt-get install -y "$package" >> "$REPORT_FILE" 2>&1
            ;;
        debian|ubuntu)
            apt-get update >> "$REPORT_FILE" 2>&1
            apt-get install -y "$package" >> "$REPORT_FILE" 2>&1
            ;;
        rhel|centos|fedora)
            yum install -y "$package" >> "$REPORT_FILE" 2>&1
            ;;
        *)
            log WARN "Неизвестный дистрибутив, пробуем apt-get"
            apt-get update >> "$REPORT_FILE" 2>&1
            apt-get install -y "$package" >> "$REPORT_FILE" 2>&1
            ;;
    esac
    
    return $?
}

# Проверка и создание директории
ensure_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log INFO "Создана директория: $dir"
    fi
}

# Валидация IP адреса
validate_ip() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ $ip =~ $regex ]]; then
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

# Валидация сети (CIDR)
validate_network() {
    local network="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
    
    if [[ $network =~ $regex ]]; then
        local ip="${network%/*}"
        local prefix="${network#*/}"
        
        if validate_ip "$ip" && [ "$prefix" -le 32 ]; then
            return 0
        fi
    fi
    return 1
}

# Ввод пароля с подтверждением
read_password() {
    local prompt="$1"
    local var_name="$2"
    local password=""
    local confirm=""
    
    while true; do
        read -s -p "$prompt" password
        echo
        read -s -p "Подтвердите пароль: " confirm
        echo
        
        if [ "$password" = "$confirm" ]; then
            if [ -z "$password" ]; then
                echo -e "${YELLOW}ВНИМАНИЕ: Пароль пустой. Использовать пароль по умолчанию P@ssw0rd? (y/n)${NC}"
                read -r use_default
                if [ "$use_default" = "y" ] || [ "$use_default" = "Y" ]; then
                    password="P@ssw0rd"
                else
                    continue
                fi
            fi
            eval "$var_name='$password'"
            return 0
        else
            echo -e "${RED}Пароли не совпадают. Попробуйте снова.${NC}"
        fi
    done
}

# Проверка статуса сервиса
check_service_status() {
    local service="$1"
    local status
    
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        status="running"
    else
        status="stopped"
    fi
    
    echo "$status"
}

# Перезапуск сервиса с проверкой
restart_service() {
    local service="$1"
    
    log INFO "Перезапуск сервиса $service..."
    
    systemctl enable "$service" >> "$REPORT_FILE" 2>&1
    systemctl restart "$service" >> "$REPORT_FILE" 2>&1
    
    sleep 2
    
    if [ "$(check_service_status "$service")" = "running" ]; then
        log INFO "Сервис $service успешно запущен"
        return 0
    else
        log ERROR "Не удалось запустить сервис $service"
        return 1
    fi
}

#--- Основная логика ----------------------------------------------------------

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ОШИБКА: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

# Инициализация отчета
{
    echo "============================================="
    echo "ОТЧЕТ ПО НАСТРОЙКЕ OSPF НА GRE ТУННЕЛЕ"
    echo "============================================="
    echo "Дата: $(date)"
    echo "Хост: $(hostname)"
    echo "Дистрибутив: $(detect_distro)"
    echo "Версия скрипта: 2.0"
    echo "============================================="
    echo ""
} > "$REPORT_FILE"

# Создаем директорию для логов
ensure_directory "/var/log"

log STEP "ШАГ 1: Определение сетевых параметров"
print_separator

# Получаем основной IP
MAIN_INFO=$(get_main_ip)
if [ -z "$MAIN_INFO" ]; then
    log ERROR "Не удалось определить основной IP адрес"
    exit 1
fi

MAIN_IP="${MAIN_INFO%:*}"
MAIN_IFACE="${MAIN_INFO#*:}"
log INFO "Основной IP адрес: $MAIN_IP (интерфейс: $MAIN_IFACE)"

# Определяем роль роутера
log INFO "Определение роли роутера..."
if [[ $MAIN_IP == 172.16.4.* ]]; then
    ROLE="HQ-RTR"
    ROUTER_ID="172.16.1.1"
    REMOTE_NETWORK="192.168.30.0/27"
    REMOTE_TEST_IP="192.168.30.1"
    log INFO "Роль роутера: HQ-RTR (Главный офис)"
elif [[ $MAIN_IP == 172.16.5.* ]]; then
    ROLE="BR-RTR"
    ROUTER_ID="172.16.2.1"
    REMOTE_NETWORK="192.168.10.0/26"
    REMOTE_TEST_IP="192.168.10.1"
    log INFO "Роль роутера: BR-RTR (Филиал)"
else
    log WARN "Не удалось автоматически определить роль роутера"
    echo -e "${CYAN}Доступные роли:${NC}"
    echo "  1) HQ-RTR - Главный офис (Router ID: 172.16.1.1)"
    echo "  2) BR-RTR - Филиал (Router ID: 172.16.2.1)"
    echo ""
    read -p "Выберите роль (1 или 2): " role_choice
    
    case "$role_choice" in
        1)
            ROLE="HQ-RTR"
            ROUTER_ID="172.16.1.1"
            REMOTE_NETWORK="192.168.30.0/27"
            REMOTE_TEST_IP="192.168.30.1"
            ;;
        2)
            ROLE="BR-RTR"
            ROUTER_ID="172.16.2.1"
            REMOTE_NETWORK="192.168.10.0/26"
            REMOTE_TEST_IP="192.168.10.1"
            ;;
        *)
            log ERROR "Неверный выбор роли"
            exit 1
            ;;
    esac
fi

log INFO "Router ID: $ROUTER_ID"

# Получаем IP адрес туннеля
log INFO "Проверка интерфейса GRE туннеля..."

TUNNEL_IP=""
TUNNEL_IFACE=""

# Проверяем наличие gre1
if interface_exists "gre1"; then
    TUNNEL_IFACE="gre1"
    TUNNEL_IP=$(get_interface_ip "gre1")
    log INFO "Найден интерфейс gre1"
elif interface_exists "tun0"; then
    TUNNEL_IFACE="tun0"
    TUNNEL_IP=$(get_interface_ip "tun0")
    log INFO "Найден интерфейс tun0"
else
    log WARN "Интерфейс GRE туннеля не найден"
    echo ""
    echo -e "${CYAN}Доступные интерфейсы:${NC}"
    ip link show | awk -F': ' '/^[0-9]/ {print "  " $2}'
    echo ""
    read -p "Введите имя интерфейса туннеля: " TUNNEL_IFACE
    
    if ! interface_exists "$TUNNEL_IFACE"; then
        log ERROR "Интерфейс $TUNNEL_IFACE не существует"
        exit 1
    fi
    
    TUNNEL_IP=$(get_interface_ip "$TUNNEL_IFACE")
fi

if [ -z "$TUNNEL_IP" ]; then
    log WARN "Не удалось автоматически определить IP туннеля"
    read -p "Введите IP адрес туннеля (например 10.10.0.1): " TUNNEL_IP
    
    if ! validate_ip "$TUNNEL_IP"; then
        log ERROR "Неверный формат IP адреса"
        exit 1
    fi
fi

log INFO "IP адрес туннеля ($TUNNEL_IFACE): $TUNNEL_IP"

# Определяем сеть туннеля
TUNNEL_NETWORK="10.10.0.0/30"

log STEP "ШАГ 2: Определение локальных сетей"
print_separator

declare -a NETWORKS=()

# Автоматическое определение сетей на основе роли
if [ "$ROLE" = "HQ-RTR" ]; then
    log INFO "Поиск сетей главного офиса..."
    
    # Список сетей для проверки
    declare -a hq_networks=(
        "192.168.10.0/26:Сеть HQ-LAN-1"
        "192.168.20.0/28:Сеть HQ-LAN-2"
        "192.168.100.0/24:Сеть HQ-MGMT"
    )
    
    for net_info in "${hq_networks[@]}"; do
        net="${net_info%:*}"
        desc="${net_info#*:}"
        if ip route show | grep -q "$net"; then
            NETWORKS+=("$net")
            log INFO "Найдена сеть: $net ($desc)"
        fi
    done
else
    log INFO "Поиск сетей филиала..."
    
    # Список сетей для проверки
    declare -a br_networks=(
        "192.168.30.0/27:Сеть BR-LAN"
        "192.168.200.0/24:Сеть BR-MGMT"
    )
    
    for net_info in "${br_networks[@]}"; do
        net="${net_info%:*}"
        desc="${net_info#*:}"
        if ip route show | grep -q "$net"; then
            NETWORKS+=("$net")
            log INFO "Найдена сеть: $net ($desc)"
        fi
    done
fi

# Добавляем сеть туннеля
NETWORKS+=("$TUNNEL_NETWORK")
log INFO "Добавлена сеть туннеля: $TUNNEL_NETWORK"

# Показываем найденные сети
echo ""
log INFO "Найденные сети для анонсирования:"
for net in "${NETWORKS[@]}"; do
    echo "  - $net"
done

# Запрос на изменение списка сетей
echo ""
read -p "Хотите изменить список сетей? (y/n): " CHANGE_NETWORKS

if [ "$CHANGE_NETWORKS" = "y" ] || [ "$CHANGE_NETWORKS" = "Y" ]; then
    NETWORKS=()
    echo ""
    echo -e "${CYAN}Введите сети для анонсирования (формат: 192.168.1.0/24)"
    echo "Пустая строка для завершения ввода:${NC}"
    
    while true; do
        read -p "Сеть: " network
        if [ -z "$network" ]; then
            break
        fi
        
        if validate_network "$network"; then
            NETWORKS+=("$network")
            log INFO "Добавлена сеть: $network"
        else
            log WARN "Неверный формат сети: $network (используйте формат CIDR, например 192.168.1.0/24)"
        fi
    done
    
    if [ ${#NETWORKS[@]} -eq 0 ]; then
        log ERROR "Список сетей пуст"
        exit 1
    fi
fi

log INFO "Итоговый список сетей для анонсирования:"
for net in "${NETWORKS[@]}"; do
    echo "  - $net" | tee -a "$REPORT_FILE"
done

log STEP "ШАГ 3: Настройка парольной защиты OSPF"
print_separator

read_password "Введите пароль для аутентификации OSPF: " OSPF_PASSWORD
log INFO "Пароль OSPF установлен (значение скрыто для безопасности)"

log STEP "ШАГ 4: Установка и настройка FRR"
print_separator

# Проверка наличия FRR
if ! command -v vtysh &>/dev/null; then
    log INFO "FRR не установлен. Начинаю установку..."
    
    # Определяем имя пакета в зависимости от дистрибутива
    DISTRO=$(detect_distro)
    case "$DISTRO" in
        altlinux|alt)
            FRR_PACKAGE="frr"
            ;;
        *)
            FRR_PACKAGE="frr"
            ;;
    esac
    
    install_package "$FRR_PACKAGE"
    
    if ! check_command "Не удалось установить FRR"; then
        log ERROR "Проверьте подключение к репозиториям и повторите попытку"
        exit 1
    fi
else
    log INFO "FRR уже установлен"
fi

# Проверка и создание файла daemons
if [ ! -f "$FRR_DAEMONS_FILE" ]; then
    log WARN "Файл $FRR_DAEMONS_FILE не найден"
    
    # Поиск альтернативных путей
    for alt_path in "/etc/frr/daemons" "/usr/local/etc/frr/daemons" "/etc/daemons"; do
        if [ -f "$alt_path" ]; then
            FRR_DAEMONS_FILE="$alt_path"
            log INFO "Найден файл daemons: $FRR_DAEMONS_FILE"
            break
        fi
    done
    
    if [ ! -f "$FRR_DAEMONS_FILE" ]; then
        log ERROR "Файл конфигурации daemons не найден"
        exit 1
    fi
fi

# Включение ospfd
log INFO "Включение ospfd в конфигурации FRR..."

# Резервное копирование
cp "$FRR_DAEMONS_FILE" "${FRR_DAEMONS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
log INFO "Создана резервная копия: ${FRR_DAEMONS_FILE}.backup.*"

# Изменение конфигурации
if grep -q "^ospfd=" "$FRR_DAEMONS_FILE"; then
    sed -i 's/^ospfd=no/ospfd=yes/' "$FRR_DAEMONS_FILE"
    sed -i 's/^ospfd=no/ospfd=yes/' "$FRR_DAEMONS_FILE"
elif grep -q "^#ospfd=" "$FRR_DAEMONS_FILE"; then
    sed -i 's/^#ospfd=no/ospfd=yes/' "$FRR_DAEMONS_FILE"
else
    echo "ospfd=yes" >> "$FRR_DAEMONS_FILE"
fi

# Проверка изменений
if grep -q "^ospfd=yes" "$FRR_DAEMONS_FILE"; then
    log INFO "ospfd успешно включен"
else
    log ERROR "Не удалось включить ospfd"
    exit 1
fi

# Запись в отчет
{
    echo ""
    echo "--- КОНФИГУРАЦИЯ DAEMONS ---"
    grep -E "^(ospfd|zebra)=" "$FRR_DAEMONS_FILE" 2>/dev/null || echo "Не удалось прочитать конфигурацию"
} >> "$REPORT_FILE"

# Запуск FRR
if ! restart_service "frr"; then
    log WARN "Пробуем альтернативное имя сервиса..."
    if ! restart_service "frr.service"; then
        log ERROR "Не удалось запустить FRR. Проверьте логи: journalctl -xe"
        exit 1
    fi
fi

# Ожидание инициализации
log INFO "Ожидание инициализации FRR..."
sleep 3

log STEP "ШАГ 5: Настройка OSPF через vtysh"
print_separator

# Проверка доступности vtysh
if ! command -v vtysh &>/dev/null; then
    log ERROR "Команда vtysh не найдена"
    exit 1
fi

# Создаем временный файл с командами
VTYSH_CMDS=$(mktemp)
trap "rm -f $VTYSH_CMDS" EXIT

# Формируем команды для vtysh
{
    echo "configure terminal"
    echo " router ospf"
    echo "  ospf router-id $ROUTER_ID"
    
    # Добавляем сети
    for net in "${NETWORKS[@]}"; do
        echo "  network $net area 0"
    done
    
    # Добавляем аутентификацию
    echo "  area 0 authentication"
    echo " exit"
    echo " interface $TUNNEL_IFACE"
    echo "  ip ospf authentication"
    echo "  ip ospf authentication-key $OSPF_PASSWORD"
    echo "  no ip ospf passive"
    echo "  ip ospf network broadcast"
    echo " exit"
    echo " end"
    echo " write memory"
} > "$VTYSH_CMDS"

log INFO "Применение конфигурации OSPF..."

# Применяем конфигурацию
if vtysh -f "$VTYSH_CMDS" >> "$REPORT_FILE" 2>&1; then
    log INFO "Конфигурация OSPF успешно применена"
else
    log ERROR "Ошибка при применении конфигурации OSPF"
    cat "$VTYSH_CMDS" >> "$REPORT_FILE"
    exit 1
fi

# Запись конфигурации в отчет
{
    echo ""
    echo "--- ПРИМЕНЕННАЯ КОНФИГУРАЦИЯ OSPF ---"
    vtysh -c "show running-config" 2>/dev/null | grep -A50 "router ospf" | head -50
} >> "$REPORT_FILE"

log STEP "ШАГ 6: Проверка конфигурации"
print_separator

# Показываем конфигурацию OSPF (без пароля)
log INFO "Текущая конфигурация OSPF:"
vtysh -c "show running-config" 2>/dev/null | grep -A30 "router ospf" | grep -v "authentication-key" | while read -r line; do
    [ -n "$line" ] && echo "  $line"
done

log INFO "Конфигурация интерфейса $TUNNEL_IFACE:"
vtysh -c "show running-config" 2>/dev/null | grep -A15 "interface $TUNNEL_IFACE" | grep -v "authentication-key" | while read -r line; do
    [ -n "$line" ] && echo "  $line"
done

log STEP "ШАГ 7: Проверка соседей OSPF"
print_separator

log INFO "Ожидание установки соседства (20 секунд)..."
for i in {20..1}; do
    printf "\r%s " "Осталось: $i сек..."
    sleep 1
done
echo ""

# Проверяем соседей
log INFO "Проверка соседей OSPF..."
NEIGHBORS=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)

if [ -n "$NEIGHBORS" ]; then
    echo "$NEIGHBORS" >> "$REPORT_FILE"
    
    log INFO "Соседи OSPF:"
    echo "$NEIGHBORS" | while read -r line; do
        [ -n "$line" ] && echo "  $line"
    done
    
    # Проверяем статус
    if echo "$NEIGHBORS" | grep -q "Full"; then
        log INFO "СТАТУС: Full/DR или Full/BDR - соседство установлено корректно"
    else
        log WARN "СТАТУС: Полное соседство еще не установлено"
    fi
else
    log WARN "Соседи OSPF не обнаружены"
    log INFO "Проверьте:"
    log INFO "  1. Настроен ли OSPF на удаленном роутере"
    log INFO "  2. Совпадают ли пароли аутентификации"
    log INFO "  3. Доступен ли туннель (ping)"
fi

log STEP "ШАГ 8: Проверка маршрутов OSPF"
print_separator

log INFO "Маршруты OSPF:"
OSPF_ROUTES=$(vtysh -c "show ip route ospf" 2>/dev/null)

if [ -n "$OSPF_ROUTES" ]; then
    echo "$OSPF_ROUTES" >> "$REPORT_FILE"
    echo "$OSPF_ROUTES" | while read -r line; do
        [ -n "$line" ] && echo "  $line"
    done
else
    log WARN "Маршруты OSPF не найдены"
fi

log STEP "ШАГ 9: Проверка связанности"
print_separator

if [ -n "$NEIGHBORS" ] && echo "$NEIGHBORS" | grep -q "Full"; then
    log INFO "OSPF соседство установлено успешно"
    
    log INFO "Проверка связи с удаленной сетью ($REMOTE_TEST_IP)..."
    
    if ping -c 3 -W 3 "$REMOTE_TEST_IP" >> "$REPORT_FILE" 2>&1; then
        log INFO "РЕЗУЛЬТАТ: Связь с $REMOTE_TEST_IP установлена"
    else
        log WARN "РЕЗУЛЬТАТ: Нет связи с $REMOTE_TEST_IP"
        log INFO "Возможно, требуется время для обновления маршрутов"
    fi
else
    log WARN "OSPF соседство не установлено, пропускаем проверку связи"
fi

#--- Финальный отчет ----------------------------------------------------------

log STEP "ЗАВЕРШЕНИЕ НАСТРОЙКИ"
print_separator

{
    echo ""
    echo "============================================="
    echo "НАСТРОЙКА OSPF ЗАВЕРШЕНА"
    echo "============================================="
    echo ""
    echo "Параметры конфигурации:"
    echo "  Роль роутера: $ROLE"
    echo "  Router ID: $ROUTER_ID"
    echo "  Интерфейс туннеля: $TUNNEL_IFACE"
    echo "  IP туннеля: $TUNNEL_IP"
    echo "  Количество сетей: ${#NETWORKS[@]}"
    echo ""
    echo "Полезные команды для проверки:"
    echo "  vtysh -c 'show ip ospf neighbor'     # показать соседей"
    echo "  vtysh -c 'show ip route ospf'        # показать маршруты OSPF"
    echo "  vtysh -c 'show running-config'       # показать конфигурацию"
    echo "  vtysh -c 'show ip ospf interface'    # показать интерфейсы OSPF"
    echo "  vtysh -c 'show ip ospf database'     # показать базу данных OSPF"
    echo ""
    echo "Отчет сохранен в: $REPORT_FILE"
    echo "============================================="
} | tee -a "$REPORT_FILE"

# Запрос на сохранение пароля
echo ""
read -p "Сохранить пароль в отдельный файл? (y/n): " SAVE_PASSWORD

if [ "$SAVE_PASSWORD" = "y" ] || [ "$SAVE_PASSWORD" = "Y" ]; then
    PASSWORD_FILE="/root/ospf_password_$(date +%Y%m%d).txt"
    {
        echo "============================================="
        echo "Пароль OSPF"
        echo "============================================="
        echo "Хост: $(hostname)"
        echo "Дата создания: $(date)"
        echo "Роль: $ROLE"
        echo "Router ID: $ROUTER_ID"
        echo "Пароль: $OSPF_PASSWORD"
        echo "============================================="
    } > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log INFO "Пароль сохранен в: $PASSWORD_FILE (права: 600)"
fi

echo ""
log INFO "Для просмотра полного отчета: cat $REPORT_FILE"

exit 0
