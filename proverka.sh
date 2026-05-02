#!/bin/bash
# =============================================================================
# NAT Setup Script for HQ-RTR (Alt Linux Server)
# Demo2026 Exam - Правильная конфигурация NAT
# =============================================================================

set -e

echo "=== Настройка NAT на HQ-RTR ==="

# Внешний интерфейс (подключён к провайдеру/интернету)
WAN_IF="ens33"

# Внутренние подсети (с ПРАВИЛЬНЫМИ масками!)
SUBNETS=(
    "192.168.10.0/27"   # VLAN 100 (SRV-Net)
    "192.168.20.0/28"   # VLAN 200 (CLI-Net)
    "192.168.99.0/29"   # VLAN 999 (Mgmt)
    "192.168.100.0/28"  # GRE tunnel (если есть)
)

# -----------------------------------------------------------------------------
# 1. Включаем IP forwarding
# -----------------------------------------------------------------------------
echo "[1] Включаем IP forwarding..."

# Временно
sysctl -w net.ipv4.ip_forward=1

# Постоянно
if [ ! -f /etc/sysctl.d/99-ipforward.conf ]; then
    cat > /etc/sysctl.d/99-ipforward.conf << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
EOF
    echo "   -> Создан /etc/sysctl.d/99-ipforward.conf"
fi

# -----------------------------------------------------------------------------
# 2. Очищаем старые NAT правила
# -----------------------------------------------------------------------------
echo "[2] Очищаем старые NAT правила..."
iptables -t nat -F
iptables -t nat -X
iptables -F FORWARD
iptables -X FORWARD

# -----------------------------------------------------------------------------
# 3. Создаём правильные NAT правила
# -----------------------------------------------------------------------------
echo "[3] Создаём NAT правила (MASQUERADE в POSTROUTING)..."

for subnet in "${SUBNETS[@]}"; do
    # MASQUERADE только в цепочке POSTROUTING!
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$WAN_IF" -j MASQUERADE
    echo "   -> Добавлено правило для $subnet"
done

# -----------------------------------------------------------------------------
# 4. Разрешаем forwarding для внутренних сетей
# -----------------------------------------------------------------------------
echo "[4] Настраиваем FORWARD цепочку..."

for subnet in "${SUBNETS[@]}"; do
    iptables -A FORWARD -i "$WAN_IF" -o ens37 -d "$subnet" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i ens37 -o "$WAN_IF" -s "$subnet" -j ACCEPT
    echo "   -> FORWARD разрешён для $subnet"
done

# -----------------------------------------------------------------------------
# 5. Сохраняем правила iptables
# -----------------------------------------------------------------------------
echo "[5] Сохраняем правила iptables..."

# Для Alt Linux
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
    iptables-save > /etc/iptables/iptables.rules 2>/dev/null || \
    echo "   -> Внимание: не удалось сохранить автоматически"
    echo "   -> Выполните вручную: iptables-save > /etc/sysconfig/iptables"
fi

# -----------------------------------------------------------------------------
# 6. Выводим результат
# -----------------------------------------------------------------------------
echo ""
echo "=== Проверка настройки ==="
echo ""
echo "IP Forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
echo ""
echo "NAT правила (POSTROUTING):"
iptables -t nat -L POSTROUTING -n -v --line-numbers
echo ""
echo "FORWARD правила:"
iptables -L FORWARD -n -v --line-numbers
echo ""
echo "=== NAT настроен! ==="
