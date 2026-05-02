#!/bin/bash
#===============================================================================
# DHCP Server - Полная диагностика и исправление
# Для Demo2026 - Alt Linux
#===============================================================================

#--- Цвета --------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

#--- Функции ------------------------------------------------------------------
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[WARN]${NC} $1"; }
line() { echo -e "${CYAN}================================================${NC}"; }

#--- Заголовок ----------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║      DHCP Server - Диагностика и Исправление         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Проверка root
if [ "$EUID" -ne 0 ]; then
    msg_er "Запустите от root: su -"
    exit 1
fi

#===============================================================================
# 1. ИНФОРМАЦИЯ О СИСТЕМЕ
#===============================================================================
line
echo -e "${WHITE}1. Системная информация${NC}"
line
echo ""
echo -e "  Хостнейм:     ${YELLOW}$(hostname)${NC}"
echo -e "  OS:           ${YELLOW}$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2)${NC}"
echo -e "  Ядро:         ${YELLOW}$(uname -r)${NC}"

#===============================================================================
# 2. СЕТЕВЫЕ ИНТЕРФЕЙСЫ
#===============================================================================
echo ""
line
echo -e "${WHITE}2. Сетевые интерфейсы${NC}"
line
echo ""

echo -e "${CYAN}>>> ip addr show${NC}"
echo ""
ip -brief addr show 2>/dev/null || ip addr show

echo ""
echo -e "${CYAN}>>> VLAN интерфейсы:${NC}"
echo ""
ip -brief addr show type vlan 2>/dev/null || echo "  (нет VLAN интерфейсов)"

echo ""
echo -e "${CYAN}>>> Таблица маршрутизации:${NC}"
echo ""
ip route show

#===============================================================================
# 3. ПРОВЕРКА DHCP ПАКЕТА
#===============================================================================
echo ""
line
echo -e "${WHITE}3. Проверка DHCP пакета${NC}"
line
echo ""

# Проверяем разные имена пакетов
PKG_FOUND=""
PKG_NAME=""

if rpm -q dhcp-server >/dev/null 2>&1; then
    PKG_FOUND="yes"
    PKG_NAME="dhcp-server"
    msg_ok "Пакет установлен: ${YELLOW}dhcp-server${NC}"
elif rpm -q dhcp >/dev/null 2>&1; then
    PKG_FOUND="yes"
    PKG_NAME="dhcp"
    msg_ok "Пакет установлен: ${YELLOW}dhcp${NC}"
elif dpkg -l isc-dhcp-server >/dev/null 2>&1; then
    PKG_FOUND="yes"
    PKG_NAME="isc-dhcp-server"
    msg_ok "Пакет установлен: ${YELLOW}isc-dhcp-server${NC}"
else
    PKG_FOUND="no"
    msg_wa "Пакет DHCP не установлен!"
fi

# Проверяем команду dhcpd
echo ""
echo -e "${CYAN}>>> which dhcpd${NC}"
if which dhcpd 2>/dev/null; then
    msg_ok "Команда dhcpd найдена"
else
    msg_wa "Команда dhcpd НЕ найдена в PATH"
fi

# Прямой поиск
echo ""
echo -e "${CYAN}>>> Поиск dhcpd:${NC}"
find /usr -name "dhcpd" -type f 2>/dev/null | head -5

#===============================================================================
# 4. УСТАНОВКА DHCP (если нужно)
#===============================================================================
if [ "$PKG_FOUND" = "no" ]; then
    echo ""
    line
    echo -e "${WHITE}4. Установка DHCP сервера${NC}"
    line
    echo ""
    
    msg_in "Определение пакетного менеджера..."
    
    if command -v apt-get >/dev/null 2>&1; then
        msg_in "Установка dhcp-server через apt-get..."
        apt-get update
        apt-get install -y dhcp-server
    elif command -v dnf >/dev/null 2>&1; then
        msg_in "Установка dhcp-server через dnf..."
        dnf install -y dhcp-server
    elif command -v yum >/dev/null 2>&1; then
        msg_in "Установка dhcp через yum..."
        yum install -y dhcp
    fi
    
    # Повторная проверка
    if which dhcpd >/dev/null 2>&1; then
        msg_ok "DHCP установлен успешно!"
    else
        msg_er "Ошибка установки DHCP!"
        exit 1
    fi
fi

#===============================================================================
# 5. КОНФИГУРАЦИЯ DHCP
#===============================================================================
echo ""
line
echo -e "${WHITE}5. Конфигурация DHCP${NC}"
line
echo ""

DHCP_CONF="/etc/dhcp/dhcpd.conf"

if [ -f "$DHCP_CONF" ]; then
    echo -e "${CYAN}>>> cat $DHCP_CONF${NC}"
    echo ""
    cat "$DHCP_CONF"
else
    msg_wa "Конфиг не существует: $DHCP_CONF"
fi

#===============================================================================
# 6. ИНТЕРФЕЙСЫ ДЛЯ DHCP
#===============================================================================
echo ""
line
echo -e "${WHITE}6. Интерфейсы для DHCP${NC}"
line
echo ""

if [ -f /etc/sysconfig/dhcpd ]; then
    echo -e "${CYAN}>>> cat /etc/sysconfig/dhcpd${NC}"
    cat /etc/sysconfig/dhcpd
elif [ -f /etc/default/isc-dhcp-server ]; then
    echo -e "${CYAN}>>> cat /etc/default/isc-dhcp-server${NC}"
    cat /etc/default/isc-dhcp-server
else
    msg_wa "Файл интерфейсов не найден"
fi

#===============================================================================
# 7. ПРОВЕРКА КОНФИГУРАЦИИ
#===============================================================================
echo ""
line
echo -e "${WHITE}7. Проверка конфигурации${NC}"
line
echo ""

echo -e "${CYAN}>>> dhcpd -t -cf $DHCP_CONF${NC}"
echo ""

if dhcpd -t -cf "$DHCP_CONF" 2>&1; then
    msg_ok "Конфигурация валидна"
else
    msg_er "Ошибка в конфигурации!"
fi

#===============================================================================
# 8. СТАТУС СЕРВИСА
#===============================================================================
echo ""
line
echo -e "${WHITE}8. Статус сервиса${NC}"
line
echo ""

# Ищем имя сервиса
SERVICE_NAME=""
for svc in dhcpd dhcp-server isc-dhcp-server; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        SERVICE_NAME="$svc"
        break
    fi
done

if [ -n "$SERVICE_NAME" ]; then
    echo -e "${CYAN}>>> systemctl status $SERVICE_NAME${NC}"
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -20
else
    msg_wa "Сервис DHCP не найден"
fi

#===============================================================================
# 9. ПОРТЫ
#===============================================================================
echo ""
line
echo -e "${WHITE}9. Проверка портов (UDP 67)${NC}"
line
echo ""

echo -e "${CYAN}>>> ss -ulnp | grep 67${NC}"
ss -ulnp 2>/dev/null | grep 67 || echo "  (порт 67 не слушается)"

#===============================================================================
# 10. ДЕЙСТВИЕ
#===============================================================================
echo ""
line
echo -e "${WHITE}10. Что сделать?${NC}"
line
echo ""
echo "  1) Создать новую конфигурацию DHCP (автоопределение)"
echo "  2) Перезапустить DHCP сервис"
echo "  3) Показать логи"
echo "  4) Выход"
echo ""
read -r -p "Выбор [1-4]: " action

case "$action" in
    1)
        #=======================================================================
        # СОЗДАНИЕ КОНФИГУРАЦИИ
        #=======================================================================
        echo ""
        line
        echo -e "${WHITE}Создание конфигурации${NC}"
        line
        echo ""
        
        # Функция преобразования префикса в маску
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
        
        # Показываем интерфейсы
        echo -e "${CYAN}Интерфейсы для DHCP:${NC}"
        echo ""
        
        TMPFILE="/tmp/dhcp_ifaces_$$"
        > "$TMPFILE"
        
        idx=0
        for iface in $(ip -brief addr show 2>/dev/null | grep -v "^lo" | awk '{print $1}'); do
            ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
            [ -z "$ip_info" ] && continue
            
            ip=$(echo "$ip_info" | cut -d'/' -f1)
            prefix=$(echo "$ip_info" | cut -d'/' -f2)
            
            printf "  ${GREEN}[%d]${NC} %-15s %s\n" "$((idx+1))" "$iface" "$ip_info"
            echo "$iface|$ip|$prefix" >> "$TMPFILE"
            idx=$((idx + 1))
        done
        
        TOTAL=$idx
        
        if [ $TOTAL -eq 0 ]; then
            msg_er "Нет интерфейсов с IP"
            rm -f "$TMPFILE"
            exit 1
        fi
        
        echo ""
        echo -e "${YELLOW}Выберите интерфейс [1-$TOTAL] или 'all':${NC}"
        read -r -p "> " sel
        
        # Бэкап
        [ -f "$DHCP_CONF" ] && cp "$DHCP_CONF" "${DHCP_CONF}.bak"
        
        # Создаём конфиг
        cat > "$DHCP_CONF" << 'HEADER'
# DHCP Configuration - Demo2026
authoritative;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;
option domain-name "au-team.irpo";

HEADER
        
        SELECTED_IFACES=""
        
        generate_subnet() {
            local data=$1
            local iface=$(echo "$data" | cut -d'|' -f1)
            local ip=$(echo "$data" | cut -d'|' -f2)
            local prefix=$(echo "$data" | cut -d'|' -f3)
            
            local mask=$(prefix_to_mask "$prefix")
            local o1=$(echo "$ip" | cut -d'.' -f1)
            local o2=$(echo "$ip" | cut -d'.' -f2)
            local o3=$(echo "$ip" | cut -d'.' -f3)
            local network="${o1}.${o2}.${o3}.0"
            local gateway="${o1}.${o2}.${o3}.1"
            
            # Диапазон
            case "$prefix" in
                26) last=62 ;;
                27) last=30 ;;
                28) last=14 ;;
                29) last=6 ;;
                *)  last=254 ;;
            esac
            local range="${o1}.${o2}.${o3}.2 ${o1}.${o2}.${o3}.${last}"
            
            echo "# Interface $iface (/${prefix})"
            echo "subnet $network netmask $mask {"
            echo "    range $range;"
            echo "    option domain-name-servers $gateway;"
            echo "    option domain-name \"au-team.irpo\";"
            echo "    option routers $gateway;"
            echo "}"
            echo ""
        }
        
        if [ "$sel" = "all" ]; then
            while IFS= read -r line; do
                generate_subnet "$line" >> "$DHCP_CONF"
                iface=$(echo "$line" | cut -d'|' -f1)
                SELECTED_IFACES="$SELECTED_IFACES $iface"
            done < "$TMPFILE"
        else
            data=$(sed -n "${sel}p" "$TMPFILE")
            generate_subnet "$data" >> "$DHCP_CONF"
            SELECTED_IFACES=$(echo "$data" | cut -d'|' -f1)
        fi
        
        rm -f "$TMPFILE"
        
        msg_ok "Конфиг создан: $DHCP_CONF"
        
        # Интерфейсы
        if [ -d /etc/sysconfig ]; then
            echo "DHCPDARGS=\"$SELECTED_IFACES\"" > /etc/sysconfig/dhcpd
            msg_ok "Интерфейсы: /etc/sysconfig/dhcpd"
        fi
        
        # Показываем
        echo ""
        cat "$DHCP_CONF"
        
        # Проверка
        echo ""
        msg_in "Проверка конфигурации..."
        dhcpd -t -cf "$DHCP_CONF" 2>&1 && msg_ok "OK" || msg_er "Ошибка!"
        
        # Запуск
        echo ""
        msg_in "Запуск DHCP..."
        systemctl stop dhcpd 2>/dev/null
        systemctl enable --now dhcpd 2>/dev/null || systemctl enable --now dhcp-server 2>/dev/null
        
        sleep 2
        systemctl status dhcpd --no-pager 2>&1 | head -10
        ;;
        
    2)
        echo ""
        msg_in "Перезапуск DHCP..."
        systemctl restart dhcpd 2>/dev/null || systemctl restart dhcp-server 2>/dev/null || systemctl restart isc-dhcp-server 2>/dev/null
        sleep 2
        systemctl status dhcpd --no-pager 2>&1 | head -10
        ;;
        
    3)
        echo ""
        echo -e "${CYAN}>>> journalctl -u dhcpd -n 30${NC}"
        journalctl -u dhcpd -n 30 --no-pager 2>/dev/null || journalctl -u dhcp-server -n 30 --no-pager 2>/dev/null
        ;;
        
    4)
        msg_in "Выход"
        ;;
esac

echo ""
msg_ok "Готово!"

