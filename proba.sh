#!/bin/bash
#===============================================================================
# FRR OSPF/GRE Setup - UNIVERSAL EXAM VERSION
# Автоматическая настройка для любых IP адресов
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

FRR_CONF="/etc/frr/frr.conf"
RC_LOCAL="/etc/rc.d/rc.local"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Запустите от root${NC}"
   exit 1
fi

print_msg() { echo -e "${CYAN}[i]${NC} $1"; }
print_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
print_err() { echo -e "${RED}[✗]${NC} $1"; }

full_cleanup() {
   print_msg "Очистка настроек..."
   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1
   
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
   echo -e "\n${YELLOW}Очистить старые настройки? [Y/n]:${NC} "
   read -r cleanup_ans
   [[ ! "$cleanup_ans" =~ ^[Nn]$ ]] && full_cleanup && sleep 1

   # Установка FRR
   if ! command -v vtysh &>/dev/null; then
      print_msg "Установка FRR..."
      apt-get update >/dev/null 2>&1
      apt-get install -y frr >/dev/null 2>&1
      print_ok "FRR установлен"
   fi

   # Определение роли
   HOST=$(hostname | tr '[:upper:]' '[:lower:]')
   if [[ "$HOST" =~ "hq" ]]; then
      ROLE="HQ"; RID="1.1.1.1"; PEER_ROLE="BR"
   elif [[ "$HOST" =~ "br" ]]; then
      ROLE="BR"; RID="2.2.2.2"; PEER_ROLE="HQ"
   else
      ROLE="HQ"; RID="1.1.1.1"; PEER_ROLE="BR"
   fi
   print_ok "Роль: $ROLE, Router ID: $RID"

   # Показ интерфейсов
   echo -e "\n${YELLOW}=== ИНТЕРФЕЙСЫ ===${NC}"
   i=1
   declare -a IFACES
   declare -a IPS
   declare -a NETS
   
   for iface in $(ls /sys/class/net/ | grep -v lo); do
      ip_line=$(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | head -1)
      if [[ -n "$ip_line" ]]; then
         ip_addr=$(echo "$ip_line" | grep -oP 'inet \K[\d.]+')
         ip_mask=$(echo "$ip_line" | grep -oP '/\K\d+')
         ip_full="$ip_addr/$ip_mask"
         
         # Вычисляем сеть
         network=$(echo "$ip_addr" | awk -F. -v m="$ip_mask" '{
            split("0 128 192 224 240 248 252 254 255", mask, " ")
            ip = $1*256^3 + $2*256^2 + $3*256 + $4
            bits = m
            net = int(ip / 2^(32-bits)) * 2^(32-bits)
            printf "%d.%d.%d.%d/%d", int(net/256^3), int(net/256^2)%256, int(net/256)%256, net%256, m
         }')
         
         printf " ${YELLOW}%d)${NC} %-10s ${WHITE}%s${NC} (сеть: %s)\n" "$i" "$iface" "$ip_full" "$network"
         IFACES+=("$iface")
         IPS+=("$ip_addr")
         NETS+=("$network")
         ((i++))
      fi
   done

   # Выбор внешнего интерфейса
   echo ""
   read -p "${YELLOW}Внешний интерфейс (номер):${NC} " ext_idx
   EXT_IFACE="${IFACES[$((ext_idx-1))]}"
   EXT_IP="${IPS[$((ext_idx-1))]}"
   print_ok "Внешний: $EXT_IFACE ($EXT_IP)"

   # Ввод IP удаленного роутера
   echo ""
   read -p "${YELLOW}IP удаленного роутера (внешний):${NC} " REMOTE_IP
   print_ok "Удаленный IP: $REMOTE_IP"

   # Автоматический расчет IP для туннеля
   TUNNEL_NET="192.168.100"
   if [[ "$ROLE" == "HQ" ]]; then
      LOCAL_TUNNEL="${TUNNEL_NET}.1"
      REMOTE_TUNNEL="${TUNNEL_NET}.2"
   else
      LOCAL_TUNNEL="${TUNNEL_NET}.2"
      REMOTE_TUNNEL="${TUNNEL_NET}.1"
   fi
   
   echo ""
   read -p "${YELLOW}IP туннеля [${LOCAL_TUNNEL}]:${NC} " tunnel_input
   LOCAL_TUNNEL="${tunnel_input:-$LOCAL_TUNNEL}"
   print_ok "IP туннеля: $LOCAL_TUNNEL/30"

   # Создание GRE туннеля
   print_msg "Создание GRE туннеля..."
   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1

   if ! ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64; then
      print_err "Не удалось создать туннель!"
      exit 1
   fi

   if ! ip addr add "$LOCAL_TUNNEL/30" dev gre1; then
      print_err "Не удалось добавить IP!"
      ip tunnel del gre1
      exit 1
   fi

   if ! ip link set gre1 up; then
      print_err "Не удалось поднять туннель!"
      ip tunnel del gre1
      exit 1
   fi

   sleep 2

   # Проверка туннеля
   if ping -c 2 "$REMOTE_TUNNEL" &>/dev/null; then
      print_ok "✓ Туннель работает"
   else
      print_err "⚠ Туннель создан, но ping не проходит"
   fi

   # Сохранение в rc.local
   print_msg "Сохранение конфигурации..."
   if [[ ! -f "$RC_LOCAL" ]]; then
      touch "$RC_LOCAL"
      chmod +x "$RC_LOCAL"
   fi
   
   sed -i '/# GRE tunnel/,/ip link set gre1 up/d' "$RC_LOCAL" 2>/dev/null || true
   
   cat >> "$RC_LOCAL" << EOF

# GRE tunnel - $(date +%Y-%m-%d)
ip tunnel del gre1 2>/dev/null || true
sleep 2
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
ip addr add $LOCAL_TUNNEL/30 dev gre1
ip link set gre1 up
sleep 2
EOF
   chmod +x "$RC_LOCAL"

   # Включение IP forwarding
   sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
   grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
      echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

   # Выбор сетей для OSPF
   echo ""
   echo -e "${YELLOW}=== СЕТИ ДЛЯ OSPF ===${NC}"
   echo "Автоматически найдены сети:"
   
   declare -a OSPF_NETWORKS
   for idx in "${!IFACES[@]}"; do
      if [[ "${IFACES[$idx]}" != "$EXT_IFACE" && "${IFACES[$idx]}" != "lo" ]]; then
         net="${NETS[$idx]}"
         echo "  - $net (${IFACES[$idx]})"
         OSPF_NETWORKS+=("$net")
      fi
   done
   
   # Добавляем сеть туннеля
   TUNNEL_NETWORK="${LOCAL_TUNNEL}.0/30"
   echo "  - $TUNNEL_NETWORK (gre1 туннель)"
   OSPF_NETWORKS+=("$TUNNEL_NETWORK")

   echo ""
   read -p "Добавить все эти сети в OSPF? [Y/n]: " add_nets
   if [[ "$add_nets" =~ ^[Nn]$ ]]; then
      echo "Введите сети вручную (формат: 192.168.0.0/24), пустая строка - завершить:"
      OSPF_NETWORKS=()
      while true; do
         read -p "Сеть: " net
         [[ -z "$net" ]] && break
         [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && OSPF_NETWORKS+=("$net")
      done
   fi

   # Пароль OSPF
   echo ""
   read -p "${YELLOW}Пароль OSPF [ospf123]:${NC} " ospf_pass
   ospf_pass="${ospf_pass:-ospf123}"

   # Генерация конфига
   print_msg "Генерация конфигурации..."
   
   networks_config=""
   for net in "${OSPF_NETWORKS[@]}"; do
      networks_config+=" network $net area 0\n"
   done

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
$(echo -e "$networks_config")!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $ospf_pass
!
line vty
!
EOF

   print_ok "Конфигурация записана"
   
   # Показ конфига
   echo -e "\n${YELLOW}=== КОНФИГУРАЦИЯ ===${NC}"
   cat "$FRR_CONF"

   # Перезапуск FRR
   systemctl enable frr >/dev/null 2>&1
   systemctl restart frr
   sleep 5

   # Итоги
   clear
   echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
   echo -e "${GREEN}║ ✅ НАСТРОЙКА ЗАВЕРШЕНА                            ║${NC}"
   echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
   echo -e "\n${WHITE}ПАРАМЕТРЫ:${NC}"
   echo " Роль: $ROLE"
   echo " Router ID: $RID"
   echo " Туннель: $LOCAL_TUNNEL/30 <-> $REMOTE_TUNNEL"
   echo ""
   echo -e "${WHITE}OSPF СОСЕДИ:${NC}"
   vtysh -c "show ip ospf neighbor" 2>/dev/null || echo " Нет соседей"
   echo ""
   echo -e "${WHITE}OSPF МАРШРУТЫ:${NC}"
   vtysh -c "show ip route ospf" 2>/dev/null | head -15
   echo ""
   echo -e "${WHITE}ТАБЛИЦА МАРШРУТИЗАЦИИ:${NC}"
   ip route show | head -10
   echo ""
   echo -e "${YELLOW}ПРОВЕРКА:${NC}"
   echo " vtysh -c 'show ip ospf neighbor'"
   echo " ping $REMOTE_TUNNEL"
   echo ""
}

# Меню
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE - UNIVERSAL VERSION                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo " 1) Настроить FRR"
echo " 2) Удалить настройки"
echo " 3) Показать статус"
echo " 4) Выход"
echo ""
read -p "Выбор [1]: " choice

case $choice in
 2) full_cleanup ;;
 3)
   echo -e "\n${WHITE}=== GRE ===${NC}"
   ip link show gre1 2>/dev/null || echo "Нет туннеля"
   echo -e "\n${WHITE}=== OSPF ===${NC}"
   vtysh -c "show running-config ospf" 2>/dev/null || echo "Не настроен"
   echo -e "\n${WHITE}=== СОСЕДИ ===${NC}"
   vtysh -c "show ip ospf neighbor" 2>/dev/null
   echo -e "\n${WHITE}=== МАРШРУТЫ ===${NC}"
   ip route show | grep -E "ospf|192.168"
   ;;
 4) exit 0 ;;
 *) setup_frr ;;
esac

echo -e "\n${GREEN}Готово!${NC}"
