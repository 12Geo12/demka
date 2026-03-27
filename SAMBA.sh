#!/bin/bash

# ==========================================
# ИСПРАВЛЕННЫЙ СКРИПТ (ошибка smb.conf)
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
print_header "1. Установка пакетов Samba DC"

apt-get update
apt-get install -y samba samba-dc samba-client samba-common acl

if ! command -v samba-tool &> /dev/null; then
    echo -e "${RED}Ошибка: samba-tool не установлен.${NC}"
    exit 1
fi
status $? "Пакеты установлены"

# ==========================================
# 2. Подготовка (ОЧЕНЬ ВАЖНЫЙ ЭТАП)
# ==========================================
print_header "2. Очистка старых данных"

# Останавливаем службы
systemctl stop smb nmb winbind 2>/dev/null

# КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ:
# Удаляем ВСЕ старые конфиги и базы данных.
# Это обязательно для чистого Provisioning.

echo "Удаление старых баз данных и конфигов..."
rm -f /etc/samba/smb.conf
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
print_header "3. Настройка домена"

read -p "Введите полное имя домена (например, au-team.irpo): " REALM_INPUT
read -p "Введите IP-адрес этого сервера: " SERVER_IP

# Формируем имена
# Realm: AU-TEAM.IRPO
REALM=$(echo "$REALM_INPUT" | tr '[:lower:]' '[:upper:]')
# Domain (Short): AU-TEAM (берем первую часть до точки и приводим к верхнему регистру)
DOMAIN_SHORT=$(echo "$REALM_INPUT" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

echo -e "Realm: ${GREEN}$REALM${NC}"
echo -e "Short Domain: ${GREEN}$DOMAIN_SHORT${NC}"

# Запуск provisioning
# ВАЖНО: Запускаем БЕЗ опции --configfile, чтобы samba-tool создал конфиг сам с нуля.
echo "Запуск samba-tool domain provision..."

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
status 0 "Домен создан успешно"

# Перемещаем конфиг, созданный samba-tool, если он лежит не там
if [ -f "/var/lib/samba/private/smb.conf" ]; then
    cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
fi

# Kerberos
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# Запуск служб
systemctl enable smb nmb winbind
systemctl start smb nmb winbind
status $? "Службы Samba запущены"

# ==========================================
# 4. Пользователи и Права
# ==========================================
print_header "4. Создание пользователей и групп"

# Группа HQ
samba-tool group add hq 2>/dev/null
status $? "Группа hq создана (или уже существует)"

# 5 пользователей
for i in {1..5}; do
    USERNAME="user${i}.hq"
    PASS="P@ssw0rd${i}"
    samba-tool user create "$USERNAME" "$PASS" 2>/dev/null
    samba-tool group addmembers hq "$USERNAME" 2>/dev/null
    echo "Пользователь $USERNAME добавлен"
done

# Импорт из CSV
CSV="/opt/users.csv"
if [ -f "$CSV" ]; then
    echo "Обработка файла $CSV..."
    while IFS=',' read -r user pass; do
        [ -z "$user" ] && continue
        samba-tool user create "$user" "$pass" 2>/dev/null && echo "Создан: $user" || echo "Существует: $user"
    done < "$CSV"
fi

# Настройка SUDO
echo "Настройка sudo для группы hq..."
SUDO_FILE="/etc/sudoers.d/hq-permissions"
cat <<EOF > $SUDO_FILE
Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id
%hq ALL=(ALL) HQ_CMDS
EOF
chmod 440 $SUDO_FILE
status 0 "SUDO настроен"

print_header "Настройка завершена!"
echo "Домен: $REALM"
echo "Логин админа: Administrator"
echo "Пароль админа: P@ssw0rd"
