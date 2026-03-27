#!/bin/bash

# ==========================================
# Конфигурация
# ==========================================
MOODLE_DOMAIN="moodle.au-team.irpo"
WIKI_DOMAIN="wiki.au-team.irpo"

# Укажите порты, на которых реально работают ваши сервисы
# (Обычно это localhost:8080, localhost:8081 или docker-контейнеры)
MOODLE_PORT="8080"
WIKI_PORT="8081"

# ==========================================
# Проверка прав суперпользователя
# ==========================================
if [ "$EUID" -ne 0 ]; then 
  echo "Ошибка: Пожалуйста, запускайте скрипт от имени root (sudo)."
  exit 1
fi

echo ">>> Начало настройки Nginx Reverse Proxy..."

# ==========================================
# 1. Установка Nginx (если не установлен)
# ==========================================
if ! command -v nginx &> /dev/null; then
    echo ">>> Nginx не найден. Установка..."
    apt-get update
    apt-get install nginx -y
else
    echo ">>> Nginx уже установлен."
fi

# ==========================================
# 2. Создание конфигурационных файлов
# ==========================================

# Конфиг для Moodle
cat > /etc/nginx/sites-available/$MOODLE_DOMAIN <<EOF
server {
    listen 80;
    server_name $MOODLE_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$MOODLE_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Конфиг для MediaWiki
cat > /etc/nginx/sites-available/$WIKI_DOMAIN <<EOF
server {
    listen 80;
    server_name $WIKI_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$WIKI_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo ">>> Конфигурационные файлы созданы."

# ==========================================
# 3. Активация сайтов (создание симлинков)
# ==========================================
ln -sf /etc/nginx/sites-available/$MOODLE_DOMAIN /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/$WIKI_DOMAIN /etc/nginx/sites-enabled/

# Удаляем дефолтный конфиг, чтобы не мешал (опционально)
rm -f /etc/nginx/sites-enabled/default

echo ">>> Сайты активированы."

# ==========================================
# 4. Настройка локального DNS (hosts)
# ==========================================
# Добавляем записи в hosts, чтобы сервер сам понимал эти домены
if ! grep -q "$MOODLE_DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $MOODLE_DOMAIN" >> /etc/hosts
fi

if ! grep -q "$WIKI_DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $WIKI_DOMAIN" >> /etc/hosts
fi

echo ">>> Записи добавлены в /etc/hosts."

# ==========================================
# 5. Проверка и перезагрузка Nginx
# ==========================================
echo ">>> Проверка конфигурации nginx..."
nginx -t

if [ $? -eq 0 ]; then
    echo ">>> Конфигурация верна. Перезагрузка службы..."
    systemctl restart nginx
    systemctl enable nginx
    echo ">>> Настройка завершена успешно!"
    echo ""
    echo "Теперь проверьте доступность:"
    echo "1. http://$MOODLE_DOMAIN"
    echo "2. http://$WIKI_DOMAIN"
else
    echo ">>> Ошибка в конфигурации Nginx! Проверьте логи."
    exit 1
fi
