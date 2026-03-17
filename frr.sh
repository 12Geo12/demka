#!/bin/bash

# ==============================================================================
# Скрипт автоматической настройки OSPF для FRR (ALT Linux)
# Задание 7: Динамическая маршрутизация через GRE туннель
# ==============================================================================

set -e # Остановить скрипт при ошибке

REPORT_FILE="ospf_report_$(hostname)_$(date +%F_%H-%M).txt"

echo "=============================================================================="
echo "  НАСТРОЙКА OSPF (FRR) ДЛЯ ALT LINUX"
echo "=============================================================================="

# 1. Проверка и установка FRR
if ! command -v vtysh &> /dev/null; then
    echo "[*] FRR не найден. Установка пакетов..."
    apt-get update -qq
    apt-get install -y -qq frr
    echo "[+] FRR установлен."
else
    echo "[+] FRR уже установлен."
fi

# 2. Включение демона OSPF
echo "[*] Активация демона ospfd..."
if grep -q "ospfd=no" /etc/frr/daemons; then
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    echo "[+] Демон ospfd активирован и служба перезагружена."
else
    echo "[!] Демон ospfd уже активен или файл конфигурации демонов изменен."
fi

# 3. Сбор параметров от пользователя
echo ""
echo "Введите параметры маршрутизации:"
read -p "Введите OSPF Router-ID (например, 172.16.1.1): " ROUTER_ID
read -p "Введите имя туннельного интерфейса (например, gre1): " TUN_IF
read -p "Введите IP сеть туннеля с маской (например, 10.10.0.0/30): " TUN_NET
read -p "Введите пароль для OSPF аутентификации: " -s OSPF_PASS
echo ""
echo "Введите локальные сети для анонсирования (через пробел):"
echo "Пример: 192.168.100.0/24 192.168.200.0/24"
read -a LAN_NETWORKS

# 4. Генерация конфигурации через vtysh
echo "[*] Применение конфигурации OSPF..."

vtysh <<EOF
configure terminal
  router ospf
    ospf router-id ${ROUTER_ID}
    network ${TUN_NET} area 0
EOF

# Добавление локальных сетей
for NET in "${LAN_NETWORKS[@]}"; do
    vtysh -c "conf t" -c "router ospf" -c "network ${NET} area 0"
done

# Настройка аутентификации области
vtysh -c "conf t" -c "router ospf" -c "area 0 authentication"

# Настройка интерфейса туннеля
vtysh <<EOF
configure terminal
  interface ${TUN_IF}
    no ip ospf passive
    ip ospf network broadcast
    ip ospf authentication
    ip ospf authentication-key ${OSPF_PASS}
  exit
exit
write
EOF

echo "[+] Конфигурация успешно применена."

# 5. Генерация отчета
echo "[*] Формирование отчета: ${REPORT_FILE}"

{
    echo "================================================================================"
    echo " ОТЧЕТ ПО НАСТРОЙКЕ OSPF (Задание 7)"
    echo " Дата: $(date)"
    echo " Хост: $(hostname)"
    echo "================================================================================"
    echo ""
    echo "1. ТЕКУЩАЯ КОНФИГУРАЦИЯ (show run):"
    echo "--------------------------------------------------------------------------------"
    vtysh -c "show run"
    echo ""
    echo "2. СТАТУС СОСЕДЕЙ OSPF (show ip ospf neighbor):"
    echo "--------------------------------------------------------------------------------"
    vtysh -c "show ip ospf neighbor"
    echo ""
    echo "3. ТАБЛИЦА МАРШРУТИЗАЦИИ (show ip route ospf):"
    echo "--------------------------------------------------------------------------------"
    vtysh -c "show ip route ospf"
    echo ""
    echo "================================================================================"
    echo " КОНЕЦ ОТЧЕТА"
    echo "================================================================================"
} > "${REPORT_FILE}"

echo ""
echo "=============================================================================="
echo "  ГОТОВО!"
echo "  Отчет сохранен в файл: ${REPORT_FILE}"
echo "  Для проверки связи используйте: ping <IP_удаленной_сети>"
echo "=============================================================================="
