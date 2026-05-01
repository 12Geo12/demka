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

# Получение списка пользователей с оболочкой входа (не системных)
echo ""
echo "Доступные пользователи:"
echo "-----------------------"

# Получаем пользователей с реальной оболочкой (не /sbin/nologin, /bin/false и т.д.)
VALID_USERS=()
while IFS=: read -r username _ uid _ _ home shell; do
  # Пропускаем системных пользователей (uid < 1000) и пользователей без оболочки
  if [ "$uid" -ge 1000 ] && [[ "$shell" != *"nologin"* ]] && [[ "$shell" != *"false"* ]]; then
    VALID_USERS+=("$username")
    echo "${#VALID_USERS[@]}) $username (UID: $uid, Shell: $shell)"
  fi
done < /etc/passwd

# Если нет обычных пользователей, показываем всех с оболочкой
if [ ${#VALID_USERS[@]} -eq 0 ]; then
  echo "Обычные пользователи не найдены. Показываем всех с оболочкой:"
  while IFS=: read -r username _ uid _ _ home shell; do
    if [[ "$shell" != *"nologin"* ]] && [[ "$shell" != *"false"* ]] && [ -n "$shell" ]; then
      VALID_USERS+=("$username")
      echo "${#VALID_USERS[@]}) $username (UID: $uid, Shell: $shell)"
    fi
  done < /etc/passwd
fi

if [ ${#VALID_USERS[@]} -eq 0 ]; then
  echo "Ошибка: не найдено пользователей с оболочкой входа"
  exit 1
fi

echo ""
echo "-----------------------"

# Выбор пользователя
while true; do
  read -p "Выберите номер пользователя (1-${#VALID_USERS[@]}): " USER_CHOICE
  
  # Проверка что введено число
  if [[ "$USER_CHOICE" =~ ^[0-9]+$ ]]; then
    if [ "$USER_CHOICE" -ge 1 ] && [ "$USER_CHOICE" -le ${#VALID_USERS[@]} ]; then
      USER_ALLOWED="${VALID_USERS[$((USER_CHOICE-1))]}"
      echo "Выбран пользователь: $USER_ALLOWED"
      break
    else
      echo "Ошибка: введите число от 1 до ${#VALID_USERS[@]}"
    fi
  else
    echo "Ошибка: введите корректный номер"
  fi
done

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
echo "Пользователь: $USER_ALLOWED"
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
echo "Разрешенный пользователь: $USER_ALLOWED"
echo "Макс. попыток входа: $MAX_TRIES"
echo ""
echo "Для подключения используйте:"
echo "  ssh -p $PORT $USER_ALLOWED@<IP-адрес>"
echo ""
