#!/bin/bash

# Скрипт для настройки OSPF на GRE туннеле
# С возможностью выбора пароля пользователем

# Файл отчета
REPORT_FILE="/root/ospf_setup_report_$(date +%Y%m%d_%H%M%S).txt"

# Начало отчета
echo "=============================================" > $REPORT_FILE
echo "ОТЧЕТ ПО НАСТРОЙКЕ OSPF" >> $REPORT_FILE
echo "Дата: $(date)" >> $REPORT_FILE
echo "Хост: $(hostname)" >> $REPORT_FILE
echo "=============================================" >> $REPORT_FILE
echo "" >> $REPORT_FILE

# Функция для вывода и записи в отчет
log() {
    echo "$1" | tee -a $REPORT_FILE
}

log "ШАГ 1: Определение сетевых параметров"
log "----------------------------------------"

# Получаем IP адрес интерфейса ens33 (или основного)
MAIN_IP=$(ip -4 addr show ens33 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -z "$MAIN_IP" ]; then
    MAIN_IP=$(ip -4 addr show | grep -v "127.0.0.1" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi
log "Основной IP адрес: $MAIN_IP"

# Определяем роль роутера
if [[ $MAIN_IP == 172.16.4.* ]]; then
    ROLE="HQ-RTR"
    ROUTER_ID="172.16.1.1"
    log "Роль роутера: HQ-RTR"
elif [[ $MAIN_IP == 172.16.5.* ]]; then
    ROLE="BR-RTR"
    ROUTER_ID="172.16.2.1"
    log "Роль роутера: BR-RTR"
else
    log "Не удалось определить роль роутера"
    echo "Введите роль роутера (HQ-RTR или BR-RTR): "
    read ROLE
    if [ "$ROLE" = "HQ-RTR" ]; then
        ROUTER_ID="172.16.1.1"
    else
        ROUTER_ID="172.16.2.1"
    fi
fi

log "Router ID: $ROUTER_ID"
log ""

# Получаем IP адрес туннеля
TUNNEL_IP=$(ip -4 addr show gre1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -z "$TUNNEL_IP" ]; then
    log "ВНИМАНИЕ: Интерфейс gre1 не найден"
    echo "Введите IP адрес туннеля gre1 (например 10.10.0.1 или 10.10.0.2): "
    read TUNNEL_IP
fi
log "IP адрес туннеля: $TUNNEL_IP"

# Определяем сети для анонсирования
log ""
log "ШАГ 2: Определение локальных сетей"
log "----------------------------------------"

declare -a NETWORKS=()

if [ "$ROLE" = "HQ-RTR" ]; then
    # Проверяем наличие сетей HQ-RTR
    if ip route | grep -q "192.168.10.0/26"; then
        NETWORKS+=("192.168.10.0/26")
        log "Найдена сеть: 192.168.10.0/26"
    fi
    if ip route | grep -q "192.168.20.0/28"; then
        NETWORKS+=("192.168.20.0/28")
        log "Найдена сеть: 192.168.20.0/28"
    fi
else
    # Проверяем наличие сетей BR-RTR
    if ip route | grep -q "192.168.30.0/27"; then
        NETWORKS+=("192.168.30.0/27")
        log "Найдена сеть: 192.168.30.0/27"
    fi
fi

# Добавляем сеть туннеля
TUNNEL_NETWORK="10.10.0.0/30"
NETWORKS+=("$TUNNEL_NETWORK")
log "Добавлена сеть туннеля: $TUNNEL_NETWORK"

# Спрашиваем подтверждение
log ""
echo "Найденные сети для анонсирования:"
for net in "${NETWORKS[@]}"; do
    echo "  - $net"
done

log ""
echo "Хотите изменить список сетей? (y/n): "
read CHANGE_NETWORKS

if [ "$CHANGE_NETWORKS" = "y" ]; then
    NETWORKS=()
    echo "Введите сети для анонсирования (по одной, пустая строка для завершения):"
    while true; do
        read NETWORK
        if [ -z "$NETWORK" ]; then
            break
        fi
        NETWORKS+=("$NETWORK")
    done
fi

log "Итоговый список сетей для анонсирования:"
for net in "${NETWORKS[@]}"; do
    log "  - $net"
done

log ""
log "ШАГ 3: Настройка парольной защиты OSPF"
log "----------------------------------------"

echo "Введите пароль для аутентификации OSPF: "
read -s OSPF_PASSWORD
echo "Подтвердите пароль: "
read -s OSPF_PASSWORD_CONFIRM

if [ "$OSPF_PASSWORD" != "$OSPF_PASSWORD_CONFIRM" ]; then
    log "ОШИБКА: Пароли не совпадают"
    echo "Пароли не совпадают. Повторите ввод:"
    echo "Введите пароль для аутентификации OSPF: "
    read -s OSPF_PASSWORD
    echo "Подтвердите пароль: "
    read -s OSPF_PASSWORD_CONFIRM
fi

if [ -z "$OSPF_PASSWORD" ]; then
    log "ВНИМАНИЕ: Пароль пустой. Используется пароль по умолчанию P@ssw0rd"
    OSPF_PASSWORD="P@ssw0rd"
fi

log "Пароль OSPF установлен (скрыт для безопасности)"

log ""
log "ШАГ 4: Установка и настройка FRR"
log "----------------------------------------"

# Установка FRR
log "Установка FRR..."
apt-get update >> $REPORT_FILE 2>&1
apt-get install frr -y >> $REPORT_FILE 2>&1
log "FRR установлен"

# Включение ospfd в daemons
log "Включение ospfd в /etc/frr/daemons"
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
sed -i 's/^#ospfd=no/ospfd=yes/' /etc/frr/daemons

# Проверка изменений
grep ospfd /etc/frr/daemons >> $REPORT_FILE

# Запуск FRR
log "Запуск FRR..."
systemctl enable frr >> $REPORT_FILE 2>&1
systemctl restart frr >> $REPORT_FILE 2>&1
log "FRR запущен"

# Небольшая пауза для инициализации
sleep 3

log ""
log "ШАГ 5: Настройка OSPF через vtysh"
log "----------------------------------------"

# Создаем временный файл с командами vtysh
VTYS_CMDS=$(mktemp)

# Формируем команды для vtysh
cat > $VTYS_CMDS << EOF
configure terminal
 router ospf
  ospf router-id $ROUTER_ID
EOF

# Добавляем сети
for net in "${NETWORKS[@]}"; do
    echo "  network $net area 0" >> $VTYS_CMDS
done

# Добавляем аутентификацию
cat >> $VTYS_CMDS << EOF
  area 0 authentication
 exit
 interface gre1
  ip ospf authentication-key $OSPF_PASSWORD
  ip ospf authentication
  no ip ospf passive
  ip ospf network broadcast
 exit
 end
 write memory
EOF

log "Применение конфигурации OSPF..."
vtysh < $VTYS_CMDS >> $REPORT_FILE 2>&1

# Удаляем временный файл
rm $VTYS_CMDS

log "Конфигурация OSPF применена"

log ""
log "ШАГ 6: Проверка конфигурации"
log "----------------------------------------"

# Получаем текущую конфигурацию FRR
log "Текущая конфигурация FRR:"
echo "" >> $REPORT_FILE
echo "--- КОНФИГУРАЦИЯ OSPF ---" >> $REPORT_FILE
vtysh -c "show running-config" | grep -A30 "router ospf" >> $REPORT_FILE
echo "" >> $REPORT_FILE
echo "--- КОНФИГУРАЦИЯ ИНТЕРФЕЙСА GRE1 ---" >> $REPORT_FILE
vtysh -c "show running-config" | grep -A10 "interface gre1" >> $REPORT_FILE

# Показываем пользователю (без пароля в открытом виде)
log ""
log "КОНФИГУРАЦИЯ OSPF:"
vtysh -c "show running-config" | grep -A30 "router ospf" | grep -v "authentication-key" | while read line; do log "  $line"; done
log ""
log "КОНФИГУРАЦИЯ ИНТЕРФЕЙСА GRE1:"
vtysh -c "show running-config" | grep -A10 "interface gre1" | grep -v "authentication-key" | while read line; do log "  $line"; done

log ""
log "ШАГ 7: Проверка соседей OSPF"
log "----------------------------------------"

# Ждем немного для установки соседства
log "Ожидание установки соседства (15 секунд)..."
sleep 15

# Проверяем соседей
log "Соседи OSPF:"
NEIGHBORS=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)
if [ -n "$NEIGHBORS" ]; then
    echo "$NEIGHBORS" >> $REPORT_FILE
    echo "$NEIGHBORS" | while read line; do 
        if [[ ! "$line" =~ "Dead Time" ]] && [[ ! -z "$line" ]]; then
            log "  $line"
        fi
    done
    
    # Проверяем статус
    if echo "$NEIGHBORS" | grep -q "Full"; then
        log "СТАТУС: Full/DR или Full/Backup установлен"
    else
        log "СТАТУС: Ожидание установки полного соседства"
    fi
else
    log "Нет соседей OSPF"
fi

log ""
log "ШАГ 8: Проверка маршрутов OSPF"
log "----------------------------------------"

# Проверяем маршруты OSPF
log "Маршруты OSPF:"
OSPF_ROUTES=$(vtysh -c "show ip route ospf" 2>/dev/null)
if [ -n "$OSPF_ROUTES" ]; then
    echo "$OSPF_ROUTES" >> $REPORT_FILE
    echo "$OSPF_ROUTES" | while read line; do 
        if [[ ! -z "$line" ]]; then
            log "  $line"
        fi
    done
else
    log "Нет маршрутов OSPF"
fi

# Тест связанности
log ""
log "ШАГ 9: Проверка связанности"
log "----------------------------------------"

if [ -n "$NEIGHBORS" ] && echo "$NEIGHBORS" | grep -q "Full"; then
    log "OSPF соседство установлено успешно"
    
    # Определяем IP для проверки связи
    if [ "$ROLE" = "HQ-RTR" ]; then
        TEST_IP="192.168.30.1"
    else
        TEST_IP="192.168.10.1"
    fi
    
    log "Проверка связи с удаленной сетью ($TEST_IP):"
    if ping -c 3 -W 3 $TEST_IP &>/dev/null; then
        log "  РЕЗУЛЬТАТ: Связь с $TEST_IP установлена"
        ping -c 3 $TEST_IP >> $REPORT_FILE 2>&1
    else
        log "  РЕЗУЛЬТАТ: Нет связи с $TEST_IP (возможно, требуется время для обновления маршрутов)"
    fi
else
    log "OSPF соседство не установлено, пропускаем проверку связи"
fi

log ""
log "============================================="
log "НАСТРОЙКА OSPF ЗАВЕРШЕНА"
log "============================================="
log ""
log "Отчет сохранен в: $REPORT_FILE"
log ""
log "Полезные команды для проверки:"
log "  vtysh -c 'show ip ospf neighbor'     # показать соседей"
log "  vtysh -c 'show ip route ospf'        # показать маршруты OSPF"
log "  vtysh -c 'show running-config'       # показать конфигурацию"
log "  vtysh -c 'show ip ospf interface'    # показать интерфейсы OSPF"
log ""

# Запись пароля в отдельный защищенный файл (опционально)
echo "Сохранить пароль в отдельный файл? (y/n): "
read SAVE_PASSWORD

if [ "$SAVE_PASSWORD" = "y" ]; then
    PASSWORD_FILE="/root/ospf_password_$(date +%Y%m%d).txt"
    echo "Пароль OSPF для $(hostname): $OSPF_PASSWORD" > $PASSWORD_FILE
    chmod 600 $PASSWORD_FILE
    log "Пароль сохранен в: $PASSWORD_FILE (с правами 600)"
fi

log ""
log "Для просмотра полного отчета: cat $REPORT_FILE"
