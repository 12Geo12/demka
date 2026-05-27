#!/bin/bash

# ============================================
# Скрипт создания пользователей v1.5
# Исправленная версия
# ============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функции логирования
log_ok() {
    echo -e "${GREEN}[OK] $1${NC}"
}

log_err() {
    echo -e "${RED}[ERR] $1${NC}"
}

log_info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

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

# Читаем ввод с проверкой
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
# ШАГ 2: Выбор уровня привилегий sudo
# ============================================
echo ""
echo "Выберите уровень привилегий sudo:"
echo "0 - Без прав sudo (обычный пользователь)"
echo "1 - Sudo с запросом пароля (рекомендуется)"
echo "2 - Sudo без пароля (по умолчанию)"
echo "3 - Максимальные привилегии (без логирования)"

while true; do
    read -p "Введите номер [0-3] (по умолчанию 2): " SUDO_INPUT
    SUDO_LEVEL=${SUDO_INPUT:-2}
    
    if [[ "$SUDO_LEVEL" =~ ^[0-3]$ ]]; then
        break
    fi
    log_err "Неверный ввод. Введите число от 0 до 3"
done

log_info "Уровень привилегий: $SUDO_LEVEL"

# ============================================
# ШАГ 3: Ввод имени пользователя
# ============================================
echo ""
log_info "Создание нового пользователя"
echo ""

# Принудительный ввод имени с проверкой
while true; do
    read -p "Введите имя пользователя: " USERNAME_INPUT
    
    # Удаляем все пробелы и специальные символы
    USERNAME=$(echo "$USERNAME_INPUT" | tr -cd 'a-zA-Z0-9_-')
    
    # Проверяем что имя не пустое
    if [[ -z "$USERNAME" ]]; then
        log_err "Имя пользователя не может быть пустым!"
        continue
    fi
    
    # Проверяем длину
    if [[ ${#USERNAME} -lt 2 ]]; then
        log_err "Имя слишком короткое (минимум 2 символа)"
        continue
    fi
    
    # Проверяем формат
    if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_err "Имя должно содержать только буквы, цифры, _ и -"
        continue
    fi
    
    # Проверяем существует ли пользователь
    if id "$USERNAME" &>/dev/null; then
        log_err "Пользователь '$USERNAME' уже существует!"
        continue
    fi
    
    # Всё ОК
    break
done

log_info "Будет создан пользователь: $USERNAME"

# ============================================
# ШАГ 4: Ввод пароля
# ============================================
echo ""
while true; do
    read -sp "Введите пароль: " PASSWORD
    echo ""
    read -sp "Подтвердите пароль: " PASSWORD2
    echo ""
    
    if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
        log_err "Пароли не совпадают!"
        continue
    fi
    
    if [[ ${#PASSWORD} -lt 4 ]]; then
        log_err "Пароль слишком короткий (минимум 4 символа)"
        continue
    fi
    
    break
done

# ============================================
# ШАГ 5: Создание пользователя
# ============================================
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
echo -e "${CYAN}============================================${NC}"

log_info "Создание пользователя $USERNAME..."

# Создаем пользователя
if useradd -m -s /bin/bash "$USERNAME" 2>/dev/null; then
    log_ok "Пользователь создан"
else
    log_err "Ошибка при создании пользователя"
    exit 1
fi

# Устанавливаем пароль
if echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null; then
    log_ok "Пароль установлен"
else
    log_err "Ошибка при установке пароля"
    exit 1
fi

# ============================================
# ШАГ 6: Настройка sudo
# ============================================
echo ""
log_info "Настройка прав sudo..."

case $SUDO_LEVEL in
    0)
        log_info "Пользователь без прав sudo"
        ;;
    1)
        # Sudo с паролем
        if usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null; then
            log_ok "Добавлен в группу sudo (требуется пароль)"
        else
            log_err "Ошибка добавления в sudo"
        fi
        ;;
    2)
        # Sudo без пароля
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null
        
        # Создаем файл sudoers ПРАВИЛЬНО
        cat > "/etc/sudoers.d/$USERNAME" << EOF
# Sudo access for $USERNAME
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
        
        chmod 440 "/etc/sudoers.d/$USERNAME"
        
        if visudo -c -f "/etc/sudoers.d/$USERNAME" &>/dev/null; then
            log_ok "Sudo без пароля настроено"
        else
            log_err "Ошибка в синтаксисе sudoers"
            rm -f "/etc/sudoers.d/$USERNAME"
        fi
        ;;
    3)
        # Максимальные привилегии (без логирования)
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null
        
        # Создаем файл sudoers ПРАВИЛЬНО (отдельно Defaults)
        cat > "/etc/sudoers.d/$USERNAME" << EOF
# Sudo access for $USERNAME (no logging)
Defaults:$USERNAME !logfile
Defaults:$USERNAME !syslog
Defaults:$USERNAME !pam_login
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
        
        chmod 440 "/etc/sudoers.d/$USERNAME"
        
        if visudo -c -f "/etc/sudoers.d/$USERNAME" &>/dev/null; then
            log_ok "Максимальные привилегии настроены"
        else
            log_err "Ошибка в синтаксисе sudoers"
            rm -f "/etc/sudoers.d/$USERNAME"
        fi
        ;;
esac

# ============================================
# ШАГ 7: Дополнительные настройки
# ============================================
echo ""
log_info "Применение дополнительных настроек..."

# Для роутера добавляем в дополнительные группы
if [[ "$DEVICE" == "2" ]]; then
    usermod -aG netdev "$USERNAME" 2>/dev/null || true
    usermod -aG dialout "$USERNAME" 2>/dev/null || true
fi

# Копируем стандартный .bashrc
if [[ -f /etc/skel/.bashrc ]] && [[ ! -f "/home/$USERNAME/.bashrc" ]]; then
    cp /etc/skel/.bashrc "/home/$USERNAME/"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"
fi

log_ok "Дополнительные настройки применены"

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
    0) echo -e "${YELLOW}Права:${NC} Обычный пользователь" ;;
    1) echo -e "${YELLOW}Права:${NC} Sudo с паролем" ;;
    2) echo -e "${YELLOW}Права:${NC} Sudo без пароля" ;;
    3) echo -e "${YELLOW}Права:${NC} Максимальные (без логов)" ;;
esac

echo ""
log_ok "Пользователь $USERNAME успешно создан!"
echo ""

# Предложение протестировать
read -p "Протестировать вход? (y/n): " TEST
if [[ "$TEST" == "y" ]] || [[ "$TEST" == "Y" ]] || [[ "$TEST" == "д" ]] || [[ "$TEST" == "Д" ]]; then
    echo ""
    log_info "Тестирование..."
    su - "$USERNAME" -c "whoami && id"
fi

exit 0
