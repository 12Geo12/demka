#!/bin/bash
#===============================================================================
# VLAN Configuration for ALT Linux 10.4 (etcnet)
# Simple and reliable version for exam
#===============================================================================

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Run as root"
    exit 1
fi

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

IFACES_DIR="/etc/net/ifaces"

echo -e "${CYAN}=== VLAN Configuration for ALT Linux ===${NC}"
echo ""

# Показываем интерфейсы
echo "Available interfaces:"
ip -br link show | grep -v lo | awk '{print NR") "$1" - "$2}'
echo ""

# Выбор интерфейса
read -p "Select interface number: " iface_num
PHYS_IFACE=$(ip -br link show | grep -v lo | awk '{print $1}' | sed -n "${iface_num}p")

if [ -z "$PHYS_IFACE" ]; then
    echo -e "${RED}Invalid interface${NC}"
    exit 1
fi

echo -e "${GREEN}Selected: $PHYS_IFACE${NC}"
echo ""

# Показываем существующие VLAN
echo "Existing VLANs on $PHYS_IFACE:"
for dir in "$IFACES_DIR"/${PHYS_IFACE}.*; do
    [ -d "$dir" ] || continue
    vlan_name=$(basename "$dir")
    vlan_id=$(grep "^VLAN_ID=" "$dir/options" 2>/dev/null | cut -d= -f2)
    vlan_ip=$(cat "$dir/ipv4address" 2>/dev/null)
    echo "  $vlan_name (VLAN $vlan_id) - $vlan_ip"
done
echo ""

# Меню
echo "1) Create VLAN"
echo "2) Delete VLAN"
echo "3) Exit"
read -p "Choice [1]: " choice
choice=${choice:-1}

case $choice in
    2)
        # Удаление VLAN
        read -p "Enter VLAN interface name (e.g., ${PHYS_IFACE}.100): " vlan_del
        if [ -z "$vlan_del" ]; then
            echo "Cancelled"
            exit 0
        fi
        
        read -p "Confirm deletion? (y/n): " conf
        if [[ "$conf" =~ ^[Yy]$ ]]; then
            ip link del "$vlan_del" 2>/dev/null || true
            rm -rf "$IFACES_DIR/$vlan_del"
            echo -e "${GREEN}Deleted${NC}"
        fi
        ;;
    
    1)
        # Создание VLAN
        echo ""
        echo "Enter VLANs in format: NAME|VLAN_ID|IP_OCTET|HOSTS"
        echo "Example: HQ-SRV|100|100|64"
        echo ""
        echo "Common masks:"
        echo "  64 hosts  -> /26 (use 64)"
        echo "  32 hosts  -> /27 (use 32)"
        echo "  16 hosts  -> /28 (use 16)"
        echo "  8 hosts   -> /29 (use 8)"
        echo ""
        
        read -p "Base network (e.g., 192.168 or 172.16): " base_net
        base_net=${base_net:-192.168}
        
        echo ""
        echo "Enter VLAN (or empty to finish):"
        
        while true; do
            read -p "VLAN: " vlan_line
            [ -z "$vlan_line" ] && break
            
            # Парсинг: NAME|ID|OCTET|HOSTS
            IFS='|' read -r name vlan_id octet hosts <<< "$vlan_line"
            
            if [ -z "$name" ] || [ -z "$vlan_id" ] || [ -z "$octet" ]; then
                echo -e "${RED}Invalid format${NC}"
                continue
            fi
            
            # Маска по количеству хостов
            hosts=${hosts:-64}
            if [ "$hosts" -le 8 ]; then
                mask=29
            elif [ "$hosts" -le 16 ]; then
                mask=28
            elif [ "$hosts" -le 32 ]; then
                mask=27
            elif [ "$hosts" -le 64 ]; then
                mask=26
            else
                mask=24
            fi
            
            vlan_iface="${PHYS_IFACE}.${vlan_id}"
            vlan_dir="$IFACES_DIR/$vlan_iface"
            
            # IP адрес: base.octet.1/mask
            ip_addr="${base_net}.${octet}.1/${mask}"
            
            echo -e "${CYAN}Creating $vlan_iface ($ip_addr)...${NC}"
            
            # Создаём директорию
            mkdir -p "$vlan_dir"
            
            # Создаём options
            cat > "$vlan_dir/options" << EOF
TYPE=vlan
BOOTPROTO=static
ONBOOT=yes
NM_CONTROLLED=no
VLAN=yes
PHYSDEV=$PHYS_IFACE
VLAN_ID=$vlan_id
EOF
            
            # Создаём ipv4address
            echo "$ip_addr" > "$vlan_dir/ipv4address"
            
            # Применяем сразу
            ip link add link "$PHYS_IFACE" name "$vlan_iface" type vlan id "$vlan_id" 2>/dev/null || true
            ip addr add "$ip_addr" dev "$vlan_iface" 2>/dev/null || true
            ip link set "$vlan_iface" up 2>/dev/null || true
            
            echo -e "${GREEN}✓ Created: $vlan_iface - $ip_addr${NC}"
        done
        
        # Перезапуск сети
        echo ""
        read -p "Restart network? (y/n): " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl restart network 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true
            echo -e "${GREEN}Network restarted${NC}"
        fi
        ;;
    
    3)
        echo "Exit"
        exit 0
        ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"
echo "Check: ip addr show | grep $PHYS_IFACE"
