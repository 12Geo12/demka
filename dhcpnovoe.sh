#!/bin/bash
################################################################################
# Скрипт настройки DHCP сервера для ALT Server
# Сервер: HQ-RTR (маршрутизатор)
# Проект: Demo2026 - au-team.irpo
################################################################################

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/dhcp-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
error() { log "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    error "Требуется root (используйте sudo)"
fi

clear
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      Настройка DHCP сервера на HQ-RTR                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Ввод параметров
read -p "Доменное имя [au-team.irpo]: " DOMAIN
DOMAIN=${DOMAIN:-au-team.irpo}

read -p "IP DNS-сервера (HQ-SRV) [192.168.10.2]: " DNS_IP
DNS_IP=${DNS_IP:-192.168.10.2}

read -p "IP этого сервера (шлюз) [192.168.20.1]: " SERVER_IP
SERVER_IP=${SERVER_IP:-192.168.20.1}

read -p "Сеть DHCP [192.168.20.0]: " DHCP_NETWORK
DHCP_NETWORK=${DHCP_NETWORK:-192.168.20.0}

read -p "Маска подсети [255.255.255.240]: " DHCP_NETMASK
DHCP_NETMASK=${DHCP_NETMASK:-255.255.255.240}

read -p "Начало диапазона [192.168.20.2]: " RANGE_START
RANGE_START=${RANGE_START:-192.168.20.2}

read -p "Конец диапазона [192.168.20.14]: " RANGE_END
RANGE_END=${RANGE_END:-192.168.20.14}

echo ""
info "Определение сетевого интерфейса..."
ip addr show | grep -E "^[0-9]+:" | grep -v "lo:"
read -p "Введите имя интерфейса для DHCP (например ens224.200): " DHCP_INTERFACE
if [[ -z "$DHCP_INTERFACE" ]]; then
    DHCP_INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp)' | head -1)
    warn "Выбран интерфейс по умолчанию: $DHCP_INTERFACE"
fi

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "Параметры конфигурации:"
echo "  Домен:           $DOMAIN"
echo "  DNS-сервер:      $DNS_IP"
echo "  Шлюз:            $SERVER_IP"
echo "  Сеть:            $DHCP_NETWORK/$DHCP_NETMASK"
echo "  Диапазон:        $RANGE_START - $RANGE_END"
echo "  Интерфейс:       $DHCP_INTERFACE"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

read -p "Продолжить? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    error "Отменено"
fi

# Установка
info "Установка ISC DHCP Server..."
apt-get update
apt-get install -y isc-dhcp-server

# Конфигурация dhcpd.conf
info "Создание конфигурации DHCP..."
cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP Server Configuration for $DOMAIN
# Server: HQ-RTR
# Generated: $(date)

ddns-update-style none;
authoritative;
log-facility local7;

subnet $DHCP_NETWORK netmask $DHCP_NETMASK {
    option routers $SERVER_IP;
    option subnet-mask $DHCP_NETMASK;
    option domain-name-servers $DNS_IP;
    option domain-name "$DOMAIN";
    option ntp-servers $DNS_IP;
    
    range dynamic-bootp $RANGE_START $RANGE_END;
    
    default-lease-time 21600;
    max-lease-time 43200;
}
EOF

success "Конфигурация создана: /etc/dhcp/dhcpd.conf"

# Настройка интерфейса
if [[ -f /etc/default/isc-dhcp-server ]]; then
    sed -i "s/INTERFACESv4=\"\"/INTERFACESv4=\"$DHCP_INTERFACE\"/" /etc/default/isc-dhcp-server
    success "DHCP привязан к интерфейсу: $DHCP_INTERFACE"
fi

# Проверка
info "Проверка конфигурации..."
if dhcpd -t -cf /etc/dhcp/dhcpd.conf &>/dev/null; then
    success "Конфигурация проверена - ошибок нет"
else
    error "Ошибка в конфигурации DHCP"
fi

# Запуск службы
info "Запуск DHCP сервера..."
systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

sleep 2
if systemctl is-active --quiet isc-dhcp-server; then
    success "DHCP сервер запущен и работает"
else
    error "DHCP сервер не запустился"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           DHCP НАСТРОЕН УСПЕШНО!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Полезные команды:"
echo "  - Статус:      systemctl status isc-dhcp-server"
echo "  - Лог:         tail -f /var/log/syslog | grep dhcp"
echo "  - Аренды:      cat /var/lib/dhcp/dhcpd.leases"
echo ""
info "Лог: $LOG_FILE"
