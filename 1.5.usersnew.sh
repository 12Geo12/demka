#!/bin/bash

# ============================================
# Скрипт создания пользователей v1.5
# ============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Логирование
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
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   НАСТРОЙКА ПОЛЬЗОВАТЕЛЕЙ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# Проверяем, задана ли DEVICE извне
if [[ -z "$DEVICE" ]]; then
    echo -e "${CYAN}Выберите устройство:${NC}"
    echo "1) Server"
    echo "2) Router (Linux)"
    read -p "Введите номер [1-2] (по умолчанию 2): " DEVICE_INPUT
    
    # Устанавливаем значение по умолчанию если пустое
    DEVICE=${DEVICE_INPUT:-2}
fi

# Проверяем корректность ввода
if [[ ! "$DEVICE" =~ ^[1-2]$ ]]; then
    log_err "Неверный выбор устройства (должно быть 1 или 2)"
    exit 1
fi

# Определяем имя устройства
if [[ "$DEVICE" == "1" ]]; then
    DEVICE_NAME="Server"
else
    DEVICE_NAME="Router"
fi

log_info "Выбрано устройство: $DEVICE_NAME"
echo ""

# ============================================
# ШАГ 2: Выбор уровня привилегий sudo
# ============================================
echo "Выберите уровень привилегий sudo:"
echo "0 - Без прав sudo (обычный пользователь)"
echo "1 - Sudo с запросом пароля (рекомендуется для безопасности)"
echo "2 - Sudo без пароля ⭐ (по умолчанию)"
echo "3 - Максимальные привилегии (без логирования, для скриптов)"
read -p "Введите номер [0-3] (по умолчанию 2): " SUDO_INPUT

# Устанавливаем значение по умолчанию
SUDO_LEVEL=${SUDO_INPUT:-2}

# Проверяем корректность
if [[ ! "$SUDO_LEVEL" =~ ^[0-3]$ ]]; then
    log_err "Неверный выбор уровня sudo (должно быть 0-3)"
    exit 1
fi

log_info "Выбран уровень привилегий: $SUDO_LEVEL"
echo ""

# ============================================
# ШАГ 3: Ввод имени пользователя
# ============================================
read -p "Введите имя пользователя: " USERNAME

if [[ -z "$USERNAME" ]]; then
    log_err "Имя пользователя не может быть пустым"
    exit 1
fi

# Проверяем, существует ли пользователь
if id "$USERNAME" &>/dev/null; then
    log_err "Пользователь $USERNAME уже существует"
    exit 1
fi

log_info "Создание пользователя: $USERNAME"
echo ""

# ============================================
# ШАГ 4: Ввод пароля
# ============================================
read -sp "Введите пароль для пользователя: " PASSWORD
echo ""
read -sp "Подтвердите пароль: " PASSWORD_CONFIRM
echo ""

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    log_err "Пароли не совпадают"
    exit 1
fi

if [[ ${#PASSWORD} -lt 4 ]]; then
    log_err "Пароль слишком короткий (минимум 4 символа)"
    exit 1
fi

# ============================================
# ШАГ 5: Создание пользователя
# ============================================
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
echo -e "${CYAN}============================================${NC}"

# Создаем пользователя
if useradd -m -s /bin/bash "$USERNAME"; then
    log_ok "Пользователь $USERNAME создан"
else
    log_err "Ошибка создания пользователя"
    exit 1
fi

# Устанавливаем пароль
echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null || echo "$USERNAME:$PASSWORD" | chpasswd
if [[ $? -eq 0 ]]; then
    log_ok "Пароль установлен"
else
    log_err "Ошибка установки пароля"
    exit 1
fi

# ============================================
# ШАГ 6: Настройка sudo
# ============================================
echo ""
log_info "Настройка прав sudo..."

case $SUDO_LEVEL in
    0)
        # Без sudo
        log_info "Пользователь без прав sudo"
        ;;
    1)
        # Sudo с паролем
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        if [[ $? -eq 0 ]]; then
            log_ok "Добавлен в группу sudo (с паролем)"
        fi
        ;;
    2)
        # Sudo без пароля
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        
        # Добавляем в sudoers без пароля
        if ! grep -q "$USERNAME" /etc/sudoers.d/* 2>/dev/null; then
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
            chmod 440 "/etc/sudoers.d/$USERNAME"
            log_ok "Добавлен в sudoers без пароля"
        fi
        ;;
    3)
        # Максимальные привилегии
        usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"
        
        # Добавляем в sudoers без пароля и без логов
        if ! grep -q "$USERNAME" /etc/sudoers.d/* 2>/dev/null; then
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL, !logfile" > "/etc/sudoers.d/$USERNAME"
            chmod 440 "/etc/sudoers.d/$USERNAME"
            log_ok "Добавлены максимальные привилегии"
        fi
        ;;
esac

# ============================================
# ШАГ 7: Дополнительные настройки
# ============================================
echo ""
log_info "Применение дополнительных настроек..."

# Добавляем в дополнительные группы (если нужно)
if [[ "$DEVICE" == "2" ]]; then
    # Для роутера добавляем в группу netdev
    usermod -aG netdev "$USERNAME" 2>/dev/null || true
fi

# Копируем .bashrc если есть
if [[ -f /etc/skel/.bashrc ]] && [[ ! -f /home/$USERNAME/.bashrc ]]; then
    cp /etc/skel/.bashrc /home/$USERNAME/
    chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc
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
echo -e "${CYAN}Уровень sudo:${NC} $SUDO_LEVEL"
echo ""

case $SUDO_LEVEL in
    0) echo -e "${YELLOW}Права:${NC} Обычный пользователь (без sudo)" ;;
    1) echo -e "${YELLOW}Права:${NC} Sudo с паролем" ;;
    2) echo -e "${YELLOW}Права:${NC} Sudo без пароля ⭐" ;;
    3) echo -e "${YELLOW}Права:${NC} Максимальные привилегии" ;;
esac

echo ""
log_ok "Пользователь $USERNAME успешно создан!"
echo ""

# Предложение протестировать
read -p "Хотите протестировать вход? (y/n): " TEST_LOGIN
if [[ "$TEST_LOGIN" == "y" ]] || [[ "$TEST_LOGIN" == "Y" ]] || [[ "$TEST_LOGIN" == "д" ]] || [[ "$TEST_LOGIN" == "Д" ]]; then
    echo ""
    log_info "Тестирование входа под пользователем $USERNAME..."
    su - "$USERNAME" -c "whoami && id"
fi

exit 0
