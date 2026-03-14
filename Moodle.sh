#!/bin/bash

# ==========================================
# MOODLE AUTO-INSTALLER (INTERACTIVE)
# ==========================================

# --- 1. ИНТЕРАКТИВНЫЙ ВВОД ДАННЫХ ---
echo "=========================================="
echo "   НАСТРОЙКА ПАРАМЕТРОВ УСТАНОВКИ"
echo "=========================================="

# Ввод имени сайта (по умолчанию можно нажать Enter)
read -p "Введите название сайта (например: 'Мой Учебный Центр'): " SITE_NAME
SITE_NAME=${SITE_NAME:-"Moodle Site"}

# Ввод логина админа
read -p "Введите логин администратора [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-"admin"}

# Ввод пароля админа (скрытый ввод)
while true; do
    read -s -p "Введите пароль администратора: " ADMIN_PASS
    echo
    read -s -p "Повторите пароль администратора: " ADMIN_PASS2
    echo
    if [ "$ADMIN_PASS" = "$ADMIN_PASS2" ]; then
        break
    else
        echo -e "\033[31mПароли не совпадают. Попробуйте снова.\033[0m"
    fi
done

# Ввод пароля от БД (для создания пользователя moodle в БД)
read -s -p "Введите пароль для пользователя БД 'moodle': " DB_PASS
echo

# Ввод имени сервера
read -p "Введите имя сервера (домен или IP) [hq-srv.au-team.irpo]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-"hq-srv.au-team.irpo"}

echo -e "\n\033[32mНастройки приняты. Начинаю установку...\033[0m"

# --- КОНСТАНТЫ ---
MOODLE_WWW="/var/www/html/moodle"
MOODLE_DATA="/var/www/moodledata"
DB_NAME="moodle"
DB_USER="moodle"
MOODLE_TGZ="moodle-latest-405.tgz"
APACHE_USER="apache2" # Пользователь для ALT Linux

# --- 2. УСТАНОВКА ЗАВИСИМОСТЕЙ ---
echo -e "\n\033[33m[1/8] Установка пакетов...\033[0m"
apt-get update
apt-get install -y apache2 php8.2 apache2-mods apache2-mod_php8.2 mariadb-server

echo -e "\n\033[33m[2/8] Установка PHP модулей...\033[0m"
apt-get install -y php8.2-opcache php8.2-curl php8.2-gd php8.2-intl \
php8.2-mysqlnd-mysqli php8.2-xmlrpc php8.2-zip php8.2-soap \
php8.2-mbstring php8.2-xmlreader php8.2-fileinfo php8.2-sodium

# --- 3. ЗАПУСК СЛУЖБ ---
echo -e "\n\033[33m[3/8] Запуск служб...\033[0m"
systemctl enable --now httpd2
systemctl enable --now mariadb

# --- 4. НАСТРОЙКА БАЗЫ ДАННЫХ ---
echo -e "\n\033[33m[4/8] Настройка MariaDB...\033[0m"
mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- 5. СКАЧИВАНИЕ MOODLE ---
echo -e "\n\033[33m[5/8] Скачивание и распаковка Moodle...\033[0m"
if [ ! -f "$MOODLE_TGZ" ]; then
    wget https://download.moodle.org/download.php/direct/stable405/$MOODLE_TGZ
fi

tar -xf $MOODLE_TGZ
rm -f /var/www/html/index.html
mv moodle /var/www/html/
mkdir -p $MOODLE_DATA
chown -R $APACHE_USER:$APACHE_USER /var/www/html
chown -R $APACHE_USER:$APACHE_USER $MOODLE_DATA

# --- 6. НАСТРОЙКА APACHE ---
echo -e "\n\033[33m[6/8] Настройка Apache...\033[0m"
cat <<EOF > /etc/httpd2/conf/sites-available/default.conf
<VirtualHost *:80>
    DocumentRoot $MOODLE_WWW
    ServerName $SERVER_NAME
    <Directory $MOODLE_WWW>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

if [ ! -f "/etc/httpd2/conf/sites-enabled/default.conf" ]; then
    ln -s /etc/httpd2/conf/sites-available/default.conf /etc/httpd2/conf/sites-enabled/default.conf
fi

# --- 7. НАСТРОЙКА PHP ---
echo -e "\n\033[33m[7/8] Настройка php.ini...\033[0m"
PHP_INI="/etc/php/8.2/apache2-mod_php/php.ini"
sed -i 's/^max_input_vars.*/max_input_vars = 5000/' $PHP_INI
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' $PHP_INI
sed -i 's/^post_max_size.*/post_max_size = 100M/' $PHP_INI

systemctl restart httpd2

# --- 8. АВТОМАТИЧЕСКАЯ УСТАНОВКА MOODLE (CLI) ---
echo -e "\n\033[33m[8/8] Установка Moodle через CLI...\033[0m"
# Переходим в директорию Moodle
cd $MOODLE_WWW

# Запускаем установку от имени веб-пользователя
# Используем --dbtype=mariadb, чтобы избежать ошибки подключения
sudo -u $APACHE_USER /usr/bin/php admin/cli/install.php \
  --lang=ru \
  --wwwroot="http://$SERVER_NAME" \
  --dataroot="$MOODLE_DATA" \
  --dbtype="mariadb" \
  --dbhost="localhost" \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASS" \
  --fullname="$SITE_NAME" \
  --shortname="$SITE_NAME" \
  --adminuser="$ADMIN_USER" \
  --adminpass="$ADMIN_PASS" \
  --agree-license \
  --allow-unstable

echo -e "\n=========================================="
echo -e "\033[32mУСТАНОВКА ЗАВЕРШЕНА!\033[0m"
echo -e "=========================================="
echo -e "Сайт: http://$SERVER_NAME"
echo -e "Логин: $ADMIN_USER"
echo -e "Пароль: [Ваш пароль]"
echo -e "Название: $SITE_NAME"
