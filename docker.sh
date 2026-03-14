#!/bin/bash
#===============================================================================
# Скрипт установки Docker + MediaWiki для Alt Linux
# Версия: 1.0
#===============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции вывода
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от имени root"
        exit 1
    fi
}

# Определение версии Alt Linux
detect_alt_version() {
    if [[ -f /etc/altlinux-release ]]; then
        ALT_VERSION=$(cat /etc/altlinux-release)
        log_info "Обнаружена система: $ALT_VERSION"
    else
        log_warning "Не удалось определить версию Alt Linux"
    fi
}

# Обновление системы
update_system() {
    log_info "Обновление системы..."
    apt-get update
    apt-get dist-upgrade -y
    log_success "Система обновлена"
}

# Установка Docker для Alt Linux
install_docker() {
    log_info "Установка Docker..."
    
    # В Alt Linux пакет может называться docker-ce или docker-io
    # Пробуем разные варианты
    
    # Способ 1: Из репозитория Alt Linux
    if apt-get install -y docker-ce docker-compose 2>/dev/null; then
        log_success "Docker установлен из репозитория (docker-ce)"
    # Способ 2: Альтернативное имя пакета
    elif apt-get install -y docker-io docker-compose 2>/dev/null; then
        log_success "Docker установлен из репозитория (docker-io)"
    # Способ 3: Установка только docker, docker-compose отдельно
    else
        log_info "Попытка альтернативной установки..."
        apt-get install -y docker
        
        # Установка docker-compose через pip если нет в репозитории
        if ! command -v docker-compose &> /dev/null; then
            log_info "Установка docker-compose через pip..."
            apt-get install -y python3 python3-pip
            pip3 install docker-compose
        fi
    fi
    
    # Включение и запуск Docker
    systemctl enable --now docker
    systemctl start docker
    
    # Проверка установки
    if systemctl is-active --quiet docker; then
        log_success "Docker успешно запущен"
        docker --version
        docker-compose --version 2>/dev/null || docker compose version
    else
        log_error "Не удалось запустить Docker"
        exit 1
    fi
}

# Создание конфигурационного файла Docker Compose
create_compose_file() {
    log_info "Создание конфигурационного файла /root/wiki.yml..."
    
    cat > /root/wiki.yml << 'EOF'
services:
  mariadb:
    image: mariadb:latest
    container_name: mariadb
    environment:
      - MYSQL_ROOT_PASSWORD=toor
      - MYSQL_DATABASE=mediawiki
      - MYSQL_USER=wiki
      - MYSQL_PASSWORD=WikiP@ssw0rd
    volumes:
      - mariadb_data:/var/lib/mysql
    restart: always

  mediawiki:
    image: mediawiki:latest
    container_name: wiki
    ports:
      - "8080:80"
    environment:
      - MEDIAWIKI_DB_TYPE=mysql
      - MEDIAWIKI_DB_HOST=mariadb
      - MEDIAWIKI_DB_USER=wiki
      - MEDIAWIKI_DB_PASSWORD=WikiP@ssw0rd
      - MEDIAWIKI_DB_NAME=mediawiki
    volumes:
      - /root/mediawiki/LocalSettings.php:/var/www/html/LocalSettings.php
    depends_on:
      - mariadb
    restart: always

volumes:
  mariadb_data:
EOF
    
    log_success "Файл /root/wiki.yml создан"
}

# Создание директории для MediaWiki
create_directories() {
    log_info "Создание директории /root/mediawiki..."
    mkdir -p /root/mediawiki
    log_success "Директория создана"
}

# Первый запуск MediaWiki (без LocalSettings.php)
first_run() {
    log_info "Первый запуск MediaWiki..."
    
    # Создаем временный файл compose без volumes для mediawiki
    cat > /root/wiki_first_run.yml << 'EOF'
services:
  mariadb:
    image: mariadb:latest
    container_name: mariadb
    environment:
      - MYSQL_ROOT_PASSWORD=toor
      - MYSQL_DATABASE=mediawiki
      - MYSQL_USER=wiki
      - MYSQL_PASSWORD=WikiP@ssw0rd
    volumes:
      - mariadb_data:/var/lib/mysql
    restart: always

  mediawiki:
    image: mediawiki:latest
    container_name: wiki
    ports:
      - "8080:80"
    environment:
      - MEDIAWIKI_DB_TYPE=mysql
      - MEDIAWIKI_DB_HOST=mariadb
      - MEDIAWIKI_DB_USER=wiki
      - MEDIAWIKI_DB_PASSWORD=WikiP@ssw0rd
      - MEDIAWIKI_DB_NAME=mediawiki
    depends_on:
      - mariadb
    restart: always

volumes:
  mariadb_data:
EOF
    
    # Запуск контейнеров
    cd /root
    docker-compose -f wiki_first_run.yml up -d 2>/dev/null || \
    docker compose -f wiki_first_run.yml up -d
    
    log_success "Контейнеры запущены"
    log_warning "============================================="
    log_warning "ВАЖНО: Дальнейшие действия:"
    log_warning "1. Откройте в браузере: http://YOUR_IP:8080"
    log_warning "2. Пройдите установку MediaWiki"
    log_warning "3. Скачайте файл LocalSettings.php"
    log_warning "4. Скопируйте его в /root/mediawiki/LocalSettings.php"
    log_warning "5. Запустите скрипт с параметром --finalize"
    log_warning "============================================="
}

# Финализация установки
finalize() {
    log_info "Финализация установки..."
    
    # Проверка наличия LocalSettings.php
    if [[ ! -f /root/mediawiki/LocalSettings.php ]]; then
        log_error "Файл /root/mediawiki/LocalSettings.php не найден!"
        log_error "Сначала скачайте его из веб-интерфейса установки MediaWiki"
        exit 1
    fi
    
    # Остановка контейнеров
    cd /root
    docker-compose -f wiki_first_run.yml down 2>/dev/null || \
    docker compose -f wiki_first_run.yml down
    
    # Удаление временного файла
    rm -f /root/wiki_first_run.yml
    
    # Запуск с основным конфигом
    docker-compose -f /root/wiki.yml up -d 2>/dev/null || \
    docker compose -f /root/wiki.yml up -d
    
    log_success "MediaWiki установлена и запущена!"
}

# Проверка статуса
check_status() {
    log_info "Проверка статуса контейнеров..."
    echo ""
    docker ps
    echo ""
    log_info "Логи wiki:"
    docker logs wiki --tail 20
    echo ""
    log_info "Проверка HTTP:"
    curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:8080
}

# Полная установка
full_install() {
    check_root
    detect_alt_version
    update_system
    install_docker
    create_compose_file
    create_directories
    first_run
}

# Показать справку
show_help() {
    cat << EOF
Скрипт установки Docker + MediaWiki для Alt Linux

Использование: $0 [команда]

Команды:
    --install       Полная установка Docker и первый запуск MediaWiki
    --finalize      Финализация установки после настройки MediaWiki в браузере
    --status        Проверка статуса контейнеров
    --stop          Остановить контейнеры
    --start         Запустить контейнеры
    --restart       Перезапустить контейнеры
    --logs          Показать логи контейнеров
    --help          Показать эту справку

Пример полного цикла установки:
    1. $0 --install
    2. Откройте http://YOUR_IP:8080 в браузере
    3. Установите MediaWiki, скачайте LocalSettings.php
    4. Скопируйте LocalSettings.php в /root/mediawiki/
    5. $0 --finalize

EOF
}

# Управление контейнерами
manage_containers() {
    local action=$1
    case $action in
        stop)
            log_info "Остановка контейнеров..."
            docker-compose -f /root/wiki.yml down 2>/dev/null || \
            docker compose -f /root/wiki.yml down
            log_success "Контейнеры остановлены"
            ;;
        start)
            log_info "Запуск контейнеров..."
            docker-compose -f /root/wiki.yml up -d 2>/dev/null || \
            docker compose -f /root/wiki.yml up -d
            log_success "Контейнеры запущены"
            ;;
        restart)
            log_info "Перезапуск контейнеров..."
            docker-compose -f /root/wiki.yml restart 2>/dev/null || \
            docker compose -f /root/wiki.yml restart
            log_success "Контейнеры перезапущены"
            ;;
        logs)
            log_info "Логи контейнеров:"
            docker logs wiki
            echo "---"
            docker logs mariadb
            ;;
    esac
}

# Главная логика
main() {
    case "${1:-}" in
        --install)
            full_install
            ;;
        --finalize)
            check_root
            finalize
            ;;
        --status)
            check_status
            ;;
        --stop)
            check_root
            manage_containers stop
            ;;
        --start)
            check_root
            manage_containers start
            ;;
        --restart)
            check_root
            manage_containers restart
            ;;
        --logs)
            manage_containers logs
            ;;
        --help|-h)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

main "$@"
