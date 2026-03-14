#!/bin/bash

# ==========================================
# MOODLE AUTO-INSTALLER (ALT LINUX)
# ==========================================

# --- КОНФИГУРАЦИЯ ---
DB_NAME="moodle"
DB_USER="moodle"
DB_PASS="P@ssw0rd"
ADMIN_USER="admin"
ADMIN_PASS="P@ssw0rd"
MOODLE_VERSION="405" # 4.5

# Пути (стандарт для ALT Linux)
MOODLE_WWW="/var/www/html/moodle"
MOODLE_DATA="/var/www/moodledata"
APACHE_CONF="/etc/httpd2/conf/sites-available/default.conf"
PHP_INI="/etc/php/8.2/apache2-mod_php/php.ini"
SERVER_NAME="hq-srv.au-team.irpo" # Измените на свой IP или домен
# --------------------

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите скрипт от root (su -).${NC}"
  exit 1
fi

echo -e "${YELLOW}=== ШАГ 1: Установка зависимостей ===${NC}"
apt-get update
# Установка Apache, PHP и MariaDB
apt-get install -y apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server

echo -e "${YELLOW}=== ШАГ 2: Установка PHP модулей ===${NC}"
apt-get install -y php8.2-opcache php8.2-curl php8.2-gd php8.2-intl \
php8.2-mysqlnd-mysqli php8.2-xmlrpc php8.2-zip php8.2-soap \
php8.2-mbstring php8.2-xmlreader php8.2-fileinfo php8.2-sodium

echo -e "${YELLOW}=== ШАГ 3: Запуск служб ===${NC}"
systemctl enable --now httpd2
systemctl enable --now mariadb

echo -e "${YELLOW}=== ШАГ 4: Настройка базы данных ===${NC}"
# Проверяем, создана ли база, чтобы не было ошибок при повторном запуске
mariadb -u root -e "CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mariadb -u root -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mariadb -u root -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mariadb -u root -e "FLUSH PRIVILEGES;"
echo -e "${GREEN}База данных готова.${NC}"

echo -e "${YELLOW}=== ШАГ 5: Скачивание и распаковка Moodle ===${NC}"
if [ ! -d "$MOODLE_WWW" ]; then
    cd /tmp
    wget https://download.moodle.org/download.php/direct/stable${MOODLE_VERSION}/moodle-latest-${MOODLE_VERSION}.tgz
    tar -xf moodle-latest-${MOODLE_VERSION}.tgz
    
    mkdir -p /var/www/html
    mv moodle /var/www/html/
    mkdir -p $MOODLE_DATA
    
    # Удаление стандартной заглушки Apache
    rm -f /var/www/html/index.html
else
    echo -e "${YELLOW}Директория Moodle уже существует, пропуск распаковки.${NC}"
fi

echo -e "${YELLOW}=== ШАГ 6: Права доступа ===${NC}"
chown -R apache2:apache2 /var/www/html
chown -R apache2:apache2 $MOODLE_DATA
chmod -R 775 $MOODLE_DATA
echo -e "${GREEN}Права назначены.${NC}"

echo -e "${YELLOW}=== ШАГ 7: Настройка Apache (VirtualHost) ===${NC}"
cat <<EOF > $APACHE_CONF
<VirtualHost *:80>
    DocumentRoot $MOODLE_WWW
    ServerName $SERVER_NAME
    
    <Directory $MOODLE_WWW>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog /var/log/httpd2/moodle-error.log
    CustomLog /var/log/httpd2/moodle-access.log common
</VirtualHost>
EOF

# В ALT Linux иногда нужно включить сайт или перезапуск
# Проверим наличие sites-enabled и создадим симлинк если нужно
if [ ! -f "/etc/httpd2/conf/sites-enabled/default.conf" ]; then
    ln -s $APACHE_CONF /etc/httpd2/conf/sites-enabled/default.conf
fi

echo -e "${YELLOW}=== ШАГ 8: Настройка PHP (php.ini) ===${NC}"
# Бэкап php.ini
cp $PHP_INI ${PHP_INI}.bak

# Изменение параметров
sed -i 's/^max_input_vars.*/max_input_vars = 5000/' $PHP_INI
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' $PHP_INI
sed -i 's/^post_max_size.*/post_max_size = 100M/' $PHP_INI

# Если параметры закомментированы или отсутствуют, добавим их (грубый метод, но рабочий)
grep -q "max_input_vars = 5000" $PHP_INI || echo "max_input_vars = 5000" >> $PHP_INI
grep -q "upload_max_filesize = 100M" $PHP_INI || echo "upload_max_filesize = 100M" >> $PHP_INI
grep -q "post_max_size = 100M" $PHP_INI || echo "post_max_size = 100M" >> $PHP_INI

echo -e "${GREEN}PHP настроен.${NC}"

echo -e "${YELLOW}=== ШАГ 9: Перезапуск Apache ===${NC}"
systemctl restart httpd2
systemctl status httpd2 --no-pager

echo -e "============================================"
echo -e "${GREEN}Установка завершена!${NC}"
echo -e "============================================"
echo -e "1. Откройте браузер и перейдите по адресу:"
echo -e "   http://$SERVER_NAME/install.php"
echo -e "   (или http://<IP-адрес сервера>/install.php)"
echo -e "2. Данные для БД:"
echo -e "   Host: localhost"
echo -e "   DB Name: $DB_NAME"
echo -e "   User: $DB_USER"
echo -e "   Pass: $DB_PASS"
echo -e "3. После веб-установки, если возникнут проблемы с БД,"
echo -e "   отредактируйте config.php и укажите \$CFG->dbtype = 'mariadb';"
