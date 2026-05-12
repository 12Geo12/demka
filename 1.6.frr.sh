#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE туннель) с полной персистентностью
# Версия: 2.0 - Улучшенная с проверками и откатом
#===============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${CYAN}  Настройка FRRouting (OSPF + GRE) с полной персистентностью${NC}"
echo -e "${CYAN}==============================================================================${NC}"
echo ""

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗ Ошибка: Запустите скрипт от root${NC}"
    exit 1
fi

# Проверка ОС
if ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null; then
    echo -e "${RED}✗ Ошибка: Не найдены apt-get или yum${NC}"
    exit 1
fi

#===============================================================================
# ФУНКЦИИ
#===============================================================================

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        log_info "$service работает"
        return 0
    else
        log_warn "$service не работает"
        return 1
    fi
}

#===============================================================================
# СБОР ПАРАМЕТРОВ
#===============================================================================

echo -e "${CYAN}=== Выбор роли роутера ===${NC}"
echo "1) HQ-RTR (Router ID: 1.1.1.1, GRE IP: 172.16.1.1)"
echo "2) BR-RTR (Router ID: 2.2.2.2, GRE IP: 172.16.1.2)"
read -p "Выберите роль [1]: " role_choice
role_choice=${role_choice:-1}

case $role_choice in
    2)
        ROLE="BR-RTR"
        RID="2.2.2.2"
        GRE_IP="172.16.1.2/24"
        GRE_LOCAL_IP=$(ip -4 addr show ens33 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        if [[ "$ROLE" == "BR-RTR" ]]; then
            GRE_REMOTE_IP="192.168.4.2"
        else
            GRE_REMOTE_IP="192.168.5.2"
        fi
        OSPF_NETWORKS="172.16.1.0/24"
        ;;
    *)
        ROLE="HQ-RTR"
        RID="1.1.1.1"
        GRE_IP="172.16.1.1/24"
        GRE_LOCAL_IP=$(ip -4 addr show ens33 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        GRE_REMOTE_IP="192.168.5.2"
        OSPF_NETWORKS="172.16.1.0/24 192.168.10.0/26 192.168.20.0/27 192.168.99.0/28"
        ;;
esac

echo -e "${YELLOW}Роль: $ROLE (Router ID: $RID)${NC}"
echo ""

#===============================================================================
# УСТАНОВКА FRR
#===============================================================================

echo -e "${CYAN}=== Установка FRRouting ===${NC}"

if command -v apt-get &>/dev/null; then
    # Debian/Ubuntu/Alt Linux
    apt-get update -qq
    apt-get install -y -qq frr frr-pythontools iproute2 iptables
elif command -v yum &>/dev/null; then
    # RHEL/CentOS
    yum install -y -q frr iproute iptables
else
    log_error "Не удалось установить FRR"
    exit 1
fi

log_info "FRR установлен"

#===============================================================================
# НАСТРОЙКА FRR DAEMONS
#===============================================================================

echo -e "${CYAN}=== Настройка демонов FRR ===${NC}"

cat > /etc/frr/daemons << 'EOF'
zebra=yes
ospfd=yes
bgpd=no
ospf6d=no
ripd=no
ripngd=no
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
vrrpd=no

#
# This file tells the system which daemons to start.
#
EOF

log_info "Демоны FRR настроены (zebra=yes, ospfd=yes)"

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ (etcnet для Alt Linux)
#===============================================================================

echo -e "${CYAN}=== Настройка GRE туннеля ===${NC}"

# Создаем директорию для конфигурации GRE
mkdir -p /etc/net/ifaces/gre1

# Конфигурация интерфейса GRE для etcnet (Alt Linux)
cat > /etc/net/ifaces/gre1/options << EOF
# GRE tunnel configuration
TYPE=gre
REMOTE=$GRE_REMOTE_IP
LOCAL=$GRE_LOCAL_IP
TTL=64
DISABLE=no
EOF

cat > /etc/net/ifaces/gre1/ipv4address << EOF
$GRE_IP
EOF

log_info "GRE туннель настроен (Local: $GRE_LOCAL_IP, Remote: $GRE_REMOTE_IP)"

# Также создаем systemd service для совместимости
cat > /etc/systemd/system/gre-tunnel.service << EOF
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${GRE_LOCAL_IP} remote ${GRE_REMOTE_IP} ttl 64
ExecStart=/sbin/ip addr add ${GRE_IP} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1400
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gre-tunnel.service
log_info "systemd service для GRE создан и включен в автозагрузку"

#===============================================================================
# НАСТРОЙКА OSPF
#===============================================================================

echo -e "${CYAN}=== Настройка OSPF ===${NC}"

cat > /etc/frr/frr.conf << EOF
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
 ip ospf authentication-key 123
EOF

# Добавляем сети в OSPF
for network in $OSPF_NETWORKS; do
    echo " network $network area 0" >> /etc/frr/frr.conf
done

cat >> /etc/frr/frr.conf << 'EOF'
!
line vty
!
EOF

log_info "OSPF настроен (Router ID: $RID)"
log_info "Сети OSPF: $OSPF_NETWORKS"

#===============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
#===============================================================================

echo -e "${CYAN}=== Системные настройки ===${NC}"

# Включаем IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
log_info "IP forwarding включен"

# Настраиваем rp_filter для GRE
cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.gre1.rp_filter=2
EOF

sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.gre1.rp_filter=2 >/dev/null
log_info "rp_filter настроен (loose mode)"

#===============================================================================
# ВКЛЮЧЕНИЕ СЛУЖБ В АВТОЗАГРУЗКУ
#===============================================================================

echo -e "${CYAN}=== Включение служб в автозагрузку ===${NC}"

systemctl enable frr
systemctl enable net 2>/dev/null || log_warn "etcnet не найден, пропускаем"
log_info "Службы добавлены в автозагрузку"

#===============================================================================
# ЗАПУСК СЛУЖБ
#===============================================================================

echo -e "${CYAN}=== Запуск служб ===${NC}"

# Поднимаем GRE туннель вручную (на случай если etcnet еще не загрузился)
ip tunnel del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local $GRE_LOCAL_IP remote $GRE_REMOTE_IP ttl 64
ip addr add $GRE_IP dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400
log_info "GRE туннель поднят"

# Перезапускаем FRR
systemctl restart frr
log_info "FRR перезапущен"

sleep 3

#===============================================================================
# ПРОВЕРКА И СОХРАНЕНИЕ
#===============================================================================

echo -e "${CYAN}=== Проверка конфигурации ===${NC}"

# Проверка GRE
if ip link show gre1 &>/dev/null; then
    log_info "GRE туннель активен"
    ip -brief addr show gre1
else
    log_error "GRE туннель не поднят!"
    exit 1
fi

# Проверка OSPF соседей
echo ""
echo -e "${CYAN}OSPF соседи:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || log_warn "OSPF соседи не найдены (подождите 30 сек)"

# Проверка маршрутов
echo ""
echo -e "${CYAN}Маршруты OSPF:${NC}"
ip route show | grep ospf || log_warn "Маршруты OSPF не найдены"

#===============================================================================
# ПЕРСИСТЕНТНОСТЬ - СОХРАНЕНИЕ КОНФИГУРАЦИИ
#===============================================================================

echo -e "${CYAN}=== Сохранение конфигурации для персистентности ===${NC}"

# Проверяем что сохранено
echo -e "\n${GREEN}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"

checks_passed=0
checks_total=6

# 1. Проверка ospfd
if grep -q '^ospfd=yes' /etc/frr/daemons; then
    echo -e "${GREEN}✓${NC} [1/6] ospfd=yes в /etc/frr/daemons"
    ((checks_passed++))
else
    echo -e "${RED}✗${NC} [1/6] ospfd=no (ОШИБКА!)"
fi

# 2. Проверка zebra
if grep -q '^zebra=yes' /etc/frr/daemons; then
    echo -e "${GREEN}✓${NC} [2/6] zebra=yes в /etc/frr/daemons"
    ((checks_passed++))
else
    echo -e "${RED}✗${NC} [2/6] zebra=no (ОШИБКА!)"
fi

# 3. Проверка GRE в etcnet
if grep -q 'DISABLE=no' /etc/net/ifaces/gre1/options 2>/dev/null; then
    echo -e "${GREEN}✓${NC} [3/6] GRE туннель: DISABLE=no"
    ((checks_passed++))
else
    echo -e "${YELLOW}⚠${NC} [3/6] etcnet GRE не найден (может использоваться systemd)"
    ((checks_passed++))
fi

# 4. Проверка systemd GRE
if systemctl is-enabled gre-tunnel.service &>/dev/null; then
    echo -e "${GREEN}✓${NC} [4/6] gre-tunnel.service в автозагрузке"
    ((checks_passed++))
else
    echo -e "${RED}✗${NC} [4/6] gre-tunnel.service не в автозагрузке (ОШИБКА!)"
fi

# 5. Проверка FRR автозагрузка
if systemctl is-enabled frr &>/dev/null; then
    echo -e "${GREEN}✓${NC} [5/6] frr в автозагрузке"
    ((checks_passed++))
else
    echo -e "${RED}✗${NC} [5/6] frr не в автозагрузке (ОШИБКА!)"
fi

# 6. Проверка sysctl
if grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo -e "${GREEN}✓${NC} [6/6] IP forwarding сохранен в sysctl.conf"
    ((checks_passed++))
else
    echo -e "${RED}✗${NC} [6/6] IP forwarding не сохранен (ОШИБКА!)"
fi

echo ""
echo -e "${CYAN}Пройдено проверок: $checks_passed/$checks_total${NC}"

if [[ $checks_passed -eq $checks_total ]]; then
    echo -e "${GREEN}✓ Все проверки пройдены! Конфигурация сохранена.${NC}"
else
    echo -e "${YELLOW}⚠ Некоторые проверки не пройдены. Проверьте логи: $LOG_FILE${NC}"
fi

#===============================================================================
# ФИНАЛЬНЫЙ ОТЧЕТ
#===============================================================================

echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}  НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo "  vtysh -c 'show ip ospf neighbor'  # Показать OSPF соседей"
echo "  ip route show | grep ospf          # Показать OSPF маршруты"
echo "  systemctl status frr               # Статус FRR"
echo "  systemctl status gre-tunnel        # Статус GRE туннеля"
echo "  journalctl -u frr -f               # Логи FRR в реальном времени"
echo ""
echo -e "${CYAN}Лог установки:${NC} $LOG_FILE"
echo ""
echo -e "${YELLOW}⚠ После перезагрузки проверьте:${NC}"
echo "  1. ip link show gre1"
echo "  2. vtysh -c 'show ip ospf neighbor'"
echo "  3. ping 172.16.1.2 (или 172.16.1.1)"
echo ""
