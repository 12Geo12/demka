#!/bin/bash

#===============================================================================
# Moodle Auto-Installation Script for Ubuntu/Debian
# Version: 1.0
# Description: Автоматическая установка Moodle LMS с веб-сервером Apache,
#              PHP и базой данных MySQL/MariaDB
#===============================================================================

set -e  # Прерывание при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Лог-файл
LOG_FILE="/var/log/moodle-install.log"

# Функция логирования
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Переменные конфигурации (можно изменить)
MOODLE_VERSION="404"  # Moodle 4.4.x
MOODLE_DIR="/var/www/moodle"
MOODLE_DATA_DIR="/var/moodledata"
DB_TYPE="mariadb"  # mysql или mariadb
DB_NAME="moodledb"
DB_USER="moodleuser"
DB_PASS=$(openssl rand -base64 12)  # Генерация случайного пароля
WEB_SERVER="apache"  # apache или nginx
PHP_VERSION="8.1"

# Функция для запроса параметров у пользователя
get_user_input() {
    log_info "Настройка параметров установки Moodle"
    echo "========================================="
    
    read -p "Введите домен или IP сервера [localhost]: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-localhost}
    
    read -p "Версия Moodle [404]: " INPUT_VERSION
    MOODLE_VERSION=${INPUT_VERSION:-$MOODLE_VERSION}
    
    read -p "Директория установки Moodle [$MOODLE_DIR]: " INPUT_DIR
    MOODLE_DIR=${INPUT_DIR:-$MOODLE_DIR}
    
    read -p "Директория данных Moodle [$MOODLE_DATA_DIR]: " INPUT_DATA_DIR
    MOODLE_DATA_DIR=${INPUT_DATA_DIR:-$MOODLE_DATA_DIR}
    
    read -sp "Пароль для базы данных (Enter для авто-генерации): " INPUT_DB_PASS
    echo
    DB_PASS=${INPUT_DB_PASS:-$DB_PASS}
    
    read -p "Веб-сервер (apache/nginx) [$WEB_SERVER]: " INPUT_WEB
    WEB_SERVER=${INPUT_WEB:-$WEB_SERVER}
    
    read -p "Версия PHP [$PHP_VERSION]: " INPUT_PHP
    PHP_VERSION=${INPUT_PHP:-$PHP_VERSION}
    
    echo ""
    log "Параметры установки:"
    echo "  - Сервер: $SERVER_NAME"
    echo "  - Версия Moodle: $MOODLE_VERSION"
    echo "  - Директория: $MOODLE_DIR"
    echo "  - Данные: $MOODLE_DATA_DIR"
    echo "  - База данных: $DB_NAME"
    echo "  - Пользователь БД: $DB_USER"
    echo "  - Веб-сервер: $WEB_SERVER"
    echo "  - PHP версия: $PHP_VERSION"
    echo ""
    
    read -p "Продолжить установку? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! $CONFIRM =~ ^[Yy] ]]; then
        log "Установка отменена пользователем"
        exit 0
    fi
}

# Обновление системы
update_system() {
    log "Обновление системы..."
    apt-get update -y >> "$LOG_FILE" 2>&1
    apt-get install -y curl wget unzip git software-properties-common >> "$LOG_FILE" 2>&1
}

# Установка веб-сервера
install_web_server() {
    log "Установка веб-сервера ($WEB_SERVER)..."
    
    if [[ "$WEB_SERVER" == "apache" ]]; then
        apt-get install -y apache2 apache2-utils >> "$LOG_FILE" 2>&1
        systemctl enable apache2 >> "$LOG_FILE" 2>&1
        systemctl start apache2 >> "$LOG_FILE" 2>&1
        
        # Включение необходимых модулей
        a2enmod rewrite headers expires deflate ssl >> "$LOG_FILE" 2>&1
        
    elif [[ "$WEB_SERVER" == "nginx" ]]; then
        apt-get install -y nginx >> "$LOG_FILE" 2>&1
        systemctl enable nginx >> "$LOG_FILE" 2>&1
        systemctl start nginx >> "$LOG_FILE" 2>&1
    fi
}

# Установка PHP и расширений
install_php() {
    log "Установка PHP $PHP_VERSION и расширений..."
    
    # Добавление репозитория PHP если нужно
    if ! apt-cache policy | grep -q "ondrej/php"; then
        log_info "Добавление репозитория PHP..."
        add-apt-repository -y ppa:ondrej/php >> "$LOG_FILE" 2>&1
        apt-get update >> "$LOG_FILE" 2>&1
    fi
    
    # Установка PHP и необходимых расширений для Moodle
    PHP_EXTENSIONS=(
        "php${PHP_VERSION}"
        "php${PHP_VERSION}-fpm"
        "php${PHP_VERSION}-cli"
        "php${PHP_VERSION}-common"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-soap"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-ldap"
        "php${PHP_VERSION}-pgsql"
        "php${PHP_VERSION}-sqlite3"
        "php${PHP_VERSION}-xmlrpc"
        "php${PHP_VERSION}-xsl"
        "php${PHP_VERSION}-opcache"
        "php${PHP_VERSION}-imagick"
        "php${PHP_VERSION}-memcached"
        "php${PHP_VERSION}-redis"
    )
    
    apt-get install -y "${PHP_EXTENSIONS[@]}" >> "$LOG_FILE" 2>&1
    
    # Настройка PHP для Moodle
    log "Настройка PHP..."
    
    PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
    if [[ "$WEB_SERVER" == "apache" ]]; then
        PHP_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"
    fi
    
    # Параметры PHP для Moodle
    sed -i "s/^max_input_vars.*/max_input_vars = 5000/" "$PHP_INI" 2>/dev/null || echo "max_input_vars = 5000" >> "$PHP_INI"
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 100M/" "$PHP_INI"
    sed -i "s/^post_max_size.*/post_max_size = 100M/" "$PHP_INI"
    sed -i "s/^memory_limit.*/memory_limit = 512M/" "$PHP_INI"
    sed -i "s/^max_execution_time.*/max_execution_time = 300/" "$PHP_INI"
    
    # Настройка OPcache для Moodle
    cat >> "$PHP_INI" << 'OPCACHE'

; Moodle OPcache Settings
opcache.enable = 1
opcache.memory_consumption = 256
opcache.max_accelerated_files = 8000
opcache.validate_timestamps = 0
opcache.save_comments = 1
opcache.fast_shutdown = 1
OPCACHE

    # Перезапуск PHP-FPM
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        systemctl restart php${PHP_VERSION}-fpm >> "$LOG_FILE" 2>&1
    elif [[ "$WEB_SERVER" == "apache" ]]; then
        systemctl restart apache2 >> "$LOG_FILE" 2>&1
    fi
}

# Установка базы данных
install_database() {
    log "Установка базы данных ($DB_TYPE)..."
    
    if [[ "$DB_TYPE" == "mariadb" ]]; then
        apt-get install -y mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
    else
        apt-get install -y mysql-server mysql-client >> "$LOG_FILE" 2>&1
    fi
    
    systemctl enable ${DB_TYPE} >> "$LOG_FILE" 2>&1
    systemctl start ${DB_TYPE} >> "$LOG_FILE" 2>&1
    
    # Безопасная настройка БД
    log "Настройка безопасности базы данных..."
    mysql_secure_installation_script
}

# Скрипт безопасной настройки MySQL/MariaDB
mysql_secure_installation_script() {
    # Автоматическая настройка безопасности
    mysql -u root <<MYSQL_SCRIPT
-- Удаление анонимных пользователей
DELETE FROM mysql.user WHERE User='';

-- Запрет удаленного входа для root
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Удаление тестовой базы данных
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Применение изменений
FLUSH PRIVILEGES;
MYSQL_SCRIPT
}

# Создание базы данных для Moodle
create_moodle_database() {
    log "Создание базы данных для Moodle..."
    
    mysql -u root <<MYSQL_SCRIPT
-- Создание базы данных с правильной кодировкой
CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Создание пользователя
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';

-- Предоставление прав
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' WITH GRANT OPTION;

-- Применение изменений
FLUSH PRIVILEGES;

-- Вывод информации
SELECT User, Host FROM mysql.user WHERE User='${DB_USER}';
MYSQL_SCRIPT
    
    log "База данных создана: $DB_NAME"
    log "Пользователь БД: $DB_USER"
}

# Загрузка Moodle
download_moodle() {
    log "Загрузка Moodle версии $MOODLE_VERSION..."
    
    # Создание директорий
    mkdir -p "$MOODLE_DIR"
    mkdir -p "$MOODLE_DATA_DIR"
    
    # Загрузка Moodle
    MOODLE_URL="https://download.moodle.org/download.php/direct/stable${MOODLE_VERSION}/moodle-latest-${MOODLE_VERSION}.tgz"
    
    cd /tmp
    wget -q --show-progress "$MOODLE_URL" -O moodle.tgz || {
        log_error "Не удалось загрузить Moodle с $MOODLE_URL"
        log_info "Попытка клонирования из Git репозитория..."
        git clone -b MOODLE_${MOODLE_VERSION}_STABLE https://github.com/moodle/moodle.git "$MOODLE_DIR"
    }
    
    # Распаковка если скачали архив
    if [[ -f moodle.tgz ]]; then
        log "Распаковка Moodle..."
        tar -xzf moodle.tgz
        mv moodle/* "$MOODLE_DIR"/
        rm -rf moodle moodle.tgz
    fi
    
    # Установка прав
    chown -R www-data:www-data "$MOODLE_DIR"
    chmod -R 755 "$MOODLE_DIR"
    
    # Настройка директории данных
    chown -R www-data:www-data "$MOODLE_DATA_DIR"
    chmod -R 755 "$MOODLE_DATA_DIR"
    
    log "Moodle установлен в: $MOODLE_DIR"
}

# Настройка Apache для Moodle
configure_apache() {
    log "Настройка Apache для Moodle..."
    
    # Создание виртуального хоста
    cat > /etc/apache2/sites-available/moodle.conf <<APACHE_CONF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    ServerAdmin webmaster@${SERVER_NAME}
    DocumentRoot ${MOODLE_DIR}

    <Directory ${MOODLE_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        
        # Дополнительные настройки безопасности
        <IfModule mod_headers.c>
            Header set X-Content-Type-Options "nosniff"
            Header set X-Frame-Options "SAMEORIGIN"
            Header set X-XSS-Protection "1; mode=block"
        </IfModule>
    </Directory>

    # Ограничение доступа к конфигурационным файлам
    <Directory ${MOODLE_DIR}/.htaccess>
        Require all denied
    </Directory>
    
    # Защита директории данных
    <Directory ${MOODLE_DATA_DIR}>
        Require all denied
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/moodle_error.log
    CustomLog \${APACHE_LOG_DIR}/moodle_access.log combined

    # Увеличение лимитов для загрузки файлов
    LimitRequestBody 104857600
</VirtualHost>
APACHE_CONF

    # Включение сайта
    a2ensite moodle >> "$LOG_FILE" 2>&1
    a2dissite 000-default >> "$LOG_FILE" 2>&1
    
    # Проверка конфигурации
    apache2ctl configtest >> "$LOG_FILE" 2>&1
    
    # Перезапуск Apache
    systemctl restart apache2 >> "$LOG_FILE" 2>&1
    
    log "Apache настроен для Moodle"
}

# Настройка Nginx для Moodle
configure_nginx() {
    log "Настройка Nginx для Moodle..."
    
    cat > /etc/nginx/sites-available/moodle <<NGINX_CONF
server {
    listen 80;
    server_name ${SERVER_NAME};
    root ${MOODLE_DIR};
    index index.php index.html;

    # Логи
    access_log /var/log/nginx/moodle_access.log;
    error_log /var/log/nginx/moodle_error.log;

    # Основные настройки
    client_max_body_size 100M;
    
    # Кэширование статических файлов
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    # PHP обработка
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        include fastcgi_params;
    }

    # Основной location
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Защита служебных файлов
    location ~ /\. {
        deny all;
    }
    
    location ~ /(config\.php|install\.php) {
        deny all;
    }

    # Защита директории данных
    location ^~ ${MOODLE_DATA_DIR} {
        internal;
        alias ${MOODLE_DATA_DIR};
    }
}
NGINX_CONF

    # Включение сайта
    ln -sf /etc/nginx/sites-available/moodle /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Проверка конфигурации
    nginx -t >> "$LOG_FILE" 2>&1
    
    # Перезапуск Nginx
    systemctl restart nginx >> "$LOG_FILE" 2>&1
    
    log "Nginx настроен для Moodle"
}

# Настройка SSL с Let's Encrypt (опционально)
setup_ssl() {
    read -p "Настроить SSL сертификат Let's Encrypt? [y/N]: " SETUP_SSL
    SETUP_SSL=${SETUP_SSL:-N}
    
    if [[ $SETUP_SSL =~ ^[Yy] ]]; then
        log "Установка Certbot..."
        apt-get install -y certbot python3-certbot-${WEB_SERVER} >> "$LOG_FILE" 2>&1
        
        log "Получение SSL сертификата..."
        certbot --${WEB_SERVER} -d "$SERVER_NAME" --non-interactive --agree-tos --register-unsafely-without-email || {
            log_warn "Не удалось получить SSL сертификат. Проверьте DNS записи."
        }
    fi
}

# Создание файла конфигурации Moodle
create_moodle_config() {
    log "Создание конфигурационного файла Moodle..."
    
    CONFIG_FILE="$MOODLE_DIR/config.php"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<MOODLE_CONFIG
<?php
// Moodle configuration file
// Сгенерировано автоматически установочным скриптом

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${DB_NAME}';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array(
    'dbpersist' => 0,
    'dbport' => 3306,
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = 'http://${SERVER_NAME}';
\$CFG->dataroot  = '${MOODLE_DATA_DIR}';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

// Описание сайта (опционально)
// \$CFG->sitename = 'Ваша платформа Moodle';

// Настройки кэширования (рекомендуется для production)
// \$CFG->cachetype = 'memcached';
// \$CFG->memcachedservers = 'localhost:11211';

// Отключение обновлений через интерфейс (для production)
// \$CFG->disableupdateautodeploy = true;

require_once(__DIR__ . '/lib/setup.php');

// Автоматическое создание сессий
// Этот код должен быть в конце файла
MOODLE_CONFIG

        chown www-data:www-data "$CONFIG_FILE"
        chmod 640 "$CONFIG_FILE"
        
        log "Конфигурационный файл создан: $CONFIG_FILE"
    fi
}

# Создание Cron задачи для Moodle
setup_cron() {
    log "Настройка Cron для Moodle..."
    
    # Moodle рекомендует запускать cron каждую минуту
    CRON_JOB="* * * * * www-data /usr/bin/php ${MOODLE_DIR}/admin/cli/cron.php > /dev/null 2>&1"
    
    # Проверка, не добавлена ли уже задача
    if ! crontab -u www-data -l 2>/dev/null | grep -q "moodle"; then
        (crontab -u www-data -l 2>/dev/null; echo "$CRON_JOB") | crontab -u www-data -
        log "Cron задача добавлена"
    else
        log_warn "Cron задача уже существует"
    fi
}

# Установка дополнительных рекомендованных пакетов
install_additional_packages() {
    log "Установка дополнительных пакетов..."
    
    apt-get install -y \
        imagemagick \
        ghostscript \
        poppler-utils \
        unoconv \
        clamav \
        clamav-daemon \
        aspell \
        aspell-ru \
        aspell-en \
        >> "$LOG_FILE" 2>&1
    
    # Обновление баз ClamAV
    log "Обновление антивирусных баз ClamAV..."
    systemctl stop clamav-freshclam >> "$LOG_FILE" 2>&1 || true
    freshclam >> "$LOG_FILE" 2>&1 || true
    systemctl start clamav-freshclam >> "$LOG_FILE" 2>&1 || true
}

# Оптимизация системы для Moodle
optimize_system() {
    log "Оптимизация системы для Moodle..."
    
    # Увеличение лимитов файловой системы
    cat >> /etc/security/limits.conf <<LIMITS
# Moodle optimization
www-data soft nofile 65535
www-data hard nofile 65535
LIMITS

    # Настройка sysctl
    cat >> /etc/sysctl.conf <<SYSCTL
# Moodle network optimization
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
SYSCTL

    sysctl -p >> "$LOG_FILE" 2>&1 || true
    
    log "Система оптимизирована"
}

# Сохранение информации об установке
save_install_info() {
    INFO_FILE="/root/moodle-install-info.txt"
    
    cat > "$INFO_FILE" <<INFO
================================================================================
                        MOODLE INSTALLATION INFO
================================================================================
Дата установки: $(date)
Версия Moodle: $MOODLE_VERSION

--- Пути ---
Директория Moodle: $MOODLE_DIR
Директория данных: $MOODLE_DATA_DIR
URL сайта: http://$SERVER_NAME

--- База данных ---
Тип БД: $DB_TYPE
Имя БД: $DB_NAME
Пользователь: $DB_USER
Пароль: $DB_PASS

--- Система ---
Веб-сервер: $WEB_SERVER
PHP версия: $PHP_VERSION

--- Доступ ---
Админ-панель: http://$SERVER_NAME}/admin
Лог-файлы:
  - Apache: /var/log/apache2/moodle_*.log
  - Nginx: /var/log/nginx/moodle_*.log
  - Установка: $LOG_FILE

--- Полезные команды ---
  Перезапуск веб-сервера: systemctl restart $WEB_SERVER
  Перезапуск PHP-FPM: systemctl restart php${PHP_VERSION}-fpm
  Moodle CLI: php ${MOODLE_DIR}/admin/cli/

--- Рекомендации после установки ---
1. Завершите установку через веб-интерфейс: http://${SERVER_NAME}
2. Настройте SSL сертификат для production
3. Настройте резервное копирование
4. Изучите настройки производительности в админ-панели
================================================================================
INFO

    chmod 600 "$INFO_FILE"
    
    log "Информация об установке сохранена: $INFO_FILE"
}

# Отображение финальной информации
show_final_info() {
    echo ""
    echo -e "${GREEN}=======================================${NC}"
    echo -e "${GREEN}      MOODLE УСТАНОВКА ЗАВЕРШЕНА!      ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    echo ""
    echo -e "${BLUE}URL сайта:${NC}     http://$SERVER_NAME"
    echo -e "${BLUE}Админ-панель:${NC}  http://$SERVER_NAME/admin"
    echo ""
    echo -e "${YELLOW}Данные базы данных:${NC}"
    echo "  База данных: $DB_NAME"
    echo "  Пользователь: $DB_USER"
    echo "  Пароль: $DB_PASS"
    echo ""
    echo -e "${YELLOW}Информация сохранена в:${NC}"
    echo "  /root/moodle-install-info.txt"
    echo ""
    echo -e "${YELLOW}Следующие шаги:${NC}"
    echo "  1. Откройте http://$SERVER_NAME в браузере"
    echo "  2. Завершите установку через веб-интерфейс"
    echo "  3. Создайте аккаунт администратора"
    echo "  4. Настройте SSL для production"
    echo ""
}

# Основная функция
main() {
    clear
    echo -e "${BLUE}"
    echo "================================================================"
    echo "           MOODLE LMS AUTO-INSTALLATION SCRIPT"
    echo "                    Версия 1.0"
    echo "================================================================"
    echo -e "${NC}"
    
    # Инициализация лог-файла
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Moodle Installation Log - $(date) ===" > "$LOG_FILE"
    
    check_root
    get_user_input
    
    log "Начало установки Moodle..."
    
    update_system
    install_web_server
    install_php
    install_database
    create_moodle_database
    download_moodle
    
    if [[ "$WEB_SERVER" == "apache" ]]; then
        configure_apache
    else
        configure_nginx
    fi
    
    setup_ssl
    create_moodle_config
    setup_cron
    install_additional_packages
    optimize_system
    save_install_info
    
    show_final_info
    
    log "Установка Moodle успешно завершена!"
}

# Запуск скрипта
main "$@"
