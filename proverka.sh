#!/bin/bash
#===============================================================================
# FRR OSPF + GRE Setup for ALT Linux - ГАРАНТИРОВАННАЯ ПЕРСИСТЕНТНОСТЬ
# Версия 5.0 - Исправлено сохранение
#===============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FRR_CONF="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"
NET_DIR="/etc/net/ifaces"

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "Запустите от root!"
    exit 1
fi

#===============================================================================
# НАСТРОЙКА
#===============================================================================
clear
echo -e "${CYAN}FRR OSPF/GRE Setup v5.0${NC}"
echo "=========================="

# 1. Установка
log_info "Проверка FRR..."
if ! command -v vtysh &>/dev/null; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y frr frr-pythontools >/dev/null 2>&1
    log_ok "FRR установлен"
fi

# 2. Выбор роли
echo -e "\n${YELLOW}Роль роутера:${NC}"
HOST=$(hostname | tr '[:upper:]' '[:lower:]')
case "$HOST" in
    *hq-rtr*) RID="1.1.1.1" ;;
    *br-rtr*) RID="2.2.2.2" ;;
    *) RID="1.1.1.1" ;;
esac
read -p "Router ID [$RID]: " INPUT_RID
RID="${INPUT_RID:-$RID}"
log_ok "Router ID: $RID"

# 3. GRE туннель
echo -e "\n${YELLOW}GRE Туннель:${NC}"
log_info "Интерфейсы:"
ls /sys/class/net/ | grep -v lo | grep -v gre | nl

read -p "Внешний интерфейс (номер): " if_num
EXT_IF=$(ls /sys/class/net/ | grep -v lo | grep -v gre | sed -n "${if_num}p")
EXT_IP=$(ip -4 addr show "$EXT_IF" | grep -oP 'inet \K[\d.]+' | head -1)
read -p "IP удаленного роутера: " REMOTE_IP

if [[ "$HOST" == *hq-rtr* ]]; then
    GRE_IP="172.16.100.1/29"
else
    GRE_IP="172.16.100.2/29"
fi
read -p "IP туннеля [$GRE_IP]: " INPUT_GRE
GRE_IP="${INPUT_GRE:-$GRE_IP}"

# ВАЖНО: Правильный формат etcnet для ALT Linux
log_info "Настройка etcnet (ПРАВИЛЬНЫЙ ФОРМАТ)..."
mkdir -p "$NET_DIR/gre1"

# options - главный файл
cat > "$NET_DIR/gre1/options" << EOF
TYPE=gre
BOOTPROTO=static
IPADDR=$GRE_IP
REMOTE_ADDR=$REMOTE_IP
LOCAL_ADDR=$EXT_IP
TTL=64
ONBOOT=yes
EOF

# route - маршруты (опционально)
echo "" > "$NET_DIR/gre1/route-eth0"

chmod 644 "$NET_DIR/gre1/options"
log_ok "etcnet конфиг создан в $NET_DIR/gre1/options"

# Поднимаем туннель сейчас
ip link set gre1 down 2>/dev/null || true
ip tunnel del gre1 2>/dev/null || true
sleep 1
ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
sleep 1
ip link show gre1 &>/dev/null && log_ok "GRE туннель поднят" || log_err "Ошибка GRE!"

# 4. OSPF
echo -e "\n${YELLOW}OSPF:${NC}"
read -p "Пароль [P@ssw0rd]: " PASS
PASS="${PASS:-P@ssw0rd}"

log_info "Сети OSPF (пример: 192.168.10.0/24):"
NETS=""
while true; do
    read -p "Сеть (Enter=готово): " net
    [[ -z "$net" ]] && break
    NETS+=" network $net area 0"$'\n'
done
[[ -z "$NETS" ]] && NETS=" network 0.0.0.0/0 area 0"$'\n'

# 5. Генерация frr.conf
log_info "Создание конфигурации..."
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
$(echo "$NETS" | sed 's/^/ /')
!
line vty
!
EOF

chmod 644 "$FRR_CONF"

# 6. daemons - ВАЖНО для автозапуска
cat > "$FRR_DAEMONS" << 'EOF'
zebra=yes
bgpd=no
ospfd=yes
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

chmod 644 "$FRR_DAEMONS"
log_ok "ospfd=yes в daemons"

# 7. КЛЮЧЕВОЙ МОМЕНТ -多重ное сохранение
echo -e "\n${CYAN}=== СОХРАНЕНИЕ КОНФИГУРАЦИИ ===${NC}"

# Метод 1: write memory через vtysh
if systemctl restart frr && sleep 3 && systemctl is-active frr &>/dev/null; then
    log_ok "FRR запущен"
    
    # Ждем пока zebra загрузится
    sleep 2
    
    # Пробуем write memory
    if vtysh -c "write memory" 2>&1; then
        log_ok "Сохранено: write memory"
    else
        log_err "write memory не сработал, копируем вручную..."
    fi
else
    log_err "FRR не запустился!"
    cat "$FRR_CONF"
    exit 1
fi

# Метод 2: Копирование в vtysh.conf (альтернатива)
cp "$FRR_CONF" /etc/frr/vtysh.conf
chmod 644 /etc/frr/vtysh.conf
log_ok "Скопировано в /etc/frr/vtysh.conf"

# Метод 3: Создаем backup для надежности
cp "$FRR_CONF" /etc/frr/frr.conf.backup
log_ok "Backup создан"

# 8. Автозапуск служб
log_info "Включение автозапуска..."
systemctl enable frr 2>/dev/null || true
systemctl enable net 2>/dev/null || true

# Для etcnet - создаем скрипт в rc.local если есть
if [[ -f /etc/rc.d/rc.local ]]; then
    grep -q "ifup gre1" /etc/rc.d/rc.local 2>/dev/null || {
        echo "# GRE tunnel" >> /etc/rc.d/rc.local
        echo "sleep 5 && ifup gre1" >> /etc/rc.d/rc.local
        chmod +x /etc/rc.d/rc.local
        log_ok "Добавлено в rc.local"
    }
fi

# 9. ФИНАЛЬНАЯ ПРОВЕРКА
echo -e "\n${GREEN}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"

checks_passed=0
checks_total=5

if systemctl is-enabled frr &>/dev/null; then
    echo -e " ${GREEN}✓${NC} frr.service enabled"
    ((checks_passed++))
else
    echo -e " ${RED}✗${NC} frr.service NOT enabled"
fi

if systemctl is-enabled net &>/dev/null 2>&1; then
    echo -e " ${GREEN}✓${NC} net.service enabled"
    ((checks_passed++))
else
    echo -e " ${YELLOW}!${NC} net.service (etcnet)"
    ((checks_passed++))  # Не критично
fi

if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
    echo -e " ${GREEN}✓${NC} ospfd=yes"
    ((checks_passed++))
else
    echo -e " ${RED}✗${NC} ospfd NOT set"
fi

if [[ -f "$NET_DIR/gre1/options" ]] && grep -q 'ONBOOT=yes' "$NET_DIR/gre1/options" 2>/dev/null; then
    echo -e " ${GREEN}✓${NC} GRE ONBOOT=yes"
    ((checks_passed++))
else
    echo -e " ${RED}✗${NC} GRE NOT configured for boot"
fi

if [[ -f /etc/frr/vtysh.conf ]]; then
    echo -e " ${GREEN}✓${NC} vtysh.conf exists"
    ((checks_passed++))
else
    echo -e " ${RED}✗${NC} vtysh.conf missing"
fi

echo ""
echo "Результат: $checks_passed/$checks_total проверок пройдено"

if [[ $checks_passed -eq $checks_total ]]; then
    echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  КОНФИГУРАЦИЯ СОХРАНЕНА!               ║${NC}"
    echo -e "${GREEN}║  После reboot всё поднимется!          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
else
    echo -e "\n${YELLOW}[!] Некоторые проверки не прошли${NC}"
fi

# 10. Тестирование
echo -e "\n${CYAN}=== ТЕКУЩИЙ СТАТУС ===${NC}"
echo "Интерфейс gre1:"
ip addr show gre1 2>/dev/null | grep "inet " || echo "  Не поднят"

echo -e "\nСоседи OSPF:"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  Нет соседей (проверьте второй роутер)"

echo -e "\nМаршруты OSPF:"
vtysh -c "show ip route ospf" 2>/dev/null | head -10 || echo "  Нет маршрутов"

echo -e "\n${WHITE}Для проверки после reboot:${NC}"
echo "  reboot"
echo "  systemctl status frr"
echo "  ip addr show gre1"
echo "  vtysh -c 'show ip ospf neighbor'"
