#!/bin/bash

# ==================================================
# Скрипт автоматической настройки Open vSwitch (OVS)
# для маршрутизатора HQ-RTR в рамках проекта Demo2026
# Основан на руководстве и материалах:
# https://github.com/stepanovs2005/Demo2026
# Версия: 1.0
# ==================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для красивого вывода
info() { echo -e "${BLUE}[ИНФО]${NC} $1"; }
success() { echo -e "${GREEN}[УСПЕХ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1"; }

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   error "Этот скрипт должен запускаться от root (или через sudo)."
   exit 1
fi

# Приветствие
clear
info "=========================================================="
info " Добро пожаловать в скрипт настройки Open vSwitch (OVS)  "
info "            для маршрутизатора HQ-RTR                     "
info "=========================================================="
echo ""

# --- Шаг 1: Обнаружение сетевых интерфейсов ---
info "Поиск доступных сетевых интерфейсов..."
# Получаем список всех интерфейсов, исключая loopback (lo), виртуальные (veth*, docker*) и уже существующие OVS-порты (ovs-system)
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v veth | grep -v docker | grep -v ovs-system | grep -v ^br- | grep -v ^tap)
if [ -z "$interfaces" ]; then
    error "Не найдено ни одного физического сетевого интерфейса для настройки."
    exit 1
fi

echo "Доступные интерфейсы:"
select interface in $interfaces; do
    if [ -n "$interface" ]; then
        PHY_IFACE=$interface
        success "Выбран интерфейс: $PHY_IFACE"
        break
    else
        error "Неверный выбор. Пожалуйста, выберите номер из списка."
    fi
done
echo ""

# --- Шаг 2: Получение информации о VLAN от пользователя ---
info "Теперь давайте настроим VLANы."
info "В задании используются ID 100, 200, 999, но вы можете задать свои."
info "Скрипт запросит данные для каждого VLAN."
echo ""

# Инициализируем массивы для хранения конфигурации VLAN
declare -a VLAN_IDS
declare -a VLAN_IPS
declare -a VLAN_NAMES

while true; do
    read -p "Введите ID VLAN (например, 100) или 'stop' для завершения: " vlan_id
    if [[ "$vlan_id" == "stop" ]]; then
        break
    fi
    if [[ ! "$vlan_id" =~ ^[0-9]+$ ]] || [ "$vlan_id" -lt 1 ] || [ "$vlan_id" -gt 4095 ]; then
        error "Некорректный VLAN ID. Должен быть числом от 1 до 4095."
        continue
    fi

    # Проверка на уникальность ID
    if [[ " ${VLAN_IDS[@]} " =~ " ${vlan_id} " ]]; then
        error "VLAN ID $vlan_id уже добавлен. Введите другой ID."
        continue
    fi

    read -p "Введите IP-адрес с маской для шлюза в этом VLAN (например, 192.168.10.1/26): " vlan_ip
    # Простейшая проверка формата IP/маска (можно усложнить)
    if [[ ! "$vlan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        error "Некорректный формат IP/маски. Используйте формат xxx.xxx.xxx.xxx/xx"
        continue
    fi

    read -p "Введите понятное имя для этого VLAN (например, hq-srv или management): " vlan_name
    if [ -z "$vlan_name" ]; then
        vlan_name="vlan$vlan_id"
        warn "Имя не введено, будет использовано: $vlan_name"
    fi

    # Добавляем в массивы
    VLAN_IDS+=("$vlan_id")
    VLAN_IPS+=("$vlan_ip")
    VLAN_NAMES+=("$vlan_name")
    success "VLAN $vlan_id ($vlan_name) добавлен для настройки."
    echo ""
done

if [ ${#VLAN_IDS[@]} -eq 0 ]; then
    error "Не добавлено ни одного VLAN. Скрипт завершает работу."
    exit 1
fi

# --- Шаг 3: Показываем план настройки и запрашиваем подтверждение ---
clear
info "=========================================================="
info "                         ПЛАН НАСТРОЙКИ                   "
info "=========================================================="
echo "Физический интерфейс: $PHY_IFACE"
echo "Будет создан мост Open vSwitch с именем: ${GREEN}ovs-br0${NC}"
echo "На мост будут добавлены следующие внутренние порты (VLAN):"
for i in "${!VLAN_IDS[@]}"; do
    vlan_iface="vlan${VLAN_IDS[$i]}"
    echo "  - Порт: ${BLUE}$vlan_iface${NC} (${VLAN_NAMES[$i]})"
    echo "    VLAN ID: ${VLAN_IDS[$i]}, IP-адрес шлюза: ${VLAN_IPS[$i]}"
done
echo ""
echo "Будет включена маршрутизация (net.ipv4.ip_forward = 1)."
echo "Будут настроены правила iptables для NAT (маскарадинга) этих сетей через внешний интерфейс (ens192)."
echo ""
warn "ВНИМАНИЕ! Это действие изменит сетевую конфигурацию системы."
warn "Текущее сетевое соединение может быть потеряно."
read -p "Вы уверены, что хотите продолжить? (yes/no): " confirmation

if [[ "$confirmation" != "yes" ]]; then
    info "Настройка отменена пользователем. Выход."
    exit 0
fi

# --- Шаг 4: Установка Open vSwitch, если не установлен ---
info "Проверка и установка Open vSwitch..."
if ! command -v ovs-vsctl &> /dev/null; then
    warn "Open vSwitch не найден. Устанавливаем..."
    apt-get update && apt-get install openvswitch-switch -y
    if [ $? -ne 0 ]; then
        error "Не удалось установить Open vSwitch. Проверьте подключение к интернету и повторите попытку."
        exit 1
    fi
    success "Open vSwitch установлен."
else
    success "Open vSwitch уже установлен."
fi

# Включаем и запускаем сервис
systemctl enable --now openvswitch-switch.service
if systemctl is-active --quiet openvswitch-switch.service; then
    success "Сервис Open vSwitch запущен."
else
    error "Не удалось запустить сервис Open vSwitch. Попробуйте перезагрузить систему."
    exit 1
fi

# --- Шаг 5: Создание моста и настройка VLAN ---
info "Создание моста Open vSwitch 'ovs-br0' и добавление физического интерфейса '$PHY_IFACE'..."
ovs-vsctl --may-exist add-br ovs-br0
if [ $? -ne 0 ]; then error "Не удалось создать мост."; exit 1; fi

ovs-vsctl --may-exist add-port ovs-br0 $PHY_IFACE
if [ $? -ne 0 ]; then error "Не удалось добавить порт $PHY_IFACE."; exit 1; fi
success "Физический интерфейс $PHY_IFACE добавлен как trunk-порт."

info "Создание внутренних портов для VLAN..."
for i in "${!VLAN_IDS[@]}"; do
    vlan_id="${VLAN_IDS[$i]}"
    vlan_ip="${VLAN_IPS[$i]}"
    port_name="vlan${vlan_id}"

    # Добавляем внутренний порт с тегом VLAN
    ovs-vsctl --may-exist add-port ovs-br0 $port_name tag=$vlan_id -- set Interface $port_name type=internal
    if [ $? -ne 0 ]; then
        error "Не удалось создать порт $port_name."
        continue
    fi

    # Назначаем IP-адрес на порт и поднимаем его
    ifconfig $port_name $vlan_ip up
    if [ $? -eq 0 ]; then
        success "Порт ${BLUE}$port_name${NC} (VLAN $vlan_id) настроен с IP ${GREEN}$vlan_ip${NC}"
    else
        error "Не удалось назначить IP на порт $port_name."
    fi
done

# Проверка результата
ovs-vsctl show
success "Мост Open vSwitch настроен."

# --- Шаг 6: Включение маршрутизации и настройка NAT ---
info "Включение пересылки пакетов (IP forwarding)..."
# Устанавливаем параметр ядра
sysctl -w net.ipv4.ip_forward=1
# Делаем изменение постоянным
if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    info "Параметр net.ipv4.ip_forward уже настроен в /etc/sysctl.conf."
else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    success "Параметр net.ipv4.ip_forward добавлен в /etc/sysctl.conf."
fi

info "Настройка правил NAT (маскарадинга) для созданных сетей через внешний интерфейс 'ens192'..."
# Проверяем, существует ли интерфейс ens192
if ! ip link show ens192 &> /dev/null; then
    warn "Интерфейс ens192 не найден. Правила NAT не будут добавлены автоматически."
    warn "Вам нужно будет настроить NAT вручную, заменив 'ens192' на ваш внешний интерфейс."
else
    for i in "${!VLAN_IPS[@]}"; do
        vlan_ip="${VLAN_IPS[$i]}"
        # Извлекаем сеть из IP/маски. Это простое извлечение, для сложных случаев используйте ipcalc
        network=$(ipcalc -n "$vlan_ip" | grep Network: | awk '{print $2}')
        if [ -z "$network" ]; then
            warn "Не удалось вычислить сеть для $vlan_ip. Пропускаем NAT для этого VLAN."
            continue
        fi

        iptables -t nat -A POSTROUTING -o ens192 -s $network -j MASQUERADE
        if [ $? -eq 0 ]; then
            success "Добавлено правило NAT для сети $network через ens192."
        else
            error "Не удалось добавить правило NAT для сети $network."
        fi
    done

    # Сохраняем правила iptables
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    success "Правила iptables сохранены в /etc/sysconfig/iptables"

    # Включаем сервис для автозагрузки (на разных ОС может называться по-разному)
    if systemctl list-unit-files | grep -q iptables.service; then
        systemctl enable iptables.service
        success "Сервис iptables добавлен в автозагрузку."
    fi
fi

# --- Шаг 7: Заключение и следующие шаги ---
echo ""
success "=========================================================="
success " Базовая настройка Open vSwitch на HQ-RTR завершена!"
success "=========================================================="
echo ""
info "Теперь необходимо настроить конечные устройства:"
info "  1. На HQ-SRV создайте VLAN-интерфейс для VLAN 100:"
info "     mkdir /etc/net/ifaces/ens192.100"
info "     (и настройте options, ipv4address согласно вашему заданию)"
info "  2. На HQ-CLI создайте VLAN-интерфейс для VLAN 200 (и, если нужно, для 999)."
info "  3. Не забудьте настроить SSH, DHCP и DNS согласно инструкции."
echo ""
info "Состояние моста можно проверить командой: ${YELLOW}ovs-vsctl show${NC}"
info "Состояние портов: ${YELLOW}ovs-ofctl dump-ports ovs-br0${NC}"
info "Состояние сетевых интерфейсов: ${YELLOW}ip a${NC}"
echo ""
