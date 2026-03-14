#!/bin/bash

# ==========================================
# RAID-5 UNIVERSAL CREATOR (ALT LINUX)
# - Auto-detects free disks
# - Auto-creates virtual disks if needed
# ==========================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'
RAID_DEVICE="/dev/md0"
MOUNT_POINT="/raid5"

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите от root (su -).${NC}"
  exit 1
fi

# Функция для создания виртуальных дисков (если нет физических)
create_virtual_disks() {
    echo -e "${YELLOW}Недостаточно свободных физических дисков.${NC}"
    echo -e "${BLUE}Создаю виртуальные диски (Loopback) для RAID...${NC}"
    
    VIRTUAL_DISK_DIR="/var/virtual_raid_disks"
    mkdir -p $VIRTUAL_DISK_DIR
    
    # Создаем 3 файла по 1Гб (можно изменить размер count=1024)
    DEVICES=""
    for i in 1 2 3; do
        FILE_PATH="$VIRTUAL_DISK_DIR/disk$i.img"
        echo "Создание файла $FILE_PATH (1GB)..."
        dd if=/dev/zero of=$FILE_PATH bs=1M count=1024 status=progress
        
        # Создаем loop устройство
        LOOP_DEV=$(losetup -f --show $FILE_PATH)
        echo -e "Создано устройство: ${GREEN}$LOOP_DEV${NC} из файла $FILE_PATH"
        DEVICES="$DEVICES $LOOP_DEV"
    done
    
    # Сохраняем список loop устройств для очистки при удалении (если нужно)
    echo "$DEVICES" > /tmp/raid_loop_devices.list
}

# --- ШАГ 1: Установка mdadm ---
echo -e "${BLUE}[1/6] Установка mdadm...${NC}"
apt-get update > /dev/null
apt-get install -y mdadm

# --- ШАГ 2: Поиск свободных дисков ---
echo -e "${BLUE}[2/6] Поиск свободных дисков...${NC}"

# Ищем диски, которые не смонтированы и не имеют разделов (простая эвристика)
# Исключаем sda (обычно системный) и диски с разделами
FREE_DISKS=$(lsblk -lno NAME,TYPE,MOUNTPOINT | grep 'disk' | grep -v '`' | awk '$2=="" {print $1}' | grep -v "sda" | head -n 3)
FREE_DISKS_ARRAY=($FREE_DISKS)

DEVICES=""

if [ "${#FREE_DISKS_ARRAY[@]}" -ge 3 ]; then
    echo -e "${GREEN}Найдено достаточно свободных дисков:${NC} ${FREE_DISKS_ARRAY[@]}"
    read -p "Использовать их? (y/n): " CHOICE
    if [[ "$CHOICE" == "y" ]]; then
        for d in "${FREE_DISKS_ARRAY[@]}"; do
            DEVICES="$DEVICES /dev/$d"
        done
    else
        # Если пользователь отказался, предложим создать виртуальные
        create_virtual_disks
    fi
else
    # Если дисков меньше 3, сразу создаем виртуальные
    create_virtual_disks
fi

# --- ШАГ 3: Подтверждение ---
echo -e "${YELLOW}Для RAID-5 будут использованы устройства:${NC}"
echo "$DEVICES"
read -p "Данные на них будут уничтожены! Продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "Отмена."
    # Если создавали виртуальные, отчистим их
    if [ -f /tmp/raid_loop_devices.list ]; then
        cat /tmp/raid_loop_devices.list | xargs -n1 losetup -d
        rm /tmp/raid_loop_devices.list
    fi
    exit 0
fi

# --- ШАГ 4: Очистка и создание RAID ---
echo -e "${BLUE}[3/6] Очистка суперблоков...${NC}"
for dev in $DEVICES; do
    wipefs -a $dev > /dev/null 2>&1
done

echo -e "${BLUE}[4/6] Создание RAID-5 массива $RAID_DEVICE...${NC}"
# Используем --force для автоматического запуска
mdadm --create $RAID_DEVICE -l5 -n3 $DEVICES --run --force

if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания RAID!${NC}"
    exit 1
fi

# --- ШАГ 5: Файловая система ---
echo -e "${BLUE}[5/6] Создание файловой системы ext4...${NC}"
mkfs.ext4 -F $RAID_DEVICE

# --- ШАГ 6: Монтирование и конфиг ---
echo -e "${BLUE}[6/6] Настройка монтирования...${NC}"
mkdir -p $MOUNT_POINT

# Сохранение конфигурации
mkdir -p /etc/mdadm
echo 'DEVICE partitions' > /etc/mdadm/mdadm.conf
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# Важно: для виртуальных устройств нужно добавить их в конфиг, чтобы они подхватывались при загрузке
# (Хотя для loopback это требует дополнительной настройки systemd, здесь базовая настройка)

if ! grep -q "$RAID_DEVICE" /etc/fstab; then
    echo "$RAID_DEVICE    $MOUNT_POINT    ext4    defaults    0 0" >> /etc/fstab
fi

mount -a

# --- ИТОГ ---
echo -e "=========================================="
echo -e "${GREEN}RAID-5 УСПЕШНО СОЗДАН!${NC}"
echo -e "=========================================="
echo -e "Устройство: $RAID_DEVICE"
echo -e "Точка монтирования: $MOUNT_POINT"
echo -e "Используемые устройства: $DEVICES"
df -h | grep md0

# Предупреждение для виртуальных дисков
if [ -f /tmp/raid_loop_devices.list ]; then
    echo ""
    echo -e "${YELLOW}ВНИМАНИЕ: Используются виртуальные диски (файлы).${NC}"
    echo "Для сохранения RAID после перезагрузки требуется дополнительная настройка автоподключения loop-устройств."
fi
