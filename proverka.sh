#!/bin/sh
#===============================================================================
#           ПОЛНОЦЕННАЯ НАСТРОЙКА СЕТИ GRE+OSPF НА ALTLINUX SERVER
#===============================================================================
# Автоматическое определение IP-адресов и настройка:
#   - GRE-туннель между офисами
#   - OSPF маршрутизация через FRR
#   - IP-forwarding
#===============================================================================

# Глобальные переменные
TUNNEL_IFACE="gre1"
TUNNEL_DIR="/etc/net/ifaces/$TUNNEL_IFACE"
ROLE=""
EXTERNAL_IF=""
EXTERNAL_IP=""
EXTERNAL_PREFIX=""
REMOTE_EXTERNAL_IP=""
TUNNEL_IP=""
TUNNEL_REMOTE=""
LOCAL_NETWORKS=""
OSPF_PASSWORD=""
OSPF_ROUTER_ID=""

#-------------------------------------------------------------------------------
# ФУНКЦИИ
#-------------------------------------------------------------------------------

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

separator() {
    echo "========================================"
}

# Автоматическое определение IP и роли маршрутизатора
auto_detect_configuration() {
    separator
    echo "    АВТООПРЕДЕЛЕНИЕ КОНФИГУРАЦИИ"
    separator
    echo ""
    
    # Получаем все интерфейсы с IP из сетей 172.16.x.x (внешние)
    echo "Поиск внешних интерфейсов..."
    echo ""
    
    TMP_FILE="/tmp/ext_ifaces.tmp"
    > "$TMP_FILE"
    
    ip -4 addr show | grep -E "inet 172\." | while read -r line; do
        ip_with_mask=$(echo "$line" | awk '{print $2}')
        iface=$(echo "$line" | awk '{print $NF}')
        ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
        prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
        
        echo "$iface $ip $prefix $ip_with_mask" >> "$TMP_FILE"
        echo "  Найден: $iface - $ip/$prefix"
    done
    
    echo ""
    
    if [ ! -s "$TMP_FILE" ]; then
        log_error "Внешние интерфейсы не найдены (нет IP из 172.16.x.x)"
        rm -f "$TMP_FILE"
        return 1
    fi
    
    # Берем первый внешний интерфейс
    first_line=$(head -1 "$TMP_FILE")
    EXTERNAL_IF=$(echo "$first_line" | awk '{print $1}')
    EXTERNAL_IP=$(echo "$first_line" | awk '{print $2}')
    EXTERNAL_PREFIX=$(echo "$first_line" | awk '{print $3}')
    
    echo "Автоматически определено:"
    echo "  Внешний интерфейс: $EXTERNAL_IF"
    echo "  Внешний IP: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo ""
    
    # Определяем роль по IP
    case "$EXTERNAL_IP" in
        172.16.1.*)
            ROLE="HQ-RTR"
            REMOTE_EXTERNAL_IP="172.16.2.2"
            TUNNEL_IP="10.10.0.1/30"
            TUNNEL_REMOTE="10.10.0.2"
            OSPF_ROUTER_ID="1.1.1.1"
            LOCAL_NETWORKS="192.168.100.0/27 192.168.200.64/28 192.168.99.88/29"
            ;;
        172.16.2.*)
            ROLE="BR-RTR"
            REMOTE_EXTERNAL_IP="172.16.1.2"
            TUNNEL_IP="10.10.0.2/30"
            TUNNEL_REMOTE="10.10.0.1"
            OSPF_ROUTER_ID="2.2.2.2"
            LOCAL_NETWORKS="192.168.3.0/28"
            ;;
        172.16.4.*)
            ROLE="HQ-RTR"
            REMOTE_EXTERNAL_IP="172.16.5.2"
            TUNNEL_IP="10.0.0.1/30"
            TUNNEL_REMOTE="10.0.0.2"
            OSPF_ROUTER_ID="1.1.1.1"
            LOCAL_NETWORKS="192.168.100.0/26 192.168.200.0/28"
            ;;
        172.16.5.*)
            ROLE="BR-RTR"
            REMOTE_EXTERNAL_IP="172.16.4.2"
            TUNNEL_IP="10.0.0.2/30"
            TUNNEL_REMOTE="10.0.0.1"
            OSPF_ROUTER_ID="2.2.2.2"
            LOCAL_NETWORKS="192.168.50.0/27"
            ;;
        *)
            log_info "Неизвестная сеть, требуется ручной ввод"
            rm -f "$TMP_FILE"
            manual_configuration
            return $?
            ;;
    esac
    
    rm -f "$TMP_FILE"
    
    echo "Определена роль: $ROLE"
    echo "Удаленный IP: $REMOTE_EXTERNAL_IP"
    echo "Туннельный IP: $TUNNEL_IP"
    echo ""
    
    # Подтверждение от пользователя
    separator
    echo "    ПОДТВЕРЖДЕНИЕ"
    separator
    echo ""
    echo "Роль: $ROLE"
    echo "Внешний интерфейс: $EXTERNAL_IF"
    echo "Локальный IP: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "Удаленный IP: $REMOTE_EXTERNAL_IP"
    echo "Туннельный IP: $TUNNEL_IP"
    echo "Локальные сети OSPF: $LOCAL_NETWORKS"
    echo ""
    printf "Конфигурация верна? [Y/n]: "
    read -r confirm
    
    case "$confirm" in
        [Nn])
            manual_configuration
            return $?
            ;;
    esac
    
    echo ""
    return 0
}

# Ручная настройка при неизвестной сети
manual_configuration() {
    echo ""
    separator
    echo "    РУЧНАЯ НАСТРОЙКА"
    separator
    echo ""
    
    # Выбор роли
    echo "Выберите роль:"
    echo "  1) HQ-RTR (главный офис)"
    echo "  2) BR-RTR (филиал)"
    printf "Ваш выбор [1-2]: "
    read -r role_choice
    
    case "$role_choice" in
        1) ROLE="HQ-RTR" ;;
        2) ROLE="BR-RTR" ;;
        *) log_error "Неверный выбор"; return 1 ;;
    esac
    
    # Удаленный IP
    printf "Удаленный внешний IP: "
    read -r REMOTE_EXTERNAL_IP
    if [ -z "$REMOTE_EXTERNAL_IP" ]; then
        log_error "IP не указан"
        return 1
    fi
    
    # Туннельные IP
    if [ "$ROLE" = "HQ-RTR" ]; then
        printf "Туннельный IP [10.10.0.1/30]: "
        read -r TUNNEL_IP
        [ -z "$TUNNEL_IP" ] && TUNNEL_IP="10.10.0.1/30"
        TUNNEL_REMOTE="10.10.0.2"
        OSPF_ROUTER_ID="1.1.1.1"
    else
        printf "Туннельный IP [10.10.0.2/30]: "
        read -r TUNNEL_IP
        [ -z "$TUNNEL_IP" ] && TUNNEL_IP="10.10.0.2/30"
        TUNNEL_REMOTE="10.10.0.1"
        OSPF_ROUTER_ID="2.2.2.2"
    fi
    
    # Локальные сети
    printf "Локальные сети OSPF (через пробел): "
    read -r LOCAL_NETWORKS
    if [ -z "$LOCAL_NETWORKS" ]; then
        if [ "$ROLE" = "HQ-RTR" ]; then
            LOCAL_NETWORKS="192.168.100.0/24"
        else
            LOCAL_NETWORKS="192.168.50.0/24"
        fi
    fi
    
    echo ""
    return 0
}

# Выбор пароля аутентификации OSPF
select_password() {
    separator
    echo "    АУТЕНТИФИКАЦИЯ OSPF"
    separator
    echo ""
    echo "Выберите:"
    echo "  1) Пароль по умолчанию: P@ssw0rd"
    echo "  2) Свой пароль"
    echo "  3) Без аутентификации"
    printf "Ваш выбор [1-3]: "
    read -r pass_choice
    
    case "$pass_choice" in
        1)
            OSPF_PASSWORD="P@ssw0rd"
            echo "Выбран: P@ssw0rd"
            ;;
        2)
            printf "Пароль: "
            read -r OSPF_PASSWORD
            [ -z "$OSPF_PASSWORD" ] && OSPF_PASSWORD="P@ssw0rd"
            ;;
        3)
            OSPF_PASSWORD=""
            echo "Без аутентификации"
            ;;
        *)
            OSPF_PASSWORD="P@ssw0rd"
            ;;
    esac
    echo ""
}

# Включение IP-forwarding
enable_ip_forward() {
    log_info "Включение IP-forwarding..."
    
    if grep -q "^net.ipv4.ip_forward" /etc/net/sysctl.conf 2>/dev/null; then
        sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/net/sysctl.conf
    fi
    
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    echo "IP-forwarding включен"
    echo ""
}

# Загрузка модуля GRE
load_gre_module() {
    log_info "Загрузка модуля GRE..."
    
    modprobe gre
    
    if [ $? -ne 0 ]; then
        log_error "Не удалось загрузить модуль GRE"
        return 1
    fi
    
    # Добавляем в автозагрузку
    if [ -f /etc/modules ]; then
        if ! grep -q "^gre" /etc/modules; then
            echo "gre" >> /etc/modules
        fi
    fi
    
    echo "Модуль GRE загружен"
    echo ""
}

# Создание GRE-туннеля
create_tunnel() {
    log_info "Создание GRE-туннеля..."
    
    # Создаем директорию
    mkdir -p "$TUNNEL_DIR"
    
    # Файл ipv4address
    echo "$TUNNEL_IP" > "$TUNNEL_DIR/ipv4address"
    echo "Файл: $TUNNEL_DIR/ipv4address"
    cat "$TUNNEL_DIR/ipv4address"
    
    # Файл options
    cat > "$TUNNEL_DIR/options" << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$EXTERNAL_IP
TUNREMOTE=$REMOTE_EXTERNAL_IP
TUNOPTIONS='ttl 64'
EOF
    
    echo "Файл: $TUNNEL_DIR/options"
    cat "$TUNNEL_DIR/options"
    echo ""
    
    log_success "Туннель создан"
}

# Перезапуск сети
restart_network() {
    log_info "Перезапуск сети..."
    
    systemctl restart network
    
    if [ $? -ne 0 ]; then
        log_error "Ошибка перезапуска сети"
        return 1
    fi
    
    echo "Сеть перезапущена"
    sleep 2
    echo ""
}

# Проверка туннеля
verify_tunnel() {
    separator
    echo "    ПРОВЕРКА ТУННЕЛЯ"
    separator
    echo ""
    
    echo "Интерфейс $TUNNEL_IFACE:"
    ip a show "$TUNNEL_IFACE" 2>/dev/null || echo "Интерфейс не найден"
    echo ""
    
    echo "Маршруты:"
    ip r | grep -E "($TUNNEL_IFACE|10\.)" || echo "Маршруты не найдены"
    echo ""
}

# Тест связности
test_connectivity() {
    printf "Проверить связность туннеля? [Y/n]: "
    read -r test_choice
    
    case "$test_choice" in
        [Nn]) return ;;
    esac
    
    echo ""
    echo "Пинг $TUNNEL_REMOTE:"
    ping -c 4 "$TUNNEL_REMOTE"
    echo ""
}

# Установка FRR
install_frr() {
    log_info "Установка FRR..."
    
    apt-get update -qq
    apt-get install -y -qq frr
    
    echo "FRR установлен"
    echo ""
}

# Настройка FRR
configure_frr() {
    log_info "Настройка OSPF..."
    
    # Включаем OSPF в daemons
    if [ -f /etc/frr/daemons ]; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        echo "OSPF включен в /etc/frr/daemons"
    fi
    
    # Запускаем FRR
    systemctl enable --now frr
    systemctl restart frr
    
    sleep 1
    
    # Настраиваем OSPF через vtysh
    echo ""
    echo "Настройка OSPF через vtysh..."
    
    # Базовая настройка OSPF
    vtysh -c "conf t" -c "router ospf" -c "ospf router-id $OSPF_ROUTER_ID"
    vtysh -c "conf t" -c "router ospf" -c "passive-interface default"
    
    # Добавляем сети
    for net in $LOCAL_NETWORKS; do
        vtysh -c "conf t" -c "router ospf" -c "network $net area 0"
        echo "Добавлена сеть: $net"
    done
    
    # Туннельная сеть
    TUNNEL_NET=$(echo "$TUNNEL_IP" | cut -d'/' -f1 | awk -F. '{print $1"."$2"."$3".0/30"}')
    vtysh -c "conf t" -c "router ospf" -c "network $TUNNEL_NET area 0"
    echo "Добавлена сеть: $TUNNEL_NET"
    
    # Аутентификация
    if [ -n "$OSPF_PASSWORD" ]; then
        vtysh -c "conf t" -c "router ospf" -c "area 0 authentication"
        vtysh -c "conf t" -c "int $TUNNEL_IFACE" -c "ip ospf authentication-key $OSPF_PASSWORD"
        vtysh -c "conf t" -c "int $TUNNEL_IFACE" -c "ip ospf authentication"
        echo "Аутентификация настроена"
    fi
    
    # Интерфейс туннеля
    vtysh -c "conf t" -c "int $TUNNEL_IFACE" -c "ip ospf network point-to-point"
    vtysh -c "conf t" -c "int $TUNNEL_IFACE" -c "no ip ospf passive"
    
    # Сохраняем
    vtysh -c "do wr"
    
    echo ""
    log_success "OSPF настроен"
}

# Проверка OSPF
verify_ospf() {
    separator
    echo "    ПРОВЕРКА OSPF"
    separator
    echo ""
    
    echo "Соседи OSPF:"
    vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Нет соседей"
    echo ""
    
    echo "Маршруты OSPF:"
    vtysh -c "show ip route ospf" 2>/dev/null || echo "Нет маршрутов"
    echo ""
}

# Итоговая информация
print_summary() {
    echo ""
    separator
    echo "         ИТОГОВАЯ ИНФОРМАЦИЯ"
    separator
    echo ""
    echo "Роль: $ROLE"
    echo "Router-ID: $OSPF_ROUTER_ID"
    echo ""
    echo "Внешний интерфейс: $EXTERNAL_IF"
    echo "Локальный IP: $EXTERNAL_IP/$EXTERNAL_PREFIX"
    echo "Удаленный IP: $REMOTE_EXTERNAL_IP"
    echo ""
    echo "Туннель: $TUNNEL_IFACE"
    echo "Туннельный IP: $TUNNEL_IP"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo ""
    echo "Локальные сети: $LOCAL_NETWORKS"
    if [ -n "$OSPF_PASSWORD" ]; then
        echo "Пароль OSPF: $OSPF_PASSWORD"
    else
        echo "Аутентификация: отключена"
    fi
    echo ""
    echo "Файлы:"
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/options"
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/ipv4address"
    echo "  /etc/frr/daemons"
    echo ""
    echo "Команды проверки:"
    echo "  ip a show $TUNNEL_IFACE"
    echo "  ping $TUNNEL_REMOTE"
    echo "  vtysh -c 'show ip ospf neighbor'"
    echo "  vtysh -c 'show ip route ospf'"
    echo ""
    separator
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ЛОГИКА
#-------------------------------------------------------------------------------

clear

echo "==============================================================================="
echo "     ПОЛНОЦЕННАЯ НАСТРОЙКА СЕТИ GRE+OSPF НА ALTLINUX SERVER"
echo "==============================================================================="
echo ""
echo "Скрипт автоматически:"
echo "  1. Определит роль маршрутизатора по IP-адресу"
echo "  2. Найдет внешний и удаленный IP"
echo "  3. Создаст GRE-туннель"
echo "  4. Настроит OSPF маршрутизацию"
echo ""

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите от root"
    exit 1
fi

# Автоопределение
auto_detect_configuration || exit 1

# Пароль
select_password

# Финальное подтверждение
separator
echo "    ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ"
separator
echo ""
echo "Будет выполнено:"
echo "  - Включение IP-forwarding"
echo "  - Загрузка модуля GRE"
echo "  - Создание туннеля $TUNNEL_IFACE"
echo "  - Установка FRR"
echo "  - Настройка OSPF"
echo ""
printf "Продолжить? [Y/n]: "
read -r confirm

case "$confirm" in
    [Nn])
        log_info "Отменено"
        exit 0
        ;;
esac

# Выполнение
enable_ip_forward
load_gre_module
create_tunnel
restart_network
verify_tunnel
test_connectivity

# FRR
printf "Настроить OSPF (FRR)? [Y/n]: "
read -r frr_choice

case "$frr_choice" in
    [Nn])
        print_summary
        log_success "Туннель настроен. OSPF пропущен."
        exit 0
        ;;
esac

install_frr
configure_frr

# Ждем установления соседства
echo "Ожидание установления соседства OSPF (10 сек)..."
sleep 10

verify_ospf
print_summary

log_success "Настройка завершена!"
echo ""
