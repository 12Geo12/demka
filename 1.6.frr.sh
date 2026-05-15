#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE туннель) - ПОЛНОСТЬЮ АВТОМАТИЧЕСКИЙ
# Версия: 4.0 - Исправлены все ошибки совместимости
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_ok() { log "${GREEN}[OK]${NC} $1"; }
log_warn() { log "${YELLOW}[WARN]${NC} $1"; }
log_err() { log "${RED}[ERR]${NC} $1"; }
sep() { log "${CYAN}================================================${NC}"; }

#===============================================================================
# ПРОВЕРКА ROOT
#===============================================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

log ""
log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║${NC}   ${WHITE}FRRouting (OSPF + GRE) - Автоматическая настройка${NC}   ${CYAN}║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
log ""

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
#===============================================================================

sep
log "${WHITE}=== Автоопределение интерфейсов ===${NC}"
sep
log ""

# Временные файлы вместо массивов (для совместимости)
IFACE_LIST="/tmp/frr_ifaces_$$"
VLAN_LIST="/tmp/frr_vlans_$$"
NETWORKS_LIST="/tmp/frr_networks_$$"
> "$IFACE_LIST"
> "$VLAN_LIST"
> "$NETWORKS_LIST"

# Функция получения IP (без local)
get_ip() {
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2}' | head -1
}

# Функция получения статуса
get_status() {
    cat "/sys/class/net/$1/operstate" 2>/dev/null || echo "unknown"
}

# Функция определения типа интерфейса
get_type() {
    if echo "$1" | grep -q '\.'; then
        echo "VLAN"
    elif [ -d "/sys/class/net/$1/device" ]; then
        echo "PHYSICAL"
    else
        echo "VIRTUAL"
    fi
}

# Функция конвертации IP/маска в сеть (без ipcalc)
ip_to_network() {
    local ip_mask="$1"
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
    
    if [ -z "$ip" ] || [ -z "$cidr" ]; then
        return
    fi
    
    # Простой расчёт маски
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$ip"
    
    # Определяем маску
    local mask=""
    case "$cidr" in
        24) mask="0.0.0" ;;
        25) mask="0.0.0" ;;
        26) mask="0.0.0" ;;
        27) mask="0.0.0" ;;
        28) mask="0.0.0" ;;
        29) mask="0.0.0" ;;
        30) mask="0.0.0" ;;
        16) mask="0.0" ;;
        *) mask="0.0.0" ;;
    esac
    
    # Для /24 и больше - обнуляем последний октет
    if [ "$cidr" -ge 24 ]; then
        echo "${o1}.${o2}.${o3}.0/${cidr}"
    elif [ "$cidr" -ge 16 ]; then
        echo "${o1}.${o2}.0.0/${cidr}"
    else
        echo "${o1}.0.0.0/${cidr}"
    fi
}

# Получаем интерфейс с default route
WAN_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')
WAN_IP=""

log "${CYAN}Обнаруженные интерфейсы:${NC}"
log ""
printf "  %-16s %-8s %-20s %-10s\n" "Интерфейс" "Статус" "IP-адрес" "Тип"
echo "  --------------------------------------------------------------"

# Перебираем все интерфейсы
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v -E '^(lo|docker|veth|virbr|br-|flannel|cni|tun|tap|bond|gre|sit)$'); do
    type=$(get_type "$iface")
    status=$(get_status "$iface")
    ip=$(get_ip "$iface")
    
    # Форматирование
    [ "$status" = "up" ] && status_s="${GREEN}UP${NC}" || status_s="${YELLOW}$status${NC}"
    
    case "$type" in
        PHYSICAL) type_s="${GREEN}PHYS${NC}" ;;
        VLAN) type_s="${CYAN}VLAN${NC}" ;;
        *) type_s="${YELLOW}$type${NC}" ;;
    esac
    
    [ -z "$ip" ] && ip="---"
    
    printf "  %-16s " "$iface"
    echo -e "$status_s\t$ip\t$type_s"
    
    # Классификация
    if [ "$type" = "VLAN" ]; then
        echo "$iface" >> "$VLAN_LIST"
    elif [ "$type" = "PHYSICAL" ]; then
        echo "$iface" >> "$IFACE_LIST"
        
        # Определяем WAN
        if [ "$iface" = "$WAN_IFACE" ] && [ -n "$ip" ] && [ "$ip" != "---" ]; then
            WAN_IP="$ip"
        fi
    fi
done

log ""

#===============================================================================
# ОПРЕДЕЛЕНИЕ WAN
#===============================================================================

if [ -z "$WAN_IFACE" ] || [ -z "$WAN_IP" ]; then
    log_warn "WAN не определён автоматически"
    log ""
    log "${YELLOW}Выберите WAN интерфейс (подключен к интернету/другому роутеру):${NC}"
    
    idx=1
    while read -r iface; do
        ip=$(get_ip "$iface")
        echo "  $idx) $iface (${ip:-нет IP})"
        idx=$((idx + 1))
    done < "$IFACE_LIST"
    
    read -p "Номер: " wan_num
    wan_num=${wan_num:-1}
    
    WAN_IFACE=$(sed -n "${wan_num}p" "$IFACE_LIST")
    WAN_IP=$(get_ip "$WAN_IFACE")
fi

log_ok "WAN: ${WHITE}$WAN_IFACE${NC} (${WAN_IP:-нет IP})"

# Убираем WAN из списка физических интерфейсов
grep -v "^${WAN_IFACE}$" "$IFACE_LIST" > "${IFACE_LIST}.tmp" 2>/dev/null
mv "${IFACE_LIST}.tmp" "$IFACE_LIST" 2>/dev/null

#===============================================================================
# ОПРЕДЕЛЕНИЕ VLAN И СЕТЕЙ
#===============================================================================

sep
log "${WHITE}=== Автоопределение сетей OSPF ===${NC}"
sep
log ""

# Собираем сети с VLAN
if [ -s "$VLAN_LIST" ]; then
    log "${CYAN}Сети с VLAN интерфейсов:${NC}"
    while read -r vlan; do
        ip=$(get_ip "$vlan")
        if [ -n "$ip" ] && [ "$ip" != "---" ]; then
            net=$(ip_to_network "$ip")
            if [ -n "$net" ]; then
                echo "$net" >> "$NETWORKS_LIST"
                log "  ${GREEN}•${NC} $vlan: ${CYAN}$net${NC}"
            fi
        fi
    done < "$VLAN_LIST"
fi

# Собираем сети с LAN интерфейсов
if [ -s "$IFACE_LIST" ]; then
    log "${CYAN}Сети с LAN интерфейсов:${NC}"
    while read -r iface; do
        ip=$(get_ip "$iface")
        if [ -n "$ip" ] && [ "$ip" != "---" ]; then
            net=$(ip_to_network "$ip")
            if [ -n "$net" ]; then
                # Проверка на дубликаты
                if ! grep -q "^${net}$" "$NETWORKS_LIST" 2>/dev/null; then
                    echo "$net" >> "$NETWORKS_LIST"
                    log "  ${GREEN}•${NC} $iface: ${CYAN}$net${NC}"
                fi
            fi
        fi
    done < "$IFACE_LIST"
fi

# Если сетей нет
if [ ! -s "$NETWORKS_LIST" ]; then
    log_warn "Сети не определены автоматически"
    log "${YELLOW}Введите сети для OSPF через пробел:${NC}"
    log "  Пример: 192.168.10.0/26 192.168.20.0/28 192.168.99.0/29"
    read -p "Сети: " networks_input
    
    for net in $networks_input; do
        echo "$net" >> "$NETWORKS_LIST"
    done
fi

# Показываем итоговый список
log ""
log_ok "Сети для OSPF:"
while read -r net; do
    log "  ${GREEN}•${NC} $net"
done < "$NETWORKS_LIST"

#===============================================================================
# НАСТРОЙКА GRE
#===============================================================================

sep
log "${WHITE}=== Настройка GRE туннеля ===${NC}"
sep
log ""

# Локальный IP для GRE
GRE_LOCAL_IP=$(echo "$WAN_IP" | cut -d'/' -f1)

if [ -z "$GRE_LOCAL_IP" ]; then
    log_err "Не удалось определить локальный IP"
    read -p "Введите локальный IP: " GRE_LOCAL_IP
fi

log_ok "Локальный IP для GRE: ${CYAN}$GRE_LOCAL_IP${NC}"

# Удаленный IP
log ""
log "${YELLOW}Введите удалённый IP для GRE туннеля:${NC}"
log "  (IP адрес удалённого роутера для туннеля)"
read -p "Удалённый IP: " GRE_REMOTE_IP

# Роль роутера
log ""
log "${YELLOW}Выберите роль:${NC}"
echo "  1) HQ-RTR (Router ID: 1.1.1.1, GRE IP: 172.16.1.1/24)"
echo "  2) BR-RTR (Router ID: 2.2.2.2, GRE IP: 172.16.1.2/24)"
read -p "Роль [1]: " role
role=${role:-1}

case "$role" in
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

log_ok "Роль: ${WHITE}$ROLE${NC}, Router ID: $RID"
log_ok "GRE IP: ${WHITE}$GRE_IP${NC}"

#===============================================================================
# УСТАНОВКА FRR
#===============================================================================

sep
log "${WHITE}=== Установка FRR ===${NC}"
sep
log ""

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq frr iproute2 2>/dev/null || apt-get install -y frr 2>/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q frr 2>/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q frr 2>/dev/null
else
    log_err "Пакетный менеджер не найден"
    exit 1
fi

log_ok "FRR установлен"

#===============================================================================
# КОНФИГУРАЦИЯ FRR DAEMONS
#===============================================================================

sep
log "${WHITE}=== Настройка демонов FRR ===${NC}"
sep
log ""

mkdir -p /etc/frr

cat > /etc/frr/daemons << 'DAEMONS'
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
DAEMONS

log_ok "Демоны настроены (zebra=yes, ospfd=yes)"

#===============================================================================
# GRE ТУННЕЛЬ
#===============================================================================

sep
log "${WHITE}=== Создание GRE туннеля ===${NC}"
sep
log ""

# ALT Linux etcnet
if [ -d "/etc/net/ifaces" ]; then
    mkdir -p /etc/net/ifaces/gre1
    
    cat > /etc/net/ifaces/gre1/options << GREOPT
TYPE=gre
REMOTE=${GRE_REMOTE_IP}
LOCAL=${GRE_LOCAL_IP}
TTL=64
DISABLE=no
GREOPT
    
    echo "${GRE_IP}" > /etc/net/ifaces/gre1/ipv4address
    log_ok "GRE настроен в /etc/net/ifaces/gre1"
fi

# Systemd service
cat > /etc/systemd/system/gre-tunnel.service << GRESVC
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
GRESVC

systemctl daemon-reload
systemctl enable gre-tunnel.service 2>/dev/null

# Поднимаем GRE
ip tunnel del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$GRE_REMOTE_IP" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400

log_ok "GRE туннель поднят"

#===============================================================================
# OSPF КОНФИГУРАЦИЯ
#===============================================================================

sep
log "${WHITE}=== Настройка OSPF ===${NC}"
sep
log ""

cat > /etc/frr/frr.conf << OSPFCFG
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
OSPFCFG

# Добавляем сети
log "${CYAN}Добавляем сети в OSPF:${NC}"
while read -r net; do
    echo " network $net area 0" >> /etc/frr/frr.conf
    log "  ${GREEN}+${NC} $net area 0"
done < "$NETWORKS_LIST"

# Добавляем GRE сеть
echo " network 172.16.1.0/24 area 0" >> /etc/frr/frr.conf
log "  ${GREEN}+${NC} 172.16.1.0/24 area 0 (GRE)"

# Завершение
cat >> /etc/frr/frr.conf << 'OSPFEND'
!
line vty
!
OSPFEND

# Права
chown frr:frr /etc/frr/frr.conf 2>/dev/null || chown frr /etc/frr/frr.conf 2>/dev/null
chmod 640 /etc/frr/frr.conf 2>/dev/null

log_ok "OSPF настроен"

#===============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
#===============================================================================

sep
log "${WHITE}=== Системные настройки ===${NC}"
sep
log ""

# IP forwarding
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
log_ok "IP forwarding включён"

# rp_filter
grep -q 'rp_filter=2' /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf << 'SYSCTL'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
log_ok "rp_filter настроен"

#===============================================================================
# ЗАПУСК
#===============================================================================

sep
log "${WHITE}=== Запуск служб ===${NC}"
sep
log ""

systemctl enable frr 2>/dev/null
systemctl restart frr 2>/dev/null

sleep 3

log_ok "FRR запущен"

#===============================================================================
# ПРОВЕРКА
#===============================================================================

sep
log "${WHITE}=== Проверка ===${NC}"
sep
log ""

# GRE
if ip link show gre1 >/dev/null 2>&1; then
    log_ok "GRE туннель: ${GREEN}активен${NC}"
    ip -br addr show gre1 2>/dev/null || ip addr show gre1 2>/dev/null | head -3
else
    log_err "GRE туннель не поднят!"
fi

log ""
log "${CYAN}OSPF соседи:${NC}"
if vtysh -c "show ip ospf neighbor" 2>/dev/null; then
    :
else
    log_warn "Соседи не найдены (проверьте удалённый роутер)"
fi

log ""
log "${CYAN}OSPF маршруты:${NC}"
if ip route show | grep -i ospf 2>/dev/null; then
    :
else
    log_warn "Маршруты OSPF не найдены"
fi

#===============================================================================
# ИТОГ
#===============================================================================

log ""
log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
log "${GREEN}║${NC}          ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                          ${GREEN}║${NC}"
log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
log ""
log "${CYAN}Конфигурация:${NC}"
log "  Роль:          ${WHITE}$ROLE${NC}"
log "  Router ID:     ${WHITE}$RID${NC}"
log "  WAN:           ${WHITE}$WAN_IFACE${NC} ($WAN_IP)"
log "  GRE Local:     ${WHITE}$GRE_LOCAL_IP${NC}"
log "  GRE Remote:    ${WHITE}$GRE_REMOTE_IP${NC}"
log "  GRE IP:        ${WHITE}$GRE_IP${NC}"
log ""
log "${CYAN}Сети OSPF:${NC}"
while read -r net; do
    log "  ${GREEN}•${NC} $net"
done < "$NETWORKS_LIST"
log "  ${GREEN}•${NC} 172.16.1.0/24 (GRE)"
log ""
log "${CYAN}Команды проверки:${NC}"
log "  ${YELLOW}vtysh -c 'show ip ospf neighbor'${NC}"
log "  ${YELLOW}ip route show | grep ospf${NC}"
log "  ${YELLOW}systemctl status frr${NC}"
log "  ${YELLOW}ping 172.16.1.2${NC}"
log ""

# Очистка временных файлов
rm -f "$IFACE_LIST" "$VLAN_LIST" "$NETWORKS_LIST"

log "${CYAN}Лог: ${LOG_FILE}${NC}"
log ""
