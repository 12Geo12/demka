#!/bin/bash

################################################################################
#                                                                              #
#                  OPEN vSWITCH VLAN CONFIGURATION TOOL                        #
#                                                                              #
#  All-in-One скрипт для настройки и управления VLAN в Open vSwitch           #
#  Поддержка: ALT Linux Server, Ubuntu, Debian, CentOS, Fedora                #
#                                                                              #
################################################################################

VERSION="2.2.0"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Глобальные переменные
BRIDGE_NAME="br0"
CONFIG_FILE="/etc/ovs-vlan-config.conf"
LOG_FILE="/var/log/ovs-vlan.log"
SERVICE_FILE="/etc/systemd/system/ovs-vlan-restore.service"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="ovs-vlan.sh"

# Определение дистрибутива
DISTRO=$(
    if [[ -f /etc/altlinux-release ]]; then echo "alt"
    elif [[ -f /etc/debian_version ]]; then echo "debian"
    elif [[ -f /etc/centos-release ]] || [[ -f /etc/redhat-release ]]; then echo "centos"
    elif [[ -f /etc/fedora-release ]]; then echo "fedora"
    else echo "unknown"
    fi
)

################################################################################
#                              ВЫВОД                                           #
################################################################################

print_header() {
    clear
    echo -e "${CYAN}"
    cat << 'LOGO'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║     ██████╗ ██████╗  ██████╗ ██████╗     █████╗   ██╗██╗   ██╗            ║
║    ██╔════╝██╔═══██╗██╔════╝██╔════╝    ██╔══██╗ ██║██║   ██║            ║
║    ██║     ██║   ██║██║     ██║         ███████║██║██║   ██║            ║
║    ██║     ██║   ██║██║     ██║         ██╔══██║██║╚██╗ ██╔╝            ║
║    ╚██████╗╚██████╔╝╚██████╗╚██████╗    ██║  ██║██║ ╚████╔╝             ║
║     ╚═════╝ ╚═════╝  ╚═════╝ ╚═════╝    ╚═╝  ╚═╝╚═╝  ╚═══╝              ║
║                                                                           ║
║                    VLAN Configuration Tool                                ║
LOGO
    echo -e "║                    Версия ${VERSION}                                       ║"
    echo -e "║                    Дистрибутив: ${DISTRO^^}                           ║"
    echo -e "╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_sep() { echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"; }
print_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
print_err() { echo -e "${RED}[✗]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_inf() { echo -e "${BLUE}[i]${NC} $1"; }
print_step() { echo -e "\n${CYAN}[ШАГ $1]${NC} ${BOLD}$2${NC}"; print_sep; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

################################################################################
#                              ПРОВЕРКИ                                        #
################################################################################

check_root() {
    [[ $EUID -ne 0 ]] && { print_err "Запустите с правами root: su - -c '$0 $@'"; exit 1; }
}

check_ovs_installed() { command -v ovs-vsctl &>/dev/null; }

check_ovs_running() {
    systemctl is-active --quiet openvswitch 2>/dev/null || \
    systemctl is-active --quiet openvswitch-switch 2>/dev/null || \
    systemctl is-active --quiet ovs-vswitchd 2>/dev/null
}

################################################################################
#                              УСТАНОВКА OVS                                   #
################################################################################

install_ovs() {
    print_inf "Установка Open vSwitch..."
    case "$DISTRO" in
        alt)     apt-get update && apt-get install -y openvswitch ;;
        debian)  apt-get update && apt-get install -y openvswitch-switch openvswitch-common ;;
        centos)  yum install -y openvswitch ;;
        fedora)  dnf install -y openvswitch ;;
        *)       print_err "Неизвестный дистрибутив"; return 1 ;;
    esac
    
    systemctl daemon-reload
    systemctl enable openvswitch 2>/dev/null || systemctl enable openvswitch-switch 2>/dev/null
    systemctl start openvswitch 2>/dev/null || systemctl start openvswitch-switch 2>/dev/null
}

start_ovs_service() {
    local svc="openvswitch"
    [[ "$DISTRO" == "debian" ]] && svc="openvswitch-switch"
    systemctl start "$svc" 2>/dev/null || systemctl start ovs-vswitchd 2>/dev/null
}

ensure_ovs() {
    if ! check_ovs_installed; then
        print_warn "Open vSwitch не установлен"
        echo -e "${YELLOW}Установить? [Y/n]:${NC}"; read -p "> " ans
        [[ "$ans" =~ ^[Nn]$ ]] && { print_err "OVS необходим"; exit 1; }
        install_ovs
    else
        print_ok "Open vSwitch установлен"
    fi
    
    check_ovs_running || { print_warn "Запуск сервиса..."; start_ovs_service; }
    print_ok "Сервис Open vSwitch запущен"
}

################################################################################
#                         ПОЛУЧЕНИЕ ИНФОРМАЦИИ                                 #
################################################################################

get_interfaces() {
    local ifaces=()
    for i in $(ls /sys/class/net/); do
        [[ "$i" != "lo" ]] && [[ ! "$i" =~ ^docker ]] && [[ ! "$i" =~ ^veth ]] && \
        [[ ! "$i" =~ ^br- ]] && [[ ! "$i" =~ ^ovs ]] && [[ ! "$i" == "$BRIDGE_NAME" ]] && \
        [[ -d "/sys/class/net/$i" ]] && { [[ -d "/sys/class/net/$i/device" ]] || [[ "$i" =~ \. ]]; } && \
        ifaces+=("$i")
    done
    echo "${ifaces[@]}"
}

get_iface_info() {
    local i=$1 info=""
    local ip=$(ip -4 addr show "$i" 2>/dev/null | grep -oP 'inet \K[\d.]+')
    [[ -n "$ip" ]] && info+="IP: ${GREEN}$ip${NC}" || info+="IP: ${YELLOW}--${NC}"
    info+=" | MAC: $(cat /sys/class/net/$i/address 2>/dev/null)"
    [[ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" == "up" ]] && info+=" | ${GREEN}UP${NC}" || info+=" | ${RED}DOWN${NC}"
    local s=$(cat /sys/class/net/$i/speed 2>/dev/null); [[ -n "$s" && "$s" != "-1" ]] && info+=" | ${s}Mbps"
    [[ "$i" =~ \.([0-9]+)$ ]] && info+=" | ${CYAN}VLAN: ${BASH_REMATCH[1]}${NC}"
    echo "$info"
}

get_vlan_ip() { ip -4 addr show "$1" 2>/dev/null | grep -oP 'inet \K[\d./]+'; }

detect_vlans() {
    local trunk=$1 vlans=()
    for i in $(ls /sys/class/net/ 2>/dev/null); do
        [[ "$i" =~ ^${trunk}\.([0-9]+)$ ]] && vlans+=("${BASH_REMATCH[1]}:$i:$(get_vlan_ip $i)")
    done
    echo "${vlans[@]}"
}

################################################################################
#                         КОНФИГУРАЦИЯ OVS                                     #
################################################################################

create_bridge() {
    print_inf "Настройка моста $BRIDGE_NAME..."
    if ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null; then
        print_warn "Мост уже существует. Пересоздать? [y/N]:"; read -p "> " ans
        [[ "$ans" =~ ^[Yy]$ ]] && { ovs-vsctl del-br "$BRIDGE_NAME"; ovs-vsctl add-br "$BRIDGE_NAME"; }
    else
        ovs-vsctl add-br "$BRIDGE_NAME"
    fi
    print_ok "Мост $BRIDGE_NAME готов"
}

config_trunk() {
    local iface=$1 vlans=$2
    print_inf "Настройка trunk $iface..."
    ovs-vsctl --if-exists del-port "$BRIDGE_NAME" "$iface"
    ovs-vsctl add-port "$BRIDGE_NAME" "$iface"
    [[ -n "$vlans" ]] && ovs-vsctl set port "$iface" trunks="$vlans"
    print_ok "Trunk: $iface (VLAN: ${vlans:-all})"
}

config_access() {
    local iface=$1 vlan=$2
    print_inf "Настройка access $iface → VLAN $vlan..."
    ovs-vsctl --if-exists del-port "$BRIDGE_NAME" "$iface"
    ovs-vsctl add-port "$BRIDGE_NAME" "$iface"
    ovs-vsctl set port "$iface" tag="$vlan"
    ip link set "$iface" up 2>/dev/null
    print_ok "Access: $iface (VLAN $vlan)"
}

migrate_ip() {
    local from=$1 to=$2
    local ip=$(get_vlan_ip "$from")
    [[ -z "$ip" ]] && { print_warn "IP не найден на $from"; return 1; }
    print_inf "Миграция IP $ip: $from → $to..."
    ip addr del "$ip" dev "$from" 2>/dev/null
    ip addr add "$ip" dev "$to" 2>/dev/null
    ip link set "$to" up
    print_ok "IP $ip перенесён на $to"
}

save_config() {
    local trunk=$1; shift
    local vlans=("$@")
    cat > "$CONFIG_FILE" << EOF
# OVS VLAN Config | $(date) | $DISTRO
BRIDGE_NAME=$BRIDGE_NAME
TRUNK_INTERFACE=$trunk
DISTRO=$DISTRO
EOF
    local n=1
    for v in "${vlans[@]}"; do
        IFS=':' read -r vid vif ip acc <<< "$v"
        echo "VLAN_${n}_ID=$vid" >> "$CONFIG_FILE"
        echo "VLAN_${n}_ACCESS=$acc" >> "$CONFIG_FILE"
        ((n++))
    done
    print_ok "Конфигурация: $CONFIG_FILE"
}

################################################################################
#                         ИНТЕРАКТИВНОЕ МЕНЮ                                   #
################################################################################

show_ifaces() {
    local ifaces=($(get_interfaces))
    [[ ${#ifaces[@]} -eq 0 ]] && { print_err "Интерфейсы не найдены"; exit 1; }
    echo ""
    printf "${CYAN}%-4s %-15s %s${NC}\n" "#" "Интерфейс" "Информация"
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    local n=1
    for i in "${ifaces[@]}"; do printf "%-4s %-15s %b\n" "[$n]" "$i" "$(get_iface_info $i)"; ((n++)); done
    echo ""
}

select_iface() {
    local prompt=$1 exclude=$2
    local ifaces=($(get_interfaces))
    while true; do
        echo -e "${YELLOW}$prompt${NC}"; read -p "> " c
        [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 ]] && [[ "$c" -le ${#ifaces[@]} ]] && \
        [[ "${ifaces[$((c-1))]}" != "$exclude" ]] && { echo "${ifaces[$((c-1))]}"; return 0; }
        print_err "Неверный выбор"
    done
}

show_vlans() {
    local vlans=("$@")
    echo ""
    printf "${CYAN}%-4s %-8s %-15s %-20s${NC}\n" "#" "VLAN" "Интерфейс" "IP"
    echo -e "${BLUE}────────────────────────────────────────────────────${NC}"
    local n=1
    for v in "${vlans[@]}"; do
        IFS=':' read -r vid vif ip <<< "$v"
        printf "%-4s %-8s %-15s %-20s\n" "[$n]" "$vid" "$vif" "${ip:---}"
        ((n++))
    done
    printf "%-4s %s\n" "[$n]" "Добавить VLAN вручную"
    printf "%-4s %s\n" "[0]" "Готово"
    echo ""
}

################################################################################
#                         ОСНОВНАЯ НАСТРОЙКА                                   #
################################################################################

do_setup() {
    print_header
    print_inf "Дистрибутив: ${DISTRO^^}"
    
    print_step 1 "Проверка системы"
    ensure_ovs
    
    print_step 2 "Выбор Trunk порта"
    echo -e "${BOLD}Порт от роутера (принимает все VLAN)${NC}"
    show_ifaces
    TRUNK=$(select_iface "Trunk порт:")
    print_ok "Trunk: $TRUNK"
    
    print_step 3 "Настройка VLAN"
    local detected=($(detect_vlans "$TRUNK"))
    [[ ${#detected[@]} -eq 0 ]] && { print_warn "VLAN не найдены"; detected+=("manual::"); }
    
    declare -a CONFIGS USED
    USED+=("$TRUNK")
    
    while true; do
        show_vlans "${detected[@]}"
        local max=$((${#detected[@]}+1))
        echo -e "${YELLOW}Выбор [0-$max]:${NC}"; read -p "> " c
        
        [[ "$c" == "0" ]] && break
        
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 ]] && [[ "$c" -le ${#detected[@]} ]]; then
            IFS=':' read -r vid vif ip <<< "${detected[$((c-1))]}"
            echo -e "\n${BOLD}VLAN $vid → Access порт${NC}"
            show_ifaces
            local acc=$(select_iface "Access порт:" "$TRUNK")
            [[ " ${USED[@]} " =~ " $acc " ]] && { print_err "$acc занят"; continue; }
            
            [[ -n "$ip" ]] && { echo -e "${YELLOW}Перенести IP $ip на $acc? [Y/n]:${NC}"; read -p "> " m; \
                [[ ! "$m" =~ ^[Nn]$ ]] && migrate_ip "$vif" "$acc"; }
            
            CONFIGS+=("$vid:$vif:$ip:$acc")
            USED+=("$acc")
            print_ok "VLAN $vid → $acc"
            
        elif [[ "$c" -eq $max ]]; then
            echo -e "\n${CYAN}Новый VLAN:${NC}"
            read -p "Номер VLAN: " vid
            read -p "IP (192.168.x.x/24): " ip
            show_ifaces
            local acc=$(select_iface "Access порт:" "$TRUNK")
            [[ -n "$ip" ]] && { echo -e "${YELLOW}Добавить IP $ip? [Y/n]:${NC}"; read -p "> " m; \
                [[ ! "$m" =~ ^[Nn]$ ]] && { ip addr add "$ip" dev "$acc"; ip link set "$acc" up; }; }
            CONFIGS+=("$vid:manual:$ip:$acc")
            USED+=("$acc")
            detected+=("$vid:manual:$ip")
            print_ok "VLAN $vid добавлен"
        fi
    done
    
    print_step 4 "Интернет (native VLAN)"
    echo -e "${YELLOW}Настроить untagged трафик? [y/N]:${NC}"; read -p "> " inet
    [[ "$inet" =~ ^[Yy]$ ]] && print_inf "Native VLAN активирован"
    
    print_step 5 "Применение"
    create_bridge
    
    local vlist=""
    for v in "${CONFIGS[@]}"; do IFS=':' read -r vid _ _ _ <<< "$v"; vlist+="$vid,"; done
    vlist="${vlist%,}"
    
    config_trunk "$TRUNK" "$vlist"
    for v in "${CONFIGS[@]}"; do IFS=':' read -r vid _ _ acc <<< "$v"; config_access "$acc" "$vid"; done
    
    save_config "$TRUNK" "${CONFIGS[@]}"
    
    print_step 6 "Результат"
    show_status
    
    echo -e "\n${YELLOW}Установить автозагрузку? [Y/n]:${NC}"; read -p "> " sv
    [[ ! "$sv" =~ ^[Nn]$ ]] && do_install_service
    
    echo -e "\n${GREEN}✓ Настройка завершена!${NC}\n"
}

################################################################################
#                         КОМАНДЫ УПРАВЛЕНИЯ                                   #
################################################################################

show_status() {
    echo -e "${BOLD}${CYAN}Bridge:${NC}"
    ovs-vsctl list-br 2>/dev/null | while read b; do echo -e "  ${GREEN}●${NC} $b"; done
    
    echo -e "\n${BOLD}${CYAN}Ports:${NC}"
    ovs-vsctl show 2>/dev/null | grep -E "Bridge|Port \"[a-z]" | while read l; do
        if [[ "$l" =~ Bridge ]]; then echo -e "\n${YELLOW}$l${NC}"
        else
            local p=$(echo "$l" | grep -oP 'Port "\K[^"]+')
            local t=$(ovs-vsctl get port "$p" tag 2>/dev/null)
            local tr=$(ovs-vsctl get port "$p" trunks 2>/dev/null)
            [[ "$t" != "[]" ]] && [[ -n "$t" ]] && echo -e "  ${GREEN}●${NC} $p ${CYAN}(Access: $t)${NC}" || \
            [[ "$tr" != "[]" ]] && [[ -n "$tr" ]] && echo -e "  ${GREEN}●${NC} $p ${MAGENTA}(Trunk: $tr)${NC}" || \
            echo -e "  ${GREEN}●${NC} $p"
        fi
    done
    echo ""
}

show_mac() {
    echo -e "${BOLD}${CYAN}MAC Table:${NC}\n"
    printf "${YELLOW}%-6s %-20s %-15s${NC}\n" "VLAN" "MAC" "Port"
    ovs-appctl fdb/show "$BRIDGE_NAME" 2>/dev/null | tail -n +2
    echo ""
}

show_flows() {
    echo -e "${BOLD}${CYAN}OpenFlow Rules:${NC}\n"
    ovs-ofctl dump-flows "$BRIDGE_NAME" 2>/dev/null | head -15
    echo ""
}

show_stats() {
    echo -e "${BOLD}${CYAN}Statistics:${NC}\n"
    for p in $(ovs-vsctl list-ports "$BRIDGE_NAME" 2>/dev/null); do
        echo -e "${YELLOW}$p:${NC}"
        ovs-vsctl get interface "$p" statistics 2>/dev/null | tr ',' '\n' | head -6
        echo ""
    done
}

add_vlan() {
    local vid=$1 port=$2 trunk=$3
    [[ -z "$vid" || -z "$port" ]] && { print_err "Usage: $0 add-vlan <id> <port> [trunk]"; return 1; }
    config_access "$port" "$vid"
    [[ -n "$trunk" ]] && { local cur=$(ovs-vsctl get port "$trunk" trunks 2>/dev/null); cur=${cur//[\[\]]/}; \
        [[ -n "$cur" ]] && ovs-vsctl set port "$trunk" trunks="$cur,$vid" || ovs-vsctl set port "$trunk" trunks="$vid"; }
    print_ok "VLAN $vid добавлен на $port"
}

remove_vlan() {
    local vid=$1
    [[ -z "$vid" ]] && { print_err "Usage: $0 remove-vlan <id>"; return 1; }
    for p in $(ovs-vsctl list-ports "$BRIDGE_NAME"); do
        [[ "$(ovs-vsctl get port "$p" tag 2>/dev/null)" == "$vid" ]] && { ovs-vsctl del-port "$BRIDGE_NAME" "$p"; print_inf "Удалён $p"; }
    done
    for p in $(ovs-vsctl list-ports "$BRIDGE_NAME"); do
        local tr=$(ovs-vsctl get port "$p" trunks 2>/dev/null)
        [[ "$tr" != "[]" ]] && [[ "$tr" =~ $vid ]] && { tr=${tr//[\[\]]/}; tr=${tr//$vid/}; tr=${tr//,,/,}; tr=${tr%,}; tr=${tr#,}; \
            ovs-vsctl set port "$p" trunks="$tr" 2>/dev/null; }
    done
    print_ok "VLAN $vid удалён"
}

monitor() {
    local if=$1
    [[ -z "$if" ]] && { echo -e "${CYAN}Порты:${NC}"; ovs-vsctl list-ports "$BRIDGE_NAME"; read -p "Интерфейс: " if; }
    command -v tcpdump &>/dev/null || { print_warn "Установка tcpdump..."; \
        case "$DISTRO" in alt|debian) apt-get install -y tcpdump ;; centos) yum install -y tcpdump ;; fedora) dnf install -y tcpdump ;; esac; }
    print_inf "Мониторинг $if (Ctrl+C)..."
    tcpdump -i "$if" -n -e "not port 22"
}

reset() {
    echo -e "${RED}Сбросить всю конфигурацию OVS? [y/N]:${NC}"; read -p "> " c
    [[ "$c" =~ ^[Yy]$ ]] && { ovs-vsctl del-br "$BRIDGE_NAME" 2>/dev/null; rm -f "$CONFIG_FILE"; print_ok "Сброшено"; }
}

################################################################################
#                         СЕРВИС                                               #
################################################################################

get_svc_name() { [[ "$DISTRO" == "debian" ]] && echo "openvswitch-switch.service" || echo "openvswitch.service"; }

do_install_service() {
    local sp="$INSTALL_DIR/$SCRIPT_NAME"
    [[ ! -f "$sp" ]] && { print_inf "Установка скрипта..."; cp "${BASH_SOURCE[0]}" "$sp"; chmod +x "$sp"; }
    print_inf "Создание systemd сервиса..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=OVS VLAN Restore
After=network.target $(get_svc_name)
Requires=$(get_svc_name)

[Service]
Type=oneshot
ExecStart=$sp restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ovs-vlan-restore
    print_ok "Сервис установлен"
}

do_remove_service() {
    systemctl disable ovs-vlan-restore 2>/dev/null; rm -f "$SERVICE_FILE"; systemctl daemon-reload
    print_ok "Сервис удалён"
}

do_restore() {
    [[ ! -f "$CONFIG_FILE" ]] && { log "Нет конфигурации"; exit 0; }
    log "Восстановление..."
    source "$CONFIG_FILE"
    sleep 2
    ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null || ovs-vsctl add-br "$BRIDGE_NAME"
    local n=1
    while true; do
        local v="VLAN_${n}_ID"; local a="VLAN_${n}_ACCESS"
        [[ -z "${!v}" ]] && break
        ovs-vsctl --if-exists del-port "$BRIDGE_NAME" "${!a}"
        ovs-vsctl add-port "$BRIDGE_NAME" "${!a}"
        ovs-vsctl set port "${!a}" tag="${!v}"
        ip link set "${!a}" up 2>/dev/null
        ((n++))
    done
    [[ -n "$TRUNK_INTERFACE" ]] && { ovs-vsctl --if-exists del-port "$BRIDGE_NAME" "$TRUNK_INTERFACE"
        ovs-vsctl add-port "$BRIDGE_NAME" "$TRUNK_INTERFACE"
        local vl=""; n=1
        while true; do local v="VLAN_${n}_ID"; [[ -z "${!v}" ]] && break; vl+="${!v},"; ((n++)); done
        [[ -n "$vl" ]] && ovs-vsctl set port "$TRUNK_INTERFACE" trunks="${vl%,}"; }
    log "Готово"
}

do_install() {
    print_inf "Установка в $INSTALL_DIR..."
    cp "${BASH_SOURCE[0]}" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    print_ok "Установлено: $INSTALL_DIR/$SCRIPT_NAME"
    echo -e "${YELLOW}Автозагрузка? [Y/n]:${NC}"; read -p "> " c
    [[ ! "$c" =~ ^[Nn]$ ]] && do_install_service
}

do_uninstall() {
    do_remove_service
    rm -f "$INSTALL_DIR/$SCRIPT_NAME" "$CONFIG_FILE"
    print_ok "Удалено"
}

################################################################################
#                         СПРАВКА                                              #
################################################################################

show_help() {
    print_header
    cat << EOF
${BOLD}ИСПОЛЬЗОВАНИЕ:${NC} $0 <команда> [аргументы]

${BOLD}НАСТРОЙКА:${NC}
  setup              Интерактивная настройка (по умолчанию)
  add-vlan <id> <port> [trunk]   Добавить VLAN
  remove-vlan <id>   Удалить VLAN
  reset              Сбросить конфигурацию

${BOLD}МОНИТОРИНГ:${NC}
  status             Статус OVS
  mac                MAC таблица
  flows              OpenFlow правила
  stats              Статистика
  monitor [iface]    Трафик

${BOLD}СИСТЕМА:${NC}
  install            Установить в систему
  uninstall          Удалить
  install-service    Автозагрузка
  restore            Восстановить (для systemd)

${BOLD}ПРИМЕРЫ:${NC}
  su - -c '$0'                    # Настройка
  su - -c '$0 add-vlan 100 eth1'  # Добавить VLAN
  $0 status                       # Статус

${BOLD}ДИСТРИБУТИВЫ:${NC} ALT, Ubuntu, Debian, CentOS, Fedora

${BOLD}ФАЙЛЫ:${NC}
  $CONFIG_FILE    Конфигурация
  $SERVICE_FILE   Systemd unit

EOF
}

################################################################################
#                         ТОЧКА ВХОДА                                          #
################################################################################

cmd=${1:-setup}; shift 2>/dev/null || true

case "$cmd" in
    setup|'') check_root "$cmd"; do_setup ;;
    status)   show_status ;;
    mac)      show_mac ;;
    flows)    show_flows ;;
    stats)    show_stats ;;
    add-vlan) check_root "$cmd"; add_vlan "$@" ;;
    remove-vlan) check_root "$cmd"; remove_vlan "$@" ;;
    monitor)  monitor "$@" ;;
    reset)    check_root "$cmd"; reset ;;
    install)  check_root "$cmd"; do_install ;;
    uninstall) check_root "$cmd"; do_uninstall ;;
    install-service) check_root "$cmd"; do_install_service ;;
    remove-service) check_root "$cmd"; do_remove_service ;;
    restore)  check_root "$cmd"; do_restore ;;
    help|--help|-h) show_help ;;
    *)        print_err "Неизвестная команда: $cmd"; show_help; exit 1 ;;
esac
