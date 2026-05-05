#!/bin/bash

# ============================================================================
# DNS Infrastructure Setup Script for ALT Linux
# Версия: 2.0
# Поддержка: ALT Linux Server 10.4+
# ============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Логирование
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Определение версии ОС
detect_os() {
    log_step "Определение версии ОС..."
    
    if [ -f /etc/altlinux-release ]; then
        OS_VERSION=$(cat /etc/altlinux-release | grep -oP '\d+\.\d+' | head -1)
        log_info "Обнаружен ALT Linux версии: $OS_VERSION"
    elif [ -f /etc/os-release ]; then
        OS_VERSION=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release)
        log_info "Обнаружена ОС версии: $OS_VERSION"
    else
        log_warn "Не удалось определить версию ОС, продолжаем..."
        OS_VERSION="unknown"
    fi
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Скрипт должен быть запущен от root"
        exit 1
    fi
}

# Установка пакетов
install_packages() {
    log_step "Установка необходимых пакетов..."
    
    # Определение менеджера пакетов
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        apt-get update
        apt-get install -y bind9 bind9utils dnsutils
    elif command -v urpmi &> /dev/null; then
        PKG_MANAGER="urpmi"
        urpmi.update -a
        urpmi bind bind-utils
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        yum install -y bind bind-utils
    else
        log_error "Менеджер пакетов не найден"
        exit 1
    fi
    
    log_info "Пакеты установлены успешно"
}

# Интерактивный ввод данных
collect_data() {
    log_step "Сбор информации о сети"
    echo ""
    
    # Автоматическое определение IP
    DEFAULT_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    read -p "IP-адрес DNS сервера (HQ-SRV) [$DEFAULT_IP]: " HQ_IP
    HQ_IP=${HQ_IP:-$DEFAULT_IP}
    
    # Определение сетевого интерфейса
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    read -p "Сетевой интерфейс [$DEFAULT_IFACE]: " NETWORK_IFACE
    NETWORK_IFACE=${NETWORK_IFACE:-$DEFAULT_IFACE}
    
    # Определение подсети
    DEFAULT_NET=$(ip addr show $NETWORK_IFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')
    read -p "Сетевой адрес (например, 192.168.1.0) [$DEFAULT_NET]: " NETWORK_ADDR
    NETWORK_ADDR=${NETWORK_ADDR:-$DEFAULT_NET}
    
    # Получение маски подсети
    DEFAULT_MASK=$(ip addr show $NETWORK_IFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f2)
    read -p "Маска подсети (CIDR, например 24) [$DEFAULT_MASK]: " SUBNET_MASK
    SUBNET_MASK=${SUBNET_MASK:-$DEFAULT_MASK}
    
    # Доменное имя
    read -p "Доменное имя организации (например, au-team.irpo): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then
        log_error "Доменное имя обязательно"
        exit 1
    fi
    
    # Имя хоста сервера
    DEFAULT_HOSTNAME="hq-srv"
    read -p "Имя хоста DNS сервера [$DEFAULT_HOSTNAME]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
    
    # FQDN
    FQDN="${HOSTNAME}.${DOMAIN_NAME}"
    
    # Forwarders
    echo ""
    log_info "Настройка пересылки запросов (forwarders)"
    echo "Доступные публичные DNS:"
    echo "  1) Яндекс DNS (77.88.8.8, 77.88.8.1)"
    echo "  2) Google DNS (8.8.8.8, 8.8.4.4)"
    echo "  3) Cloudflare (1.1.1.1, 1.0.0.1)"
    echo "  4) Свои DNS серверы"
    read -p "Выберите вариант [1]: " FORWARDER_CHOICE
    FORWARDER_CHOICE=${FORWARDER_CHOICE:-1}
    
    case $FORWARDER_CHOICE in
        1)
            FORWARDER1="77.88.8.8"
            FORWARDER2="77.88.8.1"
            ;;
        2)
            FORWARDER1="8.8.8.8"
            FORWARDER2="8.8.4.4"
            ;;
        3)
            FORWARDER1="1.1.1.1"
            FORWARDER2="1.0.0.1"
            ;;
        4)
            read -p "Первичный DNS forwarder: " FORWARDER1
            read -p "Вторичный DNS forwarder: " FORWARDER2
            ;;
        *)
            FORWARDER1="77.88.8.8"
            FORWARDER2="77.88.8.1"
            ;;
    esac
    
    log_info "Forwarders: $FORWARDER1, $FORWARDER2"
    
    # Количество хостов для добавления
    echo ""
    read -p "Сколько хостов добавить в зону (HQ-CLI, HQ-SW, BR и т.д.) [5]: " HOST_COUNT
    HOST_COUNT=${HOST_COUNT:-5}
    
    # Массивы для хранения данных
    declare -g -a HOST_NAMES
    declare -g -a HOST_IPS
    
    for ((i=1; i<=$HOST_COUNT; i++)); do
        echo ""
        log_info "Хост #$i"
        read -p "  Имя хоста (например, hq-cli, hq-sw, br-srv): " host_name
        if [ -z "$host_name" ]; then
            log_warn "Пропущен хост #$i"
            continue
        fi
        
        read -p "  IP-адрес: " host_ip
        if [ -z "$host_ip" ]; then
            log_warn "IP не указан для $host_name"
            continue
        fi
        
        HOST_NAMES+=("$host_name")
        HOST_IPS+=("$host_ip")
    done
    
    # Вывод собранной информации
    echo ""
    log_step "Собранная информация:"
    echo "  DNS Сервер: $FQDN"
    echo "  IP-адрес: $HQ_IP"
    echo "  Сеть: $NETWORK_ADDR/$SUBNET_MASK"
    echo "  Домен: $DOMAIN_NAME"
    echo "  Forwarders: $FORWARDER1, $FORWARDER2"
    echo "  Хостов: ${#HOST_NAMES[@]}"
    
    read -p "Продолжить настройку? [y/N]: " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        log_error "Настройка отменена"
        exit 1
    fi
}

# Создание директорий
create_directories() {
    log_step "Создание необходимых директорий..."
    
    mkdir -p /var/named/data
    mkdir -p /var/named/dynamic
    mkdir -p /var/named/slaves
    
    chown -R named:named /var/named
    chmod 750 /var/named
    chmod 750 /var/named/data
    chmod 750 /var/named/dynamic
    chmod 750 /var/named/slaves
    
    log_info "Директории созданы"
}

# Генерация rndc ключа
generate_rndc_key() {
    log_step "Генерация rndc ключа..."
    
    if [ ! -f /etc/rndc.key ]; then
        rndc-confgen -a -q
        chown named:named /etc/rndc.key
        chmod 640 /etc/rndc.key
        log_info "rndc ключ сгенерирован"
    else
        log_warn "rndc ключ уже существует"
    fi
}

# Создание named.conf
create_named_conf() {
    log_step "Создание конфигурации named.conf..."
    
    # Определение обратного зоны (reverse zone)
    REVERSE_ZONE=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')
    
    cat > /etc/named.conf << EOF
//
// named.conf - конфигурация BIND DNS сервера
// Сгенерировано автоматически $(date)
//

options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { ::1; };
    
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    pid-file "/run/named/named.pid";
    
    // Разрешаем рекурсию для локальной сети
    allow-recursion { 
        localhost; 
        127.0.0.1; 
        ${NETWORK_ADDR}/${SUBNET_MASK};
    };
    
    allow-query { any; };
    allow-query-cache { any; };
    
    // Forwarders - публичные DNS
    forwarders {
        ${FORWARDER1};
        ${FORWARDER2};
    };
    
    forward only;
    
    dnssec-validation no;
    
    // Логирование
    logging {
        channel default_log {
            file "/var/named/data/named.log" versions 3 size 5m;
            severity info;
            print-time yes;
            print-severity yes;
            print-category yes;
        };
        
        category default { default_log; };
    };
};

// Ключ для rndc
include "/etc/rndc.key";

controls {
    inet 127.0.0.1 allow { localhost; } keys { "rndc-key"; };
};

// Зона прямого разрешения (Forward Zone)
zone "${DOMAIN_NAME}" IN {
    type master;
    file "zones/${DOMAIN_NAME}.zone";
    allow-update { none; };
    allow-transfer { none; };
};

// Зона обратного разрешения (Reverse Zone)
zone "${REVERSE_ZONE}.in-addr.arpa" IN {
    type master;
    file "zones/${REVERSE_ZONE}.reverse";
    allow-update { none; };
    allow-transfer { none; };
};

// Локальные зоны
zone "localhost" IN {
    type master;
    file "named.localhost";
    allow-update { none; };
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "named.loopback";
    allow-update { none; };
};
EOF

    log_info "named.conf создан"
}

# Создание зоны прямого разрешения
create_forward_zone() {
    log_step "Создание зоны прямого разрешения..."
    
    mkdir -p /var/named/zones
    
    SERIAL=$(date +%Y%m%d01)
    
    cat > /var/named/zones/${DOMAIN_NAME}.zone << EOF
\$TTL 86400
@   IN  SOA ${HOSTNAME}.${DOMAIN_NAME}. root.${DOMAIN_NAME}. (
        ${SERIAL}     ; Serial
        3600          ; Refresh
        1800          ; Retry
        604800        ; Expire
        86400 )       ; Minimum TTL

; NS Records
@       IN  NS      ${HOSTNAME}.${DOMAIN_NAME}.

; A Records - DNS Server
${HOSTNAME}   IN  A       ${HQ_IP}

; A Records - Hosts
EOF

    # Добавление хостов
    for i in "${!HOST_NAMES[@]}"; do
        echo "${HOST_NAMES[$i]}   IN  A       ${HOST_IPS[$i]}" >> /var/named/zones/${DOMAIN_NAME}.zone
    done
    
    # Добавление записи для самого домена
    echo "" >> /var/named/zones/${DOMAIN_NAME}.zone
    echo "; Domain A Record" >> /var/named/zones/${DOMAIN_NAME}.zone
    echo "@       IN  A       ${HQ_IP}" >> /var/named/zones/${DOMAIN_NAME}.zone
    
    # MX Record (опционально)
    echo "" >> /var/named/zones/${DOMAIN_NAME}.zone
    echo "; MX Record" >> /var/named/zones/${DOMAIN_NAME}.zone
    echo "@       IN  MX  10  ${HOSTNAME}.${DOMAIN_NAME}." >> /var/named/zones/${DOMAIN_NAME}.zone
    
    chown named:named /var/named/zones/${DOMAIN_NAME}.zone
    chmod 640 /var/named/zones/${DOMAIN_NAME}.zone
    
    log_info "Зона прямого разрешения создана: /var/named/zones/${DOMAIN_NAME}.zone"
}

# Создание зоны обратного разрешения
create_reverse_zone() {
    log_step "Создание зоны обратного разрешения..."
    
    REVERSE_ZONE=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')
    SERIAL=$(date +%Y%m%d01)
    
    cat > /var/named/zones/${REVERSE_ZONE}.reverse << EOF
\$TTL 86400
@   IN  SOA ${HOSTNAME}.${DOMAIN_NAME}. root.${DOMAIN_NAME}. (
        ${SERIAL}     ; Serial
        3600          ; Refresh
        1800          ; Retry
        604800        ; Expire
        86400 )       ; Minimum TTL

; NS Records
@       IN  NS      ${HOSTNAME}.${DOMAIN_NAME}.

; PTR Records
EOF

    # Добавление PTR записей для DNS сервера
    DNS_LAST_OCTET=$(echo $HQ_IP | awk -F. '{print $4}')
    echo "${DNS_LAST_OCTET}   IN  PTR   ${HOSTNAME}.${DOMAIN_NAME}." >> /var/named/zones/${REVERSE_ZONE}.reverse
    
    # Добавление PTR записей для хостов
    for i in "${!HOST_IPS[@]}"; do
        LAST_OCTET=$(echo ${HOST_IPS[$i]} | awk -F. '{print $4}')
        echo "${LAST_OCTET}   IN  PTR   ${HOST_NAMES[$i]}.${DOMAIN_NAME}." >> /var/named/zones/${REVERSE_ZONE}.reverse
    done
    
    chown named:named /var/named/zones/${REVERSE_ZONE}.reverse
    chmod 640 /var/named/zones/${REVERSE_ZONE}.reverse
    
    log_info "Зона обратного разрешения создана: /var/named/zones/${REVERSE_ZONE}.reverse"
}

# Создание стандартных зон
create_standard_zones() {
    log_step "Создание стандартных зон..."
    
    # named.localhost
    if [ ! -f /var/named/named.localhost ]; then
        cat > /var/named/named.localhost << 'EOF'
$TTL 1D
@   IN SOA @ root.localhost. (
                1       ; serial
                1H      ; refresh
                15M     ; retry
                1W      ; expire
                1D )    ; minimum
    NS  @
    A   127.0.0.1
EOF
        chown named:named /var/named/named.localhost
    fi
    
    # named.loopback
    if [ ! -f /var/named/named.loopback ]; then
        cat > /var/named/named.loopback << 'EOF'
$TTL 1D
@   IN SOA @ root.localhost. (
                1       ; serial
                1H      ; refresh
                15M     ; retry
                1W      ; expire
                1D )    ; minimum
    NS  @
    PTR localhost.
EOF
        chown named:named /var/named/named.loopback
    fi
    
    # named.ca (корневые серверы)
    if [ ! -f /var/named/named.ca ]; then
        curl -s https://www.internic.net/domain/named.cache -o /var/named/named.ca 2>/dev/null || \
        cat > /var/named/named.ca << 'EOF'
; Это заглушка для named.ca
; В продакшене используйте актуальный файл
EOF
        chown named:named /var/named/named.ca
    fi
    
    log_info "Стандартные зоны созданы"
}

# Создание файла лога
create_log_file() {
    log_step "Создание файла логов..."
    
    touch /var/named/data/named.log
    chown named:named /var/named/data/named.log
    chmod 660 /var/named/data/named.log
    
    log_info "Файл логов создан"
}

# Проверка конфигурации
check_config() {
    log_step "Проверка конфигурации..."
    
    # Проверка named.conf
    if named-checkconf /etc/named.conf; then
        log_info "named.conf: OK"
    else
        log_error "named.conf: ОШИБКА"
        exit 1
    fi
    
    # Проверка зон
    if named-checkzone ${DOMAIN_NAME} /var/named/zones/${DOMAIN_NAME}.zone > /dev/null 2>&1; then
        log_info "Зона прямого разрешения: OK"
    else
        log_error "Зона прямого разрешения: ОШИБКА"
        exit 1
    fi
    
    REVERSE_ZONE=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')
    if named-checkzone ${REVERSE_ZONE}.in-addr.arpa /var/named/zones/${REVERSE_ZONE}.reverse > /dev/null 2>&1; then
        log_info "Зона обратного разрешения: OK"
    else
        log_error "Зона обратного разрешения: ОШИБКА"
        exit 1
    fi
    
    log_info "Все проверки пройдены"
}

# Настройка firewall
setup_firewall() {
    log_step "Настройка брандмауэра..."
    
    # Проверка наличия firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Обнаружен firewalld"
        firewall-cmd --permanent --add-service=dns >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "firewalld настроен"
    fi
    
    # Проверка iptables
    if command -v iptables &> /dev/null; then
        log_info "Настройка iptables..."
        iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport 53 -j ACCEPT
        iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport 53 -j ACCEPT
        log_info "iptables настроен"
    fi
}

# Настройка systemd сервиса
setup_systemd() {
    log_step "Настройка systemd сервиса..."
    
    # Проверка наличия service файла
    if [ ! -f /etc/systemd/system/named.service ] && [ ! -f /usr/lib/systemd/system/named.service ]; then
        log_warn "Service файл named не найден, создаём..."
        
        cat > /etc/systemd/system/named.service << 'EOF'
[Unit]
Description=BIND DNS Server
Documentation=man:named(8)
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/named -c /etc/named.conf
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/run/named/named.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        log_info "Service файл создан"
    fi
}

# Запуск и настройка сервиса
start_service() {
    log_step "Запуск DNS сервера..."
    
    # Создание директории для PID
    mkdir -p /run/named
    chown named:named /run/named
    
    # Включение и запуск
    systemctl enable named 2>/dev/null || systemctl enable bind9 2>/dev/null || true
    systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null || true
    
    sleep 2
    
    # Проверка статуса
    if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
        log_info "DNS сервер запущен успешно"
    else
        log_warn "DNS сервер не запустился. Проверяем логи..."
        journalctl -xeu named -n 20 --no-pager 2>/dev/null || \
        journalctl -xeu bind9 -n 20 --no-pager 2>/dev/null || true
    fi
}

# Тестирование DNS
test_dns() {
    log_step "Тестирование DNS сервера..."
    
    echo ""
    log_info "Проверка разрешения имён..."
    
    # Прямое разрешение
    for i in "${!HOST_NAMES[@]}"; do
        FQDN_HOST="${HOST_NAMES[$i]}.${DOMAIN_NAME}"
        if dig @localhost $FQDN_HOST +short | grep -q "${HOST_IPS[$i]}"; then
            log_info "✓ $FQDN_HOST -> ${HOST_IPS[$i]}"
        else
            log_warn "✗ $FQDN_HOST - ошибка"
        fi
    done
    
    # Обратное разрешение
    echo ""
    log_info "Проверка обратного разрешения..."
    for ip in "${HOST_IPS[@]}"; do
        if dig @localhost -x $ip +short | grep -q "${DOMAIN_NAME}"; then
            log_info "✓ $ip -> обратное разрешение OK"
        else
            log_warn "✗ $ip - ошибка обратного разрешения"
        fi
    done
    
    # Проверка рекурсии
    echo ""
    log_info "Проверка рекурсии (внешние запросы)..."
    if dig @localhost google.com +short | grep -q "."; then
        log_info "✓ Рекурсия работает"
    else
        log_warn "✗ Рекурсия не работает"
    fi
    
    echo ""
    log_info "Статистика сервера:"
    rndc status 2>/dev/null || true
}

# Вывод итоговой информации
show_summary() {
    echo ""
    echo "================================================================"
    echo -e "${GREEN}          НАСТРОЙКА DNS ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo "================================================================"
    echo ""
    echo "Основные параметры:"
    echo "  DNS Сервер: $FQDN"
    echo "  IP-адрес: $HQ_IP"
    echo "  Домен: $DOMAIN_NAME"
    echo "  Сеть: $NETWORK_ADDR/$SUBNET_MASK"
    echo ""
    echo "Зоны:"
    echo "  Прямая: /var/named/zones/${DOMAIN_NAME}.zone"
    REVERSE_ZONE=$(echo $NETWORK_ADDR | sed 's/\.[0-9]*$//')
    echo "  Обратная: /var/named/zones/${REVERSE_ZONE}.reverse"
    echo ""
    echo "Полезные команды:"
    echo "  Проверка статуса:    systemctl status named"
    echo "  Просмотр логов:      tail -f /var/named/data/named.log"
    echo "  Перезагрузка зон:    rndc reload"
    echo "  Проверка DNS:        dig @localhost ${HOST_NAMES[0]:-hq-cli}.${DOMAIN_NAME}"
    echo "  Статистика:          rndc status"
    echo ""
    echo "Добавленные хосты:"
    for i in "${!HOST_NAMES[@]}"; do
        echo "  ${HOST_NAMES[$i]}.${DOMAIN_NAME} -> ${HOST_IPS[$i]}"
    done
    echo ""
    echo "================================================================"
}

# Основная функция
main() {
    echo ""
    echo "================================================================"
    echo -e "${BLUE}    DNS Infrastructure Setup for ALT Linux${NC}"
    echo "    Версия: 2.0 | $(date)"
    echo "================================================================"
    echo ""
    
    check_root
    detect_os
    install_packages
    collect_data
    create_directories
    generate_rndc_key
    create_named_conf
    create_standard_zones
    create_forward_zone
    create_reverse_zone
    create_log_file
    check_config
    setup_firewall
    setup_systemd
    start_service
    test_dns
    show_summary
    
    log_info "Настройка завершена!"
}

# Запуск
main "$@"
