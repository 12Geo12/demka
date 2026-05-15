#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE туннель) - ПОЛНОСТЬЮ АВТОМАТИЧЕСКИЙ
# Версия: 3.0 - Автоопределение всех параметров
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Логирование
LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_info() { log "${GREEN}✓${NC} $1"; }
log_warn() { log "${YELLOW}⚠${NC} $1"; }
log_error() { log "${RED}✗${NC} $1"; }
line() { log "${CYAN}================================================${NC}"; }

#===============================================================================
# ПРОВЕРКИ
#===============================================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Запустите от root${NC}"
    exit 1
fi

log ""
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║${NC}    ${WHITE}FRRouting (OSPF + GRE) - Автоматическая настройка${NC}      ${CYAN}║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
#===============================================================================

line
log "${WHITE}=== Автоопределение сетевых интерфейсов ===${NC}"
line
log ""

# Получаем все интерфейсы (исключая виртуальные)
get_interfaces() {
    ls /sys/class/net/ 2>/dev/null | grep -v -E "^(lo|docker|veth|virbr|br-|flannel|cni|tun|tap|bond|gre|sit)"
}

# Определяем тип интерфейса
get_iface_type() {
    local iface="$1"
    
    # VLAN (содержит точку)
    if [[ "$iface" == *"."* ]]; then
        echo "VLAN"
        return
    fi
    
    # Проверяем через /sys
    if [ -d "/sys/class/net/${iface}/device" ]; then
        echo "PHYSICAL"
    else
        echo "VIRTUAL"
    fi
}

# Получаем IP интерфейса
get_iface_ip() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1
}

# Получаем статус интерфейса
get_iface_status() {
    local iface="$1"
    local state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null)
    echo "$state"
}

# Получаем шлюз по умолчанию
get_default_gw() {
    ip route show default 2>/dev/null | awk '{print $3}'
}

# Получаем интерфейс шлюза (WAN)
get_wan_iface() {
    ip route show default 2>/dev/null | awk '{print $5}'
}

# Получаем все сети известные системе
get_known_networks() {
    ip route show 2>/dev/null | grep -oP 'dev \K[\w.]+' | sort -u
}

# Показываем все интерфейсы
log "${CYAN}Обнаруженные интерфейсы:${NC}"
log ""

WAN_IFACE=""
WAN_IP=""
LAN_IFACES=()
VLAN_IFACES=()

printf "  %-15s %-10s %-20s %-15s\n" "Интерфейс" "Статус" "IP-адрес" "Тип"
echo "  --------------------------------------------------------------------"

for iface in $(get_interfaces); do
    local type=$(get_iface_type "$iface")
    local status=$(get_iface_status "$iface")
    local ip=$(get_iface_ip "$iface")
    [ -z "$ip" ] && ip="нет IP"
    
    local status_out
    [ "$status" = "up" ] && status_out="${GREEN}UP${NC}" || status_out="${YELLOW}$status${NC}"
    
    local type_out
    case "$type" in
        PHYSICAL) type_out="${GREEN}PHYSICAL${NC}" ;;
        VLAN) type_out="${CYAN}VLAN${NC}" ;;
        *) type_out="${YELLOW}$type${NC}" ;;
    esac
    
    printf "  %-15s " "$iface"
    echo -e "$status_out\t\t$ip\t\t$type_out"
    
    # Классификация
    if [ "$type" = "VLAN" ]; then
        VLAN_IFACES+=("$iface")
    elif [ "$type" = "PHYSICAL" ]; then
        # WAN = интерфейс с дефолтным маршрутом
        local def_iface=$(get_wan_iface)
        if [ "$iface" = "$def_iface" ] && [ -n "$ip" ]; then
            WAN_IFACE="$iface"
            WAN_IP="$ip"
        elif [ "$status" = "up" ] || [ -n "$ip" ]; then
            LAN_IFACES+=("$iface")
        fi
    fi
done

log ""

# Автоопределение WAN
if [ -z "$WAN_IFACE" ]; then
    log_warn "WAN не определён автоматически по шлюзу"
    log "${YELLOW}Выберите WAN интерфейс (для GRE туннеля):${NC}"
    
    idx=1
    for iface in ${LAN_IFACES[@]}; do
        local ip=$(get_iface_ip "$iface")
        echo "  $idx) $iface (${ip:-нет IP})"
        idx=$((idx + 1))
    done
    
    read -p "Номер [1]: " wan_num
    wan_num=${wan_num:-1}
    
    WAN_IFACE="${LAN_IFACES[$((wan_num - 1))]}"
    WAN_IP=$(get_iface_ip "$WAN_IFACE")
fi

# Очищаем WAN из списка LAN
NEW_LAN=()
for iface in "${LAN_IFACES[@]}"; do
    [ "$iface" != "$WAN_IFACE" ] && NEW_LAN+=("$iface")
done
LAN_IFACES=("${NEW_LAN[@]}")

log ""
log_info "WAN интерфейс: ${CYAN}$WAN_IFACE${NC} (${WAN_IP:-нет IP})"

# Автоопределение LAN
if [ ${#LAN_IFACES[@]} -eq 0 ]; then
    log_warn "LAN интерфейсы не определены"
    
    # Ищем интерфейсы без IP
    for iface in $(get_interfaces); do
        local type=$(get_iface_type "$iface")
        local ip=$(get_iface_ip "$iface")
        
        if [ "$type" = "PHYSICAL" ] && [ "$iface" != "$WAN_IFACE" ] && [ -z "$ip" ]; then
            LAN_IFACES+=("$iface")
        fi
    done
fi

if [ ${#LAN_IFACES[@]} -gt 0 ]; then
    log_info "LAN интерфейсы: ${CYAN}${LAN_IFACES[*]}${NC}"
fi

# Показываем VLAN
if [ ${#VLAN_IFACES[@]} -gt 0 ]; then
    log_info "VLAN интерфейсы: ${CYAN}${VLAN_IFACES[*]}${NC}"
fi

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ СЕТЕЙ
#===============================================================================

line
log "${WHITE}=== Автоопределение сетей для OSPF ===${NC}"
line
log ""

# Собираем все сети с интерфейсов
OSPF_NETWORKS=()

# Добавляем сети с VLAN
for vlan in "${VLAN_IFACES[@]}"; do
    local net=$(get_iface_ip "$vlan")
    if [ -n "$net" ]; then
        # Конвертируем IP/CIDR в сеть
        local network=$(ipcalc -n "$net" 2>/dev/null | grep Network | awk '{print $2}')
        if [ -n "$network" ]; then
            OSPF_NETWORKS+=("$network")
            log "  ${GREEN}•${NC} VLAN $vlan: $network"
        else
            # Fallback - показываем как есть
            OSPF_NETWORKS+=("$net")
            log "  ${GREEN}•${NC} VLAN $vlan: $net"
        fi
    fi
done

# Добавляем сети с LAN интерфейсов
for iface in "${LAN_IFACES[@]}"; do
    local net=$(get_iface_ip "$iface")
    if [ -n "$net" ]; then
        local network=$(ipcalc -n "$net" 2>/dev/null | grep Network | awk '{print $2}')
        if [ -n "$network" ]; then
            # Проверяем на дубликаты
            local found=0
            for n in "${OSPF_NETWORKS[@]}"; do
                [ "$n" = "$network" ] && found=1 && break
            done
            [ $found -eq 0 ] && OSPF_NETWORKS+=("$network") && log "  ${GREEN}•${NC} LAN $iface: $network"
        fi
    fi
done

# Если сетей нет - запрашиваем вручную
if [ ${#OSPF_NETWORKS[@]} -eq 0 ]; then
    log_warn "Сети не определены автоматически"
    log "${YELLOW}Введите сети для OSPF (через пробел, например: 192.168.10.0/26 192.168.20.0/28):${NC}"
    read -p "Сети: " networks_input
    
    for net in $networks_input; do
        OSPF_NETWORKS+=("$net")
    done
fi

log ""
log_info "Сети для OSPF: ${CYAN}${OSPF_NETWORKS[*]}${NC}"

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ
#===============================================================================

line
log "${WHITE}=== Настройка GRE туннеля ===${NC}"
line
log ""

# Автоопределение IP для GRE
log "${CYAN}Определение параметров GRE туннеля...${NC}"

# Локальный IP для GRE - берем с WAN интерфейса
GRE_LOCAL_IP=$(echo "$WAN_IP" | cut -d'/' -f1)

if [ -z "$GRE_LOCAL_IP" ]; then
    log_error "Не удалось определить локальный IP для GRE"
    read -p "Введите локальный IP для GRE: " GRE_LOCAL_IP
fi

log_info "Локальный IP для GRE: ${CYAN}$GRE_LOCAL_IP${NC}"

# Удаленный IP для GRE - запрашиваем или предлагаем варианты
log ""
log "${YELLOW}Введите удаленный IP для GRE туннеля (IP удаленного роутера):${NC}"
log "  Примеры:"
log "    - Для HQ-RTR: IP BR-RTR"
log "    - Для BR-RTR: IP HQ-RTR"

# Проверяем есть ли маршрут к другим сетям
OTHER_NETS=$(ip route show 2>/dev/null | grep -v "default" | grep -v "linkdown" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -5)
if [ -n "$OTHER_NETS" ]; then
    log ""
    log "${CYAN}Обнаруженные удалённые сети (возможно через GRE):${NC}"
    for net in $OTHER_NETS; do
        log "  ${GREEN}•${NC} $net"
    done
fi

log ""
read -p "Удаленный IP для GRE: " GRE_REMOTE_IP

# GRE IP и Router ID
log ""
log "${YELLOW}Выберите роль роутера:${NC}"
echo "1) HQ-RTR (Router ID: 1.1.1.1, GRE IP: 172.16.1.1/24)"
echo "2) BR-RTR (Router ID: 2.2.2.2, GRE IP: 172.16.1.2/24)"
read -p "Роль [1]: " role_choice
role_choice=${role_choice:-1}

case "$role_choice" in
    2)
        ROLE="BR-RTR"
        RID="2.2.2.2"
        GRE_IP="172.16.1.2/24"
        ;;
    *)
        ROLE="HQ-RTR"
        RID="1.1.1.1"
        GRE_IP="172.16.1.1/24"
        ;;
esac

log_info "Роль: ${CYAN}$ROLE${NC} (Router ID: $RID)"
log_info "GRE IP: ${CYAN}$GRE_IP${NC}"

#===============================================================================
# УСТАНОВКА FRR
#===============================================================================

line
log "${WHITE}=== Установка FRRouting ===${NC}"
line
log ""

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq frr frr-pythontools iproute2 iptables 2>/dev/null || {
        # Альтернативные пакеты для ALT Linux
        apt-get install -y frr 2>/dev/null
    }
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q frr iproute iptables 2>/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q frr iproute iptables 2>/dev/null
else
    log_error "Не найден пакетный менеджер"
    exit 1
fi

log_info "FRR установлен"

#===============================================================================
# НАСТРОЙКА FRR DAEMONS
#===============================================================================

line
log "${WHITE}=== Настройка демонов FRR ===${NC}"
line
log ""

# Проверяем расположение конфига
FRR_DAEMONS="/etc/frr/daemons"
if [ ! -f "$FRR_DAEMONS" ]; then
    FRR_DAEMONS="/etc/frr/daemons.conf"
fi
mkdir -p /etc/frr 2>/dev/null

cat > "$FRR_DAEMONS" << 'DAEMONS_EOF'
zebra=yes
ospfd=yes
bgpd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
DAEMONS_EOF

log_info "Демоны FRR настроены (zebra=yes, ospfd=yes)"

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ
#===============================================================================

line
log "${WHITE}=== Создание GRE туннеля ===${NC}"
line
log ""

# Для ALT Linux - etcnet
if [ -d "/etc/net/ifaces" ]; then
    log_info "Настройка через etcnet (ALT Linux)..."
    
    mkdir -p /etc/net/ifaces/gre1
    
    cat > /etc/net/ifaces/gre1/options << GRE_OPT_EOF
TYPE=gre
REMOTE=${GRE_REMOTE_IP}
LOCAL=${GRE_LOCAL_IP}
TTL=64
DISABLE=no
GRE_OPT_EOF
    
    echo "${GRE_IP}" > /etc/net/ifaces/gre1/ipv4address
    
    log_info "GRE настроен в /etc/net/ifaces/gre1"
fi

# Systemd service (универсальный)
cat > /etc/systemd/system/gre-tunnel.service << GRE_SVC_EOF
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${GRE_LOCAL_IP} remote ${GRE_REMOTE_IP} ttl 64
ExecStart=/sbin/ip addr add ${GRE_IP} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1400
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
GRE_SVC_EOF

systemctl daemon-reload
systemctl enable gre-tunnel.service 2>/dev/null
log_info "systemd service создан"

# Поднимаем GRE прямо сейчас
ip tunnel del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$GRE_REMOTE_IP" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400

log_info "GRE туннель поднят"

#===============================================================================
# НАСТРОЙКА OSPF
#===============================================================================

line
log "${WHITE}=== Настройка OSPF ===${NC}"
line
log ""

# Проверяем расположение конфига
FRR_CONF="/etc/frr/frr.conf"
mkdir -p /etc/frr 2>/dev/null

# Начало конфигурации
cat > "$FRR_CONF" << OSPF_HEADER_EOF
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id ${RID}
 passive-interface default
 no passive-interface gre1
!
 interface gre1
  ip ospf authentication
  ip ospf authentication-key 123
OSPF_HEADER_EOF

# Добавляем сети
for network in "${OSPF_NETWORKS[@]}"; do
    echo " network $network area 0" >> "$FRR_CONF"
    log "  ${GREEN}+${NC} network $network area 0"
done

# Добавляем GRE сеть
echo " network 172.16.1.0/24 area 0" >> "$FRR_CONF"
log "  ${GREEN}+${NC} network 172.16.1.0/24 area 0 (GRE)"

# Завершение
cat >> "$FRR_CONF" << 'OSPF_FOOTER_EOF'
!
line vty
!
OSPF_FOOTER_EOF

# Права доступа
chown frr:frr "$FRR_CONF" 2>/dev/null || chown frr:frr "$FRR_CONF" 2>/dev/null
chmod 640 "$FRR_CONF" 2>/dev/null

log_info "OSPF настроен (Router ID: $RID)"

#===============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
#===============================================================================

line
log "${WHITE}=== Системные настройки ===${NC}"
line
log ""

# IP forwarding
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
log_info "IP forwarding включен"

# rp_filter
if ! grep -q "net.ipv4.conf.all.rp_filter=2" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL_EOF
fi
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
log_info "rp_filter настроен"

#===============================================================================
# ЗАПУСК СЛУЖБ
#===============================================================================

line
log "${WHITE}=== Запуск служб ===${NC}"
line
log ""

systemctl enable frr 2>/dev/null
systemctl restart frr 2>/dev/null
log_info "FRR запущен"

sleep 3

#===============================================================================
# ПРОВЕРКА
#===============================================================================

line
log "${WHITE}=== Проверка ===${NC}"
line
log ""

# GRE
if ip link show gre1 >/dev/null 2>&1; then
    log_info "GRE туннель: ${GREEN}активен${NC}"
    ip -brief addr show gre1 2>/dev/null
else
    log_error "GRE туннель не поднят!"
fi

log ""
log "${CYAN}OSPF соседи:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || log_warn "Соседи не найдены (проверьте удалённый роутер)"

log ""
log "${CYAN}OSPF маршруты:${NC}"
ip route show | grep -i ospf 2>/dev/null || log_warn "Маршруты OSPF не найдены"

#===============================================================================
# ИТОГ
#===============================================================================

log ""
log "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${GREEN}║${NC}           ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}                   ${GREEN}║${NC}"
log "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""
log "${CYAN}Конфигурация:${NC}"
log "  Роль:           ${WHITE}$ROLE${NC}"
log "  Router ID:      ${WHITE}$RID${NC}"
log "  WAN интерфейс:  ${WHITE}$WAN_IFACE${NC}"
log "  GRE Local:      ${WHITE}$GRE_LOCAL_IP${NC}"
log "  GRE Remote:     ${WHITE}$GRE_REMOTE_IP${NC}"
log "  GRE IP:         ${WHITE}$GRE_IP${NC}"
log ""
log "${CYAN}Сети OSPF:${NC}"
for net in "${OSPF_NETWORKS[@]}"; do
    log "  ${GREEN}•${NC} $net"
done
log "  ${GREEN}•${NC} 172.16.1.0/24 (GRE)"
log ""
log "${CYAN}Команды проверки:${NC}"
log "  ${YELLOW}vtysh -c 'show ip ospf neighbor'${NC}"
log "  ${YELLOW}ip route show | grep ospf${NC}"
log "  ${YELLOW}systemctl status frr${NC}"
log "  ${YELLOW}ping 172.16.1.2${NC} (или .1)"
log ""
log "${CYAN}Лог:${NC} ${LOG_FILE}"
log ""
