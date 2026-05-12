#!/bin/bash
#===============================================================================
# FRR OSPF + GRE Setup for ALT Linux - ИСПРАВЛЕННЫЙ СИНТАКСИС
# Версия 5.1 - Правильные параметры etcnet
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

clear
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  FRR OSPF/GRE Setup v5.1 (FIXED)         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"

# 1. Установка
log_info "Проверка FRR..."
if ! command -v vtysh &>/dev/null; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y frr frr-pythontools >/dev/null 2>&1
    log_ok "FRR установлен"
else
    log_ok "FRR уже установлен"
fi

# 2. Выбор роли
echo -e "\n${YELLOW}=== Шаг 1: Идентификация ===${NC}"
HOST=$(hostname | tr '[:upper:]' '[:lower:]')
case "$HOST" in
    *hq-rtr*) RID="1.1.1.1"; DEF_GRE="172.16.100.1/29" ;;
    *br-rtr*) RID="2.2.2.2"; DEF_GRE="172.16.100.2/29" ;;
    *) RID="1.1.1.1"; DEF_GRE="172.16.100.1/29" ;;
esac

read -p "Router ID [$RID]: " INPUT_RID
RID="${INPUT_RID:-$RID}"
log_ok "Router ID: $RID"

# 3. GRE туннель - ИСПРАВЛЕНО!
echo -e "\n${YELLOW}=== Шаг 2: GRE Туннель ===${NC}"
log_info "Доступные интерфейсы:"

idx=1
> /tmp/frr_ifaces
for iface in $(ls /sys/class/net/ | grep -v lo | grep -v gre); do
    ip_out=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    printf " %2d) %-10s %s\n" $idx "$iface" "$ip_out"
    echo "$iface" >> /tmp/frr_ifaces
    idx=$((idx+1))
done

read -p "Внешний интерфейс (номер): " if_num
EXT_IF=$(sed -n "${if_num}p" /tmp/frr_ifaces)
EXT_IP=$(ip -4 addr show "$EXT_IF" | grep -oP 'inet \K[\d.]+' | head -1)
read -p "IP удаленного роутера: " REMOTE_IP

read -p "IP туннеля [$DEF_GRE]: " INPUT_GRE
GRE_IP="${INPUT_GRE:-$DEF_GRE}"

# ИСПРАВЛЕНО: Правильный синтаксис etcnet для ALT Linux
log_info "Создание etcnet конфигурации..."
mkdir -p "$NET_DIR/gre1"

cat > "$NET_DIR/gre1/options" << EOF
TYPE=gre
BOOTPROTO=static
IPADDR=$GRE_IP
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
ONBOOT=yes
EOF

chmod 644 "$NET_DIR/gre1/options"
touch "$NET_DIR/gre1/ipv4routes"
log_ok "etcnet конфиг создан: $NET_DIR/gre1/options"

# Показываем созданный конфиг
echo -e "\n${CYAN}Содержимое options:${NC}"
cat "$NET_DIR/gre1/options"

# Поднимаем туннель СЕЙЧАС
log_info "Активация GRE туннеля..."
ip link set gre1 down 2>/dev/null || true
ip tunnel del gre1 2>/dev/null || true
sleep 1

ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64
ip addr add "$GRE_IP" dev gre1
ip link set gre1 up
sleep 2

if ip link show gre1 &>/dev/null; then
    log_ok "GRE туннель поднят"
    ip addr show gre1 | grep "inet "
else
    log_err "Ошибка поднятия GRE туннеля!"
    exit 1
fi

# 4. OSPF конфигурация
echo -e "\n${YELLOW}=== Шаг 3: OSPF ===${NC}"
read -p "Пароль OSPF [P@ssw0rd]: " PASS
PASS="${PASS:-P@ssw0rd}"

log_info "Введите сети OSPF (пустая строка = готово):"
NETWORKS=""
while true; do
    read -p "Сеть (CIDR): " net
    [[ -z "$net" ]] && break
    NETWORKS+=" network $net area 0"$'\n'
done
[[ -z "$NETWORKS" ]] && NETWORKS=" network 0.0.0.0/0 area 0"$'\n'

# 5. Генерация frr.conf
log_info "Генерация конфигурации FRR..."
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
$(echo "$NETWORKS" | sed 's/^/ /')
!
line vty
!
EOF

chmod 644 "$FRR_CONF"

# 6. daemons
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
log_ok "ospfd=yes установлен"

# 7. Перезапуск и сохранение
echo -e "\n${CYAN}=== Сохранение конфигурации ===${NC}"
log_info "Перезапуск FRR..."

systemctl daemon-reload 2>/dev/null || true
systemctl restart frr
sleep 3

if systemctl is-active frr &>/dev/null; then
    log_ok "FRR запущен"
    
    sleep 2
    vtysh -c "write memory" 2>/dev/null && log_ok "Сохранено: write memory"
    cp "$FRR_CONF" /etc/frr/vtysh.conf
    log_ok "Скопировано в /etc/frr/vtysh.conf"
else
    log_err "FRR не запустился!"
    systemctl status frr --no-pager | head -10
    exit 1
fi

# 8. Автозапуск
log_info "Включение автозапуска..."
systemctl enable frr 2>/dev/null || true
systemctl enable net 2>/dev/null || true
log_ok "Автозапуск включен"

# 9. ФИНАЛЬНАЯ ПРОВЕРКА
echo -e "\n${GREEN}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"

checks=0
total=5

if systemctl is-enabled frr &>/dev/null; then
    echo -e " ${GREEN}✓${NC} frr.service enabled"
    ((checks++))
else
    echo -e " ${RED}✗${NC} frr.service"
fi

if systemctl is-enabled net &>/dev/null 2>&1; then
    echo -e " ${GREEN}✓${NC} net.service enabled"
    ((checks++))
else
    echo -e " ${YELLOW}!${NC} net.service"
    ((checks++))
fi

if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
    echo -e " ${GREEN}✓${NC} ospfd=yes"
    ((checks++))
else
    echo -e " ${RED}✗${NC} ospfd"
fi

if grep -q 'ONBOOT=yes' "$NET_DIR/gre1/options" 2>/dev/null; then
    echo -e " ${GREEN}✓${NC} GRE ONBOOT=yes"
    ((checks++))
else
    echo -e " ${RED}✗${NC} GRE ONBOOT"
fi

if grep -q 'REMOTE_ADDRESS=' "$NET_DIR/gre1/options" 2>/dev/null; then
    echo -e " ${GREEN}✓${NC} REMOTE_ADDRESS (правильно!)"
    ((checks++))
else
    echo -e " ${RED}✗${NC} REMOTE_ADDRESS"
fi

echo ""
echo "Пройдено: $checks/$total проверок"

if [[ $checks -eq $total ]]; then
    echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  НАСТРОЙКА ЗАВЕРШЕНА!                  ║${NC}"
    echo -e "${GREEN}║  Сохранено для перезагрузки!           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
else
    echo -e "\n${YELLOW}[!] Некоторые проверки не прошли${NC}"
fi

# 10. Тестирование
echo -e "\n${CYAN}=== ТЕКУЩИЙ СТАТУС ===${NC}"
echo "GRE туннель:"
ip addr show gre1 2>/dev/null | grep "inet " || echo "  Не поднят"

echo -e "\nСоседи OSPF:"
vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  Нет соседей"

echo -e "\n${WHITE}Проверка после reboot:${NC}"
echo "  reboot"
echo "  ip link show gre1"
echo "  vtysh -c 'show ip ospf neighbor'"
