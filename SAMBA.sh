#!/bin/bash

# ==========================================
# ПОЛНЫЙ СКРИПТ SAMBA AD ДЛЯ ALT LINUX
# - Исправлена служба запуска (samba вместо smb)
# - Исправлены пути для SUDO (/bin/cat вместо /usr/bin/cat)
# - Исправлен импорт CSV (игнорирует пробелы и пустые строки)
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
        # Если ошибка критическая, выходим
        if [ "$3" == "critical" ]; then
            echo -e "${RED}Установка прервана.${NC}"
            exit 1
        fi
    fi
}

# Проверка root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Запустите скрипт от имени root!${NC}"
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
# 2. Очистка старых данных
# ==========================================
print_header "2. Очистка старых данных"

# Останавливаем все возможные службы
systemctl stop smb nmb winbind samba 2>/dev/null
# Убиваем процессы, если висят
killall -9 smbd nmbd winbindd samba 2>/dev/null

# Удаляем старые конфиги и базы (для чистого запуска)
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
rm -f /var/lib/samba/*.tdb
rm -f /var/lib/samba/*.ldb

# Создаем нужные папки
mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/sysvol

status 0 "Очистка завершена"

# ==========================================
# 3. Создание домена (Provisioning)
# ==========================================
print_header "3. Создание домена"

echo -e "${YELLOW}Введите параметры домена:${NC}"
read -p "Полное имя домена (например, au-team.irpo): " REALM_INPUT
read -p "IP-адрес этого сервера: " SERVER_IP

# Формируем имена
REALM=$(echo "$REALM_INPUT" | tr '[:lower:]' '[:upper:]')
DOMAIN_SHORT=$(echo "$REALM_INPUT" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

echo -e "Realm: ${GREEN}$REALM${NC}"
echo -e "Domain: ${GREEN}$DOMAIN_SHORT${NC}"

# Запуск provisioning
samba-tool domain provision \
    --realm="$REALM" \
    --domain="$DOMAIN_SHORT" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssw0rd' \
    --use-rfc2307

if [ $? -ne 0 ]; then
    status 1 "Ошибка создания домена" "critical"
fi
status 0 "Домен успешно создан"

# Перенос конфигов
cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# КРИТИЧНО ДЛЯ ALT: Добавляем явные пути в smb.conf
sed -i '/\[global\]/a \   lock directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   state directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   cache directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   private dir = /var/lib/samba/private' /etc/samba/smb.conf

# Проверка синтаксиса
testparm -s 2>/dev/null
status $? "Проверка конфигурации testparm"

# ==========================================
# 4. Запуск службы Samba DC
# ==========================================
print_header "4. Запуск службы"

# В ALT Linux для DC используем службу 'samba', а не 'smb'
# Отключаем мешающие службы
systemctl disable smb nmb winbind 2>/dev/null
systemctl stop smb nmb winbind 2>/dev/null

# Включаем и запускаем samba
systemctl enable samba
systemctl start samba

if [ $? -eq 0 ]; then
    status 0 "Служба Samba (DC) запущена"
else
    status 1 "Не удалось запустить службу" "critical"
fi

# Даем время службе подняться
sleep 3

# ==========================================
# 5. Настройка пользователей и групп
# ==========================================
print_header "5. Пользователи и Группы"

# Создание группы hq
samba-tool group add hq 2>/dev/null
status 0 "Группа hq готова"

# Создание 5 пользователей user№.hq
for i in {1..5}; do
    USERNAME="user${i}.hq"
    PASSWORD="P@ssw0rd${i}"
    samba-tool user create "$USERNAME" "$PASSWORD" 2>/dev/null
    samba-tool group addmembers hq "$USERNAME" 2>/dev/null
done
status 0 "Пользователи user1-5.hq созданы и добавлены в группу hq"

# Импорт из CSV
CSV_FILE="/opt/users.csv"
if [ -f "$CSV_FILE" ]; then
    echo "Обработка файла $CSV_FILE..."
    # Цикл чтения CSV с обработкой пробелов и пустых строк
    while IFS=',' read -r raw_user raw_pass || [ -n "$raw_user" ]; do
        # Удаляем пробелы и символы возврата каретки
        USERNAME=$(echo "$raw_user" | tr -d '[:space:]')
        PASSWORD=$(echo "$raw_pass" | tr -d '[:space:]')
        
        # Если имя пользователя не пустое
        if [ -n "$USERNAME" ]; then
            samba-tool user create "$USERNAME" "$PASSWORD" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "[${GREEN}NEW${NC}] Создан: $USERNAME"
            else
                echo -e "[${YELLOW}SKIP${NC}] Уже есть: $USERNAME"
            fi
        fi
    done < "$CSV_FILE"
    status 0 "Импорт из CSV завершен"
else
    echo -e "${YELLOW}Файл /opt/users.csv не найден, импорт пропущен.${NC}"
fi

# ==========================================
# 6. Настройка SUDO
# ==========================================
print_header "6. Настройка привилегий SUDO"

# ИСПРАВЛЕНИЕ: Ищем реальные пути к командам (в ALT это /bin, а не /usr/bin)
CAT_CMD=$(which cat)
GREP_CMD=$(which grep)
ID_CMD=$(which id)

SUDO_FILE="/etc/sudoers.d/hq-permissions"

# Записываем правила
cat <<EOF > $SUDO_FILE
# Права для группы hq (Samba AD)
Cmnd_Alias HQ_CMDS = $CAT_CMD, $GREP_CMD, $ID_CMD

# Группа hq может выполнять эти команды
%hq ALL=(ALL) HQ_CMDS
EOF

# Права на файл
chmod 440 $SUDO_FILE

echo "Команды настроены: $CAT_CMD, $GREP_CMD, $ID_CMD"
status 0 "SUDO настроен"

# ==========================================
# Финальная проверка
# ==========================================
print_header "УСПЕШНО ЗАВЕРШЕНО"

echo -e "Домен: ${GREEN}$REALM${NC}"
echo -e "Администратор: ${GREEN}Administrator${NC}"
echo -e "Пароль: ${GREEN}P@ssw0rd${NC}"
echo ""
echo "Список пользователей домена:"
wbinfo -u

echo ""
echo "Для проверки введите: wbinfo -g"
