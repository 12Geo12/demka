#!/bin/bash
#===============================================================================
# Настройка FRRouting (OSPF + GRE) - Версия 8.1
# Добавлено: интерактивное меню с проверкой работоспособности
# Исправлено: функция show_ospf_status (убрана ошибка "No such interface name")
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/frr-setup-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; }
sep() { log "${CYAN}================================================${NC}"; }

#===============================================================================
# ПРОВЕРКА ROOT
#===============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

#===============================================================================
# ФУНКЦИЯ ПРОВЕРКИ РАБОТОСПОСОБНОСТИ
#===============================================================================

check_frr_status() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}ПРОВЕРКА РАБОТОСПОСОБНОСТИ FRR${NC}             ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    ERRORS=0
    WARNINGS=0
    
    #---------------------------------------------------------------------------
    # 1. Проверка сервиса FRR
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 1. Статус сервиса FRR ===${NC}"
    sep
    
    if systemctl is-active frr >/dev/null 2>&1; then
        ok "Сервис FRR: ${GREEN}АКТИВЕН${NC}"
    else
        err "Сервис FRR: ${RED}НЕ АКТИВЕН${NC}"
        ERRORS=$((ERRORS + 1))
        
        # Проверяем почему не запущен
        if systemctl is-enabled frr >/dev/null 2>&1; then
            log "  ${YELLOW}→ Сервис включён в автозагрузку${NC}"
        else
            log "  ${YELLOW}→ Сервис НЕ включён в автозагрузку${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        # Пробуем показать статус
        log ""
        log "${YELLOW}Последние строки журнала:${NC}"
        journalctl -u frr --no-pager -n 5 2>/dev/null
    fi
    
    #---------------------------------------------------------------------------
    # 2. Проверка демонов FRR
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 2. Демоны FRR ===${NC}"
    sep
    
    # zebra
    if pgrep -x zebra >/dev/null 2>&1; then
        ok "zebra: ${GREEN}запущен${NC}"
    else
        err "zebra: ${RED}НЕ запущен${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    # ospfd
    if pgrep -x ospfd >/dev/null 2>&1; then
        ok "ospfd: ${GREEN}запущен${NC}"
    else
        err "ospfd: ${RED}НЕ запущен${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    #---------------------------------------------------------------------------
    # 3. Проверка GRE туннеля
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 3. GRE туннель ===${NC}"
    sep
    
    if ip link show gre1 >/dev/null 2>&1; then
        GRE_STATE=$(ip link show gre1 2>/dev/null | grep -oP 'state \K\w+')
        GRE_MTU=$(ip link show gre1 2>/dev/null | grep -oP 'mtu \K\d+')
        GRE_IP=$(ip -4 addr show gre1 2>/dev/null | awk '/inet /{print $2}')
        
        if [ "$GRE_STATE" = "UNKNOWN" ] || [ "$GRE_STATE" = "UP" ]; then
            ok "GRE туннель: ${GREEN}АКТИВЕН${NC}"
        else
            warn "GRE туннель: ${YELLOW}состояние $GRE_STATE${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        log "  ${CYAN}Интерфейс:${NC} gre1"
        log "  ${CYAN}Состояние:${NC} $GRE_STATE"
        log "  ${CYAN}MTU:${NC} $GRE_MTU"
        log "  ${CYAN}IP адрес:${NC} ${GRE_IP:-не назначен}"
        
        # Показываем полную информацию
        log ""
        log "${CYAN}Детали туннеля:${NC}"
        ip -d link show gre1 2>/dev/null | head -3
    else
        err "GRE туннель: ${RED}НЕ СУЩЕСТВУЕТ${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    #---------------------------------------------------------------------------
    # 4. Проверка OSPF соседей
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 4. OSPF соседи ===${NC}"
    sep
    
    OSPF_NEIGHBORS=$(vtysh -c "show ip ospf neighbor" 2>/dev/null)
    
    if [ -n "$OSPF_NEIGHBORS" ] && echo "$OSPF_NEIGHBORS" | grep -q "^[0-9]"; then
        ok "OSPF соседи: ${GREEN}ОБНАРУЖЕНЫ${NC}"
        log ""
        echo "$OSPF_NEIGHBORS"
        
        # Считаем количество соседей
        NEIGHBOR_COUNT=$(echo "$OSPF_NEIGHBORS" | grep -c "^[0-9]" 2>/dev/null || echo "0")
        log ""
        log "  ${CYAN}Количество соседей:${NC} $NEIGHBOR_COUNT"
    else
        warn "OSPF соседи: ${YELLOW}НЕ ОБНАРУЖЕНЫ${NC}"
        WARNINGS=$((WARNINGS + 1))
        log ""
        log "  ${YELLOW}Возможные причины:${NC}"
        log "    • Удалённый роутер не настроен"
        log "    • GRE туннель не работает"
        log "    • Несовпадение ключей аутентификации"
        log "    • Несовпадение area ID"
        
        # Проверяем interface gre1 в OSPF
        log ""
        log "${YELLOW}Проверка OSPF на gre1:${NC}"
        vtysh -c "show ip ospf interface gre1" 2>/dev/null || err "Интерфейс gre1 не в OSPF"
    fi
    
    #---------------------------------------------------------------------------
    # 5. Проверка OSPF маршрутов
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 5. OSPF маршруты ===${NC}"
    sep
    
    OSPF_ROUTES=$(ip route show | grep -i ospf 2>/dev/null)
    
    if [ -n "$OSPF_ROUTES" ]; then
        ROUTE_COUNT=$(echo "$OSPF_ROUTES" | wc -l)
        ok "OSPF маршруты: ${GREEN}НАЙДЕНЫ${NC} ($ROUTE_COUNT шт.)"
        log ""
        echo "$OSPF_ROUTES"
    else
        warn "OSPF маршруты: ${YELLOW}НЕ НАЙДЕНЫ${NC}"
        WARNINGS=$((WARNINGS + 1))
        log ""
        log "  ${YELLOW}Проверьте:${NC}"
        log "    • OSPF соседи установлены?"
        log "    • Сети на удалённом роутере объявлены?"
    fi
    
    #---------------------------------------------------------------------------
    # 6. Проверка конфигурационных файлов
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 6. Конфигурационные файлы ===${NC}"
    sep
    
    # /etc/frr/frr.conf
    if [ -f "/etc/frr/frr.conf" ]; then
        ok "/etc/frr/frr.conf: ${GREEN}существует${NC}"
        
        # Проверяем владельца
        FRR_OWNER=$(stat -c "%U:%G" /etc/frr/frr.conf 2>/dev/null)
        if [ "$FRR_OWNER" = "frr:frr" ]; then
            ok "  Владелец: ${GREEN}$FRR_OWNER${NC}"
        else
            warn "  Владелец: ${YELLOW}$FRR_OWNER (рекомендуется frr:frr)${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        # Показываем Router ID
        RID=$(grep "ospf router-id" /etc/frr/frr.conf 2>/dev/null | awk '{print $NF}')
        if [ -n "$RID" ]; then
            log "  ${CYAN}Router ID:${NC} $RID"
        fi
    else
        err "/etc/frr/frr.conf: ${RED}НЕ НАЙДЕН${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    # /etc/frr/daemons
    if [ -f "/etc/frr/daemons" ]; then
        ok "/etc/frr/daemons: ${GREEN}существует${NC}"
        
        # Проверяем zebra и ospfd
        ZEBRA_EN=$(grep "^zebra=" /etc/frr/daemons 2>/dev/null | cut -d'=' -f2)
        OSPFD_EN=$(grep "^ospfd=" /etc/frr/daemons 2>/dev/null | cut -d'=' -f2)
        
        [ "$ZEBRA_EN" = "yes" ] && ok "  zebra: ${GREEN}enabled${NC}" || warn "  zebra: ${YELLOW}$ZEBRA_EN${NC}"
        [ "$OSPFD_EN" = "yes" ] && ok "  ospfd: ${GREEN}enabled${NC}" || warn "  ospfd: ${YELLOW}$OSPFD_EN${NC}"
    else
        err "/etc/frr/daemons: ${RED}НЕ НАЙДЕН${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    #---------------------------------------------------------------------------
    # 7. Проверка IP forwarding
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 7. IP Forwarding ===${NC}"
    sep
    
    IP_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    
    if [ "$IP_FWD" = "1" ]; then
        ok "IP Forwarding: ${GREEN}ВКЛЮЧЁН${NC}"
    else
        err "IP Forwarding: ${RED}ВЫКЛЮЧЕН${NC}"
        ERRORS=$((ERRORS + 1))
        log "  ${YELLOW}Выполните: sysctl -w net.ipv4.ip_forward=1${NC}"
    fi
    
    #---------------------------------------------------------------------------
    # 8. Тест соединения через туннель
    #---------------------------------------------------------------------------
    sep
    log "${WHITE}=== 8. Тест соединения ===${NC}"
    sep
    
    GRE_REMOTE_IP=$(ip -4 addr show gre1 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1)
    
    # Получаем IP удалённой стороны туннеля
    TUNNEL_REMOTE=""
    if [ -n "$GRE_REMOTE_IP" ]; then
        # Предполагаем, что удалённый IP туннеля отличается на 1
        IP_BASE=$(echo "$GRE_REMOTE_IP" | cut -d'.' -f1-3)
        IP_LAST=$(echo "$GRE_REMOTE_IP" | cut -d'.' -f4)
        
        if [ "$IP_LAST" = "1" ]; then
            TUNNEL_REMOTE="${IP_BASE}.2"
        else
            TUNNEL_REMOTE="${IP_BASE}.1"
        fi
    fi
    
    if [ -n "$TUNNEL_REMOTE" ]; then
        log "${CYAN}Пинг удалённого конца туннеля ($TUNNEL_REMOTE)...${NC}"
        if ping -c 3 -W 2 "$TUNNEL_REMOTE" >/dev/null 2>&1; then
            ok "Соединение: ${GREEN}РАБОТАЕТ${NC}"
            log "  ${GREEN}✓${NC} Удалённый конец туннеля доступен"
        else
            warn "Соединение: ${YELLOW}НЕТ ОТВЕТА${NC}"
            WARNINGS=$((WARNINGS + 1))
            log "  ${YELLOW}•${NC} Удалённый конец туннеля не отвечает на пинг"
            log "  ${YELLOW}•${NC} Проверьте настройки GRE на обоих роутерах"
        fi
    else
        warn "Невозможно определить IP для теста"
    fi
    
    #---------------------------------------------------------------------------
    # ИТОГОВАЯ СТАТИСТИКА
    #---------------------------------------------------------------------------
    log ""
    sep
    log "${WHITE}=== ИТОГОВАЯ СТАТИСТИКА ===${NC}"
    sep
    log ""
    
    if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
        log "${GREEN}║${NC}         ${WHITE}ВСЁ РАБОТАЕТ НОРМАЛЬНО!${NC}                     ${GREEN}║${NC}"
        log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    elif [ "$ERRORS" -eq 0 ]; then
        log "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
        log "${YELLOW}║${NC}   ${WHITE}РАБОТАЕТ С ПРЕДУПРЕЖДЕНИЯМИ${NC}                      ${YELLOW}║${NC}"
        log "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
        log ""
        log "${YELLOW}Предупреждений: $WARNINGS${NC}"
    else
        log "${RED}╔════════════════════════════════════════════════════════╗${NC}"
        log "${RED}║${NC}        ${WHITE}ОБНАРУЖЕНЫ ПРОБЛЕМЫ!${NC}                           ${RED}║${NC}"
        log "${RED}╚════════════════════════════════════════════════════════╝${NC}"
        log ""
        log "${RED}Ошибок: $ERRORS${NC}"
        log "${YELLOW}Предупреждений: $WARNINGS${NC}"
    fi
    
    log ""
    log "${CYAN}Полезные команды:${NC}"
    log "  ${YELLOW}vtysh -c 'show ip ospf neighbor'${NC}  - показать соседей"
    log "  ${YELLOW}vtysh -c 'show ip ospf database'${NC}   - база данных OSPF"
    log "  ${YELLOW}vtysh -c 'show ip route ospf'${NC}      - маршруты OSPF"
    log "  ${YELLOW}vtysh -c 'show running-config'${NC}     - текущая конфигурация"
    log "  ${YELLOW}journalctl -u frr -f${NC}               - логи FRR"
    log ""
}

#===============================================================================
# ФУНКЦИЯ ОЧИСТКИ СТАРЫХ НАСТРОЕК
#===============================================================================

clean_frr_settings() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}          ${WHITE}ОЧИСТКА СТАРЫХ НАСТРОЕК FRR${NC}                 ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    sep
    log "${WHITE}=== Остановка служб ===${NC}"
    sep
    
    systemctl stop frr 2>/dev/null && ok "FRR остановлен" || warn "FRR не был запущен"
    
    sep
    log "${WHITE}=== Удаление GRE туннелей ===${NC}"
    sep
    
    # Удаляем все GRE туннели
    for gre_iface in $(ip link show 2>/dev/null | grep -oP 'gre\d+' | sort -u); do
        ip link set "$gre_iface" down 2>/dev/null
        ip tunnel del "$gre_iface" 2>/dev/null && ok "Удалён $gre_iface"
    done
    
    # Специфично для gre1
    ip link set gre1 down 2>/dev/null
    ip tunnel del gre1 2>/dev/null
    ip addr del 172.16.1.1/24 dev gre1 2>/dev/null
    ip addr del 172.16.1.2/24 dev gre1 2>/dev/null
    
    ok "GRE туннели удалены"
    
    sep
    log "${WHITE}=== Удаление конфигурационных файлов ===${NC}"
    sep
    
    # Резервная копия старых конфигов
    BACKUP_DIR="/var/backups/frr-$(date +%Y%m%d-%H%M%S)"
    if [ -d "/etc/frr" ] || [ -d "/etc/net/ifaces/gre1" ] || [ -f "/etc/systemd/system/gre-tunnel.service" ]; then
        mkdir -p "$BACKUP_DIR"
        ok "Резервные копии: $BACKUP_DIR"
    fi
    
    # Бэкап и удаление /etc/frr
    if [ -d "/etc/frr" ]; then
        cp -r /etc/frr "$BACKUP_DIR/" 2>/dev/null
        rm -rf /etc/frr/frr.conf 2>/dev/null
        rm -rf /etc/frr/daemons 2>/dev/null
        rm -rf /etc/frr/zebra.conf 2>/dev/null
        rm -rf /etc/frr/ospfd.conf 2>/dev/null
        ok "Очищен /etc/frr/"
    fi
    
    # Бэкап и удаление GRE в etcnet
    if [ -d "/etc/net/ifaces/gre1" ]; then
        cp -r /etc/net/ifaces/gre1 "$BACKUP_DIR/gre1-etcnet" 2>/dev/null
        rm -rf /etc/net/ifaces/gre1 2>/dev/null
        ok "Удалён /etc/net/ifaces/gre1"
    fi
    
    # Удаление systemd service для GRE
    if [ -f "/etc/systemd/system/gre-tunnel.service" ]; then
        cp /etc/systemd/system/gre-tunnel.service "$BACKUP_DIR/" 2>/dev/null
        rm -f /etc/systemd/system/gre-tunnel.service
        systemctl daemon-reload
        ok "Удалён gre-tunnel.service"
    fi
    
    # Отключаем FRR от автозагрузки
    systemctl disable frr 2>/dev/null
    
    # Очистка маршрутов OSPF
    sep
    log "${WHITE}=== Очистка маршрутов ===${NC}"
    sep
    
    ip route flush proto ospf 2>/dev/null && ok "OSPF маршруты очищены"
    
    log ""
    ok "${GREEN}Очистка завершена!${NC}"
    log ""
}

#===============================================================================
# ФУНКЦИЯ НАСТРОЙКИ FRR
#===============================================================================

setup_frr() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}    ${WHITE}FRRouting OSPF + GRE - Автоматическая настройка${NC}     ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    
    # Сначала очищаем старые настройки
    clean_frr_settings
    
    #===========================================================================
    # АВТООПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ
    #===========================================================================
    
    sep
    log "${WHITE}=== Автоопределение интерфейсов ===${NC}"
    sep
    log ""
    
    # Временные файлы
    IFACE_LIST="/tmp/frr_ifaces_$$"
    VLAN_LIST="/tmp/frr_vlans_$$"
    NETWORKS_LIST="/tmp/frr_nets_$$"
    > "$IFACE_LIST"
    > "$VLAN_LIST"
    > "$NETWORKS_LIST"
    
    # Получаем интерфейс с default route
    DEF_ROUTE_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')
    WAN_IFACE=""
    WAN_IP=""
    
    log "${CYAN}Сканирование интерфейсов...${NC}"
    log ""
    printf "  %-16s %-8s %-22s %-10s\n" "Интерфейс" "Статус" "IP-адрес" "Тип"
    echo "  --------------------------------------------------------------"
    
    # Перебираем интерфейсы
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        # Пропускаем виртуальные
        case "$iface" in
            lo|docker*|veth*|virbr*|br-*|flannel*|cni*|tun*|tap*|bond*|gre*|sit*) continue ;;
        esac
        
        # Определяем тип
        iface_type="VIRTUAL"
        case "$iface" in
            *.*) iface_type="VLAN" ;;
            *)
                if [ -d "/sys/class/net/${iface}/device" ]; then
                    iface_type="PHYSICAL"
                fi
                ;;
        esac
        
        # Получаем статус
        iface_status=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        
        # Получаем IP
        iface_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        
        # Форматирование вывода
        case "$iface_status" in
            up) status_out="${GREEN}UP${NC}" ;;
            *) status_out="${YELLOW}$iface_status${NC}" ;;
        esac
        
        case "$iface_type" in
            PHYSICAL) type_out="${GREEN}PHYS${NC}" ;;
            VLAN) type_out="${CYAN}VLAN${NC}" ;;
            *) type_out="${YELLOW}VIRT${NC}" ;;
        esac
        
        [ -z "$iface_ip" ] && iface_ip="---"
        
        printf "  %-16s " "$iface"
        echo -e "$status_out\t$iface_ip\t$type_out"
        
        # Сохраняем в файлы
        case "$iface_type" in
            VLAN)
                echo "$iface" >> "$VLAN_LIST"
                ;;
            PHYSICAL)
                echo "$iface" >> "$IFACE_LIST"
                # WAN = интерфейс с default route и IP
                if [ "$iface" = "$DEF_ROUTE_IFACE" ] && [ -n "$iface_ip" ] && [ "$iface_ip" != "---" ]; then
                    WAN_IFACE="$iface"
                    WAN_IP="$iface_ip"
                fi
                ;;
        esac
    done
    
    log ""
    
    #===========================================================================
    # ВЫБОР WAN
    #===========================================================================
    
    if [ -z "$WAN_IFACE" ] || [ -z "$WAN_IP" ]; then
        warn "WAN не определён автоматически"
        log ""
        log "${YELLOW}Выберите WAN интерфейс (для GRE туннеля):${NC}"
        
        idx=0
        while read -r iface; do
            idx=$((idx + 1))
            ip_tmp=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}')
            echo "  $idx) $iface (${ip_tmp:-нет IP})"
        done < "$IFACE_LIST"
        
        read -p "Номер: " wan_num
        wan_num=${wan_num:-1}
        
        WAN_IFACE=$(sed -n "${wan_num}p" "$IFACE_LIST")
        WAN_IP=$(ip -4 addr show dev "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}')
    fi
    
    # Если всё ещё нет IP - спрашиваем вручную
    if [ -z "$WAN_IP" ]; then
        log ""
        warn "IP на WAN интерфейсе не найден"
        read -p "Введите IP адрес WAN (без маски): " WAN_IP
    fi
    
    ok "WAN: ${WHITE}$WAN_IFACE${NC} (${WAN_IP})"
    
    # Убираем WAN из списка LAN
    grep -v "^${WAN_IFACE}$" "$IFACE_LIST" > "${IFACE_LIST}.tmp" 2>/dev/null
    mv "${IFACE_LIST}.tmp" "$IFACE_LIST" 2>/dev/null
    
    #===========================================================================
    # АВТООПРЕДЕЛЕНИЕ СЕТЕЙ
    #===========================================================================
    
    sep
    log "${WHITE}=== Автоопределение сетей OSPF ===${NC}"
    sep
    log ""
    
    # Функция конвертации IP/mask в сеть
    ip_to_net() {
        _ip_mask="$1"
        _ip=$(echo "$_ip_mask" | cut -d'/' -f1)
        _cidr=$(echo "$_ip_mask" | cut -d'/' -f2)
        
        if [ -z "$_ip" ] || [ -z "$_cidr" ]; then
            return
        fi
        
        # Разбираем октеты
        _o1=$(echo "$_ip" | cut -d'.' -f1)
        _o2=$(echo "$_ip" | cut -d'.' -f2)
        _o3=$(echo "$_ip" | cut -d'.' -f3)
        
        # Возвращаем сеть
        echo "${_o1}.${_o2}.${_o3}.0/${_cidr}"
    }
    
    # Сети с VLAN
    if [ -s "$VLAN_LIST" ]; then
        log "${CYAN}VLAN интерфейсы:${NC}"
        while read -r vlan; do
            vlan_ip=$(ip -4 addr show dev "$vlan" 2>/dev/null | awk '/inet /{print $2}')
            if [ -n "$vlan_ip" ]; then
                vlan_net=$(ip_to_net "$vlan_ip")
                if [ -n "$vlan_net" ]; then
                    echo "$vlan_net" >> "$NETWORKS_LIST"
                    log "  ${GREEN}•${NC} $vlan: ${CYAN}$vlan_net${NC}"
                fi
            fi
        done < "$VLAN_LIST"
    fi
    
    # Сети с LAN
    if [ -s "$IFACE_LIST" ]; then
        log "${CYAN}LAN интерфейсы:${NC}"
        while read -r iface; do
            lan_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}')
            if [ -n "$lan_ip" ]; then
                lan_net=$(ip_to_net "$lan_ip")
                if [ -n "$lan_net" ]; then
                    if ! grep -q "^${lan_net}$" "$NETWORKS_LIST" 2>/dev/null; then
                        echo "$lan_net" >> "$NETWORKS_LIST"
                        log "  ${GREEN}•${NC} $iface: ${CYAN}$lan_net${NC}"
                    fi
                fi
            fi
        done < "$IFACE_LIST"
    fi
    
    # Если сетей нет - спрашиваем
    if [ ! -s "$NETWORKS_LIST" ]; then
        warn "Сети не найдены автоматически"
        log "${YELLOW}Введите сети для OSPF (через пробел):${NC}"
        log "  Пример: 192.168.10.0/26 192.168.20.0/28"
        read -p "Сети: " nets_input
        for net in $nets_input; do
            echo "$net" >> "$NETWORKS_LIST"
        done
    fi
    
    log ""
    ok "Сети OSPF:"
    while read -r net; do
        log "  ${GREEN}•${NC} $net"
    done < "$NETWORKS_LIST"
    
    #===========================================================================
    # НАСТРОЙКА GRE ТУННЕЛЯ - РУЧНОЙ ВВОД
    #===========================================================================
    
    sep
    log "${WHITE}=== Настройка GRE туннеля ===${NC}"
    sep
    log ""
    
    # Локальный IP для GRE
    GRE_LOCAL=$(echo "$WAN_IP" | cut -d'/' -f1)
    
    log "${CYAN}Локальный IP для GRE туннеля:${NC}"
    log "  Автоопределено: ${GREEN}$GRE_LOCAL${NC}"
    log ""
    read -p "Использовать этот IP? (y/n) [y]: " use_auto_local
    use_auto_local=${use_auto_local:-y}
    
    if [ "$use_auto_local" != "y" ] && [ "$use_auto_local" != "Y" ]; then
        read -p "Введите локальный IP для GRE: " GRE_LOCAL
    fi
    
    ok "Локальный IP GRE: ${WHITE}$GRE_LOCAL${NC}"
    
    # Удалённый IP
    log ""
    log "${YELLOW}Введите удалённый IP для GRE туннеля:${NC}"
    log "  (IP адрес удалённого роутера для туннеля)"
    read -p "Удалённый IP: " GRE_REMOTE
    
    if [ -z "$GRE_REMOTE" ]; then
        err "Удалённый IP не указан!"
        exit 1
    fi
    
    ok "Удалённый IP GRE: ${WHITE}$GRE_REMOTE${NC}"
    
    # IP адрес GRE интерфейса - РУЧНОЙ ВВОД
    log ""
    log "${YELLOW}Введите IP адрес для GRE интерфейса (туннель):${NC}"
    log "  Примеры:"
    log "    HQ-RTR: 172.16.1.1/24"
    log "    BR-RTR: 172.16.1.2/24"
    log "    Или любой другой: 10.0.0.1/30, 192.168.100.1/24"
    log ""
    read -p "GRE IP адрес с маской: " GRE_IP
    
    if [ -z "$GRE_IP" ]; then
        warn "GRE IP не указан, используется по умолчанию"
        # Предлагаем выбор роли для дефолтного IP
        log ""
        log "${YELLOW}Выберите роль для стандартного GRE IP:${NC}"
        echo "  1) HQ-RTR (GRE IP: 172.16.1.1/24, Router ID: 1.1.1.1)"
        echo "  2) BR-RTR (GRE IP: 172.16.1.2/24, Router ID: 2.2.2.2)"
        read -p "Роль [1]: " role
        role=${role:-1}
        
        case "$role" in
            2)
                ROLE="BR-RTR"
                RID="2.2.2.2"
                GRE_IP="172.16.1.2/24"
                ;;
            *)
                ROLE="HQ-RTR"
                RID="1.1.1.1"
                GRE_IP="172.16.1.1/24"
                ;;
        esac
    else
        # Если IP введён вручную - спрашиваем Router ID
        log ""
        log "${YELLOW}Введите Router ID для OSPF:${NC}"
        log "  Примеры: 1.1.1.1, 2.2.2.2, 3.3.3.3"
        read -p "Router ID [1.1.1.1]: " RID
        RID=${RID:-1.1.1.1}
        ROLE="Custom"
    fi
    
    ok "GRE IP: ${WHITE}$GRE_IP${NC}"
    ok "Router ID: ${WHITE}$RID${NC}"
    
    # Сеть GRE туннеля (автоопределение из GRE_IP)
    GRE_NET=$(ip_to_net "$GRE_IP")
    if [ -z "$GRE_NET" ]; then
        # Простой вариант - берём сеть как есть
        GRE_BASE=$(echo "$GRE_IP" | cut -d'.' -f1-3)
        GRE_CIDR=$(echo "$GRE_IP" | cut -d'/' -f2)
        GRE_NET="${GRE_BASE}.0/${GRE_CIDR}"
    fi
    
    log ""
    ok "Сеть GRE туннеля: ${CYAN}$GRE_NET${NC}"
    
    #===========================================================================
    # УСТАНОВКА FRR
    #===========================================================================
    
    sep
    log "${WHITE}=== Установка FRR ===${NC}"
    sep
    log ""
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq frr iproute2 2>/dev/null || apt-get install -y frr 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q frr 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q frr 2>/dev/null
    else
        err "Пакетный менеджер не найден"
        exit 1
    fi
    
    ok "FRR установлен"
    
    #===========================================================================
    # КОНФИГУРАЦИЯ DAEMONS
    #===========================================================================
    
    sep
    log "${WHITE}=== Настройка FRR daemons ===${NC}"
    sep
    log ""
    
    mkdir -p /etc/frr
    
    cat > /etc/frr/daemons << 'DAEMONS'
zebra=yes
ospfd=yes
bgpd=no
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
vrrpd=no
DAEMONS
    
    ok "Daemons: zebra=yes, ospfd=yes"
    
    #===========================================================================
    # СОЗДАНИЕ GRE
    #===========================================================================
    
    sep
    log "${WHITE}=== Создание GRE туннеля ===${NC}"
    sep
    log ""
    
    # ALT Linux etcnet
    if [ -d "/etc/net/ifaces" ]; then
        mkdir -p /etc/net/ifaces/gre1
        cat > /etc/net/ifaces/gre1/options << GREOPT
TYPE=gre
REMOTE=${GRE_REMOTE}
LOCAL=${GRE_LOCAL}
TTL=64
DISABLE=no
GREOPT
        echo "${GRE_IP}" > /etc/net/ifaces/gre1/ipv4address
        ok "GRE в etcnet: /etc/net/ifaces/gre1"
    fi
    
    # Systemd service
    cat > /etc/systemd/system/gre-tunnel.service << GRESVC
[Unit]
Description=GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre local ${GRE_LOCAL} remote ${GRE_REMOTE} ttl 64
ExecStart=/sbin/ip addr add ${GRE_IP} dev gre1
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip link set gre1 mtu 1400
ExecStop=/sbin/ip link set gre1 down
ExecStop=/sbin/ip tunnel del gre1

[Install]
WantedBy=multi-user.target
GRESVC
    
    systemctl daemon-reload
    systemctl enable gre-tunnel.service 2>/dev/null
    
    # Поднимаем GRE
    ip tunnel del gre1 2>/dev/null || true
    ip tunnel add gre1 mode gre local "$GRE_LOCAL" remote "$GRE_REMOTE" ttl 64
    ip addr add "$GRE_IP" dev gre1
    ip link set gre1 up
    ip link set gre1 mtu 1400
    
    ok "GRE туннель поднят"
    
    #===========================================================================
    # КОНФИГУРАЦИЯ OSPF
    #===========================================================================
    
    sep
    log "${WHITE}=== Настройка OSPF ===${NC}"
    sep
    log ""
    
    cat > /etc/frr/frr.conf << OSPFHEAD
!
frr version 9.0
frr defaults traditional
hostname $(hostname)
log syslog informational
!
router ospf
 ospf router-id ${RID}
 passive-interface default
 no passive-interface gre1
!
 interface gre1
  ip ospf authentication
  ip ospf authentication-key 123
OSPFHEAD
    
    # Добавляем сети
    while read -r net; do
        echo " network $net area 0" >> /etc/frr/frr.conf
        log "  ${GREEN}+${NC} network $net area 0"
    done < "$NETWORKS_LIST"
    
    # GRE сеть
    echo " network $GRE_NET area 0" >> /etc/frr/frr.conf
    log "  ${GREEN}+${NC} network $GRE_NET area 0 (GRE)"
    
    # Завершение
    cat >> /etc/frr/frr.conf << 'OSPFEND'
!
line vty
!
OSPFEND
    
    chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
    chmod 640 /etc/frr/frr.conf 2>/dev/null
    
    ok "OSPF настроен"
    
    #===========================================================================
    # СИСТЕМНЫЕ НАСТРОЙКИ
    #===========================================================================
    
    sep
    log "${WHITE}=== Системные настройки ===${NC}"
    sep
    log ""
    
    # Удаляем дубликаты в sysctl.conf
    grep -v '^net.ipv4.ip_forward=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
    mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null
    grep -v '^net.ipv4.conf.all.rp_filter=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
    mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null
    grep -v '^net.ipv4.conf.default.rp_filter=' /etc/sysctl.conf > /tmp/sysctl_$$ 2>/dev/null
    mv /tmp/sysctl_$$ /etc/sysctl.conf 2>/dev/null
    
    # Добавляем настройки
    cat >> /etc/sysctl.conf << 'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
    
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
    ok "sysctl настроен"
    
    #===========================================================================
    # ЗАПУСК
    #===========================================================================
    
    sep
    log "${WHITE}=== Запуск FRR ===${NC}"
    sep
    log ""
    
    systemctl enable frr 2>/dev/null
    systemctl restart frr 2>/dev/null
    sleep 2
    
    ok "FRR запущен"
    
    #===========================================================================
    # ПРОВЕРКА
    #===========================================================================
    
    sep
    log "${WHITE}=== Проверка ===${NC}"
    sep
    log ""
    
    if ip link show gre1 >/dev/null 2>&1; then
        ok "GRE: активен"
        ip -br addr show gre1 2>/dev/null || ip addr show gre1 2>/dev/null | head -2
    else
        err "GRE: не поднят"
    fi
    
    log ""
    log "${CYAN}OSPF соседи:${NC}"
    vtysh -c "show ip ospf neighbor" 2>/dev/null || warn "Нет соседей (подождите 30 сек)"
    
    log ""
    log "${CYAN}OSPF маршруты:${NC}"
    ip route show | grep -i ospf 2>/dev/null || warn "Нет OSPF маршрутов"
    
    #===========================================================================
    # ИТОГ
    #===========================================================================
    
    log ""
    log "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${GREEN}║${NC}            ${WHITE}НАСТРОЙКА ЗАВЕРШЕНА!${NC}                        ${GREEN}║${NC}"
    log "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "${CYAN}Параметры:${NC}"
    log "  Роль:       ${WHITE}$ROLE${NC}"
    log "  Router ID:  ${WHITE}$RID${NC}"
    log "  WAN:        ${WHITE}$WAN_IFACE${NC} ($WAN_IP)"
    log "  GRE Local:  ${WHITE}$GRE_LOCAL${NC}"
    log "  GRE Remote: ${WHITE}$GRE_REMOTE${NC}"
    log "  GRE IP:     ${WHITE}$GRE_IP${NC}"
    log "  GRE Net:    ${WHITE}$GRE_NET${NC}"
    log ""
    log "${CYAN}Сети OSPF:${NC}"
    while read -r net; do
        log "  ${GREEN}•${NC} $net"
    done < "$NETWORKS_LIST"
    log "  ${GREEN}•${NC} $GRE_NET (GRE)"
    log ""
    log "${CYAN}Команды проверки:${NC}"
    log "  ${YELLOW}vtysh -c 'show ip ospf neighbor'${NC}"
    log "  ${YELLOW}ip route show | grep ospf${NC}"
    log "  ${YELLOW}ping ${GRE_IP%%/*}${NC}"
    log ""
    
    rm -f "$IFACE_LIST" "$VLAN_LIST" "$NETWORKS_LIST"
    log "${CYAN}Лог: ${LOG_FILE}${NC}"
    log ""
}

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================

show_menu() {
    log ""
    log "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║${NC}              ${WHITE}МЕНЮ FRRouting${NC}                           ${CYAN}║${NC}"
    log "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    log "${CYAN}║${NC}  ${GREEN}1.${NC} Настроить FRR (OSPF + GRE)                        ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}2.${NC} Проверить работоспособность                         ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}3.${NC} Очистить настройки FRR                              ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}4.${NC} Показать статус OSPF                                ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${GREEN}5.${NC} Перезапустить FRR                                    ${CYAN}║${NC}"
    log "${CYAN}║${NC}  ${RED}0.${NC} Выход                                               ${CYAN}║${NC}"
    log "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    log ""
}

show_ospf_status() {
    log ""
    log "${CYAN}=== Статус OSPF ===${NC}"
    log ""
    
    log "${YELLOW}OSPF соседи:${NC}"
    OSPF_NEIGH=$(vtysh -c "show ip ospf neighbor json" 2>/dev/null)
    if [ -n "$OSPF_NEIGH" ] && echo "$OSPF_NEIGH" | grep -qv '"{}"'; then
        vtysh -c "show ip ospf neighbor" 2>/dev/null
    else
        warn "Нет соседей OSPF"
    fi
    
    log ""
    log "${YELLOW}OSPF интерфейсы:${NC}"
    # Показываем все интерфейсы в OSPF
    OSPF_IFACES=$(vtysh -c "show ip ospf interface" 2>/dev/null)
    if [ -n "$OSPF_IFACES" ] && echo "$OSPF_IFACES" | grep -q "gre1\|Interface"; then
        echo "$OSPF_IFACES"
    else
        warn "Нет интерфейсов в OSPF"
        log "  ${YELLOW}Проверьте, что gre1 добавлен в OSPF${NC}"
    fi
    
    log ""
    log "${YELLOW}OSPF маршруты:${NC}"
    OSPF_RTES=$(vtysh -c "show ip route ospf" 2>/dev/null)
    if [ -n "$OSPF_RTES" ] && echo "$OSPF_RTES" | grep -q "O "; then
        echo "$OSPF_RTES"
    else
        warn "Нет OSPF маршрутов"
        log "  ${YELLOW}Маршруты появятся после установки соседей${NC}"
    fi
    
    log ""
    log "${YELLOW}Router ID:${NC}"
    OSPF_INFO=$(vtysh -c "show ip ospf" 2>/dev/null)
    if [ -n "$OSPF_INFO" ]; then
        echo "$OSPF_INFO" | grep -A2 "OSPF Routing Process" || echo "$OSPF_INFO" | head -5
    else
        warn "OSPF не настроен или не запущен"
    fi
    
    log ""
    
    # Дополнительная диагностика
    log "${CYAN}--- Дополнительная информация ---${NC}"
    log ""
    log "${YELLOW}Конфигурация OSPF:${NC}"
    vtysh -c "show running-config" 2>/dev/null | grep -A20 "router ospf" | head -15
    
    log ""
}

restart_frr() {
    log ""
    log "${YELLOW}Перезапуск FRR...${NC}"
    
    systemctl restart frr 2>/dev/null
    sleep 2
    
    if systemctl is-active frr >/dev/null 2>&1; then
        ok "FRR успешно перезапущен"
    else
        err "Ошибка перезапуска FRR"
        journalctl -u frr --no-pager -n 10 2>/dev/null
    fi
    
    log ""
}

# Основной цикл
while true; do
    show_menu
    read -p "Выберите пункт: " choice
    
    case "$choice" in
        1)
            setup_frr
            ;;
        2)
            check_frr_status
            ;;
        3)
            clean_frr_settings
            ;;
        4)
            show_ospf_status
            ;;
        5)
            restart_frr
            ;;
        0)
            log ""
            ok "Выход из меню"
            log ""
            exit 0
            ;;
        *)
            err "Неверный выбор: $choice"
            ;;
    esac
    
    log ""
    read -p "Нажмите Enter для продолжения..."
done
