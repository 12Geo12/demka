#!/bin/bash
#===============================================================================
# FRR OSPF/GRE - FINAL EXAM READY (UNIVERSAL)
# Исправления:
# 1. Автоматически обрезает маску у IP (чтобы не падал при создании туннеля)
# 2. Исправлена проверка статуса (убрана ошибка Ambiguous command)
# 3. Полная настройка OSPF и маршрутов
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
   print_msg "Полная очистка настроек..."
   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1
   
   # Сброс конфига FRR
   cat > "$FRR_CONF" << 'EOF'
frr version 9.0
frr defaults traditional
hostname $(hostname)
!
line vty
!
EOF
   systemctl restart frr 2>/dev/null || true
   print_ok "Очистка завершена"
}

setup_frr() {
   # 1. Очистка
   echo -e "\n${YELLOW}Очистить старые настройки? [Y/n]:${NC} "
   read -r cleanup_ans
   [[ ! "$cleanup_ans" =~ ^[Nn]$ ]] && full_cleanup && sleep 1

   # 2. Проверка FRR
   if ! command -v vtysh &>/dev/null; then
      print_msg "Установка FRR..."
      apt-get update >/dev/null 2>&1
      apt-get install -y frr >/dev/null 2>&1
      print_ok "FRR установлен"
   fi

   # 3. Роль
   HOST=$(hostname | tr '[:upper:]' '[:lower:]')
   if [[ "$HOST" =~ "hq" ]]; then
      ROLE="HQ"; RID="1.1.1.1"
   elif [[ "$HOST" =~ "br" ]]; then
      ROLE="BR"; RID="2.2.2.2"
   else
      ROLE="HQ"; RID="1.1.1.1"
   fi
   print_ok "Роль: $ROLE, Router ID: $RID"

   # 4. Интерфейсы
   echo -e "\n${YELLOW}=== ИНТЕРФЕЙСЫ ===${NC}"
   i=1
   declare -a IFACES
   declare -a IPS_FULL
   declare -a IPS_ONLY
   
   for iface in $(ls /sys/class/net/ | grep -v lo); do
      line=$(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | head -1)
      if [[ -n "$line" ]]; then
         # Берем полный IP с маской
         ip_full=$(echo "$line" | grep -oP 'inet \K[\d.]+/\d+')
         # Берем ТОЛЬКО IP без маски (для создания туннеля)
         ip_only=$(echo "$ip_full" | cut -d'/' -f1)
         
         printf " ${YELLOW}%d)${NC} %-10s ${WHITE}%s${NC}\n" "$i" "$iface" "$ip_full"
         IFACES+=("$iface")
         IPS_FULL+=("$ip_full")
         IPS_ONLY+=("$ip_only")
         ((i++))
      fi
   done

   # 5. Выбор внешнего
   echo ""
   read -p "${YELLOW}Номер внешнего интерфейса:${NC} " ext_idx
   EXT_IFACE="${IFACES[$((ext_idx-1))]}"
   EXT_IP="${IPS_ONLY[$((ext_idx-1))]}" # Используем IP БЕЗ МАСКИ
   print_ok "Выбран: $EXT_IFACE ($EXT_IP)"

   # 6. IP соседа
   echo ""
   read -p "${YELLOW}IP удаленного роутера (внешний):${NC} " REMOTE_IP
   print_ok "Удаленный IP: $REMOTE_IP"

   # 7. IP туннеля
   if [[ "$ROLE" == "HQ" ]]; then
      DEFAULT_TUNNEL="192.168.100.1"
   else
      DEFAULT_TUNNEL="192.168.100.2"
   fi
   
   echo ""
   read -p "${YELLOW}IP этого туннеля [${DEFAULT_TUNNEL}]:${NC} " tunnel_input
   LOCAL_TUNNEL="${tunnel_input:-$DEFAULT_TUNNEL}"
   print_ok "Локальный IP туннеля: $LOCAL_TUNNEL"

   if [[ "$ROLE" == "HQ" ]]; then REMOTE_TUNNEL="192.168.100.2"; else REMOTE_TUNNEL="192.168.100.1"; fi

   # 8. Создание туннеля
   print_msg "Создание GRE туннеля..."
   ip link set gre1 down 2>/dev/null
   sleep 1
   ip tunnel del gre1 2>/dev/null
   sleep 1

   # ВАЖНО: local должен быть без маски!
   if ! ip tunnel add gre1 mode gre local "$EXT_IP" remote "$REMOTE_IP" ttl 64; then
      print_err "Ошибка создания туннеля! Проверьте IP."
      exit 1
   fi
   ip addr add "$LOCAL_TUNNEL/30" dev gre1
   ip link set gre1 up
   sleep 2

   if ping -c 2 "$REMOTE_TUNNEL" &>/dev/null; then
      print_ok "✓ Туннель работает"
   else
      print_err " Туннель создан, но пинг не идет (проверьте фаервол)"
   fi

   # 9. Автозагрузка туннеля
   if [[ ! -f "$RC_LOCAL" ]]; then touch "$RC_LOCAL"; chmod +x "$RC_LOCAL"; fi
   sed -i '/# GRE tunnel/,/ip link set gre1 up/d' "$RC_LOCAL" 2>/dev/null || true
   cat >> "$RC_LOCAL" << EOF
# GRE tunnel
ip tunnel del gre1 2>/dev/null || true
sleep 2
ip tunnel add gre1 mode gre local $EXT_IP remote $REMOTE_IP ttl 64
ip addr add $LOCAL_TUNNEL/30 dev gre1
ip link set gre1 up
sleep 2
EOF

   # 10. IP Forwarding
   sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
   grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

   # 11. Сети OSPF
   echo -e "\n${YELLOW}=== СЕТИ OSPF ===${NC}"
   echo "Добавляем все локальные сети..."
   
   declare -a OSPF_NETS
   # Добавляем туннель
   TUNNEL_NET=$(echo "$LOCAL_TUNNEL" | cut -d. -f1-3).0/30
   OSPF_NETS+=("$TUNNEL_NET")
   
   # Добавляем остальные интерфейсы
   for idx in "${!IFACES[@]}"; do
      if [[ "${IFACES[$idx]}" != "$EXT_IFACE" && "${IFACES[$idx]}" != "lo" ]]; then
         OSPF_NETS+=("${IPS_FULL[$idx]}")
      fi
   done
   
   # Формируем конфиг OSPF
   OSPF_CONFIG=""
   for net in "${OSPF_NETS[@]}"; do
      OSPF_CONFIG+=" network $net area 0\n"
   done

   # Пароль
   echo ""
   read -p "${YELLOW}Пароль OSPF [ospf123]:${NC} " ospf_pass
   ospf_pass="${ospf_pass:-ospf123}"

   # 12. Запись конфига FRR
   print_msg "Запись конфигурации FRR..."
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
$(echo -e "$OSPF_CONFIG")!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $ospf_pass
!
line vty
!
EOF

   print_ok "Конфиг записан"
   
   # Перезапуск
   systemctl enable frr >/dev/null 2>&1
   systemctl restart frr
   sleep 5

   clear
   echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
   echo -e "${GREEN}║ ✅ НАСТРОЙКА ЗАВЕРШЕНА                            ║${NC}"
   echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
   echo -e "\n${WHITE}ПРОВЕРКА:${NC}"
   echo "Соседи:"
   vtysh -c "show ip ospf neighbor" 2>/dev/null || echo "Нет соседей"
   echo -e "\nМаршруты:"
   vtysh -c "show ip route ospf" 2>/dev/null | head -10
   echo ""
}

# Меню
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ FRR OSPF/GRE - UNIVERSAL                         ║${NC}"
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
   echo -e "\n${WHITE}=== FRR CONFIG ===${NC}"
   cat "$FRR_CONF" 2>/dev/null || echo "Файл конфига пуст"
   echo -e "\n${WHITE}=== OSPF STATUS ===${NC}"
   vtysh -c "show ip ospf" 2>/dev/null || echo "FRR не работает"
   echo -e "\n${WHITE}=== NEIGHBORS ===${NC}"
   vtysh -c "show ip ospf neighbor" 2>/dev/null
   echo -e "\n${WHITE}=== ROUTES (Kernel) ===${NC}"
   ip route show | grep -E "ospf|gre1|192.168"
   ;;
 4) exit 0 ;;
 *) setup_frr ;;
esac
