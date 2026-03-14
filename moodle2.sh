#!/bin/bash
#===============================================================================
# Быстрая установка Moodle на ALT Linux (без интерактивного ввода)
# Использование: ./quick_moodle_install.sh [IP] [SERVER_NAME] [DB_PASS]
#===============================================================================

# Параметры (можно передать как аргументы или использовать по умолчанию)
SERVER_IP="${1:-192.168.100.1}"
SERVER_NAME="${2:-hq-srv.au-team.irpo}"
DB_PASS="${3:-P@ssw0rd}"

# Константы
MOODLE_DB="moodle"
MOODLE_USER="moodle"
MOODLE_VERSION="405"
MOODLE_WWW="/var/www/html/moodle"
MOODLE_DATA="/var/www/moodledata"

set -e  # Прерывание при ошибке

echo "=== Установка Moodle на ALT Linux ==="
echo "IP: $SERVER_IP | Server: $SERVER_NAME | DB Pass: $DB_PASS"

# 1. Установка пакетов
echo "[1/9] Установка пакетов..."
apt-get update -qq
apt-get install -y -qq apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server \
    php8.2-opcache php8.2-curl php8.2-gd php8.2-intl php8.2-mysqlnd-mysqli \
    php8.2-xmlrpc php8.2-zip php8.2-soap php8.2-mbstring php8.2-xmlreader \
    php8.2-fileinfo php8.2-sodium

# 2. Запуск служб
echo "[2/9] Запуск служб..."
systemctl enable --now httpd2 mariadb

# 3. Настройка БД
echo "[3/9] Создание базы данных..."
mariadb -u root -e "
CREATE DATABASE IF NOT EXISTS ${MOODLE_DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MOODLE_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${MOODLE_DB}.* TO '${MOODLE_USER}'@'localhost';
FLUSH PRIVILEGES;"

# 4. Скачивание Moodle
echo "[4/9] Скачивание Moodle..."
cd /tmp
wget -q "https://download.moodle.org/download.php/direct/stable${MOODLE_VERSION}/moodle-latest-${MOODLE_VERSION}.tgz"
tar -xf "moodle-latest-${MOODLE_VERSION}.tgz"

# 5. Установка файлов
echo "[5/9] Установка файлов..."
rm -rf "${MOODLE_WWW}"
mv moodle /var/www/html/
mkdir -p "${MOODLE_DATA}"
rm -f /var/www/html/index.html
chown -R apache2:apache2 /var/www/html "${MOODLE_DATA}"

# 6. Настройка Apache
echo "[6/9] Настройка Apache..."
mkdir -p /etc/httpd2/conf/sites-available
cat > /etc/httpd2/conf/sites-available/default.conf <<EOF
<VirtualHost *:80>
    DocumentRoot ${MOODLE_WWW}
    ServerName ${SERVER_NAME}
    <Directory ${MOODLE_WWW}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

# 7. Настройка PHP
echo "[7/9] Настройка PHP..."
PHP_INI="/etc/php/8.2/apache2-mod_php/php.ini"
sed -i 's/^max_input_vars.*/max_input_vars = 5000/' "$PHP_INI"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' "$PHP_INI"
sed -i 's/^post_max_size.*/post_max_size = 100M/' "$PHP_INI"

# 8. Создание config.php
echo "[8/9] Создание config.php..."
cat > "${MOODLE_WWW}/config.php" <<EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();
\$CFG->dbtype = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost = 'localhost';
\$CFG->dbname = '${MOODLE_DB}';
\$CFG->dbuser = '${MOODLE_USER}';
\$CFG->dbpass = '${DB_PASS}';
\$CFG->prefix = 'mdl_';
\$CFG->dboptions = array('dbcollation' => 'utf8mb4_unicode_ci');
\$CFG->wwwroot = 'http://${SERVER_IP}';
\$CFG->dataroot = '${MOODLE_DATA}';
\$CFG->admin = 'admin';
\$CFG->directorypermissions = 0777;
require_once(__DIR__ . '/lib/setup.php');
EOF
chown apache2:apache2 "${MOODLE_WWW}/config.php"

# 9. Перезапуск Apache
echo "[9/9] Перезапуск Apache..."
systemctl restart httpd2

# Завершение
echo ""
echo "=== Moodle установлен! ==="
echo "URL: http://${SERVER_IP}/install.php"
echo "БД: ${MOODLE_DB} | Пользователь: ${MOODLE_USER} | Пароль: ${DB_PASS}"
echo ""
