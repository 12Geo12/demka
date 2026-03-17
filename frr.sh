#!/bin/bash

# Скрипт настройки GRE туннеля и OSPF для ALT Linux
# Версия: 3.0

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REPORT_FILE="/root/network_setup_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR=""

# Логирование
log() { echo -e "$1[$2]$NC $3"; echo "[$(date '+%H:%M:%S')][$2] $3" >> "$REPORT_FILE"; }
info() { log "$GREEN" "INFO" "$1"; }
warn() { log "$YELLOW" "WARN" "$1"; }
error() { log "$RED" "ERROR" "$1"; exit 1; }
step() { log "$BLUE" "STEP" "$1"; }
success() { log "$CYAN" "OK" "$1"; }

# Определение сетевой конфигурации
discover_network() {
    step "Определение сетевой конфигурации..."
    
    # Основной интерфейс с default route
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$MAIN_IF" ]; then
        # Берём первый интерфейс с IP кроме lo
        MAIN_IF=$(ip -4 addr show | grep -v "lo:" | grep -B2 "inet " | grep "^[0-9]" | head -1 | awk -F': ' '{print $2}')
    fi
    
    [ -z "$MAIN_IF" ] && error "Не найден основной интерфейс"
    
    MAIN_IP=$(ip -4 addr show "$MAIN_IF" | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    [ -z "$MAIN_IP" ] && error "Не найден IP адрес на интерфейсе $MAIN_IF"
    
    info "Основной интерфейс: $MAIN_IF, IP: $MAIN_IP"
    
    # Локальные сети
    LOCAL_NETS=()
    while read -r line; do
        if [[ $line == *"scope link"* ]] && [[ $line != *"$MAIN_IF"* ]]; then
            net=$(echo "$line" | awk '{print $1}')
            dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            [ -n "$net" ] && [ "$dev" != "lo" ] && LOCAL_NETS+=("$net")
        fi
    done < <(ip route show)
    
    # Определение роли роутера
    ROUTER_ROLE=""
    
    # По имени хоста
    if hostname | grep -qi "hq"; then
        ROUTER_ROLE="HQ-RTR"
    elif hostname | grep -qi "br"; then
        ROUTER_ROLE="BR-RTR"
    fi
    
    # По IP адресу
    if [ -z "$ROUTER_ROLE" ]; then
        third=$(echo "$MAIN_IP" | cut -d'.' -f3)
        case $third in
            4) ROUTER_ROLE="HQ-RTR" ;;
            5) ROUTER_ROLE="BR-RTR" ;;
        esac
    fi
    
    # По локальным сетям
    if [ -z "$ROUTER_ROLE" ]; then
        for net in "${LOCAL_NETS[@]}"; do
            case $net in
                192.168.10.*|192.168.20.*) ROUTER_ROLE="HQ-RTR"; break ;;
                192.168.30.*) ROUTER_ROLE="BR-RTR"; break ;;
            esac
        done
    fi
    
    # Интерактивный выбор
    if [ -z "$ROUTER_ROLE" ]; then
        echo -e "${YELLOW}Не удалось определить роль роутера${NC}"
        echo "1) HQ-RTR (Главный офис)"
        echo "2) BR-RTR (Филиал)"
        read -r -p "Выберите [1/2]: " choice
        case $choice in
            1) ROUTER_ROLE="HQ-RTR" ;;
            2) ROUTER_ROLE="BR-RTR" ;;
            *) error "Неверный выбор" ;;
        esac
    fi
    
    success "Роль роутера: $ROUTER_ROLE"
}

# Определение параметров туннеля
set_tunnel_params() {
    step "Определение параметров туннеля..."
    
    TUN_LOCAL="$MAIN_IP"
    
    if [ "$ROUTER_ROLE" = "HQ-RTR" ]; then
        TUN_REMOTE="172.16.5.2"
        TUNNEL_IP="172.16.100.2"
        REMOTE_TUN="172.16.100.1"
        [ ${#LOCAL_NETS[@]} -eq 0 ] && LOCAL_NETS=("192.168.10.0/24" "192.168.20.0/24")
    else
        TUN_REMOTE="172.16.4.2"
        TUNNEL_IP="172.16.100.1"
        REMOTE_TUN="172.16.100.2"
        [ ${#LOCAL_NETS[@]} -eq 0 ] && LOCAL_NETS=("192.168.30.0/24")
    fi
    
    TUNNEL_NET="172.16.100.0/29"
    
    info "Локальный IP: $TUN_LOCAL"
    info "Удалённый IP: $TUN_REMOTE"
    info "IP туннеля: $TUNNEL_IP/29"
}

# Резервное копирование
create_backup() {
    step "Создание резервной копии..."
    
    BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    [ -d "/etc/net/ifaces" ] && cp -r /etc/net/ifaces "$BACKUP_DIR/"
    [ -d "/etc/frr" ] && cp -r /etc/frr "$BACKUP_DIR/"
    
    success "Резервная копия: $BACKUP_DIR"
}

# Настройка GRE туннеля
setup_gre() {
    step "Настройка GRE туннеля..."
    
    # Загрузка модуля
    modprobe gre 2>/dev/null || true
    
    # Удаление старого интерфейса
    ip link del gre1 2>/dev/null || true
    
    # Создание через ip command (надёжнее для ALT Linux)
    ip tunnel add gre1 mode gre local "$TUN_LOCAL" remote "$TUN_REMOTE" ttl 64
    ip link set gre1 up
    ip addr add "$TUNNEL_IP/29" dev gre1
    
    # Проверка
    sleep 1
    if ip link show gre1 &>/dev/null; then
        success "Интерфейс gre1 создан"
        ip addr show gre1
    else
        error "Ошибка создания gre1"
    fi
    
    # Сохранение конфигурации для ALT Linux
    if [ -d "/etc/net/ifaces" ]; then
        mkdir -p /etc/net/ifaces/gre1
        cat > /etc/net/ifaces/gre1/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNOPTIONS='ttl 64'
EOF
        echo "$TUNNEL_IP/29" > /etc/net/ifaces/gre1/ipv4address
        info "Конфигурация сохранена в /etc/net/ifaces/gre1/"
    fi
}

# Установка и настройка FRR
setup_frr() {
    step "Настройка FRR..."
    
    # Установка если нет
    if ! command -v vtysh &>/dev/null; then
        info "Установка FRR..."
        apt-get update >> "$REPORT_FILE" 2>&1
        apt-get install -y frr >> "$REPORT_FILE" 2>&1 || error "Ошибка установки FRR"
    fi
    
    # Включение демонов
    if [ -f "/etc/frr/daemons" ]; then
        sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
        sed -i 's/^#ospfd=no/ospfd=yes/' /etc/frr/daemons
        sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons
    fi
    
    # Базовая конфигурация FRR если нет
    if [ ! -f "/etc/frr/frr.conf" ] || [ ! -s "/etc/frr/frr.conf" ]; then
        cat > /etc/frr/frr.conf << 'EOF'
frr version 8.x
frr defaults traditional
hostname Router
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
line vty
!
EOF
    fi
    
    # Запуск
    systemctl enable frr >> "$REPORT_FILE" 2>&1
    systemctl restart frr >> "$REPORT_FILE" 2>&1
    
    sleep 2
    
    if systemctl is-active --quiet frr; then
        success "FRR запущен"
    else
        error "FRR не запустился. Проверьте: journalctl -u frr"
    fi
}

# Настройка OSPF
setup_ospf() {
    step "Настройка OSPF..."
    
    # Ожидание готовности vtysh
    sleep 2
    
    # Конфигурация OSPF
    vtysh << EOF
configure terminal
router ospf
 ospf router-id $TUNNEL_IP
 passive-interface default
 network $TUNNEL_NET area 0
EOF

    # Добавление локальных сетей
    for net in "${LOCAL_NETS[@]}"; do
        vtysh -c "configure terminal" -c "router ospf" -c "network $net area 0" 2>/dev/null || true
        info "Добавлена сеть $net в OSPF"
    done
    
    # Настройка интерфейса туннеля
    vtysh << EOF
configure terminal
interface gre1
 no ip ospf passive
 ip ospf authentication
 ip ospf authentication-key 1245
 ip ospf mtu-ignore
exit
EOF

    vtysh -c "write memory" 2>/dev/null
    
    success "OSPF настроен"
}

# Настройка firewall
setup_firewall() {
    step "Настройка firewall..."
    
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-protocol=gre 2>/dev/null || true
        firewall-cmd --permanent --add-protocol=ospf 2>/dev/null || true
        firewall-cmd --permanent --zone=trusted --add-interface=gre1 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewalld настроен"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p gre -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p ospf -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -i gre1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -o gre1 -j ACCEPT 2>/dev/null || true
        info "iptables настроены"
    fi
}

# Проверка
verify() {
    step "Проверка конфигурации..."
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}Интерфейс gre1:${NC}"
    ip -4 addr show gre1 2>/dev/null | grep "inet " || echo "  Не найден"
    
    echo ""
    echo -e "${GREEN}Соседи OSPF:${NC}"
    vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  Нет соседей"
    
    echo ""
    echo -e "${GREEN}OSPF маршруты:${NC}"
    vtysh -c "show ip route ospf" 2>/dev/null || echo "  Нет маршрутов"
    
    echo ""
    echo -e "${GREEN}Пинг туннеля ($REMOTE_TUN):${NC}"
    if ping -c 2 -W 2 "$REMOTE_TUN" &>/dev/null; then
        echo "  OK"
    else
        echo "  Нет ответа (настройте туннель на другой стороне)"
    fi
    
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
}

# Главная функция
main() {
    echo "═════════════════════════════════════════════════" | tee "$REPORT_FILE"
    echo "    Настройка GRE туннеля и OSPF (ALT Linux)    " | tee -a "$REPORT_FILE"
    echo "═════════════════════════════════════════════════" | tee -a "$REPORT_FILE"
    
    [ "$EUID" -ne 0 ] && error "Запустите от root"
    
    discover_network
    set_tunnel_params
    create_backup
    setup_gre
    setup_frr
    setup_firewall
    setup_ospf
    verify
    
    echo ""
    success "Настройка завершена!"
    info "Отчёт: $REPORT_FILE"
    info "Резервная копия: $BACKUP_DIR"
    echo ""
    echo -e "${YELLOW}Команды проверки:${NC}"
    echo "  vtysh -c 'show ip ospf neighbor'"
    echo "  vtysh -c 'show ip route ospf'"
    echo "  ip addr show gre1"
}

main "$@"
