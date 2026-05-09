#!/bin/bash
#
# Скрипт настройки GRE туннеля и OSPF для Alt Linux
# Версия: 1.0
#

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# КОНФИГУРАЦИЯ - ИЗМЕНИТЕ ПОД ВАШУ СЕТЬ
# ============================================

# Параметры GRE туннеля
LOCAL_IP=""           # Ваш внешний IP (например, 192.168.5.2)
REMOTE_IP=""          # IP удаленного роутера (например, 192.168.5.1)
GRE_LOCAL_IP=""       # IP туннеля на этом роутере (например, 172.16.1.2)
GRE_REMOTE_IP=""      # IP туннеля на удаленном роутере (например, 172.16.1.1)
GRE_NETMASK="24"      # Маска туннельной сети

# OSPF параметры
ROUTER_ID=""          # Router ID OSPF (например, 2.2.2.2)
OSPF_NETWORKS=""      # Сети для OSPF через пробел (например, "192.168.6.0/28 172.16.1.0/24")
OSPF_AREA="0"         # Area ID
AUTH_KEY="123"        # Ключ аутентификации OSPF

# Интерфейсы
WAN_INTERFACE=""      # Внешний интерфейс (например, ens33)
LAN_INTERFACE=""      # Внутренний интерфейс (например, ens37)

# ============================================
# ФУНКЦИИ
# ============================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "Скрипт должен запускаться от root"
        exit 1
    fi
}

check_config() {
    log_info "Проверка конфигурации..."
    
    if [ -z "$LOCAL_IP" ] || [ -z "$REMOTE_IP" ] || [ -z "$GRE_LOCAL_IP" ]; then
        log_error "Не заполнены обязательные параметры конфигурации!"
        exit 1
    fi
    
    if [ -z "$WAN_INTERFACE" ] || [ -z "$LAN_INTERFACE" ]; then
        log_error "Не указаны сетевые интерфейсы!"
        exit 1
    fi
}

install_packages() {
    log_info "Установка необходимых пакетов..."
    
    if ! command -v vtysh &> /dev/null; then
        log_info "Установка FRRouting..."
        apt-get update && apt-get install -y frr frr-pythontools || \
        yum install -y frr || \
        log_warn "FRR уже установлен или не найден менеджер пакетов"
    fi
    
    if ! command -v iptables &> /dev/null; then
        log_info "Установка iptables..."
        apt-get install -y iptables || yum install -y iptables
    fi
}

create_gre_systemd_service() {
    log_info "Создание systemd service для GRE туннеля..."
    
    cat > /etc/systemd/system/gre-tunnel.service << EOF
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${LOCAL_IP} remote ${REMOTE_IP} ttl 64
ExecStart=/sbin/ip addr add ${GRE_LOCAL_IP}/${GRE_NETMASK} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1476
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-tunnel.service
    log_info "GRE tunnel service создан и включен в автозагрузку"
}

configure_frr() {
    log_info "Настройка FRRouting..."
    
    # Включаем OSPF в /etc/frr/daemons
    sed -i 's/ospfd=no/ospfd=yes/g' /etc/frr/daemons
    
    # Создаем конфигурацию OSPF
    cat > /etc/frr/frr.conf << EOF
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id ${ROUTER_ID}
 passive-interface default
 no passive-interface gre1
 ip ospf authentication
 ip ospf authentication-key ${AUTH_KEY}
EOF

    # Добавляем сети OSPF
    for network in $OSPF_NETWORKS; do
        echo " network $network area $OSPF_AREA" >> /etc/frr/frr.conf
    done
    
    cat >> /etc/frr/frr.conf << EOF
!
line vty
!
EOF

    log_info "Конфигурация FRR создана"
}

configure_firewall() {
    log_info "Настройка firewall..."
    
    # Включаем IP forwarding
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1
    
    # Очищаем старые правила NAT
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    
    # Добавляем MASQUERADE для GRE туннеля
    iptables -t nat -A POSTROUTING -s 192.168.6.0/28 -o gre1 -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.1.0/24 -o gre1 -j MASQUERADE
    
    # Сохраняем правила iptables
    if command -v iptables-save &> /dev/null; then
        if [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4
        elif [ -f /etc/sysconfig/iptables ]; then
            iptables-save > /etc/sysconfig/iptables
        fi
    fi
    
    # Разрешаем OSPF трафик (протокол 89)
    iptables -A INPUT -p ospf -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p ospf -j ACCEPT 2>/dev/null || true
    
    log_info "Firewall настроен"
}

enable_services() {
    log_info "Включение служб..."
    
    systemctl enable frr
    systemctl enable gre-tunnel
    
    log_info "Службы включены в автозагрузку"
}

start_services() {
    log_info "Запуск служб..."
    
    # Запускаем GRE туннель
    systemctl start gre-tunnel || {
        log_warn "Не удалось запустить gre-tunnel через systemd, пробуем вручную..."
        ip tunnel add gre1 mode gre local $LOCAL_IP remote $REMOTE_IP ttl 64 || true
        ip addr add ${GRE_LOCAL_IP}/${GRE_NETMASK} dev gre1 || true
        ip link set gre1 up || true
    }
    
    # Перезапускаем FRR
    systemctl restart frr
    
    sleep 2
    
    log_info "Службы запущены"
}

verify_configuration() {
    log_info "Проверка конфигурации..."
    
    echo ""
    echo "=== Проверка GRE туннеля ==="
    ip link show gre1 && echo "✓ GRE туннель поднят" || echo "✗ GRE туннель НЕ поднят"
    ip addr show gre1
    
    echo ""
    echo "=== Проверка OSPF соседей ==="
    if command -v vtysh &> /dev/null; then
        vtysh -c "show ip ospf neighbor" || echo "OSPF neighbors не найдены"
    fi
    
    echo ""
    echo "=== Проверка маршрутов ==="
    ip route show | grep -E "(gre1|ospf)" || echo "OSPF маршруты не найдены"
    
    echo ""
    echo "=== Проверка NAT ==="
    iptables -t nat -L POSTROUTING -n -v | grep -E "(gre1|MASQUERADE)" || echo "NAT правила не найдены"
    
    echo ""
    echo "=== Статус служб ==="
    systemctl status gre-tunnel --no-pager -l || true
    systemctl status frr --no-pager -l || true
}

# ============================================
# ОСНОВНОЙ СЦЕНАРИЙ
# ============================================

main() {
    echo "========================================"
    echo "  Настройка GRE туннеля и OSPF"
    echo "  Alt Linux"
    echo "========================================"
    echo ""
    
    check_root
    check_config
    
    log_info "Начало настройки..."
    
    install_packages
    create_gre_systemd_service
    configure_frr
    configure_firewall
    enable_services
    start_services
    verify_configuration
    
    echo ""
    log_info "Настройка завершена!"
    log_info "Для проверки используйте:"
    echo "  vtysh -c \"show ip ospf neighbor\""
    echo "  ip route show"
    echo "  ping <IP_удаленной_сети>"
}

# Запуск
main "$@"
