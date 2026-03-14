#!/bin/bash

# ==========================================
# RAID-5 AUTO-CREATOR (ALT LINUX)
# ==========================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root (su -).${NC}"
  exit 1
fi

# --- ШАГ 1: Просмотр дисков ---
echo -e "${BLUE}Доступные диски в системе:${NC}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
echo "----------------------------------------------"

# --- ШАГ 2: Выбор дисков ---
echo -e "${YELLOW}Для RAID-5 требуется минимум 3 диска.${NC}"
read -p "Введите названия дисков через пробел (например: sdb sdc sdd): " DISK_INPUT

# Преобразование ввода в массив
DISKS_ARRAY=($DISK_INPUT)
DISK_COUNT=${#DISKS_ARRAY[@]}

# Проверка количества дисков
if [ "$DISK_COUNT" -lt 3 ]; then
    echo -e "${RED}Ошибка: Для RAID-5 нужно минимум 3 диска. Вы указали $DISK_COUNT.${NC}"
    exit 1
fi

# Формирование списка устройств для mdadm
DEVICES=""
for disk in "${DISKS_ARRAY[@]}"; do
    if [ -e "/dev/$disk" ]; then
        DEVICES="$DEVICES /dev/$disk"
    else
        echo -e "${RED}Ошибка: Диск /dev/$disk не найден!${NC}"
        exit 1
    fi
done

# --- ШАГ 3: Подтверждение ---
echo -e "${YELLOW}Будет создан RAID-5 массив из следующих дисков:${NC}"
echo "$DEVICES"
read -p "Все данные на них будут УДАЛЕНЫ! Продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "Отмена операции."
    exit 0
fi

# --- ШАГ 4: Установка mdadm ---
echo -e "${BLUE}[1/6] Установка mdadm...${NC}"
apt-get update > /dev/null
apt-get install -y mdadm

# --- ШАГ 5: Очистка дисков (во избежание ошибок) ---
echo -e "${BLUE}[2/6] Очистка суперблоков (wipe)...${NC}"
for disk in "${DISKS_ARRAY[@]}"; do
    wipefs -a /dev/$disk > /dev/null 2>&1
done

# --- ШАГ 6: Создание RAID массива ---
echo -e "${BLUE}[3/6] Создание RAID-5 массива /dev/md0...${NC}"
# --run заставляет запустить массив сразу, --force игнорирует предупреждения о существующих файловых системах
mdadm --create /dev/md0 -l5 -n$DISK_COUNT $DEVICES --run --force

if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при создании RAID!${NC}"
    exit 1
fi

echo -e "${GREEN}Массив создан. Ожидание синхронизации (может занять время)...${NC}"
cat /proc/mdstat

# --- ШАГ 7: Создание файловой системы ---
echo -e "${BLUE}[4/6] Создание файловой системы ext4...${NC}"
mkfs.ext4 -F /dev/md0

# --- ШАГ 8: Настройка конфигурации ---
echo -e "${BLUE}[5/6] Сохранение конфигурации mdadm...${NC}"
mkdir -p /etc/mdadm
echo 'DEVICE partitions' > /etc/mdadm/mdadm.conf
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# --- ШАГ 9: Монтирование ---
MOUNT_POINT="/raid5"
echo -e "${BLUE}[6/6] Настройка монтирования в $MOUNT_POINT...${NC}"

mkdir -p $MOUNT_POINT

# Добавление в fstab (проверяем, нет ли уже такой записи)
if ! grep -q "/dev/md0" /etc/fstab; then
    echo "/dev/md0    $MOUNT_POINT    ext4    defaults    0 0" >> /etc/fstab
fi

mount -a

# --- ИТОГ ---
echo -e "=========================================="
echo -e "${GREEN}RAID-5 УСПЕШНО СОЗДАН!${NC}"
echo -e "=========================================="
echo -e "Устройство: ${YELLOW}/dev/md0${NC}"
echo -e "Точка монтирования: ${YELLOW}$MOUNT_POINT${NC}"
echo ""
df -h | grep md0
echo ""
echo -e "Детальная информация:"
mdadm --detail /dev/md0