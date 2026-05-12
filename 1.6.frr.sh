#!/bin/bash

#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# Версия 3.4 - Исправлен синтаксис для совместимости
#===============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"
BACKUP_DIR="/root/frr_backups"

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Функции логирования
print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_err() { echo -e "${RED}[X]${NC} $1"; }

#===============================================================================
# ФУНКЦИЯ СОХРАНЕНИЯ КОНФИГУРАЦИИ FRR
#===============================================================================
save_frr_config() {
    print_msg "Сохранение конфигурации FRR..."
    
    # Метод 1: vtysh write memory
    if command -v vtysh &>/dev/null; then
        if vtysh -c "write memory" 2>/dev/null; then
            print_ok "Конфигурация сохранена через 'write memory'"
            return 0
        fi
    fi
    
    # Метод 2: Копируем frr.conf в vtysh.conf
    if [[ -f "$FRR_CONF" ]]; then
        cp "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null || true
        print_ok "Конфигурация скопирована в vtysh.conf"
    fi
    
    # Метод 3: Перезапускаем FRR
    systemctl restart frr 2>/dev/null || true
    print_ok "FRR перезапущен"
}

#===============================================================================
# ФУНКЦИЯ ОЧИСТКИ
#===============================================================================
cleanup_gre() {
    print_msg "Очистка старых настроек GRE..."
    ip link set gre1 down 2>/dev/null || true
    sleep 1
    ip tunnel del gre1 2>/dev/null || true
    sleep 1
    rm -rf "$IFACES_DIR/gre1" 2>/dev/null || true
    print_ok "GRE туннель очищен"
}

cleanup_frr() {
    print_msg "Сброс конфигурации FRR..."
    
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
    
    systemctl restart frr 2>/dev/null || true
    print_ok "FRR сброшен"
}

full_cleanup() {
    echo -e "\n${YELLOW}=== ПОЛНАЯ ОЧИСТКА ===${NC}"
    cleanup_gre
    cleanup_frr
    echo -e "${GREEN}Все настройки удалены!${NC}"
}

#===============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#===============================================================================
extract_ip_only() { echo "$1" | cut -d'/' -f1; }
extract_cidr() { 
    if [[ "$1" == *"/"* ]]; then 
        echo "$1" | cut -d'/' -f2
    else 
        echo "24"
    fi
}

#===============================================================================
# ФУНКЦИЯ ДОБАВЛЕНИЯ СЕТЕЙ
#===============================================================================
add_networks_manual() {
    local networks=""
    echo -e "\n${YELLOW}=== Добавление сетей для OSPF ===${NC}"
    echo ""
    echo "Вводите сети в формате: 192.168.10.0/24"
    echo "Пустая строка = завершить"
    echo "--------------------------------"
    
    while true; do
        read -p "Сеть (Enter = готово): " net
        [[ -z "$net" ]] && break
        if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            networks+=" network $net area 0\n"
            print_ok "Добавлена: $net"
        else
            print_warn "Неверный формат!"
        fi
    done
    
    [[ -z "$networks" ]] && print_warn "Сети не добавлены"
    echo -e "$networks"
}

#===============================================================================
# ВКЛЮЧЕНИЕ OSPF В DAEMONS
#===============================================================================
enable_ospf_daemon() {
    print_msg "Настройка /etc/frr/daemons..."
    
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        cat > "$FRR_DAEMONS" << 'EOF'
# FRR daemons configuration
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
        if grep -q '^ospfd=' "$FRR_DAEMONS"; then
            sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
        else
            echo "ospfd=yes" >> "$FRR_DAEMONS"
        fi
        if grep -q '^zebra=' "$FRR_DAEMONS"; then
            sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
        else
            echo "zebra=yes" >> "$FRR_DAEMONS"
        fi
    fi
    print_ok "ospfd=yes установлен"
}

#===============================================================================
# ОСНОВНАЯ НАСТРОЙКА
#===============================================================================
setup_frr() {
    # === ОЧИСТКА ===
    echo -e "\n${YELLOW}=== Очистка старых настроек ===${NC}"
    read -p "Удалить предыдущие настройки? [y/N]: " cleanup_ans
    if [[ "$cleanup_ans" =~ ^[Yy]$ ]]; then
        full_cleanup
        sleep 2
    fi
    
    # === УСТАНОВКА ===
    print_msg "Проверка FRR..."
    if ! command -v vtysh &>/dev/null; then
        print_msg "Установка FRR..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y frr >/dev/null 2>&1
        print_ok "FRR установлен"
    else
        print_ok "FRR уже установлен"
    fi
    
    # === РОЛЬ ===
    echo -e "\n${YELLOW}=== Шаг 1: Идентификация ===${NC}"
    HOST=$(hostname | tr '[:upper:]' '[:lower:]')
    
    case "$HOST" in
        *hq-rtr*) DEFAULT_ROLE="HQ-RTR"; DEFAULT_RID="1.1.1.1" ;;
        *br-rtr*) DEFAULT_ROLE="BR-RTR"; DEFAULT_RID="2.2.2.2" ;;
        *) DEFAULT_ROLE="HQ-RTR"; DEFAULT_RID="1.1.1.1" ;;
    esac
    
    echo "1) HQ-RTR (Router ID: 1.1.1.1)"
    echo "2) BR-RTR (Router ID: 2.2.2.2)"
    echo "3) Другая роль"
    read -p "Выбор [1]: " role_choice
    
    case $role_choice in
        2) ROLE="BR-RTR"; RID="2.2.2.2" ;;
        3) read -p "Роль: " ROLE; read -p "Router ID: " RID ;;
        *) ROLE="HQ-RTR"; RID="1.1.1.1" ;;
    esac
    print_ok "Роль: $ROLE, Router ID: $RID"
    
    # === GRE ТУННЕЛЬ ===
    echo -e "\n${YELLOW}=== Шаг 2: Настройка GRE ===${NC}"
    
    # Выбор внешнего интерфейса - ИСПРАВЛЕНО!
    print_msg "Доступные интерфейсы:"
    i=1
    > /tmp/interfaces.txt
    for iface in $(ls /sys/class/net/ | grep -v lo | grep -v gre); do
        ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        printf "%2d) %-10s %s\n" $i "$iface" "$ip_info"
        echo "$iface" >> /tmp/interfaces.txt
        i=$((i+1))
    done
    
    read -p "Внешний интерфейс (номер): " ext_idx
    EXT_IFACE=$(sed -n "${ext_idx}p" /tmp/interfaces.txt)
    EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)
    print_ok "Выбран: $EXT_IFACE ($EXT_IP)"
    
    read -p "IP удаленного роутера: " REMOTE_IP
    
    # IP туннеля
    if [[ "$ROLE" == "HQ-RTR" ]]; then
        DEF_GRE="172.16.100.1/29"
    else
        DEF_GRE="172.16.100.2/29"
    fi
    read -p "IP туннеля [$DEF_GRE]: " GRE_INPUT
    GRE_INPUT="${GRE_INPUT:-$DEF_GRE}"
    GRE_IP="$GRE_INPUT"
    
    # === etcnet конфиг для GRE ===
    print_msg "Создание /etc/net/ifaces/gre1..."
    mkdir -p "$IFACES_DIR/gre1"
    
    cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
DISABLE=no
BOOTPROTO=static
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
    
    echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"
    touch "$IFACES_DIR/gre1/ipv4routes"
    
    print_ok "Конфиг etcnet создан"
    
    # Активация runtime
    print_msg "Активация туннеля..."
    ip link set gre1 down 2>/dev/null || true
    ip tunnel del gre1 2>/dev/null || true
    sleep 1
    
    ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64
    ip addr add "$GRE_IP" dev gre1
    ip link set gre1 up
    sleep 2
    
    if ip link show gre1 &>/dev/null; then
        print_ok "Туннель активен"
    else
        print_err "Ошибка туннеля!"
        exit 1
    fi
    
    # === OSPF ===
    echo -e "\n${YELLOW}=== Шаг 3: Настройка OSPF ===${NC}"
    read -p "Пароль [P@ssw0rd]: " PASS
    PASS="${PASS:-P@ssw0rd}"
    
    NETWORKS_CONFIG=$(add_networks_manual)
    
    enable_ospf_daemon
    
    # Генерация frr.conf
    print_msg "Генерация $FRR_CONF..."
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
 ip ospf authentication-key $PASS
$(echo -e "$NETWORKS_CONFIG" | sed 's/^/ /')
!
line vty
!
EOF
    
    # === СОХРАНЕНИЕ КОНФИГА ===
    save_frr_config
    
    # === АВТОЗАПУСК ===
    print_msg "Включение автозапуска..."
    systemctl enable frr 2>/dev/null || true
    systemctl enable net 2>/dev/null || true
    systemctl restart frr
    sleep 3
    
    # === ИТОГИ ===
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ НАСТРОЙКА ЗАВЕРШЕНА                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
    echo "Роль: $ROLE"
    echo "Router ID: $RID"
    echo "Туннель: $GRE_IP"
    
    echo -e "\n${WHITE}ПРОВЕРКА ПЕРСИСТЕНТНОСТИ:${NC}"
    if systemctl is-enabled frr &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} frr автозапуск"
    else
        echo -e "${RED}[!!]${NC} frr автозапуск"
    fi
    
    if systemctl is-enabled net &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} net автозапуск"
    else
        echo -e "${RED}[!!]${NC} net автозапуск"
    fi
    
    if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} ospfd=yes"
    else
        echo -e "${RED}[!!]${NC} ospfd"
    fi
    
    if grep -q 'DISABLE=no' "$IFACES_DIR/gre1/options" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} gre1: DISABLE=no"
    else
        echo -e "${RED}[!!]${NC} gre1"
    fi
    
    echo -e "\n${MAGENTA}ПРОВЕРКА:${NC}"
    echo " vtysh -c 'show ip ospf neighbor'"
    echo " vtysh -c 'show ip route ospf'"
    echo " ip link show gre1"
    
    echo -e "\n${CYAN}ПОСЛЕ ПЕРЕЗАГРУЗКИ проверьте:${NC}"
    echo " systemctl status frr"
    echo " ip link show gre1"
    echo " vtysh -c 'show ip ospf neighbor'"
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================
clear
echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup v3.4                    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo "1) Настроить FRR (OSPF + GRE)"
echo "2) Удалить все настройки"
echo "3) Показать конфигурацию"
echo "4) Проверить персистентность"
echo "5) Выход"
read -p "Выбор [1]: " choice

case $choice in
    2) full_cleanup ;;
    3)
        echo -e "\n${WHITE}=== OSPF конфиг ===${NC}"
        if [[ -f "$FRR_CONF" ]]; then
            grep -A20 "router ospf" "$FRR_CONF" 2>/dev/null || echo "Не настроен"
        else
            echo "Не настроен"
        fi
        echo -e "\n${WHITE}=== Соседи OSPF ===${NC}"
        vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не активен"
        ;;
    4)
        echo -e "\n${WHITE}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"
        if systemctl is-enabled frr &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} frr"
        else
            echo -e "${RED}[!!]${NC} frr"
        fi
        
        if systemctl is-enabled net &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} net"
        else
            echo -e "${RED}[!!]${NC} net"
        fi
        
        if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} ospfd=yes"
        else
            echo -e "${RED}[!!]${NC} ospfd"
        fi
        
        if grep -q 'DISABLE=no' "$IFACES_DIR/gre1/options" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} gre1: DISABLE=no"
        else
            echo -e "${RED}[!!]${NC} gre1"
        fi
        
        if [[ -f /etc/frr/vtysh.conf ]]; then
            echo -e "${GREEN}[OK]${NC} vtysh.conf существует"
        else
            echo -e "${YELLOW}[!]${NC} vtysh.conf"
        fi
        ;;
    5) exit 0 ;;
    *) setup_frr ;;
esac

echo -e "\n${GREEN}Готово!${NC}"
