#!/bin/bash
################################################################################
# FRRouting + GRE + OSPF для ALT Linux
# С ручным вводом параметров
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ $EUID -ne 0 ]; then
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

################################################################################
# ВВОД ПАРАМЕТРОВ
################################################################################
echo -e "${CYAN}=== Настройка GRE туннеля и OSPF ===${NC}"
echo ""

# Router ID
read -p "Router ID (например 1.1.1.1): " RID
RID=${RID:-1.1.1.1}

# Интерфейс
echo ""
echo -e "${CYAN}Доступные интерфейсы:${NC}"
ip -br addr show | grep -v lo
read -p "Имя внешнего интерфейса: " IFACE
IFACE=${IFACE:-enp7s1}

LOCAL_IP=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
if [ -z "$LOCAL_IP" ]; then
    echo -e "${RED}Не найден IP на $IFACE${NC}"
    exit 1
fi
echo -e "${YELLOW}Найден IP: $LOCAL_IP${NC}"

# GRE параметры
echo ""
echo -e "${CYAN}=== Параметры GRE туннеля ===${NC}"
read -p "Локальный IP GRE (например 172.16.1.1): " GRE_LOCAL
GRE_LOCAL=${GRE_LOCAL:-172.16.1.1}

read -p "Удаленный IP GRE (например 192.168.5.2): " GRE_REMOTE
GRE_REMOTE=${GRE_REMOTE:-192.168.5.2}

read -p "Маска GRE (24): " GRE_MASK
GRE_MASK=${GRE_MASK:-24}

# OSPF сети
echo ""
echo -e "${CYAN}=== Сети для OSPF ===${NC}"
echo "Введите сети для OSPF через пробел (например: 172.16.1.0/24 192.168.10.0/24)"
echo "Или нажмите Enter для использования только GRE сети"
read -p "OSPF сети: " OSPF_NETS_INPUT

if [ -z "$OSPF_NETS_INPUT" ]; then
    # Если не ввели, используем только GRE сеть
    GRE_NETWORK=$(echo "$GRE_LOCAL" | awk -F. '{print $1"."$2"."$3".0"}')
    OSPF_NETS="${GRE_NETWORK}/${GRE_MASK}"
else
    # Добавляем GRE сеть к введенным
    GRE_NETWORK=$(echo "$GRE_LOCAL" | awk -F. '{print $1"."$2"."$3".0"}')
    OSPF_NETS="${OSPF_NETS_INPUT} ${GRE_NETWORK}/${GRE_MASK}"
fi

echo ""
echo -e "${YELLOW}=== ИТОГОВЫЕ ПАРАМЕТРЫ ===${NC}"
echo -e "Router ID:      ${RID}"
echo -e "Интерфейс:      ${IFACE} (${LOCAL_IP})"
echo -e "GRE Local:      ${GRE_LOCAL}/${GRE_MASK}"
echo -e "GRE Remote:     ${GRE_REMOTE}"
echo -e "OSPF сети:      ${OSPF_NETS}"
echo ""
read -p "Продолжить? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено"
    exit 0
fi

################################################################################
# УСТАНОВКА
################################################################################
echo -e "${CYAN}>>> Установка FRR...${NC}"
apt-get update -qq
apt-get install -y -qq frr iproute2 iptables
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки!${NC}"
    exit 1
fi

################################################################################
# ДЕМОНА
################################################################################
echo -e "${CYAN}>>> Настройка демонов...${NC}"
cat > /etc/frr/daemons << 'EOF'
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
EOF

################################################################################
# OSPF КОНФИГ
################################################################################
echo -e "${CYAN}>>> Настройка OSPF...${NC}"
cat > /etc/frr/frr.conf << EOF
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
 ip ospf authentication
 ip ospf authentication-key 123
EOF

for net in $OSPF_NETS; do
    echo " network $net area 0" >> /etc/frr/frr.conf
done

echo -e "!\nline vty\n!" >> /etc/frr/frr.conf

################################################################################
# GRE ТУННЕЛЬ
################################################################################
echo -e "${CYAN}>>> Создание GRE туннеля...${NC}"

# Удаляем старый
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null

# Создаем новый
ip tunnel add gre1 mode gre local "$LOCAL_IP" remote "$GRE_REMOTE" ttl 64
if [ $? -ne 0 ]; then
    echo -e "${RED}Не удалось создать туннель!${NC}"
    echo "Проверьте доступность $GRE_REMOTE"
    ping -c 2 "$GRE_REMOTE" || true
    exit 1
fi

ip addr add "${GRE_LOCAL}/${GRE_MASK}" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400

sleep 1
if ! ip link show gre1 | grep -q "UP"; then
    echo -e "${RED}GRE туннель не поднялся!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ GRE создан: ${GRE_LOCAL}/${GRE_MASK} -> ${GRE_REMOTE}${NC}"

# Сохранение для etcnet
mkdir -p /etc/net/ifaces/gre1
cat > /etc/net/ifaces/gre1/options << EOF
TYPE=gre
REMOTE=$GRE_REMOTE
LOCAL=$LOCAL_IP
TTL=64
DISABLE=no
EOF
echo "${GRE_LOCAL}/${GRE_MASK}" > /etc/net/ifaces/gre1/ipv4address

################################################################################
# СИСТЕМНЫЕ НАСТРОЙКИ
################################################################################
echo -e "${CYAN}>>> Системные настройки...${NC}"
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

grep -q "rp_filter=2" /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.gre1.rp_filter=2
EOF
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1

################################################################################
# ЗАПУСК
################################################################################
echo -e "${CYAN}>>> Запуск служб...${NC}"
systemctl enable frr --quiet 2>/dev/null
systemctl restart frr
sleep 2

################################################################################
# ПРОВЕРКА
################################################################################
echo ""
echo -e "${GREEN}=== РЕЗУЛЬТАТ ===${NC}"

if systemctl is-active --quiet frr; then
    echo -e "${GREEN}✓ FRR: запущен${NC}"
else
    echo -e "${RED}✗ FRR: ошибка${NC}"
fi

if ip link show gre1 | grep -q "UP"; then
    echo -e "${GREEN}✓ GRE: активен${NC}"
    ip -brief addr show gre1
else
    echo -e "${RED}✗ GRE: не активен${NC}"
fi

echo ""
echo -e "${CYAN}OSPF соседи:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  (ожидание)"

echo -e "${CYAN}OSPF маршруты:${NC}"
ip route | grep ospf || echo "  (пока нет)"

echo ""
echo -e "${CYAN}Конфигурация:${NC}"
echo -e "  vtysh"
echo -e "  vtysh -c 'show ip ospf neighbor'"
echo -e "  vtysh -c 'show ip route ospf'"
echo -e "  ping -I gre1 ${GRE_REMOTE}"
echo ""
echo -e "${GREEN}Готово!${NC}"
