#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() { echo -e "${CYAN}================================================${NC}\n ${CYAN} $1${NC}\n${CYAN}================================================${NC}"; }
status() { if [ $1 -eq 0 ]; then echo -e "[${GREEN}OK${NC}] $2"; else echo -e "[${RED}FAIL${NC}] $2"; [ "$3" == "critical" ] && exit 1; fi; }

[ "$EUID" -ne 0 ] && echo "Run as root" && exit 1

print_header "1. Install"
apt-get update && apt-get install -y samba samba-dc samba-client acl
status $? "Packages" "critical"

print_header "2. Clean"
systemctl stop smb nmb winbind 2>/dev/null
killall -9 smbd nmbd winbindd 2>/dev/null
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/* /var/lib/samba/sysvol/* /var/lib/samba/*.tdb /var/lib/samba/*.ldb
mkdir -p /var/lib/samba/private /var/lib/samba/sysvol
status 0 "Cleaned"

print_header "3. Provision"
read -p "Domain (e.g. au-team.irpo): " REALM_IN
read -p "Server IP: " IP

REALM=$(echo "$REALM_IN" | tr '[:lower:]' '[:upper:]')
DOM=$(echo "$REALM_IN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

samba-tool domain provision --realm="$REALM" --domain="$DOM" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass='P@ssw0rd' --use-rfc2307
status $? "Provision" "critical"

cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

print_header "4. Fix Config (Critical for ALT)"
# Добавляем пути в [global]
sed -i '/\[global\]/a \   lock directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   state directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   cache directory = /var/lib/samba' /etc/samba/smb.conf
sed -i '/\[global\]/a \   private dir = /var/lib/samba/private' /etc/samba/smb.conf

testparm -s 2>/dev/null
status $? "Config Check"

print_header "5. Start Services"
systemctl disable nmb winbind
systemctl enable smb
systemctl start smb
status $? "SMB Start"
sleep 3

print_header "6. Users"
samba-tool group add hq 2>/dev/null
for i in {1..5}; do samba-tool user create "user${i}.hq" "P@ssw0rd${i}" 2>/dev/null; samba-tool group addmembers hq "user${i}.hq" 2>/dev/null; done
[ -f /opt/users.csv ] && while IFS=',' read -r u p; do [ -z "$u" ] || samba-tool user create "$u" "$p" 2>/dev/null; done < /opt/users.csv

echo "Cmnd_Alias HQ_CMDS = /usr/bin/cat, /usr/bin/grep, /usr/bin/id" > /etc/sudoers.d/hq-permissions
echo "%hq ALL=(ALL) HQ_CMDS" >> /etc/sudoers.d/hq-permissions
chmod 440 /etc/sudoers.d/hq-permissions

print_header "DONE"
wbinfo -u
