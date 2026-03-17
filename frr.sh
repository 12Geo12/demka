#!/bin/bash

#==============================================================================
# Скрипт для настройки OSPF на GRE туннеле
# Для ALT Linux
# Версия: 2.1
#==============================================================================

# Файл отчета
REPORT_FILE="/root/ospf_setup_report_$(date +%Y%m%d_%H%M%S).txt"

# Начало отчета
{
    echo "============================================="
    echo "ОТЧЕТ ПО НАСТРОЙКЕ OSPF НА GRE ТУННЕЛЕ"
    echo "============================================="
    echo "Дата: $(date)"
    echo "Хост: $(hostname)"
    echo "============================================="
    echo ""
} > "$REPORT_FILE"

# Функция для вывода и записи в отчет
log() {
    echo "$1"
    echo "$1" >> "$REPORT_FILE"
}

# Функция для вывода команды и её результата
run_cmd() {
    local cmd="$1"
    log ""
    log "ВЫПОЛНЯЕТСЯ: $cmd"
    log "----------------------------------------"
    eval "$cmd" 2>&1 | tee -a "$REPORT_FILE"
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -ne 0 ]; then
        log "КОМАНДА ЗАВЕРШИЛАСЬ С ОШИБКОЙ (код: $exit_code)"
    else
        log "КОМАНДА ВЫПОЛНЕНА УСПЕШНО"
    fi
    return $exit_code
}

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    log "ОШИБКА: Скрипт должен быть запущен от root"
    exit 1
fi

log ""
log "============================================="
log "ШАГ 1: Определение сетевых параметров"
log "============================================="
log ""

# Показываем все сетевые интерфейсы
log "Доступные сетевые интерфейсы:"
ip link show 2>&1 | tee -a "$REPORT_FILE"
log ""

# Показываем все IP адреса
log "Все IP адреса в системе:"
ip -4 addr show 2>&1 | tee -a "$REPORT_FILE"
log ""

# Получаем основной IP адрес
MAIN_IP=""
MAIN_IFACE=""

# Пробуем разные интерфейсы
for iface in ens33 ens192 eth0 enp0s3 enp1s0 ens3 ens4 eth1; do
    if ip link show "$iface" &>/dev/null; then
        IP_ADDR=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
        if [ -n "$IP_ADDR" ]; then
            MAIN_IP="$IP_ADDR"
            MAIN_IFACE="$iface"
            break
        fi
    fi
done

# Если не нашли, берём первый ненулевой
if [ -z "$MAIN_IP" ]; then
    MAIN_IP=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d'/' -f1 | head -1)
    MAIN_IFACE=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $NF}' | head -1)
fi

if [ -z "$MAIN_IP" ]; then
    log "ОШИБКА: Не удалось определить основной IP адрес"
    log "Введите IP адрес вручную: "
    read -r MAIN_IP
    log "Введите имя интерфейса: "
    read -r MAIN_IFACE
fi

log "Основной IP адрес: $MAIN_IP"
log "Интерфейс: $MAIN_IFACE"
log ""

# Определяем роль роутера
log "Определение роли роутера по IP адресу..."

if echo "$MAIN_IP" | grep -q "^172\.16\.4\."; then
    ROLE="HQ-RTR"
    ROUTER_ID="172.16.1.1"
    log "Определена роль: HQ-RTR (Главный офис)"
    log "Router ID: $ROUTER_ID"
elif echo "$MAIN_IP" | grep -q "^172\.16\.5\."; then
    ROLE="BR-RTR"
    ROUTER_ID="172.16.2.1"
    log "Определена роль: BR-RTR (Филиал)"
    log "Router ID: $ROUTER_ID"
else
    log "Не удалось автоматически определить роль роутера"
    log "IP адрес $MAIN_IP не соответствует ожидаемым подсетям (172.16.4.x или 172.16.5.x)"
    log ""
    log "Выберите роль:"
    log "  1) HQ-RTR - Главный офис (Router ID: 172.16.1.1)"
    log "  2) BR-RTR - Филиал (Router ID: 172.16.2.1)"
    log ""
    read -p "Введите номер (1 или 2): " role_choice
    
    case "$role_choice" in
        1)
            ROLE="HQ-RTR"
            ROUTER_ID="172.16.1.1"
            ;;
        2)
            ROLE="BR-RTR"
            ROUTER_ID="172.16.2.1"
            ;;
        *)
            log "ОШИБКА: Неверный выбор"
            exit 1
            ;;
    esac
    log "Выбрана роль: $ROLE"
    log "Router ID: $ROUTER_ID"
fi

log ""
log "============================================="
log "ШАГ 2: Проверка GRE туннеля"
log "============================================="
log ""

# Показываем все туннельные интерфейсы
log "Поиск туннельных интерфейсов..."
ip link show 2>&1 | grep -E "(gre|tun|tap)" | tee -a "$REPORT_FILE"
log ""

# Ищем gre1 или другой туннель
TUNNEL_IFACE=""
TUNNEL_IP=""

# Проверяем gre1
if ip link show gre1 &>/dev/null; then
    TUNNEL_IFACE="gre1"
    TUNNEL_IP=$(ip -4 addr show gre1 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
    log "Найден интерфейс gre1"
fi

# Если gre1 нет, проверяем другие
if [ -z "$TUNNEL_IFACE" ]; then
    for tiface in gre0 gre1 tun0 tun1 tap0; do
        if ip link show "$tiface" &>/dev/null; then
            IP_TMP=$(ip -4 addr show "$tiface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
            if [ -n "$IP_TMP" ]; then
                TUNNEL_IFACE="$tiface"
                TUNNEL_IP="$IP_TMP"
                log "Найден туннельный интерфейс: $TUNNEL_IFACE"
                break
            fi
        fi
    done
fi

# Показываем детали туннеля
if [ -n "$TUNNEL_IFACE" ]; then
    log ""
    log "Детали интерфейса $TUNNEL_IFACE:"
    ip addr show "$TUNNEL_IFACE" 2>&1 | tee -a "$REPORT_FILE"
    log ""
    log "Статистика интерфейса $TUNNEL_IFACE:"
    ip -s link show "$TUNNEL_IFACE" 2>&1 | tee -a "$REPORT_FILE"
fi

if [ -z "$TUNNEL_IFACE" ]; then
    log "ВНИМАНИЕ: Туннельный интерфейс не найден автоматически"
    log ""
    log "Список всех интерфейсов:"
    ip link show 2>&1 | awk '/^[0-9]/ {print "  " $2}' | tr -d ':' | tee -a "$REPORT_FILE"
    log ""
    read -p "Введите имя туннельного интерфейса: " TUNNEL_IFACE
    
    if ! ip link show "$TUNNEL_IFACE" &>/dev/null; then
        log "ОШИБКА: Интерфейс $TUNNEL_IFACE не существует"
        exit 1
    fi
    
    TUNNEL_IP=$(ip -4 addr show "$TUNNEL_IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
fi

if [ -z "$TUNNEL_IP" ]; then
    log "ВНИМАНИЕ: Не удалось определить IP адрес туннеля"
    read -p "Введите IP адрес туннеля (например 10.10.0.1): " TUNNEL_IP
fi

log ""
log "Интерфейс туннеля: $TUNNEL_IFACE"
log "IP адрес туннеля: $TUNNEL_IP"

log ""
log "============================================="
log "ШАГ 3: Определение сетей для анонсирования"
log "============================================="
log ""

# Показываем таблицу маршрутизации
log "Текущая таблица маршрутизации:"
ip route show 2>&1 | tee -a "$REPORT_FILE"
log ""

# Определяем сети на основе роли
declare -a NETWORKS

if [ "$ROLE" = "HQ-RTR" ]; then
    log "Поиск сетей главного офиса..."
    
    # Проверяем сети HQ-RTR
    if ip route show | grep -q "192.168.10.0"; then
        NETWORKS+=("192.168.10.0/26")
        log "Найдена сеть: 192.168.10.0/26 (HQ-LAN-1)"
    fi
    if ip route show | grep -q "192.168.20.0"; then
        NETWORKS+=("192.168.20.0/28")
        log "Найдена сеть: 192.168.20.0/28 (HQ-LAN-2)"
    fi
    if ip route show | grep -q "192.168.100.0"; then
        NETWORKS+=("192.168.100.0/24")
        log "Найдена сеть: 192.168.100.0/24 (HQ-MGMT)"
    fi
else
    log "Поиск сетей филиала..."
    
    # Проверяем сети BR-RTR
    if ip route show | grep -q "192.168.30.0"; then
        NETWORKS+=("192.168.30.0/27")
        log "Найдена сеть: 192.168.30.0/27 (BR-LAN)"
    fi
    if ip route show | grep -q "192.168.200.0"; then
        NETWORKS+=("192.168.200.0/24")
        log "Найдена сеть: 192.168.200.0/24 (BR-MGMT)"
    fi
fi

# Добавляем сеть туннеля
NETWORKS+=("10.10.0.0/30")
log "Добавлена сеть туннеля: 10.10.0.0/30"

log ""
log "Найденные сети для анонсирования:"
for net in "${NETWORKS[@]}"; do
    log "  - $net"
done

log ""
read -p "Хотите изменить список сетей? (y/n): " CHANGE_NETWORKS

if [ "$CHANGE_NETWORKS" = "y" ] || [ "$CHANGE_NETWORKS" = "Y" ]; then
    NETWORKS=()
    log "Введите сети для анонсирования (формат: 192.168.1.0/24)"
    log "Пустая строка для завершения ввода"
    log ""
    
    while true; do
        read -p "Сеть: " net
        if [ -z "$net" ]; then
            break
        fi
        NETWORKS+=("$net")
        log "Добавлена сеть: $net"
    done
fi

if [ ${#NETWORKS[@]} -eq 0 ]; then
    log "ОШИБКА: Список сетей пуст"
    exit 1
fi

log ""
log "Итоговый список сетей для анонсирования:"
for net in "${NETWORKS[@]}"; do
    log "  - $net"
done

log ""
log "============================================="
log "ШАГ 4: Настройка пароля OSPF"
log "============================================="
log ""

read -s -p "Введите пароль для аутентификации OSPF: " OSPF_PASSWORD
echo ""
read -s -p "Подтвердите пароль: " OSPF_PASSWORD_CONFIRM
echo ""

if [ "$OSPF_PASSWORD" != "$OSPF_PASSWORD_CONFIRM" ]; then
    log "ОШИБКА: Пароли не совпадают"
    read -s -p "Введите пароль ещё раз: " OSPF_PASSWORD
    echo ""
    read -s -p "Подтвердите пароль: " OSPF_PASSWORD_CONFIRM
    echo ""
    
    if [ "$OSPF_PASSWORD" != "$OSPF_PASSWORD_CONFIRM" ]; then
        log "ОШИБКА: Пароли снова не совпадают. Используется пароль по умолчанию P@ssw0rd"
        OSPF_PASSWORD="P@ssw0rd"
    fi
fi

if [ -z "$OSPF_PASSWORD" ]; then
    log "ВНИМАНИЕ: Пароль пустой. Используется пароль по умолчанию P@ssw0rd"
    OSPF_PASSWORD="P@ssw0rd"
fi

log "Пароль OSPF установлен"

log ""
log "============================================="
log "ШАГ 5: Установка FRR"
log "============================================="
log ""

# Проверяем наличие FRR
if command -v vtysh &>/dev/null; then
    log "FRR уже установлен"
    log "Версия FRR:"
    vtysh --version 2>&1 | tee -a "$REPORT_FILE"
else
    log "FRR не установлен. Начинаю установку..."
    
    # Определяем дистрибутив
    if [ -f /etc/altlinux-release ]; then
        DISTRO="altlinux"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
    else
        DISTRO="unknown"
    fi
    
    log "Определен дистрибутив: $DISTRO"
    
    # Установка в зависимости от дистрибутива
    case "$DISTRO" in
        altlinux)
            run_cmd "apt-get update"
            run_cmd "apt-get install -y frr"
            ;;
        debian)
            run_cmd "apt-get update"
            run_cmd "apt-get install -y frr"
            ;;
        rhel)
            run_cmd "yum install -y frr"
            ;;
        *)
            log "Неизвестный дистрибутив, пробуем apt-get"
            run_cmd "apt-get update"
            run_cmd "apt-get install -y frr"
            ;;
    esac
    
    if ! command -v vtysh &>/dev/null; then
        log "ОШИБКА: Не удалось установить FRR"
        exit 1
    fi
    
    log "FRR успешно установлен"
fi

log ""
log "============================================="
log "ШАГ 6: Настройка демонов FRR"
log "============================================="
log ""

# Поиск файла daemons
DAEMONS_FILE=""
for f in /etc/frr/daemons /usr/local/etc/frr/daemons /etc/frr/daemons.conf; do
    if [ -f "$f" ]; then
        DAEMONS_FILE="$f"
        break
    fi
done

if [ -z "$DAEMONS_FILE" ]; then
    log "ОШИБКА: Файл конфигурации демонов FRR не найден"
    log "Ищем в системе:"
    find /etc -name "daemons" 2>/dev/null | tee -a "$REPORT_FILE"
    find /usr -name "daemons" 2>/dev/null | tee -a "$REPORT_FILE"
    exit 1
fi

log "Найден файл демонов: $DAEMONS_FILE"

# Показываем текущее содержимое
log ""
log "Текущее содержимое $DAEMONS_FILE (строки с ospfd и zebra):"
grep -E "^(ospfd|zebra|#ospfd|#zebra)=" "$DAEMONS_FILE" 2>&1 | tee -a "$REPORT_FILE"
log ""

# Резервное копирование
BACKUP_FILE="${DAEMONS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$DAEMONS_FILE" "$BACKUP_FILE"
log "Создана резервная копия: $BACKUP_FILE"

# Включаем zebra (если выключен)
if grep -q "^zebra=no" "$DAEMONS_FILE"; then
    sed -i 's/^zebra=no/zebra=yes/' "$DAEMONS_FILE"
    log "Включен zebra"
elif grep -q "^#zebra=no" "$DAEMONS_FILE"; then
    sed -i 's/^#zebra=no/zebra=yes/' "$DAEMONS_FILE"
    log "Включен zebra"
fi

# Включаем ospfd
if grep -q "^ospfd=no" "$DAEMONS_FILE"; then
    sed -i 's/^ospfd=no/ospfd=yes/' "$DAEMONS_FILE"
    log "Включен ospfd"
elif grep -q "^#ospfd=no" "$DAEMONS_FILE"; then
    sed -i 's/^#ospfd=no/ospfd=yes/' "$DAEMONS_FILE"
    log "Включен ospfd"
elif grep -q "^ospfd=yes" "$DAEMONS_FILE"; then
    log "ospfd уже включен"
else
    echo "ospfd=yes" >> "$DAEMONS_FILE"
    log "Добавлена строка ospfd=yes"
fi

# Показываем измененное содержимое
log ""
log "Содержимое $DAEMONS_FILE после изменений (строки с ospfd и zebra):"
grep -E "^(ospfd|zebra)=" "$DAEMONS_FILE" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "============================================="
log "ШАГ 7: Запуск сервиса FRR"
log "============================================="
log ""

# Проверяем статус сервиса
log "Проверка сервиса FRR..."
systemctl status frr 2>&1 | head -5 | tee -a "$REPORT_FILE"

log ""
log "Включение и перезапуск сервиса FRR..."
systemctl enable frr 2>&1 | tee -a "$REPORT_FILE"
systemctl restart frr 2>&1 | tee -a "$REPORT_FILE"

sleep 3

log ""
log "Статус сервиса FRR после перезапуска:"
systemctl status frr 2>&1 | tee -a "$REPORT_FILE"

if ! systemctl is-active --quiet frr; then
    log "ВНИМАНИЕ: Сервис frr не активен"
    log "Пробуем альтернативные имена..."
    
    for svc in frr.service frr-routing quagga; do
        if systemctl list-unit-files | grep -q "$svc"; then
            log "Найден сервис: $svc"
            systemctl enable "$svc" 2>&1 | tee -a "$REPORT_FILE"
            systemctl restart "$svc" 2>&1 | tee -a "$REPORT_FILE"
            sleep 3
            if systemctl is-active --quiet "$svc"; then
                log "Сервис $svc успешно запущен"
                break
            fi
        fi
    done
fi

log ""
log "============================================="
log "ШАГ 8: Применение конфигурации OSPF"
log "============================================="
log ""

# Формируем команды vtysh
log "Формирование конфигурации OSPF..."
log ""

VTYSH_CMDS=$(mktemp)

{
    echo "configure terminal"
    echo " router ospf"
    echo "  ospf router-id $ROUTER_ID"
    
    for net in "${NETWORKS[@]}"; do
        echo "  network $net area 0"
    done
    
    echo "  area 0 authentication"
    echo " exit"
    echo " interface $TUNNEL_IFACE"
    echo "  ip ospf authentication"
    echo "  ip ospf authentication-key $OSPF_PASSWORD"
    echo "  no ip ospf passive"
    echo "  ip ospf network broadcast"
    echo " exit"
    echo " end"
    echo " write memory"
} > "$VTYSH_CMDS"

log "Команды для выполнения:"
log "----------------------------------------"
cat "$VTYSH_CMDS" | tee -a "$REPORT_FILE"
log "----------------------------------------"

log ""
log "Применение конфигурации через vtysh..."
vtysh -f "$VTYSH_CMDS" 2>&1 | tee -a "$REPORT_FILE"
VTYSH_RESULT=$?

rm -f "$VTYSH_CMDS"

if [ $VTYSH_RESULT -ne 0 ]; then
    log "ОШИБКА: Не удалось применить конфигурацию OSPF"
else
    log "Конфигурация OSPF успешно применена"
fi

log ""
log "============================================="
log "ШАГ 9: Проверка конфигурации"
log "============================================="
log ""

log "Полная конфигурация FRR (router ospf):"
log "----------------------------------------"
vtysh -c "show running-config" 2>&1 | grep -A100 "router ospf" | head -50 | tee -a "$REPORT_FILE"

log ""
log "Конфигурация интерфейса $TUNNEL_IFACE:"
log "----------------------------------------"
vtysh -c "show running-config" 2>&1 | grep -A20 "interface $TUNNEL_IFACE" | tee -a "$REPORT_FILE"

log ""
log "Информация об интерфейсах OSPF:"
log "----------------------------------------"
vtysh -c "show ip ospf interface" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "Общая информация OSPF:"
log "----------------------------------------"
vtysh -c "show ip ospf" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "============================================="
log "ШАГ 10: Проверка соседей OSPF"
log "============================================="
log ""

log "Ожидание установки соседства (20 секунд)..."
for i in $(seq 20 -1 1); do
    printf "\rОсталось: %2d сек... " "$i"
    sleep 1
done
echo ""
log ""

log "Список соседей OSPF:"
log "----------------------------------------"
vtysh -c "show ip ospf neighbor" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "Детальная информация о соседях:"
log "----------------------------------------"
vtysh -c "show ip ospf neighbor detail" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "============================================="
log "ШАГ 11: Проверка маршрутов OSPF"
log "============================================="
log ""

log "Маршруты OSPF:"
log "----------------------------------------"
vtysh -c "show ip route ospf" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "Полная таблица маршрутизации:"
log "----------------------------------------"
vtysh -c "show ip route" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "База данных OSPF:"
log "----------------------------------------"
vtysh -c "show ip ospf database" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "============================================="
log "ШАГ 12: Проверка связанности"
log "============================================="
log ""

# Определяем IP для проверки связи
if [ "$ROLE" = "HQ-RTR" ]; then
    TEST_IP="192.168.30.1"
else
    TEST_IP="192.168.10.1"
fi

log "Проверка связи с удаленной сетью ($TEST_IP):"
log "----------------------------------------"
ping -c 3 "$TEST_IP" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "Проверка связи через туннель:"
log "----------------------------------------"
# Получаем удаленный IP туннеля
if [ "$TUNNEL_IP" = "10.10.0.1" ]; then
    REMOTE_TUNNEL="10.10.0.2"
elif [ "$TUNNEL_IP" = "10.10.0.2" ]; then
    REMOTE_TUNNEL="10.10.0.1"
else
    REMOTE_TUNNEL="10.10.0.2"
fi

ping -c 3 "$REMOTE_TUNNEL" 2>&1 | tee -a "$REPORT_FILE"

log ""
log "============================================="
log "ЗАВЕРШЕНИЕ НАСТРОЙКИ"
log "============================================="
log ""

log "Итоговая конфигурация:"
log "  Роль роутера: $ROLE"
log "  Router ID: $ROUTER_ID"
log "  Основной интерфейс: $MAIN_IFACE ($MAIN_IP)"
log "  Интерфейс туннеля: $TUNNEL_IFACE ($TUNNEL_IP)"
log "  Количество сетей для анонсирования: ${#NETWORKS[@]}"
log ""

log "Сети для анонсирования:"
for net in "${NETWORKS[@]}"; do
    log "  - $net"
done
log ""

log "Отчет сохранен в: $REPORT_FILE"
log ""

log "Полезные команды для проверки:"
log "  vtysh -c 'show ip ospf neighbor'       - показать соседей OSPF"
log "  vtysh -c 'show ip ospf neighbor detail' - детальная информация о соседях"
log "  vtysh -c 'show ip route ospf'          - показать маршруты OSPF"
log "  vtysh -c 'show ip ospf interface'      - показать интерфейсы OSPF"
log "  vtysh -c 'show ip ospf database'       - показать базу данных OSPF"
log "  vtysh -c 'show running-config'         - показать полную конфигурацию"
log "  vtysh -c 'show logging'                - показать логи FRR"
log "  journalctl -u frr -f                   - логи сервиса FRR"
log ""

# Запрос на сохранение пароля
read -p "Сохранить пароль в отдельный файл? (y/n): " SAVE_PASSWORD

if [ "$SAVE_PASSWORD" = "y" ] || [ "$SAVE_PASSWORD" = "Y" ]; then
    PASSWORD_FILE="/root/ospf_password_$(date +%Y%m%d).txt"
    {
        echo "============================================="
        echo "Пароль OSPF"
        echo "============================================="
        echo "Хост: $(hostname)"
        echo "Дата создания: $(date)"
        echo "Роль: $ROLE"
        echo "Router ID: $ROUTER_ID"
        echo "Пароль: $OSPF_PASSWORD"
        echo "============================================="
    } > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log "Пароль сохранен в: $PASSWORD_FILE"
fi

log ""
log "Для просмотра полного отчета: cat $REPORT_FILE"
log ""

exit 0
