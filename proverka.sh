#!/bin/bash
#===============================================================================
# FRR OSPF + GRE Setup for ALT Linux
# Версия 4.0 - ГАРАНТИРОВАННАЯ ПЕРСИСТЕНТНОСТЬ
#===============================================================================
set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Пути
FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"
NET_DIR="/etc/net/ifaces"
BACKUP_DIR="/root/frr_backups"

# Логирование
log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    log_err "Запустите скрипт от root!"
    exit 1
fi

#===============================================================================
# ФУНКЦИИ ОЧИСТКИ
#===============================================================================
cleanup_all() {
    log_warn "Полная очистка предыдущих настроек..."
    
    # Очистка GRE
    ip link set gre1 down 2>/dev/null || true
    ip tunnel del gre1 2>/dev/null || true
    rm -rf "$NET_DIR/gre1" 2>/dev/null || true
    
    # Очистка FRR
    systemctl stop frr 2>/dev/null || true
    if [[ -f "$FRR_CONF" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp "$FRR_CONF" "$BACKUP_DIR/frr.conf.$(date +%Y%m%d_%H%M%S)"
    fi
    cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname FRR
log syslog informational
!
line vty
!
EOF
    
    if [[ -f "$FRR_DAEMONS" ]]; then
        sed -i 's/^ospfd=.*/ospfd=no/' "$FRR_DAEMONS"
        sed -i 's/^ospf6d=.*/ospf6d=no/' "$FRR_DAEMONS"
    fi
    
    log_ok "Очистка завершена"
}

#===============================================================================
# ОСНОВНАЯ НАСТРОЙКА
#===============================================================================
setup_frr() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  FRR OSPF/GRE Setup v4.0 (Persistent)    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    
    # 1. Проверка установки
    log_info "Проверка пакетов..."
    if ! command -v vtysh &>/dev/null; then
        log_info "Установка FRR..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y frr frr-pythontools >/dev/null 2>&1
        log_ok "FRR установлен"
    else
        log_ok "FRR уже установлен"
    fi
    
    # 2. Выбор роли
    echo -e "\n${YELLOW}=== Шаг 1: Идентификация роутера ===${NC}"
    HOST=$(hostname | tr '[:upper:]' '[:lower:]')
    case "$HOST" in
        *hq-rtr*) DEF_ROLE="HQ-RTR"; DEF_RID="1.1.1.1" ;;
        *br-rtr*) DEF_ROLE="BR-RTR"; DEF_RID="2.2.2.2" ;;
        *) DEF_ROLE="HQ-RTR"; DEF_RID="1.1.1.1" ;;
    esac
    
    echo "1) $DEF_ROLE (Router ID: $DEF_RID)"
    echo "2) Другая роль"
    read -p "Выбор [1]: " role_sel
    if [[ "$role_sel" == "2" ]]; then
        read -p "Введите роль: " ROLE
        read -p "Введите Router ID: " RID
    else
        ROLE="$DEF_ROLE"
        RID="$DEF_RID"
    fi
    log_ok "Роль: $ROLE, Router ID: $RID"
    
    # 3. Настройка GRE (Runtime + etcnet Persistence)
    echo -e "\n${YELLOW}=== Шаг 2: GRE Туннель ===${NC}"
    log_info "Доступные интерфейсы:"
    idx=1
    for iface in $(ls /sys/class/net/ | grep -v lo | grep -v gre); do
        ip_out=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        printf " %2d) %-8s %s\n" $idx "$iface" "$ip_out"
        echo "$iface" >> /tmp/_frr_ifaces
        idx=$((idx+1))
    done
    
    read -p "Номер внешнего интерфейса: " if_sel
    EXT_IF=$(sed -n "${if_sel}p" /tmp/_frr_ifaces)
    EXT_IP=$(ip -4 addr show "$EXT_IF" | grep -oP 'inet \K[\d.]+' | head -1)
    read -p "IP удаленного роутера: " REMOTE_IP
    
    if [[ "$ROLE" == "HQ-RTR" ]]; then DEF_GRE="172.16.100.1/29"; else DEF_GRE="172.16.100.2/29"; fi
    read -p "IP туннеля [$DEF_GRE]: " GRE_INPUT
    GRE_INPUT="${GRE_INPUT:-$DEF_GRE}"
    
    # Создаем etcnet конфиг для ПЕРСИСТЕНТНОСТИ
    log_info "Настройка etcnet для сохранения после ребута..."
    mkdir -p "$NET_DIR/gre1"
    cat > "$NET_DIR/gre1/options" << EOF
TYPE=gre
DISABLE=no
BOOTPROTO=static
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
    echo "$GRE_INPUT" > "$NET_DIR/gre1/ipv4address"
    touch "$NET_DIR/gre1/ipv4routes"
    chmod 644 "$NET_DIR/gre1/options" "$NET_DIR/gre1/ipv4address"
    log_ok "etcnet конфиг создан"
    
    # Поднимаем туннель сейчас
    ip link set gre1 down 2>/dev/null || true
    ip tunnel del gre1 2>/dev/null || true
    sleep 1
    ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64
    ip addr add "$GRE_INPUT" dev gre1
    ip link set gre1 up
    sleep 2
    ip link show gre1 &>/dev/null && log_ok "Туннель gre1 поднят" || log_err "Ошибка поднятия туннеля!"
    
    # 4. Настройка OSPF
    echo -e "\n${YELLOW}=== Шаг 3: OSPF Конфигурация ===${NC}"
    read -p "Пароль OSPF [P@ssw0rd]: " OSPF_PASS
    OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"
    
    log_info "Введите сети для OSPF (пустая строка = готово):"
    NETWORKS=""
    while true; do
        read -p "Сеть (CIDR): " net
        [[ -z "$net" ]] && break
        NETWORKS+=" network $net area 0\n"
    done
    [[ -z "$NETWORKS" ]] && NETWORKS=" network 0.0.0.0/0 area 0\n"
    
    # Генерация frr.conf
    log_info "Генерация конфигурации FRR..."
    cat > "$FRR_CONF" << EOF
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id $RID
 passive-interface default
 no passive-interface gre1
 ip ospf authentication
 ip ospf authentication-key $OSPF_PASS
$(echo -e "$NETWORKS" | sed 's/^/ /')
!
line vty
!
EOF
    chmod 644 "$FRR_CONF"
    log_ok "frr.conf создан"
    
    # 5. ПРИМЕНЕНИЕ И ПЕРСИСТЕНТНОСТЬ (КЛЮЧЕВОЙ БЛОК)
    echo -e "\n${MAGENTA}=== Сохранение для перезагрузки ===${NC}"
    
    # Включаем демоны
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        cat > "$FRR_DAEMONS" << 'EOF'
zebra=yes
bgpd=no
ospfd=yes
ospf6d=no
ripd=no
ripng=no
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
EOF
    else
        sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
        sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
    fi
    log_ok "ospfd=yes и zebra=yes в daemons"
    
    # Перезапуск для применения
    log_info "Перезапуск FRR..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart frr
    sleep 3
    
    # Сохранение running-config в файл (гарантия персистентности)
    if systemctl is-active frr &>/dev/null; then
        vtysh -c "write memory" 2>/dev/null && log_ok "Конфиг сохранен: write memory"
        cp "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null || true
    else
        log_err "FRR не запустился! Проверьте конфиг."
        systemctl status frr --no-pager
        exit 1
    fi
    
    # Включение автозапуска
    systemctl enable frr 2>/dev/null || true
    systemctl enable net 2>/dev/null || true
    log_ok "Автозапуск frr и net включен"
    
    # 6. ФИНАЛЬНАЯ ПРОВЕРКА
    echo -e "\n${CYAN}=== ИТОГОВАЯ ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"
    local all_ok=true
    
    check_item() {
        if eval "$2" &>/dev/null; then
            echo -e " ${GREEN}✓${NC} $1"
        else
            echo -e " ${RED}✗${NC} $1"
            all_ok=false
        fi
    }
    
    check_item "frr.service enabled" "systemctl is-enabled frr"
    check_item "net.service enabled" "systemctl is-enabled net"
    check_item "ospfd=yes в daemons" "grep -q '^ospfd=yes' $FRR_DAEMONS"
    check_item "gre1 DISABLE=no" "grep -q 'DISABLE=no' $NET_DIR/gre1/options"
    check_item "vtysh.conf синхронизирован" "cmp -s $FRR_CONF /etc/frr/vtysh.conf"
    check_item "OSPF активен" "vtysh -c 'show ip ospf' | grep -q 'Routing Process'"
    
    echo ""
    if $all_ok; then
        echo -e "${GREEN}══════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!            ║${NC}"
        echo -e "${GREEN}║  Данные сохранены и переживут ребут!     ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}[!] Некоторые проверки не прошли. Проверьте логи.${NC}"
    fi
    
    echo -e "\n${WHITE}Команды для проверки:${NC}"
    echo " vtysh -c 'show ip ospf neighbor'"
    echo " vtysh -c 'show ip route ospf'"
    echo " ip link show gre1"
    echo " systemctl status frr"
}

#===============================================================================
# МЕНЮ
#===============================================================================
while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  FRR OSPF/GRE Setup v4.0                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo " 1) Настроить FRR (OSPF + GRE)"
    echo " 2) Полная очистка"
    echo " 3) Показать текущую конфигурацию"
    echo " 4) Проверить персистентность"
    echo " 5) Выход"
    read -p "Выбор: " menu_sel
    
    case $menu_sel in
        1) setup_frr; read -p "Нажмите Enter..." ;;
        2) cleanup_all; read -p "Нажмите Enter..." ;;
        3) 
            echo -e "\n${WHITE}=== frr.conf ===${NC}"
            cat "$FRR_CONF" 2>/dev/null || echo "Не найден"
            echo -e "\n${WHITE}=== Соседи OSPF ===${NC}"
            vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не активен"
            read -p "Нажмите Enter..."
            ;;
        4)
            echo -e "\n${CYAN}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"
            systemctl is-enabled frr &>/dev/null && echo -e "${GREEN}✓${NC} frr автозапуск" || echo -e "${RED}✗${NC} frr"
            systemctl is-enabled net &>/dev/null && echo -e "${GREEN}✓${NC} net автозапуск" || echo -e "${RED}✗${NC} net"
            grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null && echo -e "${GREEN}✓${NC} ospfd=yes" || echo -e "${RED}✗${NC} ospfd"
            grep -q 'DISABLE=no' "$NET_DIR/gre1/options" 2>/dev/null && echo -e "${GREEN}✓${NC} gre1 DISABLE=no" || echo -e "${RED}${NC} gre1"
            cmp -s "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null && echo -e "${GREEN}✓${NC} vtysh.conf синхронизирован" || echo -e "${RED}✗${NC} vtysh.conf"
            read -p "Нажмите Enter..."
            ;;
        5) exit 0 ;;
        *) log_err "Неверный выбор" ;;
    esac
done
