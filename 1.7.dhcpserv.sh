#!/bin/bash
#===============================================================================
# DHCP Server Setup for Demo2026
# Автоматическое определение интерфейсов + интерактивное взаимодействие
#
# На основе: https://каб-220.рф/ru/demo-2026/modul-1/modul-1-9
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Глобальные переменные
DHCP_INTERFACE=""
SELECTED_VLAN=""
NETWORK=""
NETMASK=""
GATEWAY=""
DNS=""
DNS_SUFFIX="au-team.irpo"
RANGE_START=""
RANGE_END=""

# Функции вывода
print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BLUE}$1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_success() { echo -e "${GREEN}[✓] $1${NC}"; }
print_error() { echo -e "${RED}[✗] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
print_info() { echo -e "${BLUE}[i] $1${NC}"; }

print_menu() {
    echo -e "${YELLOW}[$1]${NC} $2"
}

pause() {
    echo ""
    read -r -p "Нажмите Enter для продолжения..."
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите скрипт от имени root (sudo)"
        exit 1
    fi
}

# Автоматическое определение всех VLAN интерфейсов
detect_vlan_interfaces() {
    print_header "Автоматическое определение VLAN интерфейсов"

    echo -e "\n${BLUE}Поиск VLAN интерфейсов...${NC}\n"

    # Получаем все VLAN интерфейсы с их IP адресами
    declare -a VLAN_NAMES
    declare -a VLAN_IPS
    declare -a VLAN_NETWORKS

    i=0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            iface=$(echo "$line" | awk '{print $1}')
            ip_info=$(echo "$line" | awk '{print $3}')

            if [ -n "$ip_info" ]; then
                ip_addr=$(echo "$ip_info" | cut -d'/' -f1)

                # Определяем сеть по IP
                case "$ip_addr" in
                    192.168.1.*)
                        network="VLAN100 (SRV-Net) - 192.168.1.0/27"
                        vlan_id="100"
                        ;;
                    192.168.2.*)
                        network="VLAN200 (CLI-Net) - 192.168.2.0/28"
                        vlan_id="200"
                        ;;
                    192.168.3.*)
                        network="VLAN999 (Management) - 192.168.3.0/29"
                        vlan_id="999"
                        ;;
                    *)
                        network="Неизвестная сеть"
                        vlan_id="?"
                        ;;
                esac

                VLAN_NAMES[$i]="$iface"
                VLAN_IPS[$i]="$ip_addr"
                VLAN_NETWORKS[$i]="$network"

                echo -e "  ${GREEN}[$((i+1))]${NC} $iface ${YELLOW}→${NC} $ip_addr ${CYAN}($network)${NC}"
                ((i++))
            fi
        fi
    done < <(ip -br addr show type vlan 2>/dev/null)

    # Если VLAN интерфейсов нет, показываем все
    if [ ${#VLAN_NAMES[@]} -eq 0 ]; then
        print_warning "VLAN интерфейсы не найдены. Показываю все интерфейсы:"

        while IFS= read -r line; do
            if [ -n "$line" ]; then
                iface=$(echo "$line" | awk '{print $1}')
                ip_info=$(echo "$line" | awk '{print $3}')

                if [ -n "$ip_info" ] && [ "$iface" != "lo" ]; then
                    ip_addr=$(echo "$ip_info" | cut -d'/' -f1)

                    VLAN_NAMES[$i]="$iface"
                    VLAN_IPS[$i]="$ip_addr"
                    VLAN_NETWORKS[$i]="Физический интерфейс"

                    echo -e "  ${GREEN}[$((i+1))]${NC} $iface ${YELLOW}→${NC} $ip_addr"
                    ((i++))
                fi
            fi
        done < <(ip -br addr show 2>/dev/null)
    fi

    VLAN_COUNT=${#VLAN_NAMES[@]}

    if [ $VLAN_COUNT -eq 0 ]; then
        print_error "Не найдено ни одного интерфейса с IP-адресом"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

    # Выбор интерфейса
    while true; do
        echo ""
        read -r -p "Выберите интерфейс для DHCP [1-$VLAN_COUNT]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$VLAN_COUNT" ]; then
            idx=$((choice-1))
            DHCP_INTERFACE="${VLAN_NAMES[$idx]}"
            GATEWAY="${VLAN_IPS[$idx]}"
            SELECTED_VLAN="${VLAN_NETWORKS[$idx]}"

            print_success "Выбран: $DHCP_INTERFACE ($GATEWAY - $SELECTED_VLAN)"
            break
        else
            print_error "Неверный выбор. Введите число от 1 до $VLAN_COUNT"
        fi
    done
}

# Расчёт параметров сети на основе IP шлюза
calculate_network_params() {
    print_header "Расчёт параметров сети"

    echo -e "\n${BLUE}Анализ IP адреса: $GATEWAY${NC}\n"

    # Определяем подсеть по последнему октету IP шлюза
    IFS='.' read -r o1 o2 o3 o4 <<< "$GATEWAY"

    case "$o3" in
        1)
            # VLAN 100 - SRV-Net
            NETWORK="192.168.1.0"
            NETMASK="255.255.255.224"
            PREFIX="27"
            RANGE_START="192.168.1.2"
            RANGE_END="192.168.1.30"
            DNS="192.168.1.1"
            print_info "Обнаружена сеть: VLAN100 (SRV-Net)"
            ;;
        2)
            # VLAN 200 - CLI-Net
            NETWORK="192.168.2.0"
            NETMASK="255.255.255.240"
            PREFIX="28"
            RANGE_START="192.168.2.2"
            RANGE_END="192.168.2.14"
            DNS="192.168.1.2"
            print_info "Обнаружена сеть: VLAN200 (CLI-Net)"
            ;;
        3)
            # VLAN 999 - Management
            NETWORK="192.168.3.0"
            NETMASK="255.255.255.248"
            PREFIX="29"
            RANGE_START="192.168.3.2"
            RANGE_END="192.168.3.6"
            DNS="192.168.1.2"
            print_info "Обнаружена сеть: VLAN999 (Management)"
            ;;
        *)
            print_warning "Неизвестная сеть. Используйте ручной ввод."
            manual_network_config
            return
            ;;
    esac

    echo ""
    echo -e "${YELLOW}Автоматически определённые параметры:${NC}"
    echo -e "  Сеть:           ${GREEN}$NETWORK/$PREFIX${NC}"
    echo -e "  Маска:          ${GREEN}$NETMASK${NC}"
    echo -e "  Шлюз (HQ-RTR):  ${GREEN}$GATEWAY${NC}"
    echo -e "  Диапазон DHCP:  ${GREEN}$RANGE_START - $RANGE_END${NC}"
    echo -e "  DNS-сервер:     ${GREEN}$DNS${NC}"
    echo -e "  DNS-суффикс:    ${GREEN}$DNS_SUFFIX${NC}"

    echo ""
    print_menu "1" "Использовать эти параметры"
    print_menu "2" "Изменить параметры вручную"
    echo ""
    read -r -p "Выбор [1-2]: " choice

    case "$choice" in
        2)
            manual_network_config
            ;;
        *)
            print_success "Параметры подтверждены"
            ;;
    esac
}

# Ручной ввод параметров сети
manual_network_config() {
    print_header "Ручная настройка параметров сети"

    echo ""
    read -r -p "Сеть (например, 192.168.1.0): " NETWORK
    read -r -p "Маска (например, 255.255.255.224): " NETMASK
    read -r -p "Шлюз (например, 192.168.1.1): " GATEWAY
    read -r -p "Начало диапазона DHCP: " RANGE_START
    read -r -p "Конец диапазона DHCP: " RANGE_END
    read -r -p "DNS-сервер: " DNS
    read -r -p "DNS-суффикс [au-team.irpo]: " input_suffix
    DNS_SUFFIX="${input_suffix:-au-team.irpo}"

    print_success "Параметры заданы вручную"
}

# Интерактивное редактирование параметров
edit_parameters() {
    print_header "Редактирование параметров DHCP"

    while true; do
        echo ""
        echo -e "${CYAN}Текущие параметры:${NC}"
        echo -e "  ${YELLOW}[1]${NC} Сеть:           $NETWORK"
        echo -e "  ${YELLOW}[2]${NC} Маска:          $NETMASK"
        echo -e "  ${YELLOW}[3]${NC} Шлюз:           $GATEWAY"
        echo -e "  ${YELLOW}[4]${NC} Диапазон DHCP:  $RANGE_START - $RANGE_END"
        echo -e "  ${YELLOW}[5]${NC} DNS-сервер:     $DNS"
        echo -e "  ${YELLOW}[6]${NC} DNS-суффикс:    $DNS_SUFFIX"
        echo -e "  ${YELLOW}[S]${NC} Сохранить и продолжить"
        echo -e "  ${YELLOW}[C]${NC} Отмена"
        echo ""

        read -r -p "Выберите параметр для изменения [1-6/S/C]: " choice

        case "$choice" in
            1) read -r -p "Сеть: " NETWORK ;;
            2) read -r -p "Маска: " NETMASK ;;
            3) read -r -p "Шлюз: " GATEWAY ;;
            4)
                read -r -p "Начало диапазона: " RANGE_START
                read -r -p "Конец диапазона: " RANGE_END
                ;;
            5) read -r -p "DNS-сервер: " DNS ;;
            6) read -r -p "DNS-суффикс: " DNS_SUFFIX ;;
            [Ss])
                print_success "Параметры сохранены"
                return 0
                ;;
            [Cc])
                print_warning "Изменения отменены"
                return 1
                ;;
            *)
                print_error "Неверный выбор"
                ;;
        esac
    done
}

# Предпросмотр конфигурации
preview_config() {
    print_header "Предпросмотр конфигурации DHCP"

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} Файл: /etc/dhcp/dhcpd.conf"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}authoritative;${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}default-lease-time 600;${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}max-lease-time 7200;${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}subnet ${NETWORK} netmask ${NETMASK} {${NC}"
    echo -e "${CYAN}║${NC}     ${BLUE}range ${RANGE_START} ${RANGE_END};${NC}"
    echo -e "${CYAN}║${NC}     ${BLUE}option domain-name-servers ${DNS};${NC}"
    echo -e "${CYAN}║${NC}     ${BLUE}option domain-name \"${DNS_SUFFIX}\";${NC}"
    echo -e "${CYAN}║${NC}     ${BLUE}option routers ${GATEWAY};${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}}${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

    echo ""
    echo -e "${YELLOW}Примечание:${NC} Адрес шлюза ${GATEWAY} исключён из диапазона выдачи"
    echo ""
}

# Подтверждение перед применением
confirm_apply() {
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ВНИМАНИЕ! Это действие перезапишет существующую конфигурацию${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo ""

    print_menu "Y" "Применить конфигурацию"
    print_menu "E" "Редактировать параметры"
    print_menu "C" "Отмена"

    echo ""
    read -r -p "Выбор [Y/E/C]: " choice

    case "$choice" in
        [Yy])
            return 0
            ;;
        [Ee])
            if edit_parameters; then
                preview_config
                confirm_apply
            else
                confirm_apply
            fi
            return $?
            ;;
        *)
            print_warning "Операция отменена"
            exit 0
            ;;
    esac
}

# Установка DHCP сервера
install_dhcp_server() {
    print_header "Установка DHCP сервера"

    if rpm -q dhcp-server &>/dev/null; then
        print_success "Пакет dhcp-server уже установлен"
        return 0
    fi

    print_info "Установка dhcp-server..."
    dnf install -y dhcp-server

    if [ $? -eq 0 ]; then
        print_success "Пакет dhcp-server установлен"
    else
        print_error "Ошибка установки"
        exit 1
    fi
}

# Создание конфигурации
create_dhcp_config() {
    print_header "Создание конфигурации DHCP"

    DHCP_CONF="/etc/dhcp/dhcpd.conf"

    # Резервное копирование
    if [ -f "$DHCP_CONF" ]; then
        BACKUP_FILE="${DHCP_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$DHCP_CONF" "$BACKUP_FILE"
        print_info "Резервная копия: $BACKUP_FILE"
    fi

    # Создание конфигурации
    cat > "$DHCP_CONF" << EOF
# DHCP Configuration for Demo2026
# Generated: $(date)
# Interface: $DHCP_INTERFACE
# Network: $SELECTED_VLAN

authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

subnet ${NETWORK} netmask ${NETMASK} {
    range ${RANGE_START} ${RANGE_END};
    option domain-name-servers ${DNS};
    option domain-name "${DNS_SUFFIX}";
    option routers ${GATEWAY};
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

    print_success "Конфигурация создана: $DHCP_CONF"
}

# Настройка интерфейса в sysconfig
configure_sysconfig() {
    print_header "Настройка sysconfig"

    SYSCONFIG="/etc/sysconfig/dhcpd"

    if [ -f "$SYSCONFIG" ]; then
        cp "$SYSCONFIG" "${SYSCONFIG}.bak"
    fi

    cat > "$SYSCONFIG" << EOF
# DHCP Server Configuration
DHCPDARGS="${DHCP_INTERFACE}"
EOF

    print_success "Интерфейс $DHCP_INTERFACE указан в $SYSCONFIG"
}

# Настройка firewall
configure_firewall() {
    print_header "Настройка Firewall"

    # nftables
    if command -v nft &>/dev/null; then
        print_info "Настройка nftables..."

        nft add table inet filter 2>/dev/null
        nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null

        # Проверка и добавление правил
        if ! nft list chain inet filter input 2>/dev/null | grep -q "udp dport 67 accept"; then
            nft add rule inet filter input udp dport 67 accept
            nft add rule inet filter input udp dport 68 accept
            print_success "Правила nftables добавлены"
        else
            print_info "Правила уже существуют"
        fi
        return
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        print_info "Настройка iptables..."

        iptables -C INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport 67 -j ACCEPT
        iptables -C INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport 68 -j ACCEPT

        print_success "Правила iptables добавлены"
        return
    fi

    print_warning "Firewall не обнаружен"
}

# Запуск сервиса
start_service() {
    print_header "Запуск DHCP сервера"

    # Валидация конфигурации
    print_info "Проверка конфигурации..."
    if ! dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1; then
        print_error "Ошибка в конфигурации DHCP"
        exit 1
    fi
    print_success "Конфигурация валидна"

    # Остановка и запуск
    systemctl stop dhcpd 2>/dev/null || true

    print_info "Запуск сервиса dhcpd..."
    systemctl enable --now dhcpd

    sleep 2

    if systemctl is-active --quiet dhcpd; then
        print_success "Сервис dhcpd успешно запущен"
    else
        print_error "Ошибка запуска dhcpd"
        echo ""
        journalctl -u dhcpd -n 30 --no-pager
        exit 1
    fi
}

# Итоговая информация
show_result() {
    print_header "Настройка завершена"

    echo ""
    echo -e "${GREEN}DHCP сервер успешно настроен!${NC}"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Параметры DHCP:${NC}"
    echo -e "  Интерфейс:      ${YELLOW}$DHCP_INTERFACE${NC}"
    echo -e "  Сеть:           ${YELLOW}$NETWORK${NC}"
    echo -e "  Диапазон IP:    ${YELLOW}$RANGE_START - $RANGE_END${NC}"
    echo -e "  Шлюз:           ${YELLOW}$GATEWAY${NC}"
    echo -e "  DNS:            ${YELLOW}$DNS${NC}"
    echo -e "  DNS-суффикс:    ${YELLOW}$DNS_SUFFIX${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo -e "${BLUE}Статус сервиса:${NC}"
    systemctl status dhcpd --no-pager -l | head -10

    echo ""
    echo -e "${GREEN}Для проверки на клиенте:${NC}"
    echo -e "  ${YELLOW}# nmcli con reload${NC}"
    echo -e "  ${YELLOW}# nmcli con up <vlan-интерфейс>${NC}"
    echo -e "  ${YELLOW}# ip addr show${NC}"
    echo ""
}

# Главная функция
main() {
    print_header "DHCP Server Setup for Demo2026"
    echo ""
    echo -e "${BLUE}Настройка DHCP сервера согласно заданию${NC}"
    echo ""

    # Выполнение
    check_root
    pause

    detect_vlan_interfaces
    pause

    calculate_network_params
    pause

    preview_config
    confirm_apply

    install_dhcp_server
    create_dhcp_config
    configure_sysconfig
    configure_firewall
    start_service
    show_result
}

# Запуск
main "$@"
