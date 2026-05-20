#!/bin/bash

# ==============================================================================
# Скрипт управления пользователями для Demo2026
# ДОБАВЛЕНО: Выбор уровня привилегий sudo при создании пользователя
# ==============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Файлы
USERS_LOG="/var/log/created_users.log"
SUDOERS_DIR="/etc/sudoers.d"

# Функции вывода
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ==============================================================================
# ИСПРАВЛЕННАЯ ФУНКЦИЯ НАСТРОЙКИ SUDO С ВЫБОРОМ ПРИВИЛЕГИЙ
# ==============================================================================
setup_sudo () {
    local USERNAME=$1
    local PRIVILEGE_LEVEL=${2:-2}  # По умолчанию: 2 = NOPASSWD
    local SUDOERS_FILE="$SUDOERS_DIR/$USERNAME"
    
    echo -e "${CYAN}Настройка sudo для $USERNAME (уровень: $PRIVILEGE_LEVEL)...${NC}"
    
    if [ ! -d "$SUDOERS_DIR" ]; then
        mkdir -p "$SUDOERS_DIR"
        chmod 755 "$SUDOERS_DIR"
    fi
    
    local TEMP_FILE=$(mktemp)
    echo "# sudoers config for $USERNAME - created $(date)" > "$TEMP_FILE"
    
    # Выбор конфигурации в зависимости от уровня привилегий
    case $PRIVILEGE_LEVEL in
        0)
            # Без прав sudo — только добавление в базовые группы
            echo "# $USERNAME — без привилегий sudo" >> "$TEMP_FILE"
            msg_in "Пользователь создан без прав sudo"
            ;;
        1)
            # Sudo с паролем
            echo "$USERNAME ALL=(ALL) ALL" >> "$TEMP_FILE"
            msg_in "Настроено: sudo с запросом пароля"
            ;;
        2)
            # Sudo без пароля (стандартный вариант)
            echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> "$TEMP_FILE"
            msg_in "Настроено: sudo без пароля (NOPASSWD)"
            ;;
        3)
            # Максимальные привилегии + отключение логирования (для автоматизации)
            echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> "$TEMP_FILE"
            echo "Defaults:$USERNAME !logfile" >> "$TEMP_FILE"
            echo "Defaults:$USERNAME !syslog" >> "$TEMP_FILE"
            msg_wa "Настроено: полный доступ без логирования (использовать с осторожностью!)"
            ;;
        *)
            # Защита от некорректного значения
            echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> "$TEMP_FILE"
            msg_wa "Неизвестный уровень, применён режим по умолчанию (NOPASSWD)"
            ;;
    esac
    
    # Применяем файл только если он содержит правила sudo
    if [ "$PRIVILEGE_LEVEL" -ne 0 ]; then
        if visudo -c -f "$TEMP_FILE" >/dev/null 2>&1; then
            [ -f "$SUDOERS_FILE" ] && cp "$SUDOERS_FILE" "${SUDOERS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$TEMP_FILE" "$SUDOERS_FILE"
            chmod 440 "$SUDOERS_FILE"
            chown root:root "$SUDOERS_FILE"
            
            if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
                msg_ok "Файл sudoers создан: $SUDOERS_FILE"
            else
                msg_er "Ошибка в синтаксисе после копирования!"
                rm -f "$SUDOERS_FILE"
            fi
        else
            msg_er "Ошибка синтаксиса sudoers!"
            visudo -c -f "$TEMP_FILE" 2>&1 | head -5
        fi
    fi
    
    rm -f "$TEMP_FILE"
    
    # Добавление в группу sudo/wheel для совместимости (кроме уровня 0)
    if [ "$PRIVILEGE_LEVEL" -ne 0 ]; then
        if getent group wheel >/dev/null; then
            usermod -aG wheel "$USERNAME" 2>/dev/null
            msg_in "Добавлен в группу wheel"
        elif getent group sudo >/dev/null; then
            usermod -aG sudo "$USERNAME" 2>/dev/null
            msg_in "Добавлен в группу sudo"
        fi
    fi
}

# ==============================================================================
# ФУНКЦИЯ СОЗДАНИЯ ПОЛЬЗОВАТЕЛЯ (обновлена)
# ==============================================================================
create_user () {
    USERNAME=$1
    PASSWORD=$2
    USER_UID=$3
    PRIVILEGE_LEVEL=${4:-2}  # Новый параметр: уровень привилегий
    
    echo -e "${CYAN}Проверка пользователя $USERNAME...${NC}"
    
    if id "$USERNAME" &>/dev/null; then
        echo -e "${YELLOW}Пользователь уже существует${NC}"
        CURRENT_UID=$(id -u $USERNAME)
        if [ ! -z "$USER_UID" ] && [ "$CURRENT_UID" != "$USER_UID" ]; then
            echo -e "${YELLOW}UID отличается. Текущий: $CURRENT_UID Требуемый: $USER_UID${NC}"
        fi
    else
        echo -e "${GREEN}Создание пользователя...${NC}"
        if [ -z "$USER_UID" ]; then
            useradd -m -s /bin/bash "$USERNAME"
        else
            if [[ "$USER_UID" =~ ^[0-9]+$ ]] && [ "$USER_UID" -ge 1 ] && [ "$USER_UID" -le 65535 ]; then
                if getent passwd "$USER_UID" >/dev/null; then
                    CURRENT_USER=$(getent passwd "$USER_UID" | cut -d: -f1)
                    msg_wa "UID $USER_UID занят пользователем $CURRENT_USER"
                    read -p "Создать с неуникальным UID? (y/n): " force_uid
                    if [[ "$force_uid" =~ ^[Yy] ]]; then
                        useradd -m -u "$USER_UID" -o -s /bin/bash "$USERNAME"
                    else
                        msg_er "Отмена создания пользователя"
                        return 1
                    fi
                else
                    useradd -m -u "$USER_UID" -s /bin/bash "$USERNAME"
                fi
            else
                msg_er "Некорректный UID: $USER_UID"
                useradd -m -s /bin/bash "$USERNAME"
            fi
        fi
        
        # Установка пароля
        printf "%s:%s" "$USERNAME" "$PASSWORD" | chpasswd
        if [ $? -eq 0 ]; then
            msg_ok "Пароль успешно установлен"
        else
            msg_er "Ошибка при установке пароля!"
            return 1
        fi
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $USERNAME (UID: $(id -u $USERNAME))" >> "$USERS_LOG"
    fi
    
    # Настройка sudo с выбранным уровнем привилегий
    setup_sudo "$USERNAME" "$PRIVILEGE_LEVEL"
    echo -e "${GREEN}Пользователь $USERNAME готов${NC}"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (фрагмент с добавлением выбора привилегий)
# ==============================================================================
# ... (внутри цикла создания пользователей, после ввода UID) ...

    # 🔹 НОВОЕ: Выбор уровня привилегий
    echo ""
    echo -e "${WHITE}Выберите уровень привилегий sudo:${NC}"
    echo " 0 — Без прав sudo (обычный пользователь)"
    echo " 1 — Sudo с запросом пароля (рекомендуется для безопасности)"
    echo " 2 — Sudo без пароля ⭐ (по умолчанию)"
    echo " 3 — Максимальные привилегии (без логирования, для скриптов)"
    read -p "Введите номер [0-3] (по умолчанию 2): " INPUT_PRIV
    
    # Валидация ввода
    if [[ ! "$INPUT_PRIV" =~ ^[0-3]$ ]]; then
        INPUT_PRIV=2  # Значение по умолчанию
        msg_in "Использован режим по умолчанию: Sudo без пароля"
    fi

    case $DEVICE in
        1)
            echo -e "${GREEN}Настройка Server...${NC}"
            create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID" "$INPUT_PRIV"
            ;;
        2)
            echo -e "${GREEN}Настройка Router (Linux)...${NC}"
            create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID" "$INPUT_PRIV"
            ;;
        *)
            msg_er "Неверный выбор устройства"
            exit 1
            ;;
    esac
