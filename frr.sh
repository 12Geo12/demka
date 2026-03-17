#!/bin/sh

# ==============================================================================
# Скрипт автоматической настройки OSPF для FRR (ALT Linux)
# Версия 4.0: POSIX-совместимый (работает с sh)
# ==============================================================================

REPORT_FILE="ospf_report_$(hostname)_$(date +%F_%H-%M).txt"

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

print_header() {
    echo "=============================================================================="
    echo "  $1"
    echo "=============================================================================="
}

print_info() {
    echo "[*] $1"
}

print_warn() {
    echo "[!] $1"
}

print_error() {
    echo "[!] $1"
}

print_success() {
    echo "[+] $1"
}

# ------------------------------------------------------------------------------
# Проверка и установка FRR
# ------------------------------------------------------------------------------
check_install_frr() {
    print_info "Проверка FRR..."
    
    if ! command -v vtysh >/dev/null 2>&1; then
        print_info "FRR не найден. Установка..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq frr >/dev/null 2>&1
        print_success "FRR установлен"
    else
        print_success "FRR уже установлен"
    fi

    # Активация ospfd
    if grep -q "^ospfd=no" /etc/frr/daemons 2>/dev/null; then
        sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
        systemctl restart frr >/dev/null 2>&1
        print_success "Демон ospfd активирован"
    elif ! grep -q "^ospfd=yes" /etc/frr/daemons 2>/dev/null; then
        echo "ospfd=yes" >> /etc/frr/daemons
        systemctl restart frr >/dev/null 2>&1
        print_success "Демон ospfd добавлен и активирован"
    else
        print_success "Демон ospfd уже активен"
    fi
}

# ------------------------------------------------------------------------------
# Показать существующие интерфейсы
# ------------------------------------------------------------------------------
show_interfaces() {
    echo ""
    print_info "Доступные сетевые интерфейсы:"
    printf "    %-15s %-25s\n" "ИНТЕРФЕЙС" "IP АДРЕС"
    printf "    %-15s %-25s\n" "-----------" "--------"
    
    ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {
        printf "    %-15s %-25s\n", $2, $4
    }' || print_warn "Нет активных интерфейсов с IP"
    echo ""
}

# ------------------------------------------------------------------------------
# Создание GRE туннеля
# ------------------------------------------------------------------------------
create_gre_tunnel() {
    print_header "НАСТРОЙКА GRE ТУННЕЛЯ"
    
    echo ""
    print_info "GRE туннель не найден. Создать новый?"
    printf "Создать GRE туннель? (y/n): "
    read CREATE_TUNNEL
    
    case "$CREATE_TUNNEL" in
        [Yy]*)
            ;;
        *)
            print_warn "Без туннеля OSPF между офисами работать не будет!"
            printf "Продолжить без туннеля? (y/n): "
            read CONTINUE
            case "$CONTINUE" in
                [Yy]*)
                    TUNNEL_IF=""
                    return 0
                    ;;
                *)
                    exit 1
                    ;;
            esac
            ;;
    esac
    
    # Параметры для создания туннеля
    printf "Введите локальный IP (внешний интерфейс): "
    read LOCAL_IP
    printf "Введите удаленный IP (внешний IP другого офиса): "
    read REMOTE_IP
    printf "Введите IP для этого конца туннеля (например, 10.10.0.1): "
    read TUNNEL_LOCAL_IP
    printf "Введите IP для удаленного конца туннеля (например, 10.10.0.2): "
    read TUNNEL_REMOTE_IP
    printf "Введите имя интерфейса туннеля (gre1): "
    read TUNNEL_IF
    TUNNEL_IF=${TUNNEL_IF:-gre1}
    
    print_info "Создание GRE туннеля $TUNNEL_IF..."
    
    # Удаляем если существует
    ip link del "$TUNNEL_IF" 2>/dev/null || true
    
    # Создаем туннель
    ip tunnel add "$TUNNEL_IF" mode gre remote "$REMOTE_IP" local "$LOCAL_IP" ttl 255
    ip addr add "$TUNNEL_LOCAL_IP/30" dev "$TUNNEL_IF"
    ip link set "$TUNNEL_IF" up
    
    print_success "GRE туннель создан: $TUNNEL_IF"
    print_info "  Локальный IP: $LOCAL_IP"
    print_info "  Удаленный IP: $REMOTE_IP"
    print_info "  IP туннеля: $TUNNEL_LOCAL_IP/30"
    
    TUNNEL_NET="10.10.0.0/30"
}

# ------------------------------------------------------------------------------
# Выбор или создание туннеля
# ------------------------------------------------------------------------------
select_tunnel_interface() {
    print_header "ВЫБОР ТУННЕЛЬНОГО ИНТЕРФЕЙСА"
    
    # Ищем существующие GRE/IPIP туннели
    TUNNEL_IF=$(ip -o link show 2>/dev/null | grep -iE 'gre|ipip|tun' | awk -F': ' '{print $2}' | awk '{print $1}' | head -1)
    
    if [ -n "$TUNNEL_IF" ]; then
        print_success "Найден существующий туннель: $TUNNEL_IF"
        ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print "  IP адрес: " $4}'
        
        # Получаем сеть туннеля
        TUNNEL_IP=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | head -1)
        if [ -n "$TUNNEL_IP" ]; then
            IP_PART=$(echo "$TUNNEL_IP" | cut -d'/' -f1)
            TUNNEL_NET="${IP_PART%.*}.0/30"
        fi
        
        printf "Использовать этот туннель? (y/n): "
        read USE_EXISTING
        case "$USE_EXISTING" in
            [Yy]*)
                ;;
            *)
                TUNNEL_IF=""
                create_gre_tunnel
                ;;
        esac
    else
        create_gre_tunnel
    fi
}

# ------------------------------------------------------------------------------
# Получение Router-ID
# ------------------------------------------------------------------------------
get_router_id() {
    print_header "НАСТРОЙКА OSPF ПАРАМЕТРОВ"
    
    # Пробуем получить IP туннеля или первый доступный IP
    if [ -n "$TUNNEL_IF" ]; then
        DEFAULT_RID=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    fi
    
    if [ -z "$DEFAULT_RID" ]; then
        DEFAULT_RID=$(ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {print $4; exit}' | cut -d'/' -f1)
    fi
    
    if [ -n "$DEFAULT_RID" ]; then
        printf "Введите OSPF Router-ID (по умолчанию: $DEFAULT_RID): "
        read ROUTER_ID
        ROUTER_ID=${ROUTER_ID:-$DEFAULT_RID}
    else
        printf "Введите OSPF Router-ID: "
        read ROUTER_ID
    fi
    
    print_success "Router-ID установлен: $ROUTER_ID"
}

# ------------------------------------------------------------------------------
# Сбор локальных сетей
# ------------------------------------------------------------------------------
get_local_networks() {
    echo ""
    print_info "Поиск локальных сетей для анонсирования..."
    
    LOCAL_NETS=""
    TMP_IFACES=$(mktemp)
    
    # Собираем все сети кроме туннеля и loopback
    ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {print $2, $4}' > "$TMP_IFACES"
    
    while read -r IFACE IP; do
        # Пропускаем туннель и loopback
        if [ "$IFACE" = "$TUNNEL_IF" ]; then
            continue
        fi
        if [ "$IFACE" = "lo" ]; then
            continue
        fi
        if [ -z "$IP" ]; then
            continue
        fi
        
        # Извлекаем сеть из IP/маски
        NET_IP=$(echo "$IP" | cut -d'/' -f1)
        MASK=$(echo "$IP" | cut -d'/' -f2)
        
        # Вычисляем адрес сети
        NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/')
        
        if [ -z "$LOCAL_NETS" ]; then
            LOCAL_NETS="${NETWORK}/${MASK}"
        else
            LOCAL_NETS="$LOCAL_NETS ${NETWORK}/${MASK}"
        fi
        
        echo "    Найдена сеть: ${NETWORK}/${MASK} ($IFACE)"
        
    done < "$TMP_IFACES"
    
    rm -f "$TMP_IFACES"
    
    if [ -z "$LOCAL_NETS" ]; then
        print_warn "Локальные сети не найдены"
        printf "Введите сети вручную (через пробел): "
        read LOCAL_NETS
    else
        echo ""
        printf "Использовать найденные сети? (y/n): "
        read USE_FOUND
        case "$USE_FOUND" in
            [Yy]*)
                ;;
            *)
                printf "Введите сети вручную (через пробел): "
                read LOCAL_NETS
                ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# Настройка OSPF
# ------------------------------------------------------------------------------
configure_ospf() {
    print_header "ПРИМЕНЕНИЕ КОНФИГУРАЦИИ OSPF"
    
    echo ""
    printf "Введите пароль для OSPF аутентификации: "
    # Отключаем эхо для пароля
    stty -echo
    read OSPF_PASS
    stty echo
    echo ""
    
    if [ -z "$OSPF_PASS" ]; then
        print_error "Пароль не может быть пустым!"
        exit 1
    fi
    
    print_info "Настройка OSPF..."
    
    # Очищаем старую конфигурацию OSPF
    vtysh -c "conf t" -c "no router ospf" 2>/dev/null || true
    
    # Создаем новую конфигурацию
    TMP_CONFIG=$(mktemp)
    
    cat > "$TMP_CONFIG" << EOFCONFIG
configure terminal
router ospf
 ospf router-id $ROUTER_ID
EOFCONFIG
    
    # Добавляем сеть туннеля если есть
    if [ -n "$TUNNEL_NET" ]; then
        echo " network $TUNNEL_NET area 0" >> "$TMP_CONFIG"
    fi
    
    # Добавляем локальные сети
    for NET in $LOCAL_NETS; do
        if [ -n "$NET" ]; then
            echo " network $NET area 0" >> "$TMP_CONFIG"
        fi
    done
    
    cat >> "$TMP_CONFIG" << EOFCONFIG
 area 0 authentication
exit
EOFCONFIG
    
    # Настраиваем туннельный интерфейс
    if [ -n "$TUNNEL_IF" ]; then
        cat >> "$TMP_CONFIG" << EOFCONFIG
interface $TUNNEL_IF
 no ip ospf passive
 ip ospf network broadcast
 ip ospf authentication
 ip ospf authentication-key $OSPF_PASS
exit
EOFCONFIG
    fi
    
    echo "exit" >> "$TMP_CONFIG"
    echo "write" >> "$TMP_CONFIG"
    
    vtysh < "$TMP_CONFIG"
    
    rm -f "$TMP_CONFIG"
    
    print_success "OSPF настроен"
    
    # Показываем краткую информацию
    echo ""
    print_info "Конфигурация OSPF:"
    echo "  Router-ID: $ROUTER_ID"
    if [ -n "$TUNNEL_IF" ]; then
        echo "  Туннель: $TUNNEL_IF"
    fi
    if [ -n "$TUNNEL_NET" ]; then
        echo "  Сеть туннеля: $TUNNEL_NET"
    fi
    echo "  Локальные сети: ${LOCAL_NETS:-нет}"
}

# ------------------------------------------------------------------------------
# Генерация отчета
# ------------------------------------------------------------------------------
generate_report() {
    echo ""
    print_info "Генерация отчета: $REPORT_FILE"
    
    {
        echo "================================================================================"
        echo " ОТЧЕТ ПО НАСТРОЙКЕ OSPF (Задание 7)"
        echo " Дата: $(date)"
        echo " Хост: $(hostname)"
        echo "================================================================================"
        echo ""
        echo "1. ПАРАМЕТРЫ НАСТРОЙКИ:"
        echo "--------------------------------------------------------------------------------"
        echo "Router-ID:      ${ROUTER_ID}"
        if [ -n "$TUNNEL_IF" ]; then
            echo "Туннель:        ${TUNNEL_IF}"
        fi
        if [ -n "$TUNNEL_NET" ]; then
            echo "Сеть туннеля:   ${TUNNEL_NET}"
        fi
        echo "Локальные сети: ${LOCAL_NETS:-нет}"
        echo ""
        echo "2. ТЕКУЩАЯ КОНФИГУРАЦИЯ (show run):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show run" 2>/dev/null || echo "Конфигурация недоступна"
        echo ""
        echo "3. СТАТУС СОСЕДЕЙ OSPF (show ip ospf neighbor):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Соседи не найдены"
        echo ""
        echo "4. ТАБЛИЦА МАРШРУТИЗАЦИИ OSPF (show ip route ospf):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show ip route ospf" 2>/dev/null || echo "OSPF маршруты отсутствуют"
        echo ""
        echo "5. СТАТУС ИНТЕРФЕЙСОВ:"
        echo "--------------------------------------------------------------------------------"
        ip addr show 2>/dev/null | grep -A1 "inet " || echo "Информация недоступна"
        echo ""
        echo "================================================================================"
        echo " КОНЕЦ ОТЧЕТА"
        echo "================================================================================"
    } > "$REPORT_FILE"
    
    print_success "Отчет сохранен: $REPORT_FILE"
}

# ------------------------------------------------------------------------------
# Проверка работоспособности
# ------------------------------------------------------------------------------
check_status() {
    echo ""
    print_header "ПРОВЕРКА РАБОТОСПОСОБНОСТИ"
    
    echo ""
    print_info "Статус OSPF соседей:"
    vtysh -c "show ip ospf neighbor" 2>/dev/null || print_warn "Не удалось получить информацию"
    
    echo ""
    print_info "OSPF маршруты:"
    vtysh -c "show ip route ospf" 2>/dev/null | head -10 || print_warn "Маршруты не найдены"
}

# ==============================================================================
# ОСНОВНАЯ ПРОГРАММА
# ==============================================================================

clear
print_header "АВТОМАТИЧЕСКАЯ НАСТРОЙКА OSPF ДЛЯ FRR (ALT Linux)"

check_install_frr
show_interfaces
select_tunnel_interface
get_router_id
get_local_networks
configure_ospf
generate_report
check_status

print_header "НАСТРОЙКА ЗАВЕРШЕНА"
echo ""
echo "Для проверки связи:"
echo "  vtysh -c 'show ip ospf neighbor'"
echo "  ping <IP_удаленной_сети>"
echo ""
echo "Отчет: $REPORT_FILE"
echo "================================================================================"
