#!/bin/bash

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root."
   exit 1
fi

echo "=================================================="
echo "       Настройка динамической маршрутизации OSPF  "
echo "=================================================="
echo ""

# 1. Выбор роли маршрутизатора
echo "Выберите настраиваемый маршрутизатор:"
echo "1) HQ-RTR"
echo "2) BR-RTR"
read -p "Ваш выбор (1 или 2): " role_choice

# Инициализация переменных по умолчанию
case $role_choice in
    1)
        DEF_ROUTER_ID="1.1.1.1"
        # Сети через пробел для цикла
        DEF_NETWORKS=("10.0.0.0/30" "192.168.100.0/26" "192.168.200.0/28")
        HOST_NAME="HQ-RTR"
        ;;
    2)
        DEF_ROUTER_ID="2.2.2.2"
        DEF_NETWORKS=("10.0.0.0/30" "192.168.50.0/27")
        HOST_NAME="BR-RTR"
        ;;
    *)
        echo "Неверный выбор. Выход."
        exit 1
        ;;
esac

echo ""
echo "--- Настройка параметров OSPF для $HOST_NAME ---"
echo "(Нажмите ENTER для использования значения по умолчанию)"

# 2. Ввод Router ID
read -p "OSPF Router ID [$DEF_ROUTER_ID]: " router_id
router_id=${router_id:-$DEF_ROUTER_ID}

# 3. Ввод сетей для анонсирования
echo ""
echo "Настройка сетей (network area 0)."
echo "Значения по умолчанию для $HOST_NAME: ${DEF_NETWORKS[*]}"
read -p "Введите сети через пробел (или нажмите Enter для default): " user_nets

if [[ -z "$user_nets" ]]; then
    # Если пользователь нажал Enter, используем массив по умолчанию
    NETWORKS=("${DEF_NETWORKS[@]}")
else
    # Иначе парсим ввод пользователя в массив
    NETWORKS=($user_nets)
fi

# 4. Ввод пароля аутентификации
DEF_PASS="P@ssw0rd"
read -p "Пароль аутентификации OSPF (area 0) [$DEF_PASS]: " ospf_pass
ospf_pass=${ospf_pass:-$DEF_PASS}

# Имя туннельного интерфейса
DEF_IFACE="gre0"
read -p "Имя туннельного интерфейса [$DEF_IFACE]: " tun_iface
tun_iface=${tun_iface:-$DEF_IFACE}

echo ""
echo "Проверка введенных данных:"
echo "------------------------------------------------"
echo "Router ID:      $router_id"
echo "Сети OSPF:      ${NETWORKS[*]}"
echo "Интерфейс:      $tun_iface"
echo "Пароль:         $ospf_pass"
echo "------------------------------------------------"
read -p "Все верно? Продолжить установку и настройку? (y/n): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Отмена операции."
    exit 0
fi

# --- Начало установки и настройки ---

echo ""
echo "[1/5] Установка пакета FRR..."
apt-get update
apt-get install -y frr

echo ""
echo "[2/5] Включение демона OSPFd..."
# Заменяем ospfd=no на ospfd=yes
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
# Если строчки не было или она была закомментирована, добавляем/правим для надежности
if ! grep -q "^ospfd=yes" /etc/frr/daemons; then
    echo "ospfd=yes" >> /etc/frr/daemons
fi
echo "-> Демон ospfd включен."

echo ""
echo "[3/5] Генерация конфигурации /etc/frr/frr.conf..."

# Создаем резервную копию
cp /etc/frr/frr.conf /etc/frr/frr.conf.bak

# Формируем блок конфигурации
# Используем временную переменную для накопления строк сетей
NET_CONF=""
for net in "${NETWORKS[@]}"; do
    NET_CONF+=" network $net area 0\n"
done

# Записываем конфигурацию в файл.
# Внимание: FRR конфиг специфичен. Мы добавляем настройки в конец файла.
# В реальном FRR конфиге могут быть строки 'frr version ...', 'hostname ...' и т.д.
# Мы просто дописываем нужные секции.

cat <<EOF >> /etc/frr/frr.conf

!
router ospf
 ospf router-id $router_id
 $(echo -e "$NET_CONF")
 passive-interface default
 no passive-interface $tun_iface
 area 0 authentication
!
interface $tun_iface
 ip ospf authentication-key $ospf_pass
!
EOF

echo "-> Конфигурация OSPF добавлена."

echo ""
echo "[4/5] Запуск службы FRR..."
systemctl enable --now frr
systemctl restart frr
echo "-> Служба перезапущена."

echo ""
echo "[5/5] Проверка состояния OSPF..."
echo "Соседи OSPF:"
vtysh -c "show ip ospf neighbor"

echo ""
echo "Маршруты OSPF:"
vtysh -c "show ip route ospf"

echo ""
echo "Настройка завершена. Не забудьте выполнить аналогичную настройку на втором маршрутизаторе."
