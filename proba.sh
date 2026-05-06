#!/bin/bash
#===============================================================================
# FRR OSPF/GRE Setup - AUTO DETECT VERSION
# Версия 3.0 - АВТОМАТИЧЕСКОЕ ОПРЕДЕЛЕНИЕ СЕТЕЙ
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"
BACKUP_DIR="/root/frr_backups"

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
 echo -e "${RED}Ошибка: Запустите от root${NC}"
 exit 1
fi

# Функция очистки всех настроек
full_cleanup() {
 print_msg "Полная очистка настроек..."
 
 # Удаляем GRE туннель
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1
 rm -rf "$IFACES_DIR/gre1" 2>/dev/null
 
 # Сбрасываем FRR
 if [[ -f "$FRR_CONF" ]]; then
  mkdir -p "$BACKUP_DIR"
  cp "$FRR_CONF" "$BACKUP_DIR/frr.conf.$(date +%Y%m%d_%H%M%S)"
 fi
 cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
line vty
!
EOF
 
 # Перезапускаем сервисы
 systemctl restart frr 2>/dev/null || true
 systemctl restart net 2>/dev/null || true
 
 print_ok "Очистка завершена"
}

# Функция определения сети по интерфейсу
get_network_from_iface() {
 local iface=$1
 local ip_mask=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
 [[ -z "$ip_mask" ]] && return
 
 local ip=$(echo "$ip_mask" | cut -d'/' -f1)
 local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
 
 # Вычисляем network address
 local IFS='.'; read -r i1 i2 i3 i4 <<< "$ip"
 local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
 local ip_int=$(( (i1 << 24) | (i2 << 16) | (i3 << 8) | i4 ))
 local net_int=$(( ip_int & mask ))
 
 echo "$(( (net_int >> 24) & 0xFF )).$(( (net_int >> 16) & 0xFF )).$(( (net_int >> 8) & 0xFF )).$(( net_int & 0xFF ))/$cidr"
}

# Извлечение только IP без маски
extract_ip_only() { echo "$1" | cut -d'/' -f1; }
extract_cidr() { [[ "$1" == *"/"* ]] && echo "$1" | cut -d'/' -f2 || echo "24"; }

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_err() { echo -e "${RED}[X]${NC} $1"; }

#===============================================================================
# АВТО-ОПРЕДЕЛЕНИЕ СЕТЕЙ ДЛЯ OSPF
#===============================================================================

auto_detect_networks() {
 local networks=""
 local excluded_ifaces=("lo" "$EXT_IFACE" "gre1" "gre0")
 
 print_msg "Сканирование интерфейсов для авто-добавления сетей..."
 
 for iface in $(ls /sys/class/net/ 2>/dev/null); do
  # Пропускаем исключённые интерфейсы
  [[ " ${excluded_ifaces[@]} " =~ " $iface " ]] && continue
  
  # Пропускаем если интерфейс не up
  [[ ! -d "/sys/class/net/$iface/operstate" ]] && continue
  [[ $(cat "/sys/class/net/$iface/operstate" 2>/dev/null) != "up" ]] && continue
  
  # Получаем сеть
  net=$(get_network_from_iface "$iface")
  [[ -z "$net" ]] && continue
  
  # Пропускаем link-local и другие служебные сети
  [[ "$net" =~ ^169\.254\. ]] && continue
  [[ "$net" =~ ^127\. ]] && continue
  
  networks+="    network $net area 0\n"
  print_ok "Добавлена: $net ($iface)"
 done
 
 # Добавляем сеть туннеля GRE
 if [[ -n "$GRE_IP" ]]; then
  GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
  GRE_NET_CIDR=$(extract_cidr "$GRE_IP")
  GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
  networks+="    network $GRE_NET area 0\n"
  print_ok "Добавлена сеть туннеля: $GRE_NET"
 fi
 
 echo -e "$networks"
}

#===============================================================================
# НАСТРОЙКА FRR
#===============================================================================

setup_frr() {
 #===============================================================================
 # ШАГ 0: ОЧИСТКА
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Очистка старых настроек ===${NC}"
 read -p "Удалить предыдущие настройки? [Y/n]: " cleanup_ans
 if [[ ! "$cleanup_ans" =~ ^[Nn]$ ]]; then
  full_cleanup
  sleep 2
 fi
 
 #===============================================================================
 # ШАГ 1: УСТАНОВКА И РОЛЬ
 #===============================================================================
 
 print_msg "Проверка установки FRR..."
 if ! command -v vtysh &>/dev/null; then
  print_msg "Установка пакетов..."
  apt-get update >/dev/null 2>&1
  apt-get install -y frr >/dev/null 2>&1
  print_ok "FRR установлен"
 fi
 
 echo -e "\n${YELLOW}=== Шаг 1: Идентификация роутера ===${NC}"
 
 HOST=$(hostname | tr '[:upper:]' '[:lower:]')
 
 if [[ "$HOST" =~ "hq-rtr" ]]; then
  ROLE="HQ-RTR"; RID="1.1.1.1"; DEF_GRE="172.16.100.1/29"
 elif [[ "$HOST" =~ "br-rtr" ]]; then
  ROLE="BR-RTR"; RID="2.2.2.2"; DEF_GRE="172.16.100.2/29"
 else
  echo "Выберите роль:"
  echo " 1) HQ-RTR (Router ID: 1.1.1.1)"
  echo " 2) BR-RTR (Router ID: 2.2.2.2)"
  read -p "Ваш выбор [1]: " role_choice
  if [[ "$role_choice" == "2" ]]; then
   ROLE="BR-RTR"; RID="2.2.2.2"; DEF_GRE="172.16.100.2/29"
  else
   ROLE="HQ-RTR"; RID="1.1.1.1"; DEF_GRE="172.16.100.1/29"
  fi
 fi
 print_ok "Роль: $ROLE, Router ID: $RID"
 
 #===============================================================================
 # ШАГ 2: GRE ТУННЕЛЬ
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 2: Настройка GRE туннеля ===${NC}"
 
 # Показываем интерфейсы
 echo "Доступные интерфейсы:"
 for iface in $(ls /sys/class/net/ | grep -v lo); do
  ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
  [[ -n "$ip_info" ]] && printf "  • %-10s %s\n" "$iface" "$ip_info"
 done
 
 read -p "Внешний интерфейс: " EXT_IFACE
 EXT_IP_FULL=$(ip -4 addr show "$EXT_IFACE" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
 EXT_IP=$(extract_ip_only "$EXT_IP_FULL")
 print_ok "Выбран: $EXT_IFACE ($EXT_IP)"
 
 read -p "Внешний IP удалённого роутера: " REMOTE_IP
 
 read -p "Локальный IP туннеля [$DEF_GRE]: " GRE_INPUT
 GRE_INPUT="${GRE_INPUT:-$DEF_GRE}"
 GRE_IP_ADDR=$(extract_ip_only "$GRE_INPUT")
 GRE_CIDR=$(extract_cidr "$GRE_INPUT")
 GRE_IP="$GRE_IP_ADDR/$GRE_CIDR"
 print_ok "Туннель: $GRE_IP"
 
 # Создаём конфиг GRE
 print_msg "Настройка GRE..."
 mkdir -p "$IFACES_DIR/gre1"
 
 cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
 echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"
 
 # Активируем туннель
 ip link set gre1 down 2>/dev/null; sleep 1
 ip tunnel del gre1 2>/dev/null; sleep 1
 ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
 ip addr add $GRE_IP dev gre1
 ip link set gre1 up
 sleep 2
 
 if ip link show gre1 &>/dev/null; then
  print_ok "Туннель gre1 активирован ✓"
  ping -c 1 $(echo "$GRE_IP" | sed "s/$GRE_IP_ADDR/$(echo $REMOTE_IP | cut -d'.' -f4)/") &>/dev/null && print_ok "Туннель работает ✓"
 else
  print_err "Не удалось активировать туннель!"
  exit 1
 fi
 
 #===============================================================================
 # ШАГ 3: АВТО-ОПРЕДЕЛЕНИЕ СЕТЕЙ И OSPF
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 3: Авто-определение сетей для OSPF ===${NC}"
 
 read -p "Пароль OSPF [P@ssw0rd]: " PASS
 PASS="${PASS:-P@ssw0rd}"
 
 # Авто-определение сетей
 NETWORKS_CONFIG=$(auto_detect_networks)
 
 # Показываем что будет добавлено
 echo -e "\n${WHITE}Будут добавлены следующие сети:${NC}"
 echo -e "$NETWORKS_CONFIG" | sed 's/^/  /'
 
 read -p "Продолжить с этими настройками? [Y/n]: " confirm
 if [[ "$confirm" =~ ^[Nn]$ ]]; then
  print_warn "Отменено пользователем"
  exit 0
 fi
 
 #===============================================================================
 # ЗАПИСЬ КОНФИГА
 #===============================================================================
 
 print_msg "Генерация $FRR_CONF..."
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
$NETWORKS_CONFIG
!
line vty
!
EOF
 
 print_ok "Конфигурация записана"
 
 # Запуск FRR
 systemctl enable frr >/dev/null 2>&1
 systemctl restart frr
 sleep 3
 
 #===============================================================================
 # ИТОГИ
 #===============================================================================
 
 clear
 echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
 echo -e "${GREEN}║ ✅ НАСТРОЙКА ЗАВЕРШЕНА ║${NC}"
 echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
 
 echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
 echo "  Роль: $ROLE"
 echo "  Router ID: $RID"
 echo "  Туннель: $GRE_IP"
 echo "  Внешний IP: $EXT_IP → $REMOTE_IP"
 echo ""
 
 echo -e "${WHITE}OSPF СОСЕДИ:${NC}"
 vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "  Пока нет соседей"
 echo ""
 
 echo -e "${WHITE}OSPF МАРШРУТЫ:${NC}"
 vtysh -c "show ip route ospf" 2>/dev/null | head -15 || echo "  Пока нет маршрутов"
 echo ""
 
 echo -e "${MAGENTA}ПОЛЕЗНЫЕ КОМАНДЫ:${NC}"
 echo "  vtysh -c 'show ip ospf neighbor'    # Соседи"
 echo "  vtysh -c 'show ip route ospf'       # Маршруты"
 echo "  vtysh -c 'show running-config ospf' # Конфиг OSPF"
 echo "  systemctl status frr                # Статус сервиса"
 echo ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR Auto-Setup v3.0 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo " 1) Настроить FRR (авто-определение сетей)"
echo " 2) Удалить все настройки"
echo " 3) Показать статус"
echo " 4) Выход"
read -p "Выбор [1]: " choice

case $choice in
 2) full_cleanup ;;
 3)
  echo -e "\n${WHITE}=== GRE ===${NC}"
  ip link show | grep -E "gre[0-9]+" || echo "Нет туннелей"
  echo -e "\n${WHITE}=== OSPF соседи ===${NC}"
  vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не активен"
  echo -e "\n${WHITE}=== OSPF маршруты ===${NC}"
  vtysh -c "show ip route ospf" 2>/dev/null | head -10 || echo "Нет маршрутов"
  ;;
 4) exit 0 ;;
 *) setup_frr ;;
esac

echo -e "\n${GREEN}Готово!${NC}"
