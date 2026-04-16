# ... конец вашего скрипта ...

# Автозагрузка правил iptables для Альт
echo "Настройка автозагрузки правил firewall..."
if [ -f "/etc/net/ifaces/$IFACE/options" ]; then
    # Проверяем, есть ли уже строчка, чтобы не дублировать
    if ! grep -q "RESTORIPTABLES=yes" /etc/net/ifaces/$IFACE/options; then
        echo "RESTORIPTABLES=yes" >> /etc/net/ifaces/$IFACE/options
    fi
fi

echo "ГОТОВО."
