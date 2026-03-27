#!/bin/bash

# ==========================================
# ФИНАЛЬНЫЙ СКРИПТ ДЛЯ ALT LINUX
# Используем службу 'samba' вместо 'smb' для DC
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() { echo -e "${CYAN}================================================${NC}\n ${CYAN} $1${NC}\n${CYAN}================================================${NC}"; }
status() { if [ $1 -eq 0 ]; then echo -e "[${GREEN}OK${NC}] $2"; else echo -e "[${RED}FAIL${NC}] $2"; [ "$3" == "critical" ] && exit 1; fi; }

[ "$EUID" -ne 0 ] && echo "Run as root" && exit 1

# 1. Установка
print_header "1. Install Packages"
apt-get update
apt-get install -y samba samba-dc samba-client samba-common acl
status $? "Packages installed" "critical"

# 2. Очистка
print_header "2. Cleaning Old Data"
systemctl stop smb nmb winbind samba 2>/dev/null
killall -9 smbd nmbd winbindd samba 2>/dev/null

rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
rm -f /var/lib/samba/*.tdb
rm -f /var/lib/samba/*.ldb
mkdir -p /var/lib/samba/private /var/lib/samba/sysvol
status 0 "Cleaned"

# 3. Создание домена
print_header "3. Domain Provisioning"
read -p "Enter Domain (e.g. au-team.irpo): " REALM_IN
read -p "Enter Server IP: " SRV_IP

REALM=$(echo "$REALM_IN" | tr '[:lower:]' '[:upper:]')
DOM=$(echo "$REALM_IN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

samba-tool domain provision --realm="$REALM" --domain="$DOM" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass='P@ssw0rd' --use-rfc2307
status $? "Provisioning" "critical"

# 4. Настройка конфигов
cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# Добавляем критически важные пути для ALT Linux
sed -i '/\[global\]/a \   lock directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   state directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   cache directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   private dir = /var/lib/samba/private' /etc/samba/smb.conf

testparm -s 2>/dev/null
status $? "Config valid"

# 5. Запуск службы (КЛЮЧЕВОЙ МОМЕНТ ДЛЯ ALT)
print_header "4. Starting Service"

# Отключаем лишние службы файлового сервера
systemctl disable smb nmb winbind 2>/dev/null

# Включаем и запускаем службу контроллера домена
systemctl enable samba
systemctl start samba

if [ $? -ne 0 ]; then
    status 1 "Service Samba FAILED to start"
    echo "Trying debug..."
    # Иногда samba-tool создает конфиг без шар, добавим их принудительно если надо
    echo -e "\n[netlogon]\npath = /var/lib/samba/sysvol/$REALM/scripts\nread only = No" >> /etc/samba/smb.conf
    echo -e "\n[sysvol]\npath = /var/lib/samba/sysvol\nread only = No" >> /etc/samba/smb.conf
    systemctl start samba
fi

status $? "Samba service started"
sleep 3

# 6. Проверка и пользователи
print_header "5. Users & Checks"
wbinfo -t
status $? "Domain trust check"

samba-tool group add hq 2>/dev/null
for i in {1..5}; do
    U="user${i}.hq"
    P="P@ssw0rd${i}"
    samba-tool user create "$U" "$P" 2>/dev/null
    samba-tool group addmembers hq "$U" 2>/dev/null
done
status 0 "Users created"

[ -f /opt/users.csv ] && while IFS=',' read -r u p; do [ -z "$u" ] || samba-tool user create "$u" "$p" 2>/dev/null; done < /opt/users.csv

# SUDO
echo "Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id" > /etc/sudoers.d/hq-permissions
echo "%hq ALL=(ALL) HQ_CMDS" >> /etc/sudoers.d/hq-permissions
chmod 440 /etc/sudoers.d/hq-permissions

print_header "FINISHED"
echo "Check users:"
wbinfo -u
