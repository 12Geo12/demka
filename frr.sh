#!/bin/bash

# Скрипт для автоматической настройки GRE туннеля и OSPF
# Версия: 1.0

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Функция для определения роли роутера
determine_role() {
    print_step "Определение роли роутера..."
    
    # Получаем список всех IP-адресов
    local ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1")
    
    # Проверяем типичные подсети для HQ-RTR и BR-RTR
    if echo "$ips" | grep -q "192.168.10." || echo "$ips" | grep -q "192.168.20."; then
        ROUTER_ROLE="HQ-RTR"
        print_message "Определен роутер: $ROUTER_ROLE"
    elif echo "$ips" | grep -q "192.168.30."; then
        ROUTER_ROLE="BR-RTR"
        print_message "Определен роутер: $ROUTER_ROLE"
    else
        print_warning "Не удалось определить роль роутера автоматически"
        echo "Выберите роль роутера:"
        echo "1) HQ-RTR"
        echo "2) BR-RTR"
        read -p "Введите номер (1 или 2): " role_choice
        
        case $role_choice in
            1) ROUTER_ROLE="HQ-RTR" ;;
            2) ROUTER_ROLE="BR-RTR" ;;
            *) print_error "Неверный выбор"; exit 1 ;;
        esac
    fi
}

# Функция для определения основного интерфейса
get_main_interface() {
    print_step "Определение основного сетевого интерфейса..."
    
    # Ищем интерфейс с маршрутом по умолчанию
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$MAIN_IF" ]; then
        # Если нет default route, берем первый поднятый интерфейс (кроме lo)
        MAIN_IF=$(ip link show | grep -v "lo:" | grep "state UP" | head -1 | awk -F': ' '{print $2}')
    fi
    
    if [ -z "$MAIN_IF" ]; then
        print_error "Не удалось определить основной интерфейс"
        exit 1
    fi
    
    print_message "Основной интерфейс: $MAIN_IF"
}

# Функция для получения IP адреса интерфейса
get_interface_ip() {
    local interface=$1
    local ip=$(ip -4 addr show $interface | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    echo $ip
}

# Функция для определения IP-адресов для туннеля
determine_tunnel_ips() {
    print_step "Определение IP-адресов для туннеля..."
    
    MAIN_IP=$(get_interface_ip $MAIN_IF)
    
    if [ -z "$MAIN_IP" ]; then
        print_error "Не удалось получить IP адрес интерфейса $MAIN_IF"
        exit 1
    fi
    
    print_message "IP адрес интерфейса $MAIN_IF: $MAIN_IP"
    
    # Определяем локальный и удаленный IP для туннеля
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        TUN_LOCAL=$MAIN_IP
        # Пытаемся определить IP BR-RTR (можно настроить вручную)
        print_warning "Введите IP адрес удаленного роутера (BR-RTR):"
        read -p "Удаленный IP: " TUN_REMOTE
        
        # IP адрес туннеля для HQ-RTR
        TUNNEL_IP="172.16.100.2"
        TUNNEL_NETWORK="172.16.100.0/29"
    else
        TUN_LOCAL=$MAIN_IP
        print_warning "Введите IP адрес удаленного роутера (HQ-RTR):"
        read -p "Удаленный IP: " TUN_REMOTE
        
        # IP адрес туннеля для BR-RTR
        TUNNEL_IP="172.16.100.1"
        TUNNEL_NETWORK="172.16.100.0/29"
    fi
    
    print_message "Локальный IP для туннеля: $TUN_LOCAL"
    print_message "Удаленный IP для туннеля: $TUN_REMOTE"
    print_message "IP туннеля: $TUNNEL_IP/29"
}

# Функция для определения локальных сетей
determine_local_networks() {
    print_step "Определение локальных сетей..."
    
    LOCAL_NETWORKS=()
    
    if [ "$ROUTER_ROLE" == "HQ-RTR" ]; then
        # Проверяем наличие подсетей HQ-RTR
        if ip route | grep -q "192.168.10.0/26"; then
            LOCAL_NETWORKS+=("192.168.10.0/26")
        else
            print_warning "Сеть 192.168.10.0/26 не найдена. Укажите вручную:"
            read -p "Сеть HQ-SRV (например 192.168.10.0/26): " network
            LOCAL_NETWORKS+=("$network")
        fi
        
        if ip route | grep -q "192.168.20.0/28"; then
            LOCAL_NETWORKS+=("192.168.20.0/28")
        else
            print_warning "Сеть 192.168.20.0/28 не найдена. Укажите вручную:"
            read -p "Сеть HQ-CLI (например 192.168.20.0/28): " network
            LOCAL_NETWORKS+=("$network")
        fi
    else
        # BR-RTR
        if ip route | grep -q "192.168.30.0/27"; then
            LOCAL_NETWORKS+=("192.168.30.0/27")
        else
            print_warning "Сеть 192.168.30.0/27 не найдена. Укажите вручную:"
            read -p "Сеть BR-RTR (например 192.168.30.0/27): " network
            LOCAL_NETWORKS+=("$network")
        fi
    fi
    
    print_message "Локальные сети: ${LOCAL_NETWORKS[*]}"
}

# Функция для настройки GRE туннеля
setup_gre_tunnel() {
    print_step "Настройка GRE туннеля..."
    
    # Создаем каталог для интерфейса туннеля
    if [ ! -d "/etc/net/ifaces/gre1" ]; then
        mkdir -p /etc/net/ifaces/gre1
        print_message "Создан каталог /etc/net/ifaces/gre1"
    else
        print_warning "Каталог /etc/net/ifaces/gre1 уже существует"
    fi
    
    # Создаем файл options
    cat > /etc/net/ifaces/gre1/options << EOF
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNTYPE=gre
TYPE=iptun
TUNOPTIONS='ttl 64'
HOST=$MAIN_IF
EOF
    print_message "Создан файл options"
    
    # Создаем файл с IP адресом
    echo "$TUNNEL_IP/29" > /etc/net/ifaces/gre1/ipv4address
    print_message "Создан файл ipv4address с адресом $TUNNEL_IP/29"
    
    # Перезапускаем сеть
    print_message "Перезапуск сети..."
    systemctl restart network
    
    # Проверяем создание интерфейса
    sleep 2
    if ip link show gre1 &>/dev/null; then
        print_message "Интерфейс gre1 успешно создан"
    else
        print_error "Ошибка создания интерфейса gre1"
        exit 1
    fi
}

# Функция для настройки FRR
setup_frr() {
    print_step "Настройка FRR (Free Range Routing)..."
    
    # Устанавливаем FRR если не установлен
    if ! command -v vtysh &>/dev/null; then
        print_message "Установка FRR..."
        apt-get update && apt-get install -y frr frr-pythontools
    fi
    
    # Включаем и запускаем FRR
    systemctl enable --now frr
    print_message "Служба frr запущена"
    
    # Редактируем конфигурацию демонов
    sed -i 's/^#ospfd=no/ospfd=yes/' /etc/frr/daemons
    sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
    print_message "Включен демон ospfd"
    
    # Перезапускаем FRR
    systemctl restart frr
    print_message "FRR перезапущен"
    
    sleep 2
}

# Функция для настройки OSPF через vtysh
setup_ospf() {
    print_step "Настройка OSPF..."
    
    # Генерируем команды для vtysh
    local ospf_commands="
configure terminal
router ospf
 passive-interface default
 network $TUNNEL_NETWORK area 0
"
    
    # Добавляем локальные сети
    for network in "${LOCAL_NETWORKS[@]}"; do
        ospf_commands+=" network $network area 0
"
    done
    
    ospf_commands+=" area 0 authentication
 exit
 interface gre1
  no ip ospf passive
  ip ospf authentication-key 1245
 exit
 end
 write memory
"
    
    # Применяем конфигурацию
    echo "$ospf_commands" | vtysh
    
    print_message "OSPF настроен"
    
    # Перезапускаем сеть для применения
    systemctl restart network
}

# Функция для проверки настроек
verify_configuration() {
    print_step "Проверка конфигурации..."
    
    echo -e "\n${GREEN}=== Интерфейсы ===${NC}"
    ip a show gre1
    
    echo -e "\n${GREEN}=== Соседи OSPF ===${NC}"
    vtysh -c "show ip ospf neighbor"
    
    echo -e "\n${GREEN}=== Маршруты OSPF ===${NC}"
    vtysh -c "show ip route ospf"
    
    echo -e "\n${GREEN}=== Конфигурация OSPF ===${NC}"
    vtysh -c "show running-config" | grep -A20 "router ospf"
}

# Функция для создания резервной копии
create_backup() {
    local backup_dir="/root/network_backup_$(date +%Y%m%d_%H%M%S)"
    print_step "Создание резервной копии в $backup_dir"
    
    mkdir -p $backup_dir
    
    # Копируем сетевые конфиги
    if [ -d "/etc/net/ifaces" ]; then
        cp -r /etc/net/ifaces $backup_dir/
    fi
    
    # Копируем конфиги FRR
    if [ -d "/etc/frr" ]; then
        cp -r /etc/frr $backup_dir/
    fi
    
    print_message "Резервная копия создана в $backup_dir"
}

# Функция для отката изменений
rollback_changes() {
    print_warning "Откат изменений..."
    
    # Удаляем интерфейс туннеля
    if [ -d "/etc/net/ifaces/gre1" ]; then
        rm -rf /etc/net/ifaces/gre1
        print_message "Удален интерфейс gre1"
    fi
    
    # Отключаем ospfd в FRR
    sed -i 's/^ospfd=yes/ospfd=no/' /etc/frr/daemons
    systemctl restart frr
    
    # Перезапускаем сеть
    systemctl restart network
    
    print_message "Изменения откачены"
}

# Главная функция
main() {
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}   Настройка GRE и OSPF туннеля   ${NC}"
    echo -e "${GREEN}================================${NC}"
    
    # Создаем резервную копию
    create_backup
    
    # Определяем параметры
    determine_role
    get_main_interface
    determine_tunnel_ips
    determine_local_networks
    
    # Показываем план настройки
    echo -e "\n${BLUE}=== План настройки ===${NC}"
    echo "Роль роутера: $ROUTER_ROLE"
    echo "Основной интерфейс: $MAIN_IF ($MAIN_IP)"
    echo "Туннель: local=$TUN_LOCAL, remote=$TUN_REMOTE"
    echo "IP туннеля: $TUNNEL_IP/29"
    echo "Локальные сети: ${LOCAL_NETWORKS[*]}"
    echo "Ключ аутентификации OSPF: 1245"
    
    # Запрашиваем подтверждение
    echo -e "\n${YELLOW}Продолжить настройку? (y/n)${NC}"
    read -p "> " confirm
    
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        print_warning "Настройка отменена"
        exit 0
    fi
    
    # Выполняем настройку
    setup_gre_tunnel
    setup_frr
    setup_ospf
    
    # Проверяем результат
    verify_configuration
    
    echo -e "\n${GREEN}================================${NC}"
    echo -e "${GREEN}   Настройка завершена успешно!   ${NC}"
    echo -e "${GREEN}================================${NC}"
    
    # Даем рекомендации
    echo -e "\n${BLUE}=== Рекомендации ===${NC}"
    echo "1. Проверьте связность через туннель: ping 172.16.100.1 (или 172.16.100.2)"
    echo "2. Для просмотра соседей OSPF: vtysh -c 'show ip ospf neighbor'"
    echo "3. Для просмотра маршрутов: vtysh -c 'show ip route'"
    echo "4. Резервная копия сохранена в /root/network_backup_*"
}

# Запуск главной функции с обработкой ошибок
if [ "$EUID" -ne 0 ]; then 
    print_error "Скрипт должен быть запущен с правами root"
    exit 1
fi

# Обработка сигналов
trap 'echo -e "\n${RED}Прерывание скрипта${NC}"; rollback_changes; exit 1' INT TERM

main