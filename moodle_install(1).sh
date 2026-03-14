#!/bin/bash
# Скрипт установки Moodle на ALT Linux

apt-get install -y apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server

apt-get install -y php8.2-opcache php8.2-curl php8.2-gd php8.2-intl \
    php8.2-mysqlnd-mysqli php8.2-xmlrpc php8.2-zip php8.2-soap \
    php8.2-mbstring php8.2-xmlreader php8.2-fileinfo php8.2-sodium

systemctl enable --now httpd2 mariadb

mariadb -u root <<EOF
CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
EOF

cd /tmp
wget https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz
tar -xf moodle-latest-405.tgz
mv moodle /var/www/html/
mkdir /var/www/moodledata
chown -R apache2:apache2 /var/www/html /var/www/moodledata
rm /var/www/html/index.html

mkdir -p /etc/httpd2/conf/sites-available
cat > /etc/httpd2/conf/sites-available/default.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/moodle
    ServerName hq-srv.au-team.irpo
    <Directory /var/www/html/moodle>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

sed -i 's/^max_input_vars.*/max_input_vars = 5000/' /etc/php/8.2/apache2-mod_php/php.ini
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' /etc/php/8.2/apache2-mod_php/php.ini
sed -i 's/^post_max_size.*/post_max_size = 100M/' /etc/php/8.2/apache2-mod_php/php.ini

systemctl restart httpd2

echo "Установка завершена: http://192.168.100.1/install.php"
