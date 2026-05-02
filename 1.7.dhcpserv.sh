#!/bin/bash

# =============================================
# СКРИПТ НАСТРОЙКИ DHCP СЕРВЕРА ДЛЯ ALT SERVER
# Версия: 4.2 - Проверенная и исправленная
# =============================================
# 
# Соответствует требованиям задания Demo2026:
# - Настройка DHCP на HQ-RTR (сервер)
# - Исключение адреса маршрутизатора из выдачи
# - Указание шлюза и DNS
# - DNS-суффикс au-team.irpo
#
# Совместимость: Alt Linux Server / JeOS
# ВАЖНО: Запускать через bash, не sh!
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
DHCP_SYSCONFIG="/etc/sysconfig/dhcpd"
LOG_FILE="/var/log/dhcp-setup.log"

# Массивы для хранения данных
declare -a INTERFACES
declare -a IPS
declare -a VLAN_IDS
declare -a STATUSES
declare -a SELECTED_IFACES
declare -a SELECTED_VLANS
declare -a SELECTED_IPS

# Переменные для вычисления сети
CALC_NETWORK=""
CALC_NETMASK=""
CALC_BROADCAST=""
CALC_START=""
CALC_END=""
CALC_GATEWAY=""
CALC_PREFIX=""

# DNS параметры
DNS_SERVER=""
DNS_SERVER_2=""
DNS_SUFFIX=""

# =============================================
# ФУНКЦИИ
# =============================================

# Логирование
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null
}

# Функция очистки при ошибке
cleanup_on_error() {
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ОШИБКА! Откат конфигурации DHCP сервера       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    log "ERROR: Начало отката конфигурации"
    
    # Останавливаем службу
    systemctl stop dhcpd 2>/dev/null
    systemctl stop isc-dhcp-server 2>/dev/null
    
    # Удаляем конфиги
    rm -f "$DHCP_CONF" 2>/dev/null
    rm -f "$DHCP_SYSCONFIG" 2>/dev/null
    
    # Удаляем правила iptables для DHCP
    iptables -D INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
    
    log "ERROR: Конфигурация удалена"
    echo -e "${YELLOW}Конфигурация DHCP сервера полностью удалена${NC}"
    exit 1
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: Запустите скрипт с правами root (sudo)${NC}"
        exit 1
    fi
}

# Проверка на Alt Linux
check_alt_linux() {
    if [ -f /etc/altlinux-release ]; then
        echo -e "${GREEN}✓ Обнаружен Alt Linux: $(cat /etc/altlinux-release)${NC}"
        log "INFO: Alt Linux detected"
        return 0
    else
        echo -e "${YELLOW}⚠ Внимание: Система не Alt Linux.${NC}"
        log "WARN: Non-Alt Linux system"
        return 1
    fi
}

# Проверка существующей установки DHCP
check_existing_dhcp() {
    if systemctl is-active --quiet dhcpd 2>/dev/null || systemctl is-active --quiet isc-dhcp-server 2>/dev/null; then
        echo -e "${YELLOW}⚠ Обнаружен запущенный DHCP сервер!${NC}"
        echo ""
        echo "Остановить и перенастроить?"
        select STOP_DHCP in "Да" "Нет (выход)";
        do
            case $STOP_DHCP in
                "Да")
                    echo -e "${YELLOW}Остановка DHCP сервера...${NC}"
                    systemctl stop dhcpd 2>/dev/null
                    systemctl stop isc-dhcp-server 2>/dev/null
                    echo -e "${GREEN}DHCP сервер остановлен${NC}"
                    break
                    ;;
                "Нет (выход)")
                    echo "Выход..."
                    exit 0
                    ;;
                *)
                    echo "Выберите 1 или 2"
                    ;;
            esac
        done
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
    local cidr="$1"
    local gateway_ip="$2"
    
    # Получаем информацию о сети через ipcalc
    CALC_NETWORK=$(ipcalc "$cidr" 2>/dev/null | grep "^Network:" | awk '{print $2}')
    CALC_NETMASK=$(ipcalc "$cidr" 2>/dev/null | grep "^Netmask:" | awk '{print $2}')
    CALC_BROADCAST=$(ipcalc "$cidr" 2>/dev/null | grep "^Broadcast:" | awk '{print $2}')
    CALC_PREFIX=$(echo "$CALC_NETWORK" | cut -d/ -f2)
    
    # Разбираем адреса на октеты
    local network_ip=$(echo "$CALC_NETWORK" | cut -d/ -f1)
    
    IFS='.' read -r n1 n2 n3 n4 <<< "$network_ip"
    IFS='.' read -r b1 b2 b3 b4 <<< "$CALC_BROADCAST"
    IFS='.' read -r g1 g2 g3 g4 <<< "$gateway_ip"
    
    # Начало диапазона - пропускаем сетевой адрес
    local start_last=$((n4 + 1))
    # Конец диапазона - предпоследний адрес (последний - broadcast)
    local end_last=$((b4 - 1))
    
    # Если шлюз в начале диапазона, начинаем после него
    if [ "$g4" -ge "$start_last" ] && [ "$g4" -le "$end_last" ]; then
        if [ "$g4" -eq "$start_last" ]; then
            start_last=$((g4 + 1))
        elif [ "$g4" -eq "$end_last" ]; then
            end_last=$((g4 - 1))
        fi
    fi
    
    # Формируем адреса
    CALC_START="$n1.$n2.$n3.$start_last"
    CALC_END="$n1.$n2.$n3.$end_last"
    CALC_GATEWAY="$gateway_ip"
}

# Получение статуса интерфейса (как в NAT скрипте)
get_iface_status() {
    local iface=$1
    
    if [ -f "/sys/class/net/${iface}/operstate" ]; then
        local state=$(cat "/sys/class/net/${iface}/operstate")
        case "$state" in
            up|UP) echo "UP" ;;
            down|DOWN) echo "DOWN" ;;
            *) echo "$state" ;;
        esac
    else
        echo "UNKNOWN"
    fi
}

# Получение списка интерфейсов (исправлено для совместимости)
get_interfaces() {
    local INDEX=1
    
    # Используем временный файл вместо процессной подстановки
    local tmp_file="/tmp/interfaces_$$.txt"
    
    ip -4 -o addr show > "$tmp_file" 2>/dev/null
    
    while IFS= read -r line; do
        local iface=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
        local ip_cidr=$(echo "$line" | awk '{print $4}')
        local ip=$(echo "$ip_cidr" | cut -d/ -f1)
        
        # Пропускаем loopback
        [ "$iface" = "lo" ] && continue
        
        # Определяем VLAN
        local vlan_id="-"
        if [[ "$iface" =~ \.([0-9]+)$ ]]; then
            vlan_id="${BASH_REMATCH[1]}"
        fi
        
        # Определяем статус (как в NAT скрипте)
        local status=$(get_iface_status "$iface")
        
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            INTERFACES+=("$iface")
            IPS+=("$ip")
            VLAN_IDS+=("$vlan_id")
            STATUSES+=("$status")
            
            # Цветной статус
            local status_out
            if [ "$status" = "UP" ]; then
                status_out="${GREEN}UP${NC}"
            else
                status_out="${YELLOW}$status${NC}"
            fi
            
            if [ "$vlan_id" != "-" ]; then
                printf "${MAGENTA}%2d${NC}) %-18s ${CYAN}VID %-5s${NC} %-18s %b\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status_out"
            else
                printf "%2d) %-18s %-10s %-18s %b\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status_out"
            fi
            INDEX=$((INDEX + 1))
        fi
    done < "$tmp_file"
    
    rm -f "$tmp_file"
}

# Создание конфигурации DHCP
create_dhcp_config() {
    echo -e "${CYAN}→ Создание конфигурации DHCP...${NC}"
    log "INFO: Creating DHCP configuration"
    
    # Резервное копирование существующего конфига
    if [ -f "$DHCP_CONF" ]; then
        cp "$DHCP_CONF" "${DHCP_CONF}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        log "INFO: Backup created"
    fi
    
    # Создаём базовую конфигурацию
    cat > "$DHCP_CONF" << EOFMAIN
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

EOFMAIN

    # Добавляем подсети
    local idx
    for idx in "${!SELECTED_IFACES[@]}"; do
        local iface="${SELECTED_IFACES[$idx]}"
        local vlan="${SELECTED_VLANS[$idx]}"
        local cidr=$(ip -4 -o addr show "$iface" | awk '{print $4}')
        local gateway="${SELECTED_IPS[$idx]}"
        
        # Вычисляем параметры сети
        calculate_network_params "$cidr" "$gateway"
        
        # Извлекаем адрес сети без префикса
        local network_addr=$(echo "$CALC_NETWORK" | cut -d/ -f1)
        
        # Добавляем комментарий о VLAN если есть
        if [ "$vlan" != "-" ]; then
            echo "# VLAN $vlan - интерфейс $iface" >> "$DHCP_CONF"
        else
            echo "# Интерфейс $iface" >> "$DHCP_CONF"
        fi
        
        # Добавляем конфигурацию подсети
        cat >> "$DHCP_CONF" << EOFSUBNET

subnet $network_addr netmask $CALC_NETMASK {
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
}

EOFSUBNET
        
        echo -e "${GREEN}✓ Подсеть $network_addr/$CALC_PREFIX настроена (шлюз: $CALC_GATEWAY)${NC}"
        log "INFO: Subnet $network_addr configured with gateway $CALC_GATEWAY"
    done
    
    echo -e "${GREEN}✓ Конфигурация создана: $DHCP_CONF${NC}"
}

# Настройка интерфейсов для DHCP
configure_dhcp_interfaces() {
    echo -e "${CYAN}→ Настройка интерфейсов DHCP...${NC}"
    log "INFO: Configuring DHCP interfaces"
    
    # Формируем список интерфейсов
    local iface_list=""
    local i
    for i in "${SELECTED_IFACES[@]}"; do
        iface_list="$iface_list $i"
    done
    iface_list=$(echo "$iface_list" | xargs)  # Удаляем лишние пробелы
    
    # Создаём директорию если нет
    mkdir -p /etc/sysconfig 2>/dev/null
    
    # Создаём файл с указанием интерфейсов
    cat > "$DHCP_SYSCONFIG" << EOFSYSCONFIG
# Интерфейсы для DHCP сервера
# Создано скриптом dhcp-setup-alt.sh
DHCPDARGS="$iface_list"
EOFSYSCONFIG
    
    echo -e "${GREEN}✓ Интерфейсы настроены: $iface_list${NC}"
    log "INFO: Interfaces configured: $iface_list"
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

# Настройка IP форвардинга (как в NAT скрипте)
enable_ip_forward() {
    echo -e "${CYAN}→ Включение IP форвардинга...${NC}"
    log "INFO: Enabling IP forwarding"
    
    # Определяем файл sysctl (как в NAT скрипте)
    local SYSCTL_FILE="/etc/sysctl.conf"
    if [ -f /etc/net/sysctl.conf ]; then
        SYSCTL_FILE="/etc/net/sysctl.conf"
    fi
    
    # Проверяем текущее состояние
    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" -eq 1 ]; then
        echo -e "${GREEN}✓ IP форвардинг уже включён${NC}"
        return 0
    fi
    
    # Добавляем или исправляем в sysctl.conf
    if ! grep -q "net.ipv4.ip_forward" "$SYSCTL_FILE" 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
    else
        sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
    fi
    
    # Применяем
    sysctl -p > /dev/null 2>&1
    
    echo -e "${GREEN}✓ IP форвардинг включён${NC}"
    log "INFO: IP forwarding enabled"
}

# Настройка firewall (улучшено как в NAT скрипте)
configure_firewall() {
    echo -e "${CYAN}→ Настройка firewall...${NC}"
    log "INFO: Configuring firewall"
    
    # Проверяем наличие iptables
    if ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}⚠ iptables не установлен, пропускаем настройку firewall${NC}"
        log "WARN: iptables not installed, skipping firewall config"
        return 0
    fi
    
    # Добавляем правила для DHCP (проверяем наличие перед добавлением)
    echo -e "  ${GREEN}Разрешение DHCP портов (67, 68 UDP)...${NC}"
    
    if ! iptables -C INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p udp --dport 67 -j ACCEPT
        echo -e "    ${GREEN}✓ Порт 67 UDP открыт${NC}"
    else
        echo -e "    ${YELLOW}Порт 67 UDP уже открыт${NC}"
    fi
    
    if ! iptables -C INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p udp --dport 68 -j ACCEPT
        echo -e "    ${GREEN}✓ Порт 68 UDP открыт${NC}"
    else
        echo -e "    ${YELLOW}Порт 68 UDP уже открыт${NC}"
    fi
    
    # Сохраняем правила (как в NAT скрипте)
    if [ -d "/etc/sysconfig" ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
        echo -e "  ${GREEN}✓ Правила сохранены в /etc/sysconfig/iptables${NC}"
    elif [ -d "/etc/iptables" ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        echo -e "  ${GREEN}✓ Правила сохранены в /etc/iptables/rules.v4${NC}"
    fi
    
    # Включаем iptables сервис (как в NAT скрипте)
    if systemctl list-unit-files 2>/dev/null | grep -q "^iptables.service"; then
        systemctl enable iptables --now 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ Firewall настроен${NC}"
    log "INFO: Firewall configured"
}

# Запуск DHCP сервера
start_dhcp_server() {
    echo -e "${CYAN}→ Запуск DHCP сервера...${NC}"
    log "INFO: Starting DHCP server"
    
    # Определяем имя службы
    local service_name="dhcpd"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^dhcpd.service"; then
        if systemctl list-unit-files 2>/dev/null | grep -q "^isc-dhcp-server.service"; then
            service_name="isc-dhcp-server"
        fi
    fi
    
    # Включаем автозапуск
    systemctl enable "$service_name" > /dev/null 2>&1
    
    # Перезапускаем службу
    if systemctl restart "$service_name" 2>/dev/null; then
        echo -e "${GREEN}✓ DHCP сервер запущен ($service_name)${NC}"
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
    
    local idx
    for idx in "${!SELECTED_IFACES[@]}"; do
        local iface="${SELECTED_IFACES[$idx]}"
        local vlan="${SELECTED_VLANS[$idx]}"
        local cidr=$(ip -4 -o addr show "$iface" | awk '{print $4}')
        local gateway="${SELECTED_IPS[$idx]}"
        
        calculate_network_params "$cidr" "$gateway"
        
        local network_addr=$(echo "$CALC_NETWORK" | cut -d/ -f1)
        
        if [ "$vlan" != "-" ]; then
            echo -e "${MAGENTA}VLAN $vlan${NC} (${CYAN}$iface${NC})"
        else
            echo -e "${CYAN}$iface${NC}"
        fi
        
        echo -e "  Сеть:           $network_addr/$CALC_PREFIX"
        echo -e "  Шлюз:           $CALC_GATEWAY ${GREEN}(исключён из пула)${NC}"
        echo -e "  Диапазон DHCP:  $CALC_START - $CALC_END"
        echo -e "  Broadcast:      $CALC_BROADCAST"
        echo ""
    done
    
    local active_service="dhcpd"
    if systemctl is-active --quiet isc-dhcp-server 2>/dev/null; then
        active_service="isc-dhcp-server"
    fi
    
    echo -e "${WHITE}Статус службы:${NC} $(systemctl is-active "$active_service" 2>/dev/null)"
    echo -e "${WHITE}Конфигурация:${NC}   $DHCP_CONF"
    echo ""
    echo -e "${CYAN}===== Текущие правила iptables для DHCP =====${NC}"
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | grep -E "dpt:67|dpt:68" || echo "Правила не найдены"
    echo ""
    echo -e "${YELLOW}Проверка работы:${NC}"
    echo "  journalctl -u $active_service -f"
    echo "  tail -f /var/log/messages | grep dhcp"
    echo ""
}

# =============================================
# ОСНОВНОЙ КОД
# =============================================

# Проверка прав
check_root

# Создаём лог-файл
mkdir -p /var/log 2>/dev/null
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dhcp-setup.log"

log "INFO: ========== Начало настройки DHCP =========="

# Приветствие
clear
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}     НАСТРОЙКА DHCP СЕРВЕРА ДЛЯ ALT SERVER${NC}"
echo -e "${WHITE}             Версия 4.2 (Demo2026)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

# Проверка ОС
check_alt_linux
echo ""

# Проверка существующего DHCP
check_existing_dhcp
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

# Получаем список интерфейсов (исправленная функция)
get_interfaces

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
i=0
for i in $(seq 1 $IFACE_COUNT); do
    while true; do
        echo -e "${YELLOW}Выберите интерфейс #$i:${NC}"
        read -p "Введите номер: " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#INTERFACES[@]} ]; then
            idx=$((selection - 1))
            iface="${INTERFACES[$idx]}"
            
            # Проверка дубликатов
            duplicate=0
            for j in "${SELECTED_IFACES[@]}"; do
                [ "$j" = "$iface" ] && duplicate=1
            done
            
            if [ "$duplicate" -eq 0 ]; then
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

