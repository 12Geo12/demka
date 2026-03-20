#!/bin/bash
#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# - Проверка конфликтов IP
# - Выбор Router ID
# - Вывод полезных команд
#===============================================================================

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

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Функция определения сети (без ipcalc)
get_network_from_iface() {
    local iface=$1
    local ip_mask=$(ip -4 addr show dev "$iface" | grep -oP 'inet \K[\d./]+')
    if [[ -z "$ip_mask" ]]; then return; fi
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
    local IFS='.'; read -r i1 i2 i3 i4 <<< "$ip"
    local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    local ip_int=$(( (i1 << 24) | (i2 << 16) | (i3 << 8) | i4 ))
    local net_int=$(( ip_int & mask ))
    echo "$(( (net_int >> 24) & 0xFF )).$(( (net_int >> 16) & 0xFF )).$(( (net_int >> 8) & 0xFF )).$(( net_int & 0xFF ))/$cidr"
}

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

#===============================================================================
# НАЧАЛО
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗"
echo "║         FRR OSPF/GRE Setup (Final Stable Version)        ║"
echo "╚══════════════════════════════════════════════════════════╝${NC}"

# Установка
print_msg "Установка пакетов..."
apt-get update >/dev/null 2>&1
apt-get install -y frr >/dev/null 2>&1
print_ok "FRR установлен"

#===============================================================================
# ШАГ 1: РОЛЬ И ROUTER ID
#===============================================================================

echo -e "\n${YELLOW}=== Шаг 1: Идентификация роутера ===${NC}"

HOST=$(hostname | tr '[:upper:]' '[:lower:]')
DEFAULT_ROLE=""
DEFAULT_RID=""

if [[ "$HOST" =~ "hq-rtr" ]]; then
    DEFAULT_ROLE="HQ-RTR"; DEFAULT_RID="1.1.1.1"
elif [[ "$HOST" =~ "br-rtr" ]]; then
    DEFAULT_ROLE="BR-RTR"; DEFAULT_RID="2.2.2.2"
fi

echo "Выберите роль:"
echo "  1) HQ-RTR (Router ID: 1.1.1.1)"
echo "  2) BR-RTR (Router ID: 2.2.2.2)"
echo "  3) Другая роль / Ввести Router ID вручную"
read -p "Ваш выбор [1]: " role_choice

case $role_choice in
    2) ROLE="BR-RTR"; RID="2.2.2.2" ;;
    3) 
        read -p "Введите имя роли (например, ISP): " ROLE
        read -p "Введите Router ID (например, 3.3.3.3): " RID
        ;;
    *) ROLE="HQ-RTR"; RID="1.1.1.1" ;;
esac
print_ok "Роль: $ROLE, Router ID: $RID"

#===============================================================================
# ШАГ 2: НАСТРОЙКА GRE (С ПРОВЕРКОЙ КОНФЛИКТОВ)
#===============================================================================

echo -e "\n${YELLOW}=== Шаг 2: Настройка GRE туннеля ===${NC}"

# Выбор внешнего интерфейса
IFS= read -r -a IFACES <<< $(ls /sys/class/net/ | grep -v lo)
echo "Доступные интерфейсы:"
for i in "${!IFACES[@]}"; do
    ip=$(ip -4 addr show "${IFACES[$i]}" | grep -oP 'inet \K[\d.]+' | head -1)
    printf "  %2s) %-10s %s\n" "$((i+1))" "${IFACES[$i]}" "$ip"
done

read -p "Выберите ВНЕШНИЙ интерфейс: " ext_idx
EXT_IFACE="${IFACES[$((ext_idx-1))]}"
EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)
print_ok "Выбран внешний интерфейс: $EXT_IFACE ($EXT_IP)"

read -p "Введите ВНЕШНИЙ IP удаленного роутера: " REMOTE_IP

# Настройка IP туннеля с проверкой конфликтов
if [[ "$ROLE" == "HQ-RTR" ]]; then
    DEF_GRE_IP="172.16.100.1/29"
else
    DEF_GRE_IP="172.16.100.2/29"
fi

while true; do
    read -p "Локальный IP туннеля [$DEF_GRE_IP]: " GRE_IP
    GRE_IP="${GRE_IP:-$DEF_GRE_IP}"
    
    # Проверка пинга (конфликт)
    GRE_IP_CHECK=$(echo "$GRE_IP" | cut -d'/' -f1)
    print_msg "Проверка свободности IP $GRE_IP_CHECK..."
    if ping -c 1 -W 1 $GRE_IP_CHECK &>/dev/null; then
        print_warn "ВНИМАНИЕ! IP $GRE_IP_CHECK уже занят! Пинг проходит."
        read -p "Использовать другой IP? (y/n) [y]: " change_ip
        if [[ "$change_ip" != "n" ]]; then
            continue
        fi
    else
        print_ok "IP свободен."
        break
    fi
done

# Создание конфигов GRE
print_msg "Настройка /etc/net/ifaces/gre1..."
mkdir -p "$IFACES_DIR/gre1"
cat > "$IFACES_DIR/gre1/options" <<EOF
BOOTPROTO=static
TYPE=iptun
TUNLOCAL=$EXT_IP
TUNREMOTE=$REMOTE_IP
TUNTYPE=gre
TUNOPTIONS='ttl 64'
HOST=$EXT_IFACE
ONBOOT=yes
DISABLED=no
EOF
echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"

# Активация
ip tunnel del gre1 2>/dev/null
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
ip addr add $GRE_IP dev gre1
ip link set gre1 up
print_ok "Туннель gre1 активирован"

#===============================================================================
# ШАГ 3: НАСТРОЙКА OSPF
#===============================================================================

echo -e "\n${YELLOW}=== Шаг 3: Настройка OSPF ===${NC}"

read -p "Пароль для OSPF аутентификации [P@ssw0rd]: " PASS
PASS="${PASS:-P@ssw0rd}"

# Выбор сетей
echo "Выберите сети для анонсирования в OSPF:"
NETWORKS_CONFIG=""

for iface in "${IFACES[@]}"; do
    if [[ "$iface" == "$EXT_IFACE" ]] || [[ "$iface" == "gre1" ]] || [[ "$iface" == "lo" ]]; then continue; fi
    
    net=$(get_network_from_iface "$iface")
    if [[ -n "$net" ]]; then
        read -p "Добавить сеть $net (интерфейс $iface)? (y/n) [y]: " ans
        if [[ "$ans" != "n" ]]; then
            NETWORKS_CONFIG+=" network $net area 0\n"
        fi
    fi
done

# Сеть туннеля
GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
GRE_NET_CIDR=$(echo "$GRE_IP" | cut -d'/' -f2)
GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
NETWORKS_CONFIG+=" network $GRE_NET area 0\n"
print_ok "Добавлена сеть туннеля: $GRE_NET"

# Запись конфига FRR
print_msg "Генерация /etc/frr/frr.conf..."
cat > $FRR_CONF <<EOF
frr version 8.1
frr defaults traditional
hostname $HOST
!
router ospf
 ospf router-id $RID
 passive-interface default
!
interface gre1
 no ip ospf passive
 ip ospf area 0
 ip ospf authentication
 ip ospf authentication-key $PASS
exit
!
 $(echo -e "$NETWORKS_CONFIG")
 area 0 authentication
!
line vty
!
EOF

# Включение демонов
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons

# Запуск
print_msg "Перезапуск FRR..."
systemctl enable --now frr >/dev/null 2>&1
systemctl restart frr
sleep 3

#===============================================================================
# ИТОГОВАЯ ТАБЛИЦА
#===============================================================================

clear
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║             НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
echo "Роль: $ROLE"
echo "Router ID: $RID"
echo "Туннель: $GRE_IP (Сеть: $GRE_NET)"
echo ""

# Проверка соседей
echo -e "${WHITE}ТЕКУЩИЙ СТАТУС OSPF:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Соседи пока не обнаружены (подождите 10-15 сек)"
echo ""

echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║           ГЛАВНЫЕ КОМАНДЫ ДЛЯ ПРОВЕРКИ                  ║${NC}"
echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"

echo -e "${CYAN}1. Просмотр соседей OSPF:${NC}"
echo "   vtysh -c 'show ip ospf neighbor'"
echo ""

echo -e "${CYAN}2. Просмотр таблицы маршрутизации (OSPF маршруты):${NC}"
echo "   vtysh -c 'show ip route ospf'"
echo ""

echo -e "${CYAN}3. Проверка IP связности туннеля:${NC}"
echo "   ping $(echo $GRE_IP | cut -d'/' -f1)"
echo ""

echo -e "${CYAN}4. Просмотр конфигурации OSPF:${NC}"
echo "   vtysh -c 'show running-config ospf'"
echo ""

echo -e "${CYAN}5. Перезапуск FRR (если нужно):${NC}"
echo "   systemctl restart frr"
echo ""

echo -e "${YELLOW}Подсказка: Если соседи не появились, проверьте, что на другом роутере${NC}"
echo -e "${YELLOW}настроен такой же пароль ($PASS) и та же Area (0).${NC}"
