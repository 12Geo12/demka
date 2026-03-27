#!/bin/bash

# ==========================================
# ИСПРАВЛЕННЫЙ СКРИПТ SAMBA AD ДЛЯ ALT LINUX
# Устранены ошибки: netlogon share, winbind start, paths
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}================================================${NC}"
}

status() {
    if [ $1 -eq 0 ]; then
        echo -e "[${GREEN}OK${NC}] $2"
    else
        echo -e "[${RED}FAIL${NC}] $2"
        if [ "$3" == "critical" ]; then
            exit 1
        fi
    fi
}

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Запустите от root!${NC}"
    exit 1
fi

# ==========================================
# 1. Установка пакетов
# ==========================================
print_header "1. Установка пакетов"

apt-get update
apt-get install -y samba samba-dc samba-client samba-common acl
status $? "Пакеты установлены" "critical"

# ==========================================
# 2. Полная очистка перед настройкой
# ==========================================
print_header "2. Очистка старых данных"

# Останавливаем службы
systemctl stop smb nmb winbind 2>/dev/null

# КРИТИЧЕСКИ ВАЖНО: Удаляем конфиг, чтобы samba-tool создал новый чистый
rm -f /etc/samba/smb.conf

# Удаляем старые базы данных
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
rm -f /var/lib/samba/*.tdb
rm -f /var/lib/samba/*.ldb

mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/sysvol

status 0 "Очистка завершена"

# ==========================================
# 3. Ввод данных и Provisioning
# ==========================================
print_header "3. Создание домена"

# Интерактивный ввод
read -p "Введите полное имя домена (например, au-team.irpo): " REALM_INPUT
read -p "Введите IP-адрес этого сервера: " SERVER_IP

# Формируем имена
REALM=$(echo "$REALM_INPUT" | tr '[:lower:]' '[:upper:]')
DOMAIN_SHORT=$(echo "$REALM_INPUT" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')
HOSTNAME_SHORT=$(hostname -s | tr '[:lower:]' '[:upper:]')

echo -e "Realm: ${GREEN}$REALM${NC}"
echo -e "Domain: ${GREEN}$DOMAIN_SHORT${NC}"
echo -e "Hostname: ${GREEN}$HOSTNAME_SHORT${NC}"

# Запуск samba-tool (без явного указания конфига, он создаст его сам)
samba-tool domain provision \
    --realm="$REALM" \
    --domain="$DOMAIN_SHORT" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssw0rd' \
    --use-rfc2307

if [ $? -ne 0 ]; then
    status 1 "Ошибка при создании домена" "critical"
fi
status 0 "Домен создан"

# Перемещаем созданный конфиг в /etc/samba/
if [ -f "/var/lib/samba/private/smb.conf" ]; then
    cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
    status 0 "Конфиг smb.conf скопирован"
else
    # Если samba-tool создал конфиг сразу в /etc (зависит от версии)
    if [ -f "/etc/samba/smb.conf" ]; then
        status 0 "Конфиг на месте"
    else
        status 1 "Конфиг не найден" "critical"
    fi
fi

# Копируем Kerberos
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
status 0 "Kerberos настроен"

# ==========================================
# 4. Исправление путей в конфиге (для ALT Linux)
# ==========================================
print_header "4. Корректировка smb.conf"

# Добавляем явные пути, чтобы winbind точно нашел базы
sed -i "/\[global\]/a \   lock directory = /var/lib/samba" /etc/samba/smb.conf
sed -i "/\[global\]/a \   state directory = /var/lib/samba" /etc/samba/smb.conf
sed -i "/\[global\]/a \   cache directory = /var/lib/samba" /etc/samba/smb.conf
sed -i "/\[global\]/a \   private dir = /var/lib/samba/private" /etc/samba/smb.conf

# Проверка синтаксиса
testparm -s 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка в smb.conf! Проверьте вывод testparm выше.${NC}"
    exit 1
fi
status 0 "Проверка testparm прошла успешно"

# ==========================================
# 5. Запуск служб
# ==========================================
print_header "5. Запуск служб"

# ALT Linux: включаем и запускаем
systemctl enable smb nmb winbind

# Сначала запускаем smb (он поднимает AD), потом winbind
systemctl restart smb
sleep 2
systemctl restart nmb
sleep 2
systemctl restart winbind

# Проверка статуса
if systemctl is-active --quiet winbind; then
    status 0 "Winbind запущен"
else
    status 1 "Winbind НЕ запущен"
    echo -e "${YELLOW}Попробуйте перезагрузить сервер (reboot) и проверить снова.${NC}"
fi

# ==========================================
# 6. Пользователи и права
# ==========================================
print_header "6. Настройка пользователей"

# Создание группы hq
samba-tool group add hq 2>/dev/null
status 0 "Группа hq готова"

# Создание 5 пользователей
for i in {1..5}; do
    USERNAME="user${i}.hq"
    PASS="P@ssw0rd${i}"
    samba-tool user create "$USERNAME" "$PASS" 2>/dev/null
    samba-tool group addmembers hq "$USERNAME" 2>/dev/null
done
status 0 "Пользователи user1-5.hq созданы"

# Импорт из CSV
CSV="/opt/users.csv"
if [ -f "$CSV" ]; then
    echo "Импорт из $CSV..."
    while IFS=',' read -r u p; do
        [ -z "$u" ] && continue
        samba-tool user create "$u" "$p" 2>/dev/null && echo "Создан: $u"
    done < "$CSV"
fi

# Настройка SUDO
echo "Настройка sudo..."
SUDO_FILE="/etc/sudoers.d/hq-permissions"
cat <<EOF > $SUDO_FILE
Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id
%hq ALL=(ALL) HQ_CMDS
EOF
chmod 440 $SUDO_FILE
status 0 "SUDO настроен"

# ==========================================
# Завершение
# ==========================================
print_header "УСПЕШНО ЗАВЕРШЕНО"
echo -e "Домен: ${GREEN}$REALM${NC}"
echo -e "Короткое имя: ${GREEN}$DOMAIN_SHORT${NC}"
echo -e "Администратор: ${GREEN}Administrator${NC}"
echo -e "Пароль: ${GREEN}P@ssw0rd${NC}"
echo ""
echo -e "Проверка домена:"
echo "  wbinfo -u"
echo "  wbinfo -g"
echo "  systemctl status winbind"
