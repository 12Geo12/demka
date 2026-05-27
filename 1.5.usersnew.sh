#!/bin/bash

# ============================================
# Скрипт создания пользователей v1.5
# Полностью исправленная версия
# ============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функции
log_ok() { echo -e "${GREEN}[OK] $1${NC}"; }
log_err() { echo -e "${RED}[ERR] $1${NC}"; }
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }

# ============================================
# ШАГ 1: Выбор устройства
# ============================================
clear
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   НАСТРОЙКА ПОЛЬЗОВАТЕЛЕЙ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

echo -e "${CYAN}Выберите устройство:${NC}"
echo "1) Server"
echo "2) Router (Linux)"

while true; do
    read -p "Введите номер [1-2] (по умолчанию 2): " DEVICE_INPUT
    DEVICE=${DEVICE_INPUT:-2}
    if [[ "$DEVICE" =~ ^[1-2]$ ]]; then
        break
    fi
    log_err "Неверный ввод. Введите 1 или 2"
done

if [[ "$DEVICE" == "1" ]]; then
    DEVICE_NAME="Server"
else
    DEVICE_NAME="Router (Linux)"
fi

log_info "Выбрано устройство: $DEVICE_NAME"

# ============================================
# ШАГ 2: Выбор уровня sudo
# ============================================
echo ""
echo "Выберите уровень привилегий sudo:"
echo "0 - Без прав sudo"
echo "1 - Sudo с паролем"
echo "2 - Sudo без пароля (по умолчанию)"
echo "3 - Максимальные привилегии (без логов)"

while true; do
    read -p "Введите номер [0-3] (по умолчанию 2): " SUDO_INPUT
    SUDO_LEVEL=${SUDO_INPUT:-2}
    if [[ "$SUDO_LEVEL" =~ ^[0-3]$ ]]; then
        break
    fi
    log_err "Неверный ввод. Введите 0-3"
done

log_info "Уровень: $SUDO_LEVEL"

# ============================================
# ШАГ 3: Имя пользователя
# ============================================
echo ""
log_info "Создание пользователя"

while true; do
    read -p "Введите имя пользователя: " USERNAME_INPUT
    USERNAME=$(echo "$USERNAME_INPUT" | tr -cd 'a-zA-Z0-9_-')
    
    if [[ -z "$USERNAME" ]]; then
        log_err "Имя не может быть пустым"
        continue
    fi
    if [[ ${#USERNAME} -lt 2 ]]; then
        log_err "Имя слишком короткое (мин. 2 символа)"
        continue
    fi
    if id "$USERNAME" &>/dev/null; then
        log_err "Пользователь '$USERNAME' уже существует"
        continue
    fi
    break
done

log_info "Пользователь: $USERNAME"

# ============================================
# ШАГ 4: Пароль
# ============================================
while true; do
    read -sp "Введите пароль: " PASSWORD
    echo ""
    read -sp "Подтвердите пароль: " PASSWORD2
    echo ""
    
    if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
        log_err "Пароли не совпадают"
        continue
    fi
    if [[ ${#PASSWORD} -lt 4 ]]; then
        log_err "Пароль слишком короткий (мин. 4 символа)"
        continue
    fi
    break
done

# ============================================
# ШАГ 5: Создание пользователя
# ============================================
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   СОЗДАНИЕ${NC}"
echo -e "${CYAN}============================================${NC}"

if useradd -m -s /bin/bash "$USERNAME"; then
    log_ok "Пользователь создан"
else
    log_err "Ошибка создания пользователя"
    exit 1
fi

if echo "$USERNAME:$PASSWORD" | chpasswd; then
    log_ok "Пароль установлен"
else
    log_err "Ошибка установки пароля"
    exit 1
fi

# ============================================
# ШАГ 6: Настройка sudo (ИСПРАВЛЕНО!)
# ============================================
echo ""
log_info "Настройка sudo..."

case $SUDO_LEVEL in
    0)
        log_info "Без прав sudo"
        ;;
    1)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null
        log_ok "Добавлен в sudo (с паролем)"
        ;;
    2)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null
        
        SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        
        if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
            log_ok "Sudo без пароля настроено"
        else
            log_err "Ошибка sudoers"
            rm -f "$SUDOERS_FILE"
        fi
        ;;
    3)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null
        
        SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
        
        # Создаем через visudo для гарантии правильного синтаксиса
        {
            echo "Defaults:$USERNAME !logfile"
            echo "Defaults:$USERNAME !syslog"
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL"
        } > "$SUDOERS_FILE"
        
        chmod 440 "$SUDOERS_FILE"
        
        if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
            log_ok "Максимальные привилегии настроены"
        else
            log_err "Ошибка sudoers, пробую упрощенный вариант"
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
            chmod 440 "$SUDOERS_FILE"
            if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
                log_ok "Настроено (упрощенно)"
            else
                rm -f "$SUDOERS_FILE"
                log_err "Не удалось настроить sudo"
            fi
        fi
        ;;
esac

# ============================================
# ШАГ 7: Дополнительные настройки
# ============================================
echo ""
log_info "Дополнительные настройки..."

if [[ "$DEVICE" == "2" ]]; then
    usermod -aG netdev "$USERNAME" 2>/dev/null || true
    usermod -aG dialout "$USERNAME" 2>/dev/null || true
fi

log_ok "Настройки применены"

# ============================================
# ИТОГИ
# ============================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   ГОТОВО!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${CYAN}Пользователь:${NC} $USERNAME"
echo -e "${CYAN}Пароль:${NC} $PASSWORD"
echo -e "${CYAN}Устройство:${NC} $DEVICE_NAME"
echo ""

case $SUDO_LEVEL in
    0) echo -e "${YELLOW}Права:${NC} Без sudo" ;;
    1) echo -e "${YELLOW}Права:${NC} Sudo с паролем" ;;
    2) echo -e "${YELLOW}Права:${NC} Sudo без пароля" ;;
    3) echo -e "${YELLOW}Права:${NC} Максимальные" ;;
esac

echo ""
log_ok "Пользователь $USERNAME создан!"
echo ""

read -p "Протестировать вход? (y/n): " TEST
if [[ "$TEST" == "y" ]] || [[ "$TEST" == "Y" ]] || [[ "$TEST" == "д" ]]; then
    echo ""
    su - "$USERNAME" -c "whoami && id"
fi

exit 0
