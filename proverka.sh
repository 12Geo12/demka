#!/bin/bash
#===============================================================================
#                    СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ НА ALTLINUX SERVER
#===============================================================================
# Данный скрипт выполняет автоматическую настройку IP-туннеля (GRE) между
# маршрутизаторами офисов HQ и BR на базе AltLinux Server.
# Скрипт автоматически определяет IP-адреса интерфейсов и настраивает туннель.
#===============================================================================

#-------------------------------------------------------------------------------
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
declare -a INTERFACES
declare -a IP_ADDRESSES
INTERFACE_COUNT=0

#-------------------------------------------------------------------------------
# ФУНКЦИИ
#-------------------------------------------------------------------------------

# Вывод информации
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Получение всех интерфейсов с IP-адресами
get_all_interfaces() {
    log_info "Получение списка интерфейсов..."
    
    echo ""
    echo "========================================"
    echo "    ДОСТУПНЫЕ СЕТЕВЫЕ ИНТЕРФЕЙСЫ"
    echo "========================================"
    echo ""
    
    # Используем глобальные массивы
    local count=0
    
    # Получаем все интерфейсы с IPv4 адресами
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+:[[:space:]]([^:]+): ]]; then
            current_iface="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ inet[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]]; then
            ip_addr="${BASH_REMATCH[1]}"
            # Пропускаем loopback
            if [[ "$current_iface" != "lo" ]]; then
                count=$((count + 1))
                INTERFACES+=("$current_iface")
                IP_ADDRESSES+=("$ip_addr")
                echo "  $count) Интерфейс: $current_iface"
                echo "     IP-адрес: $ip_addr"
                echo ""
            fi
        fi
    done < <(ip -4 addr show)
    
    if [ $count -eq 0 ]; then
        log_error "Не найдено интерфейсов с IPv4 адресами"
        return 1
    fi
    
    INTERFACE_COUNT=$count
    
    echo "----------------------------------------"
    return 0
}

# Выбор внешнего интерфейса
select_external_interface() {
    echo ""
    echo "Выберите номер интерфейса, который будет использоваться для туннеля:"
    echo -n "Введите номер [1-$INTERFACE_COUNT]: "
    read -r selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$INTERFACE_COUNT" ]; then
        log_error "Неверный выбор"
        return 1
    fi
    
    local idx=$((selection - 1))
    EXTERNAL_INTERFACE="${INTERFACES[$idx]}"
    local ip_with_mask="${IP_ADDRESSES[$idx]}"
    EXTERNAL_IP="${ip_with_mask%/*}"
    EXTERNAL_PREFIX="${ip_with_mask#*/}"
    
    echo ""
    echo "----------------------------------------"
    echo "Выбран внешний интерфейс: $EXTERNAL_INTERFACE"
    echo "IP-адрес: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "----------------------------------------"
    
    return 0
}

# Запрос удаленного IP-адреса у пользователя
get_remote_ip() {
    echo ""
    echo "========================================"
    echo "    НАСТРОЙКА УДАЛЕННОГО IP-АДРЕСА"
    echo "========================================"
    echo ""
    echo "Введите IP-адрес удаленного маршрутизатора для туннеля."
    echo "Это внешний IP-адрес другого конца туннеля."
    echo ""
    echo -n "Удаленный IP-адрес (без маски): "
    read -r REMOTE_IP
    
    # Проверка формата IP
    if [[ ! "$REMOTE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Неверный формат IP-адреса"
        return 1
    fi
    
    echo ""
    echo "Удаленный IP-адрес: $REMOTE_IP"
    echo "----------------------------------------"
    
    return 0
}

# Запрос туннельных IP-адресов
get_tunnel_ips() {
    echo ""
    echo "========================================"
    echo "    НАСТРОЙКА ТУННЕЛЬНЫХ IP-АДРЕСОВ"
    echo "========================================"
    echo ""
    echo "Введите IP-адреса для туннельного интерфейса."
    echo "Обычно используется сеть 10.10.0.0/30 или 10.0.0.0/30"
    echo ""
    
    echo -n "Локальный туннельный IP-адрес (например, 10.10.0.1): "
    read -r TUNNEL_LOCAL
    
    if [[ ! "$TUNNEL_LOCAL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Неверный формат IP-адреса"
        return 1
    fi
    
    echo -n "Маска подсети туннеля (например, 30): "
    read -r TUNNEL_PREFIX
    
    if [ -z "$TUNNEL_PREFIX" ]; then
        TUNNEL_PREFIX="30"
    fi
    
    echo -n "Удаленный туннельный IP-адрес (например, 10.10.0.2): "
    read -r TUNNEL_REMOTE
    
    if [[ ! "$TUNNEL_REMOTE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Неверный формат IP-адреса"
        return 1
    fi
    
    echo ""
    echo "----------------------------------------"
    echo "Локальный туннельный IP: $TUNNEL_LOCAL/$TUNNEL_PREFIX"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo "----------------------------------------"
    
    return 0
}

# Выбор пароля для аутентификации туннеля
select_password() {
    echo ""
    echo "========================================"
    echo "    ВЫБОР ПАРОЛЯ АУТЕНТИФИКАЦИИ ТУННЕЛЯ"
    echo "========================================"
    echo ""
    echo "Выберите опцию для пароля аутентификации:"
    echo "  1) Использовать пароль по умолчанию: P@ssw0rd"
    echo "  2) Ввести свой пароль"
    echo "  3) Сгенерировать случайный пароль"
    echo ""
    echo -n "Ваш выбор [1-3]: "
    read -r password_choice
    
    case "$password_choice" in
        1)
            TUNNEL_PASSWORD="P@ssw0rd"
            log_info "Выбран пароль по умолчанию"
            ;;
        2)
            echo -n "Введите пароль для аутентификации туннеля: "
            read -r TUNNEL_PASSWORD
            if [ -z "$TUNNEL_PASSWORD" ]; then
                log_error "Пароль не может быть пустым. Используется пароль по умолчанию."
                TUNNEL_PASSWORD="P@ssw0rd"
            fi
            log_info "Установлен пользовательский пароль"
            ;;
        3)
            TUNNEL_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9@#$%' | head -c 16)
            log_info "Сгенерирован случайный пароль"
            ;;
        *)
            TUNNEL_PASSWORD="P@ssw0rd"
            log_info "Неверный выбор. Используется пароль по умолчанию."
            ;;
    esac
    
    echo ""
    echo "----------------------------------------"
    echo "Пароль аутентификации туннеля: $TUNNEL_PASSWORD"
    echo "----------------------------------------"
    echo ""
}

# Загрузка модуля GRE
load_gre_module() {
    log_info "Загрузка модуля GRE..."
    
    modprobe gre
    if [ $? -eq 0 ]; then
        echo "Модуль GRE успешно загружен"
    else
        log_error "Не удалось загрузить модуль GRE"
        return 1
    fi
    
    # Добавляем модуль в автозагрузку
    if ! grep -q "^gre" /etc/modules 2>/dev/null; then
        echo "gre" >> /etc/modules
        echo "Модуль GRE добавлен в автозагрузку"
    fi
    
    # Проверка загрузки модуля
    echo ""
    echo "Проверка загруженных модулей:"
    lsmod | grep gre
    echo ""
}

# Создание конфигурации туннельного интерфейса
create_tunnel_config() {
    log_info "Создание конфигурации туннеля..."
    
    TUNNEL_IFACE="gre1"
    TUNNEL_DIR="/etc/net/ifaces/$TUNNEL_IFACE"
    
    # Создание директории для туннельного интерфейса
    mkdir -p "$TUNNEL_DIR"
    
    # Создание файла options
    cat > "$TUNNEL_DIR/options" << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$EXTERNAL_IP
TUNREMOTE=$REMOTE_IP
TUNOPTIONS='ttl 64'
EOF
    
    echo "Создан файл: $TUNNEL_DIR/options"
    cat "$TUNNEL_DIR/options"
    echo ""
    
    # Создание файла ipv4address
    cat > "$TUNNEL_DIR/ipv4address" << EOF
$TUNNEL_LOCAL/$TUNNEL_PREFIX
EOF
    
    echo "Создан файл: $TUNNEL_DIR/ipv4address"
    cat "$TUNNEL_DIR/ipv4address"
    echo ""
    
    log_success "Конфигурация туннеля создана"
}

# Перезапуск сетевой службы
restart_network() {
    log_info "Перезапуск сетевой службы..."
    
    systemctl restart network
    
    if [ $? -eq 0 ]; then
        echo "Сетевая служба успешно перезапущена"
    else
        log_error "Ошибка при перезапуске сетевой службы"
        return 1
    fi
    
    sleep 2
}

# Проверка туннельного интерфейса
verify_tunnel() {
    log_info "Проверка туннельного интерфейса..."
    
    echo ""
    echo "Состояние интерфейсов:"
    ip -br a | grep -E "(gre|$TUNNEL_IFACE)"
    echo ""
    
    echo "Детальная информация о туннеле:"
    ip a show "$TUNNEL_IFACE" 2>/dev/null || echo "Интерфейс $TUNNEL_IFACE не найден"
    echo ""
    
    echo "Маршруты:"
    ip r | grep -E "(gre|10\.)" || echo "Маршруты не найдены"
    echo ""
}

# Проверка связности туннеля
test_tunnel_connectivity() {
    log_info "Проверка связности туннеля..."
    
    echo ""
    echo "Пинг удаленного туннельного адреса ($TUNNEL_REMOTE):"
    ping -c 4 "$TUNNEL_REMOTE"
    
    echo ""
}

# Установка и настройка OSPF (FRR)
setup_ospf() {
    log_info "Настройка динамической маршрутизации OSPF..."
    
    echo ""
    echo "Настроить OSPF для динамической маршрутизации? [y/N]: "
    read -r setup_ospf_choice
    
    if [[ "$setup_ospf_choice" =~ ^[Yy]$ ]]; then
        log_info "Установка FRR..."
        
        apt-get update
        apt-get install -y frr
        
        # Включение OSPF демона
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        
        # Запуск FRR
        systemctl enable --now frr
        systemctl restart frr
        
        echo ""
        echo "FRR установлен и запущен"
        echo ""
        echo "Настройка OSPF выполняется через vtysh:"
        echo "----------------------------------------"
        echo "vtysh"
        echo "conf t"
        echo "router ospf"
        echo "ospf router-id $TUNNEL_LOCAL"
        echo "network ${TUNNEL_LOCAL%.*.*}.0.0/30 area 0"
        echo "area 0 authentication"
        echo "exit"
        echo "interface $TUNNEL_IFACE"
        echo "ip ospf authentication-key $TUNNEL_PASSWORD"
        echo "ip ospf authentication"
        echo "no ip ospf passive"
        echo "exit"
        echo "exit"
        echo "wr"
        echo "----------------------------------------"
        echo ""
        
        log_success "Базовая настройка OSPF подготовлена"
    else
        log_info "Пропуск настройки OSPF"
    fi
}

# Вывод итоговой информации
print_summary() {
    echo ""
    echo "========================================"
    echo "         ИТОГОВАЯ ИНФОРМАЦИЯ"
    echo "========================================"
    echo ""
    echo "Внешний интерфейс: $EXTERNAL_INTERFACE"
    echo "Локальный IP: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "Удаленный IP: $REMOTE_IP"
    echo ""
    echo "Туннельный интерфейс: $TUNNEL_IFACE"
    echo "Локальный туннельный IP: $TUNNEL_LOCAL/$TUNNEL_PREFIX"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo ""
    echo "Пароль аутентификации: $TUNNEL_PASSWORD"
    echo ""
    echo "Конфигурационные файлы:"
    echo "  - $TUNNEL_DIR/options"
    echo "  - $TUNNEL_DIR/ipv4address"
    echo ""
    echo "Проверка туннеля:"
    echo "  ping $TUNNEL_REMOTE"
    echo ""
    echo "========================================"
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ЛОГИКА
#-------------------------------------------------------------------------------

clear

echo "==============================================================================="
echo "                 СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ НА ALTLINUX SERVER"
echo "==============================================================================="
echo ""
echo "Данный скрипт выполнит:"
echo "  1. Определение доступных интерфейсов"
echo "  2. Выбор внешнего интерфейса для туннеля"
echo "  3. Настройку параметров туннеля"
echo "  4. Настройку парольной аутентификации"
echo "  5. Проверку работоспособности туннеля"
echo ""

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Скрипт должен выполняться от имени root"
    exit 1
fi

# Шаг 1: Получение списка интерфейсов
get_all_interfaces
if [ $? -ne 0 ]; then
    exit 1
fi

# Шаг 2: Выбор внешнего интерфейса
select_external_interface
if [ $? -ne 0 ]; then
    exit 1
fi

# Шаг 3: Запрос удаленного IP
get_remote_ip
if [ $? -ne 0 ]; then
    exit 1
fi

# Шаг 4: Запрос туннельных IP
get_tunnel_ips
if [ $? -ne 0 ]; then
    exit 1
fi

# Шаг 5: Выбор пароля
select_password

# Подтверждение продолжения
echo ""
echo "========================================"
echo "    ПОДТВЕРЖДЕНИЕ ПАРАМЕТРОВ"
echo "========================================"
echo ""
echo "Внешний интерфейс: $EXTERNAL_INTERFACE ($EXTERNAL_IP/$EXTERNAL_PREFIX)"
echo "Удаленный IP: $REMOTE_IP"
echo "Локальный туннельный IP: $TUNNEL_LOCAL/$TUNNEL_PREFIX"
echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
echo "Пароль: $TUNNEL_PASSWORD"
echo ""
echo -n "Продолжить настройку туннеля? [Y/n]: "
read -r continue_choice

if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
    log_info "Настройка отменена пользователем"
    exit 0
fi

# Шаг 6: Загрузка модуля GRE
load_gre_module

# Шаг 7: Создание конфигурации
create_tunnel_config

# Шаг 8: Перезапуск сети
restart_network

# Шаг 9: Проверка
verify_tunnel

# Шаг 10: Проверка связности
echo "Выполнить тест связности туннеля? [Y/n]: "
read -r test_choice

if [[ ! "$test_choice" =~ ^[Nn]$ ]]; then
    test_tunnel_connectivity
fi

# Шаг 11: Настройка OSPF
setup_ospf

# Вывод итоговой информации
print_summary

log_success "Настройка GRE-туннеля завершена!"
echo ""
