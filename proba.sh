#!/bin/bash
#===============================================================================
# FRR OSPF/GRE Setup - FINAL FIXED VERSION
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

IFACES_DIR="/etc/net/ifaces"
FRR_CONF="/etc/frr/frr.conf"
GRE_CONFIG="/etc/sysconfig/gre1"
RC_LOCAL="/etc/rc.d/rc.local"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Запустите от root${NC}"
   exit 1
fi

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_err() { echo -e "${RED}[X]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

full_cleanup() {
   print_msg "Очистка старых настроек..."
   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1
   rm -rf "$IFACES_DIR/gre1" 2>/dev/null
   rm -f "$GRE_CONFIG" 2>/dev/null
   
   if [[ -f "$RC_LOCAL" ]]; then
      sed -i '/# GRE tunnel/,/ip link set gre1 up/d' "$RC_LOCAL" 2>/dev/null || true
   fi
   
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
   echo -e "\n${YELLOW}Очистить старые настройки? [Y/n]:${NC} "
   read -r cleanup_ans
   if [[ ! "$cleanup_ans" =~ ^[Nn]$ ]]; then
      full_cleanup
      sleep 1
   fi

   if ! command -v vtysh &>/dev/null; then
      print_msg "Установка FRR..."
      apt-get update >/dev/null 2>&1
      apt-get install -y frr >/dev/null 2>&1
      print_ok "FRR установлен"
   fi

   HOST=$(hostname | tr '[:upper:]' '[:lower:]')
   if [[ "$HOST" =~ "hq-rtr" ]]; then
      ROLE="HQ-RTR"; RID="1.1.1.1"; DEFAULT_GRE_IP="192.168.100.1"
   elif [[ "$HOST" =~ "br-rtr" ]]; then
      ROLE="BR-RTR"; RID="2.2.2.2"; DEFAULT_GRE_IP="192.168.100.2"
   else
      ROLE="HQ-RTR"; RID="1.1.1.1"; DEFAULT_GRE_IP="192.168.100.1"
   fi
   print_ok "Роль: $ROLE, Router ID: $RID"

   echo -e "\n${YELLOW}=== ДОСТУПНЫЕ ИНТЕРФЕЙСЫ ===${NC}"
   i=1
   declare -a IFACE_LIST
   declare -a IFACE_IPS
   declare -a IFACE_IPS_ONLY
   
   for iface in $(ls /sys/class/net/ | grep -v lo); do
      ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
      ip_only=$(echo "$ip_info" | cut -d'/' -f1)
      if [[ -n "$ip_info" ]]; then
         printf " ${YELLOW}%d)${NC} %-10s ${WHITE}%s${NC}\n" "$i" "$iface" "$ip_info"
         IFACE_LIST+=("$iface")
         IFACE_IPS+=("$ip_info")
         IFACE_IPS_ONLY+=("$ip_only")
         ((i++))
      fi
   done

   echo ""
   read -p "${YELLOW}Внешний интерфейс (номер):${NC} " ext_idx
   EXT_IFACE="${IFACE_LIST[$((ext_idx-1))]}"
   EXT_IP="${IFACE_IPS_ONLY[$((ext_idx-1))]}"
   EXT_IP_FULL="${IFACE_IPS[$((ext_idx-1))]}"
   print_ok "Выбран: $EXT_IFACE ($EXT_IP_FULL)"

   echo ""
   read -p "${YELLOW}Внешний IP удалённого роутера:${NC} " REMOTE_IP
   print_ok "Удалённый IP: $REMOTE_IP"

   echo ""
   read -p "${YELLOW}Локальный IP туннеля [${DEFAULT_GRE_IP}]:${NC} " GRE_INPUT
   GRE_IP="${GRE_INPUT:-$DEFAULT_GRE_IP}"
   print_ok "Туннель: $GRE_IP"

   if [[ "$ROLE" == "HQ-RTR" ]]; then
      REMOTE_GRE_IP="192.168.100.2"
   else
      REMOTE_GRE_IP="192.168.100.1"
   fi

   print_msg "Настройка GRE туннеля..."
   mkdir -p "$IFACES_DIR/gre1"

   cat > "$IFACES_DIR/gre1/options" << EOF
TYPE=gre
REMOTE_ADDRESS=$REMOTE_IP
LOCAL_ADDRESS=$EXT_IP
TTL=64
EOF
   echo "$GRE_IP/29" > "$IFACES_DIR/gre1/ipv4address"

   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1

   print_msg "Создание туннеля..."
   if ! ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64; then
      print_err "Не удалось создать туннель!"
      exit 1
   fi

   if ! ip addr add "$GRE_IP/29" dev gre1; then
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

   print_msg "Сохранение конфигурации для автозагрузки..."
   
   cat > "$GRE_CONFIG" << EOF
# GRE Tunnel Configuration
GRE_LOCAL_IP="$EXT_IP"
GRE_REMOTE_IP="$REMOTE_IP"
GRE_TUNNEL_IP="$GRE_IP"
GRE_TUNNEL_NET="29"
GRE_TTL=64
EOF
   chmod 644 "$GRE_CONFIG"
   
   if [[ ! -f "$RC_LOCAL" ]]; then
      touch "$RC_LOCAL"
      chmod +x "$RC_LOCAL"
   fi
   
   sed -i '/# GRE tunnel/,/ip link set gre1 up/d' "$RC_LOCAL" 2>/dev/null || true
   
   cat >> "$RC_LOCAL" << EOF

# GRE tunnel configuration
ip tunnel del gre1 2>/dev/null || true
sleep 2
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
ip addr add $GRE_IP/29 dev gre1
ip link set gre1 up
sleep 2

EOF

   chmod +x "$RC_LOCAL"
   print_ok "Конфигурация GRE сохранена"

   if ip link show gre1 &>/dev/null; then
      print_ok "✓ Туннель gre1 активирован"
      if ping -c 2 "$REMOTE_GRE_IP" &>/dev/null; then
         print_ok "✓ Туннель работает (ping прошёл)"
      else
         print_warn "⚠ Туннель создан, но ping не проходит"
      fi
   else
      print_err "Туннель не активен!"
      exit 1
   fi

   echo ""
   echo -e "${YELLOW}=== ДОБАВЛЕНИЕ СЕТЕЙ ДЛЯ OSPF ===${NC}"
   echo "Вводите сети в формате: IP/CIDR"
   echo "Примеры: 192.168.10.0/26, 192.168.4.0/28"
   echo "Для завершения нажмите Enter"
   echo "=========================================="

   NETWORKS=""
   NETWORK_COUNT=0

   while true; do
      read -p "Сеть: " net

      if [[ -z "$net" ]]; then
         break
      fi

      if [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
         NETWORKS+=" network $net area 0"$'\n'
         ((NETWORK_COUNT++))
         print_ok "Добавлена: $net"
      else
         print_err "Неверный формат! Используйте IP/CIDR"
      fi
   done

   if [[ $NETWORK_COUNT -eq 0 ]]; then
      GRE_NET="${GRE_IP}.0/29"
      NETWORKS=" network $GRE_NET area 0"$'\n'
      
      for idx in "${!IFACE_LIST[@]}"; do
         iface="${IFACE_LIST[$idx]}"
         if [[ "$iface" != "$EXT_IFACE" && "$iface" != "lo" ]]; then
            local_net_full="${IFACE_IPS[$idx]}"
            NETWORKS+=" network $local_net_full area 0"$'\n'
            print_ok "Автодобавлена: $local_net_full ($iface)"
         fi
      done
   fi

   echo ""
   read -p "${YELLOW}Пароль OSPF [P@ssw0rd]:${NC} " PASS
   PASS="${PASS:-P@ssw0rd}"

   echo ""
   echo -e "${YELLOW}=== БУДЕТ ЗАПИСАНО В КОНФИГ ===${NC}"
   echo "router ospf"
   echo " ospf router-id $RID"
   echo " passive-interface default"
   echo " no passive-interface gre1"
   echo " area 0 authentication message-digest"
   echo "interface gre1"
   echo " ip ospf authentication message-digest"
   echo " ip ospf message-digest-key 1 md5 $PASS"
   echo "$NETWORKS"

   read -p "Записать конфиг? [Y/n]: " write_ans
   if [[ "$write_ans" =~ ^[Nn]$ ]]; then
      print_err "Отменено!"
      exit 1
   fi

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
 area 0 authentication message-digest
$NETWORKS!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $PASS
!
line vty
!
EOF

   print_ok "Конфигурация записана"

   echo -e "\n${YELLOW}=== ФИНАЛЬНЫЙ КОНФИГ ===${NC}"
   cat "$FRR_CONF"

   print_msg "Включение IP forwarding..."
   sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
   if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
      echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
   fi
   print_ok "IP forwarding включён"

   systemctl enable frr >/dev/null 2>&1
   systemctl restart frr
   sleep 5

   clear
   echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
   echo -e "${GREEN}║ ✅ НАСТРОЙКА ЗАВЕРШЕНА                                    ║${NC}"
   echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
   echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
   echo " Роль: $ROLE"
   echo " Router ID: $RID"
   echo " Туннель: $GRE_IP/29"
   echo " Удалённый туннель: $REMOTE_GRE_IP"
   echo ""
   echo -e "${WHITE}OSPF СОСЕДИ:${NC}"
   vtysh -c "show ip ospf neighbor" 2>/dev/null || echo " Пока нет соседей"
   echo ""
   echo -e "${WHITE}OSPF МАРШРУТЫ:${NC}"
   vtysh -c "show ip route ospf" 2>/dev/null | head -20 || echo " Пока нет маршрутов"
   echo ""
   echo -e "${WHITE}ТАБЛИЦА МАРШРУТИЗАЦИИ:${NC}"
   ip route show | head -10
   echo ""
   echo -e "${MAGENTA}КОМАНДЫ:${NC}"
   echo " vtysh -c 'show ip ospf neighbor'"
   echo " vtysh -c 'show ip route ospf'"
   echo " ping $REMOTE_GRE_IP"
   echo ""
   echo -e "${YELLOW}ВАЖНО:${NC}"
   echo " ✓ GRE туннель настроен для автозагрузки"
   echo " ✓ Аутентификация OSPF на интерфейсе gre1"
   echo ""
}

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE Setup - FINAL VERSION                       ║${NC}"
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
      grep -A30 "router ospf" "$FRR_CONF" 2>/dev/null || echo "OSPF не настроен"
   fi
   echo -e "\n${WHITE}=== OSPF соседи ===${NC}"
   vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "OSPF не активен"
   echo -e "\n${WHITE}=== OSPF маршруты ===${NC}"
   vtysh -c "show ip route ospf" 2>/dev/null | head -15 || echo "Нет маршрутов"
   echo -e "\n${WHITE}=== Таблица маршрутизации ===${NC}"
   ip route show | head -15
   echo -e "\n${WHITE}=== Автозапуск GRE ===${NC}"
   if [[ -f "$RC_LOCAL" ]]; then
      grep -A6 "# GRE tunnel" "$RC_LOCAL" 2>/dev/null || echo "Не настроен"
   else
      echo "rc.local не существует"
   fi
   ;;
 4) exit 0 ;;
 *) setup_frr ;;
esac

echo -e "\n${GREEN}Готово!${NC}"
