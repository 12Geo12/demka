#!/bin/bash

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root."
   exit 1
fi

echo "=================================================="
echo "       Настройка GRE-туннеля (Interactive)        "
echo "=================================================="
echo ""

# 1. Выбор роли маршрутизатора
echo "Выберите настраиваемый маршрутизатор:"
echo "1) HQ-RTR"
echo "2) BR-RTR"
read -p "Ваш выбор (1 или 2): " role_choice

# Установка значений по умолчанию в зависимости от выбора
case $role_choice in
    1)
        def_local_wan="172.16.4.2"
        def_remote_wan="172.16.5.2"
        def_local_tun="10.0.0.1/30"
        def_remote_tun="10.0.0.2"
        host_name="HQ-RTR"
        ;;
    2)
        def_local_wan="172.16.5.2"
        def_remote_wan="172.16.4.2"
        def_local_tun="10.0.0.2/30"
        def_remote_tun="10.0.0.1"
        host_name="BR-RTR"
        ;;
    *)
        echo "Неверный выбор. Выход."
        exit 1
        ;;
esac

echo ""
echo "--- Ввод параметров для $host_name ---"
echo "(Нажмите ENTER, чтобы использовать значение по умолчанию в скобках)"

# 2. Ввод внешних адресов (WAN)
read -p "Локальный внешний IP (LOCALADDR) [$def_local_wan]: " local_wan
local_wan=${local_wan:-$def_local_wan}

read -p "Удаленный внешний IP (REMOTEADDR) [$def_remote_wan]: " remote_wan
remote_wan=${remote_wan:-$def_remote_wan}

# 3. Ввод адресов туннеля
echo ""
echo "Настройка адресации внутри туннеля:"

read -p "Локальный адрес туннеля (CIDR) [$def_local_tun]: " local_tun
local_tun=${local_tun:-$def_local_tun}

# Для пинга спрашиваем адрес соседа (удаленный конец туннеля)
# Извлекаем подсеть из введенного адреса, если нужно, или просто спрашиваем
read -p "Адрес туннеля удаленного шлюза (для проверки пинга) [$def_remote_tun]: " remote_tun
remote_tun=${remote_tun:-$def_remote_tun}

echo ""
echo "Проверка введенных данных:"
echo "------------------------------------------------"
echo "Роль:            $host_name"
echo "Внешний IP:      $local_wan (локальный) <-> $remote_wan (удаленный)"
echo "Туннельный IP:   $local_tun (локальный) <-> $remote_tun (удаленный)"
echo "------------------------------------------------"
read -p "Все верно? Продолжить? (y/n): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Отмена операции."
    exit 0
fi

# --- Начало конфигурации ---

IFACE_DIR="/etc/net/ifaces/gre0"

# 1. Загрузка модуля
echo ""
echo "[1/4] Загрузка модуля GRE..."
modprobe gre
if ! grep -q "^gre" /etc/modules; then
    echo "gre" >> /etc/modules
    echo "-> Модуль gre добавлен в /etc/modules."
else
    echo "-> Модуль gre уже есть в автозагрузке."
fi

# 2. Создание директории
echo "[2/4] Создание файлов конфигурации..."
mkdir -p "$IFACE_DIR"

# 3. Запись options
cat > "$IFACE_DIR/options" <<EOF
TYPE=gre
BOOTPROTO=static
REMOTEADDR=$remote_wan
LOCALADDR=$local_wan
TTL=64
EOF
echo "-> Файл options записан."

# 4. Запись ipv4address
echo "$local_tun" > "$IFACE_DIR/ipv4address"
echo "-> Файл ipv4address записан."

# 5. Применение
echo ""
echo "[3/4] Перезапуск сетевой службы..."
systemctl restart network

# 6. Проверка
echo ""
echo "[4/4] Проверка интерфейса gre0:"
ip a show gre0

echo ""
read -p "Выполнить пинг удаленного конца туннеля ($remote_tun)? (y/n): " ping_ask
if [[ "$ping_ask" =~ ^[Yy]$ ]]; then
    echo "Пингуем $remote_tun..."
    ping -c 4 $remote_tun
fi

echo ""
echo "Настройка завершена."
