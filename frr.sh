#!/bin/bash

# ==============================================================================
# Скрипт автоматической настройки OSPF для FRR (ALT Linux)
# Версия 2.0: Авто-определение интерфейсов и IP-адресов
# ==============================================================================

set -e

REPORT_FILE="ospf_report_$(hostname)_$(date +%F_%H-%M).txt"

echo "=============================================================================="
echo "  АВТО-НАСТРОЙКА OSPF (FRR) ДЛЯ ALT LINUX"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Функция: Проверка и установка FRR
# ------------------------------------------------------------------------------
check_install_frr() {
    if ! command -v vtysh &> /dev/null; then
        echo "[*] FRR не найден. Установка пакетов..."
        apt-get update -qq
        apt-get install -y -qq frr
        echo "[+] FRR установлен."
    else
        echo "[+] FRR уже установлен."
    fi

    if grep -q "ospfd=no" /etc/frr/daemons; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        systemctl restart frr
        echo "[+] Демон ospfd активирован."
    else
        echo "[+] Демон ospfd уже активен."
    fi
}

# ------------------------------------------------------------------------------
# Функция: Получение списка интерфейсов с IP
# ------------------------------------------------------------------------------
get_interfaces() {
    echo "[*] Сканирование сетевых интерфейсов..."
    echo ""
    printf "%-15s %-20s %-20s\n" "ИНТЕРФЕЙС" "IP АДРЕС" "МАСКА"
    printf "%-15s %-20s %-20s\n" "-----------" "--------" "-----"
    
    ip -o addr show | grep -v 'lo ' | while read -r line; do
        IFACE=$(echo "$line" | awk '{print $2}')
        IP=$(echo "$line" | awk '{print $4}')
        echo "$IFACE $IP"
        printf "%-15s %-20s\n" "$IFACE" "$IP"
    done
    echo ""
}

# ------------------------------------------------------------------------------
# Функция: Поиск туннельного интерфейса
# ------------------------------------------------------------------------------
find_tunnel_interface() {
    TUNNEL_IF=$(ip -o link show | grep -iE 'gre|ipip|sit|tun' | awk -F': ' '{print $2}' | awk '{print $1}' | head -1)
    
    if [ -z "$TUNNEL_IF" ]; then
        echo "[!] Туннельный интерфейс не найден автоматически."
        echo "    Доступные интерфейсы:"
        ip -o link show | awk -F': ' '{print $2}' | awk '{print $1}' | grep -v 'lo'
        read -p "Введите имя туннельного интерфейса вручную: " TUNNEL_IF
    else
        echo "[+] Найден туннельный интерфейс: $TUNNEL_IF"
    fi
}

# ------------------------------------------------------------------------------
# Функция: Получение IP и сети туннеля
# ------------------------------------------------------------------------------
get_tunnel_network() {
    TUNNEL_IP=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | head -1)
    
    if [ -z "$TUNNEL_IP" ]; then
        echo "[!] Не удалось получить IP туннеля автоматически."
        read -p "Введите IP сеть туннеля с маской (например, 10.10.0.0/30): " TUNNEL_NET
    else
        # Вычисляем сеть из IP/маски
        IP_PART=$(echo "$TUNNEL_IP" | cut -d'/' -f1)
        MASK_PART=$(echo "$TUNNEL_IP" | cut -d'/' -f2)
        
        # Для простоты используем введенную сеть
        echo "[+] IP туннеля: $TUNNEL_IP"
        read -p "Введите сеть туннеля для OSPF (или нажмите Enter для авто): " TUNNEL_NET_INPUT
        
        if [ -z "$TUNNEL_NET_INPUT" ]; then
            # Авто-вычисление сети (упрощенно)
            NETWORK_IP=$(echo "$IP_PART" | sed 's/\.[0-9]*$/\.0/')
            TUNNEL_NET="${NETWORK_IP}/${MASK_PART}"
        else
            TUNNEL_NET="$TUNNEL_NET_INPUT"
        fi
        echo "[+] Сеть туннеля для OSPF: $TUNNEL_NET"
    fi
}

# ------------------------------------------------------------------------------
# Функция: Сбор локальных сетей для анонсирования
# ------------------------------------------------------------------------------
get_local_networks() {
    echo ""
    echo "[*] Локальные сети для анонсирования в OSPF:"
    echo "    (Нажмите Enter чтобы использовать все найденные, или введите свои)"
    echo ""
    
    # Собираем все сети кроме туннеля и loopback
    LOCAL_NETS=()
    while read -r line; do
        IFACE=$(echo "$line" | awk '{print $1}')
        IP=$(echo "$line" | awk '{print $2}')
        
        if [ "$IFACE" != "$TUNNEL_IF" ] && [ "$IFACE" != "lo" ]; then
            # Преобразуем IP/CIDR в сеть
            NET_IP=$(echo "$IP" | cut -d'/' -f1)
            MASK=$(echo "$IP" | cut -d'/' -f2)
            # Упрощенное вычисление сети
            NETWORK=$(echo "$NET_IP" | sed 's/\.[0-9]*$/\.0/')
            LOCAL_NETS+=("${NETWORK}/${MASK}")
        fi
    done < <(ip -o addr show | grep -v 'lo ' | grep -v 'link/' | awk '{print $2, $4}')
    
    if [ ${#LOCAL_NETS[@]} -gt 0 ]; then
        echo "    Найденные сети:"
        for NET in "${LOCAL_NETS[@]}"; do
            echo "      - $NET"
        done
        echo ""
        read -p "Использовать найденные сети? (y/n): " USE_FOUND
        
        if [ "$USE_FOUND" != "y" ] && [ "$USE_FOUND" != "Y" ] && [ "$USE_FOUND" != "" ]; then
            echo "Введите сети вручную (через пробел):"
            read -a LOCAL_NETS
        fi
    else
        echo "    Сети не найдены автоматически."
        echo "Введите сети вручную (через пробел):"
        read -a LOCAL_NETS
    fi
}

# ------------------------------------------------------------------------------
# Функция: Получение Router-ID
# ------------------------------------------------------------------------------
get_router_id() {
    echo ""
    # Пытаемся получить IP туннеля как Router-ID
    DEFAULT_RID=$(ip -o addr show "$TUNNEL_IF" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    
    if [ -n "$DEFAULT_RID" ]; then
        read -p "Введите OSPF Router-ID (по умолчанию $DEFAULT_RID): " ROUTER_ID
        if [ -z "$ROUTER_ID" ]; then
            ROUTER_ID="$DEFAULT_RID"
        fi
    else
        read -p "Введите OSPF Router-ID: " ROUTER_ID
    fi
    echo "[+] Router-ID: $ROUTER_ID"
}

# ------------------------------------------------------------------------------
# Функция: Настройка OSPF через vtysh
# ------------------------------------------------------------------------------
configure_ospf() {
    echo ""
    echo "[*] Применение конфигурации OSPF..."
    
    # Базовая конфигурация OSPF
    vtysh <<EOF
configure terminal
  router ospf
    ospf router-id ${ROUTER_ID}
    network ${TUNNEL_NET} area 0
    area 0 authentication
  exit
EOF

    # Добавление локальных сетей
    for NET in "${LOCAL_NETS[@]}"; do
        if [ -n "$NET" ]; then
            vtysh -c "conf t" -c "router ospf" -c "network ${NET} area 0"
            echo "    [+] Добавлена сеть: $NET"
        fi
    done

    # Настройка интерфейса туннеля
    vtysh <<EOF
configure terminal
  interface ${TUNNEL_IF}
    no ip ospf passive
    ip ospf network broadcast
    ip ospf authentication
    ip ospf authentication-key ${OSPF_PASS}
  exit
exit
write
EOF

    echo "[+] Конфигурация успешно применена."
}

# ------------------------------------------------------------------------------
# Функция: Генерация отчета
# ------------------------------------------------------------------------------
generate_report() {
    echo ""
    echo "[*] Формирование отчета: ${REPORT_FILE}"
    
    {
        echo "================================================================================"
        echo " ОТЧЕТ ПО НАСТРОЙКЕ OSPF (Задание 7)"
        echo " Дата: $(date)"
        echo " Хост: $(hostname)"
        echo "================================================================================"
        echo ""
        echo "1. ПАРАМЕТРЫ НАСТРОЙКИ:"
        echo "--------------------------------------------------------------------------------"
        echo "Router-ID:      ${ROUTER_ID}"
        echo "Туннель:        ${TUNNEL_IF}"
        echo "Сеть туннеля:   ${TUNNEL_NET}"
        echo "Локальные сети: ${LOCAL_NETS[*]}"
        echo ""
        echo "2. ТЕКУЩАЯ КОНФИГУРАЦИЯ (show run):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show run"
        echo ""
        echo "3. СТАТУС СОСЕДЕЙ OSPF (show ip ospf neighbor):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show ip ospf neighbor"
        echo ""
        echo "4. ТАБЛИЦА МАРШРУТИЗАЦИИ OSPF (show ip route ospf):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show ip route ospf"
        echo ""
        echo "5. СТАТУС ИНТЕРФЕЙСОВ (show interface):"
        echo "--------------------------------------------------------------------------------"
        vtysh -c "show interface"
        echo ""
        echo "================================================================================"
        echo " КОНЕЦ ОТЧЕТА"
        echo "================================================================================"
    } > "${REPORT_FILE}"
}

# ==============================================================================
# ОСНОВНАЯ ЛОГИКА
# ==============================================================================

check_install_frr
get_interfaces
find_tunnel_interface
get_tunnel_network
get_router_id
get_local_networks

echo ""
echo "------------------------------------------------------------------------------"
echo "Введите пароль для OSPF аутентификации:"
read -p "Пароль: " -s OSPF_PASS
echo ""
echo "------------------------------------------------------------------------------"

configure_ospf
generate_report

echo ""
echo "=============================================================================="
echo "  НАСТРОЙКА ЗАВЕРШЕНА!"
echo "  Отчет сохранен в: ${REPORT_FILE}"
echo ""
echo "  Проверка работоспособности:"
echo "    vtysh -c 'show ip ospf neighbor'"
echo "    ping <IP_удаленной_сети>"
echo "=============================================================================="
