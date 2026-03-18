#!/bin/sh
#===============================================================================
#           СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ И OSPF НА ALTLINUX SERVER
#===============================================================================
# Настройка туннеля GRE между маршрутизаторами HQ-R и BR-R
# с динамической маршрутизацией OSPF (FRR)
#===============================================================================

# Глобальные переменные
TUNNEL_IFACE="tun1"
TUNNEL_DIR="/etc/net/ifaces/$TUNNEL_IFACE"
ROLE=""
EXTERNAL_IF=""
TUNLOCAL=""
TUNREMOTE=""
TUNNEL_IP=""
TUNNEL_REMOTE=""
LOCAL_NETWORK=""

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

# Получение списка интерфейсов
get_interfaces() {
    echo ""
    echo "========================================"
    echo "    ДОСТУПНЫЕ СЕТЕВЫЕ ИНТЕРФЕЙСЫ"
    echo "========================================"
    echo ""
    
    TMP_FILE="/tmp/ifaces_list.tmp"
    > "$TMP_FILE"
    count=0
    
    ip -4 addr show | while read -r line; do
        iface=$(echo "$line" | grep -oE "^[0-9]+: [^:]+" | sed 's/^[0-9]*: //')
        if [ -n "$iface" ]; then
            current_iface="$iface"
        fi
        
        ip_addr=$(echo "$line" | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+" | sed 's/inet //')
        if [ -n "$ip_addr" ] && [ -n "$current_iface" ] && [ "$current_iface" != "lo" ]; then
            count=$((count + 1))
            echo "$count $current_iface $ip_addr" >> "$TMP_FILE"
            echo "  $count) Интерфейс: $current_iface"
            echo "     IP-адрес: $ip_addr"
            echo ""
        fi
    done
    
    echo "----------------------------------------"
}

# Выбор интерфейса
select_interface() {
    echo ""
    printf "Выберите номер интерфейса для туннеля: "
    read -r selection
    
    if [ -z "$selection" ]; then
        log_error "Не указан номер"
        return 1
    fi
    
    selected_line=$(grep "^$selection " /tmp/ifaces_list.tmp 2>/dev/null)
    
    if [ -z "$selected_line" ]; then
        log_error "Неверный выбор"
        return 1
    fi
    
    EXTERNAL_IF=$(echo "$selected_line" | awk '{print $2}')
    local ip_with_mask=$(echo "$selected_line" | awk '{print $3}')
    TUNLOCAL=$(echo "$ip_with_mask" | cut -d'/' -f1)
    
    rm -f /tmp/ifaces_list.tmp
    
    echo ""
    echo "Выбран интерфейс: $EXTERNAL_IF"
    echo "IP-адрес: $TUNLOCAL"
    echo "----------------------------------------"
    
    return 0
}

# Выбор роли маршрутизатора
select_role() {
    echo ""
    echo "========================================"
    echo "    ВЫБОР РОЛИ МАРШРУТИЗАТОРА"
    echo "========================================"
    echo ""
    echo "  1) HQ-R (главный офис)"
    echo "  2) BR-R (филиал)"
    echo ""
    printf "Ваш выбор [1-2]: "
    read -r role_choice
    
    case "$role_choice" in
        1)
            ROLE="HQ-R"
            TUNNEL_IP="172.16.0.1/30"
            TUNNEL_REMOTE="172.16.0.2"
            ;;
        2)
            ROLE="BR-R"
            TUNNEL_IP="172.16.0.2/30"
            TUNNEL_REMOTE="172.16.0.1"
            ;;
        *)
            log_error "Неверный выбор"
            return 1
            ;;
    esac
    
    echo ""
    echo "Роль: $ROLE"
    echo "Туннельный IP: $TUNNEL_IP"
    echo "----------------------------------------"
    
    return 0
}

# Ввод удаленного IP
get_remote_ip() {
    echo ""
    echo "========================================"
    echo "    НАСТРОЙКА УДАЛЕННОГО IP"
    echo "========================================"
    echo ""
    echo "Введите внешний IP-адрес удаленного маршрутизатора."
    echo ""
    printf "Удаленный IP-адрес: "
    read -r TUNREMOTE
    
    if [ -z "$TUNREMOTE" ]; then
        log_error "IP не указан"
        return 1
    fi
    
    echo ""
    echo "Удаленный IP: $TUNREMOTE"
    echo "----------------------------------------"
    
    return 0
}

# Ввод локальной сети
get_local_network() {
    echo ""
    echo "========================================"
    echo "    НАСТРОЙКА ЛОКАЛЬНОЙ СЕТИ"
    echo "========================================"
    echo ""
    echo "Введите сеть для анонса через OSPF."
    echo "HQ-R: обычно 192.168.0.0/25"
    echo "BR-R: обычно 192.168.0.128/27"
    echo ""
    printf "Локальная сеть (например, 192.168.0.0/25): "
    read -r LOCAL_NETWORK
    
    if [ -z "$LOCAL_NETWORK" ]; then
        if [ "$ROLE" = "HQ-R" ]; then
            LOCAL_NETWORK="192.168.0.0/25"
        else
            LOCAL_NETWORK="192.168.0.128/27"
        fi
        echo "Используется сеть по умолчанию: $LOCAL_NETWORK"
    fi
    
    echo ""
    echo "Локальная сеть: $LOCAL_NETWORK"
    echo "----------------------------------------"
    
    return 0
}

# Выбор пароля OSPF
select_password() {
    echo ""
    echo "========================================"
    echo "    ПАРОЛЬ АУТЕНТИФИКАЦИИ OSPF"
    echo "========================================"
    echo ""
    echo "  1) Пароль по умолчанию: P@ssw0rd"
    echo "  2) Ввести свой пароль"
    echo "  3) Без пароля"
    echo ""
    printf "Ваш выбор [1-3]: "
    read -r pass_choice
    
    case "$pass_choice" in
        1)
            OSPF_PASSWORD="P@ssw0rd"
            USE_AUTH="yes"
            ;;
        2)
            printf "Введите пароль: "
            read -r OSPF_PASSWORD
            if [ -z "$OSPF_PASSWORD" ]; then
                OSPF_PASSWORD="P@ssw0rd"
            fi
            USE_AUTH="yes"
            ;;
        3)
            OSPF_PASSWORD=""
            USE_AUTH="no"
            ;;
        *)
            OSPF_PASSWORD="P@ssw0rd"
            USE_AUTH="yes"
            ;;
    esac
    
    echo ""
    if [ "$USE_AUTH" = "yes" ]; then
        echo "Пароль OSPF: $OSPF_PASSWORD"
    else
        echo "Аутентификация OSPF отключена"
    fi
    echo "----------------------------------------"
}

# Создание туннеля
create_tunnel() {
    log_info "Создание конфигурации туннеля..."
    
    # Создание директории
    mkdir -p "$TUNNEL_DIR"
    
    # Файл ipv4address
    echo "$TUNNEL_IP" > "$TUNNEL_DIR/ipv4address"
    echo "Создан: $TUNNEL_DIR/ipv4address"
    cat "$TUNNEL_DIR/ipv4address"
    echo ""
    
    # Файл options
    cat > "$TUNNEL_DIR/options" << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUNLOCAL
TUNREMOTE=$TUNREMOTE
TUNOPTIONS='ttl 64'
HOST=$EXTERNAL_IF
EOF
    
    echo "Создан: $TUNNEL_DIR/options"
    cat "$TUNNEL_DIR/options"
    echo ""
    
    log_success "Конфигурация туннеля создана"
}

# Перезапуск сети
restart_network() {
    log_info "Перезапуск сетевой службы..."
    
    systemctl restart network
    
    if [ $? -eq 0 ]; then
        echo "Сеть успешно перезапущена"
    else
        log_error "Ошибка перезапуска сети"
        return 1
    fi
    
    sleep 2
}

# Проверка туннеля
verify_tunnel() {
    log_info "Проверка туннеля..."
    
    echo ""
    echo "Интерфейсы:"
    ip -br a | grep -E "(tun|$TUNNEL_IFACE)"
    echo ""
    
    echo "Туннельный интерфейс $TUNNEL_IFACE:"
    ip a show "$TUNNEL_IFACE" 2>/dev/null || echo "Интерфейс не найден"
    echo ""
}

# Тест связности
test_connectivity() {
    echo ""
    printf "Проверить связность туннеля? [Y/n]: "
    read -r test_choice
    
    case "$test_choice" in
        [Nn])
            return
            ;;
    esac
    
    echo ""
    echo "Пинг $TUNNEL_REMOTE:"
    ping -c 4 "$TUNNEL_REMOTE"
    echo ""
}

# Установка FRR
install_frr() {
    log_info "Установка FRR..."
    
    apt-get update
    apt-get install -y frr
    
    systemctl enable --now frr
    
    echo ""
    log_success "FRR установлен"
}

# Настройка FRR
configure_frr() {
    log_info "Настройка OSPF..."
    
    # Включаем OSPF в daemons
    if [ -f /etc/frr/daemons ]; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        echo "OSPF включен в /etc/frr/daemons"
    fi
    
    # Перезапускаем FRR
    systemctl restart frr
    
    # Настраиваем OSPF через vtysh
    echo ""
    echo "Настройка OSPF через vtysh..."
    
    if [ "$USE_AUTH" = "yes" ]; then
        vtysh -c "conf t" \
              -c "router ospf" \
              -c "passive-interface default" \
              -c "network $LOCAL_NETWORK area 0" \
              -c "network 172.16.0.0/30 area 0" \
              -c "area 0 authentication" \
              -c "exit" \
              -c "int $TUNNEL_IFACE" \
              -c "ip ospf authentication-key $OSPF_PASSWORD" \
              -c "ip ospf authentication" \
              -c "ip ospf network point-to-point" \
              -c "no ip ospf passive" \
              -c "do wr"
    else
        vtysh -c "conf t" \
              -c "router ospf" \
              -c "passive-interface default" \
              -c "network $LOCAL_NETWORK area 0" \
              -c "network 172.16.0.0/30 area 0" \
              -c "exit" \
              -c "int $TUNNEL_IFACE" \
              -c "ip ospf network point-to-point" \
              -c "no ip ospf passive" \
              -c "do wr"
    fi
    
    echo ""
    log_success "OSPF настроен"
}

# Проверка OSPF
verify_ospf() {
    echo ""
    echo "========================================"
    echo "    ПРОВЕРКА OSPF"
    echo "========================================"
    echo ""
    
    echo "Соседи OSPF:"
    vtysh -c "show ip ospf neighbor"
    echo ""
    
    echo "Маршруты OSPF:"
    vtysh -c "show ip route ospf"
    echo ""
}

# Итоговая информация
print_summary() {
    echo ""
    echo "========================================"
    echo "         ИТОГОВАЯ ИНФОРМАЦИЯ"
    echo "========================================"
    echo ""
    echo "Роль: $ROLE"
    echo ""
    echo "Внешний интерфейс: $EXTERNAL_IF"
    echo "Локальный IP: $TUNLOCAL"
    echo "Удаленный IP: $TUNREMOTE"
    echo ""
    echo "Туннельный интерфейс: $TUNNEL_IFACE"
    echo "Туннельный IP: $TUNNEL_IP"
    echo "Удаленный туннельный IP: $TUNNEL_REMOTE"
    echo ""
    echo "Локальная сеть: $LOCAL_NETWORK"
    if [ "$USE_AUTH" = "yes" ]; then
        echo "Пароль OSPF: $OSPF_PASSWORD"
    fi
    echo ""
    echo "Конфигурация:"
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/options"
    echo "  /etc/net/ifaces/$TUNNEL_IFACE/ipv4address"
    echo ""
    echo "Проверка:"
    echo "  ip a show $TUNNEL_IFACE"
    echo "  ping $TUNNEL_REMOTE"
    echo "  vtysh -c 'show ip ospf neighbor'"
    echo ""
    echo "========================================"
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ЛОГИКА
#-------------------------------------------------------------------------------

clear

echo "==============================================================================="
echo "      СКРИПТ НАСТРОЙКИ GRE-ТУННЕЛЯ И OSPF НА ALTLINUX SERVER"
echo "==============================================================================="
echo ""
echo "Выполняется:"
echo "  1. Создание GRE-туннеля (tun1)"
echo "  2. Настройка IP-адресов туннеля"
echo "  3. Установка и настройка FRR (OSPF)"
echo "  4. Настройка динамической маршрутизации"
echo ""

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите от root"
    exit 1
fi

# Выбор интерфейса
get_interfaces
select_interface || exit 1

# Выбор роли
select_role || exit 1

# Удаленный IP
get_remote_ip || exit 1

# Локальная сеть
get_local_network || exit 1

# Пароль
select_password

# Подтверждение
echo ""
echo "========================================"
echo "    ПОДТВЕРЖДЕНИЕ ПАРАМЕТРОВ"
echo "========================================"
echo ""
echo "Роль: $ROLE"
echo "Внешний интерфейс: $EXTERNAL_IF ($TUNLOCAL)"
echo "Удаленный IP: $TUNREMOTE"
echo "Туннельный IP: $TUNNEL_IP"
echo "Локальная сеть: $LOCAL_NETWORK"
echo ""
printf "Продолжить? [Y/n]: "
read -r confirm

case "$confirm" in
    [Nn])
        log_info "Отменено"
        exit 0
        ;;
esac

# Создание туннеля
create_tunnel

# Перезапуск сети
restart_network

# Проверка туннеля
verify_tunnel

# Тест связности
test_connectivity

# Установка FRR
printf "Установить и настроить FRR (OSPF)? [Y/n]: "
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
verify_ospf

# Итог
print_summary

log_success "Настройка завершена!"
echo ""

