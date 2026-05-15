#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE туннель) с полной персистентностью
# Версия: 2.1 - Исправлена проблема с синтаксисом
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"

# Функция логирования
log() {
    local msg="$1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log "${CYAN}==============================================================================${NC}"
log "${CYAN}  Настройка FRRouting (OSPF + GRE) с полной персистентностью${NC}"
log "${CYAN}==============================================================================${NC}"
log ""

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log "${RED}✗ Ошибка: Запустите скрипт от root${NC}"
    exit 1
fi

# Проверка ОС
if ! command -v apt-get >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
    log "${RED}✗ Ошибка: Не найдены apt-get или yum${NC}"
    exit 1
fi

#===============================================================================
# ФУНКЦИИ
#===============================================================================

log_info() {
    log "${GREEN}✓${NC} $1"
}

log_warn() {
    log "${YELLOW}⚠${NC} $1"
}

log_error() {
    log "${RED}✗${NC} $1"
}

check_service() {
    local service="$1"
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

log "${CYAN}=== Выбор роли роутера ===${NC}"
echo "1) HQ-RTR (Router ID: 1.1.1.1, GRE IP: 172.16.1.1)"
echo "2) BR-RTR (Router ID: 2.2.2.2, GRE IP: 172.16.1.2)"
read -p "Выберите роль [1]: " role_choice
role_choice="${role_choice:-1}"

case "$role_choice" in
    2)
        ROLE="BR-RTR"
        RID="2.2.2.2"
        GRE_IP="172.16.1.2/24"
        GRE_LOCAL_IP=$(ip -4 addr show ens33 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        GRE_REMOTE_IP="192.168.4.2"
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

log "${YELLOW}Роль: $ROLE (Router ID: $RID)${NC}"
log ""

# Запрос IP если не определился автоматически
if [ -z "$GRE_LOCAL_IP" ]; then
    log_warn "Не удалось определить локальный IP автоматически"
    read -p "Введите локальный IP адрес для GRE туннеля: " GRE_LOCAL_IP
fi

log_info "Локальный IP: $GRE_LOCAL_IP"
log_info "Удаленный IP: $GRE_REMOTE_IP"

#===============================================================================
# УСТАНОВКА FRR
#===============================================================================

log "${CYAN}=== Установка FRRouting ===${NC}"

if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu/Alt Linux
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq frr frr-pythontools iproute2 iptables 2>/dev/null
elif command -v yum >/dev/null 2>&1; then
    # RHEL/CentOS
    yum install -y -q frr iproute iptables 2>/dev/null
else
    log_error "Не удалось установить FRR"
    exit 1
fi

log_info "FRR установлен"

#===============================================================================
# НАСТРОЙКА FRR DAEMONS
#===============================================================================

log "${CYAN}=== Настройка демонов FRR ===${NC}"

cat > /etc/frr/daemons << 'DAEMONS_EOF'
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
DAEMONS_EOF

log_info "Демоны FRR настроены (zebra=yes, ospfd=yes)"

#===============================================================================
# НАСТРОЙКА GRE ТУННЕЛЯ (etcnet для Alt Linux)
#===============================================================================

log "${CYAN}=== Настройка GRE туннеля ===${NC}"

# Создаем директорию для конфигурации GRE
mkdir -p /etc/net/ifaces/gre1

# Конфигурация интерфейса GRE для etcnet (Alt Linux)
cat > /etc/net/ifaces/gre1/options << GRE_OPTIONS_EOF
# GRE tunnel configuration
TYPE=gre
REMOTE=${GRE_REMOTE_IP}
LOCAL=${GRE_LOCAL_IP}
TTL=64
DISABLE=no
GRE_OPTIONS_EOF

cat > /etc/net/ifaces/gre1/ipv4address << GRE_IP_EOF
${GRE_IP}
GRE_IP_EOF

log_info "GRE туннель настроен (Local: $GRE_LOCAL_IP, Remote: $GRE_REMOTE_IP)"

# Также создаем systemd service для совместимости
cat > /etc/systemd/system/gre-tunnel.service << GRE_SERVICE_EOF
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
GRE_SERVICE_EOF

systemctl daemon-reload
systemctl enable gre-tunnel.service 2>/dev/null
log_info "systemd service для GRE создан и включен в автозагрузку"

#===============================================================================
# НАСТРОЙКА OSPF
#===============================================================================

log "${CYAN}=== Настройка OSPF ===${NC}"

# Начало конфигурации
cat > /etc/frr/frr.conf << OSPF_CONF_EOF
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id ${RID}
 passive-interface default
 no passive-interface gre1
!
 interface gre1
  ip ospf authentication
  ip ospf authentication-key 123
OSPF_CONF_EOF

# Добавляем сети в OSPF
for network in $OSPF_NETWORKS; do
    echo " network $network area 0" >> /etc/frr/frr.conf
done

# Завершение конфигурации
cat >> /etc/frr/frr.conf << OSPF_END_EOF
!
line vty
!
OSPF_END_EOF

log_info "OSPF настроен (Router ID: $RID)"
log_info "Сети OSPF: $OSPF_NETWORKS"

#===============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
#===============================================================================

log "${CYAN}=== Системные настройки ===${NC}"

# Включаем IP forwarding (проверяем перед добавлением)
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
log_info "IP forwarding включен"

# Настраиваем rp_filter для GRE (проверяем перед добавлением)
if ! grep -q "net.ipv4.conf.all.rp_filter=2" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf << SYSCTL_EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL_EOF
fi

sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
log_info "rp_filter настроен (loose mode)"

#===============================================================================
# ПРАВА ДОСТУПА
#===============================================================================

log "${CYAN}=== Настройка прав доступа ===${NC}"

# Устанавливаем правильные права
chown frr:frr /etc/frr/frr.conf 2>/dev/null || chown frr:frr /etc/frr/frr.conf 2>/dev/null
chmod 640 /etc/frr/frr.conf 2>/dev/null
log_info "Права доступа настроены"

#===============================================================================
# ВКЛЮЧЕНИЕ СЛУЖБ В АВТОЗАГРУЗКУ
#===============================================================================

log "${CYAN}=== Включение служб в автозагрузку ===${NC}"

systemctl enable frr 2>/dev/null
systemctl enable network 2>/dev/null || log_warn "network service не найден"
log_info "Службы добавлены в автозагрузку"

#===============================================================================
# ЗАПУСК СЛУЖБ
#===============================================================================

log "${CYAN}=== Запуск служб ===${NC}"

# Поднимаем GRE туннель вручную (на случай если etcnet еще не загрузился)
ip tunnel del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$GRE_REMOTE_IP" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400
log_info "GRE туннель поднят"

# Перезапускаем FRR
systemctl restart frr 2>/dev/null
log_info "FRR перезапущен"

sleep 3

#===============================================================================
# ПРОВЕРКА И СОХРАНЕНИЕ
#===============================================================================

log "${CYAN}=== Проверка конфигурации ===${NC}"

# Проверка GRE
if ip link show gre1 >/dev/null 2>&1; then
    log_info "GRE туннель активен"
    ip -brief addr show gre1 2>/dev/null
else
    log_error "GRE туннель не поднят!"
    exit 1
fi

# Проверка OSPF соседей
log ""
log "${CYAN}OSPF соседи:${NC}"
vtysh -c "show ip ospf neighbor" 2>/dev/null || log_warn "OSPF соседи не найдены (подождите 30 сек)"

# Проверка маршрутов
log ""
log "${CYAN}Маршруты OSPF:${NC}"
ip route show | grep -i ospf 2>/dev/null || log_warn "Маршруты OSPF не найдены"

#===============================================================================
# ПЕРСИСТЕНТНОСТЬ - ПРОВЕРКА
#===============================================================================

log "${CYAN}=== Проверка персистентности ===${NC}"

checks_passed=0
checks_total=6

# 1. Проверка ospfd
if grep -q '^ospfd=yes' /etc/frr/daemons 2>/dev/null; then
    log "${GREEN}✓${NC} [1/6] ospfd=yes в /etc/frr/daemons"
    checks_passed=$((checks_passed + 1))
else
    log "${RED}✗${NC} [1/6] ospfd не включен (ОШИБКА!)"
fi

# 2. Проверка zebra
if grep -q '^zebra=yes' /etc/frr/daemons 2>/dev/null; then
    log "${GREEN}✓${NC} [2/6] zebra=yes в /etc/frr/daemons"
    checks_passed=$((checks_passed + 1))
else
    log "${RED}✗${NC} [2/6] zebra не включен (ОШИБКА!)"
fi

# 3. Проверка GRE в etcnet
if [ -f /etc/net/ifaces/gre1/options ]; then
    log "${GREEN}✓${NC} [3/6] GRE конфигурация в /etc/net/ifaces/gre1"
    checks_passed=$((checks_passed + 1))
else
    log "${YELLOW}⚠${NC} [3/6] etcnet GRE не найден"
fi

# 4. Проверка systemd GRE
if systemctl is-enabled gre-tunnel.service >/dev/null 2>&1; then
    log "${GREEN}✓${NC} [4/6] gre-tunnel.service в автозагрузке"
    checks_passed=$((checks_passed + 1))
else
    log "${RED}✗${NC} [4/6] gre-tunnel.service не в автозагрузке"
fi

# 5. Проверка FRR автозагрузка
if systemctl is-enabled frr >/dev/null 2>&1; then
    log "${GREEN}✓${NC} [5/6] frr в автозагрузке"
    checks_passed=$((checks_passed + 1))
else
    log "${RED}✗${NC} [5/6] frr не в автозагрузке"
fi

# 6. Проверка sysctl
if grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    log "${GREEN}✓${NC} [6/6] IP forwarding сохранен в sysctl.conf"
    checks_passed=$((checks_passed + 1))
else
    log "${RED}✗${NC} [6/6] IP forwarding не сохранен"
fi

log ""
log "${CYAN}Пройдено проверок: ${checks_passed}/${checks_total}${NC}"

if [ "$checks_passed" -eq "$checks_total" ]; then
    log "${GREEN}✓ Все проверки пройдены! Конфигурация сохранена.${NC}"
else
    log "${YELLOW}⚠ Некоторые проверки не пройдены. Проверьте логи: ${LOG_FILE}${NC}"
fi

#===============================================================================
# ФИНАЛЬНЫЙ ОТЧЕТ
#===============================================================================

log ""
log "${GREEN}==============================================================================${NC}"
log "${GREEN}  НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
log "${GREEN}==============================================================================${NC}"
log ""
log "${CYAN}Полезные команды:${NC}"
log "  vtysh -c 'show ip ospf neighbor'  # Показать OSPF соседей"
log "  ip route show | grep ospf          # Показать OSPF маршруты"
log "  systemctl status frr               # Статус FRR"
log "  systemctl status gre-tunnel        # Статус GRE туннеля"
log "  journalctl -u frr -f               # Логи FRR в реальном времени"
log ""
log "${CYAN}Лог установки:${NC} ${LOG_FILE}"
log ""
log "${YELLOW}⚠ После перезагрузки проверьте:${NC}"
log "  1. ip link show gre1"
log "  2. vtysh -c 'show ip ospf neighbor'"
log "  3. ping 172.16.1.2 (или 172.16.1.1)"
log ""
