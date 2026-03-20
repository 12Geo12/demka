#!/bin/bash
#===============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR ДЛЯ ALT LINUX (DEMO 2025/2026)
# Основано на методичке Module_1 и cheatsheet_sysadmin
# 
# Особенности:
# - Настройка GRE через /etc/net/ifaces
# - Принудительное включение OSPF на интерфейсе (решение проблемы отсутствия соседей)
# - Автоматический расчет сетей без внешних утилит
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Функция определения сети по IP и маске (без ipcalc)
# Возвращает формат: 192.168.1.0/24
get_network_from_iface() {
    local iface=$1
    local ip_mask=$(ip -4 addr show dev "$iface" | grep -oP 'inet \K[\d./]+')
    
    if [[ -z "$ip_mask" ]]; then return; fi
    
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
    
    # Простая математика для определения сети (работает для /8, /16, /24, /29 и т.д.)
    local IFS='.'
    read -r i1 i2 i3 i4 <<< "$ip"
    
    # Маска в бинарном виде -> DEC
    local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    
    # Наложение маски
    local n1=$(( (i1 << 24) & 0xFF000000 ))
    local n2=$(( (i2 << 16) & 0x00FF0000 ))
    local n3=$(( (i3 << 8) & 0x0000FF00 ))
    local n4=$i4
    
    local ip_int=$(( n1 | n2 | n3 | n4 ))
    local net_int=$(( ip_int & mask ))
    
    local result="$(( (net_int >> 24) & 0xFF )).$(( (net_int >> 16) & 0xFF )).$(( (net_int >> 8) & 0xFF )).$(( net_int & 0xFF ))/$cidr"
    echo "$result"
}

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_err() { echo -e "${RED}[ОШИБКА]${NC} $1"; }

#===============================================================================
# НАЧАЛО
#===============================================================================

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════╗"
echo "║    FRR OSPF/GRE Setup (Demo 2025/2026 Edition)    ║"
echo "╚════════════════════════════════════════════════════╝${NC}"

# Установка FRR
print_msg "Установка пакетов..."
apt-get update >/dev/null 2>&1
apt-get install -y frr >/dev/null 2>&1
print_ok "FRR установлен"

# Определение роли
HOST=$(hostname | tr '[:upper:]' '[:lower:]')
ROLE=""
RID=""
SUGGESTED_GRE_IP=""

if [[ "$HOST" =~ "hq-rtr" ]]; then
    ROLE="HQ-RTR"; RID="1.1.1.1"; SUGGESTED_GRE_IP="172.16.100.1/29"
elif [[ "$HOST" =~ "br-rtr" ]]; then
    ROLE="BR-RTR"; RID="2.2.2.2"; SUGGESTED_GRE_IP="172.16.100.2/29"
else
    print_err "Не удалось определить роль. Выберите вручную:"
    echo "1) HQ-RTR (Router ID 1.1.1.1, GRE IP .1)"
    echo "2) BR-RTR (Router ID 2.2.2.2, GRE IP .2)"
    read -p "Ваш выбор: " r_choice
    case $r_choice in
        1) ROLE="HQ-RTR"; RID="1.1.1.1"; SUGGESTED_GRE_IP="172.16.100.1/29" ;;
        2) ROLE="BR-RTR"; RID="2.2.2.2"; SUGGESTED_GRE_IP="172.16.100.2/29" ;;
        *) exit 1 ;;
    esac
fi
print_ok "Роль: $ROLE, Router ID: $RID"

#===============================================================================
# ШАГ 1: НАСТРОЙКА GRE
#===============================================================================

echo -e "\n${YELLOW}=== Настройка GRE туннеля ===${NC}"

# Список интерфейсов
IFS= read -r -a IFACES <<< $(ls /sys/class/net/ | grep -v lo)
echo "Доступные интерфейсы:"
for i in "${!IFACES[@]}"; do
    ip=$(ip -4 addr show "${IFACES[$i]}" | grep -oP 'inet \K[\d.]+' | head -1)
    printf "  %2s) %-8s %s\n" "$((i+1))" "${IFACES[$i]}" "$ip"
done

read -p "Выберите ВНЕШНИЙ интерфейс (через который идет туннель): " ext_idx
EXT_IFACE="${IFACES[$((ext_idx-1))]}"
EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)

read -p "Введите ВНЕШНИЙ IP удаленного роутера: " REMOTE_IP
read -p "Локальный IP туннеля [$SUGGESTED_GRE_IP]: " GRE_IP_INPUT
GRE_IP="${GRE_IP_INPUT:-$SUGGESTED_GRE_IP}"

# Создание конфигов GRE (метод Module_1)
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

# Активация туннеля "на лету"
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64 2>/dev/null || ip tunnel change gre1 local $EXT_IP remote $REMOTE_IP
ip addr add $GRE_IP dev gre1 2>/dev/null
ip link set gre1 up
print_ok "Туннель gre1 активирован"

#===============================================================================
# ШАГ 2: НАСТРОЙКА OSPF
#===============================================================================

echo -e "\n${YELLOW}=== Настройка OSPF ===${NC}"

read -p "Пароль для OSPF аутентификации [P@ssw0rd]: " PASS
PASS="${PASS:-P@ssw0rd}"

# Выбор сетей для анонса
echo "Выберите сети для анонсирования в OSPF:"
NETWORKS_CONFIG=""
SELECTED_IFACES=""

# Автоматически найдем сети, исключая lo и gre1 и внешний интерфейс
for iface in "${IFACES[@]}"; do
    if [[ "$iface" == "$EXT_IFACE" ]] || [[ "$iface" == "gre1" ]] || [[ "$iface" == "lo" ]]; then
        continue
    fi
    
    net=$(get_network_from_iface "$iface")
    if [[ -n "$net" ]]; then
        read -p "Добавить сеть $net (интерфейс $iface)? (y/n) [y]: " ans
        if [[ "$ans" != "n" ]]; then
            NETWORKS_CONFIG+=" network $net area 0\n"
        fi
    fi
done

# Сеть туннеля (автоматически)
# Берем подсеть из GRE_IP (меняем последний октет на 0)
GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
GRE_NET_CIDR=$(echo "$GRE_IP" | cut -d'/' -f2)
GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
print_msg "Автоматически добавлена сеть туннеля: $GRE_NET"
NETWORKS_CONFIG+=" network $GRE_NET area 0\n"

# Генерация конфига FRR
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

# Включаем демоны
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons

# Перезапуск
print_msg "Перезапуск FRR..."
systemctl enable --now frr >/dev/null 2>&1
systemctl restart frr

sleep 3

echo -e "\n${GREEN}=== НАСТРОЙКА ЗАВЕРШЕНА ===${NC}"
echo "Проверка состояния OSPF:"
vtysh -c "show ip ospf interface brief"
echo ""
echo "Проверка соседей:"
vtysh -c "show ip ospf neighbor"
echo ""
echo "Если соседи не появились через 10 секунд, проверьте пинг туннеля."
