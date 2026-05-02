#!/bin/bash
#===============================================================================
# DHCP Server Setup - Для Demo2026 Alt Linux
# Ищет VLAN и в /etc/net/ifaces/ и через ip link
#===============================================================================

echo "===== Настройка DHCP сервера ====="

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: Запустите от root (su -)"
    exit 1
fi

# Установка
if ! command -v dhcpd &> /dev/null; then
    echo "Установка dhcp-server..."
    apt-get update -y 2>/dev/null
    apt-get install -y dhcp-server 2>/dev/null || dnf install -y dhcp-server 2>/dev/null
fi

if ! command -v dhcpd &> /dev/null; then
    echo "ОШИБКА: dhcpd не установлен!"
    exit 1
fi

echo "DHCP установлен: $(dhcpd --version 2>&1 | head -1)"

# Функция поиска VLAN интерфейсов
find_vlan_interfaces() {
    echo "Поиск VLAN интерфейсов..."
    echo
    
    # 1. Активные VLAN через ip link
    echo "=== Активные VLAN (ip link) ==="
    local active_vlans=$(ip -o link show type vlan 2>/dev/null | awk -F': ' '{print $2}')
    if [ -n "$active_vlans" ]; then
        echo "$active_vlans"
    else
        echo "(нет активных VLAN)"
    fi
    echo
    
    # 2. Настроенные VLAN в /etc/net/ifaces/
    echo "=== Настроенные VLAN (/etc/net/ifaces/) ==="
    if [ -d "/etc/net/ifaces" ]; then
        local found=0
        for dir in /etc/net/ifaces/*.*; do
            if [ -d "$dir" ]; then
                local vlan_name=$(basename "$dir")
                local vlan_ip=$(cat "$dir/ipv4address" 2>/dev/null || echo "")
                local vlan_vid=$(grep "^VID=" "$dir/options" 2>/dev/null | cut -d= -f2 || echo "?")
                echo "  $vlan_name (VLAN $vlan_vid): ${vlan_ip:-без IP}"
                found=1
            fi
        done
        [ $found -eq 0 ] && echo "(нет настроенных VLAN)"
    else
        echo "(директория /etc/net/ifaces не найдена)"
    fi
    echo
    
    # 3. Все интерфейсы с IP
    echo "=== Все интерфейсы с IP ==="
    ip -br addr show 2>/dev/null | grep -v "^lo"
}

find_vlan_interfaces

# Сбор списка интерфейсов для выбора
echo
echo "===== Выбор интерфейсов для DHCP ====="

INTERFACES=()
IPS=()
PREFIXES=()

idx=0

# Сначала проверяем /etc/net/ifaces/ (Alt Linux native)
if [ -d "/etc/net/ifaces" ]; then
    for dir in /etc/net/ifaces/*.*; do
        if [ -d "$dir" ]; then
            iface=$(basename "$dir")
            ip_info=$(cat "$dir/ipv4address" 2>/dev/null | head -1)
            
            if [ -n "$ip_info" ]; then
                idx=$((idx + 1))
                INTERFACES+=("$iface")
                IPS+=("$(echo "$ip_info" | cut -d'/' -f1)")
                PREFIXES+=("$(echo "$ip_info" | cut -d'/' -f2)")
                printf "%2d) %-20s %s\n" "$idx" "$iface" "$ip_info"
            fi
        fi
    done
fi

# Потом проверяем активные интерфейсы
for iface in $(ip -br addr show 2>/dev/null | grep -v "^lo" | awk '{print $1}'); do
    # Пропускаем если уже добавлен
    local already=0
    for i in "${INTERFACES[@]}"; do
        [ "$i" = "$iface" ] && already=1 && break
    done
    [ $already -eq 1 ] && continue
    
    ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    if [ -n "$ip_info" ]; then
        idx=$((idx + 1))
        INTERFACES+=("$iface")
        IPS+=("$(echo "$ip_info" | cut -d'/' -f1)")
        PREFIXES+=("$(echo "$ip_info" | cut -d'/' -f2)")
        printf "%2d) %-20s %s\n" "$idx" "$iface" "$ip_info"
    fi
done

TOTAL=$idx

if [ $TOTAL -eq 0 ]; then
    echo
    echo "ОШИБКА: Нет интерфейсов с IP!"
    echo
    echo "Сначала создайте VLAN интерфейсы:"
    echo "  bash /home/z/my-project/download/vlan-setup.sh"
    echo
    echo "Или используйте скрипт:"
    echo "  https://github.com/12Geo12/demka/blob/main/1.3.vlans.sh"
    exit 1
fi

echo
read -p "Введите номера интерфейсов через пробел (или 'all'): " selection

# Преобразование префикса в маску
prefix_to_mask() {
    case "$1" in
        24) echo "255.255.255.0" ;;
        25) echo "255.255.255.128" ;;
        26) echo "255.255.255.192" ;;
        27) echo "255.255.255.224" ;;
        28) echo "255.255.255.240" ;;
        29) echo "255.255.255.248" ;;
        30) echo "255.255.255.252" ;;
        *)  echo "255.255.255.0" ;;
    esac
}

# Расчёт последнего адреса
calc_last() {
    case "$1" in
        24) echo "254" ;;
        25) echo "126" ;;
        26) echo "62" ;;
        27) echo "30" ;;
        28) echo "14" ;;
        29) echo "6" ;;
        30) echo "2" ;;
        *)  echo "254" ;;
    esac
}

# Создаём конфиг
echo
echo "===== Создание конфигурации DHCP ====="

[ -f /etc/dhcp/dhcpd.conf ] && cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.bak

cat > /etc/dhcp/dhcpd.conf << 'EOF'
# DHCP Server - Demo2026
authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;
option domain-name "au-team.irpo";

EOF

SELECTED_IFACES=""

# Обработка выбора
if [ "$selection" = "all" ]; then
    for i in $(seq 0 $((TOTAL-1))); do
        iface="${INTERFACES[$i]}"
        ip="${IPS[$i]}"
        prefix="${PREFIXES[$i]}"
        
        mask=$(prefix_to_mask "$prefix")
        last=$(calc_last "$prefix")
        
        o1=$(echo "$ip" | cut -d'.' -f1)
        o2=$(echo "$ip" | cut -d'.' -f2)
        o3=$(echo "$ip" | cut -d'.' -f3)
        
        network="${o1}.${o2}.${o3}.0"
        gateway="${o1}.${o2}.${o3}.1"
        range="${o1}.${o2}.${o3}.2 ${o1}.${o2}.${o3}.${last}"
        
        echo "  $iface: $network/$prefix, DHCP: ${o1}.${o2}.${o3}.2-${last}"
        
        cat >> /etc/dhcp/dhcpd.conf << EOF

# $iface
subnet $network netmask $mask {
    range $range;
    option routers $gateway;
    option domain-name-servers $gateway;
    option domain-name "au-team.irpo";
}
EOF
        
        SELECTED_IFACES="$SELECTED_IFACES $iface"
    done
else
    for num in $selection; do
        i=$((num - 1))
        
        if [ $i -lt 0 ] || [ $i -ge $TOTAL ]; then
            echo "Пропускаем неверный номер: $num"
            continue
        fi
        
        iface="${INTERFACES[$i]}"
        ip="${IPS[$i]}"
        prefix="${PREFIXES[$i]}"
        
        mask=$(prefix_to_mask "$prefix")
        last=$(calc_last "$prefix")
        
        o1=$(echo "$ip" | cut -d'.' -f1)
        o2=$(echo "$ip" | cut -d'.' -f2)
        o3=$(echo "$ip" | cut -d'.' -f3)
        
        network="${o1}.${o2}.${o3}.0"
        gateway="${o1}.${o2}.${o3}.1"
        range="${o1}.${o2}.${o3}.2 ${o1}.${o2}.${o3}.${last}"
        
        echo "  $iface: $network/$prefix, DHCP: ${o1}.${o2}.${o3}.2-${last}"
        
        cat >> /etc/dhcp/dhcpd.conf << EOF

# $iface
subnet $network netmask $mask {
    range $range;
    option routers $gateway;
    option domain-name-servers $gateway;
    option domain-name "au-team.irpo";
}
EOF
        
        SELECTED_IFACES="$SELECTED_IFACES $iface"
    done
fi

# Показываем конфиг
echo
echo "===== Конфигурация /etc/dhcp/dhcpd.conf ====="
cat /etc/dhcp/dhcpd.conf

# Интерфейсы для DHCP
echo "DHCPDARGS=\"$SELECTED_IFACES\"" > /etc/sysconfig/dhcpd
echo
echo "Интерфейсы DHCP:$SELECTED_IFACES"

# IP Forwarding
echo
echo "===== IP Forwarding ====="
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p 2>/dev/null | grep ip_forward

# Firewall
echo
echo "===== Firewall ====="
iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
echo "Порты 67, 68 открыты"

# Проверка
echo
echo "===== Проверка конфигурации ====="
if dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1; then
    echo "OK: Конфигурация валидна"
else
    echo "ОШИБКА в конфигурации!"
    exit 1
fi

# Запуск
echo
echo "===== Запуск DHCP ====="
systemctl stop dhcpd 2>/dev/null
systemctl enable --now dhcpd 2>/dev/null

sleep 2

if systemctl is-active --quiet dhcpd; then
    echo "OK: DHCP сервер запущен"
else
    echo "ОШИБКА запуска!"
    systemctl status dhcpd --no-pager
    exit 1
fi

echo
echo "===== Проверка порта ====="
ss -ulnp 2>/dev/null | grep ':67' && echo "OK: Порт 67 слушается"

echo
echo "===== ГОТОВО ====="
echo "DHCP настроен на:$SELECTED_IFACES"
