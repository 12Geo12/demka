#!/bin/bash

# ==========================================
# Конфигурация для ALT Linux
# ==========================================
MOODLE_DOMAIN="moodle.au-team.irpo"
WIKI_DOMAIN="wiki.au-team.irpo"
MOODLE_PORT="8080"
WIKI_PORT="8081"

# Определяем правильную директорию
if [ -d "/etc/nginx/sites-available.d" ]; then
    CONF_DIR="/etc/nginx/sites-available.d"
elif [ -d "/etc/nginx/conf.d" ]; then
    CONF_DIR="/etc/nginx/conf.d"
else
    # Создаем директорию если нет
    CONF_DIR="/etc/nginx/conf.d"
    mkdir -p $CONF_DIR
fi

echo ">>> Используем директорию: $CONF_DIR"

# ==========================================
# Создаем конфигурационные файлы
# ==========================================

# Конфиг для Moodle
cat > $CONF_DIR/$MOODLE_DOMAIN.conf <<EOF
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
cat > $CONF_DIR/$WIKI_DOMAIN.conf <<EOF
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

echo ">>> Конфигурационные файлы созданы в $CONF_DIR"

# ==========================================
# Добавляем в /etc/hosts
# ==========================================
if ! grep -q "$MOODLE_DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $MOODLE_DOMAIN" >> /etc/hosts
fi

if ! grep -q "$WIKI_DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $WIKI_DOMAIN" >> /etc/hosts
fi

# ==========================================
# Проверяем и перезапускаем nginx
# ==========================================
echo ">>> Проверка конфигурации..."
nginx -t

if [ $? -eq 0 ]; then
    echo ">>> Перезапуск nginx..."
    systemctl restart nginx
    echo ">>> Настройка завершена!"
    echo ""
    echo "Проверьте доступность:"
    echo "1. http://$MOODLE_DOMAIN"
    echo "2. http://$WIKI_DOMAIN"
else
    echo ">>> Ошибка в конфигурации!"
    exit 1
fi
