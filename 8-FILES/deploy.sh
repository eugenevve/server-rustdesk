#!/bin/bash

# Выход при любой ошибке (для безопасности)
set -e

echo "============================================"
echo "  СТАРТ ПЕРВИЧНОЙ НАСТРОЙКИ СЕРВЕРА UBUNTU  "
echo "============================================"

# Проверка наличия curl перед началом (необходим для Docker и API GitHub)
if ! command -v curl &> /dev/null; then
    echo "=== Установка curl для работы скрипта ==="
    sudo apt update && sudo apt install curl -y
fi

# ==============================================================================
# 0. ИНТЕРАКТИВНЫЙ СБОР ДАННЫХ С ПРОВЕРКОЙ
# ==============================================================================

# Проверка имени пользователя
while true; do
    read -p "Введите имя нового пользователя (только маленькие буквы и цифры): " NEW_USER

    if [[ "$NEW_USER" =~ ^[a-z0-9_-]+$ ]]; then
        break
    else
        echo "❌ Ошибка: Имя должно содержать ТОЛЬКО маленькие латинские буквы, цифры, дефис или подчеркивание! Без заглавных букв."
        echo "Попробуйте еще раз."
        echo "----------------------------------------"
    fi
done

# Безопасный ввод пароля (символы не будут видны при вводе)
read -s -p "Введите пароль для $NEW_USER: " USER_PASSWORD
echo ""
read -s -p "Повторите пароль: " USER_PASSWORD_CONFIRM
echo ""

if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
    echo "Ошибка: Пароли не совпадают!"
    exit 1
fi

# Ввод персонального SSH-ключа для входа в систему
read -p "Вставьте ваш публичный SSH-ключ (начинается с ssh-ed25519...): " SSH_PUBLIC_KEY
if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "Ошибка: SSH-ключ обязателен для отключения паролей!"
    exit 1
fi

# 1. Вопрос про файл подкачки (SWAP)
while true; do
    read -p "Включить файл подкачки SWAP на 1ГБ? (y/n): " CHOOSE_SWAP
    case $CHOOSE_SWAP in
        [Yy]* ) INTRODUCE_SWAP=true; break;;
        [Nn]* ) INTRODUCE_SWAP=false; break;;
        * ) echo "Пожалуйста, ответьте 'y' (да) или 'n' (нет).";;
    esac
done

# 2. Вопрос про установку Docker
while true; do
    read -p "Установить Docker на сервер? (y/n): " INSTALL_DOCKER_CHOICE
    case $INSTALL_DOCKER_CHOICE in
        [Yy]* ) INSTALL_DOCKER=true; break;;
        [Nn]* ) INSTALL_DOCKER=false; break;;
        * ) echo "Пожалуйста, ответьте 'y' (да) или 'n' (нет).";;
    esac
done

# 3. Вопрос про установку RustDesk (только если выбран Docker)
INSTALL_RUSTDESK=false
RUSTDESK_DOMAIN=""
RUSTDESK_VERSION=""

if [ "$INSTALL_DOCKER" = true ]; then
    while true; do
        read -p "Установить RustDesk Server в Docker? (y/n): " INSTALL_RUSTDESK_CHOICE
        case $INSTALL_RUSTDESK_CHOICE in
            [Yy]* ) INSTALL_RUSTDESK=true; break;;
            [Nn]* ) INSTALL_RUSTDESK=false; break;;
            * ) echo "Пожалуйста, ответьте 'y' (да) или 'n' (нет).";;
        esac
    done

    if [ "$INSTALL_RUSTDESK" = true ]; then
        while true; do
            read -p "Введите ваш домен для RustDesk (например, rustdesk.example.com): " RUSTDESK_DOMAIN
            if [[ "$RUSTDESK_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                break
            else
                echo "Ошибка: введите корректное доменное имя без http:// и без порта."
            fi
        done

        read -p "Введите версию RustDesk Server (например, 1.1.16). Enter - последняя стабильная: " USER_RUSTDESK_VERSION

        if [ -z "$USER_RUSTDESK_VERSION" ]; then
            echo "Определяем последнюю стабильную версию RustDesk Server с GitHub..."
            RUSTDESK_VERSION=$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

            if [ -z "$RUSTDESK_VERSION" ]; then
                echo "Ошибка: не удалось определить последнюю версию RustDesk."
                exit 1
            fi
        else
            RUSTDESK_VERSION="$USER_RUSTDESK_VERSION"
        fi

        # Убираем необязательную приставку v и проверяем формат версии.
        RUSTDESK_VERSION="${RUSTDESK_VERSION#v}"
        if [[ ! "$RUSTDESK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
            echo "Ошибка: некорректный формат версии RustDesk: $RUSTDESK_VERSION"
            exit 1
        fi

        echo "Будет установлена версия RustDesk Server: $RUSTDESK_VERSION"
    fi
fi

echo "=== Все данные получены. Начинаем настройку... ==="
sleep 2

# ==============================================================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ И СОЗДАНИЕ SWAP
# ==============================================================================
echo "=== Обновление пакетов системы ==="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" upgrade

if [ "$INTRODUCE_SWAP" = true ] ; then
    echo "=== Настройка файла подкачки SWAP на 1ГБ ==="
    
    # Отключение всех текущих файлов подкачки, для сброса системных настроек
    echo "Сбрасываем старые настройки подкачки..."
    sudo swapoff -a || true
    
    # Удаление старых файлов
    sudo rm -f /swapfile
    sudo sed -i '/swapfile/d' /etc/fstab

    # Создание 1ГБ с нуля
    echo "Выделяем 1ГБ под новый SWAP..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    
    # Выставление прав и активации
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    # Добавление в автозапуск при перезагрузке
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "Новый файл подкачки на 1ГБ успешно активирован!"
fi

# ==============================================================================
# 2. НАСТРОЙКА SSH СЛУЖБЫ
# ==============================================================================
echo "=== Проверка и установка OpenSSH ==="
if ! systemctl is-active --quiet ssh; then
    sudo apt install openssh-server -y
    sudo systemctl enable ssh
    sudo systemctl start ssh
fi

# ==============================================================================
# 3. НАСТРОЙКА БРАНДМАУЭРА (UFW)
# ==============================================================================
echo "=== Настройка брандмауэра UFW ==="
sudo ufw allow OpenSSH

# Открытие портов общего назначения и Xray протоколов
sudo ufw allow 80/tcp

# Порты RustDesk (без WebSocket-портов для веб-клиента)
if [ "$INSTALL_RUSTDESK" = true ]; then
    echo "=== Открытие портов RustDesk в UFW ==="
    sudo ufw allow 21114:21119/tcp
    sudo ufw allow 21116/udp
fi

# Включение UFW без интерактивного запроса (--force)
sudo ufw --force enable
sudo ufw status

# ==============================================================================
# 4. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ И НАСТРОЙКА ПРАВ
# ==============================================================================
echo "=== Создание пользователя $NEW_USER ==="
# Создание пользователя без дополнительных вопросов
sudo adduser --disabled-password --gecos "" "$NEW_USER"
# Установка пароль из переменной
echo "$NEW_USER:$USER_PASSWORD" | sudo chpasswd
# Добавление в группу sudo
sudo usermod -aG sudo "$NEW_USER"

# ==============================================================================
# 5. НАСТРОЙКА SSH-КЛЮЧЕЙ НА СЕРВЕРЕ
# ==============================================================================
echo "=== Настройка SSH-ключей ==="
USER_HOME="/home/$NEW_USER"
sudo mkdir -p "$USER_HOME/.ssh"

# Запись ключа напрямую в authorized_keys
echo "$SSH_PUBLIC_KEY" | sudo tee "$USER_HOME/.ssh/authorized_keys" > /dev/null

# Выставление прав
sudo chmod 700 "$USER_HOME/.ssh"
sudo chmod 600 "$USER_HOME/.ssh/authorized_keys"
sudo chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

# ==============================================================================
# 6. УСТАНОВКА DOCKER (ПО ИНСТРУКЦИИ)
# ==============================================================================
if [ "$INSTALL_DOCKER" = true ] ; then
    echo "=== Установка Docker ==="

    # Ожидание освобождения пакетного менеджера (если ОС занята фоновым обновлением)
    echo "Проверяем, не запущены ли другие процессы apt/dpkg..."
    while pgrep -x "apt" >/dev/null || pgrep -x "apt-get" >/dev/null || pgrep -x "dpkg" >/dev/null ; do
        echo "Обнаружен активный процесс пакетного менеджера. Ожидаем 5 секунд..."
        sleep 5
    done

    # Дополнительная пауза в 2 секунды, чтобы система успела полностью освободить дескрипторы файлов
    sleep 2

    # Скачивание и запуск официального скрипта
    curl -fsSL https://get.docker.com | sudo sh

    # Добавление пользователя в группу docker
    sudo usermod -aG docker "$NEW_USER"
    
    # Включение Docker и добавление в автозапуск
    sudo systemctl enable --now docker

    echo "Docker успешно установлен!"
else
    echo "=== Установка Docker пропущена по выбору пользователя ==="
fi

# ==============================================================================
# 7. РАЗВЕРТЫВАНИЕ RUSTDESK SERVER
# ==============================================================================
if [ "$INSTALL_RUSTDESK" = true ]; then
    echo "=== Развертывание RustDesk Server $RUSTDESK_VERSION ==="

    RUSTDESK_DIR="/home/$NEW_USER/rustdesk"
    RUSTDESK_IMAGE="ghcr.io/rustdesk/rustdesk-server:$RUSTDESK_VERSION"

    sudo mkdir -p "$RUSTDESK_DIR/data"
    sudo chown -R "$NEW_USER:$NEW_USER" "$RUSTDESK_DIR"

    sudo tee "$RUSTDESK_DIR/docker-compose.yml" > /dev/null <<EOF
services:
  hbbs:
    container_name: hbbs
    image: $RUSTDESK_IMAGE
    command: hbbs -r $RUSTDESK_DOMAIN:21117
    volumes:
      - ./data:/root
    network_mode: host
    restart: unless-stopped

  hbbr:
    container_name: hbbr
    image: $RUSTDESK_IMAGE
    command: hbbr
    volumes:
      - ./data:/root
    network_mode: host
    restart: unless-stopped
EOF

    sudo chown "$NEW_USER:$NEW_USER" "$RUSTDESK_DIR/docker-compose.yml"

    echo "Загружаем образ RustDesk..."
    cd "$RUSTDESK_DIR"
    if ! sudo docker compose pull; then
        echo "Ошибка: не удалось загрузить образ $RUSTDESK_IMAGE."
        echo "Проверьте версию RustDesk и доступность GitHub Container Registry."
        exit 1
    fi
    sudo docker compose up -d

    echo "Ожидаем генерации публичного ключа RustDesk..."
    RUSTDESK_PUBLIC_KEY=""
    for attempt in {1..30}; do
        if [ -s "$RUSTDESK_DIR/data/id_ed25519.pub" ]; then
            RUSTDESK_PUBLIC_KEY=$(sudo cat "$RUSTDESK_DIR/data/id_ed25519.pub" | tr -d '\r\n')
            if [ -n "$RUSTDESK_PUBLIC_KEY" ]; then
                break
            fi
        fi
        sleep 2
    done

    if [ -z "$RUSTDESK_PUBLIC_KEY" ]; then
        echo "Ошибка: публичный ключ RustDesk не появился за 60 секунд."
        echo "Проверьте логи командой: cd $RUSTDESK_DIR && sudo docker compose logs"
        exit 1
    fi

    # Сохраняем домен и публичный ключ в домашнюю папку пользователя.
    RUSTDESK_KEY_FILE="/home/$NEW_USER/rustdesk_server_key.txt"
    {
        echo "RustDesk Server"
        echo "Домен: $RUSTDESK_DOMAIN"
        echo "Версия: $RUSTDESK_VERSION"
        echo "Публичный ключ:"
        echo "$RUSTDESK_PUBLIC_KEY"
    } | sudo tee "$RUSTDESK_KEY_FILE" > /dev/null

    sudo chmod 600 "$RUSTDESK_KEY_FILE"
    sudo chown "$NEW_USER:$NEW_USER" "$RUSTDESK_KEY_FILE"

    echo
    echo "=========================================================="
    echo "             RUSTDESK УСПЕШНО УСТАНОВЛЕН!"
    echo "=========================================================="
    echo "Домен: $RUSTDESK_DOMAIN"
    echo "Версия: $RUSTDESK_VERSION"
    echo
    echo "Публичный ключ RustDesk:"
    echo -e "\033[1;32m$RUSTDESK_PUBLIC_KEY\033[0m"
    echo
    echo "Файл с данными для подключения:"
    echo "$RUSTDESK_KEY_FILE"
    echo
    echo "В клиенте RustDesk укажите:"
    echo "Сервер ID: $RUSTDESK_DOMAIN"
    echo "Key: публичный ключ выше"
    echo "=========================================================="
    echo

    sudo docker ps --filter "name=hbbs" --filter "name=hbbr"
fi


# ==============================================================================
# 8. НАСТРОЙКА ДАТЫ И ВРЕМЕНИ
# ==============================================================================
echo "=== Настройка часового пояса (Москва) ==="
sudo timedatectl set-timezone Europe/Moscow
timedatectl

# ==============================================================================
# 9. ОГРАНИЧЕНИЕ ЛОГИРОВАНИЯ (3 дня)
# ==============================================================================
echo "=== Ограничение логирования до 3 дней ==="
sudo journalctl --vacuum-time=3d

# Правка основной конфигурации journald
sudo sed -i 's/#MaxRetentionSec=/MaxRetentionSec=3day/g' /etc/systemd/journald.conf
# Раскомментирование параметра если ранее было что-то изменено
sudo sed -i 's/MaxRetentionSec=.*/MaxRetentionSec=3day/g' /etc/systemd/journald.conf

sudo systemctl restart systemd-journald

# ==============================================================================
# 10. НАСТРОЙКА ЕЖЕНЕДЕЛЬНОЙ ОЧИСТКИ DOCKER (CRON)
# ==============================================================================
if [ "$INSTALL_DOCKER" = true ] ; then
    echo "=== 4.1. Настройка еженедельной очистки Docker ==="
    
    CRON_CMD="0 0 * * 1 /usr/bin/docker system prune -af --volumes > /dev/null 2>&1"
    
    # Создание временного файла для безопасного редактирования
    TMP_CRON=$(mktemp)
    
    # Выгрузка текущих задач (если они есть), заглушая ошибку "no crontab"
    sudo crontab -l > "$TMP_CRON" 2>/dev/null || true
    
    # Проверка, нет ли уже такой задачи в файле
    if ! grep -Fq "$CRON_CMD" "$TMP_CRON"; then
        # Если задачи нет - дописывается с новой строки
        echo "$CRON_CMD" >> "$TMP_CRON"
        # Загрузка обновленного файла обратно в cron
        sudo crontab "$TMP_CRON"
        echo "Cron-задача на очистку Docker успешно добавлена!"
    else
        echo "Cron-задача уже была настроена ранее. Пропускаем."
    fi
    
    # Удаление временного файла
    rm -f "$TMP_CRON"
fi

# ==============================================================================
# 11. ОТКЛЮЧЕНИЕ ПАРОЛЕЙ И ROOT
# ==============================================================================
echo "=== Отключение root и входа по паролю ==="

# Изменение параметра в основном sshd_config
sudo sed -i 's/PermitRootLogin.*/PermitRootLogin no/g' /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication.*/PasswordAuthentication no/g' /etc/ssh/sshd_config

# Проверка наличия cloud-init конфигов, которые часто перебивают настройки на хостингах
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sudo sed -i 's/PasswordAuthentication.*/PasswordAuthentication no/g' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

# Перезапуск SSH для применения настроек
sudo systemctl restart ssh

echo "=========================================================="
echo " НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА! Сервер уходит в перезагрузку."
echo " Подключайтесь под пользователем: $NEW_USER по SSH-ключу."
echo "=========================================================="
sleep 5

sudo reboot
