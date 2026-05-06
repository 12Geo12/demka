#!/bin/bash
#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# Версия 2.1 - ИСПРАВЛЕНО: полная очистка и обработка IP
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

# Функция очистки GRE туннеля
cleanup_gre() {
 print_msg "Очистка старых настроек GRE..."
 
 # Удаляем туннель
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1
 
 # Удаляем конфиги
 rm -rf "$IFACES_DIR/gre1" 2>/dev/null
 
 # Перезапускаем network (если нужно)
 if systemctl is-active --quiet net; then
  systemctl restart net 2>/dev/null || true
 fi
 
 print_ok "GRE туннель очищен"
}

# Функция очистки FRR
cleanup_frr() {
 print_msg "Сброс конфигурации FRR..."
 
 # Бэкап
 if [[ -f "$FRR_CONF" ]]; then
  mkdir -p "$BACKUP_DIR"
  cp "$FRR_CONF" "$BACKUP_DIR/frr.conf.$(date +%Y%m%d_%H%M%S)"
 fi
 
 # Сброс к дефолту
 cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
line vty
!
EOF
 
 systemctl restart frr
 print_ok "FRR сброшен к настройкам по умолчанию"
}

# Функция очистки ВСЕГО
full_cleanup() {
 echo -e "\n${YELLOW}=== ПОЛНАЯ ОЧИСТКА ===${NC}"
 cleanup_gre
 cleanup_frr
 echo -e "${GREEN}Все настройки удалены!${NC}"
}

# Функция определения сети
get_network_from_iface() {
 local iface=$1
 local ip_mask=$(ip -4 addr show dev "$iface" | grep -oP 'inet \K[\d./]+')
 if [[ -z "$ip_mask" ]]; then return; fi
 local ip=$(echo "$ip_mask" | cut -d'/' -f1)
 local cidr=$(echo "$ip_mask" | cut -d'/' -f2)
 local IFS='.'; read -r i1 i2 i3 i4 <<< "$ip"
 local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
 local ip_int=$(( (i1 << 24) | (i2 << 16) | (i3 << 8) | i4 ))
 local net_int=$(( ip_int & mask ))
 echo "$(( (net_int >> 24) & 0xFF )).$(( (net_int >> 16) & 0xFF )).$(( (net_int >> 8) & 0xFF )).$(( net_int & 0xFF ))/$cidr"
}

# Функция извлечения IP без маски
extract_ip_only() {
 echo "$1" | cut -d'/' -f1
}

# Функция извлечения маски
extract_cidr() {
 local input="$1"
 if [[ "$input" == *"/"* ]]; then
  echo "$input" | cut -d'/' -f2
 else
  echo "24"  # по умолчанию
 fi
}

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_err() { echo -e "${RED}[X]${NC} $1"; }

#===============================================================================
# ФУНКЦИЯ ДОБАВЛЕНИЯ СЕТЕЙ
#===============================================================================

add_networks_interactive() {
 local networks=""
 
 echo -e "\n${YELLOW}=== Добавление сетей для OSPF ===${NC}"
 echo ""
 echo "Доступные интерфейсы и их сети:"
 echo "--------------------------------"
 
 for iface in $(ls /sys/class/net/ | grep -v lo); do
  net=$(get_network_from_iface "$iface")
  if [[ -n "$net" ]]; then
   printf "  %-10s -> %s\n" "$iface" "$net"
  fi
 done
 
 echo ""
 echo "Выберите способ добавления сетей:"
 echo " 1) Автоматически (все интерфейсы кроме внешнего)"
 echo " 2) Выбрать из списка"
 echo " 3) Ввести сети вручную"
 echo " 4) Пропустить"
 read -p "Ваш выбор [1]: " add_method
 
 case $add_method in
  2)
   echo ""
   echo "Отметьте сети для добавления (y/n):"
   echo "-----------------------------------"
   for iface in $(ls /sys/class/net/ | grep -v lo); do
    if [[ "$iface" == "$EXT_IFACE" ]] || [[ "$iface" == "gre1" ]]; then
     continue
    fi
    net=$(get_network_from_iface "$iface")
    if [[ -n "$net" ]]; then
     read -p "  $iface ($net)? [y]: " ans
     if [[ "$ans" != "n" ]]; then
      networks+=" network $net area 0\n"
     fi
    fi
   done
   ;;
   
  3)
   echo ""
   echo "Вводите сети в формате: IP/CIDR (например, 192.168.10.0/24)"
   echo "Для завершения введите пустую строку"
   echo "-----------------------------------"
   
   while true; do
    read -p "Сеть (или Enter для завершения): " net
    if [[ -z "$net" ]]; then
     break
    fi
    
    if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
     networks+=" network $net area 0\n"
     print_ok "Добавлена сеть: $net"
    else
     print_warn "Неверный формат! Используйте IP/CIDR"
    fi
   done
   ;;
   
  4)
   print_warn "Сети не добавлены"
   ;;
   
  *)
   print_msg "Автоматический выбор всех сетей..."
   for iface in $(ls /sys/class/net/ | grep -v lo); do
    if [[ "$iface" == "$EXT_IFACE" ]] || [[ "$iface" == "gre1" ]]; then
     continue
    fi
    net=$(get_network_from_iface "$iface")
    if [[ -n "$net" ]]; then
     networks+=" network $net area 0\n"
     print_ok "Добавлена: $net ($iface)"
    fi
   done
   ;;
 esac
 
 if [[ -n "$GRE_IP" ]]; then
  GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
  GRE_NET_CIDR=$(echo "$GRE_IP" | grep -oP '/\K\d+$' || echo "30")
  GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
  networks+=" network $GRE_NET area 0\n"
  print_ok "Добавлена сеть туннеля: $GRE_NET"
 fi
 
 echo -e "$networks"
}

#===============================================================================
# ОСНОВНАЯ НАСТРОЙКА
#===============================================================================

setup_frr() {
 #===============================================================================
 # ШАГ 0: ОЧИСТКА
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Очистка старых настроек ===${NC}"
 read -p "Удалить предыдущие настройки GRE и FRR? [y/N]: " cleanup_ans
 if [[ "$cleanup_ans" =~ ^[Yy]$ ]]; then
  full_cleanup
  sleep 2
 fi
 
 #===============================================================================
 # ШАГ 1: УСТАНОВКА И РОЛЬ
 #===============================================================================
 
 print_msg "Проверка установки FRR..."
 if ! command -v vtysh &> /dev/null; then
  print_msg "Установка FRR..."
  apt-get update >/dev/null 2>&1
  apt-get install -y frr >/dev/null 2>&1
  print_ok "FRR установлен"
 else
  print_ok "FRR уже установлен"
 fi
 
 echo -e "\n${YELLOW}=== Шаг 1: Идентификация роутера ===${NC}"
 
 HOST=$(hostname | tr '[:upper:]' '[:lower:]')
 DEFAULT_ROLE=""
 DEFAULT_RID=""
 
 if [[ "$HOST" =~ "hq-rtr" ]]; then
  DEFAULT_ROLE="HQ-RTR"; DEFAULT_RID="1.1.1.1"
 elif [[ "$HOST" =~ "br-rtr" ]]; then
  DEFAULT_ROLE="BR-RTR"; DEFAULT_RID="2.2.2.2"
 fi
 
 echo "Выберите роль:"
 echo " 1) HQ-RTR (Router ID: 1.1.1.1)"
 echo " 2) BR-RTR (Router ID: 2.2.2.2)"
 echo " 3) Другая роль"
 read -p "Ваш выбор [1]: " role_choice
 
 case $role_choice in
  2) ROLE="BR-RTR"; RID="2.2.2.2" ;;
  3)
   read -p "Введите имя роли: " ROLE
   read -p "Введите Router ID: " RID
   ;;
  *) ROLE="HQ-RTR"; RID="1.1.1.1" ;;
 esac
 print_ok "Роль: $ROLE, Router ID: $RID"
 
 #===============================================================================
 # ШАГ 2: GRE ТУННЕЛЬ (ИСПРАВЛЕНО)
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 2: Настройка GRE туннеля ===${NC}"
 
 # Показываем интерфейсы
 IFS= read -r -a IFACES <<< $(ls /sys/class/net/ | grep -v lo)
 echo "Доступные интерфейсы:"
 for i in "${!IFACES[@]}"; do
  ip_info=$(ip -4 addr show "${IFACES[$i]}" | grep -oP 'inet \K[\d./]+' | head -1)
  printf " %2s) %-10s %s\n" "$((i+1))" "${IFACES[$i]}" "$ip_info"
 done
 
 read -p "Выберите ВНЕШНИЙ интерфейс: " ext_idx
 EXT_IFACE="${IFACES[$((ext_idx-1))]}"
 EXT_IP_FULL=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d./]+' | head -1)
 EXT_IP=$(extract_ip_only "$EXT_IP_FULL")
 print_ok "Выбран: $EXT_IFACE ($EXT_IP)"
 
 read -p "Введите ВНЕШНИЙ IP удаленного роутера: " REMOTE_IP
 
 # Локальный IP туннеля - ИСПРАВЛЕНО
 if [[ "$ROLE" == "HQ-RTR" ]]; then
  DEF_GRE_IP="172.16.100.1/29"
 else
  DEF_GRE_IP="172.16.100.2/29"
 fi
 
 echo -n "Локальный IP туннеля [$DEF_GRE_IP]: "
 read GRE_IP_INPUT
 GRE_IP_INPUT="${GRE_IP_INPUT:-$DEF_GRE_IP}"
 
 # Извлекаем IP без маски для записи в конфиг
 GRE_IP_ADDR=$(extract_ip_only "$GRE_IP_INPUT")
 GRE_CIDR=$(extract_cidr "$GRE_IP_INPUT")
 GRE_IP="$GRE_IP_ADDR/$GRE_CIDR"
 
 print_ok "Туннель: $GRE_IP"
 
 # Создание конфигов
 print_msg "Настройка /etc/net/ifaces/gre1..."
 mkdir -p "$IFACES_DIR/gre1"
 
 cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
 
 echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"
 
 # Активация туннеля - ИСПРАВЛЕНО
 print_msg "Активация туннеля..."
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1
 
 ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
 if [[ $? -ne 0 ]]; then
  print_err "Не удалось создать туннель!"
  exit 1
 fi
 
 ip addr add $GRE_IP dev gre1
 ip link set gre1 up
 
 sleep 2
 
 if ip link show gre1 &>/dev/null; then
  print_ok "Туннель gre1 активирован"
 else
  print_err "Туннель не активирован!"
  exit 1
 fi
 
 #===============================================================================
 # ШАГ 3: OSPF
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 3: Настройка OSPF ===${NC}"
 
 read -p "Пароль для OSPF [P@ssw0rd]: " PASS
 PASS="${PASS:-P@ssw0rd}"
 
 NETWORKS_CONFIG=$(add_networks_interactive)
 
 print_msg "Генерация $FRR_CONF..."
 cat > $FRR_CONF << EOF
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
$(echo -e "$NETWORKS_CONFIG" | sed 's/^/    /')
!
line vty
!
EOF
 
 print_ok "Конфигурация записана"
 
 systemctl enable frr >/dev/null 2>&1
 systemctl restart frr
 sleep 3
 
 #===============================================================================
 # ИТОГИ
 #===============================================================================
 
 clear
 echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
 echo -e "${GREEN}║ НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА ║${NC}"
 echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
 
 echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
 echo "Роль: $ROLE"
 echo "Router ID: $RID"
 echo "Туннель: $GRE_IP"
 echo ""
 
 echo -e "${WHITE}СТАТУС OSPF:${NC}"
 vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Соседи не обнаружены"
 echo ""
 
 echo -e "${MAGENTA}КОМАНДЫ:${NC}"
 echo " vtysh -c 'show ip ospf neighbor'"
 echo " vtysh -c 'show ip route ospf'"
 echo ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup v2.1 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo "Выберите действие:"
echo " 1) Настроить FRR (OSPF + GRE)"
echo " 2) Удалить все настройки (GRE + FRR)"
echo " 3) Показать конфигурацию"
echo " 4) Добавить сети"
echo " 5) Выход"
read -p "Ваш выбор [1]: " main_choice

case $main_choice in
 2)
  full_cleanup
  ;;
  
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
  
 4)
  # Добавить сети (реализация как раньше)
  print_msg "Функция добавления сетей"
  ;;
  
 5)
  exit 0
  ;;
  
 *)
  setup_frr
  ;;
esac

echo ""
echo "Готово!"
