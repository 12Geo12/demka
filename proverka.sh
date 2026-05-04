#!/bin/bash
# ПОЛНОЕ ИСПРАВЛЕНИЕ ПРАВ ДЛЯ ALT LINUX

echo "=== Анализ структуры ==="
echo ""

# Проверяем named.conf
echo "Проверка /etc/named.conf:"
ls -la /etc/named.conf

# Если это ссылка - находим реальный файл
if [ -L /etc/named.conf ]; then
    REAL_CONF=$(readlink -f /etc/named.conf)
    echo ""
    echo "Реальный путь: $REAL_CONF"
else
    REAL_CONF="/etc/named.conf"
fi

echo ""
echo "=== Исправление прав ==="

# 1. Права на директорию /var/named
echo "1. /var/named..."
chown named:named /var/named
chmod 770 /var/named
ls -la /var/named | head -3

# 2. Права на конфигурационный файл
echo ""
echo "2. Конфигурация ($REAL_CONF)..."
chown root:named "$REAL_CONF"
chmod 640 "$REAL_CONF"
ls -la "$REAL_CONF"

# 3. Права на поддиректории
echo ""
echo "3. Поддиректории..."
chown -R named:named /var/named/data 2>/dev/null
chown -R named:named /var/named/slaves 2>/dev/null
chown -R named:named /var/named/dynamic 2>/dev/null
chmod 770 /var/named/data 2>/dev/null

# 4. Права на файлы зон
echo ""
echo "4. Файлы зон..."
chown named:named /var/named/*.zone 2>/dev/null
chown named:named /var/named/*.rev 2>/dev/null
chmod 660 /var/named/*.zone 2>/dev/null
chmod 660 /var/named/*.rev 2>/dev/null

# 5. Если есть директория /etc/bind
if [ -d /etc/bind ]; then
    echo ""
    echo "5. /etc/bind..."
    chown root:named /etc/bind
    chmod 750 /etc/bind
fi

echo ""
echo "=== Проверка конфигурации ==="
named-checkconf 2>&1 | head -5

echo ""
echo "=== Запуск named ==="
pkill -9 named 2>/dev/null
sleep 1

# Запуск
/usr/sbin/named -u named 2>&1 &
sleep 2

if pgrep -x named >/dev/null; then
    echo ""
    echo "✓✓✓ named ЗАПУЩЕН! ✓✓✓"
    pgrep -a named
    
    # Тест
    echo ""
    echo "=== Тест DNS ==="
    nslookup hq-rtr 127.0.0.1 2>&1 | head -8
else
    echo ""
    echo "✗ named не запустился"
    echo "Запустите с отладкой:"
    echo "  /usr/sbin/named -u named -g"
fi
