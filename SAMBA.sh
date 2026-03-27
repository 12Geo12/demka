#!/bin/bash

# ==========================================
# Скрипт настройки Samba AD для ALT Linux
# Автор: AI Assistant
# ==========================================

# Цветовые коды для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функция для красивого вывода заголовков
print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}================================================${NC}"
}

# Функция статуса
status() {
    if [ $1 -eq 0 ]; then
        echo -e "[${GREEN}OK${NC}] $2"
    else
        echo -e "[${RED}FAIL${NC}] $2"
        # Если критическая ошибка, выходим
        if [ "$3" == "critical" ]; then
            exit 1
        fi
    fi
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Пожалуйста, запустите этот скрипт от имени root (su -).${NC}"
    exit 1
fi

# ==========================================
# 1. Установка и настройка Samba (базовая)
# ==========================================
print_header "1. Установка Samba"

# Установка пакетов (классические имена в ALT)
apt-get update > /dev/null 2>&1
apt-get install -y samba samba-client samba-common samba-common-tools acl

status $? "Установка пакетов Samba завершена."

# Запрашиваем параметры домена интерактивно
echo -e "${YELLOW}Настройка домена. Введите параметры:${NC}"
read -p "Имя домена (например, HQ): " DOMAIN_INPUT
read -p "IP-адрес этого сервера (для DNS): " SERVER_IP

# Приводим к верхнему регистру и формируем имена
REALM=$(echo "$DOMAIN_INPUT" | tr '[:lower:]' '[:upper:]')
DOMAIN_SHORT=$(echo "$DOMAIN_INPUT" | tr '[:upper:]' '[:lower:]')

echo -e "Будет настроен домен: ${GREEN}$REALM${NC} ($DOMAIN_SHORT)"

# Проверяем, сконфигурирован ли уже домен
if testparm -s 2>/dev/null | grep -q "security = ADS"; then
    echo -e "${YELLOW}Домен уже сконфигурирован. Пропускаем provision.${NC}"
else
    print_header "1.1. Provisioning Active Directory"
    
    # Резервное копирование конфига
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

    # Интерактивный provision. 
    # В ALT Linux samba-tool provisioning interactive работает корректно.
    # Мы используем --use-rfc2307 для совместимости с UID/GID.
    echo "Запускаю samba-tool provisioning..."
    samba-tool domain provision --realm="$REALM" --domain="$DOMAIN_SHORT" --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307 --adminpass='P@ssw0rd'
    
    # В ALT Kerberos конфиг часто лежит отдельно, копируем
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    
    status $? "Создание домена завершено" "critical"
fi

# Запуск службы
print_header "1.2. Запуск служб"
systemctl enable smb nmb winbind
systemctl restart smb nmb winbind
status $? "Службы Samba запущены"

# ==========================================
# 2. Создание пользователей и групп HQ
# ==========================================
print_header "2. Создание группы и пользователей HQ"

# Создание группы hq
samba-tool group list | grep -q "^hq$" && echo -e "[${GREEN}OK${NC}] Группа hq уже существует" || {
    samba-tool group add hq
    status $? "Группа hq создана"
}

# Создание 5 пользователей формата user№.hq
for i in {1..5}; do
    USERNAME="user${i}.hq"
    PASS="P@ssw0rd${i}" # Стандартный пароль для скрипта
    
    # Проверяем существование
    if id "$USERNAME" &>/dev/null || samba-tool user list | grep -q "^$USERNAME$"; then
        echo -e "[${YELLOW}SKIP${NC}] Пользователь $USERNAME уже существует"
    else
        samba-tool user create "$USERNAME" "$PASS"
        status $? "Создан пользователь $USERNAME"
    fi
    
    # Добавление в группу hq
    samba-tool group addmembers hq "$USERNAME" 2>/dev/null
done

# ==========================================
# 3. Импорт пользователей из CSV
# ==========================================
print_header "3. Импорт пользователей из CSV"
CSV_FILE="/opt/users.csv"

if [ -f "$CSV_FILE" ]; then
    echo "Файл $CSV_FILE найден. Начинаю обработку..."
    
    # Чтение CSV (формат: user,pass)
    while IFS=',' read -r username password; do
        # Пропуск пустых строк
        [ -z "$username" ] && continue
        
        # Проверяем, существует ли пользователь
        if samba-tool user list | grep -q "^$username$"; then
            echo -e "[${YELLOW}EXISTS${NC}] Пользователь $username найден в базе."
            
            # Запрос действия для существующего
            read -p "Обновить пароль для $username? (y/n): " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                samba-tool user setpassword "$username" --newpassword="$password"
                status $? "Пароль обновлен для $username"
            else
                echo "Пропуск обновления пароля."
            fi
        else
            # Создание нового
            samba-tool user create "$username" "$password"
            status $? "Создан новый пользователь $username (из CSV)"
            
            # Если имя содержит .hq, добавляем в группу
            if [[ "$username" == *".hq" ]]; then
                samba-tool group addmembers hq "$username"
                status $? "$username добавлен в группу hq"
            fi
        fi
    done < "$CSV_FILE"
else
    echo -e "${RED}Файл $CSV_FILE не найден. Пропускаем импорт.${NC}"
fi

# ==========================================
# 4. Настройка SUDO для группы hq
# ==========================================
print_header "4. Настройка привилегий SUDO"

# В ALT Linux sudo настраивается через файлы в /etc/sudoers.d/
# Это позволяет выполнять команды: cat, grep, id без пароля (или с паролем пользователя)
SUDOERS_FILE="/etc/sudoers.d/hq-permissions"

echo "Настраиваю права sudo для группы hq..."

# Проверяем наличие группы hq в системе (POSIX группа)
# Для winbind нам нужно убедиться, что группа видна системе через NSS
# Обычно в ALT Linux winbind настраивается автоматически через /etc/nsswitch.conf

cat <<EOF > $SUDOERS_FILE
# Права для группы hq (Samba AD)
# Разрешены только команды: cat, grep, id

Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id

# Группа hq (через winbind часто выглядит как DOMAIN\hq или просто hq)
# Синтаксис %hq должен работать при корректной настройке NSS
%hq ALL=(ALL) HQ_CMDS
EOF

# Установка правильных прав на файл sudoers
chmod 440 $SUDOERS_FILE

status $? "Файл $SUDOERS_FILE создан"

# Проверка корректности синтаксиса sudoers
visudo -c > /dev/null 2>&1
status $? "Проверка синтаксиса sudoers" "critical"

# ==========================================
# Завершение
# ==========================================
print_header "Настройка завершена"
echo -e "Информация о домене:"
echo -e " Realm: ${GREEN}$REALM${NC}"
echo -e " Domain: ${GREEN}$DOMAIN_SHORT${NC}"
echo -e " Admin: ${GREEN}Administrator${NC}"
echo ""
echo -e "Для ввода машины HQ-CLI в домен выполните на ней:"
echo -e "${YELLOW}1. Укажите DNS сервер (IP этого сервера BR-SRV).${NC}"
echo -e "${YELLOW}2. system-auth write ad $REALM${NC}"
echo ""
echo -e "${GREEN}Скрипт завершил работу успешно.${NC}"
