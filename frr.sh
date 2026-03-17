#!/bin/bash

# Скрипт для автоматической настройки GRE туннеля и OSPF
# Версия: 2.0 с автоматическим определением IP и подробным выводом

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

# Функция для вывода сообщений с дублированием в отчет
log_message() {
    local color=$1
    local level=$2
    local message=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Вывод в консоль с цветом
    echo -e "${color}[$level]${NC} $message"
    
    # Запись в лог-файл без цвета
    echo "[$timestamp][$level] $message" >> $REPORT_FILE
}

print_info() { log_message "$GREEN" "INFO" "$1"; }
print_warning() { log_message "$YELLOW" "WARNING" "$1"; }
print_error() { log_message "$RED" "ERROR" "$1"; exit 1; }
print_step() { log_message "$BLUE" "STEP" "$1"; }
print_success() { log_message "$PURPLE" "SUCCESS" "$1"; }
print_command() { log_message "$CYAN" "COMMAND" "$1"; }

# Функция для выполнения команд с логированием
run_command() {
    local cmd="$1"
    local description="$2"
    
    print_command "Выполнение: $cmd"
    echo "### Результат выполнения команды: $cmd" >> $REPORT_FILE
    
    # Выполняем команду и сохраняем вывод
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    echo "$output" >> $REPORT_FILE
    echo "### Код возврата: $exit_code" >> $REPORT_FILE
    
    if [ $exit_code -eq 0 ]; then
        print_info "✓ Команда выполнена успешно"
    else
        print_warning "⚠ Команда завершилась с кодом $exit_code"
    fi
    
    return $exit_code
}

# Функция для определения всех IP-адресов и сетей
discover_networks() {
    print_step "Автоматическое определение сетевой конфигурации..."
    
    # Создаем временные файлы для сбора информации
    local temp_file=$(mktemp)
    
    # Собираем всю информацию о сети
    {
        echo "=== СЕТЕВАЯ КОНФИГУРАЦИЯ ==="
        echo "Дата: $(date)"
        echo ""
        echo "--- IP-адреса интерфейсов ---"
        ip -4 addr show | grep -v "127.0.0.1" | grep -E '^[0-9]+:|inet'
        echo ""
        echo "--- Таблица маршрутизации ---"
        ip route show
        echo ""
        echo "--- Интерфейсы (состояние) ---"
        ip link show
    } >> $REPORT_FILE
    
    # Определяем все активные интерфейсы (кроме lo)
    INTERFACES=($(ip link show | grep -v "lo:" | grep "state UP" | awk -F': ' '{print $2}' | cut -d@ -f1))
    
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        print_error "Не найдено активных сетевых интерфейсов"
    fi
    
    print_info "Найдены активные интерфейсы: ${INTERFACES[*]}"
    
    # Определяем основной интерфейс (с default route)
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$MAIN_IF" ]; then
        # Если нет default route, берем первый интерфейс с IP (кроме lo)
        for iface in "${INTERFACES[@]}"; do
            if ip -4 addr show $iface | grep -q "inet"; then
                MAIN_IF=$iface
                break
            fi
        done
    fi
    
    if [ -z "$MAIN_IF" ]; then
        print_error "Не удалось определить основной интерфейс"
    fi
    
    MAIN_IP=$(ip -4 addr show $MAIN_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    print_info "Основной интерфейс: $MAIN_IF (IP: $MAIN_IP)"
    
    # Определяем все локальные сети
    LOCAL_NETWORKS=()
    
    # Получаем все маршруты для connected сетей
    while read -r line; do
        if [[ $line == *"proto kernel"* ]] && [[ $line == *"scope link"* ]]; then
            # Извлекаем сеть из маршрута
            local network=$(echo "$line" | awk '{print $1}')
            local dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            
            # Исключаем сеть основного интерфейса (она будет использоваться для туннеля)
            if [ "$dev" != "$MAIN_IF" ]; then
                LOCAL_NETWORKS+=("$network")
                print_info "Найдена локальная сеть: $network на интерфейсе $dev"
            fi
        fi
    done < <(ip route show)
    
    # Определяем роль роутера по локальным сетям
    ROUTER_ROLE="UNKNOWN"
    for network in "${LOCAL_NETWORKS[@]}"; do
        case $network in
            192.168.10.*|192.168.20.*)
                ROUTER_ROLE="HQ-RTR"
                ;;
            192.168.30.*)
                ROUTER_ROLE="BR-RTR"
                ;;
        esac
    done
    
    if [ "$ROUTER_ROLE" == "UNKNOWN" ]; then
        # Пытаемся определить по имени хоста или другим признакам
        if hostname | grep -qi "hq"; then
            ROUTER_ROLE="HQ-RTR"
        elif hostname | grep -qi "br"; then
            ROUTER_ROLE="BR-RTR"
        else
            # По умолчанию определяем по подсети основного IP
            if [[ $MAIN_IP == 172.16.4.* ]]; then
                ROUTER_ROLE="HQ-RTR"
            elif [[ $MAIN_IP == 172.16.5.* ]]; then
                ROUTER_ROLE="BR-RTR"
            fi
        fi
    fi
    
    print_info "Определена роль роутера: $ROUTER_ROLE"
}

# Функция для определения параметров туннеля
determine_tunnel_params() {
    print_step "Определение параметров GRE туннеля..."
    
    TUN_LOCAL=$MAIN_IP
    
    # Определяем удаленный IP на основе роли
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        # Для HQ-RTR удаленный IP должен быть в сети 172.16.5.0/24
        # Извлекаем первые три октета локального IP
        local base_ip=$(echo $MAIN_IP | cut -d. -f1-3)
        # Меняем 4-й октет на 5-й
        TUN_REMOTE="172.16.5.2"
        
        # Проверяем доступность удаленного IP
        if ping -c 1 -W 1 $TUN_REMOTE &>/dev/null; then
            print_info "Удаленный IP $TUN_REMOTE доступен"
        else
            print_warning "Удаленный IP $TUN_REMOTE не отвечает на ping, но продолжаем настройку"
        fi
        
        TUNNEL_IP="172.16.100.2"
    else
        # Для BR-RTR
        TUN_REMOTE="172.16.4.2"
        
        if ping -c 1 -W 1 $TUN_REMOTE &>/dev/null; then
            print_info "Удаленный IP $TUN_REMOTE доступен"
        else
            print_warning "Удаленный IP $TUN_REMOTE не отвечает на ping, но продолжаем настройку"
        fi
        
        TUNNEL_IP="172.16.100.1"
    fi
    
    TUNNEL_NETWORK="172.16.100.0/29"
    
    print_info "Параметры туннеля:"
    print_info "  - Локальный IP: $TUN_LOCAL"
    print_info "  - Удаленный IP: $TUN_REMOTE"
    print_info "  - IP туннеля: $TUNNEL_IP/29"
    print_info "  - Сеть туннеля: $TUNNEL_NETWORK"
}

# Функция для создания резервной копии
create_backup() {
    print_step "Создание резервной копии конфигурации..."
    
    BACKUP_DIR="/root/network_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR
    
    # Сохраняем текущую конфигурацию сети
    if [ -d "/etc/net/ifaces" ]; then
        cp -r /etc/net/ifaces $BACKUP_DIR/
        print_info "Сохранена конфигурация сети"
    fi
    
    # Сохраняем конфигурацию FRR
    if [ -d "/etc/frr" ]; then
        cp -r /etc/frr $BACKUP_DIR/
        print_info "Сохранена конфигурация FRR"
    fi
    
    # Сохраняем вывод команд для диагностики
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
        systemctl status frr 2>&1
    } > $BACKUP_DIR/pre_setup_diagnostics.txt
    
    print_success "Резервная копия создана в $BACKUP_DIR"
    echo "BACKUP_PATH=$BACKUP_DIR" >> $REPORT_FILE
}

# Функция для настройки GRE туннеля
setup_gre_tunnel() {
    print_step "Настройка GRE туннеля..."
    
    # Создаем каталог для интерфейса туннеля
    if [ ! -d "/etc/net/ifaces/gre1" ]; then
        mkdir -p /etc/net/ifaces/gre1
        print_info "Создан каталог /etc/net/ifaces/gre1"
    else
        print_warning "Каталог /etc/net/ifaces/gre1 уже существует"
    fi
    
    # Создаем файл options
    cat > /etc/net/ifaces/gre1/options << EOF
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNTYPE=gre
TYPE=iptun
TUNOPTIONS='ttl 64'
HOST=$MAIN_IF
EOF
    print_info "Создан файл options с содержимым:"
    cat /etc/net/ifaces/gre1/options >> $REPORT_FILE
    
    # Создаем файл с IP адресом
    echo "$TUNNEL_IP/29" > /etc/net/ifaces/gre1/ipv4address
    print_info "Создан файл ipv4address с адресом $TUNNEL_IP/29"
    
    # Перезапускаем сеть
    print_info "Перезапуск сетевой службы..."
    run_command "systemctl restart network" "Перезапуск сети"
    
    # Проверяем создание интерфейса
    sleep 3
    if ip link show gre1 &>/dev/null; then
        print_success "Интерфейс gre1 успешно создан"
        
        # Показываем детали интерфейса
        {
            echo "=== ДЕТАЛИ ИНТЕРФЕЙСА GRE1 ==="
            ip addr show gre1
            echo ""
            ip link show gre1
        } >> $REPORT_FILE
    else
        print_error "Ошибка создания интерфейса gre1"
    fi
}

# Функция для настройки FRR
setup_frr() {
    print_step "Настройка FRR (Free Range Routing)..."
    
    # Проверяем установлен ли FRR
    if ! command -v vtysh &>/dev/null; then
        print_info "FRR не установлен. Установка..."
        run_command "apt-get update" "Обновление репозиториев"
        run_command "apt-get install -y frr frr-pythontools" "Установка FRR"
    else
        print_info "FRR уже установлен"
    fi
    
    # Включаем и запускаем FRR
    run_command "systemctl enable --now frr" "Включение и запуск FRR"
    
    # Проверяем статус
    if systemctl is-active --quiet frr; then
        print_success "Служба frr активна"
    else
        print_error "Служба frr не запустилась"
    fi
    
    # Редактируем конфигурацию демонов
    print_info "Включение демона ospfd в /etc/frr/daemons"
    
    # Создаем резервную копию оригинального файла
    cp /etc/frr/daemons /etc/frr/daemons.backup
    
    # Включаем ospfd
    sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
    sed -i 's/^#ospfd=no/ospfd=yes/' /etc/frr/daemons
    
    # Показываем изменения
    {
        echo "=== ИЗМЕНЕНИЯ В /etc/frr/daemons ==="
        echo "Было:"
        grep -E '^#?ospfd=' /etc/frr/daemons.backup || echo "ospfd=no"
        echo "Стало:"
        grep -E '^ospfd=' /etc/frr/daemons
    } >> $REPORT_FILE
    
    # Перезапускаем FRR
    run_command "systemctl restart frr" "Перезапуск FRR"
    
    sleep 3
    print_success "FRR настроен"
}

# Функция для настройки OSPF
setup_ospf() {
    print_step "Настройка OSPF через vtysh..."
    
    # Создаем временный файл с командами OSPF
    local ospf_cmds_file=$(mktemp)
    
    {
        echo "configure terminal"
        echo "router ospf"
        echo " passive-interface default"
        echo " network $TUNNEL_NETWORK area 0"
        
        # Добавляем все локальные сети
        for network in "${LOCAL_NETWORKS[@]}"; do
            echo " network $network area 0"
            print_info "Добавлена сеть $network в OSPF"
        done
        
        echo " area 0 authentication"
        echo " exit"
        echo " interface gre1"
        echo "  no ip ospf passive"
        echo "  ip ospf authentication-key 1245"
        echo " exit"
        echo " end"
        echo " write memory"
    } > $ospf_cmds_file
    
    print_info "Команды OSPF:"
    cat $ospf_cmds_file >> $REPORT_FILE
    
    # Применяем конфигурацию
    print_info "Применение конфигурации OSPF..."
    vtysh < $ospf_cmds_file >> $REPORT_FILE 2>&1
    
    rm $ospf_cmds_file
    
    # Перезапускаем сеть
    run_command "systemctl restart network" "Перезапуск сети для применения OSPF"
    
    print_success "OSPF настроен"
}

# Функция для проверки конфигурации
verify_configuration() {
    print_step "Проверка итоговой конфигурации..."
    
    {
        echo "=== ПРОВЕРКА КОНФИГУРАЦИИ ==="
        echo ""
        echo "--- Интерфейс gre1 ---"
        ip addr show gre1
        echo ""
        echo "--- Соседи OSPF ---"
        vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не настроен или нет соседей"
        echo ""
        echo "--- Маршруты OSPF ---"
        vtysh -c "show ip route ospf" 2>/dev/null || echo "Нет OSPF маршрутов"
        echo ""
        echo "--- Полная таблица маршрутизации ---"
        ip route show
        echo ""
        echo "--- Конфигурация OSPF ---"
        vtysh -c "show running-config" | grep -A30 "router ospf" || echo "OSPF не настроен"
    } >> $REPORT_FILE
    
    # Выводим важную информацию в консоль
    echo ""
    print_info "РЕЗУЛЬТАТЫ НАСТРОЙКИ:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo -e "${CYAN}Интерфейс gre1:${NC}"
    ip -4 addr show gre1 | grep -o 'inet [0-9./]*' | sed 's/^/  /'
    
    echo -e "${CYAN}Соседи OSPF:${NC}"
    vtysh -c "show ip ospf neighbor" 2>/dev/null | sed 's/^/  /' || echo "  Нет соседей"
    
    echo -e "${CYAN}OSPF маршруты:${NC}"
    vtysh -c "show ip route ospf" 2>/dev/null | sed 's/^/  /' || echo "  Нет маршрутов"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Функция для тестирования связанности
test_connectivity() {
    print_step "Тестирование сетевой связанности..."
    
    {
        echo "=== ТЕСТИРОВАНИЕ СВЯЗАННОСТИ ==="
        echo ""
    } >> $REPORT_FILE
    
    # Определяем удаленный IP туннеля
    if [ "$TUNNEL_IP" == "172.16.100.2" ]; then
        REMOTE_TUN_IP="172.16.100.1"
    else
        REMOTE_TUN_IP="172.16.100.2"
    fi
    
    print_info "Проверка связи с удаленным концом туннеля ($REMOTE_TUN_IP)..."
    if ping -c 4 -W 2 $REMOTE_TUN_IP &>/dev/null; then
        print_success "✓ Связь с туннелем установлена"
        {
            echo "--- Ping до $REMOTE_TUN_IP ---"
            ping -c 4 $REMOTE_TUN_IP
            echo ""
        } >> $REPORT_FILE
    else
        print_warning "✗ Нет связи с удаленным концом туннеля"
        {
            echo "--- Ping до $REMOTE_TUN_IP (неуспешно) ---"
            ping -c 4 $REMOTE_TUN_IP
            echo ""
        } >> $REPORT_FILE
    fi
    
    # Проверяем маршрут до удаленных сетей
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        TEST_NET="192.168.30.1"
    else
        TEST_NET="192.168.10.1"
    fi
    
    print_info "Проверка маршрута до $TEST_NET..."
    if ip route get $TEST_NET &>/dev/null; then
        print_success "✓ Маршрут до $TEST_NET существует"
        ip route get $TEST_NET >> $REPORT_FILE
    else
        print_warning "✗ Нет маршрута до $TEST_NET"
    fi
}

# Главная функция
main() {
    echo "═══════════════════════════════════════════════════════════════" | tee -a $REPORT_FILE
    echo "     НАСТРОЙКА GRE ТУННЕЛЯ И OSPF (Автоматический режим)     " | tee -a $REPORT_FILE
    echo "═══════════════════════════════════════════════════════════════" | tee -a $REPORT_FILE
    echo "Дата и время: $(date)" | tee -a $REPORT_FILE
    echo "Хост: $(hostname)" | tee -a $REPORT_FILE
    echo "" | tee -a $REPORT_FILE
    
    # Проверка прав root
    if [ "$EUID" -ne 0 ]; then
        print_error "Скрипт должен быть запущен с правами root"
    fi
    
    # Выполняем шаги настройки
    discover_networks
    determine_tunnel_params
    create_backup
    setup_gre_tunnel
    setup_frr
    setup_ospf
    verify_configuration
    test_connectivity
    
    # Итоговый отчет
    echo ""
    echo "═══════════════════════════════════════════════════════════════" | tee -a $REPORT_FILE
    echo "                    НАСТРОЙКА ЗАВЕРШЕНА                        " | tee -a $REPORT_FILE
    echo "═══════════════════════════════════════════════════════════════" | tee -a $REPORT_FILE
    
    print_success "Конфигурация успешно применена!"
    print_info "Подробный отчет сохранен в: $REPORT_FILE"
    print_info "Резервная копия: $BACKUP_DIR"
    
    echo ""
    echo -e "${YELLOW}ПОЛЕЗНЫЕ КОМАНДЫ ДЛЯ ПРОВЕРКИ:${NC}"
    echo "  • Просмотр соседей OSPF: vtysh -c 'show ip ospf neighbor'"
    echo "  • Просмотр маршрутов: vtysh -c 'show ip route'"
    echo "  • Проверка интерфейса: ip addr show gre1"
    echo "  • Пинг туннеля: ping 172.16.100.1 (или 172.16.100.2)"
    echo "  • Просмотр отчета: cat $REPORT_FILE"
}

# Запуск с обработкой ошибок
trap 'print_error "Скрипт прерван пользователем"' INT TERM
main