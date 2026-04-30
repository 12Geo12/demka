#!/bin/bash
################################################################################
# Скрипт настройки DNS сервера (BIND) для ALT Linux Server
# Версия: 5.0 - Интерактивный с автоопределением интерфейсов
# GitHub: https://github.com/stepanovs2005/Demo2026#19-настройка-dns-и-dhcp
################################################################################

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/dns-setup-$(date +%Y%m%d-%H%M%S).log"

# Функции логирования
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
error() { log "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Требуется root (используйте sudo или запустите от root)"
    fi
}

# Функция получения IP адреса интерфейса
get_ip() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

# Функция получения статуса интерфейса (UP/DOWN)
get_state() {
    local iface="$1"
    cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "unknown"
}

# Функция автоматического определения интерфейсов
detect_interfaces() {
    info "Поиск доступных сетевых интерфейсов..."

    ALL_IFACES=($(ls /sys/class/net 2>/dev/null))
    VALID_IFACES=()
    VALID_IPS=()

    for iface in "${ALL_IFACES[@]}"; do
        # Пропускаем loopback
        if [[ "$iface" == "lo" ]]; then continue; fi

        IP_ADDR=$(get_ip "$iface")
        STATE=$(get_state "$iface")

        # Показываем все интерфейсы для отладки
        info "  -> $iface: State=$STATE, IP=${IP_ADDR:-'Отсутствует'}"

        # Если интерфейс включен и имеет IP адрес
        if [[ -n "$IP_ADDR" ]]; then
            VALID_IFACES+=("$iface")
            VALID_IPS+=("$IP_ADDR")
        fi
    done

    if [ ${#VALID_IFACES[@]} -eq 0 ]; then
        warn "Не найдено интерфейсов с IP-адресами!"
        warn "Список всех интерфейсов:"
        for iface in "${ALL_IFACES[@]}"; do
            if [[ "$iface" != "lo" ]]; then
                STATE=$(get_state "$iface")
                IP=$(get_ip "$iface")
                echo "   - $iface (Статус: $STATE, IP: ${IP:-'Отсутствует'})"
            fi
        done
        echo ""
        warn "Настройте сеть (назначьте IP адреса) через:"
        echo "   nmtui   (NetworkManager Text UI)"
        echo "   или отредактируйте файлы в /etc/net/ifaces/"
        return 1
    fi

    return 0
}

# Функция выбора интерфейса пользователем
select_interface() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}         ВЫБОР СЕТЕВОГО ИНТЕРФЕЙСА${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo "Выберите интерфейс, на котором будет работать DNS:"
    echo ""

    PS3="${YELLOW}Введите номер интерфейса:${NC} "

    # Создаем массив для отображения
    DISPLAY_IFACES=()
    for i in "${!VALID_IFACES[@]}"; do
        DISPLAY_IFACES+=("${VALID_IFACES[$i]} (${VALID_IPS[$i]})")
    done

    select item in "${DISPLAY_IFACES[@]}" "Выход"; do
        if [[ "$item" == "Выход" ]]; then
            info "Выход из скрипта"
            exit 0
        fi
        if [[ -n "$item" ]]; then
            LAN_IFACE=$(echo "$item" | cut -d' ' -f1)
            LAN_IP=$(echo "$item" | cut -d'(' -f2 | tr -d ')')
            break
        else
            warn "Неверный выбор, попробуйте еще раз."
        fi
    done

    echo ""
    success "Выбран интерфейс: $LAN_IFACE"
    success "IP адрес: $LAN_IP"
}

# Функция ввода параметров DNS
input_dns_params() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}         ВВОД ПАРАМЕТРОВ DNS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    # Домен
    read -p "Доменное имя [au-team.irpo]: " DOMAIN
    DOMAIN=${DOMAIN:-au-team.irpo}

    # IP сервера (предлагаем выбранный)
    read -p "IP этого сервера [$LAN_IP]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-$LAN_IP}

    # Дополнительные хосты
    echo ""
    info "Введите IP для хостов (оставьте пустым, если не нужно):"

    read -p "  IP HQ-RTR (роутер головного офиса): " ROUTER_IP
    ROUTER_IP=${ROUTER_IP:-}

    read -p "  IP HQ-CLI (клиент головного офиса): " CLI_IP
    CLI_IP=${CLI_IP:-}

    read -p "  IP BR-RTR (роутер филиала): " BR_RTR_IP
    BR_RTR_IP=${BR_RTR_IP:-}

    read -p "  IP BR-SRV (сервер филиала): " BR_SRV_IP
    BR_SRV_IP=${BR_SRV_IP:-}

    # Форвардеры
    echo ""
    info "Настройка DNS-форвардеров (внешние DNS для разрешения интернет-запросов):"

    read -p "  Первичный форвардер [77.88.8.8 (Яндекс)]: " FORWARDER1
    FORWARDER1=${FORWARDER1:-77.88.8.8}

    read -p "  Вторичный форвардер [77.88.8.3 (Яндекс)]: " FORWARDER2
    FORWARDER2=${FORWARDER2:-77.88.8.3}

    # Показываем сводку
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo "Параметры конфигурации:"
    echo -e "  ${GREEN}Домен:${NC}           $DOMAIN"
    echo -e "  ${GREEN}IP сервера:${NC}      $SERVER_IP"
    echo -e "  ${GREEN}Интерфейс:${NC}       $LAN_IFACE"
    [[ -n "$ROUTER_IP" ]] && echo -e "  ${GREEN}HQ-RTR:${NC}          $ROUTER_IP"
    [[ -n "$CLI_IP" ]] && echo -e "  ${GREEN}HQ-CLI:${NC}          $CLI_IP"
    [[ -n "$BR_RTR_IP" ]] && echo -e "  ${GREEN}BR-RTR:${NC}          $BR_RTR_IP"
    [[ -n "$BR_SRV_IP" ]] && echo -e "  ${GREEN}BR-SRV:${NC}          $BR_SRV_IP"
    echo -e "  ${GREEN}Forwarder 1:${NC}     $FORWARDER1"
    echo -e "  ${GREEN}Forwarder 2:${NC}     $FORWARDER2"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo ""

    read -p "Продолжить настройку? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Настройка отменена"
        return 1
    fi

    return 0
}

# Функция установки BIND
install_bind() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}         УСТАНОВКА BIND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

    info "Обновление списка пакетов..."
    apt-get update > /dev/null 2>&1

    info "Установка пакетов BIND..."
    if command -v named &>/dev/null; then
        success "BIND уже установлен"
    else
        apt-get install -y bind bind-utils 2>/dev/null || apt-get install -y bind 2>/dev/null || {
            error "Не удалось установить BIND. Проверьте подключение к интернету."
        }
    fi

    if ! command -v named &>/dev/null; then
        error "named не найден после установки"
    fi

    success "BIND установлен"
}

# Функция создания директорий
create_directories() {
    info "Создание директорий..."

    mkdir -p /etc/bind
    mkdir -p /var/lib/bind
    mkdir -p /var/lib/bind/zones
    mkdir -p /var/log/bind
    mkdir -p /var/run/named

    # Устанавливаем права
    chown -R root:root /etc/bind
    chown -R root:root /var/lib/bind
    chown -R root:root /var/lib/bind/zones
    chown -R root:root /var/log/bind
    chown -R root:root /var/run/named

    chmod 755 /etc/bind
    chmod 755 /var/lib/bind
    chmod 755 /var/lib/bind/zones
    chmod 755 /var/log/bind
    chmod 755 /var/run/named

    success "Директории созданы"
}

# Функция создания конфигурации named.conf
create_named_conf() {
    info "Создание named.conf..."

    # Резервное копирование
    [[ -f /etc/named.conf ]] && cp /etc/named.conf /etc/named.conf.bak.$(date +%Y%m%d%H%M%S)

    cat > /etc/named.conf << EOF
// BIND Configuration for ALT Linux
// Generated: $(date)
// Interface: $LAN_IFACE ($SERVER_IP)

options {
    directory "/var/lib/bind";
    pid-file "/var/run/named/named.pid";

    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 port 53 { none; };

    allow-query { any; };
    recursion yes;
    allow-recursion { any; };

    forwarders {
        $FORWARDER1;
        $FORWARDER2;
    };
    forward only;

    dnssec-validation no;
};

logging {
    channel default_log {
        file "/var/log/bind/bind.log" versions 3 size 5m;
        severity info;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default { default_log; };
};

include "/etc/bind/named.conf.local";
EOF

    success "named.conf создан"
}

# Функция создания зон
create_zones() {
    info "Создание зон..."

    SERIAL=$(date +%Y%m%d)01

    # Прямая зона
    cat > /var/lib/bind/zones/db.$DOMAIN << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400
)

@       IN  NS      hq-srv.$DOMAIN.

EOF

    # Добавляем записи A
    [[ -n "$ROUTER_IP" ]] && echo "hq-rtr      IN  A       $ROUTER_IP" >> /var/lib/bind/zones/db.$DOMAIN
    echo "hq-srv      IN  A       $SERVER_IP" >> /var/lib/bind/zones/db.$DOMAIN
    [[ -n "$CLI_IP" ]] && echo "hq-cli      IN  A       $CLI_IP" >> /var/lib/bind/zones/db.$DOMAIN
    [[ -n "$BR_RTR_IP" ]] && echo "br-rtr      IN  A       $BR_RTR_IP" >> /var/lib/bind/zones/db.$DOMAIN
    [[ -n "$BR_SRV_IP" ]] && echo "br-srv      IN  A       $BR_SRV_IP" >> /var/lib/bind/zones/db.$DOMAIN

    # Дополнительные записи
    cat >> /var/lib/bind/zones/db.$DOMAIN << EOF

docker      IN  A       172.16.4.1
web         IN  A       172.16.5.1
moodle      IN  CNAME   hq-rtr.$DOMAIN.
wiki        IN  CNAME   hq-rtr.$DOMAIN.
ftp         IN  CNAME   hq-srv.$DOMAIN.
mail        IN  CNAME   hq-srv.$DOMAIN.
@           IN  MX  10  hq-srv.$DOMAIN.
EOF

    chmod 644 /var/lib/bind/zones/db.$DOMAIN
    success "Прямая зона создана: db.$DOMAIN"

    # Обратные зоны (если указаны IP)
    if [[ -n "$ROUTER_IP" ]]; then
        create_reverse_zone "192.168.10" "10.168.192.in-addr.arpa" "$ROUTER_IP" "hq-rtr"
    fi

    if [[ -n "$CLI_IP" ]]; then
        create_reverse_zone "192.168.20" "20.168.192.in-addr.arpa" "$CLI_IP" "hq-cli"
    fi

    # ISP зоны
    create_reverse_zone "172.16.4" "4.16.172.in-addr.arpa" "172.16.4.1" "docker"
    create_reverse_zone "172.16.5" "5.16.172.in-addr.arpa" "172.16.5.1" "web"

    success "Зоны созданы"
}

# Вспомогательная функция для создания обратной зоны
create_reverse_zone() {
    local subnet="$1"
    local zone_name="$2"
    local ip="$3"
    local hostname="$4"

    local last_octet=$(echo $ip | cut -d. -f4)
    local SERIAL=$(date +%Y%m%d)01

    # Для подсетей 172.16.x используем первый октет после 172.16
    if [[ "$subnet" == "172.16.4" ]]; then
        last_octet=1
    elif [[ "$subnet" == "172.16.5" ]]; then
        last_octet=1
    fi

    cat > /var/lib/bind/zones/db.$subnet << EOF
\$TTL 86400
@   IN  SOA hq-srv.$DOMAIN. admin.$DOMAIN. (
        $SERIAL
        3600
        1800
        604800
        86400
)
@       IN  NS      hq-srv.$DOMAIN.
$last_octet       IN  PTR     $hostname.$DOMAIN.
EOF

    chmod 644 /var/lib/bind/zones/db.$subnet
    info "  -> Обратная зона создана: db.$subnet"
}

# Функция создания named.conf.local
create_named_conf_local() {
    info "Создание named.conf.local..."

    cat > /etc/bind/named.conf.local << EOF
zone "$DOMAIN" {
    type master;
    file "/var/lib/bind/zones/db.$DOMAIN";
    allow-transfer { none; };
};
EOF

    # Добавляем обратные зоны
    if [[ -n "$ROUTER_IP" ]]; then
        cat >> /etc/bind/named.conf.local << EOF
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.192.168.10";
    allow-transfer { none; };
};
EOF
    fi

    if [[ -n "$CLI_IP" ]]; then
        cat >> /etc/bind/named.conf.local << EOF
zone "20.168.192.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.192.168.20";
    allow-transfer { none; };
};
EOF
    fi

    # ISP зоны
    cat >> /etc/bind/named.conf.local << EOF
zone "4.16.172.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.172.16.4";
    allow-transfer { none; };
};
zone "5.16.172.in-addr.arpa" {
    type master;
    file "/var/lib/bind/zones/db.172.16.5";
    allow-transfer { none; };
};
EOF

    chmod 644 /etc/bind/named.conf.local
    success "named.conf.local создан"
}

# Функция проверки конфигурации
check_config() {
    info "Проверка конфигурации..."

    if named-checkconf 2>&1; then
        success "Конфигурация named.conf корректна"
    else
        error "Ошибка в named.conf"
    fi

    if named-checkzone "$DOMAIN" /var/lib/bind/zones/db.$DOMAIN 2>&1; then
        success "Зона $DOMAIN корректна"
    else
        error "Ошибка в зоне $DOMAIN"
    fi
}

# Функция запуска DNS сервера
start_dns() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}         ЗАПУСК DNS СЕРВЕРА${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

    info "Остановка старых процессов named..."
    pkill named 2>/dev/null || true
    sleep 2

    info "Запуск named..."
    touch /var/log/bind/bind.log
    chmod 644 /var/log/bind/bind.log

    # Запускаем named
    cd /var/lib/bind
    named -c /etc/named.conf &
    sleep 3

    if pgrep -x named &>/dev/null; then
        local PID=$(pgrep -x named)
        success "named запущен (PID: $PID)"
    else
        error "named не запустился. Выполните: cd /var/lib/bind && named -c /etc/named.conf -g"
    fi
}

# Функция тестирования DNS
test_dns() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}           ТЕСТИРОВАНИЕ DNS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

    echo ""

    # Прямое разрешение
    if dig @$SERVER_IP hq-srv.$DOMAIN +short 2>/dev/null | grep -q "$SERVER_IP"; then
        success "✓ Прямое разрешение работает (hq-srv.$DOMAIN -> $SERVER_IP)"
    else
        warn "✗ Прямое разрешение не работает"
    fi

    # Обратное разрешение (если есть ROUTER_IP)
    if [[ -n "$ROUTER_IP" ]]; then
        if dig -x $ROUTER_IP @$SERVER_IP +short 2>/dev/null | grep -q "hq-rtr"; then
            success "✓ Обратное разрешение работает"
        else
            warn "✗ Обратное разрешение не работает"
        fi
    fi

    # Внешние DNS
    if dig @$SERVER_IP ya.ru +short 2>/dev/null | grep -q "."; then
        success "✓ Внешние DNS работают (форвардеры)"
    else
        warn "✗ Внешние DNS не работают (проверьте форвардеры)"
    fi

    # Проверка порта
    if ss -tulpn | grep -q ":53 "; then
        success "✓ Порт 53 открыт"
    else
        warn "✗ Порт 53 не прослушивается"
    fi
}

# Функция показа статуса
show_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           СТАТУС DNS СЕРВЕРА${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

    echo ""
    info "Процессы named:"
    ps aux | grep "[n]amed" || echo "  Нет активных процессов"

    echo ""
    info "Порт 53:"
    ss -tulpn | grep ":53" || echo "  Порт 53 не прослушивается"

    echo ""
    info "Последние строки лога:"
    if [[ -f /var/log/bind/bind.log ]]; then
        tail -5 /var/log/bind/bind.log 2>/dev/null || echo "  Лог пуст"
    else
        echo "  Лог не найден"
    fi
}

# Главное меню
main_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Настройка DNS сервера на ALT Linux Server            ║${NC}"
    echo -e "${BLUE}║   Версия 5.0 - Интерактивная настройка                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Выберите действие:${NC}"
    echo ""
    echo "  1) Полная настройка DNS (установка + конфигурация)"
    echo "  2) Только установка BIND"
    echo "  3) Только конфигурация (если BIND установлен)"
    echo "  4) Запустить DNS сервер"
    echo "  5) Остановить DNS сервер"
    echo "  6) Перезапустить DNS сервер"
    echo "  7) Проверить конфигурацию"
    echo "  8) Тестировать DNS"
    echo "  9) Показать статус"
    echo "  10) Просмотр логов"
    echo "  0) Выход"
    echo ""
}

# Основная функция
main() {
    check_root

    # Определяем интерфейсы
    if ! detect_interfaces; then
        error "Невозможно продолжить без сетевого интерфейса"
    fi

    echo ""

    while true; do
        main_menu
        read -p "Ваш выбор [0-10]: " choice

        case $choice in
            1)
                # Полная настройка
                select_interface
                if input_dns_params; then
                    install_bind
                    create_directories
                    create_named_conf
                    create_zones
                    create_named_conf_local
                    check_config
                    start_dns
                    test_dns
                    echo ""
                    success "═══════════════════════════════════════════════════════"
                    success "           DNS НАСТРОЕН УСПЕШНО!"
                    success "═══════════════════════════════════════════════════════"
                    echo ""
                    echo "Команды управления:"
                    echo "  Статус:   ps aux | grep named"
                    echo "  Тест:     dig @$SERVER_IP hq-srv.$DOMAIN"
                    echo "  Лог:      tail -f /var/log/bind/bind.log"
                    echo "  Стоп:     pkill named"
                    echo "  Старт:    cd /var/lib/bind && named -c /etc/named.conf &"
                fi
                ;;
            2)
                # Только установка
                install_bind
                ;;
            3)
                # Только конфигурация
                select_interface
                if input_dns_params; then
                    create_directories
                    create_named_conf
                    create_zones
                    create_named_conf_local
                    check_config
                fi
                ;;
            4)
                # Запуск
                start_dns
                ;;
            5)
                # Остановка
                info "Остановка DNS сервера..."
                pkill named 2>/dev/null && success "DNS сервер остановлен" || warn "DNS сервер не был запущен"
                ;;
            6)
                # Перезапуск
                pkill named 2>/dev/null || true
                sleep 2
                start_dns
                ;;
            7)
                # Проверка
                check_config
                ;;
            8)
                # Тестирование
                if [[ -z "$SERVER_IP" ]]; then
                    # Пытаемся определить IP
                    if [[ ${#VALID_IPS[@]} -gt 0 ]]; then
                        SERVER_IP="${VALID_IPS[0]}"
                    else
                        warn "IP сервера не определен"
                    fi
                fi
                test_dns
                ;;
            9)
                # Статус
                show_status
                ;;
            10)
                # Логи
                if [[ -f /var/log/bind/bind.log ]]; then
                    echo ""
                    info "Последние 20 строк лога:"
                    tail -20 /var/log/bind/bind.log
                else
                    warn "Лог не найден"
                fi
                ;;
            0)
                info "Выход из скрипта"
                exit 0
                ;;
            *)
                warn "Неверный выбор, попробуйте снова"
                ;;
        esac

        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск
main "$@"
