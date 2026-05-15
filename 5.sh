#!/bin/bash

echo "=== Настройка безопасного SSH ==="

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от root"
  exit 1
fi

# Выбор типа устройства
echo ""
echo "Выберите тип устройства:"
echo "1 - Server (HQ-SRV / BR-SRV)"
echo "2 - Router (HQ-RTR / BR-RTR)"
read -p "Введите номер: " DEVICE

case $DEVICE in
    1)
        DEVICE_TYPE="Server"
        # Путь к конфигурации для Server (обычно Debian/Ubuntu/CentOS)
        if [ -f "/etc/ssh/sshd_config" ]; then
            CONFIG="/etc/ssh/sshd_config"
            BANNER="/etc/ssh/banner"
        elif [ -f "/etc/openssh/sshd_config" ]; then
            CONFIG="/etc/openssh/sshd_config"
            BANNER="/etc/openssh/banner"
        else
            echo "Ошибка: конфигурационный файл sshd не найден"
            exit 1
        fi
        SERVICE_NAME="sshd"
        ;;
    2)
        DEVICE_TYPE="Router"
        # Путь к конфигурации для Router (обычно AltLinux/RedOS)
        if [ -f "/etc/openssh/sshd_config" ]; then
            CONFIG="/etc/openssh/sshd_config"
            BANNER="/etc/openssh/banner"
        elif [ -f "/etc/ssh/sshd_config" ]; then
            CONFIG="/etc/ssh/sshd_config"
            BANNER="/etc/ssh/banner"
        else
            echo "Ошибка: конфигурационный файл sshd не найден"
            exit 1
        fi
        SERVICE_NAME="sshd"
        ;;
    *)
        echo "Неверный выбор устройства"
        exit 1
        ;;
esac

echo ""
echo "Выбрано устройство: $DEVICE_TYPE"
echo "Конфигурационный файл: $CONFIG"

# =============================================================================
# ИСПРАВЛЕНИЕ: Добавлена опция создания пользователя с любым UID
# =============================================================================
echo ""
echo "=========================================="
echo "Выберите действие:"
echo "1 - Выбрать существующего пользователя"
echo "2 - Создать нового пользователя sshuser"
echo "=========================================="
read -p "Ваш выбор [1]: " USER_ACTION
USER_ACTION=${USER_ACTION:-1}

case "$USER_ACTION" in
    2)
        # Создание нового пользователя
        echo ""
        read -p "Введите имя пользователя [sshuser]: " NEW_USERNAME
        NEW_USERNAME=${NEW_USERNAME:-sshuser}
        
        # Проверка существования пользователя
        if id "$NEW_USERNAME" &>/dev/null; then
            echo "Пользователь $NEW_USERNAME уже существует"
            USER_ALLOWED="$NEW_USERNAME"
        else
            # Запрос UID с возможностью указания системного UID
            echo ""
            echo "Введите UID для пользователя (1-65535):"
            echo "  - Обычные пользователи: 1000-65533"
            echo "  - Системные пользователи: 1-999"
            echo "  - Оставьте пустым для автоматического назначения"
            read -p "UID [авто]: " NEW_UID
            
            # Запрос пароля
            while true; do
                read -s -p "Введите пароль: " NEW_PASSWORD
                echo
                read -s -p "Повторите пароль: " NEW_PASSWORD_CONFIRM
                echo
                
                if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ] && [ -n "$NEW_PASSWORD" ]; then
                    break
                else
                    echo "Пароли не совпадают или пустые. Попробуйте снова."
                fi
            done
            
            # Создание пользователя
            echo ""
            echo "Создание пользователя $NEW_USERNAME..."
            
            if [ -z "$NEW_UID" ]; then
                # Автоматический UID
                useradd -m -s /bin/bash "$NEW_USERNAME"
            else
                # Проверка корректности UID
                if [[ "$NEW_UID" =~ ^[0-9]+$ ]] && [ "$NEW_UID" -ge 1 ] && [ "$NEW_UID" -le 65535 ]; then
                    # Проверка занятости UID
                    if getent passwd "$NEW_UID" >/dev/null; then
                        CURRENT_USER=$(getent passwd "$NEW_UID" | cut -d: -f1)
                        echo "Предупреждение: UID $NEW_UID занят пользователем $CURRENT_USER"
                        read -p "Продолжить с этим UID? (y/n): " FORCE_UID
                        if [[ "$FORCE_UID" =~ ^[Yy] ]]; then
                            useradd -m -u "$NEW_UID" -o -s /bin/bash "$NEW_USERNAME"
                        else
                            echo "Отмена операции"
                            exit 1
                        fi
                    else
                        useradd -m -u "$NEW_UID" -s /bin/bash "$NEW_USERNAME"
                    fi
                else
                    echo "Ошибка: Некорректный UID. Используйте число от 1 до 65535"
                    exit 1
                fi
            fi
            
            # Установка пароля
            echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
            
            if [ $? -eq 0 ]; then
                echo "Пользователь $NEW_USERNAME успешно создан (UID: $(id -u $NEW_USERNAME))"
            else
                echo "Ошибка при создании пользователя"
                exit 1
            fi
            
            USER_ALLOWED="$NEW_USERNAME"
        fi
        ;;
    *)
        # Выбор существующего пользователя
        echo ""
        echo "Доступные пользователи:"
        echo "-----------------------"
        
        # ИСПРАВЛЕНИЕ: Показываем ВСЕХ пользователей с оболочкой, включая системных
        # Разделяем на категории для наглядности
        VALID_USERS=()
        SYSTEM_USERS=()
        
        echo ""
        echo "=== Обычные пользователи (UID >= 1000) ==="
        idx=1
        while IFS=: read -r username _ uid _ _ home shell; do
            # Пропускаем пользователей без оболочки
            if [[ "$shell" != *"nologin"* ]] && [[ "$shell" != *"false"* ]] && [ -n "$shell" ]; then
                if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
                    VALID_USERS+=("$username")
                    echo "  $idx) $username (UID: $uid, Shell: $shell)"
                    idx=$((idx + 1))
                fi
            fi
        done < /etc/passwd
        
        echo ""
        echo "=== Системные пользователи (UID < 1000) с оболочкой ==="
        echo "  (может потребоваться для экзаменационных заданий)"
        while IFS=: read -r username _ uid _ _ home shell; do
            # Пропускаем пользователей без оболочки и root (он выше)
            if [[ "$shell" != *"nologin"* ]] && [[ "$shell" != *"false"* ]] && [ -n "$shell" ] && [ "$uid" -lt 1000 ] && [ "$uid" -ge 1 ]; then
                SYSTEM_USERS+=("$username")
                echo "  $idx) $username (UID: $uid, Shell: $shell) [СИСТЕМНЫЙ]"
                idx=$((idx + 1))
            fi
        done < /etc/passwd
        
        # Объединяем для выбора
        ALL_USERS=("${VALID_USERS[@]}" "${SYSTEM_USERS[@]}")
        TOTAL_USERS=${#ALL_USERS[@]}
        
        if [ $TOTAL_USERS -eq 0 ]; then
            echo "Ошибка: не найдено пользователей с оболочкой входа"
            exit 1
        fi
        
        echo ""
        echo "-----------------------"
        
        # Выбор пользователя
        while true; do
            read -p "Выберите номер пользователя (1-$TOTAL_USERS): " USER_CHOICE
            
            # Проверка что введено число
            if [[ "$USER_CHOICE" =~ ^[0-9]+$ ]]; then
                if [ "$USER_CHOICE" -ge 1 ] && [ "$USER_CHOICE" -le $TOTAL_USERS ]; then
                    USER_ALLOWED="${ALL_USERS[$((USER_CHOICE-1))]}"
                    echo "Выбран пользователь: $USER_ALLOWED"
                    break
                else
                    echo "Ошибка: введите число от 1 до $TOTAL_USERS"
                fi
            else
                echo "Ошибка: введите корректный номер"
            fi
        done
        ;;
esac

# Ввод порта
echo ""
while true; do
  read -p "Введите порт SSH (1-65535, по умолчанию 22): " PORT
  
  # Если пусто, используем 22
  if [ -z "$PORT" ]; then
    PORT="22"
    echo "Используется порт по умолчанию: $PORT"
    break
  fi
  
  # Проверка что введено число
  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
      echo "Будет использован порт: $PORT"
      break
    else
      echo "Ошибка: порт должен быть от 1 до 65535"
    fi
  else
    echo "Ошибка: введите корректный номер порта"
  fi
done

# Ввод количества попыток входа
echo ""
while true; do
  read -p "Введите макс. количество попыток входа (1-10, по умолчанию 2): " MAX_TRIES
  
  # Если пусто, используем 2
  if [ -z "$MAX_TRIES" ]; then
    MAX_TRIES="2"
    echo "Используется значение по умолчанию: $MAX_TRIES"
    break
  fi
  
  # Проверка что введено число
  if [[ "$MAX_TRIES" =~ ^[0-9]+$ ]]; then
    if [ "$MAX_TRIES" -ge 1 ] && [ "$MAX_TRIES" -le 10 ]; then
      echo "Будет установлено макс. попыток: $MAX_TRIES"
      break
    else
      echo "Ошибка: количество попыток должно быть от 1 до 10"
    fi
  else
    echo "Ошибка: введите корректное число"
  fi
done

# Подтверждение
echo ""
echo "=== Проверка настроек ==="
echo "Устройство: $DEVICE_TYPE"
echo "Пользователь: $USER_ALLOWED (UID: $(id -u $USER_ALLOWED 2>/dev/null || echo 'N/A'))"
echo "SSH порт: $PORT"
echo "Макс. попыток входа: $MAX_TRIES"
echo ""
read -p "Продолжить? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Отменено пользователем"
  exit 0
fi

# Резервная копия конфигурации
echo ""
echo "Создание резервной копии sshd_config"
cp $CONFIG ${CONFIG}.backup.$(date +%Y%m%d_%H%M%S)

# Функция изменения параметров
set_param () {
    PARAM=$1
    VALUE=$2

    if grep -q "^$PARAM" $CONFIG; then
        sed -i "s/^$PARAM.*/$PARAM $VALUE/" $CONFIG
    else
        echo "$PARAM $VALUE" >> $CONFIG
    fi
}

# Функция удаления/комментирования параметра
comment_param () {
    PARAM=$1
    if grep -q "^$PARAM" $CONFIG; then
        sed -i "s/^$PARAM/#$PARAM/" $CONFIG
    fi
}

echo "Настройка параметров SSH"

# Убираем старые настройки AllowUsers если есть
sed -i '/^AllowUsers/d' $CONFIG

set_param "Port" "$PORT"
set_param "AllowUsers" "$USER_ALLOWED"
set_param "MaxAuthTries" "$MAX_TRIES"
set_param "PasswordAuthentication" "yes"
set_param "Banner" "$BANNER"

echo "Создание баннера"
mkdir -p $(dirname $BANNER)
cat > $BANNER << 'EOF'

================================================================
                    ВНИМАНИЕ!
================================================================
  Несанкционированный доступ к данной системе запрещен.
  Все действия регистрируются и контролируются.
  
  Authorized access only. All activities are logged.
================================================================

EOF

# Проверка конфигурации
echo "Проверка конфигурации sshd"
sshd -t

if [ $? -ne 0 ]; then
  echo "Ошибка в конфигурации SSH. Восстановление из резервной копии..."
  # Восстанавливаем последнюю резервную копию
  LATEST_BACKUP=$(ls -t ${CONFIG}.backup.* 2>/dev/null | head -1)
  if [ -n "$LATEST_BACKUP" ]; then
    cp "$LATEST_BACKUP" $CONFIG
    echo "Конфигурация восстановлена из $LATEST_BACKUP"
  fi
  exit 1
fi

# Перезапуск службы
echo "Перезапуск SSH"

# Проверяем какая система управления службами используется
if command -v systemctl &> /dev/null; then
    systemctl restart $SERVICE_NAME
elif command -v service &> /dev/null; then
    service $SERVICE_NAME restart
else
    /etc/init.d/$SERVICE_NAME restart
fi

if [ $? -ne 0 ]; then
  echo "Ошибка при перезапуске SSH службы"
  exit 1
fi

echo ""
echo "=== Настройка завершена ==="
echo "Устройство: $DEVICE_TYPE"
echo "SSH порт: $PORT"
echo "Разрешенный пользователь: $USER_ALLOWED (UID: $(id -u $USER_ALLOWED))"
echo "Макс. попыток входа: $MAX_TRIES"
echo ""
echo "Для подключения используйте:"
echo "  ssh -p $PORT $USER_ALLOWED@<IP-адрес>"
echo ""
