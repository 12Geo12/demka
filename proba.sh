#!/bin/bash
################################################################################
# FRRouting + GRE + OSPF для ALT Linux
# Версия 2.0: Очистка старых конфигов + вывод настроек
################################################################################

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ $EUID -ne 0 ]; then
    echo -e "${RED}✗ Запустите от root!${NC}"
    exit 1
fi

################################################################################
# ФУНКЦИЯ ОЧИСТКИ СТАРЫХ КОНФИГОВ
################################################################################
cleanup_old_config() {
    echo -e "${CYAN}>>> Очистка старых конфигураций...${NC}"
    
    # Останавливаем FRR
    systemctl stop frr 2>/dev/null
    
    # Удаляем старый GRE туннель
    ip link set gre1 down 2>/dev/null
    ip tunnel del gre1 2>/dev/null
    
    # Очищаем конфиги FRR
    rm -f /etc/frr/frr.conf
    rm -f /etc/frr/daemons
    rm -f /etc/frr/vtysh.conf
    
    # Очищаем etcnet конфиг для gre1
    rm -rf /etc/net/ifaces/gre1
    
    # Очищаем sysctl от наших настроек (если нужно - можно пропустить)
    # Оставляем только базовую очистку
    
    echo -e "${GREEN}✓ Старые конфиги очищены${NC}"
}

################################################################################
# ФУНКЦИЯ ВЫВОДА ТЕКУЩИХ НАСТРОЕК
################################################################################
show_current_config() {
    echo ""
    echo -e "${BOLD}${CYAN}=== ТЕКУЩИЕ НАСТРОЙКИ ===${NC}"
    
    # GRE туннель
    echo -e "${YELLOW}🔹 GRE туннель:${NC}"
    if ip link show gre1 &>/dev/null; then
        ip addr show gre1 | grep "inet " | sed 's/^/   /'
        echo "   $(ip tunnel show gre1 2>/dev/null | head -1)"
    else
        echo "   (не настроен)"
    fi
    
    # FRR статус
    echo -e "\n${YELLOW}🔹 FRR служба:${NC}"
    if systemctl is-active --quiet frr 2>/dev/null; then
        echo "   ${GREEN}активна${NC}"
    else
        echo "   ${RED}не активна${NC}"
    fi
    
    # OSPF конфиг (если есть)
    echo -e "\n${YELLOW}🔹 OSPF конфигурация:${NC}"
    if [ -f /etc/frr/frr.conf ]; then
        grep -E "router-id|network" /etc/frr/frr.conf 2>/dev/null | sed 's/^/   /' || echo "   (пусто)"
    else
        echo "   (файл не найден)"
    fi
    
    # Маршруты
    echo -e "\n${YELLOW}🔹 OSPF маршруты:${NC}"
    ip route | grep ospf | head -5 | sed 's/^/   /' || echo "   (нет)"
    
    echo ""
}

################################################################################
# ВВОД ПАРАМЕТРОВ
################################################################################
echo -e "${BOLD}${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  FRR + GRE + OSPF для ALT Linux   ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

# Показываем текущие настройки ДО изменений
show_current_config

# Очистка старых конфигов
read -p "Очистить старые конфигурации? [Y/n]: " CLEANUP_ANSWER
CLEANUP_ANSWER=${CLEANUP_ANSWER:-Y}
if [[ "$CLEANUP_ANSWER" =~ ^[Yy]$ ]]; then
    cleanup_old_config
fi

echo ""
echo -e "${CYAN}=== Ввод параметров ===${NC}"

# Router ID
read -p "Router ID (например 1.1.1.1): " RID
RID=${RID:-1.1.1.1}

# Интерфейс
echo ""
echo -e "${CYAN}Доступные интерфейсы:${NC}"
ip -br addr show | grep -v lo | sed 's/^/  /'
read -p "Имя внешнего интерфейса: " IFACE
IFACE=${IFACE:-enp7s1}

LOCAL_IP=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
if [ -z "$LOCAL_IP" ]; then
    echo -e "${RED}✗ Не найден IP на $IFACE${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Найден IP: $LOCAL_IP${NC}"

# GRE параметры
echo ""
echo -e "${CYAN}=== Параметры GRE туннеля ===${NC}"
read -p "Локальный IP GRE (например 172.16.1.1): " GRE_LOCAL
GRE_LOCAL=${GRE_LOCAL:-172.16.1.1}

read -p "Удаленный IP GRE (например 192.168.5.2): " GRE_REMOTE
GRE_REMOTE=${GRE_REMOTE:-192.168.5.2}

read -p "Маска GRE (24): " GRE_MASK
GRE_MASK=${GRE_MASK:-24}

# OSPF сети
echo ""
echo -e "${CYAN}=== Сети для OSPF ===${NC}"
echo "Введите сети через пробел (пример: 172.16.1.0/24 192.168.10.0/24)"
echo "Или Enter для использования только GRE сети"
read -p "OSPF сети: " OSPF_NETS_INPUT

if [ -z "$OSPF_NETS_INPUT" ]; then
    GRE_NETWORK=$(echo "$GRE_LOCAL" | awk -F. '{print $1"."$2"."$3".0"}')
    OSPF_NETS="${GRE_NETWORK}/${GRE_MASK}"
else
    GRE_NETWORK=$(echo "$GRE_LOCAL" | awk -F. '{print $1"."$2"."$3".0"}')
    OSPF_NETS="${OSPF_NETS_INPUT} ${GRE_NETWORK}/${GRE_MASK}"
fi

# Итоговый вывод параметров
echo ""
echo -e "${BOLD}${YELLOW}╔════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║     ИТОГОВЫЕ ПАРАМЕТРЫ            ║${NC}"
echo -e "${BOLD}${YELLOW}╚════════════════════════════════════╝${NC}"
echo -e "  ${CYAN}Router ID:${NC}      ${RID}"
echo -e "  ${CYAN}Интерфейс:${NC}      ${IFACE} (${LOCAL_IP})"
echo -e "  ${CYAN}GRE Local:${NC}      ${GRE_LOCAL}/${GRE_MASK}"
echo -e "  ${CYAN}GRE Remote:${NC}     ${GRE_REMOTE}"
echo -e "  ${CYAN}OSPF сети:${NC}      ${OSPF_NETS}"
echo ""
read -p "Продолжить установку? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено пользователем"
    exit 0
fi

################################################################################
# УСТАНОВКА ПАКЕТОВ
################################################################################
echo -e "${CYAN}>>> Установка FRR...${NC}"
apt-get update -qq
apt-get install -y -qq frr iproute2 iptables
if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Ошибка установки!${NC}"
    exit 1
fi
echo -e "${GREEN}✓ FRR установлен${NC}"

################################################################################
# НАСТРОЙКА ДЕМОНОВ
################################################################################
echo -e "${CYAN}>>> Настройка демонов...${NC}"
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
EOF

################################################################################
# OSPF КОНФИГУРАЦИЯ
################################################################################
echo -e "${CYAN}>>> Настройка OSPF...${NC}"
cat > /etc/frr/frr.conf << EOF
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
 ip ospf authentication
 ip ospf authentication-key 123
EOF

for net in $OSPF_NETS; do
    echo " network $net area 0" >> /etc/frr/frr.conf
done

cat >> /etc/frr/frr.conf << 'EOF'
!
line vty
!
EOF

################################################################################
# GRE ТУННЕЛЬ
################################################################################
echo -e "${CYAN}>>> Создание GRE туннеля...${NC}"

# Удаляем старый (на всякий случай)
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null

# Создаем новый
ip tunnel add gre1 mode gre local "$LOCAL_IP" remote "$GRE_REMOTE" ttl 64
if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Не удалось создать туннель!${NC}"
    echo "Проверьте доступность $GRE_REMOTE"
    ping -c 2 "$GRE_REMOTE" || true
    exit 1
fi

ip addr add "${GRE_LOCAL}/${GRE_MASK}" dev gre1
ip link set gre1 up
ip link set gre1 mtu 1400

sleep 1
if ! ip link show gre1 | grep -q "UP"; then
    echo -e "${RED}✗ GRE туннель не поднялся!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ GRE создан: ${GRE_LOCAL}/${GRE_MASK} -> ${GRE_REMOTE}${NC}"

# Сохранение для etcnet (ALT Linux)
mkdir -p /etc/net/ifaces/gre1
cat > /etc/net/ifaces/gre1/options << EOF
TYPE=gre
REMOTE=$GRE_REMOTE
LOCAL=$LOCAL_IP
TTL=64
DISABLE=no
EOF
echo "${GRE_LOCAL}/${GRE_MASK}" > /etc/net/ifaces/gre1/ipv4address

################################################################################
# СИСТЕМНЫЕ НАСТРОЙКИ
################################################################################
echo -e "${CYAN}>>> Системные настройки...${NC}"

# IP forwarding
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# rp_filter для GRE
grep -q "rp_filter=2" /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.gre1.rp_filter=2
EOF
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1

echo -e "${GREEN}✓ Системные параметры применены${NC}"

################################################################################
# ЗАПУСК СЛУЖБ
################################################################################
echo -e "${CYAN}>>> Запуск служб...${NC}"
systemctl enable frr --quiet 2>/dev/null
systemctl restart frr
sleep 2

################################################################################
# ФИНАЛЬНЫЙ ОТЧЁТ
################################################################################
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         НАСТРОЙКА ЗАВЕРШЕНА       ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════╝${NC}"
echo ""

# Показываем новые настройки ПОСЛЕ изменений
show_current_config

# Проверка статуса
echo -e "${CYAN}Статус служб:${NC}"
if systemctl is-active --quiet frr; then
    echo -e "  ${GREEN}✓ FRR: запущен${NC}"
else
    echo -e "  ${RED}✗ FRR: ошибка запуска${NC}"
fi

if ip link show gre1 | grep -q "UP"; then
    echo -e "  ${GREEN}✓ GRE: активен${NC}"
    ip -brief addr show gre1 | sed 's/^/    /'
else
    echo -e "  ${RED}✗ GRE: не активен${NC}"
fi

# Тест связи
echo ""
echo -e "${CYAN}Тест связи через туннель:${NC}"
ping -c 2 -W 1 -I gre1 "$GRE_REMOTE" 2>/dev/null && \
    echo -e "  ${GREEN}✓ Пинг успешен${NC}" || \
    echo -e "  ${YELLOW}⚠ Пинг не прошёл (проверьте удалённую сторону)${NC}"

# Полезные команды
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo "  vtysh                              # Войти в CLI FRR"
echo "  vtysh -c 'show ip ospf neighbor'   # Показать соседей OSPF"
echo "  vtysh -c 'show ip route ospf'      # Показать OSPF маршруты"
echo "  vtysh -c 'show running-config'     # Показать полную конфигурацию"
echo "  ip addr show gre1                  # Информация о GRE"
echo "  ping -I gre1 ${GRE_REMOTE}         # Тест туннеля"
echo "  journalctl -u frr -f               # Логи FRR в реальном времени"
echo ""
echo -e "${GREEN}✓ Готово к работе!${NC}"
