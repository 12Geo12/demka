#!/bin/bash
#===============================================================================
# FRR OSPF/GRE Setup - MANUAL ONLY VERSION
# Только ручной ввод сетей
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"

if [[ $EUID -ne 0 ]]; then
 echo -e "${RED}Запустите от root${NC}"
 exit 1
fi

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_err() { echo -e "${RED}[X]${NC} $1"; }

# Очистка
full_cleanup() {
 print_msg "Очистка старых настроек..."
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1
 rm -rf "$IFACES_DIR/gre1" 2>/dev/null
 cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname $(hostname)
!
line vty
!
EOF
 systemctl restart frr 2>/dev/null || true
 print_ok "Очищено"
}

setup_frr() {
 # Очистка
 echo -e "\n${YELLOW}Очистить старые настройки? [Y/n]:${NC} \c"
 read -r cleanup_ans
 if [[ ! "$cleanup_ans" =~ ^[Nn]$ ]]; then
  full_cleanup
  sleep 1
 fi

 # Установка FRR
 if ! command -v vtysh &>/dev/null; then
  print_msg "Установка FRR..."
  apt-get update >/dev/null 2>&1
  apt-get install -y frr >/dev/null 2>&1
  print_ok "FRR установлен"
 fi

 # Роль
 HOST=$(hostname | tr '[:upper:]' '[:lower:]')
 if [[ "$HOST" =~ "hq-rtr" ]]; then
  ROLE="HQ-RTR"; RID="1.1.1.1"; GRE_IP="172.16.100.1/29"
 elif [[ "$HOST" =~ "br-rtr" ]]; then
  ROLE="BR-RTR"; RID="2.2.2.2"; GRE_IP="172.16.100.2/29"
 else
  ROLE="HQ-RTR"; RID="1.1.1.1"; GRE_IP="172.16.100.1/29"
 fi
 print_ok "Роль: $ROLE, Router ID: $RID"

 # Интерфейсы
 echo -e "\n${YELLOW}Доступные интерфейсы:${NC}"
 i=1
 declare -a IFACE_LIST
 for iface in $(ls /sys/class/net/ | grep -v lo); do
  ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
  if [[ -n "$ip_info" ]]; then
   printf " %d) %-10s %s\n" "$i" "$iface" "$ip_info"
   IFACE_LIST+=("$iface")
   ((i++))
  fi
 done

 echo -e "\n${YELLOW}Внешний интерфейс (номер):${NC} \c"
 read -r ext_idx
 EXT_IFACE="${IFACE_LIST[$((ext_idx-1))]}"
 EXT_IP=$(ip -4 addr show "$EXT_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
 print_ok "Выбран: $EXT_IFACE ($EXT_IP)"

 echo -e "${YELLOW}Внешний IP удалённого роутера:${NC} \c"
 read -r REMOTE_IP
 print_ok "Удалённый IP: $REMOTE_IP"

 echo -e "${YELLOW}Локальный IP туннеля [$GRE_IP]:${NC} \c"
 read -r GRE_INPUT
 GRE_IP="${GRE_INPUT:-$GRE_IP}"
 print_ok "Туннель: $GRE_IP"

 # Настройка GRE
 print_msg "Настройка GRE..."
 mkdir -p "$IFACES_DIR/gre1"
 
 cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
 echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"

 # Удаление старого туннеля
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1

 # Создание туннеля
 print_msg "Создание туннеля..."
 if ! ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64; then
  print_err "Не удалось создать туннель!"
  exit 1
 fi

 if ! ip addr add "$GRE_IP" dev gre1; then
  print_err "Не удалось добавить IP!"
  ip tunnel del gre1
  exit 1
 fi

 if ! ip link set gre1 up; then
  print_err "Не удалось активировать!"
  ip tunnel del gre1
  exit 1
 fi

 sleep 2

 if ip link show gre1 &>/dev/null; then
  print_ok "✓ Туннель gre1 активирован"
  if [[ "$ROLE" == "HQ-RTR" ]]; then
   REMOTE_GRE="172.16.100.2"
  else
   REMOTE_GRE="172.16.100.1"
  fi
  if ping -c 2 "$REMOTE_GRE" &>/dev/null; then
   print_ok "✓ Туннель работает (ping прошёл)"
  else
   print_err "⚠ Туннель создан, но ping не проходит"
  fi
 else
  print_err "Туннель не активен!"
  exit 1
 fi

 #===============================================================================
 # РУЧНОЙ ВВОД СЕТЕЙ - ИСПРАВЛЕНО
 #===============================================================================
 
 echo ""
 echo -e "${YELLOW}=== ДОБАВЛЕНИЕ СЕТЕЙ ДЛЯ OSPF ===${NC}"
 echo ""
 echo "Вводите сети в формате: IP/CIDR"
 echo "Примеры:"
 echo "  192.168.10.0/26"
 echo "  192.168.4.0/28"
 echo "  172.16.100.0/29  (сеть туннеля)"
 echo ""
 echo "Для завершения ввода нажмите Enter"
 echo "=========================================="
 
 NETWORKS=""
 
 while true; do
  read -p "Сеть: " net
  
  # Если пустая строка - завершаем
  if [[ -z "$net" ]]; then
   break
  fi
  
  # Проверка формата
  if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
   NETWORKS+="  network $net area 0"$'\n'
   print_ok "Добавлена: $net"
  else
   print_err "Неверный формат! Используйте IP/CIDR (например, 192.168.10.0/24)"
  fi
 done

 # Если ничего не ввели - добавляем хотя бы туннель
 if [[ -z "$NETWORKS" ]]; then
  GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
  GRE_NET_CIDR=$(echo "$GRE_IP" | grep -oP '/\K\d+$' || echo "29")
  GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
  NETWORKS="  network $GRE_NET area 0"$'\n'
  print_warn "Сети не введены. Добавлена только сеть туннеля: $GRE_NET"
 fi

 #===============================================================================
 # ПАРОЛЬ И КОНФИГ
 #===============================================================================
 
 echo ""
 read -p "Пароль OSPF [P@ssw0rd]: " PASS
 PASS="${PASS:-P@ssw0rd}"

 # Показываем что будет записано
 echo ""
 echo -e "${YELLOW}=== БУДЕТ ЗАПИСАНО В КОНФИГ ===${NC}"
 echo "router ospf"
 echo " ospf router-id $RID"
 echo " passive-interface default"
 echo " no passive-interface gre1"
 echo " ip ospf authentication"
 echo " ip ospf authentication-key $PASS"
 echo " area 0 authentication"
 echo "$NETWORKS"
 
 read -p "Записать конфиг? [Y/n]: " write_ans
 if [[ "$write_ans" =~ ^[Nn]$ ]]; then
  print_err "Отменено!"
  exit 1
 fi

 # Запись конфига
 print_msg "Запись конфигурации..."
 cat > "$FRR_CONF" << EOF
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id $RID
 passive-interface default
 no passive-interface gre1
 ip ospf authentication
 ip ospf authentication-key $PASS
 area 0 authentication
$NETWORKS!
line vty
!
EOF

 print_ok "Конфигурация записана"

 # Показываем финальный конфиг
 echo -e "\n${YELLOW}=== ФИНАЛЬНЫЙ КОНФИГ ===${NC}"
 cat "$FRR_CONF"

 # Запуск
 systemctl enable frr >/dev/null 2>&1
 systemctl restart frr
 sleep 3

 # Итоги
 clear
 echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
 echo -e "${GREEN}║ ✅ НАСТРОЙКА ЗАВЕРШЕНА ║${NC}"
 echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
 echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
 echo "  Роль: $ROLE"
 echo "  Router ID: $RID"
 echo "  Туннель: $GRE_IP"
 echo ""
 echo -e "${WHITE}OSPF СОСЕДИ:${NC}"
 vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  Пока нет соседей"
 echo ""
 echo -e "${WHITE}OSPF МАРШРУТЫ:${NC}"
 vtysh -c "show ip route ospf" 2>/dev/null | head -15 || echo "  Пока нет маршрутов"
 echo ""
 echo -e "${MAGENTA}КОМАНДЫ:${NC}"
 echo "  vtysh -c 'show ip ospf neighbor'"
 echo "  vtysh -c 'show ip route ospf'"
 echo "  vtysh -c 'show running-config ospf'"
 echo ""
}

# Меню
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup - MANUAL ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo " 1) Настроить FRR (ручной ввод сетей)"
echo " 2) Удалить настройки"
echo " 3) Показать статус"
echo " 4) Выход"
echo ""
read -p "Выбор [1]: " choice

case $choice in
 2) full_cleanup ;;
 3)
  echo -e "\n${WHITE}=== GRE туннели ===${NC}"
  ip link show | grep -E "gre[0-9]+" || echo "Нет активных"
  echo -e "\n${WHITE}=== FRR OSPF ===${NC}"
  if [[ -f "$FRR_CONF" ]]; then
   grep -A20 "router ospf" "$FRR_CONF" 2>/dev/null || echo "OSPF не настроен"
  fi
  echo -e "\n${WHITE}=== OSPF соседи ===${NC}"
  vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не активен"
  ;;
 4) exit 0 ;;
 *) setup_frr ;;
esac

echo -e "\n${GREEN}Готово!${NC}"
