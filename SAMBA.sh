#!/bin/bash

# ==========================================
# Исправленный скрипт настройки Samba AD для ALT Linux
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
# 1. Установка ВСЕХ необходимых пакетов
# ==========================================
print_header "1. Установка пакетов Samba DC"

# Обновляем списки и ставим полный набор для контроллера домена
apt-get update
apt-get install -y samba samba-dc samba-client samba-common acl

# Проверяем, появилась ли команда samba-tool
if ! command -v samba-tool &> /dev/null; then
    echo -e "${RED}Ошибка: samba-tool не найден даже после установки. Проверьте репозитории.${NC}"
    exit 1
fi
status $? "Пакеты установлены, samba-tool доступен"

# ==========================================
# 2. Подготовка конфигурации
# ==========================================
print_header "2. Подготовка smb.conf"

# Запрос данных
read -p "Введите имя домена (например, HQ): " DOMAIN_INPUT
read -p "Введите IP-адрес этого сервера: " SERVER_IP

REALM=$(echo "$DOMAIN_INPUT" | tr '[:lower:]' '[:upper:]')
DOMAIN_SHORT=$(echo "$DOMAIN_INPUT" | tr '[:upper:]' '[:lower:]')

# Останавливаем службы перед изменениями
systemctl stop smb nmb winbind 2>/dev/null

# Удаляем старую базу данных (если была неудачная попытка), чтобы избежать конфликтов
rm -rf /var/lib/samba/private/* /var/lib/samba/sysvol/* /var/lib/samba/*.tdb /var/lib/samba/*.ldb 2>/dev/null

# Создаем каталоги, если их нет
mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/sysvol

# КРИТИЧЕСКИ ВАЖНО: Создаем минимальный smb.conf ПЕРЕД provisioning
# Без этого samba-tool provisioning не работает
cat <<EOF > /etc/samba/smb.conf
[global]
   workgroup = $DOMAIN_SHORT
   realm = $REALM
   netbios name = $(hostname -s | tr '[:lower:]' '[:upper:]')
   server role = active directory domain controller
   idmap_ldb:use rfc2307 = yes
   
   # Пути (стандартные для ALT Linux)
   private dir = /var/lib/samba/private
   lock directory = /var/lib/samba
   state directory = /var/lib/samba
   cache directory = /var/lib/samba
   
   log file = /var/log/samba/log.%m
   log level = 1
EOF

status $? "Создан временный smb.conf"

# ==========================================
# 3. Provisioning (Создание домена)
# ==========================================
print_header "3. Provisioning Active Directory"

echo "Создание базы данных домена..."
# Используем samba-tool с явным указанием конфига
samba-tool domain provision \
    --configfile=/etc/samba/smb.conf \
    --realm="$REALM" \
    --domain="$DOMAIN_SHORT" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssw0rd' \
    --use-rfc2307

if [ $? -eq 0 ]; then
    status 0 "Домен успешно создан!"
else
    status 1 "Ошибка при создании домена"
    exit 1
fi

# Копируем Kerberos конфиг
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
status $? "Kerberos конфиг скопирован"

# Запуск служб
systemctl enable smb nmb winbind
systemctl start smb nmb winbind
status $? "Службы запущены"

# ==========================================
# 4. Пользователи, Группы, SUDO, CSV
# ==========================================
print_header "4. Создание пользователей и прав"

# Создаем группу
samba-tool group add hq 2>/dev/null || echo "Группа hq уже есть"

# Создаем 5 пользователей
for i in {1..5}; do
    U="user${i}.hq"
    P="P@ssw0rd${i}"
    samba-tool user create "$U" "$P" 2>/dev/null || echo "Пользователь $U уже есть"
    samba-tool group addmembers hq "$U" 2>/dev/null
done

# Импорт из CSV
CSV="/opt/users.csv"
if [ -f "$CSV" ]; then
    echo "Импорт из $CSV..."
    while IFS=',' read -r u p; do
        [ -z "$u" ] && continue
        samba-tool user create "$u" "$p" 2>/dev/null && echo "Создан: $u" || echo "Существует: $u"
    done < "$CSV"
fi

# Настройка SUDO
echo "Настройка sudo..."
SUDO_F="/etc/sudoers.d/hq-permissions"
echo "Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id" > $SUDO_F
echo "%hq ALL=(ALL) HQ_CMDS" >> $SUDO_F
chmod 440 $SUDO_F

print_header "Готово!"
echo "Домен: $REALM"
echo "Admin: Administrator / P@ssw0rd"
