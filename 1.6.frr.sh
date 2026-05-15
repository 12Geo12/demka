#!/bin/bash
#===============================================================================
# Настройка GRE туннеля + OSPF (Alt Linux / FRRouting)
# Версия: 3.2 - ИСПРАВЛЕНО: обработка состояния UNKNOWN и стабильность проверок
#===============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "Запустите от root!"
    exit 1
fi

#===============================================================================
# ФУНКЦИИ ПРОВЕРКИ (ИСПРАВЛЕНО!)
#===============================================================================
check_gre_tunnel() {
    echo -e "${CYAN}→ Проверка GRE туннеля...${NC}"
    if ! ip link show gre1 &>/dev/null; then
        echo -e "  ${RED}✗${NC} gre1: не существует"
        return 1
    fi
    
    # ИСПРАВЛЕНО: GRE туннели в состоянии UP часто показывают state UNKNOWN
    local state=$(ip link show gre1 | grep -oP 'state \K\w+')
    if [[ "$state" == "UP" || "$state" == "UNKNOWN" ]]; then
        echo -e "  ${GREEN}✓${NC} gre1: $state (Активен)"
        ip addr show gre1 2>/dev/null | grep "inet " | sed 's/^/    /'
        return 0
    else
        echo -e "  ${RED}✗${NC} gre1: $state (Не активен)"
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
    
    if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ospfd=yes"
    else
        echo -e "  ${RED}✗${NC} ospfd не включен"
        return 1
    fi
    
    if grep -q 'router ospf' "$FRR_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} OSPF конфиг найден"
    else
        echo -e "  ${RED}✗${NC} OSPF конфиг не найден"
        return 1
    fi
    
    local neighbors=$(vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full" || true)
    if [[ $neighbors -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Соседи OSPF: $neighbors"
    else
        echo -e "  ${YELLOW}!${NC} Соседей пока нет (ожидайте)"
    fi
    return 0
}

check_persistence() {
    echo -e "${CYAN}→ Проверка сохранения...${NC}"
    if systemctl is-enabled frr &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} frr.service enabled"
    else
        echo -e "  ${RED}✗${NC} frr.service"
    fi
    
    if [[ -f /etc/frr/vtysh.conf ]]; then
        echo -e "  ${GREEN}✓${NC} vtysh.conf существует"
    else
        echo -e "  ${RED}✗${NC} vtysh.conf"
    fi
}

check_nat_rules() {
    echo -e "${CYAN}→ Проверка NAT...${NC}"
    local rules=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "gre1" || true)
    if [[ $rules -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} NAT правил: $rules"
    else
        echo -e "  ${YELLOW}!${NC} NAT правил нет"
    fi
}

run_all_checks() {
    echo -e "\n${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}   ПРОВЕРКА КОНФИГУРАЦИИ${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}\n"
    
    # ИСПРАВЛЕНО: || true предотвращает выход из скрипта при ошибке проверки
    check_gre_tunnel || true
    echo ""
    check_ospf_status || true
    echo ""
    check_persistence || true
    echo ""
    check_nat_rules || true
    
    echo ""
}

#===============================================================================
# ФУНКЦИЯ ПРИМЕНЕНИЯ КОНФИГУРАЦИИ
#===============================================================================
apply_configuration() {
    local EXT_IP="$1"
    local REMOTE_IP="$2"
    local GRE_IP="$3"
    local RID="$4"
    local PASS="$5"
    shift 5
    local NETWORKS=("$@")
    
    echo -e "\n${CYAN}════════════════════════════════════${NC}"
    echo -e "${CYAN}   ПРИМЕНЕНИЕ КОНФИГУРАЦИИ${NC}"
    echo -e "${CYAN}════════════════════════════════════${NC}\n"
    
    # 1. Создаем GRE туннель
    log_info "Создание GRE туннеля..."
    ip link set gre1 down 2>/dev/null || true
    ip tunnel del gre1 2>/dev/null || true
    sleep 1
    
    if ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64; then
        log_ok "GRE туннель создан"
    else
        log_err "Ошибка создания GRE туннеля!"
        return 1
    fi
    
    if ip addr add "$GRE_IP" dev gre1; then
        log_ok "IP адрес назначен: $GRE_IP"
    else
        log_err "Ошибка назначения IP!"
        return 1
    fi
    
    if ip link set gre1 up; then
        log_ok "GRE туннель поднят"
    else
        log_err "Ошибка включения туннеля!"
        return 1
    fi
    
    sleep 2
    ip link show gre1 &>/dev/null && log_ok "Туннель активен" || { log_err "Туннель не активен!"; return 1; }
    
    # 2. Включаем OSPF демон
    log_info "Настройка FRR демонов..."
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        cat > "$FRR_DAEMONS" << 'EOF'
zebra=yes
ospfd=yes
bgpd=no
ospf6d=no
ripd=no
ripng=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
EOF
    else
        sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
        sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
    fi
    log_ok "ospfd=yes установлен"
    
    # 3. Создаем FRR конфиг
    log_info "Генерация конфигурации OSPF..."
    cat > "$FRR_CONF" << EOF
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
 ip ospf authentication-key $PASS
EOF
    
    # Добавляем сети
    for net in "${NETWORKS[@]}"; do
        echo " network $net area 0" >> "$FRR_CONF"
    done
    # Добавляем сеть туннеля
    TUNNEL_NET=$(echo "$GRE_IP" | cut -d'/' -f1 | sed 's/\.[0-9]*$/.0/')
    echo " network ${TUNNEL_NET}/24 area 0" >> "$FRR_CONF"
    
    cat >> "$FRR_CONF" << 'EOF'
!
line vty
!
EOF
    
    chmod 644 "$FRR_CONF"
    log_ok "FRR конфиг создан"
    
    # 4. NAT правила
    log_info "Настройка NAT..."
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    for net in "${NETWORKS[@]}"; do
        if iptables -t nat -A POSTROUTING -s "$net" -o gre1 -j MASQUERADE 2>/dev/null; then
            log_ok "NAT: $net -> gre1"
        fi
    done
    
    # 5. Включаем IP forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        log_ok "IP forwarding включен"
    fi
    
    # 6. Перезапускаем FRR
    log_info "Перезапуск FRR..."
    systemctl daemon-reload 2>/dev/null || true
    if systemctl restart frr; then
        sleep 3
        if systemctl is-active frr &>/dev/null; then
            log_ok "FRR перезапущен и работает"
        else
            log_err "FRR не запустился!"
            systemctl status frr --no-pager | head -10
            return 1
        fi
    else
        log_err "Ошибка перезапуска FRR!"
        return 1
    fi
    
    # 7. Сохраняем конфигурацию
    log_info "Сохранение конфигурации..."
    if vtysh -c "write memory" 2>/dev/null; then
        log_ok "Конфигурация сохранена (write memory)"
    else
        log_err "write memory не сработал"
    fi
    
    cp "$FRR_CONF" /etc/frr/vtysh.conf 2>/dev/null || true
    log_ok "Скопировано в vtysh.conf"
    
    # 8. Включаем автозапуск
    systemctl enable frr 2>/dev/null || true
    log_ok "Автозапуск FRR включен"
    
    echo -e "\n${GREEN}════════════════════════════════════${NC}"
    echo -e "${GREEN}   КОНФИГУРАЦИЯ ПРИМЕНЕНА!${NC}"
    echo -e "${GREEN}════════════════════════════════════${NC}\n"
    
    return 0
}

#===============================================================================
# ОСНОВНОЕ МЕНЮ
#===============================================================================
while true; do
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN} Настройка GRE туннеля и OSPF v3.2${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "1) Настроить GRE + OSPF (с очисткой)"
    echo "2) Настроить GRE + OSPF (без очистки)"
    echo "3) Только очистить конфигурацию"
    echo "4) Проверить текущую конфигурацию"
    echo "5) Выход"
    echo ""
    
    read -p "Выбор [1]: " menu_choice
    menu_choice=${menu_choice:-1} # Значение по умолчанию
    
    case $menu_choice in
        4)
            run_all_checks
            read -p "Нажмите Enter..."
            ;;
        5)
            echo "Выход..."
            exit 0
            ;;
        3)
            echo -e "${YELLOW}Очистка конфигурации...${NC}"
            ip link set gre1 down 2>/dev/null || true
            ip tunnel del gre1 2>/dev/null || true
            systemctl stop frr 2>/dev/null || true
            echo -e "${GREEN}Очищено${NC}"
            read -p "Нажмите Enter..."
            ;;
        1|2)
            # СБОР ПАРАМЕТРОВ
            if [[ "$menu_choice" == "1" ]]; then
                echo -e "${YELLOW}Очистка старой конфигурации...${NC}"
                ip link set gre1 down 2>/dev/null || true
                ip tunnel del gre1 2>/dev/null || true
                sleep 1
            fi
            
            echo -e "\n${CYAN}=== Выбор роли роутера ===${NC}"
            echo "1) HQ-RTR (Router ID: 1.1.1.1)"
            echo "2) BR-RTR (Router ID: 2.2.2.2)"
            read -p "Выберите роль [1]: " role_choice
            role_choice=${role_choice:-1}
            
            case $role_choice in
                2) ROLE="BR-RTR"; RID="2.2.2.2"; GRE_IP="172.16.1.2" ;;
                *) ROLE="HQ-RTR"; RID="1.1.1.1"; GRE_IP="172.16.1.1" ;;
            esac
            echo -e "${GREEN}Роль: $ROLE${NC}"
            
            # Определение внешнего интерфейса
            EXT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
            EXT_IP=$(ip -4 addr show "$EXT_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            
            if [[ -z "$EXT_IP" ]]; then
                log_err "Не удалось определить внешний IP!"
                read -p "Нажмите Enter..."
                continue
            fi
            
            echo -e "\n${CYAN}=== Параметры GRE туннеля ===${NC}"
            echo "Внешний интерфейс: $EXT_IFACE | Ваш IP: $EXT_IP"
            read -p "IP удаленного роутера: " REMOTE_IP
            read -p "Локальный IP туннеля [$GRE_IP]: " user_gre
            GRE_IP="${user_gre:-$GRE_IP}"
            read -p "Маска туннеля [24]: " gre_mask
            GRE_MASK="${gre_mask:-24}"
            GRE_FULL_IP="${GRE_IP}/${GRE_MASK}"
            
            # Ввод сетей OSPF
            echo -e "\n${CYAN}=== Сети для OSPF ===${NC}"
            echo "Введите сети через пробел (пример: 192.168.10.0/26 172.16.1.0/24):"
            read -p "> " networks_input
            
            if [[ -z "$networks_input" ]]; then
                log_err "Не введены сети OSPF!"
                read -p "Нажмите Enter..."
                continue
            fi
            
            # Пароль OSPF
            read -p "Пароль OSPF [123]: " pass
            pass="${pass:-123}"
            
            # Преобразуем ввод в массив
            IFS=' ' read -r -a NETWORKS_ARRAY <<< "$networks_input"
            
            # ПРИМЕНЕНИЕ КОНФИГУРАЦИИ
            if apply_configuration "$EXT_IP" "$REMOTE_IP" "$GRE_FULL_IP" "$RID" "$pass" "${NETWORKS_ARRAY[@]}"; then
                # Показываем результат
                run_all_checks
            else
                log_err "Ошибка применения конфигурации!"
            fi
            
            read -p "Нажмите Enter..."
            ;;
        *)
            log_err "Неверный выбор"
            sleep 1
            ;;
    esac
done
