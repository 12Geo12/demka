#!/bin/bash
# ============================================================================
# DNS Server Setup Script для ALT Linux Server
# Demo 2026 - Модуль 1, Задание 10
# Автоматическая настройка DNS-сервера с интерактивным вводом параметров
# ============================================================================

set -e

# ======================== ЦВЕТА И ФУНКЦИИ ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[X]${NC} $1"; }
header() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}========================================${NC}\n"; }

# ======================== ПРОВЕРКА ROOT ========================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Этот скрипт должен быть запущен от имени root!"
        info "Используйте: sudo $0"
        exit 1
    fi
}

# ======================== АВТООПРЕДЕЛЕНИЕ СЕТИ ========================
detect_network_info() {
    header "Автоопределение сетевых параметров"
    
    # Получаем список интерфейсов (исключаем loopback)
    INTERFACES=$(ls /sys/class/net/ | grep -v lo)
    
    info "Обнаруженные сетевые интерфейсы:"
    echo "$INTERFACES" | while read iface; do
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
        if [ -n "$ip_addr" ]; then
            echo "  - $iface: $ip_addr"
        else
            echo "  - $iface: (нет IPv4)"
        fi
    done
    echo ""
    
    # Автоопределение основного IP (через маршрут по умолчанию)
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    AUTO_IP=$(ip -4 addr show "$MAIN_INTERFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+')
    
    if [ -z "$AUTO_IP" ]; then
        # Альтернативный метод
        AUTO_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    fi
    
    if [ -n "$AUTO_IP" ]; then
        AUTO_NET=$(echo "$AUTO_IP" | cut -d. -f1-3)
        AUTO_GW=$(ip route | grep default | awk '{print $3}' | head -1)
        log "Автоопределено: IP=$AUTO_IP, Сеть=$AUTO_NET, Шлюз=$AUTO_GW"
    else
        warn "Не удалось автоматически определить IP-адрес"
        AUTO_NET="192.168.10"
        AUTO_GW="${AUTO_NET}.254"
    fi
}

# ======================== ИНТЕРАКТИВНЫЙ ВВОД ========================
interactive_input() {
    header "Ввод параметров DNS-сервера"
    
    # Домен
    echo -e "${YELLOW}Введите доменное имя зоны${NC}"
    read -p "Домен [au-team.irpo]: " DOMAIN
    DOMAIN=${DOMAIN:-au-team.irpo}
    
    # IP текущего сервера (HQ-SRV)
    echo -e "\n${YELLOW}Введите IP-адрес текущего сервера (HQ-SRV)${NC}"
    read -p "IP HQ-SRV [$AUTO_IP]: " HQ_SRV_IP
    HQ_SRV_IP=${HQ_SRV_IP:-$AUTO_IP}
    
    # Сеть
    echo -e "\n${YELLOW}Введите сеть (первые 3 октета)${NC}"
    read -p "Сеть [$AUTO_NET]: " NETWORK
    NETWORK=${NETWORK:-$AUTO_NET}
    
    # Шлюз
    echo -e "\n${YELLOW}Введите IP-адрес шлюза${NC}"
    read -p "Шлюз [$AUTO_GW]: " GATEWAY
    GATEWAY=${GATEWAY:-$AUTO_GW}
    
    # DNS серверы пересылки
    echo -e "\n${YELLOW}DNS серверы пересылки (через пробел)${NC}"
    read -p "Forwarders [77.88.8.7 77.88.8.8]: " FORWARDERS
    FORWARDERS=${FORWARDERS:-"77.88.8.7 77.88.8.8"}
    
    # Подтверждение
    echo ""
    header "Проверка введённых данных"
    echo -e "  Домен:           ${GREEN}$DOMAIN${NC}"
    echo -e "  IP HQ-SRV:       ${GREEN}$HQ_SRV_IP${NC}"
    echo -e "  Сеть:            ${GREEN}$NETWORK${NC}"
    echo -e "  Шлюз:            ${GREEN}$GATEWAY${NC}"
    echo -e "  Forwarders:      ${GREEN}$FORWARDERS${NC}"
    echo ""
    
    read -p "Продолжить? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! "$CONFIRM" =~ ^[YyДд]*$ ]]; then
        err "Отмена операции пользователем"
        exit 0
    fi
}

# ======================== ВВОД ХОСТОВ ========================
input_hosts() {
    header "Ввод DNS записей для устройств"
    
    # Инициализируем ассоциативный массив для хостов
    declare -gA HOSTS_A_RECORDS
    declare -gA HOSTS_PTR_RECORDS
    
    # Предустановленные хосты из задания (кроме HQ-CLI - исключён!)
    echo -e "${YELLOW}Ввод IP-адресов для устройств (согласно Таблице 3)${NC}"
    echo -e "${CYAN}Примечание: HQ-CLI исключён из задания${NC}\n"
    
    # HQ-RTR (A + PTR)
    read -p "IP для HQ-RTR (маршрутизатор HQ) [${NETWORK}.254]: " HQ_RTR_IP
    HQ_RTR_IP=${HQ_RTR_IP:-"${NETWORK}.254"}
    HOSTS_A_RECORDS["hq-rtr"]="$HQ_RTR_IP"
    HOSTS_PTR_RECORDS["hq-rtr"]="$HQ_RTR_IP"
    
    # BR-RTR (только A)
    read -p "IP для BR-RTR (маршрутизатор BR) [${NETWORK}.253]: " BR_RTR_IP
    BR_RTR_IP=${BR_RTR_IP:-"${NETWORK}.253"}
    HOSTS_A_RECORDS["br-rtr"]="$BR_RTR_IP"
    
    # HQ-SRV (A + PTR) - текущий сервер
    HOSTS_A_RECORDS["hq-srv"]="$HQ_SRV_IP"
    HOSTS_PTR_RECORDS["hq-srv"]="$HQ_SRV_IP"
    
    # BR-SRV (только A)
    read -p "IP для BR-SRV (сервер BR) [${NETWORK}.10]: " BR_SRV_IP
    BR_SRV_IP=${BR_SRV_IP:-"${NETWORK}.10"}
    HOSTS_A_RECORDS["br-srv"]="$BR_SRV_IP"
    
    # ISP записи
    echo -e "\n${YELLOW}Записи для ISP (интерфейсы провайдера)${NC}"
    
    # docker.au-team.irpo
    read -p "IP для docker.au-team.irpo (ISP -> HQ-RTR): " DOCKER_IP
    if [ -n "$DOCKER_IP" ]; then
        HOSTS_A_RECORDS["docker"]="$DOCKER_IP"
    fi
    
    # web.au-team.irpo
    read -p "IP для web.au-team.irpo (ISP -> BR-RTR): " WEB_IP
    if [ -n "$WEB_IP" ]; then
        HOSTS_A_RECORDS["web"]="$WEB_IP"
    fi
    
    # Дополнительные хосты
    echo -e "\n${YELLOW}Добавить дополнительные записи?${NC}"
    echo "Формат: имя:ip (например, server1:192.168.10.100)"
    echo "Пустой ввод - завершить"
    
    while true; do
        read -p "Дополнительная запись: " EXTRA_HOST
        [ -z "$EXTRA_HOST" ] && break
        
        EXTRA_NAME="${EXTRA_HOST%%:*}"
        EXTRA_IP="${EXTRA_HOST##*:}"
        
        if [ -n "$EXTRA_NAME" ] && [ -n "$EXTRA_IP" ]; then
            HOSTS_A_RECORDS["$EXTRA_NAME"]="$EXTRA_IP"
            log "Добавлено: $EXTRA_NAME -> $EXTRA_IP"
            
            read -p "Создать PTR запись? [y/N]: " ADD_PTR
            if [[ "$ADD_PTR" =~ ^[YyДд]+$ ]]; then
                HOSTS_PTR_RECORDS["$EXTRA_NAME"]="$EXTRA_IP"
            fi
        fi
    done
    
    # Вывод всех записей
    echo ""
    header "Сводка DNS записей"
    echo -e "${CYAN}A-записи (прямое разрешение):${NC}"
    for name in "${!HOSTS_A_RECORDS[@]}"; do
        echo -e "  $name.$DOMAIN -> ${HOSTS_A_RECORDS[$name]}"
    done
    
    echo -e "\n${CYAN}PTR-записи (обратное разрешение):${NC}"
    for name in "${!HOSTS_PTR_RECORDS[@]}"; do
        echo -e "  ${HOSTS_PTR_RECORDS[$name]} -> $name.$DOMAIN"
    done
    echo ""
}

# ======================== УСТАНОВКА BIND ========================
install_bind() {
    header "Установка BIND DNS сервера"
    
    # Проверка ALT Linux
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "altlinux" ]] || [[ "$ID" == "alt" ]]; then
            log "Обнаружена ALT Linux: $PRETTY_NAME"
            
            # Обновление и установка
            log "Обновление списков пакетов..."
            apt-get update -qq
            
            log "Установка bind и bind-utils..."
            apt-get install -y bind bind-utils
        else
            warn "Не ALT Linux, пытаемся установить через apt-get..."
            apt-get update && apt-get install -y bind bind-utils || {
                err "Не удалось установить BIND"
                exit 1
            }
        fi
    fi
    
    log "BIND успешно установлен"
}

# ======================== НАСТРОЙКА RNDC ========================
setup_rndc() {
    header "Настройка RNDC ключа"
    
    log "Генерация RNDC ключа..."
    
    # Удаляем старые ключи
    rm -f /etc/rndc.key /etc/bind/rndc.key 2>/dev/null || true
    
    # Генерируем новый ключ
    rndc-confgen -a -k rndc-key
    
    # Настраиваем права
    if [ -f /etc/rndc.key ]; then
        cp /etc/rndc.key /etc/bind/rndc.key
        chmod 640 /etc/rndc.key /etc/bind/rndc.key
        chown root:named /etc/rndc.key /etc/bind/rndc.key
        log "RNDC ключ успешно создан"
    else
        warn "Не удалось создать RNDC ключ, продолжаем..."
    fi
}

# ======================== КОНФИГУРАЦИЯ BIND ========================
configure_bind() {
    header "Создание конфигурационных файлов BIND"
    
    # Создаём директорию для зон
    mkdir -p /etc/bind/zones
    
    # ======================== options.conf ========================
    log "Создание /etc/bind/options.conf..."
    
    # Формируем список forwarders
    FORWARDERS_CONFIG=""
    for fwd in $FORWARDERS; do
        FORWARDERS_CONFIG+="        $fwd;\n"
    done
    
    cat > /etc/bind/options.conf << EOF
options {
    // Слушаем на всех интерфейсах
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    
    // Рабочая директория
    directory "/var/named";
    
    // PID файл
    pid-file "/run/named/named.pid";
    
    // Разрешаем запросы от всех
    allow-query { any; };
    
    // Разрешаем рекурсию
    allow-recursion { any; };
    recursion yes;
    
    // Серверы пересылки (forwarders)
    forwarders {
$(echo -e "$FORWARDERS_CONFIG")
    };
    forward only;
    
    // Отключаем DNSSEC для локальной сети
    dnssec-validation no;
    
    // Логирование
    statistics-file "/var/named/data/named_stats.txt";
    session-keyfile "/run/named/session.key";
};
EOF

    # ======================== local.conf (зоны) ========================
    log "Создание /etc/bind/local.conf..."
    
    cat > /etc/bind/local.conf << EOF
// ============================================================
// Конфигурация зон DNS сервера
// Сгенерировано: $(date)
// ============================================================

// Прямая зона домена
zone "$DOMAIN" IN {
    type master;
    file "/etc/bind/zones/db.$DOMAIN";
    allow-update { none; };
};

// Обратная зона
zone "${NETWORK}.in-addr.arpa" IN {
    type master;
    file "/etc/bind/zones/db.${NETWORK}";
    allow-update { none; };
};

// Стандартные зоны
zone "localhost" IN {
    type master;
    file "/etc/bind/zones/db.local";
    allow-update { none; };
};

zone "0.0.127.in-addr.arpa" IN {
    type master;
    file "/etc/bind/zones/db.127.0.0";
    allow-update { none; };
};

zone "0.in-addr.arpa" IN {
    type master;
    file "/etc/bind/zones/db.empty";
    allow-update { none; };
};

zone "255.in-addr.arpa" IN {
    type master;
    file "/etc/bind/zones/db.empty";
    allow-update { none; };
};
EOF

    # ======================== named.conf ========================
    log "Создание /etc/named.conf..."
    
    cat > /etc/named.conf << EOF
// ============================================================
// Главный конфигурационный файл BIND
// ALT Linux Server - DNS Setup
// ============================================================

// Опции сервера
include "/etc/bind/options.conf";

// RNDC ключ
include "/etc/bind/rndc.key";

// Определения зон
include "/etc/bind/local.conf";
EOF

    log "Конфигурационные файлы созданы"
}

# ======================== СОЗДАНИЕ ЗОН ========================
create_zones() {
    header "Создание файлов зон"
    
    SERIAL=$(date +%Y%m%d01)
    
    # ======================== Прямая зона ========================
    log "Создание прямой зоны: $DOMAIN"
    
    cat > /etc/bind/zones/db.$DOMAIN << EOF
; ============================================================
; Прямая зона DNS: $DOMAIN
; Сгенерировано: $(date)
; ============================================================

\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. root.$DOMAIN. (
            $SERIAL  ; Serial (серийный номер)
            3600     ; Refresh (обновление)
            1800     ; Retry (повтор)
            604800   ; Expire (истечение)
            86400    ; Minimum TTL (минимум)
            )

; NS записи
        IN  NS      hq-srv.$DOMAIN.

; MX запись (если нужен почтовый сервер)
        IN  MX  10  hq-srv.$DOMAIN.

; ============================================================
; A-записи устройств
; ============================================================

; DNS сервер (HQ-SRV)
hq-srv      IN  A   $HQ_SRV_IP

; Маршрутизаторы
hq-rtr      IN  A   ${HOSTS_A_RECORDS["hq-rtr"]}
br-rtr      IN  A   ${HOSTS_A_RECORDS["br-rtr"]}

; Сервер филиала
br-srv      IN  A   ${HOSTS_A_RECORDS["br-srv"]}

; ISP интерфейсы
EOF

    # Добавляем docker и web если есть
    if [ -n "${HOSTS_A_RECORDS["docker"]}" ]; then
        echo "docker      IN  A   ${HOSTS_A_RECORDS["docker"]}" >> /etc/bind/zones/db.$DOMAIN
    fi
    if [ -n "${HOSTS_A_RECORDS["web"]}" ]; then
        echo "web         IN  A   ${HOSTS_A_RECORDS["web"]}" >> /etc/bind/zones/db.$DOMAIN
    fi
    
    # Добавляем дополнительные записи
    for name in "${!HOSTS_A_RECORDS[@]}"; do
        if [[ ! "$name" =~ ^(hq-srv|hq-rtr|br-rtr|br-srv|docker|web)$ ]]; then
            echo "$name       IN  A   ${HOSTS_A_RECORDS[$name]}" >> /etc/bind/zones/db.$DOMAIN
        fi
    done

    # ======================== Обратная зона ========================
    log "Создание обратной зоны: ${NETWORK}.in-addr.arpa"
    
    cat > /etc/bind/zones/db.${NETWORK} << EOF
; ============================================================
; Обратная зона DNS: ${NETWORK}.in-addr.arpa
; Сгенерировано: $(date)
; ============================================================

\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. root.$DOMAIN. (
            $SERIAL  ; Serial
            3600     ; Refresh
            1800     ; Retry
            604800   ; Expire
            86400    ; Minimum TTL
            )

; NS запись
        IN  NS      hq-srv.$DOMAIN.

; ============================================================
; PTR-записи (обратное разрешение)
; ============================================================

EOF

    # Добавляем PTR записи
    for name in "${!HOSTS_PTR_RECORDS[@]}"; do
        ip="${HOSTS_PTR_RECORDS[$name]}"
        last_octet=$(echo "$ip" | cut -d. -f4)
        echo "$last_octet     IN  PTR     $name.$DOMAIN." >> /etc/bind/zones/db.${NETWORK}
    done

    # ======================== localhost зона ========================
    log "Создание стандартных зон..."
    
    cat > /etc/bind/zones/db.local << 'EOF'
$TTL 86400
@   IN  SOA localhost. root.localhost. (
            1       ; Serial
            3600    ; Refresh
            1800    ; Retry
            604800  ; Expire
            86400 ) ; Minimum TTL

        IN  NS      localhost.
        IN  A       127.0.0.1
EOF

    cat > /etc/bind/zones/db.127.0.0 << 'EOF'
$TTL 86400
@   IN  SOA localhost. root.localhost. (
            1       ; Serial
            3600    ; Refresh
            1800    ; Retry
            604800  ; Expire
            86400 ) ; Minimum TTL

        IN  NS      localhost.
1       IN  PTR     localhost.
EOF

    cat > /etc/bind/zones/db.empty << 'EOF'
$TTL 86400
@   IN  SOA localhost. root.localhost. (
            1       ; Serial
            3600    ; Refresh
            1800    ; Retry
            604800  ; Expire
            86400 ) ; Minimum TTL

        IN  NS      localhost.
EOF

    log "Файлы зон успешно созданы"
}

# ======================== НАСТРОЙКА ПРАВ ========================
set_permissions() {
    header "Настройка прав доступа"
    
    log "Установка владельца и прав для /etc/bind..."
    chown -R root:named /etc/bind
    chmod 755 /etc/bind
    chmod 640 /etc/bind/*.conf 2>/dev/null || true
    chmod 640 /etc/bind/*.key 2>/dev/null || true
    chmod 644 /etc/bind/zones/*
    
    log "Настройка /var/named..."
    mkdir -p /var/named/data
    mkdir -p /var/named/dynamic
    mkdir -p /var/named/slaves
    
    chown -R named:named /var/named
    chmod 750 /var/named
    chmod 770 /var/named/data /var/named/dynamic /var/named/slaves
    
    # Создаём файл лога
    touch /var/named/data/named.log
    chown named:named /var/named/data/named.log
    
    log "Права доступа настроены"
}

# ======================== FIREWALL ========================
configure_firewall() {
    header "Настройка firewall"
    
    # Проверяем iptables
    if command -v iptables &> /dev/null; then
        log "Добавление правил iptables для DNS..."
        
        # UDP 53
        iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport 53 -j ACCEPT
        
        # TCP 53
        iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport 53 -j ACCEPT
        
        log "Порты DNS открыты в iptables"
    fi
    
    # Проверяем firewalld
    if systemctl is-active firewalld &>/dev/null; then
        log "Настройка firewalld..."
        firewall-cmd --permanent --add-service=dns 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log "Сервис DNS добавлен в firewalld"
    fi
}

# ======================== ПРОВЕРКА КОНФИГУРАЦИИ ========================
verify_config() {
    header "Проверка конфигурации BIND"
    
    ERROR_FOUND=0
    
    log "Проверка named.conf..."
    if named-checkconf; then
        log "✓ named.conf: синтаксис корректен"
    else
        err "✗ Ошибка в named.conf"
        ERROR_FOUND=1
    fi
    
    log "Проверка прямой зоны $DOMAIN..."
    if named-checkzone "$DOMAIN" /etc/bind/zones/db.$DOMAIN; then
        log "✓ Прямая зона $DOMAIN: корректна"
    else
        err "✗ Ошибка в прямой зоне"
        ERROR_FOUND=1
    fi
    
    log "Проверка обратной зоны ${NETWORK}.in-addr.arpa..."
    if named-checkzone "${NETWORK}.in-addr.arpa" /etc/bind/zones/db.${NETWORK}; then
        log "✓ Обратная зона: корректна"
    else
        err "✗ Ошибка в обратной зоне"
        ERROR_FOUND=1
    fi
    
    if [ $ERROR_FOUND -eq 1 ]; then
        err "Обнаружены ошибки конфигурации!"
        err "Исправьте ошибки и запустите скрипт снова."
        exit 1
    fi
}

# ======================== ЗАПУСК СЕРВИСА ========================
start_service() {
    header "Запуск DNS сервера"
    
    # Отключаем SELinux если есть
    if command -v setenforce &> /dev/null; then
        setenforce 0 2>/dev/null || true
    fi
    
    log "Перезапуск сервиса bind..."
    systemctl daemon-reload
    systemctl enable bind
    systemctl restart bind
    
    sleep 3
    
    # Проверка статуса
    if systemctl is-active --quiet bind; then
        log "✓ DNS-сервер успешно запущен!"
    else
        err "✗ Не удалось запустить DNS-сервер"
        warn "Журнал ошибок:"
        journalctl -u bind -n 20 --no-pager
        exit 1
    fi
}

# ======================== ТЕСТИРОВАНИЕ ========================
test_dns() {
    header "Тестирование DNS сервера"
    
    log "Проверка прямого разрешения (A-записи):"
    echo ""
    
    # Тестируем все A-записи
    for name in "${!HOSTS_A_RECORDS[@]}"; do
        result=$(dig @localhost $name.$DOMAIN +short 2>/dev/null || echo "ошибка")
        expected="${HOSTS_A_RECORDS[$name]}"
        
        if [ "$result" = "$expected" ]; then
            echo -e "  ${GREEN}✓${NC} $name.$DOMAIN -> $result"
        else
            echo -e "  ${RED}✗${NC} $name.$DOMAIN -> $result (ожидалось: $expected)"
        fi
    done
    
    echo ""
    log "Проверка обратного разрешения (PTR-записи):"
    echo ""
    
    # Тестируем PTR записи
    for name in "${!HOSTS_PTR_RECORDS[@]}"; do
        ip="${HOSTS_PTR_RECORDS[$name]}"
        result=$(dig @localhost -x $ip +short 2>/dev/null | head -1 || echo "ошибка")
        expected="$name.$DOMAIN."
        
        if [ "$result" = "$expected" ]; then
            echo -e "  ${GREEN}✓${NC} $ip -> $result"
        else
            echo -e "  ${RED}✗${NC} $ip -> $result (ожидалось: $expected)"
        fi
    done
    
    echo ""
    log "Проверка серверов пересылки:"
    result=$(dig @localhost google.com +short 2>/dev/null | head -1)
    if [ -n "$result" ]; then
        echo -e "  ${GREEN}✓${NC} google.com -> $result (через forwarders)"
    else
        echo -e "  ${YELLOW}!${NC} Не удалось проверить forwarders (возможно, нет интернета)"
    fi
}

# ======================== ИНФОРМАЦИЯ ========================
print_info() {
    header "Настройка DNS сервера завершена!"
    
    echo -e "${CYAN}Информация о сервере:${NC}"
    echo -e "  Домен:          $DOMAIN"
    echo -e "  IP сервера:     $HQ_SRV_IP"
    echo -e "  Сеть:           $NETWORK.0/24"
    echo ""
    
    echo -e "${CYAN}Файлы конфигурации:${NC}"
    echo -e "  /etc/named.conf              - главный конфиг"
    echo -e "  /etc/bind/options.conf       - опции сервера"
    echo -e "  /etc/bind/local.conf         - определение зон"
    echo -e "  /etc/bind/zones/db.$DOMAIN  - прямая зона"
    echo -e "  /etc/bind/zones/db.$NETWORK - обратная зона"
    echo ""
    
    echo -e "${CYAN}Полезные команды:${NC}"
    echo -e "  systemctl status bind        - статус сервера"
    echo -e "  systemctl restart bind       - перезапуск"
    echo -e "  journalctl -u bind -f        - просмотр логов"
    echo ""
    echo -e "  nslookup hq-srv.$DOMAIN    - проверка DNS"
    echo -e "  dig @localhost $DOMAIN ANY - информация о зоне"
    echo -e "  dig @localhost -x $HQ_SRV_IP - обратный запрос"
    echo ""
    
    echo -e "${CYAN}Для проверки с другого компьютера:${NC}"
    echo -e "  nslookup hq-srv.$DOMAIN $HQ_SRV_IP"
    echo ""
}

# ======================== MAIN ========================
main() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     DNS Server Setup Script для ALT Linux Server            ║"
    echo "║              Demo 2026 - Модуль 1, Задание 10               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Проверка root
    check_root
    
    # Автоопределение сети
    detect_network_info
    
    # Интерактивный ввод
    interactive_input
    
    # Ввод хостов
    input_hosts
    
    # Установка BIND
    install_bind
    
    # Настройка RNDC
    setup_rndc
    
    # Конфигурация BIND
    configure_bind
    
    # Создание зон
    create_zones
    
    # Права доступа
    set_permissions
    
    # Firewall
    configure_firewall
    
    # Проверка конфигурации
    verify_config
    
    # Запуск
    start_service
    
    # Тестирование
    test_dns
    
    # Информация
    print_info
}

# Запуск
main "$@"
