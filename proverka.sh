#!/bin/bash
#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# Версия 2.0 - С возможностью добавления сетей
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
 
 # Показываем все интерфейсы
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
 echo " 4) Пропустить (добавлю позже)"
 read -p "Ваш выбор [1]: " add_method
 
 case $add_method in
  2)
   # Выбор из списка
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
   # Ручной ввод
   echo ""
   echo "Вводите сети в формате: IP/CIDR (например, 192.168.10.0/24)"
   echo "Для завершения введите пустую строку"
   echo "-----------------------------------"
   
   while true; do
    read -p "Сеть (или Enter для завершения): " net
    if [[ -z "$net" ]]; then
     break
    fi
    
    # Проверка формата
    if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
     networks+=" network $net area 0\n"
     print_ok "Добавлена сеть: $net"
    else
     print_warn "Неверный формат! Используйте IP/CIDR (например, 192.168.10.0/24)"
    fi
   done
   ;;
   
  4)
   print_warn "Сети не добавлены"
   ;;
   
  *)
   # Автоматически
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
 
 # Всегда добавляем сеть туннеля GRE
 if [[ -n "$GRE_IP" ]]; then
  GRE_NET_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
  GRE_NET_CIDR=$(echo "$GRE_IP" | cut -d'/' -f2)
  GRE_NET="${GRE_NET_BASE}.0/${GRE_NET_CIDR}"
  networks+=" network $GRE_NET area 0\n"
  print_ok "Добавлена сеть туннеля: $GRE_NET"
 fi
 
 echo -e "$networks"
}

#===============================================================================
# ФУНКЦИЯ ДОБАВЛЕНИЯ СЕТЕЙ ПОСЛЕ НАСТРОЙКИ
#===============================================================================

add_network_after_setup() {
 if [[ ! -f "$FRR_CONF" ]]; then
  print_err "FRR не настроен! Сначала выполните полную настройку."
  return 1
 fi
 
 echo -e "\n${YELLOW}=== Добавление новых сетей в OSPF ===${NC}"
 
 # Показываем текущие сети
 echo ""
 echo "Текущие сети в OSPF:"
 grep "network.*area" "$FRR_CONF" | sed 's/^/  /'
 
 echo ""
 echo "Добавление новых сетей:"
 echo "----------------------"
 
 # Читаем текущий конфиг
 current_config=$(cat "$FRR_CONF")
 
 # Добавляем новые сети
 while true; do
  read -p "Введите сеть (IP/CIDR) или 'q' для выхода: " net
  
  if [[ "$net" == "q" ]]; then
   break
  fi
  
  if [[ -z "$net" ]]; then
   continue
  fi
  
  # Проверка формата
  if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
   # Проверяем, есть ли уже такая сеть
   if grep -q "network $net area" "$FRR_CONF"; then
    print_warn "Сеть $net уже существует!"
   else
    # Добавляем сеть в конфиг
    sed -i "/router ospf/a\\    network $net area 0" "$FRR_CONF"
    print_ok "Сеть $net добавлена"
   fi
  else
   print_warn "Неверный формат!"
  fi
 done
 
 # Перезапускаем FRR
 print_msg "Применение изменений..."
 systemctl restart frr
 print_ok "FRR перезапущен"
 
 # Показываем обновлённый конфиг
 echo ""
 echo "Обновлённая конфигурация OSPF:"
 grep -A20 "router ospf" "$FRR_CONF"
}

#===============================================================================
# ОСНОВНАЯ НАСТРОЙКА
#===============================================================================

setup_frr() {
 # Установка
 print_msg "Установка пакетов..."
 apt-get update >/dev/null 2>&1
 apt-get install -y frr >/dev/null 2>&1
 print_ok "FRR установлен"
 
 #===============================================================================
 # ШАГ 1: РОЛЬ И ROUTER ID
 #===============================================================================
 
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
 echo " 3) Другая роль / Ввести Router ID вручную"
 read -p "Ваш выбор [1]: " role_choice
 
 case $role_choice in
  2) ROLE="BR-RTR"; RID="2.2.2.2" ;;
  3)
   read -p "Введите имя роли (например, ISP): " ROLE
   read -p "Введите Router ID (например, 3.3.3.3): " RID
   ;;
  *) ROLE="HQ-RTR"; RID="1.1.1.1" ;;
 esac
 print_ok "Роль: $ROLE, Router ID: $RID"
 
 #===============================================================================
 # ШАГ 2: НАСТРОЙКА GRE
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 2: Настройка GRE туннеля ===${NC}"
 
 # Выбор внешнего интерфейса
 IFS= read -r -a IFACES <<< $(ls /sys/class/net/ | grep -v lo)
 echo "Доступные интерфейсы:"
 for i in "${!IFACES[@]}"; do
  ip=$(ip -4 addr show "${IFACES[$i]}" | grep -oP 'inet \K[\d./]+' | head -1)
  printf " %2s) %-10s %s\n" "$((i+1))" "${IFACES[$i]}" "$ip"
 done
 
 read -p "Выберите ВНЕШНИЙ интерфейс: " ext_idx
 EXT_IFACE="${IFACES[$((ext_idx-1))]}"
 EXT_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP 'inet \K[\d./]+' | head -1)
 print_ok "Выбран внешний интерфейс: $EXT_IFACE ($EXT_IP)"
 
 read -p "Введите ВНЕШНИЙ IP удаленного роутера: " REMOTE_IP
 
 # Настройка IP туннеля
 if [[ "$ROLE" == "HQ-RTR" ]]; then
  DEF_GRE_IP="172.16.100.1/29"
 else
  DEF_GRE_IP="172.16.100.2/29"
 fi
 
 read -p "Локальный IP туннеля [$DEF_GRE_IP]: " GRE_IP
 GRE_IP="${GRE_IP:-$DEF_GRE_IP}"
 
 # Создание конфигов GRE
 print_msg "Настройка /etc/net/ifaces/gre1..."
 mkdir -p "$IFACES_DIR/gre1"
 cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
 
 echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"
 
 # Активация
 ip tunnel del gre1 2>/dev/null
 ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
 ip addr add $GRE_IP dev gre1
 ip link set gre1 up
 print_ok "Туннель gre1 активирован"
 
 #===============================================================================
 # ШАГ 3: НАСТРОЙКА OSPF С ДОБАВЛЕНИЕМ СЕТЕЙ
 #===============================================================================
 
 echo -e "\n${YELLOW}=== Шаг 3: Настройка OSPF ===${NC}"
 
 read -p "Пароль для OSPF аутентификации [P@ssw0rd]: " PASS
 PASS="${PASS:-P@ssw0rd}"
 
 # Добавление сетей через функцию
 NETWORKS_CONFIG=$(add_networks_interactive)
 
 # Запись конфига FRR
 print_msg "Генерация /etc/frr/frr.conf..."
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
 
 print_ok "Конфигурация FRR записана"
 
 # Включение и запуск
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
 
 echo -e "${WHITE}ТЕКУЩИЙ СТАТУС OSPF:${NC}"
 vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Соседи пока не обнаружены"
 echo ""
 
 echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
 echo -e "${MAGENTA}║ ГЛАВНЫЕ КОМАНДЫ ║${NC}"
 echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
 
 echo -e "${CYAN}1. Просмотр соседей OSPF:${NC}"
 echo " vtysh -c 'show ip ospf neighbor'"
 echo ""
 
 echo -e "${CYAN}2. Просмотр OSPF маршрутов:${NC}"
 echo " vtysh -c 'show ip route ospf'"
 echo ""
 
 echo -e "${CYAN}3. Добавить сеть после настройки:${NC}"
 echo " Запустите скрипт и выберите пункт 5"
 echo ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup v2.0 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo "Выберите действие:"
echo " 1) Настроить FRR (OSPF + GRE)"
echo " 2) Удалить прошлые настройки"
echo " 3) Показать текущую конфигурацию"
echo " 4) Добавить сети в существующую конфигурацию"
echo " 5) Выход"
read -p "Ваш выбор [1]: " main_choice

case $main_choice in
 2)
  # Удаление (оставляем как было)
  echo "Удаление настроек..."
  ip link set gre1 down 2>/dev/null
  ip tunnel del gre1 2>/dev/null
  rm -rf "$IFACES_DIR/gre1"
  systemctl restart frr
  print_ok "Настройки удалены"
  ;;
  
 3)
  # Показать конфигурацию
  echo -e "\n${WHITE}=== Текущая конфигурация ===${NC}"
  
  echo -e "\n${CYAN}GRE туннели:${NC}"
  ip link show | grep -E "gre[0-9]+" || echo " Нет активных GRE туннелей"
  
  echo -e "\n${CYAN}Конфигурация FRR (OSPF):${NC}"
  if [[ -f "$FRR_CONF" ]]; then
   grep -A20 "router ospf" "$FRR_CONF" 2>/dev/null || echo " OSPF не настроен"
  else
   echo " Файл $FRR_CONF не найден"
  fi
  
  echo -e "\n${CYAN}OSPF соседи:${NC}"
  vtysh -c "show ip ospf neighbor" 2>/dev/null || echo " OSPF не активен"
  ;;
  
 4)
  # Добавить сети
  add_network_after_setup
  ;;
  
 5)
  echo "Выход..."
  exit 0
  ;;
  
 *)
  setup_frr
  ;;
esac

echo ""
echo "Готово!"
