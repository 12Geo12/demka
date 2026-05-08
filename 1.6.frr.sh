#!/bin/bash
#===============================================================================
# ИДЕАЛЬНЫЙ СКРИПТ НАСТРОЙКИ FRR (OSPF + GRE) ДЛЯ ALT LINUX
# Версия 3.2 - ИСПРАВЛЕНО: полная персистентность + ручной ввод сетей
#
# КЛЮЧЕВЫЕ ИСПРАВЛЕНИЯ v3.2:
#   1) ospfd=yes в /etc/frr/daemons — OSPF демон стартует после ребута
#   2) DISABLE=no + BOOTPROTO=static в /etc/net/ifaces/gre1/options —
#      etcnet поднимает GRE туннель при загрузке
#   3) systemctl enable net — сетевая служба включена автозапуском
#   4) Корректный формат ipv4address для etcnet
#   5) ИСПРАВЛЕНО: меню выбора сетей видно на экране (stderr)
#   6) ТОЛЬКО ручной ввод сетей — никакого автоопределения
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
FRR_DAEMONS="/etc/frr/daemons"
BACKUP_DIR="/root/frr_backups"

# Проверка ROOT
if [[ $EUID -ne 0 ]]; then
 echo -e "${RED}Ошибка: Запустите от root${NC}"
 exit 1
fi

# Функция очистки GRE туннеля
cleanup_gre() {
 print_msg "Очистка старых настроек GRE..."

 # Удаляем туннель runtime
 ip link set gre1 down 2>/dev/null
 sleep 1
 ip tunnel del gre1 2>/dev/null
 sleep 1

 # Удаляем конфиги etcnet
 rm -rf "$IFACES_DIR/gre1" 2>/dev/null

 # Отключаем автозапуск сети (если нужно)
 # systemctl disable net 2>/dev/null || true

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

 # Сброс frr.conf к дефолту
 cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
line vty
!
EOF

 # Отключаем ospfd в daemons
 if [[ -f "$FRR_DAEMONS" ]]; then
  sed -i 's/^ospfd=yes/ospfd=no/' "$FRR_DAEMONS"
  sed -i 's/^ospf6d=yes/ospf6d=no/' "$FRR_DAEMONS"
 fi

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

add_networks_manual() {
 local networks=""

 # Все информационные выводы направляем в stderr (>&2),
 # чтобы они не перехватывались подстановкой $(...)
 # В stdout — ТОЛЬКО финальный список сетей

 echo -e "\n${YELLOW}=== Добавление сетей для OSPF ===${NC}" >&2
 echo "" >&2
 echo "Вводите сети для OSPF в формате: IP/CIDR" >&2
 echo "Пример: 192.168.10.0/24" >&2
 echo "Для завершения введите пустую строку" >&2
 echo "-----------------------------------" >&2

 while true; do
  read -p "Сеть (Enter = готово): " net
  if [[ -z "$net" ]]; then
   break
  fi

  if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
   networks+=" network $net area 0\n"
   print_ok "Добавлена: $net" >&2
  else
   print_warn "Неверный формат! Используйте IP/CIDR (например, 192.168.10.0/24)" >&2
  fi
 done

 if [[ -z "$networks" ]]; then
  print_warn "Сети не добавлены" >&2
 fi

 # Только это идёт в stdout (перехватывается $())
 echo -e "$networks"
}

#===============================================================================
# ФУНКЦИЯ ВКЛЮЧЕНИЯ OSPF В DAEMONS (КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ #1)
#===============================================================================

enable_ospf_daemon() {
 print_msg "Настройка /etc/frr/daemons для автозапуска OSPF..."

 if [[ ! -f "$FRR_DAEMONS" ]]; then
  # Если файл daemons не существует, создаём минимальный
  cat > "$FRR_DAEMONS" << 'DAEMONSEOF'
# This file tells the frr package which daemons to start.
# Entries are in the format: <daemon>=<yes|no>
zebra=yes
bgpd=no
ospfd=yes
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
DAEMONSEOF
  print_ok "Файл daemons создан с ospfd=yes"
 else
  # Файл существует — включаем ospfd
  if grep -q '^ospfd=' "$FRR_DAEMONS"; then
   sed -i 's/^ospfd=.*/ospfd=yes/' "$FRR_DAEMONS"
  else
   echo "ospfd=yes" >> "$FRR_DAEMONS"
  fi

  # Также гарантируем, что zebra включена
  if grep -q '^zebra=' "$FRR_DAEMONS"; then
   sed -i 's/^zebra=.*/zebra=yes/' "$FRR_DAEMONS"
  else
   echo "zebra=yes" >> "$FRR_DAEMONS"
  fi

  print_ok "ospfd=yes и zebra=yes установлены в $FRR_DAEMONS"
 fi
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
 # ШАГ 2: GRE ТУННЕЛЬ (ИСПРАВЛЕНО ДЛЯ ПЕРСИСТЕНТНОСТИ)
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

 # Локальный IP туннеля
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

 #===========================================================================
 # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ #2: Правильный конфиг etcnet для Alt Linux
 # Добавлены DISABLE=no и BOOTPROTO=static для автоподнятия при загрузке
 #===========================================================================

 print_msg "Настройка /etc/net/ifaces/gre1 (персистентный конфиг)..."
 mkdir -p "$IFACES_DIR/gre1"

 cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
DISABLE=no
BOOTPROTO=static
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF

 # ipv4address — только IP/маска, без лишних данных
 echo "$GRE_IP" > "$IFACES_DIR/gre1/ipv4address"

 print_ok "Конфиг etcnet для gre1 записан (DISABLE=no)"

 # Активация туннеля (runtime — для текущей сессии)
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

 NETWORKS_CONFIG=$(add_networks_manual)

 #---------------------------------------------------------------
 # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ #1: Включаем ospfd в /etc/frr/daemons
 #---------------------------------------------------------------
 enable_ospf_daemon

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

 #---------------------------------------------------------------
 # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ #3: Включаем автозапуск служб
 #---------------------------------------------------------------
 print_msg "Включение автозапуска служб..."

 # FRR — автозапуск демона маршрутизации
 systemctl enable frr >/dev/null 2>&1
 print_ok "frr добавлен в автозапуск"

 # net — автозапуск сети (поднимает gre1 через etcnet)
 systemctl enable net >/dev/null 2>&1
 print_ok "net добавлен в автозапуск"

 # Перезапускаем FRR для применения конфигурации
 systemctl restart frr
 sleep 3

 #===============================================================================
 # ИТОГИ
 #===============================================================================

 clear
 echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
 echo -e "${GREEN}║ НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА                            ║${NC}"
 echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

 echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
 echo "Роль: $ROLE"
 echo "Router ID: $RID"
 echo "Туннель: $GRE_IP"
 echo ""

 echo -e "${WHITE}ПРОВЕРКА ПЕРСИСТЕНТНОСТИ:${NC}"
 # Проверяем что службы включены
 if systemctl is-enabled frr &>/dev/null; then
  echo -e "  ${GREEN}[OK]${NC} frr — автозапуск включён"
 else
  echo -e "  ${RED}[!!]${NC} frr — автозапуск НЕ включён"
 fi
 if systemctl is-enabled net &>/dev/null; then
  echo -e "  ${GREEN}[OK]${NC} net — автозапуск включён"
 else
  echo -e "  ${RED}[!!]${NC} net — автозапуск НЕ включён"
 fi
 # Проверяем ospfd в daemons
 if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
  echo -e "  ${GREEN}[OK]${NC} ospfd=yes в $FRR_DAEMONS"
 else
  echo -e "  ${RED}[!!]${NC} ospfd не включён в $FRR_DAEMONS"
 fi
 # Проверяем DISABLE=no в gre1/options
 if grep -q 'DISABLE=no' "$IFACES_DIR/gre1/options" 2>/dev/null; then
  echo -e "  ${GREEN}[OK]${NC} gre1: DISABLE=no (поднимется при загрузке)"
 else
  echo -e "  ${RED}[!!]${NC} gre1: DISABLE не установлен"
 fi
 echo ""

 echo -e "${WHITE}СТАТУС OSPF:${NC}"
 vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Соседи не обнаружены"
 echo ""

 echo -e "${MAGENTA}КОМАНДЫ ДЛЯ ПРОВЕРКИ:${NC}"
 echo " vtysh -c 'show ip ospf neighbor'"
 echo " vtysh -c 'show ip route ospf'"
 echo " ip link show gre1"
 echo " systemctl status frr"
 echo ""
 echo -e "${CYAN}ДИАГНОСТИКА ПОСЛЕ ПЕРЕЗАГРУЗКИ:${NC}"
 echo " Перезагрузитесь и выполните:"
 echo "   systemctl status frr"
 echo "   ip link show gre1"
 echo "   vtysh -c 'show ip ospf neighbor'"
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup v3.2 (персистентный)               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo "Выберите действие:"
echo " 1) Настроить FRR (OSPF + GRE)"
echo " 2) Удалить все настройки (GRE + FRR)"
echo " 3) Показать конфигурацию"
echo " 4) Показать статус персистентности"
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
  echo -e "\n${WHITE}=== ПРОВЕРКА ПЕРСИСТЕНТНОСТИ ===${NC}"

  # FRR service
  if systemctl is-enabled frr &>/dev/null; then
   echo -e "  ${GREEN}[OK]${NC} frr — автозапуск включён"
  else
   echo -e "  ${RED}[!!]${NC} frr — автозапуск НЕ включён -> systemctl enable frr"
  fi

  # net service
  if systemctl is-enabled net &>/dev/null; then
   echo -e "  ${GREEN}[OK]${NC} net — автозапуск включён"
  else
   echo -e "  ${RED}[!!]${NC} net — автозапуск НЕ включён -> systemctl enable net"
  fi

  # ospfd daemon
  if grep -q '^ospfd=yes' "$FRR_DAEMONS" 2>/dev/null; then
   echo -e "  ${GREEN}[OK]${NC} ospfd=yes в $FRR_DAEMONS"
  else
   echo -e "  ${RED}[!!]${NC} ospfd не включён -> добавить ospfd=yes в $FRR_DAEMONS"
  fi

  # zebra daemon
  if grep -q '^zebra=yes' "$FRR_DAEMONS" 2>/dev/null; then
   echo -e "  ${GREEN}[OK]${NC} zebra=yes в $FRR_DAEMONS"
  else
   echo -e "  ${RED}[!!]${NC} zebra не включена -> добавить zebra=yes в $FRR_DAEMONS"
  fi

  # gre1 etcnet
  if [[ -d "$IFACES_DIR/gre1" ]]; then
   echo -e "  ${GREEN}[OK]${NC} $IFACES_DIR/gre1 — каталог существует"
   if grep -q 'DISABLE=no' "$IFACES_DIR/gre1/options" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} gre1/options: DISABLE=no"
   else
    echo -e "  ${RED}[!!]${NC} gre1/options: DISABLE=no не найден -> туннель НЕ поднимется при загрузке"
   fi
   if grep -q 'BOOTPROTO=static' "$IFACES_DIR/gre1/options" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} gre1/options: BOOTPROTO=static"
   else
    echo -e "  ${YELLOW}[!]${NC} gre1/options: BOOTPROTO=static не указан"
   fi
   if [[ -f "$IFACES_DIR/gre1/ipv4address" ]]; then
    echo -e "  ${GREEN}[OK]${NC} gre1/ipv4address: $(cat $IFACES_DIR/gre1/ipv4address)"
   else
    echo -e "  ${RED}[!!]${NC} gre1/ipv4address — файл не найден"
   fi
  else
   echo -e "  ${RED}[!!]${NC} $IFACES_DIR/gre1 — каталог не существует -> GRE не настроен"
  fi

  # FRR config
  if [[ -f "$FRR_CONF" ]]; then
   echo -e "  ${GREEN}[OK]${NC} $FRR_CONF — существует"
   if grep -q 'router ospf' "$FRR_CONF"; then
    echo -e "  ${GREEN}[OK]${NC} Секция 'router ospf' найдена"
   else
    echo -e "  ${RED}[!!]${NC} Секция 'router ospf' не найдена"
   fi
  else
   echo -e "  ${RED}[!!]${NC} $FRR_CONF — не существует"
  fi
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
