#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE) - Версия 7.0
# Добавлено: удаление старых настроек FRR перед настройкой
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; }
sep() { log "${CYAN}================================================${NC}"; }

#===============================================================================
# ПРОВЕРКА ROOT
#===============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

log ""
log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║${NC}    ${WHITE}FRRouting OSPF + GRE - Автоматическая настройка${NC}     ${CYAN}║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
log ""

#===============================================================================
# ОЧИСТКА СТАРЫХ НАСТРОЕК FRR
#===============================================================================

sep
log "${WHITE}=== Очистка старых настроек FRR ===${NC}"
sep
log ""

log "${YELLOW}Остановка служб...${NC}"
systemctl stop frr 2>/dev/null && ok "FRR остановлен" || warn "FRR не был запущен"

log "${YELLOW}Удаление GRE туннелей...${NC}"
# Удаляем все GRE туннели
for gre_iface in $(ip link show 2>/dev/null | grep -oP 'gre\d+' | sort -u); do
    ip link set "$gre_iface" down 2>/dev/null
    ip tunnel del "$gre_iface" 2>/dev/null && ok "Удалён $gre_iface"
done

# Специфично для gre1
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null
ip addr del 172.16.1.1/24 dev gre1 2>/dev/null
ip addr del 172.16.1.2/24 dev gre1 2>/dev/null

log "${YELLOW}Удаление конфигурационных файлов...${NC}"

# Резервная копия старых конфигов
BACKUP_DIR="/var/backups/frr-$(date +%Y%m%d-%H%M%S)"
if [ -d "/etc/frr" ] || [ -d "/etc/net/ifaces/gre1" ] || [ -f "/etc/systemd/system/gre-tunnel.service" ]; then
    mkdir -p "$BACKUP_DIR"
    ok "Резервные копии: $BACKUP_DIR"
fi

# Бэкап и удаление /etc/frr
if [ -d "/etc/frr" ]; then
    cp -r /etc/frr "$BACKUP_DIR/" 2>/dev/null
    rm -rf /etc/frr/frr.conf 2>/dev/null
    rm -rf /etc/frr/daemons 2>/dev/null
    rm -rf /etc/frr/zebra.conf 2>/dev/null
    rm -rf /etc/frr/ospfd.conf 2>/dev/null
    ok "Очищен /etc/frr/"
fi

# Бэкап и удаление GRE в etcnet
if [ -d "/etc/net/ifaces/gre1" ]; then
    cp -r /etc/net/ifaces/gre1 "$BACKUP_DIR/gre1-etcnet" 2>/dev/null
    rm -rf /etc/net/ifaces/gre1 2>/dev/null
    ok "Удалён /etc/net/ifaces/gre1"
fi

# Удаление systemd service для GRE
if [ -f "/etc/systemd/system/gre-tunnel.service" ]; then
    cp /etc/systemd/system/gre-tunnel.service "$BACKUP_DIR/" 2>/dev/null
    rm -f /etc/systemd/system/gre-tunnel.service
    systemctl daemon-reload
    ok "Удалён gre-tunnel.service"
fi

# Отключаем FRR от автозагрузки (будет включён заново при настройке)
systemctl disable frr 2>/dev/null

# Очистка маршрутов OSPF
log "${YELLOW}Очистка OSPF маршрутов...${NC}"
ip route flush proto ospf 2>/dev/null && ok "OSPF маршруты очищены"

log ""
ok "${GREEN}Очистка завершена!${NC}"
log ""

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
#===============================================================================

sep
log "${WHITE}=== Автоопределение интерфейсов ===${NC}"
sep
log ""

# Временные файлы
IFACE_LIST="/tmp/frr_ifaces_$$"
VLAN_LIST="/tmp/frr_vlans_$$"
NETWORKS_LIST="/tmp/frr_nets_$$"
> "$IFACE_LIST"
> "$VLAN_LIST"
> "$NETWORKS_LIST"

# Получаем интерфейс с default route
DEF_ROUTE_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')
WAN_IFACE=""
WAN_IP=""

log "${CYAN}Сканирование интерфейсов...${NC}"
log ""
printf "  %-16s %-8s %-22s %-10s\n" "Интерфейс" "Статус" "IP-адрес" "Тип"
echo "  --------------------------------------------------------------"

# Перебираем интерфейсы
for iface in $(ls /sys/class/net/ 2>/dev/null); do
    # Пропускаем виртуальные
    case "$iface" in
        lo|docker*|veth*|virbr*|br-*|flannel*|cni*|tun*|tap*|bond*|gre*|sit*) continue ;;
    esac
    
    # Определяем тип
    iface_type="VIRTUAL"
    case "$iface" in
        *.*) iface_type="VLAN" ;;
        *)
            if [ -d "/sys/class/net/${iface}/device" ]; then
                iface_type="PHYSICAL"
            fi
            ;;
    esac
    
    # Получаем статус
    iface_status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    
    # Получаем IP
    iface_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    
    # Форматирование вывода
    case "$iface_status" in
        up) status_out="${GREEN}UP${NC}" ;;
        *) status_out="${YELLOW}$iface_status${NC}" ;;
    esac
    
    case "$iface_type" in
        PHYSICAL) type_out="${GREEN}PHYS${NC}" ;;
        VLAN) type_out="${CYAN}VLAN${NC}" ;;
        *) type_out="${YELLOW}VIRT${NC}" ;;
    esac
    
    [ -z "$iface_ip" ] && iface_ip="---"
    
    printf "  %-16s " "$iface"
    echo -e "$status_out\t$iface_ip\t$type_out"
    
    # Сохраняем в файлы
    case "$iface_type" in
        VLAN)
            echo "$iface" >> "$VLAN_LIST"
            ;;
        PHYSICAL)
            echo "$iface" >> "$IFACE_LIST"
            # WAN = интерфейс с default route и IP
            if [ "$iface" = "$DEF_ROUTE_IFACE" ] && [ -n "$iface_ip" ] && [ "$iface_ip" != "---" ]; then
                WAN_IFACE="$iface"
                WAN_IP="$iface_ip"
            fi
            ;;
    esac
done

log ""

#===============================================================================
# ВЫБОР WAN
#===============================================================================

if [ -z "$WAN_IFACE" ] || [ -z "$WAN_IP" ]; then
    warn "WAN не определён автоматически"
    log ""
    log "${YELLOW}Выберите WAN интерфейс (для GRE туннеля):${NC}"
    
    idx=0
    while read -r iface; do
        idx=$((idx + 1))
        ip_tmp=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}')
        echo "  $idx) $iface (${ip_tmp:-нет IP})"
    done < "$IFACE_LIST"
    
    read -p "Номер: " wan_num
    wan_num=${wan_num:-1}
    
    WAN_IFACE=$(sed -n "${wan_num}p" "$IFACE_LIST")
    WAN_IP=$(ip -4 addr show dev "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}')
fi

# Если всё ещё нет IP - спрашиваем вручную
if [ -z "$WAN_IP" ]; then
    log ""
    warn "IP на WAN интерфейсе не найден"
    read -p "Введите IP адрес WAN (без маски): " WAN_IP
fi

ok "WAN: ${WHITE}$WAN_IFACE${NC} (${WAN_IP})"

# Убираем WAN из списка LAN
grep -v "^${WAN_IFACE}$" "$IFACE_LIST" > "${IFACE_LIST}.tmp" 2>/dev/null
mv "${IFACE_LIST}.tmp" "$IFACE_LIST" 2>/dev/null

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ СЕТЕЙ
#===============================================================================

sep
log "${WHITE}=== Автоопределение сетей OSPF ===${NC}"
sep
log ""

# Функция конвертации IP/mask в сеть
ip_to_net() {
    _ip_mask="$1"
    _ip=$(echo "$_ip_mask" | cut -d'/' -f1)
    _cidr=$(echo "$_ip_mask" | cut -d'/' -f2)
    
    if [ -z "$_ip" ] || [ -z "$_cidr" ]; then
        return
    fi
    
    # Разбираем октеты
    _o1=$(echo "$_ip" | cut -d'.' -f1)
    _o2=$(echo "$_ip" | cut -d'.' -f2)
    _o3=$(echo "$_ip" | cut -d'.' -f3)
    
    # Возвращаем сеть
    echo "${_o1}.${_o2}.${_o3}.0/${_cidr}"
}

# Сети с VLAN
if [ -s "$VLAN_LIST" ]; then
    log "${CYAN}VLAN интерфейсы:${NC}"
    while read -r vlan; do
        vlan_ip=$(ip -4 addr show dev "$vlan" 2>/dev/null | awk '/inet /{print $2}')
        if [ -n "$vlan_ip" ]; then
            vlan_net=$(ip_to_net "$vlan_ip")
            if [ -n "$vlan_net" ]; then
                echo "$vlan_net" >> "$NETWORKS_LIST"
                log "  ${GREEN}•${NC} $vlan: ${CYAN}$vlan_net${NC}"
            fi
        fi
    done < "$VLAN_LIST"
fi

# Сети с LAN
if [ -s "$IFACE_LIST" ]; then
    log "${CYAN}LAN интерфейсы:${NC}"
    while read -r iface; do
        lan_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}')
        if [ -n "$lan_ip" ]; then
            lan_net=$(ip_to_net "$lan_ip")
            if [ -n "$lan_net" ]; then
                if ! grep -q "^${lan_net}$" "$NETWORKS_LIST" 2>/dev/null; then
                    echo "$lan_net" >> "$NETWORKS_LIST"
                    log "  ${GREEN}•${NC} $iface: ${CYAN}$lan_net${NC}"
                fi
            fi
        fi
    done < "$IFACE_LIST"
fi

# Если сетей нет - спрашиваем
if [ ! -s "$NETWORKS_LIST" ]; then
    warn "Сети не найдены автоматически"
    log "${YELLOW}Введите сети для OSPF (через пробел):${NC}"
    log "  Пример: 192.168.10.0/26 192.168.20.0/28"
    read -p "Сети: " nets_input
    for net in $nets_input; do
        echo "$net" >> "$NETWORKS_LIST"
    done
fi

log ""
ok "Сети OSPF:"
while read -r net; do
    log "  ${GREEN}•${NC} $net"
done < "$NETWORKS_LIST"

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ - РУЧНОЙ ВВОД
#===============================================================================

sep
log "${WHITE}=== Настройка GRE туннеля ===${NC}"
sep
log ""

# Локальный IP для GRE
GRE_LOCAL=$(echo "$WAN_IP" | cut -d'/' -f1)

log "${CYAN}Локальный IP для GRE туннеля:${NC}"
log "  Автоопределено: ${GREEN}$GRE_LOCAL${NC}"
log ""
read -p "Использовать этот IP? (y/n) [y]: " use_auto_local
use_auto_local=${use_auto_local:-y}

if [ "$use_auto_local" != "y" ] && [ "$use_auto_local" != "Y" ]; then
    read -p "Введите локальный IP для GRE: " GRE_LOCAL
fi

ok "Локальный IP GRE: ${WHITE}$GRE_LOCAL${NC}"

# Удалённый IP
log ""
log "${YELLOW}Введите удалённый IP для GRE туннеля:${NC}"
log "  (IP адрес удалённого роутера для туннеля)"
read -p "Удалённый IP: " GRE_REMOTE

if [ -z "$GRE_REMOTE" ]; then
    err "Удалённый IP не указан!"
    exit 1
fi

ok "Удалённый IP GRE: ${WHITE}$GRE_REMOTE${NC}"

# IP адрес GRE интерфейса - РУЧНОЙ ВВОД
log ""
log "${YELLOW}Введите IP адрес для GRE интерфейса (туннель):${NC}"
log "  Примеры:"
log "    HQ-RTR: 172.16.1.1/24"
log "    BR-RTR: 172.16.1.2/24"
log "    Или любой другой: 10.0.0.1/30, 192.168.100.1/24"
log ""
read -p "GRE IP адрес с маской: " GRE_IP

if [ -z "$GRE_IP" ]; then
    warn "GRE IP не указан, используется по умолчанию"
    # Предлагаем выбор роли для дефолтного IP
    log ""
    log "${YELLOW}Выберите роль для стандартного GRE IP:${NC}"
    echo "  1) HQ-RTR (GRE IP: 172.16.1.1/24, Router ID: 1.1.1.1)"
    echo "  2) BR-RTR (GRE IP: 172.16.1.2/24, Router ID: 2.2.2.2)"
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
else
    # Если IP введён вручную - спрашиваем Router ID
    log ""
    log "${YELLOW}Введите Router ID для OSPF:${NC}"
    log "  Примеры: 1.1.1.1, 2.2.2.2, 3.3.3.3"
    read -p "Router ID [1.1.1.1]: " RID
    RID=${RID:-1.1.1.1}
    ROLE="Custom"
fi

ok "GRE IP: ${WHITE}$GRE_IP${NC}"
ok "Router ID: ${WHITE}$RID${NC}"

# Сеть GRE туннеля (автоопределение из GRE_IP)
GRE_NET=$(ip_to_net "$GRE_IP")
if [ -z "$GRE_NET" ]; then
    # Простой вариант - берём сеть как есть
    GRE_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
    GRE_CIDR=$(echo "$GRE_IP" | cut -d'/' -f2)
    GRE_NET="${GRE_BASE}.0/${GRE_CIDR}"
fi

log ""
ok "Сеть GRE туннеля: ${CYAN}$GRE_NET${NC}"

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
    err "Пакетный менеджер не найден"
    exit 1
fi

ok "FRR установлен"

#===============================================================================
# КОНФИГУРАЦИЯ DAEMONS
#===============================================================================

sep
log "${WHITE}=== Настройка FRR daemons ===${NC}"
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

ok "Daemons: zebra=yes, ospfd=yes"

#===============================================================================
# СОЗДАНИЕ GRE
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
REMOTE=${GRE_REMOTE}
LOCAL=${GRE_LOCAL}
TTL=64
DISABLE=no
GREOPT
    echo "${GRE_IP}" > /etc/net/ifaces/gre1/ipv4address
    ok "GRE в etcnet: /etc/net/ifaces/gre1"
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
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${GRE_LOCAL} remote ${GRE_REMOTE} ttl 64
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
ip tunnel add gre1 mode gre local "$GRE_LOCAL" remote "$GRE_REMOTE" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400

ok "GRE туннель поднят"

#===============================================================================
# КОНФИГУРАЦИЯ OSPF
#===============================================================================

sep
log "${WHITE}=== Настройка OSPF ===${NC}"
sep
log ""

cat > /etc/frr/frr.conf << OSPFHEAD
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
OSPFHEAD

# Добавляем сети
while read -r net; do
    echo " network $net area 0" >> /etc/frr/frr.conf
    log "  ${GREEN}+${NC} network $net area 0"
done < "$NETWORKS_LIST"

# GRE сеть
echo " network $GRE_NET area 0" >> /etc/frr/frr.conf
log "  ${GREEN}+${NC} network $GRE_NET area 0 (GRE)"

# Завершение
cat >> /etc/frr/frr.conf << 'OSPFEND'
!
line vty
!
OSPFEND

chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
chmod 640 /etc/frr/frr.conf 2>/dev/null

ok "OSPF настроен"

#===============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
#===============================================================================

sep
log "${WHITE}=== Системные настройки ===${NC}"
sep
log ""

# Удаляем дубликаты в sysctl.conf
grep -v '^net.ipv4.ip_forward=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null
grep -v '^net.ipv4.conf.all.rp_filter=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null
grep -v '^net.ipv4.conf.default.rp_filter=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null

# Добавляем настройки
cat >> /etc/sysctl.conf << 'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
ok "sysctl настроен"

#===============================================================================
# ЗАПУСК
#===============================================================================

sep
log "${WHITE}=== Запуск FRR ===${NC}"
sep
log ""

systemctl enable frr 2>/dev/null
systemctl restart frr 2>/dev/null
sleep 2

ok "FRR запущен"

#===============================================================================
# ПРОВЕРКА
#===============================================================================

sep
log "${WHITE}=== Проверка ===${NC}"
sep
log ""

if ip link show gre1 >/dev/null 2>&1; then
    ok "GRE: активен"
    ip -br addr show gre1 2>/dev/null || ip addr show gre1 2>/dev/null | head -2
else
    err "GRE: не поднят"
fi

log ""
log "${CYAN}OSPF соседи:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || warn "Нет соседей (подождите 30 сек)"

log ""
log "${CYAN}OSPF маршруты:${NC}"
ip route show | grep -i ospf 2>/dev/null || warn "Нет OSPF маршрутов"

#===============================================================================
# ИТОГ
#===============================================================================

log ""
log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
log "${GREEN}║${NC}            ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                        ${GREEN}║${NC}"
log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
log ""
log "${CYAN}Параметры:${NC}"
log "  Роль:       ${WHITE}$ROLE${NC}"
log "  Router ID:  ${WHITE}$RID${NC}"
log "  WAN:        ${WHITE}$WAN_IFACE${NC} ($WAN_IP)"
log "  GRE Local:  ${WHITE}$GRE_LOCAL${NC}"
log "  GRE Remote: ${WHITE}$GRE_REMOTE${NC}"
log "  GRE IP:     ${WHITE}$GRE_IP${NC}"
log "  GRE Net:    ${WHITE}$GRE_NET${NC}"
log ""
log "${CYAN}Сети OSPF:${NC}"
while read -r net; do
    log "  ${GREEN}•${NC} $net"
done < "$NETWORKS_LIST"
log "  ${GREEN}•${NC} $GRE_NET (GRE)"
log ""
log "${CYAN}Резервные копии:${NC}"
log "  ${YELLOW}$BACKUP_DIR${NC}"
log ""
log "${CYAN}Команды проверки:${NC}"
log "  ${YELLOW}vtysh -c 'show ip ospf neighbor'${NC}"
log "  ${YELLOW}ip route show | grep ospf${NC}"
log "  ${YELLOW}ping ${GRE_IP%%/*}${NC}"
log ""

rm -f "$IFACE_LIST" "$VLAN_LIST" "$NETWORKS_LIST"
log "${CYAN}Лог: ${LOG_FILE}${NC}"
log ""
