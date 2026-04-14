#!/bin/bash

# Проверка на запуск от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (используйте sudo)."
  exit
fi

echo "=== Начало настройки экзаменационного задания ==="
echo ""

# --- 1. Настройка сети ---
echo "1. Настройка сетевого интерфейса."
echo "Введите настройки сети (как на рабочей станции):"
read -p "IP-адрес (например, 192.168.1.100): " IP_ADDR
read -p "Маска подсети (например, 24 или 255.255.255.0): " NETMASK
read -p "Шлюз (например, 192.168.1.1): " GATEWAY

# Определяем основной интерфейс (обычно eth0 или enp0s3)
INTERFACE=$(ip route | grep default | awk '{print $5}')

if [ -z "$INTERFACE" ]; then
    echo "Не удалось найти сетевой интерфейс. Проверьте настройки NAT в VMware."
    exit 1
fi

echo "Настройка интерфейса $INTERFACE..."
# Команды ifconfig для ALT Linux (если не установлено, можно использовать ip, но ifconfig часто бывает по умолчанию в простых задачах)
# Для надежности используем 'ip addr'
ip addr add $IP_ADDR/$NETMASK dev $INTERFACE
ip link set $INTERFACE up

# Настройка шлюза
ip route replace default via $GATEWAY

# Настройка DNS (чтобы работали блокировки и интернет
