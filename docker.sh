#!/bin/bash
#===============================================================================
# Скрипт установки Docker + MediaWiki для Alt Linux
# Версия: 1.0
#===============================================================================

echo "=========================================="
echo "Установка Docker + MediaWiki для Alt Linux"
echo "=========================================="

# Обновление системы
echo "[1/7] Обновление системы..."
apt-get update
apt-get dist-upgrade -y
echo "[OK] Система обновлена"

# Установка Docker
echo "[2/7] Установка Docker..."
apt-get install -y docker-ce docker-compose || apt-get install -y docker-io docker-compose || {
    apt-get install -y docker
    apt-get install -y python3 python3-pip
    pip3 install docker-compose
}
echo "[OK] Docker установлен"

# Включение Docker
echo "[3/7] Запуск Docker..."
systemctl enable --now docker
systemctl start docker
docker --version
echo "[OK] Docker запущен"

# Создание директории
echo "[4/7] Создание директории /root/mediawiki..."
mkdir -p /root/mediawiki
echo "[OK] Директория создана"

# Создание wiki.yml
echo "[5/7] Создание файла /root/wiki.yml..."
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
echo "[OK] Файл создан"

# Создание временного файла без volumes
echo "[6/7] Создание временного файла для первого запуска..."
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
echo "[OK] Временный файл создан"

# Первый запуск
echo "[7/7] Первый запуск контейнеров..."
cd /root
docker-compose -f wiki_first_run.yml up -d 2>/dev/null || docker compose -f wiki_first_run.yml up -d
echo "[OK] Контейнеры запущены"

# Проверка
echo ""
echo "=========================================="
echo "Проверка статуса:"
echo "=========================================="
docker ps

echo ""
echo "=========================================="
echo "ВАЖНО! Дальнейшие действия:"
echo "=========================================="
echo "1. Откройте в браузере: http://YOUR_IP:8080"
echo "2. Установите MediaWiki"
echo "3. Скачайте LocalSettings.php"
echo "4. Скопируйте: cp LocalSettings.php /root/mediawiki/"
echo "5. Выполните команды:"
echo ""
echo "   docker compose -f /root/wiki_first_run.yml down"
echo "   rm /root/wiki_first_run.yml"
echo "   docker compose -f /root/wiki.yml up -d"
echo ""
echo "=========================================="
