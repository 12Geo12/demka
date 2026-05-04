#!/bin/bash
#===============================================================================
# DNS Server Setup for Demo2026 - Alt Linux (IMPROVED VERSION)
# Настройка DNS сервера на HQ-SRV
#
# Задание 10:
# - Основной DNS-сервер на HQ-SRV
# - Разрешение имён в адреса и обратно
# - DNS сервер пересылки: 77.88.8.8
#
# ИСПРАВЛЕНИЯ:
# - Автоматическое создание директории /var/named/
# - Правильная зона обратного просмотра для конкретной сети
# - Предопределённые DNS записи из таблицы 3
# - Улучшенная обработка ошибок
# - Проверка платформы
#===============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Параметры по умолчанию
DOMAIN="au-team.irpo"
FORWARDER="77.88.8.8"

# Предопределённые DNS записи (Таблица 3)
# Формат: "имя IP PTR_флаг"
DEFAULT_DNS_ENTRIES=(
    "hq-rtr 192.168.10.1 yes"
    "br-rtr 192.168.20.1 no"
    "hq-srv 192.168.10.2 yes"
    "hq-cli 192.168.10.3 yes"
    "br-srv 192.168.20.2 no"
    "docker 172.16.10.1 no"
    "web 172.16.20.1 no"
)

# Флаги
USE_DEFAULT_ENTRIES=true
AUTO_MODE=false

# Вывод сообщений
msg_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
msg_er() { echo -e "${RED}[✗]${NC} $1"; }
msg_in() { echo -e "${BLUE}[i]${NC} $1"; }
msg_wrn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Обработка ошибок с выходом
die() {
    msg_er "$1"
    exit 1
}

# Проверка root
if [ "$EUID" -ne 0 ]; then
    die "Запустите от root (su -)"
fi

# Определение пакетного менеджера
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_NAME="bind"
        SERVICE_NAME="named"
        NAMED_USER="named"
    else
        die "Пакетный менеджер не найден (поддерживаются: apt-get, dnf, yum)"
    fi
}

# Парсинг аргументов командной строки
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--auto)
                AUTO_MODE=true
                shift
                ;;
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -f|--forwarder)
                FORWARDER="$2"
                shift 2
                ;;
            -m|--manual)
                USE_DEFAULT_ENTRIES=false
                shift
                ;;
            -h|--help)
                echo "Использование: $0 [OPTIONS]"
                echo ""
                echo "Опции:"
                echo "  -a, --auto        Автоматический режим (без подтверждения)"
                echo "  -d, --domain      Домен (по умолчанию: au-team.irpo)"
                echo "  -f, --forwarder   DNS пересылки (по умолчанию: 77.88.8.8)"
                echo "  -m, --manual      Ручной ввод DNS записей"
                echo "  -h, --help        Показать справку"
                exit 0
                ;;
            *)
                msg_wrn "Неизвестный параметр: $1"
                shift
                ;;
        esac
    done
}

parse_args "$@"

# Очистка экрана
clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}DNS Server Setup for Demo2026 (IMPROVED)${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

detect_pkg_manager
msg_ok "Пакетный менеджер: $PKG_MANAGER"

# Получаем IP адрес сервера
echo -e "\n${BLUE}Поиск IP адресов...${NC}\n"

SERVER_IP=""
INTERFACE=""

TMPFILE="/tmp/dns_ifaces_$$"
ip -br addr show | grep -v "^lo" > "$TMPFILE" || die "Не удалось получить список интерфейсов"

idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    iface=$(echo "$line" | awk '{print $1}')
    ip_full=$(echo "$line" | awk '{print $3}')
    [ -z "$ip_full" ] && continue
    
    ip=$(echo "$ip_full" | cut -d'/' -f1)
    
    # Очищаем имя интерфейса
    iface_clean=$(echo "$iface" | cut -d'@' -f1)
    
    echo -e "  ${GREEN}[$((idx+1))]${NC} $iface_clean ${YELLOW}→${NC} $ip"
    
    echo "$iface_clean" >> /tmp/dns_iface_$$
    echo "$ip" >> /tmp/dns_ip_$$
    
    idx=$((idx + 1))
done < "$TMPFILE"

rm -f "$TMPFILE"

TOTAL=$idx

if [ $TOTAL -eq 0 ]; then
    die "IP адреса не найдены"
fi

# Выбор интерфейса
echo ""
if [ "$AUTO_MODE" = true ]; then
    # В автоматическом режиме берём первый подходящий IP
    SERVER_IP=$(sed -n "1p" /tmp/dns_ip_$$)
    INTERFACE=$(sed -n "1p" /tmp/dns_iface_$$)
    msg_in "Автоматический выбор: $INTERFACE → $SERVER_IP"
else
    read -r -p "Выберите IP для DNS сервера [1-$TOTAL]: " num

    case "$num" in
        ''|*[!0-9]*)
            rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$
            die "Неверный выбор"
            ;;
    esac

    if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL" ]; then
        rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$
        die "Неверный выбор: введите число от 1 до $TOTAL"
    fi

    SERVER_IP=$(sed -n "${num}p" /tmp/dns_ip_$$)
    INTERFACE=$(sed -n "${num}p" /tmp/dns_iface_$$)
fi

rm -f /tmp/dns_iface_$$ /tmp/dns_ip_$$

# Ввод домена и forwarder
if [ "$AUTO_MODE" = false ]; then
    echo ""
    read -r -p "Домен [$DOMAIN]: " input_domain
    DOMAIN="${input_domain:-$DOMAIN}"

    read -r -p "DNS пересылки [$FORWARDER]: " input_fwd
    FORWARDER="${input_fwd:-$FORWARDER}"
fi

# Сбор DNS записей
DNS_ENTRIES=()
PTR_ENTRIES=()

if [ "$USE_DEFAULT_ENTRIES" = true ]; then
    msg_in "Использование предопределённых записей из таблицы 3..."
    echo ""
    
    for entry in "${DEFAULT_DNS_ENTRIES[@]}"; do
        name=$(echo "$entry" | awk '{print $1}')
        addr=$(echo "$entry" | awk '{print $2}')
        has_ptr=$(echo "$entry" | awk '{print $3}')
        
        DNS_ENTRIES+=("$name $addr")
        
        if [ "$has_ptr" = "yes" ]; then
            PTR_ENTRIES+=("$name $addr")
        fi
        
        echo -e "  ${GREEN}✓${NC} $name.${DOMAIN} → $addr ${YELLOW}(PTR: $has_ptr)${NC}"
    done
    
    # Возможность добавить дополнительные записи
    if [ "$AUTO_MODE" = false ]; then
        echo ""
        echo -e "${CYAN}Добавить дополнительные записи? (пустая строка - пропустить)${NC}"
        while true; do
            read -r -p "Запись (имя IP): " entry
            [ -z "$entry" ] && break
            
            name=$(echo "$entry" | awk '{print $1}')
            addr=$(echo "$entry" | awk '{print $2}')
            
            if [ -n "$name" ] && [ -n "$addr" ]; then
                DNS_ENTRIES+=("$name $addr")
                # По умолчанию добавляем PTR для записей в той же сети
                server_net=$(echo "$SERVER_IP" | cut -d'.' -f1-3)
                entry_net=$(echo "$addr" | cut -d'.' -f1-3)
                if [ "$server_net" = "$entry_net" ]; then
                    PTR_ENTRIES+=("$name $addr")
                fi
                msg_ok "Добавлено: $name.$DOMAIN → $addr"
            fi
        done
    fi
else
    echo ""
    echo -e "${CYAN}Введите DNS записи (имя IP):${NC}"
    echo -e "${YELLOW}Пример: hq-rtr 192.168.10.1${NC}"
    echo -e "${YELLOW}Пустая строка - завершить ввод${NC}"
    echo ""

    while true; do
        read -r -p "Запись: " entry
        [ -z "$entry" ] && break
        
        name=$(echo "$entry" | awk '{print $1}')
        addr=$(echo "$entry" | awk '{print $2}')
        
        if [ -n "$name" ] && [ -n "$addr" ]; then
            DNS_ENTRIES+=("$name $addr")
            read -r -p "Добавить PTR запись? (y/n) [n]: " add_ptr
            if [ "$add_ptr" = "y" ] || [ "$add_ptr" = "Y" ]; then
                PTR_ENTRIES+=("$name $addr")
            fi
        fi
    done
fi

# Проверка наличия записей
if [ ${#DNS_ENTRIES[@]} -eq 0 ]; then
    die "Не указано ни одной DNS записи"
fi

# Определение сети для обратной зоны
SERVER_NET=$(echo "$SERVER_IP" | cut -d'.' -f1-3)
REVERSE_ZONE="${SERVER_NET}.in-addr.arpa"

# Показ параметров
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}Параметры DNS:${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "  IP сервера:    ${YELLOW}$SERVER_IP${NC}"
echo -e "  Интерфейс:     ${YELLOW}$INTERFACE${NC}"
echo -e "  Домен:         ${YELLOW}$DOMAIN${NC}"
echo -e "  Пересылка:     ${YELLOW}$FORWARDER${NC}"
echo -e "  Обратная зона: ${YELLOW}$REVERSE_ZONE${NC}"
echo ""
echo -e "${YELLOW}A-записи (${#DNS_ENTRIES[@]}):${NC}"
for entry in "${DNS_ENTRIES[@]}"; do
    echo -e "  $(echo "$entry" | awk '{print $1}').$DOMAIN → $(echo "$entry" | awk '{print $2}')"
done
echo ""
echo -e "${YELLOW}PTR-записи (${#PTR_ENTRIES[@]}):${NC}"
for entry in "${PTR_ENTRIES[@]}"; do
    echo -e "  $(echo "$entry" | awk '{print $2}') → $(echo "$entry" | awk '{print $1}').$DOMAIN"
done
echo -e "${CYAN}══════════════════════════════════════════════${NC}"

if [ "$AUTO_MODE" = false ]; then
    echo ""
    read -r -p "Применить? (y/n): " confirm
    case "$confirm" in
        [Yy]*) ;;
        *) msg_in "Отменено"; exit 0 ;;
    esac
fi

# Установка пакета
echo ""
msg_in "Установка DNS сервера..."

case "$PKG_MANAGER" in
    apt-get)
        apt-get update -qq || msg_wrn "Не удалось обновить список пакетов"
        apt-get install -y $PKG_NAME || die "Ошибка установки пакета $PKG_NAME"
        ;;
    dnf)
        dnf install -y $PKG_NAME || die "Ошибка установки пакета $PKG_NAME"
        ;;
    yum)
        yum install -y $PKG_NAME || die "Ошибка установки пакета $PKG_NAME"
        ;;
esac

msg_ok "Пакет установлен: $PKG_NAME"

#===========================================
# КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Создание директорий
#===========================================
echo ""
msg_in "Создание необходимых директорий..."

# Создаём основную директорию
if [ ! -d "/var/named" ]; then
    mkdir -p /var/named || die "Не удалось создать /var/named"
    msg_ok "Создана директория /var/named"
else
    msg_ok "Директория /var/named существует"
fi

# Создаём поддиректорию для данных
if [ ! -d "/var/named/data" ]; then
    mkdir -p /var/named/data || die "Не удалось создать /var/named/data"
    msg_ok "Создана директория /var/named/data"
fi

# Создаём директорию для динамических зон (если используется)
if [ ! -d "/var/named/dynamic" ]; then
    mkdir -p /var/named/dynamic 2>/dev/null
fi

# Установка прав ownership
chown -R $NAMED_USER:$NAMED_USER /var/named 2>/dev/null || {
    # Попробуем alternative group
    chown -R root:$NAMED_USER /var/named 2>/dev/null || {
        msg_wrn "Не удалось изменить владельца /var/named (продолжаем)"
    }
}
chmod 775 /var/named
chmod 775 /var/named/data 2>/dev/null

msg_ok "Права на директории установлены"

# Создание named.conf
msg_in "Создание конфигурации named.conf..."

# Резервное копирование существующего конфига
if [ -f /etc/named.conf ]; then
    cp /etc/named.conf /etc/named.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null
fi

cat > /etc/named.conf << EOF
// DNS Server for Demo2026 - Auto-generated configuration
// Generated: $(date)

options {
    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 port 53 { ::1; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    recursing-file  "/var/named/data/named.recursing";
    secroots-file   "/var/named/data/named.secroots";
    
    allow-query     { any; };
    allow-recursion { any; };
    
    recursion yes;
    dnssec-enable no;
    dnssec-validation no;
    
    // DNS сервер пересылки
    forwarders { $FORWARDER; };
    forward only;
};

// Логирование
logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

// Зона прямого просмотра
zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.zone";
    allow-update { none; };
};

// Зона обратного просмотра для сети $SERVER_NET
zone "$REVERSE_ZONE" IN {
    type master;
    file "$DOMAIN.rev";
    allow-update { none; };
};
EOF

msg_ok "named.conf создан"

# Создание зоны прямого просмотра
msg_in "Создание зоны прямого просмотра..."

ZONE_FILE="/var/named/$DOMAIN.zone"

# Получаем компоненты IP для SOA
o1=$(echo "$SERVER_IP" | cut -d'.' -f1)
o2=$(echo "$SERVER_IP" | cut -d'.' -f2)
o3=$(echo "$SERVER_IP" | cut -d'.' -f3)

SERIAL=$(date +%Y%m%d01)

cat > "$ZONE_FILE" << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL      ; Serial (YYYYMMDDNN)
        3600         ; Refresh
        1800         ; Retry
        604800       ; Expire
        86400        ; Minimum TTL
)

; NS записи
@       IN  NS      ns1.$DOMAIN.

; Запись nameserver
ns1     IN  A       $SERVER_IP

EOF

# Добавляем A-записи
for entry in "${DNS_ENTRIES[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    addr=$(echo "$entry" | awk '{print $2}')
    echo "$name    IN  A       $addr" >> "$ZONE_FILE"
done

msg_ok "Зона прямого просмотра создана: $ZONE_FILE"

# Создание зоны обратного просмотра
msg_in "Создание зоны обратного просмотра..."

REV_FILE="/var/named/$DOMAIN.rev"

cat > "$REV_FILE" << EOF
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
        $SERIAL      ; Serial
        3600         ; Refresh
        1800         ; Retry
        604800       ; Expire
        86400        ; Minimum TTL
)

; NS записи
@       IN  NS      ns1.$DOMAIN.

EOF

# Добавляем PTR записи
for entry in "${PTR_ENTRIES[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    addr=$(echo "$entry" | awk '{print $2}')
    
    # Извлекаем последний октет для PTR
    last_octet=$(echo "$addr" | cut -d'.' -f4)
    echo "$last_octet     IN  PTR     $name.$DOMAIN." >> "$REV_FILE"
done

msg_ok "Зона обратного просмотра создана: $REV_FILE"

# Права на файлы зон
chown $NAMED_USER:$NAMED_USER "$ZONE_FILE" 2>/dev/null || chown root:$NAMED_USER "$ZONE_FILE" 2>/dev/null
chown $NAMED_USER:$NAMED_USER "$REV_FILE" 2>/dev/null || chown root:$NAMED_USER "$REV_FILE" 2>/dev/null
chown root:$NAMED_USER /etc/named.conf 2>/dev/null

chmod 640 "$ZONE_FILE" "$REV_FILE" /etc/named.conf

msg_ok "Права на файлы установлены"

# Проверка конфигурации
echo ""
msg_in "Проверка конфигурации..."

# Проверяем named.conf
if named-checkconf 2>&1; then
    msg_ok "named.conf валиден"
else
    msg_er "Ошибки в named.conf:"
    named-checkconf
    die "Исправьте ошибки конфигурации"
fi

# Проверяем зону прямого просмотра
if named-checkzone "$DOMAIN" "$ZONE_FILE" 2>&1; then
    msg_ok "Зона $DOMAIN валидна"
else
    msg_er "Ошибки в зоне $DOMAIN"
    named-checkzone "$DOMAIN" "$ZONE_FILE"
    die "Исправьте ошибки в файле зоны"
fi

# Проверяем зону обратного просмотра
if named-checkzone "$REVERSE_ZONE" "$REV_FILE" 2>&1; then
    msg_ok "Зона $REVERSE_ZONE валидна"
else
    msg_wrn "Зона обратного просмотра может быть пустой или содержать ошибки"
    named-checkzone "$REVERSE_ZONE" "$REV_FILE"
fi

# Firewall
echo ""
msg_in "Настройка firewall..."

if command -v nft >/dev/null 2>&1; then
    # nftables
    nft add table inet filter 2>/dev/null
    nft 'add chain inet filter input { type filter hook input priority 0 ; }' 2>/dev/null
    nft add rule inet filter input tcp dport 53 accept 2>/dev/null
    nft add rule inet filter input udp dport 53 accept 2>/dev/null
    msg_ok "Firewall настроен (nftables)"
elif command -v iptables >/dev/null 2>&1; then
    # iptables
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    msg_ok "Firewall настроен (iptables)"
elif command -v firewall-cmd >/dev/null 2>&1; then
    # firewalld
    firewall-cmd --permanent --add-service=dns 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    msg_ok "Firewall настроен (firewalld)"
else
    msg_wrn "Firewall не найден - убедитесь, что порт 53 открыт"
fi

# Запуск DNS сервера
echo ""
msg_in "Запуск DNS сервера..."

# Останавливаем сервис если запущен
systemctl stop $SERVICE_NAME 2>/dev/null

# Включаем и запускаем
systemctl enable $SERVICE_NAME 2>/dev/null
systemctl start $SERVICE_NAME

sleep 3

# Проверка статуса
if systemctl is-active --quiet $SERVICE_NAME; then
    msg_ok "DNS сервер запущен!"
else
    msg_er "Ошибка запуска DNS сервера"
    echo ""
    msg_in "Статус сервиса:"
    systemctl status $SERVICE_NAME --no-pager -l
    echo ""
    msg_in "Последние логи:"
    journalctl -u $SERVICE_NAME -n 30 --no-pager
    die "Не удалось запустить DNS сервер"
fi

# Настройка resolv.conf
echo ""
msg_in "Настройка resolv.conf..."

# Создаём backup
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
fi

# Проверяем, является ли resolv.conf символической ссылкой
if [ -L /etc/resolv.conf ]; then
    RESOLV_TARGET=$(readlink -f /etc/resolv.conf)
    msg_in "resolv.conf является ссылкой на $RESOLV_TARGET"
fi

# Добавляем локальный DNS сервер
if ! grep -q "nameserver $SERVER_IP" /etc/resolv.conf 2>/dev/null; then
    # Добавляем в начало файла
    sed -i "1i\nameserver $SERVER_IP" /etc/resolv.conf 2>/dev/null || \
        echo "nameserver $SERVER_IP" > /etc/resolv.conf
    msg_ok "Локальный DNS добавлен в resolv.conf"
fi

# Добавляем search домен
if ! grep -q "search.*$DOMAIN" /etc/resolv.conf 2>/dev/null; then
    echo "search $DOMAIN" >> /etc/resolv.conf
    msg_ok "Search домен добавлен в resolv.conf"
fi

# Финальный отчёт
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DNS СЕРВЕР УСПЕШНО НАСТРОЕН!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}IP сервера:${NC}       ${YELLOW}$SERVER_IP${NC}"
echo -e "  ${CYAN}Домен:${NC}            ${YELLOW}$DOMAIN${NC}"
echo -e "  ${CYAN}DNS пересылки:${NC}    ${YELLOW}$FORWARDER${NC}"
echo -e "  ${CYAN}Обратная зона:${NC}    ${YELLOW}$REVERSE_ZONE${NC}"
echo ""
echo -e "  ${CYAN}Файлы конфигурации:${NC}"
echo -e "    ${YELLOW}/etc/named.conf${NC}"
echo -e "    ${YELLOW}$ZONE_FILE${NC}"
echo -e "    ${YELLOW}$REV_FILE${NC}"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo -e "  ${YELLOW}nslookup hq-rtr.$DOMAIN $SERVER_IP${NC}"
echo -e "  ${YELLOW}nslookup 192.168.10.1 $SERVER_IP${NC}"
echo -e "  ${YELLOW}dig @$SERVER_IP hq-rtr.$DOMAIN${NC}"
echo -e "  ${YELLOW}dig @$SERVER_IP -x 192.168.10.1${NC}"
echo ""
echo -e "${CYAN}Логи:${NC}"
echo -e "  ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}"
echo ""
