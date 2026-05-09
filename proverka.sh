cat > /root/setup_gre_ospf.sh << 'SCRIPT'
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== Настройка GRE + OSPF ===${NC}"

# Выбор роли
read -p "Роль: 1) HQ-RTR  2) BR-RTR [1]: " role
if [ "$role" = "2" ]; then
    RID="2.2.2.2"
    GRE_IP="172.16.1.2/24"
    REMOTE_IP="192.168.4.2"
    OSPF_NETS="192.168.5.0/28 192.168.6.0/28"
else
    RID="1.1.1.1"
    GRE_IP="172.16.1.1/24"
    REMOTE_IP="192.168.5.2"
    OSPF_NETS="192.168.4.0/28 192.168.10.0/26"
fi

# Получить внешний IP
EXT_IP=$(ip -4 addr show ens33 | grep -oP 'inet \K[\d.]+')

echo "Внешний IP: $EXT_IP"
echo "Удаленный IP: $REMOTE_IP"

# Создать systemd service
cat > /etc/systemd/system/gre-tunnel.service << EOF
[Unit]
Description=GRE Tunnel
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
ExecStart=/sbin/ip addr add $GRE_IP dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1476
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gre-tunnel

# Настроить FRR
cat > /etc/frr/frr.conf << EOF
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
 ip ospf authentication-key 123
EOF

for net in $OSPF_NETS; do
    echo " network $net area 0" >> /etc/frr/frr.conf
done
echo " network 172.16.1.0/24 area 0" >> /etc/frr/frr.conf

echo "!" >> /etc/frr/frr.conf
echo "line vty" >> /etc/frr/frr.conf
echo "!" >> /etc/frr/frr.conf

# Включить OSPF демон
sed -i 's/ospfd=.*/ospfd=yes/' /etc/frr/daemons
sed -i 's/zebra=.*/zebra=yes/' /etc/frr/daemons

# Включить IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2

# Запустить службы
systemctl start gre-tunnel
systemctl restart frr

sleep 5

echo -e "${GREEN}=== Готово ===${NC}"
ip link show gre1
vtysh -c "show ip ospf neighbor"
SCRIPT

chmod +x /root/setup_gre_ospf.sh
