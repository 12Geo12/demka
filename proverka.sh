#!/bin/bash
#===============================================================================
#                    СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ НА ALTLINUX SERVER
#===============================================================================
# Данный скрипт выполняет автоматическую настройку IP-туннеля (GRE) между
# маршрутизаторами офисов HQ и BR на базе AltLinux Server.
# Скрипт автоматически определяет IP-адреса интерфейсов и настраивает туннель.
#===============================================================================

#-------------------------------------------------------------------------------
# ФУНКЦИИ
#-------------------------------------------------------------------------------

# Вывод информации с меткой времени
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Автоматическое определение IP-адреса внешнего интерфейса
detect_external_ip() {
    log_info "Определение внешнего IP-адреса..."
    
    # Получаем список интерфейсов с IP-адресами из сети 172.16.0.0/12
    local interfaces=$(ip -4 addr show | grep -E "inet 172\.(1[0-6]|[0-9])\." | head -1)
    
    if [ -z "$interfaces" ]; then
        log_error "Не найден интерфейс с IP-адресом из сети 172.16.0.0/12"
        return 1
    fi
    
    EXTERNAL_INTERFACE=$(echo "$interfaces" | awk '{print $NF}')
    EXTERNAL_IP=$(echo "$interfaces" | awk '{print $2}' | cut -d'/' -f1)
    EXTERNAL_PREFIX=$(echo "$interfaces" | awk '{print $2}' | cut -d'/' -f2)
    
    echo "----------------------------------------"
    echo "Найден внешний интерфейс: $EXTERNAL_INTERFACE"
    echo "IP-адрес: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "----------------------------------------"
    
    return 0
}

# Определение удаленного IP-адреса для туннеля
detect_remote_ip() {
    log_info "Определение удаленного IP-адреса для туннеля..."
    
    # Определяем роль маршрутизатора по IP-адресу
    case "$EXTERNAL_IP" in
        172.16.1.*)
            # HQ-RTR (сеть 172.16.1.0/28)
            ROUTER_ROLE="HQ-RTR"
            REMOTE_IP="172.16.2.2"
            TUNNEL_LOCAL="10.10.0.1"
            TUNNEL_REMOTE="10.10.0.2"
            TUNNEL_PREFIX="30"
            log_info "Определена роль: HQ-RTR"
            ;;
        172.16.2.*)
            # BR-RTR (сеть 172.16.2.0/28)
            ROUTER_ROLE="BR-RTR"
            REMOTE_IP="172.16.1.2"
            TUNNEL_LOCAL="10.10.0.2"
            TUNNEL_REMOTE="10.10.0.1"
            TUNNEL_PREFIX="30"
            log_info "Определена роль: BR-RTR"
            ;;
        172.16.4.*)
            # Альтернативная конфигурация HQ-RTR
            ROUTER_ROLE="HQ-RTR"
            REMOTE_IP="172.16.5.2"
            TUNNEL_LOCAL="10.0.0.1"
            TUNNEL_REMOTE="10.0.0.2"
            TUNNEL_PREFIX="30"
            log_info "Определена роль: HQ-RTR (альтернативная сеть)"
            ;;
        172.16.5.*)
            # Альтернативная конфигурация BR-RTR
            ROUTER_ROLE="BR-RTR"
            REMOTE_IP="172.16.4.2"
            TUNNEL_LOCAL="10.0.0.2"
            TUNNEL_REMOTE="10.0.0.1"
            TUNNEL_PREFIX="30"
            log_info "Определена роль: BR-RTR (альтернативная сеть)"
            ;;
        *)
            log_error "Не удалось определить роль маршрутизатора для IP: $EXTERNAL_IP"
            echo "Введите удаленный IP-адрес вручную:"
            read -r REMOTE_IP
            echo "Введите локальный туннельный IP-адрес (например, 10.10.0.1):"
            read -r TUNNEL_LOCAL
            echo "Введите удаленный туннельный IP-адрес (например, 10.10.0.2):"
            read -r TUNNEL_REMOTE
            TUNNEL_PREFIX="30"
            ROUTER_ROLE="CUSTOM"
            ;;
    esac
    
    echo "----------------------------------------"
    echo "Роль маршрутизатора: $ROUTER_ROLE"
    echo "Удаленный IP: $REMOTE_IP"
    echo "Локальный туннельный IP: $TUNNEL_LOCAL/$TUNNEL_PREFIX"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo "----------------------------------------"
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
    ip r | grep -E "(gre|10\.)"
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
        echo "network 10.10.0.0/30 area 0"
        
        # Определяем сети для анонса
        if [ "$ROUTER_ROLE" = "HQ-RTR" ]; then
            echo "network 192.168.100.0/27 area 0"
            echo "network 192.168.200.64/28 area 0"
        else
            echo "network 192.168.3.0/28 area 0"
        fi
        
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
    echo "Роль маршрутизатора: $ROUTER_ROLE"
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
echo "  1. Автоматическое определение IP-адресов"
echo "  2. Создание GRE-туннеля между офисами"
echo "  3. Настройку парольной аутентификации"
echo "  4. Проверку работоспособности туннеля"
echo ""

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Скрипт должен выполняться от имени root"
    exit 1
fi

# Шаг 1: Определение IP-адресов
detect_external_ip
if [ $? -ne 0 ]; then
    exit 1
fi

detect_remote_ip

# Шаг 2: Выбор пароля
select_password

# Подтверждение продолжения
echo ""
echo "Продолжить настройку туннеля? [Y/n]: "
read -r continue_choice

if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
    log_info "Настройка отменена пользователем"
    exit 0
fi

# Шаг 3: Загрузка модуля GRE
load_gre_module

# Шаг 4: Создание конфигурации
create_tunnel_config

# Шаг 5: Перезапуск сети
restart_network

# Шаг 6: Проверка
verify_tunnel

# Шаг 7: Проверка связности
echo "Выполнить тест связности туннеля? [Y/n]: "
read -r test_choice

if [[ ! "$test_choice" =~ ^[Nn]$ ]]; then
    test_tunnel_connectivity
fi

# Шаг 8: Настройка OSPF
setup_ospf

# Вывод итоговой информации
print_summary

log_success "Настройка GRE-туннеля завершена!"
echo ""
