#!/bin/bash

#===============================================================================
# DHCP Server Setup for ALT Linux - VLAN Support
# Версия: 3.1 - ИСПРАВЛЕНО: создание директорий
#===============================================================================

set -e

# Цвета (ИСПРАВЛЕНО: убраны обратные слеши)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_LEASES="/var/lib/dhcp/dhcpd.leases"
DHCP_DEFAULTS="/etc/sysconfig/dhcpd"

log() { echo -e "${CYAN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "Запустите от root!"
    exit 1
fi

#===============================================================================
# ОЧИСТКА СТАРОЙ КОНФИГУРАЦИИ (ИСПРАВЛЕНО)
#===============================================================================
cleanup_old_config() {
    echo -e "${YELLOW}=== Очистка старой конфигурации DHCP ===${NC}"
    
    # Останавливаем службу
    systemctl stop dhcpd 2>/dev/null || true
    
    # ✅ ГЛАВНОЕ ИСПРАВЛЕНИЕ: Создаем директорию ПЕРЕД использованием
    if [[ ! -d "/var/lib/dhcp" ]]; then
        mkdir -p /var/lib/dhcp
        log "Создана директория /var/lib/dhcp"
    fi
    
    # Также создаем директорию для конфига
    if [[ ! -d "/etc/dhcp" ]]; then
        mkdir -p /etc/dhcp
        log "Создана директория /etc/dhcp"
    fi
    
    # Удаляем старый конфиг
    if [[ -f "$DHCP_CONF" ]]; then
        mv "$DHCP_CONF" "${DHCP_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Старый конфиг сохранен в backup"
    fi
    
    # Очищаем файл lease (аренд)
    if [[ -f "$DHCP_LEASES" ]]; then
        > "$DHCP_LEASES"
        log "Файл аренд DHCP очищен"
    fi
    
    # Создаем пустой lease файл
    touch "$DHCP_LEASES"
    chmod 644 "$DHCP_LEASES"
    
    log "Очистка завершена"
}

#===============================================================================
# ПОИСК СУЩЕСТВУЮЩИХ VLAN ИНТЕРФЕЙСОВ
#===============================================================================
find_vlan_interfaces() {
    echo -e "\n${CYAN}=== Найденные VLAN интерфейсы ===${NC}"
    local i=1
    > /tmp/vlan_ifaces
    
    # Ищем VLAN интерфейсы (eth0.10, eth0.20 и т.д.)
    for iface in $(ls /sys/class/net/ | grep -E '\.[0-9]+$'); do
        local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        local vlan_id=$(echo "$iface" | grep -oP '\.\K[0-9]+$')
        
        if [[ -n "$ip" ]]; then
            printf " %2d) %-12s VLAN %s | IP: %s\n" "$i" "$iface" "$vlan_id" "$ip"
            echo "$iface|$vlan_id|$ip" >> /tmp/vlan_ifaces
            ((i++))
        fi
    done
    
    # Если VLAN не найдены, показываем обычные интерфейсы
    if [[ ! -s /tmp/vlan_ifaces ]]; then
        warn "VLAN интерфейсы не найдены. Показываю все интерфейсы:"
        for iface in $(ls /sys/class/net/ | grep -v lo); do
            local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
            if [[ -n "$ip" ]]; then
                printf " %2d) %-12s %s\n" "$i" "$iface" "$ip"
                echo "$iface|0|$ip" >> /tmp/vlan_ifaces
                ((i++))
            fi
        done
    fi
    
    if [[ ! -s /tmp/vlan_ifaces ]]; then
        err "Интерфейсы с IP адресами не найдены!"
        exit 1
    fi
}

#===============================================================================
# НАСТРОЙКА DHCP
#===============================================================================
setup_dhcp() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ DHCP Server Setup v3.1 (VLAN)         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    # Очистка
    cleanup_old_config
    
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
    
    # 2. Глобальные настройки
    echo -e "\n${YELLOW}=== Глобальные параметры ===${NC}"
    read -p "Домен [local.lan]: " DOMAIN
    DOMAIN="${DOMAIN:-local.lan}"
    read -p "DNS серверы [8.8.8.8, 77.88.8.8]: " DNS_SERVERS
    DNS_SERVERS="${DNS_SERVERS:-8.8.8.8, 77.88.8.8}"
    
    # 3. Показываем VLAN интерфейсы
    find_vlan_interfaces
    
    echo -e "\n${YELLOW}=== Настройка DHCP для VLAN ===${NC}"
    echo "Выберите интерфейсы для настройки DHCP (через запятую или пробел)"
    echo "Пример: 1,2,3 или 1 2 3"
    read -p "Номера интерфейсов: " selected_ifaces
    
    # Парсим выбор
    IFS=', ' read -r -a IFACE_NUMS <<< "$selected_ifaces"
    
    DHCP_CONF_CONTENT=""
    DHCP_INTERFACES=""
    
    # Для каждого выбранного интерфейса
    for num in "${IFACE_NUMS[@]}"; do
        line=$(sed -n "${num}p" /tmp/vlan_ifaces)
        if [[ -z "$line" ]]; then
            warn "Интерфейс #$num не найден, пропускаем"
            continue
        fi
        
        IFS='|' read -r IFACE VLAN_ID IFACE_IP <<< "$line"
        
        # Извлекаем подсеть из IP
        IP_OCTETS=(${IFACE_IP//\// })
        IP_PARTS=(${IP_OCTETS[0]//./ })
        SUBNET="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.0"
        GATEWAY="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.1"
        MASK="255.255.255.0"
        
        echo -e "\n${CYAN}--- Настройка: $IFACE (VLAN $VLAN_ID) ---${NC}"
        echo "Текущий IP: $IFACE_IP"
        echo "Подсеть: $SUBNET"
        
        # Диапазон адресов
        read -p "Начало диапазона [${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.100]: " range_start
        range_start="${range_start:-${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.100}"
        read -p "Конец диапазона [${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.200]: " range_end
        range_end="${range_end:-${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.200}"
        
        # Шлюз
        read -p "Шлюз [$GATEWAY]: " gateway
        gateway="${gateway:-$GATEWAY}"
        
        # Добавляем интерфейс в список
        DHCP_INTERFACES="$DHCP_INTERFACES $IFACE"
        
        # Генерируем конфиг для этого VLAN
        if [[ "$VLAN_ID" != "0" ]]; then
            DHCP_CONF_CONTENT+="
# VLAN $VLAN_ID - $IFACE
shared-network vlan${VLAN_ID} {
  subnet $SUBNET netmask $MASK {
    range $range_start $range_end;
    option routers $gateway;
    option domain-name \"$DOMAIN\";
    option domain-name-servers $DNS_SERVERS;
    option subnet-mask $MASK;
    default-lease-time 600;
    max-lease-time 7200;
  }
}"
        else
            DHCP_CONF_CONTENT+="
# $IFACE
subnet $SUBNET netmask $MASK {
  range $range_start $range_end;
  option routers $gateway;
  option domain-name \"$DOMAIN\";
  option domain-name-servers $DNS_SERVERS;
  option subnet-mask $MASK;
  default-lease-time 600;
  max-lease-time 7200;
}"
        fi
        
        log "$IFACE: $range_start - $range_end | GW: $gateway"
    done
    
    # 4. Создаем основной конфиг
    echo -e "\n${YELLOW}=== Генерация конфигурации ===${NC}"
    cat > "$DHCP_CONF" <<EOF
# DHCP Server Configuration
# Generated: $(date)
# Cleaned old config and leases

authoritative;

# Global settings
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

# Global options
option domain-name "$DOMAIN";
option domain-name-servers $DNS_SERVERS;

# VLAN Scopes
$DHCP_CONF_CONTENT
EOF
    
    chmod 644 "$DHCP_CONF"
    log "Конфиг создан: $DHCP_CONF"
    
    # 5. Настройка службы
    echo -e "\n${YELLOW}=== Настройка службы ===${NC}"
    
    # Для ALT Linux
    if [[ -f /etc/sysconfig/dhcpd ]]; then
        echo "DHCPD_INTERFACE=\"$DHCP_INTERFACES\"" > /etc/sysconfig/dhcpd
        log "Настроен /etc/sysconfig/dhcpd"
        log "Интерфейсы: $DHCP_INTERFACES"
    fi
    
    # Проверяем конфиг
    log "Проверка конфигурации..."
    if dhcpd -t -cf "$DHCP_CONF" 2>&1 | grep -q "Configuration file tests succeed"; then
        log "Конфигурация валидна"
    else
        warn "Возможны ошибки в конфиге:"
        dhcpd -t -cf "$DHCP_CONF" 2>&1 | head -5 || true
    fi
    
    # Включаем и запускаем
    systemctl enable dhcpd 2>/dev/null || true
    systemctl restart dhcpd
    
    sleep 2
    
    # 6. Финальная проверка
    echo -e "\n${GREEN}=== ИТОГОВАЯ ПРОВЕРКА ===${NC}"
    if systemctl is-active dhcpd &>/dev/null; then
        echo -e "${GREEN}✓ DHCP сервер запущен${NC}"
    else
        echo -e "${RED}✗ DHCP сервер НЕ запущен${NC}"
        warn "Проверьте логи: journalctl -u dhcpd -n 20"
    fi
    
    echo -e "\nНастроенные подсети:"
    grep -E "^  subnet|^  range" "$DHCP_CONF" | sed 's/^/  /'
    
    echo -e "\n${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}"
    echo ""
    echo "Полезные команды:"
    echo "  systemctl status dhcpd"
    echo "  journalctl -u dhcpd -f"
    echo "  cat /var/lib/dhcp/dhcpd.leases # кто получил IP"
}

#===============================================================================
# МЕНЮ
#===============================================================================
while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ DHCP Server Setup v3.1                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) Настроить DHCP (очистка + VLAN)"
    echo "2) Проверить конфигурацию"
    echo "3) Перезапустить DHCP"
    echo "4) Показать логи"
    echo "5) Показать выданные аренды"
    echo "6) Выход"
    echo ""
    
    read -p "Выбор [1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1) setup_dhcp; read -p "Нажмите Enter..." ;;
        2)
            echo -e "\n${CYAN}Проверка конфига:${NC}"
            dhcpd -t -cf "$DHCP_CONF" 2>&1 || echo "Ошибка"
            echo -e "\nТекущий конфиг:"
            cat "$DHCP_CONF" | head -30
            read -p "Нажмите Enter..."
            ;;
        3)
            systemctl restart dhcpd
            systemctl status dhcpd --no-pager -n 5
            read -p "Нажмите Enter..."
            ;;
        4)
            journalctl -u dhcpd --no-pager -n 30
            read -p "Нажмите Enter..."
            ;;
        5)
            echo -e "\n${CYAN}Выданные аренды:${NC}"
            if [[ -f "$DHCP_LEASES" ]]; then
                cat "$DHCP_LEASES" | grep -E "lease|hardware|uid" | head -20
            else
                echo "Файл leases не найден"
            fi
            read -p "Нажмите Enter..."
            ;;
        6) exit 0 ;;
        *) warn "Неверный выбор" ;;
    esac
done
