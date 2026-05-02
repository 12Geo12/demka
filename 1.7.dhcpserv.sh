#!/bin/bash
#===============================================================================
# Скрипт настройки DHCP сервера для Demo2026
# АДАПТИРОВАН: HQ-CLI отсутствует, DHCP только для HQ-SRV (VLAN 100)
#
# На основе: https://каб-220.рф/ru/demo-2026/modul-1/modul-1-9
#
# Топология:
#   HQ-RTR (DHCP сервер) <---> HQ-SRV (DHCP клиент)
#   VLAN 100 (SRV-Net): 192.168.1.0/27
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Параметры сети VLAN 100 (SRV-Net)
VLAN100_NETWORK="192.168.1.0"
VLAN100_NETMASK="255.255.255.224"    # /27 = 32 адреса
VLAN100_GATEWAY="192.168.1.1"         # Адрес HQ-RTR в VLAN100
VLAN100_DNS="192.168.1.1"             # DNS будет на HQ-SRV (можно изменить)
VLAN100_DNS_SUFFIX="au-team.irpo"
VLAN100_RANGE_START="192.168.1.2"     # Исключаем адрес шлюза (192.168.1.1)
VLAN100_RANGE_END="192.168.1.30"      # Последний адрес в подсети /27

# Функции вывода
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() { echo -e "${GREEN}[✓] $1${NC}"; }
print_error() { echo -e "${RED}[✗] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
print_info() { echo -e "${BLUE}[i] $1${NC}"; }

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите скрипт от имени root"
        exit 1
    fi
}

# Определение интерфейса для DHCP
detect_dhcp_interface() {
    print_header "Определение интерфейса для DHCP"

    echo -e "\nДоступные VLAN интерфейсы:"
    ip -br link show type vlan 2>/dev/null || ip -br link show

    echo -e "\nТекущие IP-адреса:"
    ip -br addr show

    echo ""
    echo "Введите имя интерфейса для DHCP сервера (например: vlan100)"
    echo "Или нажмите Enter для автоматического определения"
    read -r DHCP_INTERFACE

    if [ -z "$DHCP_INTERFACE" ]; then
        # Поиск интерфейса с IP из сети 192.168.1.x
        DHCP_INTERFACE=$(ip -br addr show | grep "192.168.1" | awk '{print $1}')
        if [ -n "$DHCP_INTERFACE" ]; then
            print_success "Найден интерфейс: $DHCP_INTERFACE"
        else
            print_warning "Интерфейс не определён автоматически"
            read -r -p "Введите имя интерфейса: " DHCP_INTERFACE
        fi
    fi

    if [ ! -d "/sys/class/net/$DHCP_INTERFACE" ]; then
        print_error "Интерфейс $DHCP_INTERFACE не существует"
        exit 1
    fi

    print_success "Выбран интерфейс: $DHCP_INTERFACE"
}

# Установка DHCP сервера
install_dhcp_server() {
    print_header "Установка DHCP сервера"

    if rpm -q dhcp-server &>/dev/null; then
        print_success "Пакет dhcp-server уже установлен"
    else
        print_info "Установка dhcp-server..."
        dnf install -y dhcp-server

        if [ $? -eq 0 ]; then
            print_success "Пакет dhcp-server успешно установлен"
        else
            print_error "Ошибка установки dhcp-server"
            exit 1
        fi
    fi
}

# Настройка конфигурации DHCP
configure_dhcp() {
    print_header "Настройка DHCP сервера"

    DHCP_CONF="/etc/dhcp/dhcpd.conf"

    # Резервное копирование
    if [ -f "$DHCP_CONF" ]; then
        cp "$DHCP_CONF" "${DHCP_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        print_info "Создана резервная копия"
    fi

    # Создание конфигурации для VLAN 100
    cat > "$DHCP_CONF" << EOF
# DHCP конфигурация для Demo2026
# VLAN 100 (SRV-Net) - сеть в сторону HQ-SRV
# Адрес маршрутизатора (192.168.1.1) исключён из диапазона выдачи

# Глобальные параметры
authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

# Подсеть VLAN100 (SRV-Net)
subnet ${VLAN100_NETWORK} netmask ${VLAN100_NETMASK} {
    # Диапазон выдачи IP-адресов (исключён адрес шлюза 192.168.1.1)
    range ${VLAN100_RANGE_START} ${VLAN100_RANGE_END};

    # DNS-сервер (может быть внешним или локальным)
    option domain-name-servers ${VLAN100_DNS};

    # DNS-суффикс
    option domain-name "${VLAN100_DNS_SUFFIX}";

    # Шлюз по умолчанию (HQ-RTR)
    option routers ${VLAN100_GATEWAY};

    # Время аренды
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

    print_success "Конфигурация создана: $DHCP_CONF"

    echo ""
    echo -e "${YELLOW}Содержимое конфигурации:${NC}"
    echo "----------------------------------------"
    cat "$DHCP_CONF"
    echo "----------------------------------------"
}

# Настройка интерфейса для прослушивания DHCP
configure_dhcp_interface() {
    print_header "Настройка интерфейса прослушивания DHCP"

    DHCP_SYSCONFIG="/etc/sysconfig/dhcpd"

    if [ -f "$DHCP_SYSCONFIG" ]; then
        cp "$DHCP_SYSCONFIG" "${DHCP_SYSCONFIG}.bak"
    fi

    cat > "$DHCP_SYSCONFIG" << EOF
# Интерфейс DHCP сервера
DHCPDARGS="${DHCP_INTERFACE}"
EOF

    print_success "Интерфейс $DHCP_INTERFACE настроен для DHCP"
}

# Настройка firewall
configure_firewall() {
    print_header "Настройка firewall для DHCP"

    if command -v nft &>/dev/null; then
        print_info "Настройка nftables..."

        # Создаём таблицу если нет
        nft add table inet filter 2>/dev/null || true

        # Создаём цепь input если нет
        nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null || true

        # Добавляем правила DHCP
        if ! nft list chain inet filter input 2>/dev/null | grep -q "udp dport 67"; then
            nft add rule inet filter input udp dport 67 accept
            print_success "Правило для UDP 67 добавлено"
        fi

        if ! nft list chain inet filter input 2>/dev/null | grep -q "udp dport 68"; then
            nft add rule inet filter input udp dport 68 accept
            print_success "Правило для UDP 68 добавлено"
        fi

    elif command -v iptables &>/dev/null; then
        print_info "Настройка iptables..."

        iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
        print_success "Правила iptables добавлены"
    else
        print_warning "Firewall не обнаружен"
    fi
}

# Запуск DHCP сервера
start_dhcp_service() {
    print_header "Запуск DHCP сервера"

    systemctl stop dhcpd 2>/dev/null || true

    print_info "Запуск dhcpd..."
    systemctl enable --now dhcpd

    if [ $? -eq 0 ]; then
        print_success "Сервис dhcpd запущен"
    else
        print_error "Ошибка запуска dhcpd"
        journalctl -u dhcpd -n 20 --no-pager
        exit 1
    fi

    echo ""
    systemctl status dhcpd --no-pager || true
}

# Проверка работы
verify_dhcp() {
    print_header "Проверка работы DHCP"

    echo -e "\n${YELLOW}Порт 67 (DHCP):${NC}"
    ss -ulnp | grep ":67" && print_success "DHCP слушает порт 67" || print_warning "Порт 67 не прослушивается"

    echo -e "\n${YELLOW}Валидация конфигурации:${NC}"
    dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1 && print_success "Конфигурация валидна" || print_error "Ошибка конфигурации"
}

# Основная функция
main() {
    clear
    print_header "Настройка DHCP для HQ-SRV (VLAN 100)"
    echo ""
    echo "Конфигурация:"
    echo "  VLAN 100 (SRV-Net): ${VLAN100_NETWORK}/27"
    echo "  Шлюз (HQ-RTR): ${VLAN100_GATEWAY}"
    echo "  Диапазон DHCP: ${VLAN100_RANGE_START} - ${VLAN100_RANGE_END}"
    echo "  DNS-суффикс: ${VLAN100_DNS_SUFFIX}"
    echo ""

    read -r -p "Продолжить? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Отмена."
        exit 0
    fi

    check_root
    detect_dhcp_interface
    install_dhcp_server
    configure_dhcp
    configure_dhcp_interface
    configure_firewall
    start_dhcp_service
    verify_dhcp

    print_header "Настройка завершена!"
    echo ""
    echo -e "${GREEN}DHCP сервер настроен для VLAN 100${NC}"
    echo ""
    echo "На HQ-SRV настройте сетевой интерфейс:"
    echo "  1. nmtui"
    echo "  2. Выберите vlan100"
    echo "  3. IPv4: Автоматически"
    echo "  4. Активируйте"
    echo ""
    echo "HQ-SRV получит IP из диапазона ${VLAN100_RANGE_START} - ${VLAN100_RANGE_END}"
}

main "$@"
