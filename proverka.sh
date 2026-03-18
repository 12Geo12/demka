#!/bin/sh
#===============================================================================
#                    СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ НА ALTLINUX SERVER
#===============================================================================
# Данный скрипт выполняет настройку IP-туннеля (GRE) между маршрутизаторами
# офисов HQ и BR на базе AltLinux Server.
#===============================================================================

# Глобальные переменные
EXTERNAL_INTERFACE=""
EXTERNAL_IP=""
EXTERNAL_PREFIX=""
REMOTE_IP=""
TUNNEL_LOCAL=""
TUNNEL_REMOTE=""
TUNNEL_PREFIX=""
TUNNEL_PASSWORD=""
TUNNEL_IFACE="gre1"

#-------------------------------------------------------------------------------
# ФУНКЦИИ
#-------------------------------------------------------------------------------

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
    
    # Временный файл для хранения интерфейсов
    TMP_FILE="/tmp/tunnel_interfaces.tmp"
    > "$TMP_FILE"
    
    local_count=0
    
    # Получаем все интерфейсы с IPv4 адресами (кроме lo)
    ip -4 addr show | grep -v "^1:" | while read -r line; do
        # Ищем имя интерфейса
        iface=$(echo "$line" | grep -oE "^[0-9]+: [^:]+" | sed 's/^[0-9]*: //')
        if [ -n "$iface" ]; then
            current_iface="$iface"
        fi
        
        # Ищем IP-адрес
        ip_addr=$(echo "$line" | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+" | sed 's/inet //')
        if [ -n "$ip_addr" ] && [ -n "$current_iface" ]; then
            local_count=$((local_count + 1))
            echo "$local_count $current_iface $ip_addr" >> "$TMP_FILE"
            echo "  $local_count) Интерфейс: $current_iface"
            echo "     IP-адрес: $ip_addr"
            echo ""
        fi
    done
    
    if [ ! -s "$TMP_FILE" ]; then
        log_error "Не найдено интерфейсов с IPv4 адресами"
        rm -f "$TMP_FILE"
        return 1
    fi
    
    echo "----------------------------------------"
    return 0
}

# Выбор внешнего интерфейса
select_external_interface() {
    echo ""
    echo "Выберите номер интерфейса для туннеля:"
    printf "Введите номер: "
    read -r selection
    
    # Проверка ввода
    if [ -z "$selection" ]; then
        log_error "Не указан номер интерфейса"
        return 1
    fi
    
    # Получаем данные выбранного интерфейса
    selected_line=$(grep "^$selection " /tmp/tunnel_interfaces.tmp)
    
    if [ -z "$selected_line" ]; then
        log_error "Неверный выбор"
        rm -f /tmp/tunnel_interfaces.tmp
        return 1
    fi
    
    EXTERNAL_INTERFACE=$(echo "$selected_line" | awk '{print $2}')
    local ip_with_mask=$(echo "$selected_line" | awk '{print $3}')
    EXTERNAL_IP=$(echo "$ip_with_mask" | cut -d'/' -f1)
    EXTERNAL_PREFIX=$(echo "$ip_with_mask" | cut -d'/' -f2)
    
    rm -f /tmp/tunnel_interfaces.tmp
    
    echo ""
    echo "----------------------------------------"
    echo "Выбран интерфейс: $EXTERNAL_INTERFACE"
    echo "IP-адрес: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "----------------------------------------"
    
    return 0
}

# Запрос удаленного IP-адреса
get_remote_ip() {
    echo ""
    echo "========================================"
    echo "    НАСТРОЙКА УДАЛЕННОГО IP-АДРЕСА"
    echo "========================================"
    echo ""
    echo "Введите IP-адрес удаленного маршрутизатора."
    echo "Это внешний IP-адрес другого конца туннеля."
    echo ""
    printf "Удаленный IP-адрес (без маски): "
    read -r REMOTE_IP
    
    if [ -z "$REMOTE_IP" ]; then
        log_error "IP-адрес не указан"
        return 1
    fi
    
    # Простая проверка формата
    if ! echo "$REMOTE_IP" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
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
    
    printf "Локальный туннельный IP (например, 10.10.0.1): "
    read -r TUNNEL_LOCAL
    
    if [ -z "$TUNNEL_LOCAL" ]; then
        log_error "IP-адрес не указан"
        return 1
    fi
    
    printf "Маска подсети туннеля [30]: "
    read -r TUNNEL_PREFIX
    
    if [ -z "$TUNNEL_PREFIX" ]; then
        TUNNEL_PREFIX="30"
    fi
    
    printf "Удаленный туннельный IP (например, 10.10.0.2): "
    read -r TUNNEL_REMOTE
    
    if [ -z "$TUNNEL_REMOTE" ]; then
        log_error "IP-адрес не указан"
        return 1
    fi
    
    echo ""
    echo "----------------------------------------"
    echo "Локальный туннельный IP: $TUNNEL_LOCAL/$TUNNEL_PREFIX"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo "----------------------------------------"
    
    return 0
}

# Выбор пароля аутентификации
select_password() {
    echo ""
    echo "========================================"
    echo "    ВЫБОР ПАРОЛЯ АУТЕНТИФИКАЦИИ"
    echo "========================================"
    echo ""
    echo "Выберите опцию:"
    echo "  1) Пароль по умолчанию: P@ssw0rd"
    echo "  2) Ввести свой пароль"
    echo "  3) Сгенерировать случайный пароль"
    echo ""
    printf "Ваш выбор [1-3]: "
    read -r password_choice
    
    case "$password_choice" in
        1)
            TUNNEL_PASSWORD="P@ssw0rd"
            log_info "Выбран пароль по умолчанию"
            ;;
        2)
            printf "Введите пароль: "
            read -r TUNNEL_PASSWORD
            if [ -z "$TUNNEL_PASSWORD" ]; then
                log_error "Пароль пуст. Используется по умолчанию."
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
    echo "Пароль аутентификации: $TUNNEL_PASSWORD"
    echo "----------------------------------------"
    echo ""
}

# Загрузка модуля GRE
load_gre_module() {
    log_info "Загрузка модуля GRE..."
    
    if modprobe gre 2>/dev/null; then
        echo "Модуль GRE успешно загружен"
    else
        log_error "Не удалось загрузить модуль GRE"
        return 1
    fi
    
    # Добавляем в автозагрузку
    if [ -f /etc/modules ]; then
        if ! grep -q "^gre" /etc/modules; then
            echo "gre" >> /etc/modules
            echo "Модуль GRE добавлен в автозагрузку"
        fi
    fi
    
    echo ""
    echo "Проверка загруженных модулей:"
    lsmod | grep gre
    echo ""
}

# Создание конфигурации туннеля
create_tunnel_config() {
    log_info "Создание конфигурации туннеля..."
    
    TUNNEL_DIR="/etc/net/ifaces/$TUNNEL_IFACE"
    
    # Создание директории
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
    
    if systemctl restart network; then
        echo "Сетевая служба успешно перезапущена"
    else
        log_error "Ошибка при перезапуске сетевой службы"
        return 1
    fi
    
    sleep 2
}

# Проверка туннеля
verify_tunnel() {
    log_info "Проверка туннельного интерфейса..."
    
    echo ""
    echo "Состояние интерфейсов:"
    ip -br a 2>/dev/null | grep -E "(gre|$TUNNEL_IFACE)" || echo "Интерфейс не найден"
    echo ""
    
    echo "Детальная информация о туннеле:"
    ip a show "$TUNNEL_IFACE" 2>/dev/null || echo "Интерфейс $TUNNEL_IFACE не найден"
    echo ""
    
    echo "Маршруты:"
    ip r | grep -E "(gre|10\.)" || echo "Маршруты не найдены"
    echo ""
}

# Тест связности
test_tunnel_connectivity() {
    log_info "Проверка связности туннеля..."
    
    echo ""
    echo "Пинг удаленного туннельного адреса ($TUNNEL_REMOTE):"
    ping -c 4 "$TUNNEL_REMOTE"
    echo ""
}

# Настройка OSPF
setup_ospf() {
    echo ""
    printf "Настроить OSPF для динамической маршрутизации? [y/N]: "
    read -r ospf_choice
    
    case "$ospf_choice" in
        [Yy]|[Yy][Ee][Ss])
            log_info "Установка FRR..."
            
            apt-get update
            apt-get install -y frr
            
            # Включение OSPF
            if [ -f /etc/frr/daemons ]; then
                sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
            fi
            
            systemctl enable --now frr
            systemctl restart frr
            
            echo ""
            echo "FRR установлен и запущен"
            echo ""
            echo "Настройка OSPF через vtysh:"
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
            ;;
        *)
            log_info "Пропуск настройки OSPF"
            ;;
    esac
}

# Итоговая информация
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
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/options"
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/ipv4address"
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
get_all_interfaces || exit 1

# Шаг 2: Выбор внешнего интерфейса
select_external_interface || exit 1

# Шаг 3: Запрос удаленного IP
get_remote_ip || exit 1

# Шаг 4: Запрос туннельных IP
get_tunnel_ips || exit 1

# Шаг 5: Выбор пароля
select_password

# Подтверждение
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
printf "Продолжить настройку? [Y/n]: "
read -r confirm

case "$confirm" in
    [Nn]|[Nn][Oo])
        log_info "Настройка отменена"
        exit 0
        ;;
esac

# Шаг 6: Загрузка модуля GRE
load_gre_module

# Шаг 7: Создание конфигурации
create_tunnel_config

# Шаг 8: Перезапуск сети
restart_network

# Шаг 9: Проверка
verify_tunnel

# Шаг 10: Тест связности
echo ""
printf "Выполнить тест связности? [Y/n]: "
read -r test_choice

case "$test_choice" in
    [Nn]|[Nn][Oo])
        ;;
    *)
        test_tunnel_connectivity
        ;;
esac

# Шаг 11: Настройка OSPF
setup_ospf

# Итоговая информация
print_summary

log_success "Настройка GRE-туннеля завершена!"
echo ""
