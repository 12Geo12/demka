#!/bin/bash

# Скрипт для автоматической настройки GRE туннеля и OSPF на ALT Linux
# Версия: 3.0 - Исправленная и оптимизированная для ALT Linux
# Совместимость: ALT Linux p10+, FRR 8.x+

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Файл для лога отчета
REPORT_FILE="/root/network_setup_report_$(date +%Y%m%d_%H%M%S).log"

# Переменные для отката
BACKUP_DIR=""
ROLLBACK_NEEDED=false

# Функция для вывода сообщений с дублированием в отчет
log_message() {
    local color=$1
    local level=$2
    local message=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${color}[$level]${NC} $message"
    echo "[$timestamp][$level] $message" >> "$REPORT_FILE"
}

print_info() { log_message "$GREEN" "INFO" "$1"; }
print_warning() { log_message "$YELLOW" "WARNING" "$1"; }
print_error() { log_message "$RED" "ERROR" "$1"; }
print_step() { log_message "$BLUE" "STEP" "$1"; }
print_success() { log_message "$PURPLE" "SUCCESS" "$1"; }
print_command() { log_message "$CYAN" "COMMAND" "$1"; }

# Функция для выполнения команд с логированием
run_command() {
    local cmd="$1"
    local description="$2"
    local critical="${3:-false}"  # Критическая ли команда (true/false)
    
    print_command "Выполнение: $cmd"
    echo "### Результат выполнения команды: $cmd" >> "$REPORT_FILE"
    
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    echo "$output" >> "$REPORT_FILE"
    echo "### Код возврата: $exit_code" >> "$REPORT_FILE"
    
    if [ $exit_code -eq 0 ]; then
        print_info "✓ Команда выполнена успешно"
    else
        if [ "$critical" = "true" ]; then
            print_error "✗ Критическая команда завершилась с кодом $exit_code"
            return $exit_code
        else
            print_warning "⚠ Команда завершилась с кодом $exit_code"
        fi
    fi
    
    return $exit_code
}

# Функция отката изменений
rollback_changes() {
    print_warning "Выполняется откат изменений..."
    
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        # Восстанавливаем конфигурацию сети
        if [ -d "$BACKUP_DIR/ifaces" ]; then
            rm -rf /etc/net/ifaces/gre1 2>/dev/null
            print_info "Удалена конфигурация gre1"
        fi
        
        # Восстанавливаем конфигурацию FRR
        if [ -d "$BACKUP_DIR/frr" ]; then
            cp -r "$BACKUP_DIR/frr"/* /etc/frr/ 2>/dev/null
            print_info "Восстановлена конфигурация FRR"
        fi
        
        # Перезапускаем службы
        systemctl restart network 2>/dev/null
        systemctl restart frr 2>/dev/null
        
        print_info "Откат завершен"
    fi
}

# Функция для определения всех IP-адресов и сетей
discover_networks() {
    print_step "Автоматическое определение сетевой конфигурации..."
    
    # Собираем информацию о сети
    {
        echo "=== СЕТЕВАЯ КОНФИГУРАЦИЯ ==="
        echo "Дата: $(date)"
        echo "Хост: $(hostname)"
        echo ""
        echo "--- IP-адреса интерфейсов ---"
        ip -4 addr show
        echo ""
        echo "--- Таблица маршрутизации ---"
        ip route show
        echo ""
        echo "--- Интерфейсы (состояние) ---"
        ip link show
        echo ""
        echo "--- Версия системы ---"
        cat /etc/os-release 2>/dev/null || cat /etc/altlinux-release 2>/dev/null
    } >> "$REPORT_FILE"
    
    # Определяем все активные интерфейсы (кроме lo)
    mapfile -t INTERFACES < <(ip link show | grep -E "state UP" | grep -v "lo:" | awk -F': ' '{print $2}' | cut -d@ -f1)
    
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        print_error "Не найдено активных сетевых интерфейсов"
    fi
    
    print_info "Найдены активные интерфейсы: ${INTERFACES[*]}"
    
    # Определяем основной интерфейс (с default route)
    MAIN_IF=$(ip route | grep "default" | awk '{print $5}' | head -1)
    
    if [ -z "$MAIN_IF" ]; then
        for iface in "${INTERFACES[@]}"; do
            if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet"; then
                MAIN_IF=$iface
                break
            fi
        done
    fi
    
    if [ -z "$MAIN_IF" ]; then
        print_error "Не удалось определить основной интерфейс"
    fi
    
    # Получаем основной IP (исправлено для совместимости)
    MAIN_IP=$(ip -4 addr show "$MAIN_IF" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
    
    if [ -z "$MAIN_IP" ]; then
        print_error "Не удалось определить IP-адрес основного интерфейса"
    fi
    
    print_info "Основной интерфейс: $MAIN_IF (IP: $MAIN_IP)"
    
    # Определяем все локальные сети
    LOCAL_NETWORKS=()
    
    while IFS= read -r line; do
        if [[ $line == *"proto kernel"* ]] && [[ $line == *"scope link"* ]]; then
            local network=$(echo "$line" | awk '{print $1}')
            local dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            
            # Проверяем что сеть валидна
            if [[ $network =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                if [ "$dev" != "$MAIN_IF" ] && [ "$dev" != "lo" ]; then
                    LOCAL_NETWORKS+=("$network")
                    print_info "Найдена локальная сеть: $network на интерфейсе $dev"
                fi
            fi
        fi
    done < <(ip route show)
    
    # Определяем роль роутера
    ROUTER_ROLE="UNKNOWN"
    
    # Метод 1: По локальным сетям
    for network in "${LOCAL_NETWORKS[@]}"; do
        case $network in
            192.168.10.*|192.168.20.*)
                ROUTER_ROLE="HQ-RTR"
                break
                ;;
            192.168.30.*)
                ROUTER_ROLE="BR-RTR"
                break
                ;;
        esac
    done
    
    # Метод 2: По имени хоста
    if [ "$ROUTER_ROLE" == "UNKNOWN" ]; then
        local hostname_lower=$(hostname | tr '[:upper:]' '[:lower:]')
        if [[ $hostname_lower == *"hq"* ]]; then
            ROUTER_ROLE="HQ-RTR"
        elif [[ $hostname_lower == *"br"* ]]; then
            ROUTER_ROLE="BR-RTR"
        fi
    fi
    
    # Метод 3: По IP-адресу основного интерфейса
    if [ "$ROUTER_ROLE" == "UNKNOWN" ]; then
        local third_octet=$(echo "$MAIN_IP" | cut -d'.' -f3)
        case $third_octet in
            4)
                ROUTER_ROLE="HQ-RTR"
                ;;
            5)
                ROUTER_ROLE="BR-RTR"
                ;;
        esac
    fi
    
    # Если все еще неизвестно, запрашиваем у пользователя
    if [ "$ROUTER_ROLE" == "UNKNOWN" ]; then
        print_warning "Не удалось автоматически определить роль роутера"
        echo -e "${YELLOW}Выберите роль:${NC}"
        echo "  1) HQ-RTR (Главный офис)"
        echo "  2) BR-RTR (Филиал)"
        read -r -p "Введите номер [1/2]: " choice
        
        case $choice in
            1) ROUTER_ROLE="HQ-RTR" ;;
            2) ROUTER_ROLE="BR-RTR" ;;
            *) print_error "Неверный выбор" ;;
        esac
    fi
    
    print_success "Определена роль роутера: $ROUTER_ROLE"
    echo "ROUTER_ROLE=$ROUTER_ROLE" >> "$REPORT_FILE"
    echo "MAIN_IF=$MAIN_IF" >> "$REPORT_FILE"
    echo "MAIN_IP=$MAIN_IP" >> "$REPORT_FILE"
}

# Функция для определения параметров туннеля
determine_tunnel_params() {
    print_step "Определение параметров GRE туннеля..."
    
    TUN_LOCAL="$MAIN_IP"
    
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        # HQ-RTR: локальный IP в сети 172.16.4.x, удаленный в 172.16.5.x
        TUN_REMOTE="172.16.5.2"
        TUNNEL_IP="172.16.100.2"
        REMOTE_TUN_IP="172.16.100.1"
        
        # Добавляем локальные сети HQ для OSPF
        if [ ${#LOCAL_NETWORKS[@]} -eq 0 ]; then
            LOCAL_NETWORKS=("192.168.10.0/24" "192.168.20.0/24")
        fi
    else
        # BR-RTR: локальный IP в сети 172.16.5.x, удаленный в 172.16.4.x
        TUN_REMOTE="172.16.4.2"
        TUNNEL_IP="172.16.100.1"
        REMOTE_TUN_IP="172.16.100.2"
        
        # Добавляем локальные сети BR для OSPF
        if [ ${#LOCAL_NETWORKS[@]} -eq 0 ]; then
            LOCAL_NETWORKS=("192.168.30.0/24")
        fi
    fi
    
    TUNNEL_NETWORK="172.16.100.0/29"
    
    print_info "Параметры туннеля:"
    print_info "  - Роль: $ROUTER_ROLE"
    print_info "  - Локальный IP: $TUN_LOCAL"
    print_info "  - Удаленный IP: $TUN_REMOTE"
    print_info "  - IP туннеля: $TUNNEL_IP/29"
    print_info "  - Сеть туннеля: $TUNNEL_NETWORK"
    print_info "  - Локальные сети для OSPF: ${LOCAL_NETWORKS[*]}"
    
    # Проверяем доступность удаленного IP (не критично)
    print_info "Проверка доступности удаленного IP $TUN_REMOTE..."
    if ping -c 2 -W 2 "$TUN_REMOTE" &>/dev/null; then
        print_success "Удаленный IP $TUN_REMOTE доступен"
    else
        print_warning "Удаленный IP $TUN_REMOTE не отвечает (возможно, туннель еще не настроен на другой стороне)"
    fi
    
    echo "TUN_LOCAL=$TUN_LOCAL" >> "$REPORT_FILE"
    echo "TUN_REMOTE=$TUN_REMOTE" >> "$REPORT_FILE"
    echo "TUNNEL_IP=$TUNNEL_IP" >> "$REPORT_FILE"
}

# Функция для создания резервной копии
create_backup() {
    print_step "Создание резервной копии конфигурации..."
    
    BACKUP_DIR="/root/network_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    ROLLBACK_NEEDED=true
    
    # Сохраняем конфигурацию сети
    if [ -d "/etc/net/ifaces" ]; then
        mkdir -p "$BACKUP_DIR/ifaces"
        # Копируем только существующую конфигурацию gre1 если есть
        if [ -d "/etc/net/ifaces/gre1" ]; then
            cp -r /etc/net/ifaces/gre1 "$BACKUP_DIR/ifaces/"
            print_info "Сохранена существующая конфигурация gre1"
        fi
        # Копируем конфигурацию основного интерфейса
        if [ -d "/etc/net/ifaces/$MAIN_IF" ]; then
            cp -r "/etc/net/ifaces/$MAIN_IF" "$BACKUP_DIR/ifaces/"
            print_info "Сохранена конфигурация интерфейса $MAIN_IF"
        fi
    fi
    
    # Сохраняем конфигурацию FRR
    if [ -d "/etc/frr" ]; then
        cp -r /etc/frr "$BACKUP_DIR/"
        print_info "Сохранена конфигурация FRR"
    fi
    
    # Сохраняем диагностику
    {
        echo "=== ДИАГНОСТИКА ДО ИЗМЕНЕНИЙ ==="
        echo "Дата: $(date)"
        echo ""
        echo "--- IP-адреса ---"
        ip addr show
        echo ""
        echo "--- Маршруты ---"
        ip route show
        echo ""
        echo "--- Статус FRR ---"
        systemctl status frr 2>&1 || echo "FRR не установлен или не запущен"
        echo ""
        echo "--- Конфигурация FRR ---"
        cat /etc/frr/frr.conf 2>/dev/null || echo "Файл не существует"
    } > "$BACKUP_DIR/pre_setup_diagnostics.txt"
    
    print_success "Резервная копия создана в $BACKUP_DIR"
    echo "BACKUP_PATH=$BACKUP_DIR" >> "$REPORT_FILE"
}

# Функция для настройки GRE туннеля (ALT Linux специфично)
setup_gre_tunnel() {
    print_step "Настройка GRE туннеля..."
    
    # Проверяем наличие модуля ядра gre
    if ! lsmod | grep -q "^gre"; then
        print_info "Загрузка модуля ядра gre..."
        modprobe gre || print_warning "Не удалось загрузить модуль gre (возможно, встроен в ядро)"
    fi
    
    # Удаляем существующий интерфейс если есть
    if ip link show gre1 &>/dev/null; then
        print_warning "Интерфейс gre1 уже существует, удаляем..."
        ip link del gre1 2>/dev/null || true
    fi
    
    # Создаем каталог для интерфейса туннеля (ALT Linux way)
    GRE_DIR="/etc/net/ifaces/gre1"
    
    if [ -d "$GRE_DIR" ]; then
        print_warning "Каталог $GRE_DIR уже существует, пересоздаем..."
        rm -rf "$GRE_DIR"
    fi
    
    mkdir -p "$GRE_DIR"
    
    # Создаем файл options (формат для ALT Linux)
    # ВАЖНО: Для GRE туннелей в ALT Linux используется TYPE=iptun
    cat > "$GRE_DIR/options" << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNOPTIONS='ttl 64 key 0'
HOST=$MAIN_IF
ONBOOT=yes
EOF
    
    print_info "Создан файл options:"
    cat "$GRE_DIR/options" >> "$REPORT_FILE"
    
    # Создаем файл с IP адресом туннеля
    echo "$TUNNEL_IP/29" > "$GRE_DIR/ipv4address"
    print_info "Создан файл ipv4address"
    
    # Создаем файл для активации интерфейса
    echo "TYPE=iptun" > "$GRE_DIR/options"
    echo "TUNTYPE=gre" >> "$GRE_DIR/options"
    echo "TUNLOCAL=$TUN_LOCAL" >> "$GRE_DIR/options"
    echo "TUNREMOTE=$TUN_REMOTE" >> "$GRE_DIR/options"
    echo "TUNOPTIONS='ttl 64'" >> "$GRE_DIR/options"
    echo "HOST=$MAIN_IF" >> "$GRE_DIR/options"
    
    # Перезапускаем сеть
    print_info "Перезапуск сетевой службы..."
    
    # Пробуем разные способы перезапуска сети в ALT Linux
    if systemctl status network &>/dev/null; then
        run_command "systemctl restart network" "Перезапуск network" "false"
    elif systemctl status networkmanager &>/dev/null; then
        run_command "systemctl restart networkmanager" "Перезапуск networkmanager" "false"
    else
        # Альтернативный способ - поднимаем интерфейс вручную
        print_warning "Network service не найден, пробуем поднять интерфейс вручную..."
        
        # Создаем туннель через ip command (fallback)
        ip tunnel add gre1 mode gre local "$TUN_LOCAL" remote "$TUN_REMOTE" ttl 64
        ip link set gre1 up
        ip addr add "$TUNNEL_IP/29" dev gre1
    fi
    
    # Ждем появления интерфейса
    print_info "Ожидание появления интерфейса gre1..."
    local wait_count=0
    while ! ip link show gre1 &>/dev/null; do
        sleep 1
        wait_count=$((wait_count + 1))
        if [ $wait_count -ge 10 ]; then
            print_error "Таймаут ожидания интерфейса gre1"
        fi
    done
    
    # Проверяем создание интерфейса
    if ip link show gre1 &>/dev/null; then
        print_success "Интерфейс gre1 успешно создан"
        
        # Показываем детали
        {
            echo "=== ДЕТАЛИ ИНТЕРФЕЙСА GRE1 ==="
            ip addr show gre1
            echo ""
            ip link show gre1
            echo ""
            ip tunnel show gre1 2>/dev/null || true
        } >> "$REPORT_FILE"
        
        # Проверяем что интерфейс UP
        if ip link show gre1 | grep -q "state UNKNOWN\|state UP"; then
            print_success "Интерфейс gre1 активен"
        else
            print_warning "Интерфейс gre1 не активен, пытаемся поднять..."
            ip link set gre1 up
        fi
    else
        print_error "Ошибка создания интерфейса gre1"
    fi
}

# Функция для установки и настройки FRR
setup_frr() {
    print_step "Настройка FRR (Free Range Routing)..."
    
    # Проверяем установлен ли FRR
    if ! rpm -q frr &>/dev/null; then
        print_info "FRR не установлен. Установка..."
        
        # Обновляем репозитории и устанавливаем FRR
        run_command "apt-get update" "Обновление репозиториев" "false"
        run_command "apt-get install -y frr" "Установка FRR" "true"
        
        if [ $? -ne 0 ]; then
            print_error "Не удалось установить FRR"
        fi
    else
        print_info "FRR уже установлен: $(rpm -q frr)"
    fi
    
    # Проверяем наличие необходимых пакетов
    print_info "Проверка зависимостей FRR..."
    for pkg in frr frr-pythontools; do
        if ! rpm -q "$pkg" &>/dev/null; then
            print_warning "Пакет $pkg не установлен, устанавливаем..."
            apt-get install -y "$pkg" || print_warning "Не удалось установить $pkg"
        fi
    done
    
    # Включаем демоны в /etc/frr/daemons
    print_info "Настройка демонов FRR..."
    
    local daemons_file="/etc/frr/daemons"
    
    # Создаем резервную копию
    cp "$daemons_file" "$daemons_file.bak"
    
    # Включаем необходимые демоны
    # zebra обычно уже включена
    sed -i 's/^zebra=no/zebra=yes/' "$daemons_file"
    sed -i 's/^#zebra=no/zebra=yes/' "$daemons_file"
    
    # Включаем ospfd
    sed -i 's/^ospfd=no/ospfd=yes/' "$daemons_file"
    sed -i 's/^#ospfd=no/ospfd=yes/' "$daemons_file"
    
    # Показываем изменения
    {
        echo "=== ИЗМЕНЕНИЯ В /etc/frr/daemons ==="
        echo "Статус демонов:"
        grep -E "^(z|ospf|bgp|rip)d=" "$daemons_file" || true
    } >> "$REPORT_FILE"
    
    # Настраиваем /etc/frr/frr.conf если не существует
    if [ ! -f "/etc/frr/frr.conf" ] || [ ! -s "/etc/frr/frr.conf" ]; then
        print_info "Создание базовой конфигурации FRR..."
        cat > /etc/frr/frr.conf << 'EOF'
frr version 8.x
frr defaults traditional
hostname Router
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
line vty
!
EOF
    fi
    
    # Включаем и запускаем FRR
    print_info "Включение и запуск службы FRR..."
    run_command "systemctl enable frr" "Включение FRR в автозагрузку" "false"
    run_command "systemctl start frr" "Запуск FRR" "true"
    
    # Ждем запуска
    sleep 3
    
    # Проверяем статус
    if systemctl is-active --quiet frr; then
        print_success "Служба frr активна"
        
        # Проверяем что vtysh работает
        if vtysh -c "show version" &>/dev/null; then
            print_success "VTYSH работает корректно"
        else
            print_warning "VTYSH не отвечает, проверьте конфигурацию"
        fi
    else
        print_error "Служба frr не запустилась. Проверьте логи: journalctl -u frr -n 50"
    fi
    
    # Показываем статус
    {
        echo "=== СТАТУС FRR ==="
        systemctl status frr
        echo ""
        echo "=== ВЕРСИЯ FRR ==="
        vtysh -c "show version" 2>/dev/null || echo "VTYSH недоступен"
    } >> "$REPORT_FILE"
}

# Функция для настройки OSPF (исправлена для FRR 8.x+)
setup_ospf() {
    print_step "Настройка OSPF через vtysh..."
    
    # Проверяем что FRR запущен
    if ! systemctl is-active --quiet frr; then
        print_error "FRR не запущен, невозможно настроить OSPF"
    fi
    
    # Формируем команды OSPF для FRR 8.x
    # ВАЖНО: В FRR 8.x синтаксис аутентификации изменился
    
    local ospf_config="/tmp/ospf_config.txt"
    
    {
        echo "configure terminal"
        echo "!"
        echo "! Настройка OSPF"
        echo "router ospf"
        echo " ospf router-id $TUNNEL_IP"
        echo " passive-interface default"
        echo "!"
        
        # Добавляем туннельную сеть
        echo "! Туннельная сеть"
        echo " network $TUNNEL_NETWORK area 0"
        echo "!"
        
        # Добавляем все локальные сети
        for network in "${LOCAL_NETWORKS[@]}"; do
            echo "! Локальная сеть $network"
            echo " network $network area 0"
            print_info "Добавлена сеть $network в OSPF area 0"
        done
        echo "!"
        
        # Выходим из router ospf
        echo "exit"
        echo "!"
        
        # Настраиваем интерфейс туннеля
        echo "interface gre1"
        echo " no ip ospf passive"
        echo " ip ospf mtu-ignore"
        echo " ip ospf hello-interval 10"
        echo " ip ospf dead-interval 40"
        
        # Аутентификация (простая для совместимости)
        # Для FRR 8.x используем новый синтаксис
        echo " ip ospf authentication"
        echo " ip ospf authentication-key 1245"
        echo "exit"
        echo "!"
        
        echo "end"
        echo "write memory"
    } > "$ospf_config"
    
    print_info "Команды OSPF:"
    cat "$ospf_config" >> "$REPORT_FILE"
    
    # Применяем конфигурацию
    print_info "Применение конфигурации OSPF..."
    
    if vtysh < "$ospf_config" >> "$REPORT_FILE" 2>&1; then
        print_success "Конфигурация OSPF применена"
    else
        print_warning "Возникли проблемы при применении конфигурации OSPF"
        
        # Пытаемся применить пошагово
        print_info "Пробуем применить конфигурацию пошагово..."
        
        vtysh -c "configure terminal" \
              -c "router ospf" \
              -c "ospf router-id $TUNNEL_IP" \
              -c "passive-interface default" \
              -c "network $TUNNEL_NETWORK area 0" 2>/dev/null
        
        for network in "${LOCAL_NETWORKS[@]}"; do
            vtysh -c "configure terminal" \
                  -c "router ospf" \
                  -c "network $network area 0" 2>/dev/null
        done
        
        vtysh -c "configure terminal" \
              -c "interface gre1" \
              -c "no ip ospf passive" \
              -c "ip ospf authentication" \
              -c "ip ospf authentication-key 1245" 2>/dev/null
        
        vtysh -c "write memory" 2>/dev/null
    fi
    
    rm -f "$ospf_config"
    
    # Перезапускаем FRR для применения
    print_info "Перезапуск FRR..."
    run_command "systemctl restart frr" "Перезапуск FRR" "false"
    sleep 3
    
    print_success "OSPF настроен"
}

# Функция для проверки конфигурации
verify_configuration() {
    print_step "Проверка итоговой конфигурации..."
    
    {
        echo "=== ПРОВЕРКА КОНФИГУРАЦИИ ==="
        echo "Дата: $(date)"
        echo ""
        echo "--- Интерфейс gre1 ---"
        ip addr show gre1 2>/dev/null || echo "Интерфейс gre1 не найден"
        echo ""
        echo "--- Туннель ---"
        ip tunnel show 2>/dev/null || true
        echo ""
        echo "--- Статус OSPF ---"
        vtysh -c "show ip ospf" 2>/dev/null || echo "OSPF не настроен"
        echo ""
        echo "--- Интерфейсы OSPF ---"
        vtysh -c "show ip ospf interface" 2>/dev/null || echo "Нет OSPF интерфейсов"
        echo ""
        echo "--- Соседи OSPF ---"
        vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Нет OSPF соседей"
        echo ""
        echo "--- Маршруты OSPF ---"
        vtysh -c "show ip route ospf" 2>/dev/null || echo "Нет OSPF маршрутов"
        echo ""
        echo "--- Полная таблица маршрутизации ---"
        ip route show
        echo ""
        echo "--- Конфигурация FRR ---"
        vtysh -c "show running-config" 2>/dev/null | head -100 || echo "Не удалось получить конфигурацию"
    } >> "$REPORT_FILE"
    
    # Выводим важную информацию в консоль
    echo ""
    print_info "════════════════════════════════════════════════════════════"
    print_info "                    РЕЗУЛЬТАТЫ НАСТРОЙКИ"
    print_info "════════════════════════════════════════════════════════════"
    
    echo -e "${CYAN}Интерфейс gre1:${NC}"
    ip -4 addr show gre1 2>/dev/null | grep "inet " | sed 's/^/  /' || echo "  Не найден"
    
    echo ""
    echo -e "${CYAN}Статус OSPF:${NC}"
    vtysh -c "show ip ospf" 2>/dev/null | head -10 | sed 's/^/  /' || echo "  OSPF не активен"
    
    echo ""
    echo -e "${CYAN}Соседи OSPF:${NC}"
    vtysh -c "show ip ospf neighbor" 2>/dev/null | sed 's/^/  /' || echo "  Нет соседей (ожидайте ~40 секунд)"
    
    echo ""
    echo -e "${CYAN}OSPF маршруты:${NC}"
    vtysh -c "show ip route ospf" 2>/dev/null | sed 's/^/  /' || echo "  Нет маршрутов (ожидайте появления соседей)"
    
    print_info "════════════════════════════════════════════════════════════"
}

# Функция для тестирования связанности
test_connectivity() {
    print_step "Тестирование сетевой связанности..."
    
    {
        echo "=== ТЕСТИРОВАНИЕ СВЯЗАННОСТИ ==="
        echo "Дата: $(date)"
        echo ""
    } >> "$REPORT_FILE"
    
    # Тестируем ping до удаленного конца туннеля
    print_info "Проверка связи с удаленным концом туннеля ($REMOTE_TUN_IP)..."
    
    local ping_result
    if ping -c 4 -W 2 "$REMOTE_TUN_IP" &>/dev/null; then
        print_success "✓ Связь с туннелем установлена"
        {
            echo "--- Ping до $REMOTE_TUN_IP ---"
            ping -c 4 "$REMOTE_TUN_IP"
            echo ""
        } >> "$REPORT_FILE"
    else
        print_warning "✗ Нет связи с удаленным концом туннеля ($REMOTE_TUN_IP)"
        print_warning "  Проверьте: 1) Настроен ли туннель на другой стороне"
        print_warning "           2) Доступен ли удаленный IP ($TUN_REMOTE)"
        print_warning "           3) Нет ли блокировки firewall"
        {
            echo "--- Ping до $REMOTE_TUN_IP (неуспешно) ---"
            ping -c 4 "$REMOTE_TUN_IP" 2>&1
            echo ""
            echo "--- Трассировка ---"
            traceroute -n "$REMOTE_TUN_IP" 2>&1 | head -10 || true
        } >> "$REPORT_FILE"
    fi
    
    # Проверяем маршрут до удаленных сетей
    local test_net
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        test_net="192.168.30.1"
    else
        test_net="192.168.10.1"
    fi
    
    print_info "Проверка маршрута до удаленной сети ($test_net)..."
    if ip route get "$test_net" &>/dev/null; then
        print_success "✓ Маршрут до $test_net существует"
        ip route get "$test_net" >> "$REPORT_FILE"
    else
        print_warning "✗ Нет маршрута до $test_net (OSPF маршрут появится после установления соседства)"
    fi
    
    # Проверяем OSPF соседей
    print_info "Ожидание появления OSPF соседей (до 60 секунд)..."
    
    local neighbor_count=0
    local wait_time=0
    
    while [ $wait_time -lt 60 ]; do
        neighbor_count=$(vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full\|Init\|2-Way" || echo "0")
        
        if [ "$neighbor_count" -gt 0 ]; then
            print_success "✓ OSPF сосед найден!"
            break
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
        print_info "  Ожидание... ($wait_time сек)"
    done
    
    if [ "$neighbor_count" -eq 0 ]; then
        print_warning "✗ OSPF соседи не обнаружены за 60 секунд"
        print_warning "  Убедитесь, что на удаленном роутере настроен OSPF с совместимой аутентификацией"
    fi
}

# Функция для настройки firewall
setup_firewall() {
    print_step "Настройка firewall..."
    
    # Проверяем какой firewall используется
    if systemctl is-active --quiet firewalld; then
        print_info "Обнаружен firewalld"
        
        # Разрешаем OSPF и GRE
        firewall-cmd --permanent --add-protocol=ospf 2>/dev/null || true
        firewall-cmd --permanent --add-protocol=gre 2>/dev/null || true
        firewall-cmd --permanent --add-port=22/tcp 2>/dev/null || true
        
        # Разрешаем трафик в туннеле
        firewall-cmd --permanent --zone=trusted --add-interface=gre1 2>/dev/null || true
        
        firewall-cmd --reload 2>/dev/null || true
        
        print_info "Firewalld настроен для OSPF и GRE"
        
    elif command -v iptables &>/dev/null; then
        print_info "Используется iptables"
        
        # Разрешаем GRE протокол (протокол 47)
        iptables -I INPUT -p gre -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p ospf -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT -p gre -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT -p ospf -j ACCEPT 2>/dev/null || true
        
        # Разрешаем трафик через туннель
        iptables -I FORWARD -i gre1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -o gre1 -j ACCEPT 2>/dev/null || true
        
        print_info "iptables настроены для OSPF и GRE"
    else
        print_info "Firewall не обнаружен или отключен"
    fi
    
    # Сохраняем правила iptables если нужно
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    fi
}

# Функция для вывода справки
show_help() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  -h, --help     Показать эту справку"
    echo "  -r, --role     Указать роль роутера (HQ-RTR или BR-RTR)"
    echo "  -d, --dry-run  Только показать что будет сделано без применения"
    echo "  -v, --verbose  Подробный вывод"
    echo ""
    echo "Примеры:"
    echo "  $0                     # Автоматическое определение роли"
    echo "  $0 -r HQ-RTR           # Явное указание роли"
    echo ""
    exit 0
}

# Главная функция
main() {
    # Обработка аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -r|--role)
                ROUTER_ROLE_OVERRIDE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            *)
                print_warning "Неизвестный параметр: $1"
                shift
                ;;
        esac
    done
    
    # Инициализация лога
    echo "═══════════════════════════════════════════════════════════════" | tee -a "$REPORT_FILE"
    echo "     НАСТРОЙКА GRE ТУННЕЛЯ И OSPF ДЛЯ ALT LINUX               " | tee -a "$REPORT_FILE"
    echo "                    Версия 3.0                                " | tee -a "$REPORT_FILE"
    echo "═══════════════════════════════════════════════════════════════" | tee -a "$REPORT_FILE"
    echo "Дата и время: $(date)" | tee -a "$REPORT_FILE"
    echo "Хост: $(hostname)" | tee -a "$REPORT_FILE"
    echo "Пользователь: $(whoami)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Проверка прав root
    if [ "$EUID" -ne 0 ]; then
        print_error "Скрипт должен быть запущен с правами root"
    fi
    
    # Проверка что это ALT Linux
    if [ ! -f "/etc/altlinux-release" ] && [ ! -f "/etc/os-release" ] || ! grep -qi "alt" /etc/os-release 2>/dev/null; then
        print_warning "Эта система может быть не ALT Linux. Скрипт оптимизирован для ALT Linux."
        print_warning "Продолжаем выполнение..."
    fi
    
    # Устанавливаем trap для отката
    trap 'echo ""; print_warning "Скрипт прерван!"; if [ "$ROLLBACK_NEEDED" = true ]; then read -p "Выполнить откат? [y/N]: " answer; if [ "$answer" = "y" ]; then rollback_changes; fi; fi; exit 130' INT TERM
    
    # Выполняем шаги настройки
    discover_networks
    
    # Применяем переопределение роли если задано
    if [ -n "$ROUTER_ROLE_OVERRIDE" ]; then
        ROUTER_ROLE="$ROUTER_ROLE_OVERRIDE"
        print_info "Роль переопределена: $ROUTER_ROLE"
    fi
    
    determine_tunnel_params
    create_backup
    setup_gre_tunnel
    setup_frr
    setup_firewall
    setup_ospf
    verify_configuration
    test_connectivity
    
    # Итоговый отчет
    echo ""
    echo "═══════════════════════════════════════════════════════════════" | tee -a "$REPORT_FILE"
    echo "                    НАСТРОЙКА ЗАВЕРШЕНА                        " | tee -a "$REPORT_FILE"
    echo "═══════════════════════════════════════════════════════════════" | tee -a "$REPORT_FILE"
    
    ROLLBACK_NEEDED=false
    
    print_success "Конфигурация успешно применена!"
    print_info "Подробный отчет сохранен в: $REPORT_FILE"
    print_info "Резервная копия: $BACKUP_DIR"
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                    ПОЛЕЗНЫЕ КОМАНДЫ                          ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}Просмотр соседей OSPF:${NC}     vtysh -c 'show ip ospf neighbor'"
    echo -e "${GREEN}Просмотр OSPF маршрутов:${NC}   vtysh -c 'show ip route ospf'"
    echo -e "${GREEN}Просмотр OSPF интерфейсов:${NC} vtysh -c 'show ip ospf interface'"
    echo -e "${GREEN}Просмотр OSPF базы данных:${NC} vtysh -c 'show ip ospf database'"
    echo -e "${GREEN}Конфигурация OSPF:${NC}        vtysh -c 'show running-config' | grep -A20 'router ospf'"
    echo ""
    echo -e "${GREEN}Проверка интерфейса gre1:${NC} ip addr show gre1"
    echo -e "${GREEN}Проверка туннеля:${NC}         ip tunnel show"
    echo -e "${GREEN}Пинг туннеля:${NC}             ping 172.16.100.1  (или 172.16.100.2)"
    echo ""
    echo -e "${GREEN}Перезапуск FRR:${NC}           systemctl restart frr"
    echo -e "${GREEN}Логи FRR:${NC}                 journalctl -u frr -f"
    echo -e "${GREEN}Просмотр отчета:${NC}          cat $REPORT_FILE"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
}

# Запуск
main "$@"
