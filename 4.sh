#!/bin/bash

# ==============================================================================
# Скрипт управления пользователями для Demo2026
# ИСПРАВЛЕНИЯ:
# - Улучшено создание файлов в /etc/sudoers.d/
# - Добавлена валидация синтаксиса sudoers
# - Добавлена обработка специальных UID (включая системные)
# - Добавлено резервное копирование
# ==============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Файл для хранения списка созданных пользователей
USERS_LOG="/var/log/created_users.log"
SUDOERS_DIR="/etc/sudoers.d"

# Функции вывода
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_er() { echo -e "${RED}[ERR]${NC} $1"; }
msg_in() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_wa() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ==============================================================================
# ФУНКЦИЯ СОЗДАНИЯ ПОЛЬЗОВАТЕЛЯ
# ==============================================================================
create_user () {
    USERNAME=$1
    PASSWORD=$2
    USER_UID=$3

    echo -e "${CYAN}Проверка пользователя $USERNAME...${NC}"

    if id "$USERNAME" &>/dev/null; then
        echo -e "${YELLOW}Пользователь уже существует${NC}"

        CURRENT_UID=$(id -u $USERNAME)

        if [ ! -z "$USER_UID" ] && [ "$CURRENT_UID" != "$USER_UID" ]; then
            echo -e "${YELLOW}UID отличается. Текущий: $CURRENT_UID Требуемый: $USER_UID${NC}"
        fi
    else
        echo -e "${GREEN}Создание пользователя...${NC}"

        # ИСПРАВЛЕНИЕ: Обработка системных UID
        if [ -z "$USER_UID" ]; then
            useradd -m -s /bin/bash "$USERNAME"
        else
            # Проверка UID
            if [[ "$USER_UID" =~ ^[0-9]+$ ]] && [ "$USER_UID" -ge 1 ] && [ "$USER_UID" -le 65535 ]; then
                # Проверка занятости UID
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

        # Записываем в лог созданных пользователей
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $USERNAME (UID: $(id -u $USERNAME))" >> "$USERS_LOG"
    fi

    # ИСПРАВЛЕНИЕ: Улучшенная настройка sudo
    setup_sudo "$USERNAME"

    echo -e "${GREEN}Пользователь $USERNAME готов${NC}"
}

# ==============================================================================
# ИСПРАВЛЕНИЕ: ФУНКЦИЯ НАСТРОЙКИ SUDO
# ==============================================================================
setup_sudo () {
    local USERNAME=$1
    local SUDOERS_FILE="$SUDOERS_DIR/$USERNAME"
    
    echo -e "${CYAN}Настройка sudo для $USERNAME...${NC}"
    
    # Проверяем существование директории sudoers.d
    if [ ! -d "$SUDOERS_DIR" ]; then
        mkdir -p "$SUDOERS_DIR"
        chmod 755 "$SUDOERS_DIR"
    fi
    
    # Создаем временный файл для проверки
    local TEMP_FILE=$(mktemp)
    
    # Определяем содержимое sudoers
    # Можно выбрать разные варианты:
    # 1. Полный доступ без пароля
    # 2. Полный доступ с паролем
    # 3. Выборочный доступ
    
    echo "#sudoers config for $USERNAME - created $(date)" > "$TEMP_FILE"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> "$TEMP_FILE"
    
    # Проверяем синтаксис с помощью visudo
    if visudo -c -f "$TEMP_FILE" >/dev/null 2>&1; then
        # Резервная копия существующего файла
        if [ -f "$SUDOERS_FILE" ]; then
            cp "$SUDOERS_FILE" "${SUDOERS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            msg_in "Резервная копия создана"
        fi
        
        # Копируем проверенный файл
        cp "$TEMP_FILE" "$SUDOERS_FILE"
        
        # Устанавливаем правильные права
        chmod 440 "$SUDOERS_FILE"
        chown root:root "$SUDOERS_FILE"
        
        # Проверяем итоговый файл
        if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
            msg_ok "Файл sudoers создан: $SUDOERS_FILE"
        else
            msg_er "Ошибка в синтаксисе sudoers!"
            rm -f "$SUDOERS_FILE"
            # Восстанавливаем из резервной копии
            LATEST_BACKUP=$(ls -t ${SUDOERS_FILE}.backup.* 2>/dev/null | head -1)
            if [ -n "$LATEST_BACKUP" ]; then
                cp "$LATEST_BACKUP" "$SUDOERS_FILE"
                msg_in "Восстановлено из резервной копии"
            fi
        fi
    else
        msg_er "Ошибка в синтаксисе sudoers! Файл не создан"
        visudo -c -f "$TEMP_FILE" 2>&1 | head -5
    fi
    
    rm -f "$TEMP_FILE"
    
    # Также добавляем в группу wheel/sudo для совместимости
    if getent group wheel >/dev/null; then
        usermod -aG wheel "$USERNAME" 2>/dev/null
        msg_in "Добавлен в группу wheel"
    elif getent group sudo >/dev/null; then
        usermod -aG sudo "$USERNAME" 2>/dev/null
        msg_in "Добавлен в группу sudo"
    fi
}

# ==============================================================================
# ФУНКЦИЯ ПОКАЗА СОЗДАННЫХ ПОЛЬЗОВАТЕЛЕЙ
# ==============================================================================
show_users() {
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${WHITE}     СПИСОК ПОЛЬЗОВАТЕЛЕЙ В СИСТЕМЕ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""

    # Показываем пользователей из лога
    if [ -f "$USERS_LOG" ]; then
        echo -e "${GREEN}--- Пользователи, созданные через этот скрипт ---${NC}"
        cat "$USERS_LOG"
        echo ""
    fi

    echo -e "${WHITE}--- Все пользователи с домашней директорией ---${NC}"
    # Показываем всех пользователей с домашней директорией и bash shell
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 ~ /bash$/ {print "Пользователь: " $1 " | UID: " $3 " | Домашняя директория: " $6}' /etc/passwd
    
    echo ""
    echo -e "${WHITE}--- Системные пользователи с оболочкой ---${NC}"
    awk -F: '$3 >= 1 && $3 < 1000 && $7 ~ /bash$/ {print "Пользователь: " $1 " | UID: " $3}' /etc/passwd
    
    echo ""
    echo -e "${WHITE}--- Пользователи в группе wheel/sudo ---${NC}"
    
    if getent group wheel >/dev/null; then
        echo -e "${GREEN}Группа wheel: $(getent group wheel | cut -d: -f4)${NC}"
    fi
    if getent group sudo >/dev/null; then
        echo -e "${GREEN}Группа sudo: $(getent group sudo | cut -d: -f4)${NC}"
    fi
    
    # Показываем файлы sudoers.d
    echo ""
    echo -e "${WHITE}--- Файлы в /etc/sudoers.d/ ---${NC}"
    if [ -d "$SUDOERS_DIR" ]; then
        for f in "$SUDOERS_DIR"/*; do
            if [ -f "$f" ]; then
                local fname=$(basename "$f")
                echo -e "  ${CYAN}$fname${NC}"
                cat "$f" | sed 's/^/    /'
            fi
        done
    else
        echo "  Директория не существует"
    fi
    
    echo ""
    echo -e "${CYAN}==========================================${NC}"
}

# ==============================================================================
# ФУНКЦИЯ УДАЛЕНИЯ ПОЛЬЗОВАТЕЛЯ
# ==============================================================================
delete_user() {
    local USERNAME=$1
    
    if ! id "$USERNAME" &>/dev/null; then
        msg_er "Пользователь $USERNAME не существует"
        return 1
    fi
    
    echo -e "${YELLOW}Удаление пользователя $USERNAME...${NC}"
    
    # Удаляем файл sudoers
    if [ -f "$SUDOERS_DIR/$USERNAME" ]; then
        rm -f "$SUDOERS_DIR/$USERNAME"
        msg_ok "Файл sudoers удален"
    fi
    
    # Удаляем пользователя
    userdel -r "$USERNAME" 2>/dev/null || userdel "$USERNAME"
    
    if [ $? -eq 0 ]; then
        msg_ok "Пользователь $USERNAME удален"
        # Обновляем лог
        if [ -f "$USERS_LOG" ]; then
            sed -i "/$USERNAME/d" "$USERS_LOG"
        fi
    else
        msg_er "Ошибка при удалении пользователя"
        return 1
    fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

echo -e "${CYAN}==========================================${NC}"
echo -e "${WHITE}     МЕНЮ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ${NC}"
echo -e "${CYAN}==========================================${NC}"
echo ""
echo "1 - Создать пользователей"
echo "2 - Показать список пользователей"
echo "3 - Удалить пользователя"
echo "4 - Проверить sudoers"
echo "5 - Выход"
echo ""
read -p "Выберите действие: " ACTION

case $ACTION in
    1)
        echo ""
        echo -e "${WHITE}Выберите тип устройства:${NC}"
        echo "1 - Server (HQ-SRV / BR-SRV)"
        echo "2 - Router (HQ-RTR / BR-RTR)"
        read -p "Введите номер: " DEVICE

        # Запрос количества пользователей
        echo ""
        read -p "Введите количество пользователей для создания: " USER_COUNT
        
        # Проверка корректности числа
        if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
            msg_er "Введите корректное число больше 0"
            exit 1
        fi

        # Цикл создания пользователей
        for ((i=1; i<=USER_COUNT; i++)); do
            echo ""
            echo -e "${CYAN}==========================================${NC}"
            echo -e "${WHITE}Создание пользователя #$i из $USER_COUNT${NC}"
            echo -e "${CYAN}==========================================${NC}"
            
            read -p "Введите имя пользователя: " INPUT_USERNAME
            
            # Проверка пустого имени
            if [ -z "$INPUT_USERNAME" ]; then
                msg_er "Имя пользователя не может быть пустым"
                ((i--))
                continue
            fi
            
            # Проверка существования
            if id "$INPUT_USERNAME" &>/dev/null; then
                msg_wa "Пользователь $INPUT_USERNAME уже существует"
                read -p "Настроить существующего пользователя? (y/n): " setup_existing
                if [[ ! "$setup_existing" =~ ^[Yy] ]]; then
                    ((i--))
                    continue
                fi
                INPUT_PASSWORD=""
            else
                while true; do
                    read -s -p "Введите пароль: " INPUT_PASSWORD
                    echo
                    
                    # Проверка пустого пароля
                    if [ -z "$INPUT_PASSWORD" ]; then
                        msg_er "Пароль не может быть пустым"
                        continue
                    fi
                    
                    read -s -p "Повторите пароль: " INPUT_PASSWORD_CONFIRM
                    echo
                    
                    if [ "$INPUT_PASSWORD" = "$INPUT_PASSWORD_CONFIRM" ]; then
                        break
                    else
                        msg_er "Пароли не совпадают!"
                    fi
                done
            fi
            
            # ИСПРАВЛЕНИЕ: Улучшенный запрос UID
            echo ""
            echo -e "${WHITE}Настройка UID:${NC}"
            echo "  - Оставьте пустым для автоматического назначения"
            echo "  - Обычные UID: 1000-65533"
            echo "  - Системные UID: 1-999 (например, 500)"
            read -p "Введите UID: " INPUT_UID

            case $DEVICE in
                1)
                    echo -e "${GREEN}Настройка Server...${NC}"
                    create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID"
                    ;;
                2)
                    echo -e "${GREEN}Настройка Router (Linux)...${NC}"
                    create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID"
                    ;;
                *)
                    msg_er "Неверный выбор устройства"
                    exit 1
                    ;;
            esac
        done
        
        echo ""
        msg_ok "Создание пользователей завершено!"
        echo "Всего обработано: $USER_COUNT пользователей"
        ;;

    2)
        show_users
        ;;

    3)
        # Удаление пользователя
        show_users
        echo ""
        read -p "Введите имя пользователя для удаления: " DEL_USERNAME
        
        if [ -z "$DEL_USERNAME" ]; then
            msg_er "Имя не указано"
            exit 1
        fi
        
        # Защита от удаления важных пользователей
        case "$DEL_USERNAME" in
            root|admin|administrator)
                msg_er "Нельзя удалить системного пользователя $DEL_USERNAME"
                exit 1
                ;;
        esac
        
        read -p "Подтвердите удаление $DEL_USERNAME? (y/n): " confirm_del
        if [[ "$confirm_del" =~ ^[Yy] ]]; then
            delete_user "$DEL_USERNAME"
        else
            echo "Отменено"
        fi
        ;;

    4)
        # Проверка sudoers
        echo ""
        echo -e "${CYAN}=== Проверка файлов sudoers ===${NC}"
        echo ""
        
        # Проверка основного файла
        echo -e "${WHITE}Проверка /etc/sudoers:${NC}"
        if visudo -c 2>&1 | grep -q "parsed OK"; then
            msg_ok "/etc/sudoers - синтаксис корректен"
        else
            msg_er "/etc/sudoers - обнаружены ошибки!"
            visudo -c 2>&1
        fi
        
        # Проверка файлов в sudoers.d
        echo ""
        if [ -d "$SUDOERS_DIR" ]; then
            echo -e "${WHITE}Проверка файлов в $SUDOERS_DIR:${NC}"
            for f in "$SUDOERS_DIR"/*; do
                if [ -f "$f" ]; then
                    local fname=$(basename "$f")
                    if visudo -c -f "$f" >/dev/null 2>&1; then
                        echo -e "  ${GREEN}✓${NC} $fname - OK"
                    else
                        echo -e "  ${RED}✗${NC} $fname - ОШИБКА"
                        visudo -c -f "$f" 2>&1 | head -3
                    fi
                fi
            done
        fi
        ;;

    5)
        echo "Выход..."
        exit 0
        ;;

    *)
        msg_er "Неверный выбор"
        exit 1
        ;;
esac

echo ""
msg_ok "Настройка завершена"
echo ""
