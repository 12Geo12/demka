#!/bin/bash
#
# Скрипт настройки службы сетевого времени (NTP) на базе chrony
# Для Alt Linux (Маршрутизатор ISP)
#
# Задание:
# - Вышестоящий сервер NTP - на выбор (используем pool.ntp.org)
# - Стратум сервера - 5
# - Клиенты NTP: HQ-SRV, HQ-CLI, BR-RTR, BR-SRV
#

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    log_success "Проверка прав root пройдена"
}

# Определение сетей клиентов NTP
# Будут заполнены автоматически или вручную
NTP_CLIENTS=()
CLIENT_NETWORKS=()
DETECTED_INTERFACES=()

# =============================================================================
# АВТОМАТИЧЕСКОЕ ОПРЕДЕЛЕНИЕ IP-АДРЕСОВ КЛИЕНТОВ
# =============================================================================

# Функция для получения списка сетевых интерфейсов и их сетей
get_network_interfaces() {
    log_info "Определение сетевых интерфейсов..."
    
    DETECTED_INTERFACES=()
    
    # Получаем список интерфейсов с IP-адресами (исключаем lo и docker)
    while IFS= read -r line; do
        IFACE=$(echo "$line" | awk '{print $2}')
        IP_ADDR=$(echo "$line" | awk '{print $4}')
        
        # Пропускаем loopback и docker интерфейсы
        if [[ "$IFACE" == "lo" ]] || [[ "$IFACE" == docker* ]]; then
            continue
        fi
        
        if [[ -n "$IP_ADDR" ]]; then
            DETECTED_INTERFACES+=("$IFACE:$IP_ADDR")
            log_info "  Найден интерфейс: $IFACE с IP $IP_ADDR"
        fi
    done < <(ip -o -4 addr show 2>/dev/null)
    
    if [[ ${#DETECTED_INTERFACES[@]} -eq 0 ]]; then
        log_warning "Не найдены подходящие сетевые интерфейсы"
        return 1
    fi
    
    log_success "Найдено интерфейсов: ${#DETECTED_INTERFACES[@]}"
    return 0
}

# Функция для определения сети по IP-адресу интерфейса
get_network_from_ip() {
    local ip_with_mask="$1"
    local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
    local mask=$(echo "$ip_with_mask" | cut -d'/' -f2)
    
    # Преобразуем CIDR в маску подсети
    local mask_int=$((0xffffffff << (32 - mask) & 0xffffffff))
    local mask_octets=""
    for i in {1..4}; do
        mask_octets="$((mask_int >> (8 * (4 - i)) & 0xff)).$mask_octets"
    done
    mask_octets="${mask_octets%.}"
    
    # Вычисляем адрес сети
    local IFS='.'
    read -ra ip_parts <<< "$ip"
    read -ra mask_parts <<< "$mask_octets"
    
    local network=""
    for i in {0..3}; do
        network="$network.$((${ip_parts[$i]} & ${mask_parts[$i]}))"
    done
    network="${network#.}"
    
    echo "$network/$mask"
}

# Функция для сканирования сети на наличие хостов (через ARP)
scan_network_arp() {
    local network="$1"
    local found_hosts=()
    
    log_info "  Сканирование сети $network через ARP-таблицу..."
    
    # Получаем хосты из ARP-таблицы
    while IFS= read -r line; do
        local ip=$(echo "$line" | awk '{print $1}')
        if [[ -n "$ip" ]] && [[ "$ip" != "" ]]; then
            found_hosts+=("$ip")
        fi
    done < <(arp -n 2>/dev/null | grep -v "incomplete" | awk '/^[0-9]/ {print $1}')
    
    echo "${found_hosts[@]}"
}

# Функция для быстрого пинга хостов в сети
ping_sweep() {
    local network="$1"
    local base_ip=$(echo "$network" | cut -d'/' -f1 | cut -d'.' -f1-3)
    local found_hosts=()
    
    log_info "  Пинг-сканирование сети $base_ip.0/24..."
    
    # Параллельный пинг первых 50 адресов (быстрое сканирование)
    for i in $(seq 1 50); do
        (
            ping -c 1 -W 1 "$base_ip.$i" &>/dev/null && echo "$base_ip.$i"
        ) &
    done
    wait
    
    # Собираем результаты из ARP-таблицы
    while IFS= read -r ip; do
        if [[ -n "$ip" ]]; then
            found_hosts+=("$ip")
        fi
    done < <(arp -n 2>/dev/null | grep "$base_ip" | awk '{print $1}' | head -20)
    
    echo "${found_hosts[@]}"
}

# Функция для ручного ввода IP-адресов клиентов
manual_input_clients() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}РУЧНОЙ ВВОД IP-АДРЕСОВ КЛИЕНТОВ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "Введите IP-адреса для каждого клиента."
    echo "Оставьте пустым для использования значения по умолчанию."
    echo ""
    
    local default_ips=("192.168.1.10" "192.168.1.20" "192.168.2.1" "192.168.2.10")
    local default_networks=("192.168.1.0/24" "192.168.2.0/24")
    local client_names=("HQ-SRV" "HQ-CLI" "BR-RTR" "BR-SRV")
    
    NTP_CLIENTS=()
    
    for i in "${!client_names[@]}"; do
        local name="${client_names[$i]}"
        local default="${default_ips[$i]}"
        
        echo -ne "${BLUE}$name${NC} [по умолчанию: $default]: "
        read -r input
        
        if [[ -z "$input" ]]; then
            input="$default"
        fi
        
        # Проверка корректности IP
        if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            NTP_CLIENTS+=("$name:$input")
            log_success "$name -> $input"
        else
            log_error "Некорректный IP-адрес: $input"
            NTP_CLIENTS+=("$name:$default")
            log_warning "Используем значение по умолчанию: $default"
        fi
    done
    
    echo ""
    echo "Введите сети для разрешения доступа (через пробел):"
    echo -ne "Сети [по умолчанию: ${default_networks[*]}]: "
    read -r input_networks
    
    if [[ -z "$input_networks" ]]; then
        CLIENT_NETWORKS=("${default_networks[@]}")
    else
        CLIENT_NETWORKS=($input_networks)
    fi
    
    echo ""
    log_success "Сети для доступа: ${CLIENT_NETWORKS[*]}"
}

# Функция выбора клиента из списка обнаруженных хостов
select_clients_from_hosts() {
    local -n hosts_ref=$1
    
    echo ""
    echo "Обнаруженные хосты в сети:"
    echo ""
    
    local i=1
    for host in "${hosts_ref[@]}"; do
        # Пытаемся получить имя хоста
        local hostname=$(getent hosts "$host" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$hostname" ]]; then
            printf "  %2d) %s (%s)\n" "$i" "$host" "$hostname"
        else
            printf "  %2d) %s\n" "$i" "$host"
        fi
        ((i++))
    done
    echo "   0) Пропустить / Ввести вручную"
    echo ""
}

# Основная функция определения клиентов
detect_clients() {
    echo ""
    echo "=========================================="
    echo "ОПРЕДЕЛЕНИЕ КЛИЕНТОВ NTP"
    echo "=========================================="
    echo ""
    
    # Получаем сетевые интерфейсы
    get_network_interfaces
    
    if [[ ${#DETECTED_INTERFACES[@]} -gt 0 ]]; then
        echo ""
        echo "Обнаруженные интерфейсы и сети:"
        echo ""
        
        local auto_networks=()
        
        for iface_info in "${DETECTED_INTERFACES[@]}"; do
            IFS=':' read -r iface ip_with_mask <<< "$iface_info"
            local network=$(get_network_from_ip "$ip_with_mask")
            echo "  Интерфейс: $iface"
            echo "    IP: $ip_with_mask"
            echo "    Сеть: $network"
            echo ""
            auto_networks+=("$network")
        done
        
        # Предлагаем автоматически определённые сети
        echo ""
        echo -e "${BLUE}Автоматически определены сети:${NC} ${auto_networks[*]}"
        echo ""
        echo "Выберите вариант:"
        echo "  1) Использовать автоматически определённые сети"
        echo "  2) Ввести IP-адреса клиентов вручную"
        echo "  3) Использовать значения по умолчанию (192.168.1.0/24, 192.168.2.0/24)"
        echo "  4) Пропустить и настроить позже"
        echo ""
        echo -ne "Ваш выбор [1-4]: "
        read -r choice
        
        case $choice in
            1)
                log_info "Использование автоматически определённых сетей..."
                CLIENT_NETWORKS=("${auto_networks[@]}")
                
                # Пытаемся найти хосты в сетях
                local all_hosts=()
                for network in "${CLIENT_NETWORKS[@]}"; do
                    local hosts=$(scan_network_arp "$network")
                    if [[ -n "$hosts" ]]; then
                        all_hosts+=($hosts)
                    fi
                done
                
                if [[ ${#all_hosts[@]} -gt 0 ]]; then
                    echo ""
                    log_info "Найдены хосты в сетях: ${all_hosts[*]}"
                    
                    # Назначаем клиентов автоматически (первые 4 хоста)
                    local client_names=("HQ-SRV" "HQ-CLI" "BR-RTR" "BR-SRV")
                    NTP_CLIENTS=()
                    
                    local j=0
                    for name in "${client_names[@]}"; do
                        if [[ $j -lt ${#all_hosts[@]} ]]; then
                            NTP_CLIENTS+=("$name:${all_hosts[$j]}")
                            ((j++))
                        else
                            NTP_CLIENTS+=("$name:192.168.$((j/2+1)).$((j%2*10+10))")
                        fi
                    done
                else
                    log_warning "Хосты не найдены, будут использованы значения по умолчанию"
                    NTP_CLIENTS=(
                        "HQ-SRV:192.168.1.10"
                        "HQ-CLI:192.168.1.20"
                        "BR-RTR:192.168.2.1"
                        "BR-SRV:192.168.2.10"
                    )
                fi
                ;;
            2)
                manual_input_clients
                ;;
            3)
                log_info "Использование значений по умолчанию..."
                CLIENT_NETWORKS=("192.168.1.0/24" "192.168.2.0/24")
                NTP_CLIENTS=(
                    "HQ-SRV:192.168.1.10"
                    "HQ-CLI:192.168.1.20"
                    "BR-RTR:192.168.2.1"
                    "BR-SRV:192.168.2.10"
                )
                ;;
            4|*)
                log_warning "Пропуск настройки клиентов. Настройте их позже вручную."
                CLIENT_NETWORKS=("192.168.1.0/24" "192.168.2.0/24")
                NTP_CLIENTS=(
                    "HQ-SRV:192.168.1.10"
                    "HQ-CLI:192.168.1.20"
                    "BR-RTR:192.168.2.1"
                    "BR-SRV:192.168.2.10"
                )
                ;;
        esac
    else
        log_warning "Не удалось автоматически определить сетевые интерфейсы"
        manual_input_clients
    fi
    
    # Вывод итоговой конфигурации
    echo ""
    echo "=========================================="
    echo "ИТОГОВАЯ КОНФИГУРАЦИЯ КЛИЕНТОВ"
    echo "=========================================="
    echo ""
    echo "Разрешённые сети:"
    for net in "${CLIENT_NETWORKS[@]}"; do
        echo "  - $net"
    done
    echo ""
    echo "Клиенты NTP:"
    for client in "${NTP_CLIENTS[@]}"; do
        IFS=':' read -r name ip <<< "$client"
        echo "  - $name: $ip"
    done
    echo ""
    
    # Подтверждение
    echo -ne "${GREEN}Конфигурация верна? [Y/n]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" == "n" ]] || [[ "$confirm" == "N" ]]; then
        manual_input_clients
    fi
}

# Установка chrony
install_chrony() {
    log_info "Установка пакета chrony..."
    
    if command -v apt-get &> /dev/null; then
        # Alt Linux использует apt-get (apt-rpm)
        apt-get update
        apt-get install -y chrony
    elif command -v yum &> /dev/null; then
        yum install -y chrony
    elif command -v dnf &> /dev/null; then
        dnf install -y chrony
    else
        log_error "Не удалось определить менеджер пакетов"
        exit 1
    fi
    
    log_success "Пакет chrony успешно установлен"
}

# Создание конфигурационного файла chrony
configure_chrony() {
    log_info "Настройка конфигурации chrony..."
    
    # Резервное копирование оригинального конфига
    if [[ -f /etc/chrony.conf ]]; then
        cp /etc/chrony.conf /etc/chrony.conf.backup.$(date +%Y%m%d_%H%M%S)
        log_info "Создана резервная копия конфигурации"
    fi
    
    # Формируем список allow директив
    local allow_directives=""
    allow_directives+="allow 127.0.0.1\n"
    
    for net in "${CLIENT_NETWORKS[@]}"; do
        allow_directives+="allow $net\n"
    done
    
    # Создание нового конфигурационного файла
    cat > /etc/chrony.conf << EOF
# =============================================================================
# Конфигурация NTP сервера на базе chrony
# Маршрутизатор ISP
# Создано автоматически: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# -----------------------------------------------------------------------------
# Вышестоящие NTP серверы (публичные пулы)
# -----------------------------------------------------------------------------
# Используем пул NTP серверов (можно заменить на конкретные серверы)
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst

# Альтернативные серверы (раскомментируйте при необходимости):
# server ntp1.vniiftri.ru iburst
# server ntp2.vniiftri.ru iburst
# server ntp.msk-ix.ru iburst

# -----------------------------------------------------------------------------
# Локальные настройки сервера
# -----------------------------------------------------------------------------
# Установка стратума 5 для данного сервера
# (сервер будет сообщать клиентам, что он на stratum 5)
local stratum 5

# -----------------------------------------------------------------------------
# Настройки синхронизации
# -----------------------------------------------------------------------------
# driftfile для хранения информации о частоте часов
driftfile /var/lib/chrony/drift

# Логирование
logdir /var/log/chrony
log measurements statistics tracking

# -----------------------------------------------------------------------------
# Настройки доступа (разрешённые сети клиентов)
# -----------------------------------------------------------------------------
EOF
    
    # Добавляем директивы allow для каждой сети
    echo "# Разрешить локальному хосту" >> /etc/chrony.conf
    echo "allow 127.0.0.1" >> /etc/chrony.conf
    echo "" >> /etc/chrony.conf
    
    # Добавляем сети клиентов с комментариями
    local net_num=1
    for net in "${CLIENT_NETWORKS[@]}"; do
        echo "# Сеть клиента #$net_num" >> /etc/chrony.conf
        echo "allow $net" >> /etc/chrony.conf
        ((net_num++))
    done
    
    cat >> /etc/chrony.conf << 'EOF'

# -----------------------------------------------------------------------------
# Дополнительные настройки
# -----------------------------------------------------------------------------
# Количество шагов для начальной синхронизации
makestep 1.0 3

# Включить RTC (аппаратные часы)
rtcsync

# Увеличить точность синхронизации
# hwtimestamp *

EOF
    
    # Создание директории для логов если её нет
    mkdir -p /var/log/chrony
    mkdir -p /var/lib/chrony
    
    log_success "Конфигурация chrony создана"
    
    # Выводим созданную конфигурацию
    echo ""
    echo "Содержимое /etc/chrony.conf:"
    echo "----------------------------------------"
    cat /etc/chrony.conf
    echo "----------------------------------------"
}

# Настройка firewalld (если используется)
configure_firewall() {
    log_info "Настройка фаервола..."
    
    if command -v firewall-cmd &> /dev/null; then
        # Проверяем, запущен ли firewalld
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=ntp
            firewall-cmd --permanent --add-port=123/udp
            
            # Добавляем правила для сетей клиентов
            for network in "${CLIENT_NETWORKS[@]}"; do
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$network' service name='ntp' accept"
            done
            
            firewall-cmd --reload
            log_success "Правила firewalld настроены"
        else
            log_warning "firewalld не активен, пропускаем настройку"
        fi
    else
        log_warning "firewall-cmd не найден, проверьте настройки фаервола вручную"
    fi
}

# Настройка iptables (альтернатива firewalld)
configure_iptables() {
    log_info "Настройка iptables (если используется)..."
    
    if command -v iptables &> /dev/null; then
        # Разрешаем NTP трафик
        iptables -I INPUT -p udp --dport 123 -j ACCEPT
        iptables -I INPUT -p tcp --dport 123 -j ACCEPT
        
        # Сохраняем правила (для Alt Linux)
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        
        log_success "Правила iptables настроены"
    fi
}

# Запуск и включение службы chrony
enable_chrony() {
    log_info "Запуск службы chrony..."
    
    # Останавливаем ntpd если запущен (конфликт)
    if systemctl is-active --quiet ntpd 2>/dev/null; then
        systemctl stop ntpd
        systemctl disable ntpd
        log_info "Служба ntpd остановлена (конфликт с chrony)"
    fi
    
    # Включаем и запускаем chrony
    systemctl enable chronyd
    systemctl start chronyd
    
    log_success "Служба chrony запущена и включена"
}

# Проверка статуса синхронизации
check_status() {
    log_info "Проверка статуса синхронизации..."
    
    echo ""
    echo "=========================================="
    echo "СТАТУС СЛУЖБЫ CHRONY"
    echo "=========================================="
    
    # Статус службы
    systemctl status chronyd --no-pager || true
    
    echo ""
    echo "=========================================="
    echo "ИСТОЧНИКИ NTP"
    echo "=========================================="
    chronyc sources -v || true
    
    echo ""
    echo "=========================================="
    echo "ДЕТАЛИ СИНХРОНИЗАЦИИ"
    echo "=========================================="
    chronyc tracking || true
    
    echo ""
    echo "=========================================="
    echo "СТАТИСТИКА"
    echo "=========================================="
    chronyc sourcestats || true
}

# =============================================================================
# ВЕРИФИКАЦИЯ - ПРОВЕРКА ЧТО ВСЁ ПОЛУЧИЛОСЬ
# =============================================================================

# Счётчики результатов проверки
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Функции для вывода результатов проверок
check_pass() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((PASS_COUNT++))
}

check_fail() {
    echo -e "${RED}[✗]${NC} $1"
    ((FAIL_COUNT++))
}

check_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    ((WARN_COUNT++))
}

# Основная функция верификации
verify_configuration() {
    echo ""
    echo "=========================================="
    echo "ВЕРИФИКАЦИЯ КОНФИГУРАЦИИ NTP"
    echo "=========================================="
    echo ""
    
    # Сброс счётчиков
    PASS_COUNT=0
    FAIL_COUNT=0
    WARN_COUNT=0
    
    echo "--- Проверка 1: Установлен ли пакет chrony ---"
    if rpm -q chrony &>/dev/null; then
        check_pass "Пакет chrony установлен: $(rpm -q chrony)"
    else
        check_fail "Пакет chrony НЕ установлен"
    fi
    
    echo ""
    echo "--- Проверка 2: Существует ли конфигурационный файл ---"
    if [[ -f /etc/chrony.conf ]]; then
        check_pass "Конфигурационный файл /etc/chrony.conf существует"
        
        # Проверка наличия ключевых настроек в конфиге
        if grep -q "^local stratum 5" /etc/chrony.conf 2>/dev/null; then
            check_pass "В конфиге указан stratum 5"
        else
            check_fail "В конфиге НЕ указан stratum 5"
        fi
        
        if grep -q "^server.*iburst" /etc/chrony.conf 2>/dev/null; then
            check_pass "В конфиге указаны вышестоящие NTP серверы"
        else
            check_fail "В конфиге НЕ указаны вышестоящие NTP серверы"
        fi
        
        if grep -q "^allow" /etc/chrony.conf 2>/dev/null; then
            check_pass "В конфиге разрешён доступ клиентам (allow)"
        else
            check_fail "В конфиге НЕ разрешён доступ клиентам"
        fi
    else
        check_fail "Конфигурационный файл /etc/chrony.conf НЕ существует"
    fi
    
    echo ""
    echo "--- Проверка 3: Запущена ли служба chronyd ---"
    if systemctl is-active --quiet chronyd 2>/dev/null; then
        check_pass "Служба chronyd ЗАПУЩЕНА (active)"
    else
        check_fail "Служба chronyd НЕ ЗАПУЩЕНА"
    fi
    
    echo ""
    echo "--- Проверка 4: Включена ли служба chronyd (autostart) ---"
    if systemctl is-enabled --quiet chronyd 2>/dev/null; then
        check_pass "Служба chronyd ВКЛЮЧЕНА (автозапуск)"
    else
        check_fail "Служба chronyd НЕ ВКЛЮЧЕНА (нет автозапуска)"
    fi
    
    echo ""
    echo "--- Проверка 5: Открыт ли порт 123/UDP ---"
    if ss -ulnp 2>/dev/null | grep -q ":123"; then
        check_pass "Порт 123/UDP открыт и слушается"
        ss -ulnp | grep ":123" | head -1
    else
        check_fail "Порт 123/UDP НЕ открыт"
    fi
    
    echo ""
    echo "--- Проверка 6: Стратум сервера (должен быть 5) ---"
    STRATUM=$(chronyc tracking 2>/dev/null | grep "Stratum" | awk '{print $3}')
    if [[ "$STRATUM" == "5" ]]; then
        check_pass "Стратум сервера = 5 (СООТВЕТСТВУЕТ ЗАДАНИЮ)"
    elif [[ -n "$STRATUM" ]]; then
        check_fail "Стратум сервера = $STRATUM (должен быть 5)"
    else
        check_fail "Не удалось определить стратум (служба не синхронизирована?)"
    fi
    
    echo ""
    echo "--- Проверка 7: Синхронизация с вышестоящими серверами ---"
    # Проверяем, есть ли выбранный источник (с символом *)
    if chronyc sources 2>/dev/null | grep -q "\^\*"; then
        check_pass "Есть выбранный источник синхронизации (^* в chronyc sources)"
        chronyc sources 2>/dev/null | grep "\^\*" | head -1
    else
        check_warn "Нет выбранного источника синхронизации. Подождите 1-2 минуты или выполните: chronyc makestep"
        echo "Текущие источники:"
        chronyc sources 2>/dev/null || echo "Не удалось получить список источников"
    fi
    
    echo ""
    echo "--- Проверка 8: Количество источников NTP ---"
    SOURCE_COUNT=$(chronyc sources 2>/dev/null | grep -c "^\^[*+-]" || echo "0")
    if [[ "$SOURCE_COUNT" -ge 1 ]]; then
        check_pass "Найдено источников NTP: $SOURCE_COUNT"
    else
        check_fail "Нет доступных источников NTP"
    fi
    
    echo ""
    echo "--- Проверка 9: Reach (доступность источников) ---"
    # Reach должен быть 377 (все 8 попыток успешны) или хотя бы > 0
    REACH_VALUES=$(chronyc sources 2>/dev/null | awk '/^\^/ {print $5}' | grep -v "Reach")
    if echo "$REACH_VALUES" | grep -q "[1-9]"; then
        check_pass "Источники доступны (Reach > 0)"
    else
        check_warn "Источники могут быть недоступны (Reach = 0). Проверьте сеть."
    fi
    
    echo ""
    echo "--- Проверка 10: Фаервол (NTP трафик разрешён) ---"
    FW_OK=false
    
    # Проверка firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-services 2>/dev/null | grep -q "ntp"; then
            check_pass "Firewalld: сервис ntp разрешён"
            FW_OK=true
        fi
        if firewall-cmd --list-ports 2>/dev/null | grep -q "123"; then
            check_pass "Firewalld: порт 123 разрешён"
            FW_OK=true
        fi
    fi
    
    # Проверка iptables
    if command -v iptables &>/dev/null; then
        if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:123"; then
            check_pass "Iptables: правило для порта 123 есть"
            FW_OK=true
        fi
    fi
    
    if [[ "$FW_OK" == "false" ]]; then
        check_warn "Не удалось проверить фаервол. Убедитесь, что порт 123/UDP открыт."
    fi
    
    echo ""
    echo "--- Проверка 11: Конфликт с ntpd ---"
    if systemctl is-active --quiet ntpd 2>/dev/null; then
        check_fail "Служба ntpd ЗАПУЩЕНА - конфликт с chrony! Выполните: systemctl stop ntpd && systemctl disable ntpd"
    else
        check_pass "Служба ntpd не запущена (нет конфликта)"
    fi
    
    echo ""
    echo "--- Проверка 12: Скрипты для клиентов созданы ---"
    if [[ -f /root/ntp_client_scripts/setup_ntp_client.sh ]]; then
        check_pass "Скрипт настройки клиентов существует: /root/ntp_client_scripts/setup_ntp_client.sh"
    else
        check_warn "Скрипт настройки клиентов не найден (не обязательно)"
    fi
    
    echo ""
    echo "--- Проверка 13: Текущее время системы ---"
    echo "Текущее время: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    # Проверка смещения времени
    LAST_OFFSET=$(chronyc tracking 2>/dev/null | grep "Last offset" | awk '{print $4}')
    if [[ -n "$LAST_OFFSET" ]]; then
        echo "Смещение времени: $LAST_OFFSET"
        # Проверяем, что смещение меньше 1 секунды
        if [[ $(echo "$LAST_OFFSET" | sed 's/[a-z]//gi' | awk '{if($1<1) print 1; else print 0}') -eq 1 ]] 2>/dev/null; then
            check_pass "Смещение времени приемлемое (< 1 сек)"
        else
            check_warn "Смещение времени > 1 сек. Выполните: chronyc makestep"
        fi
    fi
    
    echo ""
    echo "--- Проверка 14: Подключённые клиенты ---"
    CLIENT_COUNT=$(chronyc clients 2>/dev/null | grep -c "^[A-Za-z]" || echo "0")
    # chronyc clients выводит заголовок, поэтому вычитаем
    if [[ "$CLIENT_COUNT" -gt 0 ]]; then
        ACTUAL_CLIENTS=$((CLIENT_COUNT - 1))
        if [[ "$ACTUAL_CLIENTS" -gt 0 ]]; then
            check_pass "Подключено клиентов: $ACTUAL_CLIENTS"
            chronyc clients 2>/dev/null | head -10
        else
            check_warn "Нет подключённых клиентов (настройте клиенты и подождите)"
        fi
    else
        check_warn "Нет подключённых клиентов (это нормально, если клиенты ещё не настроены)"
    fi
    
    # Итоговый отчёт
    echo ""
    echo "=========================================="
    echo "ИТОГОВЫЙ ОТЧЁТ ВЕРИФИКАЦИИ"
    echo "=========================================="
    echo ""
    echo -e "${GREEN}Пройдено проверок:${NC} $PASS_COUNT"
    echo -e "${RED}Провалено проверок:${NC} $FAIL_COUNT"
    echo -e "${YELLOW}Предупреждений:${NC} $WARN_COUNT"
    echo ""
    
    # Финальный вердикт
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅ КОНФИГУРАЦИЯ УСПЕШНА!            ║${NC}"
        echo -e "${GREEN}║   Все критические проверки пройдены    ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo "NTP сервер готов к работе!"
        echo "Stratum: 5 (как требуется в задании)"
        echo ""
        echo "Теперь настройте клиенты:"
        echo "  HQ-SRV, HQ-CLI, BR-RTR, BR-SRV"
        echo ""
        echo "Используйте скрипт: /root/ntp_client_scripts/setup_ntp_client.sh"
        return 0
    else
        echo -e "${RED}╔════════════════════════════════════════╗${NC}"
        echo -e "${RED}║   ❌ ЕСТЬ ПРОБЛЕМЫ!                   ║${NC}"
        echo -e "${RED}║   Проверьте проваленные тесты выше    ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo "Рекомендации по исправлению:"
        echo ""
        [[ $FAIL_COUNT -gt 0 ]] && echo "1. Проверьте ошибки выше"
        echo "2. Убедитесь, что есть доступ к интернету"
        echo "3. Выполните: chronyc makestep (для принудительной синхронизации)"
        echo "4. Перезапустите службу: systemctl restart chronyd"
        echo "5. Проверьте логи: journalctl -xeu chronyd"
        return 1
    fi
}

# Функция для быстрой проверки (только верификация без настройки)
verify_only() {
    clear
    echo "=========================================="
    echo "ПРОВЕРКА КОНФИГУРАЦИИ NTP (только проверка)"
    echo "=========================================="
    echo ""
    check_root
    verify_configuration
}

# Создание скрипта для клиентов
create_client_scripts() {
    log_info "Создание скриптов настройки для клиентов..."
    
    local client_dir="/root/ntp_client_scripts"
    mkdir -p "$client_dir"
    
    # IP маршрутизатора ISP (NTP сервера)
    # Определяем IP локального интерфейса
    LOCAL_IP=$(ip route get 1 | awk '{print $7; exit}')
    
    # Скрипт для клиента
    cat > "$client_dir/setup_ntp_client.sh" << 'CLIENTSCRIPT'
#!/bin/bash
#
# Скрипт настройки NTP клиента (chrony) для Alt Linux
# Автоматически определяет IP NTP сервера
#

set -e

NTP_SERVER="NTP_SERVER_IP_PLACEHOLDER"

echo "[INFO] Установка chrony..."
apt-get update && apt-get install -y chrony

echo "[INFO] Настройка chrony клиента..."

cat > /etc/chrony.conf << EOF
# NTP клиент - синхронизация с маршрутизатором ISP
server $NTP_SERVER iburst prefer

# Дополнительные публичные серверы (резерв)
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst

# driftfile
driftfile /var/lib/chrony/drift

# Локальные настройки
makestep 1.0 3
rtcsync

# Логирование
logdir /var/log/chrony
EOF

echo "[INFO] Запуск службы chrony..."
systemctl enable chronyd
systemctl restart chronyd

echo "[SUCCESS] NTP клиент настроен!"
echo "NTP сервер: $NTP_SERVER"
chronyc sources
CLIENTSCRIPT
    
    # Заменяем плейсхолдер на реальный IP
    sed -i "s/NTP_SERVER_IP_PLACEHOLDER/$LOCAL_IP/g" "$client_dir/setup_ntp_client.sh"
    chmod +x "$client_dir/setup_ntp_client.sh"
    
    # Создаем инструкции для каждого клиента
    for client in "${NTP_CLIENTS[@]}"; do
        IFS=':' read -r name ip <<< "$client"
        echo "Настройка для $name ($ip):" > "$client_dir/instruction_${name}.txt"
        echo "" >> "$client_dir/instruction_${name}.txt"
        echo "1. Скопируйте скрипт на $name:" >> "$client_dir/instruction_${name}.txt"
        echo "   scp $client_dir/setup_ntp_client.sh root@$ip:/root/" >> "$client_dir/instruction_${name}.txt"
        echo "" >> "$client_dir/instruction_${name}.txt"
        echo "2. Выполните на $name:" >> "$client_dir/instruction_${name}.txt"
        echo "   chmod +x /root/setup_ntp_client.sh" >> "$client_dir/instruction_${name}.txt"
        echo "   /root/setup_ntp_client.sh" >> "$client_dir/instruction_${name}.txt"
        echo "" >> "$client_dir/instruction_${name}.txt"
        echo "3. Проверьте синхронизацию:" >> "$client_dir/instruction_${name}.txt"
        echo "   chronyc sources" >> "$client_dir/instruction_${name}.txt"
        echo "   chronyc tracking" >> "$client_dir/instruction_${name}.txt"
    done
    
    log_success "Скрипты для клиентов созданы в директории: $client_dir"
}

# Вывод информации о настройках
show_info() {
    echo ""
    echo "=========================================="
    echo "НАСТРОЙКА NTP СЕРВЕРА ЗАВЕРШЕНА"
    echo "=========================================="
    echo ""
    echo "Параметры сервера:"
    echo "  - Stratum: 5"
    echo "  - Вышестоящие серверы: pool.ntp.org"
    echo ""
    echo "Разрешённые сети:"
    for net in "${CLIENT_NETWORKS[@]}"; do
        echo "  - $net"
    done
    echo ""
    echo "Настроенные клиенты:"
    for client in "${NTP_CLIENTS[@]}"; do
        IFS=':' read -r name ip <<< "$client"
        echo "  - $name: $ip"
    done
    echo ""
    echo "Полезные команды:"
    echo "  chronyc sources    - показать источники времени"
    echo "  chronyc tracking   - показать статус синхронизации"
    echo "  chronyc clients    - показать подключённых клиентов"
    echo "  chronyc makestep   - принудительная синхронизация"
    echo ""
    echo "Конфигурационный файл: /etc/chrony.conf"
    echo "Логи: /var/log/chrony/"
    echo ""
}

# Главная функция
main() {
    # Проверка аргументов
    if [[ "$1" == "--verify" ]] || [[ "$1" == "-v" ]] || [[ "$1" == "verify" ]]; then
        verify_only
        exit $?
    fi
    
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "Использование: $0 [опция]"
        echo ""
        echo "Опции:"
        echo "  без аргументов  - полная настройка NTP сервера"
        echo "  --verify, -v    - только проверка конфигурации"
        echo "  --help, -h      - показать эту справку"
        echo ""
        echo "Примеры:"
        echo "  $0              - настройка NTP сервера"
        echo "  $0 --verify     - проверка что всё настроено правильно"
        exit 0
    fi
    
    clear
    echo "=========================================="
    echo "НАСТРОЙКА NTP СЕРВЕРА (CHRONY)"
    echo "Маршрутизатор ISP - Alt Linux"
    echo "=========================================="
    echo ""
    
    check_root
    detect_clients
    install_chrony
    configure_chrony
    configure_firewall
    configure_iptables
    enable_chrony
    create_client_scripts
    
    # Ждём немного для инициализации синхронизации
    echo ""
    log_info "Ожидание инициализации службы (5 секунд)..."
    sleep 5
    
    # Пытаемся принудительно синхронизировать время
    log_info "Принудительная синхронизация времени..."
    chronyc makestep 2>/dev/null || true
    sleep 2
    
    # Проверка статуса
    check_status
    
    # Верификация
    verify_configuration
    
    show_info
    
    log_success "Настройка завершена!"
}

# Запуск
main "$@"
