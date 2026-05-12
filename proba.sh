#!/bin/bash
#===============================================================================
# Настройка GRE туннеля + OSPF (Alt Linux / FRRouting)
# Версия: 3.0 - ИСПРАВЛЕНО: цвета + проверки + персистентность
#===============================================================================
set -e

# Цвета - ИСПРАВЛЕНО!
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"

#===============================================================================
# ФУНКЦИИ ПРОВЕРКИ (НОВОЕ!)
#===============================================================================
check_gre_tunnel() {
    echo -e "${CYAN}→ Проверка GRE туннеля...${NC}"
    if ip link show gre1 &>/dev/null; then
        local state=$(ip link show gre1 | grep -oP 'state \K\w+')
        if [[ "$state" == "UP" ]]; then
            echo -e "  ${GREEN}✓${NC} gre1: UP"
            ip -brief addr show gre1 | grep "inet " | sed 's/^/    /'
            return 0
        else
            echo -e "  ${YELLOW}!${NC} gre1: $state (не активен)"
            return 1
        fi
    else
        echo -e "  ${RED}✗${NC} gre1: не существует"
        return 1
    fi
}

check_ospf_status() {
    echo -e "${CYAN}→ Проверка OSPF...${NC}"
    if ! systemctl is-active frr &>/dev/null; then
        echo -e "  ${RED}✗${NC} FRR не запущен"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} FRR запущен"
    
    # Проверка демона ospfd
    if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ospfd=yes в daemons"
    else
        echo -e "  ${RED}✗${NC} ospfd не включен"
        return 1
    fi
    
    # Проверка конфига
    if grep -q 'router ospf' "$FRR_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} OSPF конфиг найден"
    else
        echo -e "  ${RED}✗${NC} OSPF конфиг не найден"
        return 1
    fi
    
    # Соседи (не критично, если нет)
    local neighbors=$(vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full" || true)
    if [[ $neighbors -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Соседи OSPF: $neighbors"
    else
        echo -e "  ${YELLOW}!${NC} Соседей пока нет (ждем 30-60 сек)"
    fi
    return 0
}

check_persistence() {
    echo -e "${CYAN}→ Проверка сохранения после перезагрузки...${NC}"
    local ok=true
    
    # FRR автозапуск
    if systemctl is-enabled frr &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} frr.service enabled"
    else
        echo -e "  ${RED}✗${NC} frr.service NOT enabled"
        ok=false
    fi
    
    # GRE systemd service
    if [[ -f /etc/systemd/system/gre-tunnel.service ]]; then
        if systemctl is-enabled gre-tunnel &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} gre-tunnel.service enabled"
        else
            echo -e "  ${RED}✗${NC} gre-tunnel.service NOT enabled"
            ok=false
        fi
    else
        echo -e "  ${RED}✗${NC} gre-tunnel.service не создан"
        ok=false
    fi
    
    # Проверка vtysh.conf (для FRR)
    if cmp -s "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Конфиг синхронизирован (vtysh.conf)"
    else
        echo -e "  ${YELLOW}!${NC} vtysh.conf не синхронизирован"
    fi
    
    $ok && return 0 || return 1
}

check_nat_rules() {
    echo -e "${CYAN}→ Проверка NAT правил...${NC}"
    local rules=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "gre1" || true)
    if [[ $rules -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} NAT правил для gre1: $rules"
        iptables -t nat -L POSTROUTING -n | grep gre1 | sed 's/^/    /'
        return 0
    else
        echo -e "  ${YELLOW}!${NC} NAT правил не найдено"
        return 1
    fi
}

run_all_checks() {
    echo -e "\n${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}   ПРОВЕРКА КОНФИГУРАЦИИ${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}\n"
    
    local total=4
    local passed=0
    
    check_gre_tunnel && ((passed++))
    echo ""
    check_ospf_status && ((passed++))
    echo ""
    check_persistence && ((passed++))
    echo ""
    check_nat_rules && ((passed++))
    
    echo -e "\n${CYAN}Результат: ${passed}/${total} проверок пройдено${NC}"
    
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}✓ Всё работает корректно!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Некоторые проверки не пройдены${NC}"
        return 1
    fi
}

#===============================================================================
# ФУНКЦИЯ ОЧИСТКИ КОНФИГУРАЦИИ
#===============================================================================
cleanup_config() {
    echo -e "${YELLOW}=== ОЧИСТКА ПРЕДЫДУЩЕЙ КОНФИГУРАЦИИ ===${NC}"
    echo ""
    
    echo "[1/6] Удаление GRE туннеля..."
    ip link set gre1 down 2>/dev/null && ip tunnel del gre1 2>/dev/null && echo " ✓ Удалён" || echo " → Не найден"
    
    echo "[2/6] Удаление systemd service..."
    systemctl stop gre-tunnel.service 2>/dev/null || true
    systemctl disable gre-tunnel.service 2>/dev/null || true
    rm -f /etc/systemd/system/gre-tunnel.service
    systemctl daemon-reload
    echo " ✓ Готово"
    
    echo "[3/6] Сброс FRR конфигурации..."
    cat > "$FRR_CONF" << EOF
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
line vty
!
EOF
    echo " ✓ Готово"
    
    echo "[4/6] Отключение OSPF демона..."
    sed -i 's/^ospfd=.*/ospfd=no/' "$FRR_DAEMONS" 2>/dev/null || true
    echo " ✓ Готово"
    
    echo "[5/6] Очистка NAT правил..."
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    echo " ✓ Готово"
    
    echo "[6/6] Перезапуск служб..."
    systemctl restart frr 2>/dev/null || true
    echo " ✓ Готово"
    
    echo ""
    echo -e "${GREEN}✓ Очистка завершена!${NC}\n"
}

#===============================================================================
# ФУНКЦИЯ СОЗДАНИЯ SYSTEMD SERVICE
#===============================================================================
create_gre_systemd() {
    local local_ip="$1"
    local remote_ip="$2"
    local gre_ip="$3"
    
    cat > /etc/systemd/system/gre-tunnel.service << EOF
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${local_ip} remote ${remote_ip} ttl 64
ExecStart=/sbin/ip addr add ${gre_ip} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1476
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gre-tunnel.service
}

#===============================================================================
# ФУНКЦИЯ ВКЛЮЧЕНИЯ OSPF ДЕМОНА
#===============================================================================
enable_ospf_daemon() {
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        cat > "$FRR_DAEMONS" << 'EOF'
zebra=yes
ospfd=yes
bgpd=no
ospf6d=no
ripd=no
EOF
    else
        sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
        sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
    fi
}

#===============================================================================
# ОСНОВНОЕ МЕНЮ
#===============================================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Настройка GRE туннеля и OSPF v3.0${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

echo "1) Настроить GRE + OSPF (с очисткой старой конфигурации)"
echo "2) Настроить GRE + OSPF (без очистки)"
echo "3) Только очистить конфигурацию"
echo "4) Проверить текущую конфигурацию"
echo "5) Выход"
echo ""

read -p "Выбор [1]: " menu_choice

case $menu_choice in
    2) CLEANUP="no" ;;
    3) cleanup_config; exit 0 ;;
    4) run_all_checks; exit $? ;;
    5) echo "Выход..."; exit 0 ;;
    *) CLEANUP="yes" ;;
esac

[[ "$CLEANUP" == "yes" ]] && cleanup_config

#===============================================================================
# СБОР ПАРАМЕТРОВ
#===============================================================================
echo "=== Выбор роли роутера ==="
echo "1) HQ-RTR (Router ID: 1.1.1.1)"
echo "2) BR-RTR (Router ID: 2.2.2.2)"
read -p "Выберите роль [1]: " role_choice

case $role_choice in
    2) ROLE="BR-RTR"; RID="2.2.2.2"; GRE_IP="172.16.1.2" ;;
    *) ROLE="HQ-RTR"; RID="1.1.1.1"; GRE_IP="172.16.1.1" ;;
esac

echo -e "${YELLOW}Роль: $ROLE${NC}"

# Определение внешнего интерфейса и IP
EXT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)

if [[ -z "$EXT_IP" ]]; then
    echo -e "${RED}Ошибка: Не удалось определить внешний IP!${NC}"
    exit 1
fi

echo ""
echo "=== Параметры GRE туннеля ==="
echo "Внешний интерфейс: $EXT_IFACE | Ваш IP: $EXT_IP"
read -p "IP удаленного роутера: " REMOTE_IP
read -p "Локальный IP туннеля [$GRE_IP]: " user_gre
GRE_IP="${user_gre:-$GRE_IP}"
read -p "Маска туннеля [24]: " gre_mask
GRE_FULL_IP="${GRE_IP}/${gre_mask:-24}"

#===============================================================================
# ВВОД НЕСКОЛЬКИХ СЕТЕЙ С ВАЛИДАЦИЕЙ
#===============================================================================
echo ""
echo "=== Сети для OSPF ==="
echo "Введите сети через пробел или запятую:"
echo "Пример: 192.168.6.0/28 192.168.10.0/26, 10.0.0.0/24"
echo ""

while true; do
    read -p "> " RAW_INPUT
    CLEANED_INPUT=$(echo "$RAW_INPUT" | tr ',' ' ' | xargs)
    declare -a OSPF_NETWORKS=()
    valid_count=0
    
    for net in $CLEANED_INPUT; do
        if [[ $net =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            mask=${net##*/}
            if (( mask >=1 && mask <=32 )); then
                OSPF_NETWORKS+=("$net")
                ((valid_count++))
            else
                echo -e "${YELLOW}⚠ Некорректная маска: $net${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ Пропущено: $net${NC}"
        fi
    done
    
    if (( valid_count > 0 )); then
        echo ""
        echo -e "${GREEN}✓ Распознано сетей: $valid_count${NC}"
        for n in "${OSPF_NETWORKS[@]}"; do echo " • $n"; done
        echo ""
        read -p "Подтвердить сети? [Y/n]: " confirm
        confirm=${confirm:-y}
        [[ $confirm =~ ^[Yy]$ ]] && break
    else
        echo -e "${RED}✗ Нет корректных сетей. Попробуйте снова.${NC}"
    fi
done

read -p "Area ID для всех сетей [0]: " area_id
area_id="${area_id:-0}"
read -p "Пароль OSPF [123]: " pass
pass="${pass:-123}"

#===============================================================================
# ПРИМЕНЕНИЕ КОНФИГУРАЦИИ
#===============================================================================
echo ""
echo -e "${CYAN}Применение конфигурации...${NC}"

create_gre_systemd "$EXT_IP" "$REMOTE_IP" "$GRE_FULL_IP"
enable_ospf_daemon

# Генерация FRR конфига
cat > "$FRR_CONF" << EOF
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id $RID
 passive-interface default
 no passive-interface gre1
 ip ospf authentication
 ip ospf authentication-key $pass
EOF

for net in "${OSPF_NETWORKS[@]}"; do
    echo " network $net area $area_id" >> "$FRR_CONF"
done
echo " network 172.16.1.0/24 area $area_id" >> "$FRR_CONF"

cat >> "$FRR_CONF" << EOF
!
line vty
!
EOF

# Системные настройки
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# NAT для всех указанных сетей
iptables -t nat -F POSTROUTING 2>/dev/null || true
for net in "${OSPF_NETWORKS[@]}"; do
    iptables -t nat -A POSTROUTING -s "$net" -o gre1 -j MASQUERADE 2>/dev/null || true
    echo -e "${GREEN}✓${NC} NAT: $net -> gre1"
done

# Включение автозапуска
systemctl enable frr gre-tunnel >/dev/null 2>&1 || true

# Запуск служб
systemctl start gre-tunnel
sleep 2
systemctl restart frr
sleep 3

# Сохранение конфигурации FRR
vtysh -c "write memory" 2>/dev/null || true
cp "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null || true

#===============================================================================
# ФИНАЛЬНЫЕ ПРОВЕРКИ
#===============================================================================
run_all_checks

echo ""
echo -e "${GREEN}════════════════════════════════════${NC}"
echo -e "${GREEN}   НАСТРОЙКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}💡 Полезные команды:${NC}"
echo "  systemctl status gre-tunnel     # Статус туннеля"
echo "  vtysh -c 'show ip ospf neighbor' # Соседи OSPF"
echo "  vtysh -c 'show ip route ospf'    # Маршруты"
echo "  ./$0                             # Повторный запуск"
echo "  ./$0  # опция 4  # Проверка конфигурации"
echo ""
echo -e "${GREEN}✅ Конфигурация сохранится после перезагрузки!${NC}"
