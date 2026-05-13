#!/bin/bash
#===============================================================================
# NAT Setup for Demo2026 - ALT Linux 10.4 (etcnet compatible)
#===============================================================================

set -e  # Выход при ошибке

# Цвета (исправлены экранирования)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

line() { echo "-----------------------------------------------"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_in() { echo -e "${CYAN}[...]${NC} $1"; }
msg_err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Проверка root
if [ "$EUID" -ne 0 ]; then 
    msg_err "Запустите от root"
    exit 1
fi

echo -e "${CYAN}=== NAT для ALT Linux 10.4 ===${NC}"

#===============================================================================
# ЭТАП 1: Проверка iptables
#===============================================================================
line
echo -e "${WHITE}ЭТАП 1: Проверка iptables${NC}"
line

if ! command -v iptables >/dev/null 2>&1; then
    msg_in "Установка iptables..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq iptables 2>/dev/null || {
        msg_err "Не удалось установить iptables"
        exit 1
    }
fi
msg_ok "iptables: $(iptables --version 2>&1 | head -1)"

#===============================================================================
# ЭТАП 2: IP Forwarding
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 2: IP Forwarding${NC}"
line

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
msg_ok "IP forwarding включен"

#===============================================================================
# ЭТАП 3: Выбор интерфейсов (без валидации файлов)
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 3: Выбор интерфейсов${NC}"
line

# Показываем доступные интерфейсы
echo "Доступные интерфейсы:"
ip -br link show | grep -v lo | awk '{printf "  %s - %s\n", $1, $2}'
echo ""

# WAN интерфейс
while true; do
    read -p "Введите WAN интерфейс (например, enp7s1): " WAN
    [ -z "$WAN" ] && continue
    [ -d "/sys/class/net/$WAN" ] && break
    msg_err "Интерфейс $WAN не найден"
done
msg_ok "WAN: $WAN"

# LAN сети (упрощённый ввод)
echo ""
echo "Введите LAN подсети через пробел (например, 172.16.0.0/16 192.168.100.0/24):"
read -a LAN_NETS

if [ ${#LAN_NETS[@]} -eq 0 ]; then
    LAN_NETS=("172.16.0.0/16")
    msg_in "Используется по умолчанию: ${LAN_NETS[0]}"
fi

#===============================================================================
# ЭТАП 4: Подтверждение
#===============================================================================
echo ""
echo -e "${CYAN}Конфигурация:${NC}"
echo "  WAN: $WAN"
echo "  LAN: ${LAN_NETS[*]}"
echo ""
read -p "Применить NAT? (y/n): " confirm
[[ "$confirm" =~ ^[Yy] ]] || { msg_in "Отменено"; exit 0; }

#===============================================================================
# ЭТАП 5: Настройка NAT
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 5: Применение правил${NC}"
line

# Очистка старых правил
msg_in "Очистка правил..."
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# Добавление правил
msg_in "Добавление MASQUERADE..."
for net in "${LAN_NETS[@]}"; do
    iptables -t nat -A POSTROUTING -o "$WAN" -s "$net" -j MASQUERADE
    echo -e "  ${GREEN}✓${NC} $net → $WAN"
done

# Разрешение FORWARD
iptables -A FORWARD -i "$WAN" -o "$WAN" -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

msg_ok "NAT правила добавлены"

#===============================================================================
# ЭТАП 6: Сохранение для ALT Linux
#===============================================================================
echo ""
line
echo -e "${WHITE}ЭТАП 6: Сохранение конфигурации${NC}"
line

# Сохраняем правила
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
msg_ok "Правила сохранены: /etc/iptables/rules.v4"

# Для etcnet: создаём post-up скрипт
mkdir -p /etc/net/ifaces/post-up.d
cat > /etc/net/ifaces/post-up.d/nat-restore.sh << 'EOF'
#!/bin/bash
[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
EOF
chmod +x /etc/net/ifaces/post-up.d/nat-restore.sh
msg_ok "Автозагрузка NAT настроена"

#===============================================================================
# ИТОГ
#===============================================================================
echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         NAT УСПЕШНО НАСТРОЕН!                        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "Проверка:"
echo -e "  ${YELLOW}iptables -t nat -L POSTROUTING -n -v${NC}"
echo -e "  ${YELLOW}ping -c 2 8.8.8.8${NC} (с клиента)"
echo ""
