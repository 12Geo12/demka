#!/bin/bash
#===============================================================================
# ИСПРАВЛЕННЫЙ СКРИПТ - GRE туннель через systemd (надежнее чем etcnet)
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

IFACES_DIR="/etc/net/ifaces"
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
echo -e "${CYAN}=== Настройка GRE + OSPF ===${NC}"

# Выбор роли
echo "1) HQ-RTR (1.1.1.1)"
echo "2) BR-RTR (2.2.2.2)"
read -p "Выбор [1]: " role_choice

case $role_choice in
    2) ROLE="BR-RTR"; RID="2.2.2.2"; GRE_IP="172.16.1.2/24" ;;
    *) ROLE="HQ-RTR"; RID="1.1.1.1"; GRE_IP="172.16.1.1/24" ;;
esac

# Внешний интерфейс
EXT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)

read -p "IP удаленного роутера: " REMOTE_IP
read -p "Локальный IP туннеля [$GRE_IP]: " user_gre
GRE_IP="${user_gre:-$GRE_IP}"

# Создаем systemd service для GRE
create_gre_systemd "$EXT_IP" "$REMOTE_IP" "$GRE_IP"

# Включаем OSPF
enable_ospf_daemon

# Настраиваем FRR
read -p "Пароль OSPF [123]: " pass
pass="${pass:-123}"

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
 ip ospf authentication-key $pass
 network 192.168.6.0/28 area 0
 network 172.16.1.0/24 area 0
!
line vty
!
EOF

# Включаем IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# NAT для туннеля
iptables -t nat -A POSTROUTING -s 192.168.6.0/28 -o gre1 -j MASQUERADE 2>/dev/null || true

# Включаем службы
systemctl enable frr
systemctl enable gre-tunnel

# Запускаем
systemctl start gre-tunnel
systemctl restart frr

# Проверяем
sleep 2
echo -e "\n${GREEN}=== ГОТОВО ===${NC}"
echo "Туннель:"
ip link show gre1
echo -e "\nOSPF соседи:"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Проверьте через 10 сек"

echo -e "\n${YELLOW}После перезагрузки туннель поднимется автоматически!${NC}"
