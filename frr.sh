#!/bin/sh

# ==============================================================================
# Скрипт автоматической настройки OSPF для FRR (ALT Linux)
# Версия 5.0: Полностью исправленный, POSIX-совместимый
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
# Проверка прав root
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "Скрипт должен запускаться от root!"
        exit 1
    fi
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
# Загрузка модуля GRE
# ------------------------------------------------------------------------------
load_gre_module() {
    print_info "Проверка модуля GRE..."
    
    if ! lsmod | grep -q ip_gre; then
        print_info "Загрузка модуля ip_gre..."
        modprobe ip_gre
        if [ $? -eq 0 ]; then
            print_success "Модуль ip_gre загружен"
        else
            print_error "Не удалось загрузить модуль ip_gre"
            exit 1
        fi
    else
        print_success "Модуль ip_gre уже загружен"
    fi
}

# ------------------------------------------------------------------------------
# Показать существующие интерфейсы
# ------------------------------------------------------------------------------
show_interfaces() {
    echo ""
    print_info "Доступные сетевые интерфейсы:"
    printf "    %-12s %-25s %-20s\n" "ИНТЕРФЕЙС" "IP АДРЕС" "СТАТУС"
    printf "    %-12s %-25s %-20s\n" "-----------" "--------" "------"
    
    ip -o addr show 2>/dev/null | while read -r line; do
        IFACE=$(echo "$line" | awk '{print $2}')
        IP=$(echo "$line" | awk '{print $4}')
        STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
        printf "    %-12s %-25s %-20s\n" "$IFACE" "$IP" "$STATE"
    done
    echo ""
}

# ------------------------------------------------------------------------------
# Исправление неправильного IP на физическом интерфейсе
# ------------------------------------------------------------------------------
fix_wrong_ip() {
    print_info "Проверка корректности назначения IP..."
    
    # Проверяем, не назначен ли IP туннеля на физический интерфейс
    for IFACE in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}'); do
        case "$IFACE" in
            lo|gre*|ipip*|tun*)
                continue
                ;;
            *)
                # Проверяем есть ли на физическом интерфейсе IP из сети 10.10.0.0/30
                if ip addr show "$IFACE" 2>/dev/null | grep -q '10\.10\.0\.[0-9]/30'; then
                    print_warn "Обнаружен IP туннеля на физическом интерфейсе $IFACE"
                    print_info "Удаляем 10.10.0.0/30 с $IFACE..."
                    ip addr show "$IFACE" | grep '10\.10\.0\.[0-9]/30' | while read -r line; do
                        IP_TO_DEL=$(echo "$line" | awk '{print $2}' | awk '{print $1}')
                        ip addr del "$IP_TO_DEL" dev "$IFACE" 2>/dev/null
                        print_success "Удален $IP_TO_DEL с $IFACE"
                    done
                fi
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Создание GRE туннеля
# ------------------------------------------------------------------------------
create_gre_tunnel() {
    print_header "НАСТРОЙКА GRE ТУННЕЛЯ"
    
    echo ""
    print_info "GRE туннель не найден. Создадим новый."
    
    # Получаем внешний IP по умолчанию
    DEFAULT_LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    
    printf "Введите ваш внешний IP (по умолчанию %s): " "$DEFAULT_LOCAL_IP"
    read LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_LOCAL_IP}
    
    printf "Введите внешний IP другого офиса: "
    read REMOTE_IP
    
    printf "Введите IP для этого конца туннеля (по умолчанию 10.10.0.1): "
    read TUNNEL_LOCAL_IP
    TUNNEL_LOCAL_IP=${TUNNEL_LOCAL_IP:-10.10.0.1}
    
    printf "Введите IP для удаленного конца туннеля (по умолчанию 10.10.0.2): "
    read TUNNEL_REMOTE_IP
    TUNNEL_REMOTE_IP=${TUNNEL_REMOTE_IP:-10.10.0.2}
    
    printf "Введите имя интерфейса туннеля (по умолчанию gre1): "
    read TUNNEL_IF
    TUNNEL_IF=${TUNNEL_IF:-gre1}
    
    print_info "Создание GRE туннеля $TUNNEL_IF..."
    
    # Удаляем если существует
    ip link del "$TUNNEL_IF" 2>/dev/null || true
    
    # Создаем туннель
    if ip tunnel add "$TUNNEL_IF" mode gre remote "$REMOTE_IP" local "$LOCAL_IP" ttl 255; then
        print_success "Туннель создан"
    else
        print_error "Не удалось создать туннель"
        exit 1
    fi
    
    # Добавляем IP
    if ip addr add "$TUNNEL_LOCAL_IP/30" dev "$TUNNEL_IF"; then
        print_success "IP адрес назначен"
    else
        print_error "Не удалось назначить IP"
        exit 1
    fi
    
    # Поднимаем интерфейс
    if ip link set "$TUNNEL_IF" up; then
        print_success "Интерфейс поднят"
    else
        print_error "Не удалось поднять интерфейс"
        exit 1
    fi
    
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
    
    # Исправляем неправильные IP
    fix_wrong_ip
    
    # Ищем существующие GRE туннели
    TUNNEL_IF=""
    for IFACE in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}'); do
        case "$IFACE" in
            gre*|ipip*|tun*)
                if ip addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
                    TUNNEL_IF="$IFACE"
                    break
                fi
                ;;
        esac
    done
    
    if [ -n "$TUNNEL_IF" ]; then
        print_success "Найден существующий туннель: $TUNNEL_IF"
        ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print "  IP адрес: " $4}'
        
        # Получаем сеть туннеля
        TUNNEL_IP=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | head -1)
        if [ -n "$TUNNEL_IP" ]; then
            IP_PART=$(echo "$TUNNEL_IP" | cut -d'/' -f1)
            TUNNEL_NET=$(echo "$IP_PART" | sed 's/\.[0-9]*$/\.0/')"/30"
        fi
        
        printf "Использовать этот туннель? (y/n): "
        read USE_EXISTING
        case "$USE_EXISTING" in
            [Yy]*)
                print_success "Используем $TUNNEL_IF"
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
    
    # Пробуем получить IP туннеля
    if [ -n "$TUNNEL_IF" ]; then
        DEFAULT_RID=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    fi
    
    # Если нет, берем первый доступный IP
    if [ -z "$DEFAULT_RID" ]; then
        DEFAULT_RID=$(ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {print $4; exit}' | cut -d'/' -f1)
    fi
    
    if [ -n "$DEFAULT_RID" ]; then
        printf "Введите OSPF Router-ID (по умолчанию: %s): " "$DEFAULT_RID"
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
    TMP_IFACES="/tmp/interfaces_$$"
    
    # Собираем все сети кроме туннеля и loopback
    ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {print $2, $4}' > "$TMP_IFACES"
    
    while read -r IFACE IP; do
        # Пропускаем туннель и loopback
        case "$IFACE" in
            "$TUNNEL_IF"|lo)
                continue
                ;;
        esac
        
        [ -z "$IP" ] && continue
        
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
                print_success "Используем найденные сети"
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
    old_stty=$(stty -g)
    stty -echo
    read OSPF_PASS
    stty "$old_stty"
    echo ""
    
    if [ -z "$OSPF_PASS" ]; then
        print_error "Пароль не может быть пустым!"
        exit 1
    fi
    
    print_info "Настройка OSPF..."
    
    # Очищаем старую конфигурацию OSPF
    vtysh -c "conf t" -c "no router ospf" 2>/dev/null || true
    
    # Создаем новую конфигурацию
    TMP_CONFIG="/tmp/ospf_config_$$"
    
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
    
    echo ""
    print_info "Статус туннеля:"
    if [ -n "$TUNNEL_IF" ]; then
        ip addr show "$TUNNEL_IF" 2>/dev/null || print_warn "Туннель не найден"
    fi
}

# ==============================================================================
# ОСНОВНАЯ ПРОГРАММА
# ==============================================================================

clear
print_header "АВТОМАТИЧЕСКАЯ НАСТРОЙКА OSPF ДЛЯ FRR (ALT Linux)"

check_root
check_install_frr
load_gre_module
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
