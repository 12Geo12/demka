#!/bin/bash
#===============================================================================
# ПРОСТОЙ СКРИПТ НАСТРОЙКИ FRR ДЛЯ ALT LINUX
# Метод: Создание файлов конфигурации (как в Module_1_2026.md)
#===============================================================================

# Цвета для удобства
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Основные пути
IFACES_DIR="/etc/net/ifaces"
FRR_DIR="/etc/frr"

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Запустите от root${NC}"
    exit 1
fi

# 1. Установка FRR
echo -e "${CYAN}[1/4] Установка FRR...${NC}"
apt-get update > /dev/null 2>&1
apt-get install -y frr > /dev/null 2>&1 || { echo "Ошибка установки FRR"; exit 1; }
echo -e "${GREEN}[OK] FRR установлен${NC}"

# 2. Определение роли роутера
echo -e "${CYAN}[2/4] Определение роли маршрутизатора...${NC}"
HOST=$(hostname | tr '[:upper:]' '[:lower:]')
ROLE=""
ROUTER_ID=""
GRE_LOCAL_IP=""
GRE_REMOTE_IP=""

# Автоматическое определение (можно изменить вручную)
if [[ "$HOST" =~ "hq-rtr" ]]; then
    ROLE="HQ-RTR"
    ROUTER_ID="10.10.10.1"
    GRE_LOCAL_IP="172.16.100.1/29"
    GRE_REMOTE_IP="172.16.100.2" # IP туннеля на BR-RTR
elif [[ "$HOST" =~ "br-rtr" ]]; then
    ROLE="BR-RTR"
    ROUTER_ID="10.10.10.2"
    GRE_LOCAL_IP="172.16.100.2/29"
    GRE_REMOTE_IP="172.16.100.1" # IP туннеля на HQ-RTR
else
    # Если не определился автоматически
    echo "Не удалось определить роль автоматически."
    read -p "Введите роль (1 - HQ-RTR, 2 - BR-RTR): " r_choice
    case $r_choice in
        1) ROLE="HQ-RTR"; ROUTER_ID="10.10.10.1"; GRE_LOCAL_IP="172.16.100.1/29" ;;
        2) ROLE="BR-RTR"; ROUTER_ID="10.10.10.2"; GRE_LOCAL_IP="172.16.100.2/29" ;;
    esac
fi
echo -e "${GREEN}[OK] Роль: $ROLE, Router ID: $ROUTER_ID${NC}"

# 3. Настройка GRE туннеля
echo -e "${CYAN}[3/4] Настройка GRE туннеля...${NC}"
# Получаем список интерфейсов для выбора внешнего
echo "Доступные интерфейсы:"
interfaces=($(ls /sys/class/net/ | grep -v lo))
for i in "${!interfaces[@]}"; do
    ip addr show ${interfaces[$i]} | grep inet | head -1 | awk '{print "  " "'$i') " $2}'
done

read -p "Выберите номер ВНЕШНЕГО интерфейса (для туннеля): " ext_idx
EXT_IFACE="${interfaces[$ext_idx]}"
EXT_IP=$(ip -4 addr show $EXT_IFACE | grep -oP 'inet \K[\d.]+')

# Запрос удаленного IP (внешнего адреса другого роутера)
read -p "Введите ВНЕШНИЙ IP удаленного роутера: " REMOTE_EXT_IP

# Создание конфигурации GRE в /etc/net/ifaces
mkdir -p "$IFACES_DIR/gre1"
cat > "$IFACES_DIR/gre1/options" <<EOF
BOOTPROTO=static
TYPE=iptun
TUNLOCAL=$EXT_IP
TUNREMOTE=$REMOTE_EXT_IP
TUNTYPE=gre
TUNOPTIONS='ttl 64'
HOST=$EXT_IFACE
ONBOOT=yes
DISABLED=no
EOF

echo "$GRE_LOCAL_IP" > "$IFACES_DIR/gre1/ipv4address"
echo -e "${GREEN}[OK] GRE туннель gre1 настроен${NC}"

# Поднимаем туннель прямо сейчас (без перезагрузки)
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_EXT_IP ttl 64
ip addr add $GRE_LOCAL_IP dev gre1
ip link set gre1 up

# 4. Настройка FRR (OSPF)
echo -e "${CYAN}[4/4] Настройка OSPF...${NC}"

# Пароль
read -p "Введите пароль для OSPF [P@ssw0rd]: " PASS
PASS=${PASS:-P@ssw0rd}

# Запрос сетей для анонса
echo "Введите сети для анонса в OSPF (например, 172.16.1.0/24)."
echo "Сеть туннеля 172.16.100.0/29 будет добавлена автоматически."
NETWORKS=""

# Автоматический поиск сетей (кроме внешнего и lo)
echo "Автоматический поиск локальных сетей..."
for iface in "${interfaces[@]}"; do
    if [[ "$iface" != "$EXT_IFACE" ]]; then
        net=$(ip -4 addr show $iface | grep -oP 'inet \K[\d./]+')
        if [[ -n "$net" ]]; then
            # Простой хак для получения сети из IP/Mask (работает в большинстве случаев)
            # Если ipcalc есть - используем, иначе берем как есть
            if command -v ipcalc &> /dev/null; then
                base_net=$(ipcalc -n $net | grep Network | awk '{print $2}')
            else
                # Если ipcalc нет, просто берем то, что выводит ip addr (часто это уже сеть)
                # Для простоты скрипта оставим так, или попросим ввести вручную если ошибка
                base_net=$(echo $net | cut -d'/' -f1) # Упрощенно
            fi
            read -p "Добавить сеть интерфейса $iface ($net)? (y/n) [y]: " ans
            if [[ "$ans" != "n" ]]; then
                # Используем формат сеть/маска
                NETWORKS+="  network $base_net area 0\n"
            fi
        fi
    fi
done

# Добавляем сеть туннеля
NETWORKS+="  network 172.16.100.0/29 area 0\n"

# Включаем демоны
sed -i 's/^ospfd=no/ospfd=yes/' $FRR_DIR/daemons
sed -i 's/^zebra=no/zebra=yes/' $FRR_DIR/daemons

# Создаем frr.conf
cat > $FRR_DIR/frr.conf <<EOF
!
frr version 8.1
frr defaults traditional
hostname $HOST
!
router ospf
 ospf router-id $ROUTER_ID
 passive-interface default
!
 interface gre1
  no ip ospf passive
  ip ospf authentication
  ip ospf authentication-key $PASS
 exit
!
 $(echo -e "$NETWORKS")
 area 0 authentication
!
line vty
!
EOF

# Права и запуск
chmod 640 $FRR_DIR/frr.conf
systemctl enable --now frr

echo -e "${GREEN}[OK] FRR настроен и запущен${NC}"
echo "------------------------------------------------"
echo "Проверка:"
echo "1. Пинг туннеля: ping $GRE_REMOTE_IP"
echo "2. Соседи OSPF: vtysh -c 'show ip ospf neighbor'"
