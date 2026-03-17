#!/bin/bash

# ==============================================================================
# Скрипт автоматической настройки OSPF для FRR (ALT Linux)
# Версия 3.0: Работа без предустановленных туннелей + оптимизация
# ==============================================================================

set -e

REPORT_FILE="ospf_report_$(hostname)_$(date +%F_%H-%M).txt"
FRR_CONFIG="/etc/frr/frr.conf"

# Цвета для вывода (можно отключить)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

print_info() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[+]${NC} $1"
}

# ------------------------------------------------------------------------------
# Функция: Проверка и установка FRR
# ------------------------------------------------------------------------------
check_install_frr() {
    print_info "Проверка FRR..."
    
    if ! command -v vtysh &>/dev/null; then
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
# Функция: Показать существующие интерфейсы
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
# Функция: Создание GRE туннеля
# ------------------------------------------------------------------------------
create_gre_tunnel() {
    print_header "НАСТРОЙКА GRE ТУННЕЛЯ"
    
    echo ""
    print_info "GRE туннель не найден. Создать новый?"
    read -p "Создать GRE туннель? (y/n): " CREATE_TUNNEL
    
    if [[ ! "$CREATE_TUNNEL" =~ ^[Yy]$ ]]; then
        print_warn "Без туннеля OSPF между офисами работать не будет!"
        read -p "Продолжить без туннеля? (y/n): " CONTINUE
        if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
            TUNNEL_IF=""
            return 0
        else
            exit 1
        fi
    fi
    
    # Параметры для создания туннеля
    read -p "Введите локальный IP (внешний интерфейс): " LOCAL_IP
    read -p "Введите удаленный IP (внешний IP другого офиса): " REMOTE_IP
    read -p "Введите IP для этого конца туннеля (например, 10.10.0.1): " TUNNEL_LOCAL_IP
    read -p "Введите IP для удаленного конца туннеля (например, 10.10.0.2): " TUNNEL_REMOTE_IP
    read -p "Введите имя интерфейса туннеля (gre1): " TUNNEL_IF
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
# Функция: Выбор или создание туннеля
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
        
        read -p "Использовать этот туннель? (y/n): " USE_EXISTING
        if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
            TUNNEL_IF=""
            create_gre_tunnel
        fi
    else
        create_gre_tunnel
    fi
}

# ------------------------------------------------------------------------------
# Функция: Получение Router-ID
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
        read -p "Введите OSPF Router-ID (по умолчанию: $DEFAULT_RID): " ROUTER_ID
        ROUTER_ID=${ROUTER_ID:-$DEFAULT_RID}
    else
        read -p "Введите OSPF Router-ID: " ROUTER_ID
    fi
    
    print_success "Router-ID установлен: $ROUTER_ID"
}

# ------------------------------------------------------------------------------
# Функция: Сбор локальных сетей
# ------------------------------------------------------------------------------
get_local_networks() {
    echo ""
    print_info "Поиск локальных сетей для анонсирования..."
    
    LOCAL_NETS=()
    
    # Собираем все сети кроме туннеля и loopback
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        IFACE=$(echo "$line" | awk '{print $1}')
        IP=$(echo "$line" | awk '{print $2}')
        
        # Пропускаем туннель и loopback
        [[ "$IFACE" == "$TUNNEL_IF" ]] && continue
        [[ "$IFACE" == "lo" ]] && continue
        [[ -z "$IP" ]] && continue
        
        # Извлекаем сеть из IP/маски
        NET_IP=$(echo "$IP" | cut -d'/' -f1)
        MASK=$(echo "$IP" | cut -d'/' -f2)
        
        # Вычисляем адрес сети
        case "$MASK" in
            24) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            25) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            26) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            27) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            28) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            29) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            30) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
            *) NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/') ;;
        esac
        
        LOCAL_NETS+=("${NETWORK}/${MASK}")
        echo "    Найдена сеть: ${NETWORK}/${MASK} ($IFACE)"
        
    done < <(ip -o addr show 2>/dev/null | awk '$2 != "lo" && NF >= 4 {print $2, $4}')
    
    if [ ${#LOCAL_NETS[@]} -eq 0 ]; then
        print_warn "Локальные сети не найдены"
        read -p "Введите сети вручную (через пробел): " -a LOCAL_NETS
    else
        echo ""
        read -p "Использовать найденные сети? (y/n): " USE_FOUND
        if [[ ! "$USE_FOUND" =~ ^[Yy]$ ]]; then
            read -p "Введите сети вручную (через пробел): " -a LOCAL_NETS
        fi
    fi
}

# ------------------------------------------------------------------------------
# Функция: Настройка OSPF
# ------------------------------------------------------------------------------
configure_ospf() {
    print_header "ПРИМЕНЕНИЕ КОНФИГУРАЦИИ OSPF"
    
    echo ""
    read -p "Введите пароль для OSPF аутентификации: " -s OSPF_PASS
    echo ""
    
    if [ -z "$OSPF_PASS" ]; then
        print_error "Пароль не может быть пустым!"
        exit 1
    fi
    
    print_info "Настройка OSPF..."
    
    # Очищаем старую конфигурацию OSPF
    vtysh -c "conf t" -c "no router ospf" 2>/dev/null || true
    
    # Создаем новую конфигурацию
    {
        echo "configure terminal"
        echo "router ospf"
        echo " ospf router-id $ROUTER_ID"
        
        # Добавляем сеть туннеля если есть
        if [ -n "$TUNNEL_NET" ]; then
            echo " network $TUNNEL_NET area 0"
        fi
        
        # Добавляем локальные сети
        for NET in "${LOCAL_NETS[@]}"; do
            [ -n "$NET" ] && echo " network $NET area 0"
        done
        
        echo " area 0 authentication"
        echo "exit"
        
        # Настраиваем туннельный интерфейс
        if [ -n "$TUNNEL_IF" ]; then
            echo "interface $TUNNEL_IF"
            echo " no ip ospf passive"
            echo " ip ospf network broadcast"
            echo " ip ospf authentication"
            echo " ip ospf authentication-key $OSPF_PASS"
            echo "exit"
        fi
        
        echo "exit"
        echo "write"
    } | vtysh
    
    print_success "OSPF настроен"
    
    # Показываем краткую информацию
    echo ""
    print_info "Конфигурация OSPF:"
    echo "  Router-ID: $ROUTER_ID"
    [ -n "$TUNNEL_IF" ] && echo "  Туннель: $TUNNEL_IF"
    [ -n "$TUNNEL_NET" ] && echo "  Сеть туннеля: $TUNNEL_NET"
    echo "  Локальные сети: ${LOCAL_NETS[*]}"
}

# ------------------------------------------------------------------------------
# Функция: Генерация отчета
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
        [ -n "$TUNNEL_IF" ] && echo "Туннель:        ${TUNNEL_IF}"
        [ -n "$TUNNEL_NET" ] && echo "Сеть туннеля:   ${TUNNEL_NET}"
        echo "Локальные сети: ${LOCAL_NETS[*]:-нет}"
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
# Функция: Проверка работоспособности
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
