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
OSPF_PASSWORD=""
USE_AUTH=""

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

# Автоматическое определение IP и выбор интерфейса
detect_and_select_interface() {
    echo ""
    echo "========================================"
    echo "    АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ"
    echo "========================================"
    echo ""
    
    TMP_FILE="/tmp/ifaces_list.tmp"
    > "$TMP_FILE"
    count=0
    
    # Получаем все интерфейсы с IPv4
    ip -4 addr show | while read -r line; do
        iface=$(echo "$line" | grep -oE "^[0-9]+: [^:]+" | sed 's/^[0-9]*: //')
        if [ -n "$iface" ]; then
            current_iface="$iface"
        fi
        
        ip_addr=$(echo "$line" | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+" | sed 's/inet //')
        if [ -n "$ip_addr" ] && [ -n "$current_iface" ] && [ "$current_iface" != "lo" ]; then
            count=$((count + 1))
            echo "$count $current_iface $ip_addr" >> "$TMP_FILE"
        fi
    done
    
    # Показываем найденные интерфейсы
    echo "Найденные интерфейсы:"
    echo ""
    while IFS= read -r line; do
        num=$(echo "$line" | awk '{print $1}')
        iface=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        echo "  $num) $iface - $ip"
    done < "$TMP_FILE"
    echo ""
    
    # Автоматический выбор первого не-VLAN интерфейса с внешним IP
    auto_line=$(head -1 "$TMP_FILE")
    auto_iface=$(echo "$auto_line" | awk '{print $2}')
    auto_ip=$(echo "$auto_line" | awk '{print $3}' | cut -d'/' -f1)
    
    echo "Автоматически определено:"
    echo "  Интерфейс: $auto_iface"
    echo "  IP-адрес: $auto_ip"
    echo ""
    echo "----------------------------------------"
    printf "Это верно? [Y/n]: "
    read -r confirm
    
    case "$confirm" in
        [Nn])
            echo ""
            printf "Выберите номер интерфейса из списка: "
            read -r selection
            
            selected_line=$(grep "^$selection " "$TMP_FILE" 2>/dev/null)
            if [ -z "$selected_line" ]; then
                log_error "Неверный выбор"
                rm -f "$TMP_FILE"
                return 1
            fi
            
            EXTERNAL_IF=$(echo "$selected_line" | awk '{print $2}')
            TUNLOCAL=$(echo "$selected_line" | awk '{print $3}' | cut -d'/' -f1)
            ;;
        *)
            EXTERNAL_IF="$auto_iface"
            TUNLOCAL="$auto_ip"
            ;;
    esac
    
    rm -f "$TMP_FILE"
    
    echo ""
    echo "Выбран интерфейс: $EXTERNAL_IF"
    echo "IP-адрес: $TUNLOCAL"
    echo "----------------------------------------"
    
    return 0
}

# Ввод удаленного IP
get_remote_ip() {
    echo ""
    echo "========================================"
    echo "    УДАЛЕННЫЙ IP-АДРЕС"
    echo "========================================"
    echo ""
    printf "Введите IP-адрес удаленного маршрутизатора: "
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

# Выбор роли маршрутизатора
select_role() {
    echo ""
    echo "========================================"
    echo "    РОЛЬ МАРШРУТИЗАТОРА"
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

# Ввод локальной сети
get_local_network() {
    echo ""
    echo "========================================"
    echo "    ЛОКАЛЬНАЯ СЕТЬ ДЛЯ OSPF"
    echo "========================================"
    echo ""
    echo "HQ-R: обычно 192.168.0.0/25"
    echo "BR-R: обычно 192.168.0.128/27"
    echo ""
    printf "Локальная сеть: "
    read -r LOCAL_NETWORK
    
    if [ -z "$LOCAL_NETWORK" ]; then
        if [ "$ROLE" = "HQ-R" ]; then
            LOCAL_NETWORK="192.168.0.0/25"
        else
            LOCAL_NETWORK="192.168.0.128/27"
        fi
        echo "Используется: $LOCAL_NETWORK"
    fi
    
    echo ""
    echo "Локальная сеть: $LOCAL_NETWORK"
    echo "----------------------------------------"
    
    return 0
}

# Выбор пароля аутентификатора
select_password() {
    echo ""
    echo "========================================"
    echo "    ПАРОЛЬ АУТЕНТИФИКАТОРА OSPF"
    echo "========================================"
    echo ""
    echo "  1) По умолчанию: P@ssw0rd"
    echo "  2) Ввести свой пароль"
    echo "  3) Без аутентификации"
    echo ""
    printf "Ваш выбор [1-3]: "
    read -r pass_choice
    
    case "$pass_choice" in
        1)
            OSPF_PASSWORD="P@ssw0rd"
            USE_AUTH="yes"
            log_info "Выбран пароль по умолчанию"
            ;;
        2)
            printf "Введите пароль: "
            read -r OSPF_PASSWORD
            if [ -z "$OSPF_PASSWORD" ]; then
                OSPF_PASSWORD="P@ssw0rd"
                log_info "Пароль пуст, используется по умолчанию"
            fi
            USE_AUTH="yes"
            log_info "Установлен пользовательский пароль"
            ;;
        3)
            OSPF_PASSWORD=""
            USE_AUTH="no"
            log_info "Аутентификация отключена"
            ;;
        *)
            OSPF_PASSWORD="P@ssw0rd"
            USE_AUTH="yes"
            log_info "Неверный выбор, используется по умолчанию"
            ;;
    esac
    
    echo ""
    if [ "$USE_AUTH" = "yes" ]; then
        echo "Пароль: $OSPF_PASSWORD"
    else
        echo "Аутентификация: отключена"
    fi
    echo "----------------------------------------"
}

# Создание туннеля
create_tunnel() {
    log_info "Создание туннеля..."
    
    mkdir -p "$TUNNEL_DIR"
    
    echo "$TUNNEL_IP" > "$TUNNEL_DIR/ipv4address"
    echo "Файл: $TUNNEL_DIR/ipv4address"
    cat "$TUNNEL_DIR/ipv4address"
    echo ""
    
    cat > "$TUNNEL_DIR/options" << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUNLOCAL
TUNREMOTE=$TUNREMOTE
TUNOPTIONS='ttl 64'
HOST=$EXTERNAL_IF
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
    
    if [ $? -eq 0 ]; then
        echo "Сеть перезапущена"
    else
        log_error "Ошибка перезапуска"
        return 1
    fi
    
    sleep 2
}

# Проверка туннеля
verify_tunnel() {
    log_info "Проверка туннеля..."
    
    echo ""
    echo "Интерфейсы:"
    ip -br a | grep -E "tun"
    echo ""
    
    echo "Туннель $TUNNEL_IFACE:"
    ip a show "$TUNNEL_IFACE" 2>/dev/null || echo "Не найден"
    echo ""
}

# Тест связности
test_connectivity() {
    echo ""
    printf "Проверить связность? [Y/n]: "
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
    
    log_success "FRR установлен"
}

# Настройка FRR
configure_frr() {
    log_info "Настройка OSPF..."
    
    if [ -f /etc/frr/daemons ]; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        echo "OSPF включен"
    fi
    
    systemctl restart frr
    
    echo "Настройка OSPF..."
    
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
    echo "Интерфейс: $EXTERNAL_IF"
    echo "Локальный IP: $TUNLOCAL"
    echo "Удаленный IP: $TUNREMOTE"
    echo ""
    echo "Туннель: $TUNNEL_IFACE"
    echo "Туннельный IP: $TUNNEL_IP"
    echo ""
    echo "Локальная сеть: $LOCAL_NETWORK"
    if [ "$USE_AUTH" = "yes" ]; then
        echo "Пароль OSPF: $OSPF_PASSWORD"
    else
        echo "Аутентификация: отключена"
    fi
    echo ""
    echo "Файлы:"
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
echo "  1. Автоопределение IP-адреса"
echo "  2. Создание GRE-туннеля (tun1)"
echo "  3. Установка и настройка FRR (OSPF)"
echo "  4. Настройка аутентификации"
echo ""

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите от root"
    exit 1
fi

# Автоопределение и выбор интерфейса
detect_and_select_interface || exit 1

# Удаленный IP
get_remote_ip || exit 1

# Роль
select_role || exit 1

# Локальная сеть
get_local_network || exit 1

# Пароль
select_password

# Подтверждение
echo ""
echo "========================================"
echo "    ПОДТВЕРЖДЕНИЕ"
echo "========================================"
echo ""
echo "Роль: $ROLE"
echo "Интерфейс: $EXTERNAL_IF ($TUNLOCAL)"
echo "Удаленный IP: $TUNREMOTE"
echo "Туннельный IP: $TUNNEL_IP"
echo "Сеть: $LOCAL_NETWORK"
if [ "$USE_AUTH" = "yes" ]; then
    echo "Пароль: $OSPF_PASSWORD"
fi
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

# Проверка
verify_tunnel

# Тест
test_connectivity

# FRR
printf "Настроить FRR (OSPF)? [Y/n]: "
read -r frr_choice

case "$frr_choice" in
    [Nn])
        print_summary
        log_success "Туннель настроен"
        exit 0
        ;;
esac

install_frr
configure_frr
verify_ospf

print_summary

log_success "Настройка завершена!"
echo ""
