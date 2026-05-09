#!/bin/bash
#===============================================================================
# Настройка GRE туннеля + OSPF с ручным вводом всех параметров
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Функция создания systemd service для GRE
create_gre_systemd() {
    local local_ip="$1"
    local remote_ip="$2"
    local gre_ip="$3"
    
    cat > /etc/systemd/system/gre-tunnel.service << EOF
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${local_ip} remote ${remote_ip} ttl 64
ExecStart=/sbin/ip addr add ${gre_ip} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1476
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gre-tunnel.service
}

# Включение OSPF демона
enable_ospf_daemon() {
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        cat > "$FRR_DAEMONS" << 'EOF'
zebra=yes
ospfd=yes
bgpd=no
ospf6d=no
ripd=no
EOF
    else
        sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
        sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
    fi
}

# Основная настройка
echo -e "${CYAN}=== Настройка GRE туннеля и OSPF ===${NC}"
echo ""

# Выбор роли
echo "1) HQ-RTR (Router ID: 1.1.1.1)"
echo "2) BR-RTR (Router ID: 2.2.2.2)"
read -p "Выберите роль [1]: " role_choice

case $role_choice in
    2) 
        ROLE="BR-RTR"
        RID="2.2.2.2"
        GRE_IP="172.16.1.2"
        ;;
    *) 
        ROLE="HQ-RTR"
        RID="1.1.1.1"
        GRE_IP="172.16.1.1"
        ;;
esac

echo -e "${YELLOW}Роль: $ROLE${NC}"

# Внешний интерфейс
EXT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)

echo ""
echo "=== Параметры GRE туннеля ==="
echo "Внешний интерфейс: $EXT_IFACE"
echo "Ваш внешний IP: $EXT_IP"
read -p "IP удаленного роутера: " REMOTE_IP
read -p "Локальный IP туннеля [$GRE_IP]: " user_gre
GRE_IP="${user_gre:-$GRE_IP}"
read -p "Маска туннеля [24]: " gre_mask
gre_mask="${gre_mask:-24}"
GRE_FULL_IP="${GRE_IP}/${gre_mask}"

# Ввод сетей для OSPF
echo ""
echo "=== Сети для OSPF ==="
echo "Введите сети которые нужно анонсировать в OSPF (через пробел):"
echo "Пример: 192.168.6.0/28 192.168.10.0/26 10.0.0.0/24"
echo ""
read -p "Сети OSPF: " OSPF_NETWORKS_INPUT

# Проверка ввода
if [[ -z "$OSPF_NETWORKS_INPUT" ]]; then
    echo -e "${RED}Ошибка: Не введены сети OSPF!${NC}"
    exit 1
fi

# Area ID
read -p "Area ID [0]: " area_id
area_id="${area_id:-0}"

# Пароль OSPF
echo ""
read -p "Пароль OSPF [123]: " pass
pass="${pass:-123}"

# Создаем systemd service для GRE
echo ""
echo -e "${CYAN}Создание GRE туннеля...${NC}"
create_gre_systemd "$EXT_IP" "$REMOTE_IP" "$GRE_FULL_IP"

# Включаем OSPF
enable_ospf_daemon

# Настраиваем FRR с введенными сетями
echo -e "${CYAN}Настройка OSPF...${NC}"

cat > "$FRR_CONF" << EOF
!
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
 ip ospf authentication-key $pass
EOF

# Добавляем сети в OSPF
for network in $OSPF_NETWORKS_INPUT; do
    echo " network $network area $area_id" >> "$FRR_CONF"
done

# Добавляем туннельную сеть
echo " network 172.16.1.0/24 area $area_id" >> "$FRR_CONF"

cat >> "$FRR_CONF" << EOF
!
line vty
!
EOF

# Включаем IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# NAT для туннеля (для всех введенных сетей)
echo -e "${CYAN}Настройка NAT...${NC}"
for network in $OSPF_NETWORKS_INPUT; do
    iptables -t nat -A POSTROUTING -s $network -o gre1 -j MASQUERADE 2>/dev/null || true
    echo "  Добавлен NAT для: $network"
done

# Включаем службы
systemctl enable frr
systemctl enable gre-tunnel

# Запускаем
echo ""
echo -e "${CYAN}Запуск служб...${NC}"
systemctl start gre-tunnel
systemctl restart frr

# Проверяем
sleep 3
echo ""
echo -e "${GREEN}=== НАСТРОЙКА ЗАВЕРШЕНА ===${NC}"
echo ""
echo "GRE туннель:"
ip link show gre1
ip addr show gre1
echo ""
echo "OSPF соседи:"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Подождите 10 секунд и проверьте снова"
echo ""
echo "Маршруты OSPF:"
vtysh -c "show ip route ospf" 2>/dev/null | head -20
echo ""
echo -e "${YELLOW}Конфигурация FRR:${NC}"
cat "$FRR_CONF"
echo ""
echo -e "${GREEN}✓ После перезагрузки туннель поднимется автоматически!${NC}"
echo -e "${YELLOW}Для проверки: systemctl status gre-tunnel${NC}"
