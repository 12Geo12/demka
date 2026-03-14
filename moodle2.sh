#!/bin/bash

#===============================================================================
# Скрипт автоматической установки Moodle на ALT Linux
# Платформа: ALT Linux (Apache2, PHP 8.2, MariaDB)
# Версия: 1.0
#===============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Параметры конфигурации по умолчанию
MOODLE_DB_NAME="moodle"
MOODLE_DB_USER="moodle"
MOODLE_DB_PASS="P@ssw0rd"
SERVER_NAME="hq-srv.au-team.irpo"
SERVER_IP="192.168.100.1"
MOODLE_VERSION="405"
SITE_NAME=""  # Название сайта = номер рабочего места

# Пути для ALT Linux
MOODLE_WWW_ROOT="/var/www/html/moodle"
MOODLE_DATA_ROOT="/var/www/moodledata"
APACHE_CONF_DIR="/etc/httpd2/conf/sites-available"
APACHE_CONF="${APACHE_CONF_DIR}/default.conf"
PHP_INI="/etc/php/8.2/apache2-mod_php/php.ini"

#===============================================================================
# Функции вывода
#===============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

print_error() {
    echo -e "${RED}  ✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}  ℹ $1${NC}"
}

#===============================================================================
# Проверка прав root
#===============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Скрипт должен быть запущен с правами root"
        echo "Используйте: sudo $0"
        exit 1
    fi
}

#===============================================================================
# Определение версии PHP
#===============================================================================
detect_php_version() {
    # Поиск установленной версии PHP
    if [[ -d "/etc/php/8.2" ]]; then
        PHP_VERSION="8.2"
    elif [[ -d "/etc/php/8.1" ]]; then
        PHP_VERSION="8.1"
    elif [[ -d "/etc/php/8.0" ]]; then
        PHP_VERSION="8.0"
    else
        PHP_VERSION="8.2"  # По умолчанию
    fi
    
    PHP_INI="/etc/php/${PHP_VERSION}/apache2-mod_php/php.ini"
    print_info "Обнаружена PHP версия: ${PHP_VERSION}"
}

#===============================================================================
# Основной скрипт
#===============================================================================

clear
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          УСТАНОВКА MOODLE НА ALT LINUX                     ║"
echo "║                    Версия 1.0                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

check_root
detect_php_version

#-------------------------------------------------------------------------------
# Ввод параметров
#-------------------------------------------------------------------------------
print_header "НАСТРОЙКА ПАРАМЕТРОВ"

echo -e "${YELLOW}Текущие параметры:${NC}"
echo "  База данных:      ${MOODLE_DB_NAME}"
echo "  Пользователь БД:  ${MOODLE_DB_USER}"
echo "  Пароль БД:        ${MOODLE_DB_PASS}"
echo "  Имя сервера:      ${SERVER_NAME}"
echo "  IP сервера:       ${SERVER_IP}"
echo ""

read -p "Использовать параметры по умолчанию? (y/n): " use_defaults
echo ""

if [[ "$use_defaults" != "y" && "$use_defaults" != "Y" ]]; then
    read -p "Имя базы данных [${MOODLE_DB_NAME}]: " input
    MOODLE_DB_NAME=${input:-$MOODLE_DB_NAME}
    
    read -p "Пользователь БД [${MOODLE_DB_USER}]: " input
    MOODLE_DB_USER=${input:-$MOODLE_DB_USER}
    
    read -p "Пароль БД [${MOODLE_DB_PASS}]: " input
    MOODLE_DB_PASS=${input:-$MOODLE_DB_PASS}
    
    read -p "Имя сервера [${SERVER_NAME}]: " input
    SERVER_NAME=${input:-$SERVER_NAME}
    
    read -p "IP сервера [${SERVER_IP}]: " input
    SERVER_IP=${input:-$SERVER_IP}
    
    read -p "Название сайта (номер рабочего места): " SITE_NAME
    echo ""
fi

print_warning "Установка начнётся через 3 секунды... (Ctrl+C для отмены)"
sleep 3

#-------------------------------------------------------------------------------
# Шаг 1: Обновление системы
#-------------------------------------------------------------------------------
print_header "ШАГ 1: ОБНОВЛЕНИЕ СИСТЕМЫ"

print_step "Обновление списков пакетов..."
apt-get update

if [[ $? -eq 0 ]]; then
    print_success "Списки пакетов обновлены"
else
    print_error "Ошибка обновления списков"
    exit 1
fi

#-------------------------------------------------------------------------------
# Шаг 2: Установка Apache2 и PHP
#-------------------------------------------------------------------------------
print_header "ШАГ 2: УСТАНОВКА APACHE2 И PHP"

print_step "Установка Apache2, PHP ${PHP_VERSION} и модулей..."

# Установка базовых пакетов
apt-get install -y \
    apache2 \
    apache2-mods \
    apache2-mod_php${PHP_VERSION} \
    mariadb-server

if [[ $? -eq 0 ]]; then
    print_success "Apache2 и MariaDB установлены"
else
    print_error "Ошибка установки базовых пакетов"
    exit 1
fi

# Установка PHP модулей для Moodle
print_step "Установка PHP модулей..."

apt-get install -y \
    php${PHP_VERSION}-opcache \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-mysqli \
    php${PHP_VERSION}-xmlrpc \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xmlreader \
    php${PHP_VERSION}-fileinfo \
    php${PHP_VERSION}-sodium

if [[ $? -eq 0 ]]; then
    print_success "PHP модули установлены"
else
    print_warning "Некоторые PHP модули не установлены (продолжаем)"
fi

#-------------------------------------------------------------------------------
# Шаг 3: Запуск служб
#-------------------------------------------------------------------------------
print_header "ШАГ 3: ЗАПУСК СЛУЖБ"

print_step "Запуск Apache2 (httpd2)..."
systemctl enable --now httpd2

if [[ $? -eq 0 ]]; then
    print_success "Apache2 запущен"
else
    print_error "Ошибка запуска Apache2"
    exit 1
fi

print_step "Запуск MariaDB..."
systemctl enable --now mariadb

if [[ $? -eq 0 ]]; then
    print_success "MariaDB запущена"
else
    print_error "Ошибка запуска MariaDB"
    exit 1
fi

#-------------------------------------------------------------------------------
# Шаг 4: Настройка MariaDB
#-------------------------------------------------------------------------------
print_header "ШАГ 4: НАСТРОЙКА БАЗЫ ДАННЫХ"

print_step "Создание базы данных и пользователя..."

mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${MOODLE_DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MOODLE_DB_USER}'@'localhost' IDENTIFIED BY '${MOODLE_DB_PASS}';
GRANT ALL PRIVILEGES ON ${MOODLE_DB_NAME}.* TO '${MOODLE_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SHOW DATABASES;
SELECT User, Host FROM mysql.user WHERE User='${MOODLE_DB_USER}';
EOF

if [[ $? -eq 0 ]]; then
    print_success "База данных '${MOODLE_DB_NAME}' создана"
    print_success "Пользователь '${MOODLE_DB_USER}' создан"
else
    print_error "Ошибка настройки MariaDB"
    exit 1
fi

#-------------------------------------------------------------------------------
# Шаг 5: Скачивание Moodle
#-------------------------------------------------------------------------------
print_header "ШАГ 5: СКАЧИВАНИЕ MOODLE"

MOODLE_TAR="moodle-latest-${MOODLE_VERSION}.tgz"
cd /tmp

if [[ -f "$MOODLE_TAR" ]]; then
    print_info "Файл уже скачан: ${MOODLE_TAR}"
else
    print_step "Скачивание Moodle ${MOODLE_VERSION}..."
    wget --progress=bar:force "https://download.moodle.org/download.php/direct/stable${MOODLE_VERSION}/${MOODLE_TAR}" 2>&1
    
    if [[ $? -eq 0 ]]; then
        print_success "Moodle скачан"
    else
        print_error "Ошибка скачивания Moodle"
        exit 1
    fi
fi

#-------------------------------------------------------------------------------
# Шаг 6: Установка файлов Moodle
#-------------------------------------------------------------------------------
print_header "ШАГ 6: УСТАНОВКА ФАЙЛОВ MOODLE"

print_step "Распаковка архива..."
tar -xf "${MOODLE_TAR}"

if [[ $? -ne 0 ]]; then
    print_error "Ошибка распаковки"
    exit 1
fi
print_success "Архив распакован"

print_step "Перемещение файлов в ${MOODLE_WWW_ROOT}..."
rm -rf "${MOODLE_WWW_ROOT}"
mv moodle /var/www/html/
print_success "Файлы перемещены"

print_step "Создание директории данных ${MOODLE_DATA_ROOT}..."
mkdir -p "${MOODLE_DATA_ROOT}"
print_success "Директория создана"

print_step "Удаление стандартного index.html..."
rm -f /var/www/html/index.html
print_success "index.html удалён"

print_step "Установка прав доступа..."
chown -R apache2:apache2 /var/www/html
chown -R apache2:apache2 "${MOODLE_DATA_ROOT}"
chmod -R 755 /var/www/html
chmod -R 755 "${MOODLE_DATA_ROOT}"
print_success "Права установлены"

#-------------------------------------------------------------------------------
# Шаг 7: Настройка Apache
#-------------------------------------------------------------------------------
print_header "ШАГ 7: НАСТРОЙКА APACHE"

print_step "Создание конфигурации виртуального хоста..."

# Создание директории если нет
mkdir -p "${APACHE_CONF_DIR}"

cat > "${APACHE_CONF}" <<EOF
<VirtualHost *:80>
    DocumentRoot ${MOODLE_WWW_ROOT}
    ServerName ${SERVER_NAME}
    
    <Directory ${MOODLE_WWW_ROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog /var/log/httpd2/moodle-error.log
    CustomLog /var/log/httpd2/moodle-access.log common
</VirtualHost>
EOF

if [[ $? -eq 0 ]]; then
    print_success "Конфигурация создана: ${APACHE_CONF}"
else
    print_error "Ошибка создания конфигурации"
    exit 1
fi

#-------------------------------------------------------------------------------
# Шаг 8: Настройка PHP
#-------------------------------------------------------------------------------
print_header "ШАГ 8: НАСТРОЙКА PHP"

print_step "Настройка параметров PHP для Moodle..."

if [[ -f "${PHP_INI}" ]]; then
    # Резервная копия
    cp "${PHP_INI}" "${PHP_INI}.bak"
    
    # Настройка параметров
    sed -i 's/^max_input_vars.*/max_input_vars = 5000/' "${PHP_INI}"
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' "${PHP_INI}"
    sed -i 's/^post_max_size.*/post_max_size = 100M/' "${PHP_INI}"
    sed -i 's/^memory_limit.*/memory_limit = 512M/' "${PHP_INI}"
    sed -i 's/^max_execution_time.*/max_execution_time = 300/' "${PHP_INI}"
    
    # Добавление если отсутствуют
    grep -q "^max_input_vars" "${PHP_INI}" || echo "max_input_vars = 5000" >> "${PHP_INI}"
    grep -q "^upload_max_filesize = 100M" "${PHP_INI}" || echo "upload_max_filesize = 100M" >> "${PHP_INI}"
    grep -q "^post_max_size = 100M" "${PHP_INI}" || echo "post_max_size = 100M" >> "${PHP_INI}"
    
    print_success "PHP настроен: ${PHP_INI}"
else
    print_warning "Файл ${PHP_INI} не найден"
fi

#-------------------------------------------------------------------------------
# Шаг 9: Перезапуск Apache
#-------------------------------------------------------------------------------
print_header "ШАГ 9: ПРИМЕНЕНИЕ НАСТРОЕК"

print_step "Перезапуск Apache2..."
systemctl restart httpd2

if [[ $? -eq 0 ]]; then
    print_success "Apache2 перезапущен"
else
    print_error "Ошибка перезапуска Apache2"
    exit 1
fi

#-------------------------------------------------------------------------------
# Шаг 10: Создание config.php
#-------------------------------------------------------------------------------
print_header "ШАГ 10: СОЗДАНИЕ CONFIG.PHP"

MOODLE_CONFIG="${MOODLE_WWW_ROOT}/config.php"

print_step "Создание конфигурационного файла Moodle..."

cat > "${MOODLE_CONFIG}" <<EOF
<?php
// Moodle configuration file
// Автоматически создано установочным скриптом

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${MOODLE_DB_NAME}';
\$CFG->dbuser    = '${MOODLE_DB_USER}';
\$CFG->dbpass    = '${MOODLE_DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array(
    'dbpersist' => false,
    'dbport' => '',
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = 'http://${SERVER_IP}';
\$CFG->dataroot  = '${MOODLE_DATA_ROOT}';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');
EOF

chown apache2:apache2 "${MOODLE_CONFIG}"
chmod 640 "${MOODLE_CONFIG}"

print_success "config.php создан: ${MOODLE_CONFIG}"

#-------------------------------------------------------------------------------
# Шаг 11: Настройка cron
#-------------------------------------------------------------------------------
print_header "ШАГ 11: НАСТРОЙКА CRON"

print_step "Добавление задачи cron для Moodle..."

CRON_LINE="* * * * * /usr/bin/php ${MOODLE_WWW_ROOT}/admin/cli/cron.php > /dev/null 2>&1"

# Проверяем, есть ли уже запись
if crontab -l 2>/dev/null | grep -q "moodle.*cron"; then
    print_info "Cron задача уже существует"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    print_success "Cron задача добавлена"
fi

#-------------------------------------------------------------------------------
# Информация о завершении
#-------------------------------------------------------------------------------
print_header "УСТАНОВКА ЗАВЕРШЕНА"

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            MOODLE УСПЕШНО УСТАНОВЛЕН!                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${CYAN}═══ ПАРАМЕТРЫ ПОДКЛЮЧЕНИЯ ═══${NC}"
echo ""
echo "  URL сайта:        http://${SERVER_IP}"
echo "  URL установки:    http://${SERVER_IP}/install.php"
echo ""
echo -e "${CYAN}═══ БАЗА ДАННЫХ ═══${NC}"
echo ""
echo "  Имя БД:           ${MOODLE_DB_NAME}"
echo "  Пользователь:     ${MOODLE_DB_USER}"
echo "  Пароль:           ${MOODLE_DB_PASS}"
echo ""
echo -e "${CYAN}═══ ФАЙЛЫ ═══${NC}"
echo ""
echo "  Moodle:           ${MOODLE_WWW_ROOT}"
echo "  Данные:           ${MOODLE_DATA_ROOT}"
echo "  Config:           ${MOODLE_CONFIG}"
echo "  Apache config:    ${APACHE_CONF}"
echo "  PHP config:       ${PHP_INI}"
echo ""
echo -e "${CYAN}═══ ДАЛЬНЕЙШИЕ ДЕЙСТВИЯ ═══${NC}"
echo ""
echo "  1. Откройте браузер на клиентской машине"
echo "  2. Перейдите по адресу: http://${SERVER_IP}/install.php"
echo "  3. Выберите язык и следуйте инструкциям"
echo "  4. Подтвердите пути (должны быть уже заполнены)"
echo "  5. Выберите драйвер БД: MariaDB (native/mariadb)"
echo "  6. Введите параметры БД (указаны выше)"
echo "  7. Создайте администратора:"
echo "     Логин: admin"
echo "     Пароль: P@ssw0rd"
if [[ -n "$SITE_NAME" ]]; then
    echo "  8. Название сайта: ${SITE_NAME}"
fi
echo ""
echo -e "${YELLOW}═══ ПОЛЕЗНЫЕ КОМАНДЫ ═══${NC}"
echo ""
echo "  Перезапуск Apache:  systemctl restart httpd2"
echo "  Перезапуск MariaDB: systemctl restart mariadb"
echo "  Статус служб:       systemctl status httpd2 mariadb"
echo "  Логи Apache:        tail -f /var/log/httpd2/moodle-error.log"
echo "  Moodle CLI:         php ${MOODLE_WWW_ROOT}/admin/cli/"
echo ""
