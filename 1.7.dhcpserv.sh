#!/bin/bash
#===============================================================================
# DHCP Server Setup for ALT Linux with VLAN support
# Версия: 2.0 - Простой, с автоопределением и поддержкой VLAN
#===============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_DEFAULTS="/etc/sysconfig/dhcpd"

log() { echo -e "${CYAN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "Запустите от root!"
    exit 1
fi

#===============================================================================
# АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
#===============================================================================
get_interfaces() {
    echo "Доступные интерфейсы:"
    local i=1
    > /tmp/dhcp_ifaces
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        printf " %2d) %-10s %s\n" $i "$iface" "${ip:-no IP}"
        echo "$iface" >> /tmp/dhcp_ifaces
        ((i++))
    done
}

#===============================================================================
# ГЕНЕРАЦИЯ КОНФИГА ДЛЯ ОДНОГО VLAN
#===============================================================================
generate_vlan_scope() {
    local vlan_id=$1
    local subnet=$2
    local mask=$3
    local range_start=$4
    local range_end=$5
    local gateway=$6
    local dns=$7
    local domain=$8
    
    cat << EOF
# VLAN $vlan_id
subnet $subnet netmask $mask {
  range $range_start $range_end;
  option routers $gateway;
  option domain-name "$domain";
  option domain-name-servers $dns;
  option subnet-mask $mask;
  option broadcast-address ${subnet%.*}.255;
  default-lease-time 600;
  max-lease-time 7200;
}
EOF
}

#===============================================================================
# ОСНОВНАЯ НАСТРОЙКА
#===============================================================================
setup_dhcp() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  DHCP Server Setup v2.0 (VLAN)         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    # 1. Установка
    log "Проверка пакетов..."
    if ! command -v dhcpd &>/dev/null; then
        log "Установка DHCP сервера..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y dhcp-server >/dev/null 2>&1
        log "DHCP сервер установлен"
    else
        log "DHCP сервер уже установлен"
    fi
    
    # 2. Выбор основного интерфейса
    echo -e "\n${YELLOW}=== Шаг 1: Основной интерфейс ===${NC}"
    get_interfaces
    read -p "Выберите интерфейс (номер): " iface_num
    MAIN_IFACE=$(sed -n "${iface_num}p" /tmp/dhcp_ifaces)
    MAIN_IP=$(ip -4 addr show "$MAIN_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)
    MAIN_NET=$(echo "$MAIN_IP" | cut -d'.' -f1-3)
    log "Выбран: $MAIN_IFACE ($MAIN_IP)"
    
    # 3. Глобальные настройки
    echo -e "\n${YELLOW}=== Шаг 2: Глобальные параметры ===${NC}"
    read -p "Домен [local.lan]: " DOMAIN
    DOMAIN="${DOMAIN:-local.lan}"
    read -p "DNS серверы [8.8.8.8, 77.88.8.8]: " DNS_SERVERS
    DNS_SERVERS="${DNS_SERVERS:-8.8.8.8, 77.88.8.8}"
    
    # 4. Настройка VLAN
    echo -e "\n${YELLOW}=== Шаг 3: Настройка VLAN ===${NC}"
    echo "Сколько VLAN нужно настроить? (1-10)"
    read -p "Количество VLAN: " vlan_count
    vlan_count=${vlan_count:-1}
    
    VLAN_CONFIG=""
    DHCP_INTERFACES="$MAIN_IFACE"
    
    for ((v=1; v<=vlan_count; v++)); do
        echo -e "\n${CYAN}--- VLAN #$v ---${NC}"
        
        # VLAN ID
        read -p "VLAN ID (10-4094) [$((10+v-1))]: " vlan_id
        vlan_id=${vlan_id:-$((10+v-1))}
        
        # Подсеть
        read -p "Подсеть [$MAIN_NET.0]: " subnet
        subnet="${subnet:-$MAIN_NET.0}"
        SUBNET_OCTETS=(${subnet//./ })
        
        # Маска
        read -p "Маска [255.255.255.0]: " mask
        mask="${mask:-255.255.255.0}"
        
        # Диапазон адресов
        read -p "Начало диапазона [${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.100]: " range_start
        range_start="${range_start:-${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.100}"
        read -p "Конец диапазона [${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.200]: " range_end
        range_end="${range_end:-${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.200}"
        
        # Шлюз
        read -p "Шлюз (обычно .1) [${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.1]: " gateway
        gateway="${gateway:-${SUBNET_OCTETS[0]}.${SUBNET_OCTETS[1]}.${SUBNET_OCTETS[2]}.1}"
        
        # Создаем подинтерфейс если нужно
        VLAN_IFACE="${MAIN_IFACE}.${vlan_id}"
        if ! ip link show "$VLAN_IFACE" &>/dev/null; then
            log "Создание интерфейса $VLAN_IFACE..."
            ip link add link "$MAIN_IFACE" name "$VLAN_IFACE" type vlan id "$vlan_id" 2>/dev/null || true
            ip addr add "$gateway/24" dev "$VLAN_IFACE" 2>/dev/null || true
            ip link set "$VLAN_IFACE" up 2>/dev/null || true
        fi
        
        DHCP_INTERFACES="$DHCP_INTERFACES $VLAN_IFACE"
        
        # Генерируем конфиг для этого VLAN
        VLAN_CONFIG+=$(generate_vlan_scope "$vlan_id" "$subnet" "$mask" "$range_start" "$range_end" "$gateway" "$DNS_SERVERS" "$DOMAIN")
        VLAN_CONFIG+=$'\n\n'
        
        log "VLAN $vlan_id: $subnet | $range_start-$range_end | GW: $gateway"
    done
    
    # 5. Генерация основного конфига
    echo -e "\n${YELLOW}=== Шаг 4: Генерация конфигурации ===${NC}"
    
    cat > "$DHCP_CONF" << EOF
# DHCP Server Configuration for VLANs
# Generated: $(date)

authoritative;

# Global settings
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

# Global options
option domain-name "$DOMAIN";
option domain-name-servers $DNS_SERVERS;

# VLAN Scopes
$VLAN_CONFIG
EOF
    
    chmod 644 "$DHCP_CONF"
    log "Конфиг создан: $DHCP_CONF"
    
    # 6. Настройка интерфейсов для dhcpd
    echo -e "\n${YELLOW}=== Шаг 5: Настройка службы ===${NC}"
    
    # Для ALT Linux
    if [[ -f /etc/sysconfig/dhcpd ]]; then
        echo "DHCPD_INTERFACE=\"$DHCP_INTERFACES\"" > /etc/sysconfig/dhcpd
        log "Настроен /etc/sysconfig/dhcpd"
    fi
    
    # Включаем и запускаем
    systemctl enable dhcpd 2>/dev/null || true
    systemctl restart dhcpd
    sleep 2
    
    if systemctl is-active dhcpd &>/dev/null; then
        log "DHCP сервер запущен"
    else
        warn "DHCP сервер не запустился, проверяем конфиг..."
        dhcpd -t -cf "$DHCP_CONF" 2>&1 | head -10 || true
    fi
    
    # 7. Финальная проверка
    echo -e "\n${GREEN}=== ИТОГОВАЯ ПРОВЕРКА ===${NC}"
    
    echo "Интерфейсы DHCP:"
    echo "$DHCP_INTERFACES" | tr ' ' '\n' | grep -v '^$' | sed 's/^/  • /'
    
    echo -e "\nКонфигурация:"
    grep -E "^subnet|^  range|^  option routers" "$DHCP_CONF" | sed 's/^/  /'
    
    echo -e "\nСтатус службы:"
    systemctl status dhcpd --no-pager -n 3 2>/dev/null | grep -E "Active|Loaded" | sed 's/^/  /'
    
    echo -e "\n${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}"
    echo ""
    echo "Полезные команды:"
    echo "  systemctl status dhcpd"
    echo "  journalctl -u dhcpd -f"
    echo "  dhcpd -t -cf $DHCP_CONF  # проверка конфига"
    echo "  tail -f /var/log/messages | grep dhcpd"
    echo ""
    echo "Клиенты получат адреса из указанных диапазонов по VLAN!"
}

#===============================================================================
# МЕНЮ
#===============================================================================
while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  DHCP Server Setup v2.0                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) Настроить DHCP сервер (VLAN)"
    echo "2) Проверить конфигурацию"
    echo "3) Перезапустить DHCP"
    echo "4) Показать логи"
    echo "5) Выход"
    echo ""
    
    read -p "Выбор [1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1) setup_dhcp; read -p "Нажмите Enter..." ;;
        2) 
            echo -e "\n${CYAN}Проверка конфига:${NC}"
            dhcpd -t -cf "$DHCP_CONF" 2>&1 || echo "Ошибка в конфиге"
            read -p "Нажмите Enter..."
            ;;
        3)
            systemctl restart dhcpd
            systemctl status dhcpd --no-pager -n 5
            read -p "Нажмите Enter..."
            ;;
        4)
            journalctl -u dhcpd --no-pager -n 20
            read -p "Нажмите Enter..."
            ;;
        5) exit 0 ;;
        *) warn "Неверный выбор" ;;
    esac
done
