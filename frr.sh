#!/bin/bash

# Скрипт настройки GRE туннеля и OSPF для ALT Linux
# Версия: 3.1 (исправленная)

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

# Глобальные переменные
MAIN_IF=""
MAIN_IP=""
ROUTER_ROLE=""
TUN_LOCAL=""
TUN_REMOTE=""
TUNNEL_IP=""
REMOTE_TUN=""
TUNNEL_NET=""
declare -a LOCAL_NETS

# Логирование
log() {
    local color="$1"
    local level="$2"
    local message="$3"
    echo -e "${color}[${level}]${NC} ${message}"
    echo "[$(date '+%H:%M:%S')][${level}] ${message}" >> "$REPORT_FILE"
}

info() { log "$GREEN" "INFO" "$1"; }
warn() { log "$YELLOW" "WARN" "$1"; }
error() { log "$RED" "ERROR" "$1"; exit 1; }
step() { log "$BLUE" "STEP" "$1"; }
success() { log "$CYAN" "OK" "$1"; }

# Определение сетевой конфигурации
discover_network() {
    step "Определение сетевой конфигурации..."
    
    # Основной интерфейс с default route
    MAIN_IF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    
    # Если не нашли через default route, берём первый интерфейс с IP
    if [ -z "$MAIN_IF" ]; then
        MAIN_IF=$(ip -4 addr show | awk '/^[0-9]+:/{iface=$2} /inet /{print iface; exit}' | tr -d ':')
    fi
    
    [ -z "$MAIN_IF" ] && error "Не найден основной интерфейс"
    
    MAIN_IP=$(ip -4 addr show "$MAIN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1)
    [ -z "$MAIN_IP" ] && error "Не найден IP адрес на интерфейсе $MAIN_IF"
    
    info "Основной интерфейс: $MAIN_IF, IP: $MAIN_IP"
    
    # Локальные сети (исключаем основной интерфейс и loopback)
    LOCAL_NETS=()
    while read -r line; do
        if [[ $line == *"scope link"* ]]; then
            local net dev
            net=$(echo "$line" | awk '{print $1}')
            dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            if [ -n "$net" ] && [ "$dev" != "lo" ] && [ "$dev" != "$MAIN_IF" ]; then
                LOCAL_NETS+=("$net")
            fi
        fi
    done < <(ip route show scope link 2>/dev/null)
    
    # Определение роли роутера
    ROUTER_ROLE=""
    
    # По имени хоста
    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "")
    if echo "$hostname_str" | grep -qi "hq"; then
        ROUTER_ROLE="HQ-RTR"
    elif echo "$hostname_str" | grep -qi "br"; then
        ROUTER_ROLE="BR-RTR"
    fi
    
    # По IP адресу (третий октет)
    if [ -z "$ROUTER_ROLE" ]; then
        local third
        third=$(echo "$MAIN_IP" | cut -d'.' -f3)
        case "$third" in
            4) ROUTER_ROLE="HQ-RTR" ;;
            5) ROUTER_ROLE="BR-RTR" ;;
        esac
    fi
    
    # По локальным сетям
    if [ -z "$ROUTER_ROLE" ]; then
        for net in "${LOCAL_NETS[@]}"; do
            case "$net" in
                192.168.10.*|192.168.20.*) ROUTER_ROLE="HQ-RTR"; break ;;
                192.168.30.*) ROUTER_ROLE="BR-RTR"; break ;;
            esac
        done
    fi
    
    # Интерактивный выбор
    if [ -z "$ROUTER_ROLE" ]; then
        echo -e "${YELLOW}Не удалось автоматически определить роль роутера${NC}"
        echo "1) HQ-RTR (Главный офис)"
        echo "2) BR-RTR (Филиал)"
        read -r -p "Выберите [1/2]: " choice
        case "$choice" in
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
        # HQ-RTR: подключается к BR-RTR
        TUN_REMOTE="172.16.5.2"
        TUNNEL_IP="172.16.100.2"
        REMOTE_TUN="172.16.100.1"
        # Сети HQ по умолчанию
        if [ ${#LOCAL_NETS[@]} -eq 0 ]; then
            LOCAL_NETS=("192.168.10.0/24" "192.168.20.0/24")
        fi
    else
        # BR-RTR: подключается к HQ-RTR
        TUN_REMOTE="172.16.4.2"
        TUNNEL_IP="172.16.100.1"
        REMOTE_TUN="172.16.100.2"
        # Сети BR по умолчанию
        if [ ${#LOCAL_NETS[@]} -eq 0 ]; then
            LOCAL_NETS=("192.168.30.0/24")
        fi
    fi
    
    TUNNEL_NET="172.16.100.0/29"
    
    info "Локальный endpoint: $TUN_LOCAL"
    info "Удалённый endpoint: $TUN_REMOTE"
    info "IP туннеля: $TUNNEL_IP/29"
    info "Локальные сети: ${LOCAL_NETS[*]}"
}

# Резервное копирование
create_backup() {
    step "Создание резервной копии..."
    
    BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    if [ -d "/etc/net/ifaces" ]; then
        cp -r /etc/net/ifaces "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [ -d "/etc/frr" ]; then
        cp -r /etc/frr "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [ -f "/etc/sysctl.conf" ]; then
        cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    success "Резервная копия: $BACKUP_DIR"
}

# Настройка GRE туннеля
setup_gre() {
    step "Настройка GRE туннеля..."
    
    # Загрузка модуля
    modprobe gre 2>/dev/null || true
    if ! lsmod | grep -q "^gre"; then
        warn "Модуль gre не загружен, продолжаю..."
    fi
    
    # Удаление старого интерфейса если существует
    ip link del gre1 2>/dev/null || true
    
    # Создание туннеля
    ip tunnel add gre1 mode gre local "$TUN_LOCAL" remote "$TUN_REMOTE" ttl 64 || {
        error "Не удалось создать GRE туннель"
    }
    
    ip link set gre1 up || error "Не удалось включить интерфейс gre1"
    ip addr add "${TUNNEL_IP}/29" dev gre1 || error "Не удалось назначить IP для gre1"
    
    # Проверка создания
    sleep 1
    if ip link show gre1 &>/dev/null; then
        success "Интерфейс gre1 создан"
        ip addr show gre1 | grep -E "^[0-9]+:|inet "
    else
        error "Интерфейс gre1 не создан"
    fi
    
    # Сохранение конфигурации для ALT Linux (/etc/net)
    if [ -d "/etc/net/ifaces" ]; then
        mkdir -p /etc/net/ifaces/gre1
        
        cat > /etc/net/ifaces/gre1/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
EOF
        
        echo "${TUNNEL_IP}/29" > /etc/net/ifaces/gre1/ipv4address
        echo "UP" > /etc/net/ifaces/gre1/control
        
        success "Конфигурация сохранена в /etc/net/ifaces/gre1/"
    fi
}

# Включение IP forwarding
setup_sysctl() {
    step "Настройка sysctl..."
    
    # Применение немедленно
    sysctl -w net.ipv4.ip_forward=1 >> "$REPORT_FILE" 2>&1
    
    # Сохранение в конфиг
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    else
        sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi
    
    success "IP forwarding включён"
}

# Установка и настройка FRR
setup_frr() {
    step "Настройка FRR (Free Range Routing)..."
    
    # Проверка установки
    if ! command -v vtysh &>/dev/null; then
        info "Установка FRR..."
        
        # Обновление индекса пакетов
        apt-get update >> "$REPORT_FILE" 2>&1 || {
            warn "apt-get update завершился с ошибкой, продолжаю..."
        }
        
        # Установка FRR
        apt-get install -y frr >> "$REPORT_FILE" 2>&1 || {
            # Пробуем альтернативное имя пакета
            apt-get install -y frr8 >> "$REPORT_FILE" 2>&1 || {
                error "Не удалось установить FRR. Установите вручную: apt-get install frr"
            }
        }
    fi
    
    # Включение демонов
    if [ -f "/etc/frr/daemons" ]; then
        sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons
        sed -i 's/^#zebra=no/zebra=yes/' /etc/frr/daemons
        sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
        sed -i 's/^#ospfd=no/ospfd=yes/' /etc/frr/daemons
        info "Демоны zebra и ospfd включены"
    else
        warn "Файл /etc/frr/daemons не найден"
    fi
    
    # Базовая конфигурация FRR
    if [ ! -f "/etc/frr/frr.conf" ] || [ ! -s "/etc/frr/frr.conf" ]; then
        cat > /etc/frr/frr.conf << EOF
frr version 8.x
frr defaults traditional
hostname $(hostname)
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
line vty
!
EOF
        info "Создана базовая конфигурация FRR"
    fi
    
    # Права на конфигурацию
    chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
    chmod 640 /etc/frr/frr.conf 2>/dev/null || true
    
    # Запуск сервиса
    systemctl enable frr >> "$REPORT_FILE" 2>&1 || true
    systemctl restart frr >> "$REPORT_FILE" 2>&1
    
    sleep 3
    
    if systemctl is-active --quiet frr; then
        success "FRR успешно запущен"
    else
        warn "FRR не запустился нормально. Проверьте: journalctl -u frr -n 50"
        # Пробуем ещё раз
        systemctl restart frr >> "$REPORT_FILE" 2>&1
        sleep 2
        systemctl is-active --quiet frr || warn "FRR всё ещё не активен"
    fi
}

# Настройка OSPF
setup_ospf() {
    step "Настройка OSPF..."
    
    # Ожидание готовности vtysh
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if vtysh -c "show version" &>/dev/null; then
            break
        fi
        info "Ожидание готовности vtysh... ($attempt/$max_attempts)"
        sleep 1
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        error "vtysh не отвечает после $max_attempts попыток"
    fi
    
    # Конфигурация OSPF через vtysh
    info "Настройка OSPF router..."
    
    vtysh -c "configure terminal" \
          -c "router ospf" \
          -c "ospf router-id $TUNNEL_IP" \
          -c "passive-interface default" \
          -c "network $TUNNEL_NET area 0" || {
        warn "Ошибка при базовой настройке OSPF"
    }
    
    # Добавление локальных сетей
    for net in "${LOCAL_NETS[@]}"; do
        if vtysh -c "configure terminal" -c "router ospf" -c "network $net area 0" 2>/dev/null; then
            info "Добавлена сеть $net в OSPF area 0"
        else
            warn "Не удалось добавить сеть $net"
        fi
    done
    
    # Настройка интерфейса туннеля (без passive, с аутентификацией)
    info "Настройка интерфейса gre1 для OSPF..."
    
    vtysh -c "configure terminal" \
          -c "interface gre1" \
          -c "no ip ospf passive" \
          -c "ip ospf authentication" \
          -c "ip ospf authentication-key 1245" \
          -c "ip ospf mtu-ignore" \
          -c "exit" || {
        warn "Ошибка при настройке интерфейса gre1"
    }
    
    # Сохранение конфигурации
    vtysh -c "write memory" 2>/dev/null || vtysh -c "copy running-config startup-config" 2>/dev/null || {
        warn "Не удалось сохранить конфигурацию FRR"
    }
    
    success "OSPF настроен"
}

# Настройка firewall
setup_firewall() {
    step "Настройка firewall..."
    
    if systemctl is-active --quiet firewalld; then
        # Firewalld
        firewall-cmd --permanent --add-protocol=gre 2>/dev/null || true
        firewall-cmd --permanent --add-protocol=ospf 2>/dev/null || true
        firewall-cmd --permanent --zone=trusted --add-interface=gre1 2>/dev/null || true
        firewall-cmd --permanent --add-port=89/udp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewalld настроен"
        
    elif command -v iptables &>/dev/null; then
        # iptables
        iptables -I INPUT -p gre -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p 89 -j ACCEPT 2>/dev/null || true  # OSPF protocol
        iptables -I INPUT -i gre1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -i gre1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -o gre1 -j ACCEPT 2>/dev/null || true
        
        # Сохранение правил (если есть iptables-save)
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        info "iptables настроены"
        
    else
        warn "Ни firewalld, ни iptables не найдены"
    fi
}

# Проверка конфигурации
verify() {
    step "Проверка конфигурации..."
    
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    # Интерфейс gre1
    echo -e "${GREEN}[1] Интерфейс GRE туннеля:${NC}"
    if ip -4 addr show gre1 &>/dev/null; then
        ip -4 addr show gre1 | grep -E "^[0-9]+:|inet "
    else
        echo "  ${RED}Интерфейс gre1 не найден${NC}"
    fi
    
    # Туннель
    echo ""
    echo -e "${GREEN}[2] Состояние туннеля:${NC}"
    ip tunnel show gre1 2>/dev/null || echo "  Туннель не найден"
    
    # OSPF соседи
    echo ""
    echo -e "${GREEN}[3] Соседи OSPF:${NC}"
    local neighbors
    neighbors=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)
    if [ -n "$neighbors" ]; then
        echo "$neighbors"
    else
        echo "  ${YELLOW}Нет соседей (настройте туннель на другой стороне)${NC}"
    fi
    
    # OSPF маршруты
    echo ""
    echo -e "${GREEN}[4] OSPF маршруты:${NC}"
    local routes
    routes=$(vtysh -c "show ip route ospf" 2>/dev/null)
    if [ -n "$routes" ]; then
        echo "$routes"
    else
        echo "  ${YELLOW}Нет OSPF маршрутов${NC}"
    fi
    
    # Пинг удалённого конца туннеля
    echo ""
    echo -e "${GREEN}[5] Пинг удалённого конца туннеля ($REMOTE_TUN):${NC}"
    if ping -c 3 -W 2 "$REMOTE_TUN" &>/dev/null; then
        echo "  ${GREEN}✓ Туннель работает${NC}"
    else
        echo "  ${YELLOW}✗ Нет ответа (проверьте туннель на другой стороне)${NC}"
    fi
    
    # FRR статус
    echo ""
    echo -e "${GREEN}[6] Статус FRR:${NC}"
    if systemctl is-active --quiet frr; then
        echo "  ${GREEN}✓ FRR активен${NC}"
    else
        echo "  ${RED}✗ FRR не активен${NC}"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# Главная функция
main() {
    # Инициализация лог-файла
    echo "═════════════════════════════════════════════════" > "$REPORT_FILE"
    echo "  Настройка GRE туннеля и OSPF (ALT Linux)" >> "$REPORT_FILE"
    echo "  Дата: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "═════════════════════════════════════════════════" >> "$REPORT_FILE"
    
    # Вывод заголовка на экран
    echo ""
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}    Настройка GRE туннеля и OSPF (ALT Linux)    ${NC}"
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"
    echo ""
    
    # Проверка прав root
    if [ "$EUID" -ne 0 ]; then
        error "Скрипт должен быть запущен от имени root"
    fi
    
    # Основные шаги
    discover_network
    set_tunnel_params
    create_backup
    setup_sysctl
    setup_gre
    setup_frr
    setup_firewall
    setup_ospf
    verify
    
    # Итоговое сообщение
    echo ""
    success "═════════ НАСТРОЙКА ЗАВЕРШЕНА ═════════"
    echo ""
    info "Отчёт: $REPORT_FILE"
    info "Резервная копия: $BACKUP_DIR"
    echo ""
    echo -e "${YELLOW}Полезные команды для проверки:${NC}"
    echo "  vtysh -c 'show ip ospf neighbor'   # Соседи OSPF"
    echo "  vtysh -c 'show ip route ospf'      # OSPF маршруты"
    echo "  vtysh -c 'show ip ospf interface'  # Интерфейсы OSPF"
    echo "  ip addr show gre1                  # Состояние туннеля"
    echo "  ip tunnel show                     # Информация о туннеле"
    echo ""
    echo -e "${YELLOW}Для просмотра логов:${NC}"
    echo "  journalctl -u frr -f               # Логи FRR в реальном времени"
    echo ""
}

# Запуск
main "$@"
