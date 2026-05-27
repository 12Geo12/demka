#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функции логирования
log_ok() { echo -e "${GREEN}[OK] $1${NC}"; }
log_err() { echo -e "${RED}[ERR] $1${NC}"; }
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }

# ============================================
# ШАГ 1: Выбор устройства
# ============================================
echo -e "${CYAN}Выберите устройство:${NC}"
echo "1) Server"
echo "2) Router (Linux)"
read -p "Введите номер [1-2]: " DEVICE

# Проверка DEVICE
if [[ -z "$DEVICE" ]]; then
    DEVICE=2
fi

if [[ ! "$DEVICE" =~ ^[1-2]$ ]]; then
    log_err "Неверный выбор устройства"
    exit 1
fi

# ============================================
# ШАГ 2: Выбор уровня sudo
# ============================================
echo ""
echo "Выберите уровень привилегий sudo:"
echo "0 - Без прав sudo"
echo "1 - Sudo с паролем"
echo "2 - Sudo без пароля (по умолчанию)"
echo "3 - Максимальные привилегии"
read -p "Введите номер [0-3]: " SUDO_LEVEL

if [[ -z "$SUDO_LEVEL" ]]; then
    SUDO_LEVEL=2
fi

if [[ ! "$SUDO_LEVEL" =~ ^[0-3]$ ]]; then
    log_err "Неверный выбор уровня"
    exit 1
fi

# ============================================
# ШАГ 3: ИМЯ ПОЛЬЗОВАТЕЛЯ (ИСПРАВЛЕНО!)
# ============================================
echo ""
read -p "Введите имя пользователя: " USERNAME

# Очищаем от пробелов и запятых
USERNAME=$(echo "$USERNAME" | tr -d ' \t,;')

# Проверяем что не пустое
if [[ -z "$USERNAME" ]]; then
    log_err "Имя пользователя не может быть пустым!"
    exit 1
fi

# Проверяем формат
if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_err "Недопустимое имя (только буквы, цифры, _ и -)"
    exit 1
fi

# Проверяем существует ли
if id "$USERNAME" &>/dev/null; then
    log_err "Пользователь $USERNAME уже существует"
    exit 1
fi

log_info "Будет создан пользователь: $USERNAME"

# ============================================
# ШАГ 4: ПАРОЛЬ (ИСПРАВЛЕНО!)
# ============================================
read -sp "Введите пароль: " PASSWORD
echo ""
read -sp "Подтвердите пароль: " PASSWORD2
echo ""

if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
    log_err "Пароли не совпадают"
    exit 1
fi

if [[ ${#PASSWORD} -lt 4 ]]; then
    log_err "Пароль слишком короткий"
    exit 1
fi

# ============================================
# ШАГ 5: СОЗДАНИЕ
# ============================================
echo ""
log_info "Создание пользователя..."

if useradd -m -s /bin/bash "$USERNAME"; then
    log_ok "Пользователь создан"
else
    log_err "Ошибка создания пользователя"
    exit 1
fi

echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null
if [[ $? -eq 0 ]]; then
    log_ok "Пароль установлен"
else
    log_err "Ошибка установки пароля"
    exit 1
fi

# ============================================
# ШАГ 6: SUDO (ИСПРАВЛЕНО!)
# ============================================
log_info "Настройка sudo..."

case $SUDO_LEVEL in
    0)
        log_info "Без прав sudo"
        ;;
    1)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        log_ok "Добавлен в sudo (с паролем)"
        ;;
    2)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        cat > "/etc/sudoers.d/$USERNAME" << EOF
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
        chmod 440 "/etc/sudoers.d/$USERNAME"
        log_ok "Sudo без пароля настроено"
        ;;
    3)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        cat > "/etc/sudoers.d/$USERNAME" << EOF
Defaults:$USERNAME !logfile
Defaults:$USERNAME !syslog
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
        chmod 440 "/etc/sudoers.d/$USERNAME"
        log_ok "Максимальные привилегии настроены"
        ;;
esac

# Проверка
if visudo -c &>/dev/null; then
    log_ok "Синтаксис sudoers верный"
else
    log_err "Ошибка в sudoers!"
fi

# ============================================
# ИТОГИ
# ============================================
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}ГОТОВО!${NC}"
echo -e "${GREEN}================================${NC}"
echo "Пользователь: $USERNAME"
echo "Пароль: $PASSWORD"
echo ""

exit 0
