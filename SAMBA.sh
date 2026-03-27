#!/bin/bash

# ==========================================
# Финальный исправленный скрипт настройки Samba AD
# Исправлена ошибка с Realm/NetBIOS именами
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

if ! command -v samba-tool &> /dev/null; then
    echo -e "${RED}samba-tool не найден. Проверьте установку пакетов.${NC}"
    exit 1
fi
status $? "Пакеты установлены"

# ==========================================
# 2. Подготовка конфигурации
# ==========================================
print_header "2. Подготовка smb.conf"

read -p "Введите полное имя домена (например, au-team.irpo): " REALM_INPUT
read -p "Введите IP-адрес этого сервера: " SERVER_IP

# --- ИСПРАВЛЕНИЕ ОШИБКИ ---
# Приводим Realm к верхнему регистру (AU-TEAM.IRPO)
REALM=$(echo "$REALM_INPUT" | tr '[:lower:]' '[:upper:]')
# Берем ТОЛЬКО ПЕРВУЮ часть до точки для короткого имени (AU)
# Было: DOMAIN_SHORT=$(echo "$REALM" | tr '[:upper:]' '[:lower:]') - это вызывало баг
DOMAIN_SHORT=$(echo "$REALM_INPUT" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

echo -e "Конфигурация:"
echo -e " Realm (Full): ${GREEN}$REALM${NC}"
echo -e " Domain (Short): ${GREEN}$DOMAIN_SHORT${NC}"
# --------------------------

systemctl stop smb nmb winbind 2>/dev/null

# Очистка старых данных (важно при повторном запуске!)
rm -rf /var/lib/samba/private/* /var/lib/samba/sysvol/* /var/lib/samba/*.tdb /var/lib/samba/*.ldb 2>/dev/null
mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/sysvol

# Создаем временный конфиг
cat <<EOF > /etc/samba/smb.conf
[global]
   workgroup = $DOMAIN_SHORT
   realm = $REALM
   netbios name = $(hostname -s | tr '[:lower:]' '[:upper:]')
   server role = active directory domain controller
   idmap_ldb:use rfc2307 = yes
   
   private dir = /var/lib/samba/private
   lock directory = /var/lib/samba
   state directory = /var/lib/samba
   cache directory = /var/lib/samba
   
   log file = /var/log/samba/log.%m
   log level = 1
EOF

status $? "Конфигурация подготовлена"

# ==========================================
# 3. Provisioning
# ==========================================
print_header "3. Создание домена (Provisioning)"

samba-tool domain provision \
    --configfile=/etc/samba/smb.conf \
    --realm="$REALM" \
    --domain="$DOMAIN_SHORT" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssw0rd' \
    --use-rfc2307

if [ $? -eq 0 ]; then
    status 0 "Домен успешно создан"
else
    status 1 "Ошибка создания домена" "critical"
fi

# Настройка Kerberos и запуск
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable smb nmb winbind
systemctl start smb nmb winbind
status $? "Службы запущены"

# ==========================================
# 4. Пользователи и SUDO
# ==========================================
print_header "4. Пользователи и права"

# Группа
samba-tool group add hq 2>/dev/null || echo "[SKIP] Группа hq уже есть"

# 5 пользователей
for i in {1..5}; do
    U="user${i}.hq"
    P="P@ssw0rd${i}"
    samba-tool user create "$U" "$P" 2>/dev/null || echo "[SKIP] $U уже есть"
    samba-tool group addmembers hq "$U" 2>/dev/null
done

# Импорт CSV
CSV="/opt/users.csv"
if [ -f "$CSV" ]; then
    echo "Импорт из CSV..."
    while IFS=',' read -r u p; do
        [ -z "$u" ] && continue
        samba-tool user create "$u" "$p" 2>/dev/null && echo "Создан: $u" || echo "Уже есть: $u"
    done < "$CSV"
fi

# SUDO
SUDO_F="/etc/sudoers.d/hq-permissions"
echo "Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id" > $SUDO_F
echo "%hq ALL=(ALL) HQ_CMDS" >> $SUDO_F
chmod 440 $SUDO_F

print_header "ЗАВЕРШЕНО"
echo "Домен: $REALM ($DOMAIN_SHORT)"
echo "Admin: Administrator / P@ssw0rd"
