#!/bin/bash
# Скрипт установки Moodle на ALT Linux

set -e

# Параметры
DB_NAME="moodle"
DB_USER="moodle"
DB_PASS="P@ssw0rd"
SERVER_NAME="hq-srv.au-team.irpo"
SERVER_IP="192.168.100.1"

echo "Установка зависимостей..."
echo "apt-get update"
apt-get update

echo "apt-get install -y apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server"
apt-get install -y apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server

echo ""
echo "Установка PHP модулей..."
echo "apt-get install -y php8.2-opcache php8.2-curl php8.2-gd php8.2-intl php8.2-mysqlnd-mysqli php8.2-xmlrpc php8.2-zip php8.2-soap php8.2-mbstring php8.2-xmlreader php8.2-fileinfo php8.2-sodium"
apt-get install -y php8.2-opcache php8.2-curl php8.2-gd php8.2-intl \
    php8.2-mysqlnd-mysqli php8.2-xmlrpc php8.2-zip php8.2-soap \
    php8.2-mbstring php8.2-xmlreader php8.2-fileinfo php8.2-sodium

echo ""
echo "Запуск служб..."
echo "systemctl enable --now httpd2 mariadb"
systemctl enable --now httpd2 mariadb

echo ""
echo "Настройка MariaDB..."
echo "mariadb -u root -e \"CREATE DATABASE ${DB_NAME}...\""
mariadb -u root <<EOF
CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo ""
echo "Скачивание Moodle..."
echo "cd /tmp && wget https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz"
cd /tmp
wget https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz

echo ""
echo "Распаковка..."
echo "tar -xf moodle-latest-405.tgz"
tar -xf moodle-latest-405.tgz

echo ""
echo "Установка файлов..."
echo "mv moodle /var/www/html/"
mv moodle /var/www/html/

echo "mkdir /var/www/moodledata"
mkdir /var/www/moodledata

echo "chown -R apache2:apache2 /var/www/html /var/www/moodledata"
chown -R apache2:apache2 /var/www/html /var/www/moodledata

echo "rm -f /var/www/html/index.html"
rm -f /var/www/html/index.html

echo ""
echo "Настройка Apache..."
echo "cat > /etc/httpd2/conf/sites-available/default.conf"
mkdir -p /etc/httpd2/conf/sites-available
cat > /etc/httpd2/conf/sites-available/default.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/moodle
    ServerName ${SERVER_NAME}
    <Directory /var/www/html/moodle>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

echo ""
echo "Настройка PHP..."
echo "sed -i 's/^max_input_vars.*/max_input_vars = 5000/' /etc/php/8.2/apache2-mod_php/php.ini"
sed -i 's/^max_input_vars.*/max_input_vars = 5000/' /etc/php/8.2/apache2-mod_php/php.ini

echo "sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' /etc/php/8.2/apache2-mod_php/php.ini"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' /etc/php/8.2/apache2-mod_php/php.ini

echo "sed -i 's/^post_max_size.*/post_max_size = 100M/' /etc/php/8.2/apache2-mod_php/php.ini"
sed -i 's/^post_max_size.*/post_max_size = 100M/' /etc/php/8.2/apache2-mod_php/php.ini

echo ""
echo "Перезапуск Apache..."
echo "systemctl restart httpd2"
systemctl restart httpd2

echo ""
echo "=========================================="
echo "Установка завершена!"
echo "=========================================="
echo "URL:      http://${SERVER_IP}/install.php"
echo "БД:       ${DB_NAME}"
echo "Пользователь: ${DB_USER}"
echo "Пароль:   ${DB_PASS}"
echo "=========================================="
