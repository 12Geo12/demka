#!/bin/bash

# Файл для хранения списка созданных пользователей
USERS_LOG="/var/log/created_users.log"

# Функция создания пользователя
create_user () {
    USERNAME=$1
    PASSWORD=$2
    USER_UID=$3

    echo "Проверка пользователя $USERNAME..."

    if id "$USERNAME" &>/dev/null; then
        echo "Пользователь уже существует"

        CURRENT_UID=$(id -u $USERNAME)

        if [ ! -z "$USER_UID" ] && [ "$CURRENT_UID" != "$USER_UID" ]; then
            echo "UID отличается. Текущий: $CURRENT_UID Требуемый: $USER_UID"
        fi
    else
        echo "Создание пользователя..."

        if [ -z "$USER_UID" ]; then
            useradd -m -s /bin/bash "$USERNAME"
        else
            useradd -m -u "$USER_UID" -s /bin/bash "$USERNAME"
        fi

        # Исправленная установка пароля (без sudo, используем printf для надёжности)
        printf "%s:%s" "$USERNAME" "$PASSWORD" | chpasswd

        if [ $? -eq 0 ]; then
            echo "Пароль успешно установлен"
        else
            echo "Ошибка при установке пароля!"
            return 1
        fi

        # Записываем в лог созданных пользователей
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $USERNAME (UID: $(id -u $USERNAME))" >> "$USERS_LOG"
    fi

    echo "Настройка sudo..."

    if getent group wheel >/dev/null; then
        usermod -aG wheel "$USERNAME"
    elif getent group sudo >/dev/null; then
        usermod -aG sudo "$USERNAME"
    fi

    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME
    chmod 440 /etc/sudoers.d/$USERNAME

    echo "Пользователь $USERNAME готов"
}

# Функция показа созданных пользователей
show_users() {
    echo ""
    echo "=========================================="
    echo "     СПИСОК ПОЛЬЗОВАТЕЛЕЙ В СИСТЕМЕ"
    echo "=========================================="
    echo ""

    # Показываем пользователей из лога
    if [ -f "$USERS_LOG" ]; then
        echo "--- Пользователи, созданные через этот скрипт ---"
        cat "$USERS_LOG"
        echo ""
    fi

    echo "--- Все пользователи с домашней директорией ---"
    # Показываем всех пользователей с домашней директорией и bash shell
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 ~ /bash$/ {print "Пользователь: " $1 " | UID: " $3 " | Домашняя директория: " $6}' /etc/passwd
    
    echo ""
    echo "--- Пользователи в группе wheel/sudo ---"
    
    if getent group wheel >/dev/null; then
        echo "Группа wheel: $(getent group wheel | cut -d: -f4)"
    fi
    if getent group sudo >/dev/null; then
        echo "Группа sudo: $(getent group sudo | cut -d: -f4)"
    fi
    
    echo ""
    echo "=========================================="
}

# Главное меню
echo "=========================================="
echo "     МЕНЮ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ"
echo "=========================================="
echo ""
echo "1 - Создать пользователей"
echo "2 - Показать список пользователей"
echo "3 - Выход"
echo ""
read -p "Выберите действие: " ACTION

case $ACTION in
    1)
        echo ""
        echo "Выберите тип устройства:"
        echo "1 - Server (HQ-SRV / BR-SRV)"
        echo "2 - Router (HQ-RTR / BR-RTR)"
        read -p "Введите номер: " DEVICE

        # Запрос количества пользователей
        echo ""
        read -p "Введите количество пользователей для создания: " USER_COUNT
        
        # Проверка корректности числа
        if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
            echo "Ошибка: введите корректное число больше 0"
            exit 1
        fi

        # Цикл создания пользователей
        for ((i=1; i<=USER_COUNT; i++)); do
            echo ""
            echo "=========================================="
            echo "Создание пользователя #$i из $USER_COUNT"
            echo "=========================================="
            
            read -p "Введите имя пользователя: " INPUT_USERNAME
            
            # Проверка пустого имени
            if [ -z "$INPUT_USERNAME" ]; then
                echo "Ошибка: имя пользователя не может быть пустым"
                ((i--))
                continue
            fi
            
            read -s -p "Введите пароль: " INPUT_PASSWORD
            echo
            
            # Проверка пустого пароля
            if [ -z "$INPUT_PASSWORD" ]; then
                echo "Ошибка: пароль не может быть пустым"
                ((i--))
                continue
            fi
            
            # Повтор пароля для подтверждения
            read -s -p "Повторите пароль: " INPUT_PASSWORD_CONFIRM
            echo
            
            if [ "$INPUT_PASSWORD" != "$INPUT_PASSWORD_CONFIRM" ]; then
                echo "Ошибка: пароли не совпадают!"
                ((i--))
                continue
            fi
            
            read -p "Введите идентификатор (UID, можно пропустить нажав Enter): " INPUT_UID

            case $DEVICE in
                1)
                    echo "Настройка Server..."
                    create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID"
                    ;;
                2)
                    echo "Настройка Router (Linux)..."
                    create_user "$INPUT_USERNAME" "$INPUT_PASSWORD" "$INPUT_UID"
                    ;;
                *)
                    echo "Неверный выбор устройства"
                    exit 1
                    ;;
            esac
        done
        
        echo ""
        echo "Создание пользователей завершено!"
        echo "Всего создано: $USER_COUNT пользователей"
        ;;

    2)
        show_users
        ;;

    3)
        echo "Выход..."
        exit 0
        ;;

    *)
        echo "Неверный выбор"
        exit 1
        ;;
esac

echo ""
echo "Настройка завершена"
