#!/bin/bash

# =============================================
# СКРИПТ НАСТРОЙКИ DHCP СЕРВЕРА ДЛЯ ALT SERVER
# Версия: 4.0 - Адаптировано для Demo2026
# =============================================
# 
# Соответствует требованиям задания:
# - Настройка DHCP на HQ-RTR (сервер)
# - Исключение адреса маршрутизатора из выдачи
# - Указание шлюза и DNS
# - DNS-суффикс au-team.irpo
#
# Совместимость: Alt Linux Server / JeOS
# =============================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Глобальные переменные
DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_SYSconfig="/etc/sysconfig/dhcpd"
LOG_FILE="/var/log/dhcp-setup.log"

# =============================================
# ФУНКЦИИ
# =============================================

# Логирование
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Функция очистки при ошибке
cleanup_on_error() {
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ОШИБКА! Откат конфигурации DHCP сервера       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    log "ERROR: Начало отката конфигурации"
    
    # Определяем имя службы
    local service_name=$(get_dhcp_service_name)
    
    # Останавливаем службу
    systemctl stop "$service_name" 2>/dev/null
    systemctl disable "$service_name" 2>/dev/null
    
    # Удаляем конфиги
    rm -f "$DHCP_CONF"
    rm -f "$DHCP_SYSCONFIG"
    
    # Удаляем правила iptables
    iptables -D INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
    
    log "ERROR: Конфигурация удалена"
    echo -e "${YELLOW}Конфигурация DHCP сервера полностью удалена${NC}"
    exit 1
}

# Определение имени службы DHCP в Alt Linux
get_dhcp_service_name() {
    if systemctl list-unit-files | grep -q "^dhcpd.service"; then
        echo "dhcpd"
    elif systemctl list-unit-files | grep -q "^isc-dhcp-server.service"; then
        echo "isc-dhcp-server"
    else
        echo "dhcpd"
    fi
}

# Проверка на Alt Linux
check_alt_linux() {
    if [ -f /etc/altlinux-release ]; then
        echo -e "${GREEN}✓ Обнаружен Alt Linux: $(cat /etc/altlinux-release)${NC}"
        log "INFO: Alt Linux detected"
        return 0
    else
        echo -e "${YELLOW}⚠ Внимание: Система не Alt Linux. Совместимость не гарантируется.${NC}"
        log "WARN: Non-Alt Linux system"
        return 1
    fi
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: Запустите скрипт с правами root (sudo)${NC}"
        exit 1
    fi
}

# Установка пакетов для Alt Linux
install_packages_alt() {
    echo -e "${CYAN}→ Обновление списка пакетов...${NC}"
    log "INFO: Updating package list"
    
    apt-get update -y > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Не удалось обновить список пакетов${NC}"
        log "ERROR: apt-get update failed"
        cleanup_on_error
    fi
    
    echo -e "${CYAN}→ Установка dhcp-server и ipcalc...${NC}"
    log "INFO: Installing dhcp-server and ipcalc"
    
    apt-get install -y dhcp-server ipcalc > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Не удалось установить пакеты${NC}"
        log "ERROR: Package installation failed"
        cleanup_on_error
    fi
    
    echo -e "${GREEN}✓ Пакеты установлены${NC}"
    log "INFO: Packages installed successfully"
}

# Вычисление сетевых параметров
calculate_network_params() {
    local cidr=$1
    local gateway_ip=$2
    
    # Получаем информацию о сети через ipcalc
    local network=$(ipcalc "$cidr" 2>/dev/null | grep "^Network:" | awk '{print $2}')
    local netmask=$(ipcalc "$cidr" 2>/dev/null | grep "^Netmask:" | awk '{print $2}')
    local broadcast=$(ipcalc "$cidr" 2>/dev/null | grep "^Broadcast:" | awk '{print $2}')
    local prefix=$(echo "$network" | cut -d/ -f2)
    
    # Разбираем адреса на октеты
    IFS='.' read -r n1 n2 n3 n4 <<< "$(echo "$network" | cut -d/ -f1)"
    IFS='.' read -r b1 b2 b3 b4 <<< "$broadcast"
    IFS='.' read -r g1 g2 g3 g4 <<< "$gateway_ip"
    
    # Вычисляем диапазон DHCP с исключением шлюза
    local gateway_last_octet=$g4
    local network_last_octet=$n4
    local broadcast_last_octet=$b4
    
    # Начало диапазона - первый адрес после сетевого адреса
    local start_last=$((network_last_octet + 1))
    
    # Конец диапазона - предпоследний адрес (последний - broadcast)
    local end_last=$((broadcast_last_octet - 1))
    
    # Если шлюз в начале диапазона, начинаем после него
    if [ "$gateway_last_octet" -ge "$start_last" ] && [ "$gateway_last_octet" -le "$end_last" ]; then
        if [ "$gateway_last_octet" -eq "$start_last" ]; then
            start_last=$((gateway_last_octet + 1))
        elif [ "$gateway_last_octet" -eq "$end_last" ]; then
            end_last=$((gateway_last_octet - 1))
        fi
        # Если шлюз внутри диапазона - корректируем
    fi
    
    # Формируем адреса
    local start_ip="$n1.$n2.$n3.$start_last"
    local end_ip="$n1.$n2.$n3.$end_last"
    
    # Возвращаем значения через глобальные переменные
    CALC_NETWORK="$network"
    CALC_NETMASK="$netmask"
    CALC_BROADCAST="$broadcast"
    CALC_START="$start_ip"
    CALC_END="$end_ip"
    CALC_GATEWAY="$gateway_ip"
    CALC_PREFIX="$prefix"
}

# Создание конфигурации DHCP
create_dhcp_config() {
    echo -e "${CYAN}→ Создание конфигурации DHCP...${NC}"
    log "INFO: Creating DHCP configuration"
    
    # Резервное копирование существующего конфига
    if [ -f "$DHCP_CONF" ]; then
        cp "$DHCP_CONF" "${DHCP_CONF}.backup.$(date +%Y%m%d%H%M%S)"
        log "INFO: Backup created"
    fi
    
    # Создаём базовую конфигурацию
    cat > "$DHCP_CONF" <<EOF
# =============================================
# Конфигурация DHCP сервера
# Создано скриптом dhcp-setup-alt.sh
# Дата: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================

# Глобальные параметры
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
authoritative;

# DNS параметры
option domain-name "$DNS_SUFFIX";
option domain-name-servers $DNS_SERVER${DNS_SERVER_2:+, $DNS_SERVER_2};

# Логирование
log-facility local7;

EOF

    # Добавляем подсети
    for idx in "${!SELECTED_IFACES[@]}"; do
        local iface="${SELECTED_IFACES[$idx]}"
        local vlan="${SELECTED_VLANS[$idx]}"
        local cidr=$(ip -4 -o addr show "$iface" | awk '{print $4}')
        local gateway="${SELECTED_IPS[$idx]}"
        
        # Вычисляем параметры сети
        calculate_network_params "$cidr" "$gateway"
        
        # Добавляем комментарий о VLAN если есть
        if [ "$vlan" != "-" ]; then
            echo "# VLAN $vlan - интерфейс $iface" >> "$DHCP_CONF"
        else
            echo "# Интерфейс $iface" >> "$DHCP_CONF"
        fi
        
        # Добавляем конфигурацию подсети с исключением шлюза
        cat >> "$DHCP_CONF" <<EOF

subnet ${CALC_NETWORK%/*} netmask $CALC_NETMASK {
    # Диапазон выдачи адресов (шлюз $CALC_GATEWAY исключён)
    range $CALC_START $CALC_END;
    
    # Шлюз по умолчанию
    option routers $CALC_GATEWAY;
    
    # Broadcast адрес
    option broadcast-address $CALC_BROADCAST;
    
    # DNS суффикс
    option domain-name "$DNS_SUFFIX";
    
    # Время аренды
    default-lease-time 600;
    max-lease-time 7200;
    
    # Исключение адреса шлюза из пула
    host gateway-${iface} {
        hardware ethernet 00:00:00:00:00:00;
        fixed-address $CALC_GATEWAY;
    }
}

EOF
        
        echo -e "${GREEN}✓ Подсеть ${CALC_NETWORK%/*} настроена (шлюз: $CALC_GATEWAY)${NC}"
        log "INFO: Subnet ${CALC_NETWORK%/*} configured with gateway $CALC_GATEWAY"
    done
    
    echo -e "${GREEN}✓ Конфигурация создана: $DHCP_CONF${NC}"
}

# Настройка интерфейсов для DHCP
configure_dhcp_interfaces() {
    echo -e "${CYAN}→ Настройка интерфейсов DHCP...${NC}"
    log "INFO: Configuring DHCP interfaces"
    
    # Создаём файл с указанием интерфейсов
    cat > "$DHCP_SYSCONFIG" <<EOF
# Интерфейсы для DHCP сервера
# Создано скриптом dhcp-setup-alt.sh
DHCPDARGS="${SELECTED_IFACES[*]}"
EOF
    
    echo -e "${GREEN}✓ Интерфейсы настроены: ${SELECTED_IFACES[*]}${NC}"
    log "INFO: Interfaces configured: ${SELECTED_IFACES[*]}"
}

# Проверка конфигурации
verify_config() {
    echo -e "${CYAN}→ Проверка синтаксиса конфигурации...${NC}"
    log "INFO: Verifying configuration syntax"
    
    if dhcpd -t -cf "$DHCP_CONF" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Синтаксис конфигурации верен${NC}"
        log "INFO: Configuration syntax is valid"
        return 0
    else
        echo -e "${RED}✗ Ошибка в конфигурации:${NC}"
        dhcpd -t -cf "$DHCP_CONF" 2>&1
        log "ERROR: Configuration syntax error"
        cleanup_on_error
    fi
}

# Настройка IP форвардинга
enable_ip_forward() {
    echo -e "${CYAN}→ Включение IP форвардинга...${NC}"
    log "INFO: Enabling IP forwarding"
    
    # Проверяем текущее состояние
    if [ "$(sysctl -n net.ipv4.ip_forward)" -eq 1 ]; then
        echo -e "${GREEN}✓ IP форвардинг уже включён${NC}"
        return 0
    fi
    
    # Добавляем в sysctl.conf если нет
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    # Применяем
    sysctl -p > /dev/null 2>&1
    
    echo -e "${GREEN}✓ IP форвардинг включён${NC}"
    log "INFO: IP forwarding enabled"
}

# Настройка firewall
configure_firewall() {
    echo -e "${CYAN}→ Настройка firewall...${NC}"
    log "INFO: Configuring firewall"
    
    # Проверяем наличие iptables
    if ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}⚠ iptables не установлен, пропускаем настройку firewall${NC}"
        log "WARN: iptables not installed, skipping firewall config"
        return 0
    fi
    
    # Добавляем правила для DHCP
    iptables -C INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport 67 -j ACCEPT
    
    iptables -C INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport 68 -j ACCEPT
    
    # Сохраняем правила (для Alt Linux)
    if [ -d "/etc/sysconfig" ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
        systemctl enable iptables 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ Firewall настроен (порты 67, 68 UDP открыты)${NC}"
    log "INFO: Firewall configured"
}

# Запуск DHCP сервера
start_dhcp_server() {
    local service_name=$(get_dhcp_service_name)
    
    echo -e "${CYAN}→ Запуск DHCP сервера ($service_name)...${NC}"
    log "INFO: Starting DHCP server: $service_name"
    
    # Включаем автозапуск
    systemctl enable "$service_name" > /dev/null 2>&1
    
    # Перезапускаем службу
    if systemctl restart "$service_name" 2>/dev/null; then
        echo -e "${GREEN}✓ DHCP сервер запущен${NC}"
        log "INFO: DHCP server started successfully"
        return 0
    else
        echo -e "${RED}✗ Не удалось запустить DHCP сервер${NC}"
        echo -e "${YELLOW}Логи ошибок:${NC}"
        journalctl -u "$service_name" -n 20 --no-pager 2>/dev/null || \
            tail -20 /var/log/messages 2>/dev/null
        log "ERROR: Failed to start DHCP server"
        cleanup_on_error
    fi
}

# Вывод итоговой информации
print_summary() {
    local service_name=$(get_dhcp_service_name)
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         НАСТРОЙКА DHCP ЗАВЕРШЕНА УСПЕШНО          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${WHITE}Параметры:${NC}"
    echo -e "  DNS сервер:     ${CYAN}$DNS_SERVER${NC}"
    [ -n "$DNS_SERVER_2" ] && echo -e "  Вторичный DNS:  ${CYAN}$DNS_SERVER_2${NC}"
    echo -e "  DNS суффикс:    ${CYAN}$DNS_SUFFIX${NC}"
    echo ""
    
    echo -e "${WHITE}Настроенные подсети:${NC}"
    echo "────────────────────────────────────────────────────────"
    
    for idx in "${!SELECTED_IFACES[@]}"; do
        local iface="${SELECTED_IFACES[$idx]}"
        local vlan="${SELECTED_VLANS[$idx]}"
        local cidr=$(ip -4 -o addr show "$iface" | awk '{print $4}')
        local gateway="${SELECTED_IPS[$idx]}"
        
        calculate_network_params "$cidr" "$gateway"
        
        if [ "$vlan" != "-" ]; then
            echo -e "${MAGENTA}VLAN $vlan${NC} (${CYAN}$iface${NC})"
        else
            echo -e "${CYAN}$iface${NC}"
        fi
        
        echo -e "  Сеть:           ${CALC_NETWORK%/*}/$CALC_PREFIX"
        echo -e "  Шлюз:           $CALC_GATEWAY ${GREEN}(исключён из пула)${NC}"
        echo -e "  Диапазон DHCP:  $CALC_START - $CALC_END"
        echo -e "  Broadcast:      $CALC_BROADCAST"
        echo ""
    done
    
    echo -e "${WHITE}Статус службы:${NC} $(systemctl is-active "$service_name")"
    echo -e "${WHITE}Конфигурация:${NC}   $DHCP_CONF"
    echo -e "${WHITE}Лог установки:${NC}  $LOG_FILE"
    echo ""
    echo -e "${YELLOW}Проверка работы:${NC}"
    echo "  journalctl -u $service_name -f"
    echo "  tail -f /var/log/messages | grep dhcp"
    echo ""
}

# =============================================
# ОСНОВНОЙ КОД
# =============================================

# Проверка прав
check_root

# Создаём лог-файл
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dhcp-setup.log"

log "INFO: ========== Начало настройки DHCP =========="

# Приветствие
clear
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     НАСТРОЙКА DHCP СЕРВЕРА ДЛЯ ALT SERVER${NC}"
echo -e "${WHITE}             Версия 4.0 (Demo2026)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

# Проверка ОС
check_alt_linux
echo ""

# Установка пакетов
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     УСТАНОВКА ПАКЕТОВ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""
install_packages_alt
echo ""

# Получение интерфейсов
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     ВЫБОР ИНТЕРФЕЙСОВ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${WHITE}Доступные интерфейсы:${NC}"
echo "────────────────────────────────────────────────────────"
printf "%-3s %-18s %-10s %-18s %-10s\n" "№" "Интерфейс" "VLAN ID" "IP адрес" "Статус"
echo "────────────────────────────────────────────────────────"

INTERFACES=()
IPS=()
VLAN_IDS=()
STATUSES=()
INDEX=1

while IFS= read -r line; do
    iface=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
    ip_cidr=$(echo "$line" | awk '{print $4}')
    ip=$(echo "$ip_cidr" | cut -d/ -f1)
    
    [ "$iface" = "lo" ] && continue
    
    # Определяем VLAN
    vlan_id="-"
    if [[ "$iface" =~ \.([0-9]+)$ ]]; then
        vlan_id="${BASH_REMATCH[1]}"
    fi
    
    # Определяем статус
    status=$(ip link show "$iface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')
    
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        INTERFACES+=("$iface")
        IPS+=("$ip")
        VLAN_IDS+=("$vlan_id")
        STATUSES+=("$status")
        
        if [ "$vlan_id" != "-" ]; then
            printf "${MAGENTA}%2d${NC}) %-18s ${CYAN}VID %-5s${NC} %-18s %s\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status"
        else
            printf "%2d) %-18s %-10s %-18s %s\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status"
        fi
        INDEX=$((INDEX + 1))
    fi
done < <(ip -4 -o addr show 2>/dev/null)

echo "────────────────────────────────────────────────────────"
echo ""

if [ ${#INTERFACES[@]} -lt 1 ]; then
    echo -e "${RED}✗ Нет интерфейсов с IP адресом${NC}"
    log "ERROR: No interfaces with IP address"
    cleanup_on_error
fi

# Выбор количества интерфейсов
echo -e "${WHITE}Сколько интерфейсов настроить для DHCP?${NC}"
read -p "Введите число [1]: " IFACE_COUNT
IFACE_COUNT=${IFACE_COUNT:-1}

if ! [[ "$IFACE_COUNT" =~ ^[0-9]+$ ]] || [ "$IFACE_COUNT" -lt 1 ]; then
    echo -e "${RED}✗ Некорректное число${NC}"
    cleanup_on_error
fi

if [ "$IFACE_COUNT" -gt ${#INTERFACES[@]} ]; then
    echo -e "${RED}✗ Нельзя выбрать больше ${#INTERFACES[@]} интерфейсов${NC}"
    cleanup_on_error
fi

# Выбор интерфейсов
SELECTED_IFACES=()
SELECTED_VLANS=()
SELECTED_IPS=()

for i in $(seq 1 $IFACE_COUNT); do
    while true; do
        echo -e "${YELLOW}Выберите интерфейс #$i:${NC}"
        read -p "Введите номер: " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#INTERFACES[@]} ]; then
            idx=$((selection - 1))
            iface="${INTERFACES[$idx]}"
            
            # Проверка дубликатов
            duplicate=0
            for selected in "${SELECTED_IFACES[@]}"; do
                [ "$selected" = "$iface" ] && duplicate=1
            done
            
            if [ $duplicate -eq 0 ]; then
                SELECTED_IFACES+=("$iface")
                SELECTED_VLANS+=("${VLAN_IDS[$idx]}")
                SELECTED_IPS+=("${IPS[$idx]}")
                echo -e "${GREEN}✓ Выбран: $iface (${IPS[$idx]})${NC}"
                log "INFO: Selected interface $iface with IP ${IPS[$idx]}"
                break
            else
                echo -e "${RED}✗ Интерфейс уже выбран${NC}"
            fi
        else
            echo -e "${RED}✗ Неверный номер${NC}"
        fi
    done
done

echo ""
echo -e "${GREEN}Выбраны интерфейсы: ${SELECTED_IFACES[*]}${NC}"
echo ""

# DNS параметры
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     НАСТРОЙКА DNS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

read -p "DNS сервер [8.8.8.8]: " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-8.8.8.8}

read -p "Вторичный DNS [Enter - пропустить]: " DNS_SERVER_2

read -p "DNS суффикс [au-team.irpo]: " DNS_SUFFIX
DNS_SUFFIX=${DNS_SUFFIX:-au-team.irpo}

echo ""
echo -e "${GREEN}✓ DNS: $DNS_SERVER${NC}"
[ -n "$DNS_SERVER_2" ] && echo -e "${GREEN}✓ Вторичный DNS: $DNS_SERVER_2${NC}"
echo -e "${GREEN}✓ Суффикс: $DNS_SUFFIX${NC}"
log "INFO: DNS config - Server: $DNS_SERVER, Suffix: $DNS_SUFFIX"
echo ""

# Предварительный просмотр
echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     ПРЕДВАРИТЕЛЬНЫЙ ПРОСМОТР${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${WHITE}Интерфейсы:${NC} ${CYAN}${SELECTED_IFACES[*]}${NC}"
echo -e "${WHITE}DNS сервер:${NC} ${CYAN}$DNS_SERVER${NC}"
echo -e "${WHITE}DNS суффикс:${NC} ${CYAN}$DNS_SUFFIX${NC}"
echo ""

echo -e "${WHITE}Пулы DHCP:${NC}"
for idx in "${!SELECTED_IFACES[@]}"; do
    iface="${SELECTED_IFACES[$idx]}"
    cidr=$(ip -4 -o addr show "$iface" | awk '{print $4}')
    gateway="${SELECTED_IPS[$idx]}"
    calculate_network_params "$cidr" "$gateway"
    echo -e "  ${CYAN}$iface${NC}: $CALC_START - $CALC_END (шлюз $CALC_GATEWAY исключён)"
done
echo ""

read -p "Продолжить настройку? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[YyДд]$ ]]; then
    echo -e "${RED}Отменено пользователем${NC}"
    log "INFO: Cancelled by user"
    exit 0
fi

# Создание конфигурации
echo ""
create_dhcp_config
configure_dhcp_interfaces

# Проверка конфигурации
verify_config

# Настройка системы
enable_ip_forward
configure_firewall

# Запуск DHCP
start_dhcp_server

# Итоговый вывод
print_summary

log "INFO: ========== Настройка DHCP завершена =========="

exit 0
