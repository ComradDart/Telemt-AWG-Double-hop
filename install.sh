#!/usr/bin/env bash
# ==============================================================================
#  vps_setup.sh — первичная настройка VPS:
#    1. Безопасность: новый пользователь, SSH hardening, ufw, fail2ban
#    2. AmneziaWG kernel module (PPA amnezia/ppa)
#    3. Панель wg-easy в Docker (официальный образ, режим AmneziaWG)
#    4. Nginx: сайт-заглушка на 80/443 + доступ к панели по секретному пути
#
#  Поддерживаемые ОС: Ubuntu 22.04 / 24.04, Debian 11 / 12
#  Запуск:  sudo bash vps_setup.sh
#  Лог:     /var/log/vps_setup.log
#
#  Скрипт идемпотентен: повторный запуск пропускает уже выполненные шаги
#  и переиспользует ранее сгенерированные секреты.
# ==============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Константы
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/vps_setup.log"
STATE_DIR="/var/lib/vps_setup"           # маркеры шагов и сохранённые ответы
ANSWERS_FILE="$STATE_DIR/answers.env"    # ответы на вопросы (для повторных запусков)
SECRETS_FILE="$STATE_DIR/secrets.env"    # сгенерированные секреты
PANEL_INFO_FILE="/root/panel_path.txt"   # итоговая памятка для пользователя
CF_CREDS_FILE="/root/.secrets/cloudflare.ini"  # API-токен Cloudflare для DNS-01

WG_DIR="/opt/wg-easy"                    # docker-compose панели
WG_IMAGE="ghcr.io/wg-easy/wg-easy:15"
WG_UI_PORT="51821"                       # порт веб-интерфейса (только 127.0.0.1)

STUB_DIR="/var/www/stub"                 # сайт-заглушка
SSL_DIR="/etc/nginx/ssl"
NGINX_SITE="/etc/nginx/sites-available/vpn-panel"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-vps-setup.conf"

AMNEZIA_KEY_FPR="75C9DD72C799870E310542E24166F2C257290828"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Логирование: всё, что выводит скрипт, дублируется в $LOG_FILE.
# Функции log/warn/die добавляют временные метки.
# ------------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] [INFO ] $*"; }
skip() { echo "[$(ts)] [SKIP ] $*"; }
warn() { echo "[$(ts)] [WARN ] $*"; }
die()  { echo "[$(ts)] [ERROR] $*"; exit 1; }

trap 'echo "[$(ts)] [ERROR] Скрипт аварийно остановлен на строке $LINENO (команда: $BASH_COMMAND). Подробности: $LOG_FILE"' ERR

# ------------------------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------------------------

# Установить пакеты, только если они ещё не установлены
apt_install() {
    local missing=()
    local p
    for p in "$@"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        skip "Пакеты уже установлены: $*"
        return 0
    fi
    log "Устанавливаю пакеты: ${missing[*]}"
    apt-get install -y "${missing[@]}"
}

# Записать файл из stdin, только если содержимое изменилось.
# Возвращает 0, если файл записан (изменился), 1 — если уже актуален.
deploy_file() {
    local dest="$1" mode="${2:-644}" tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    mv "$tmp" "$dest"
    chmod "$mode" "$dest"
    return 0
}

# ------------------------------------------------------------------------------
# Проверки окружения
# ------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"

[[ -f /etc/os-release ]] || die "Не найден /etc/os-release — неподдерживаемая ОС"
. /etc/os-release
OS_ID="${ID:-}"
case "$OS_ID" in
    ubuntu|debian) ;;
    *) die "Поддерживаются только Ubuntu и Debian (обнаружено: ${PRETTY_NAME:-$OS_ID})" ;;
esac

log "=============================================================="
log "Запуск vps_setup.sh на ${PRETTY_NAME}"
log "=============================================================="

# ==============================================================================
# ШАГ 0. Вопросы пользователю
# ==============================================================================
# Ответы прошлого запуска используются как значения по умолчанию
if [[ -f "$ANSWERS_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
    log "Найдены ответы предыдущего запуска — они подставлены как значения по умолчанию"
fi

DEF_USER="${NEW_USER:-vpnadmin}"
DEF_PORT="${WG_PORT:-51820}"
DEF_HOST="${SERVER_HOST:-}"

echo ""
echo "================  НАСТРОЙКА  ================"

while true; do
    read -rp "Имя нового пользователя (вместо root) [${DEF_USER}]: " NEW_USER
    NEW_USER="${NEW_USER:-$DEF_USER}"
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    echo "  Некорректное имя. Допустимы строчные латинские буквы, цифры, '-' и '_'."
done

while true; do
    read -rp "Порт AmneziaWG (UDP) [${DEF_PORT}]: " WG_PORT
    WG_PORT="${WG_PORT:-$DEF_PORT}"
    [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) && break
    echo "  Некорректный порт. Введите число от 1 до 65535."
done

while true; do
    if [[ -n "$DEF_HOST" ]]; then
        read -rp "Публичный IP или домен сервера [${DEF_HOST}]: " SERVER_HOST
        SERVER_HOST="${SERVER_HOST:-$DEF_HOST}"
    else
        read -rp "Публичный IP или домен сервера: " SERVER_HOST
    fi
    [[ -n "$SERVER_HOST" ]] && break
    echo "  Значение не может быть пустым."
done

# --- Способ получения TLS-сертификата ---
echo ""
echo "TLS-сертификат для https://$SERVER_HOST/<секретный путь>:"
echo "  1) Самоподписанный — быстро, но браузер будет показывать предупреждение"
echo "  2) Let's Encrypt (HTTP-01) — нужен ДОМЕН с A-записью на этот сервер и открытый порт 80"
echo "  3) Let's Encrypt (Cloudflare DNS-01) — нужен API-токен Cloudflare; работает даже за оранжевым облаком CF"
DEF_CERT="${CERT_MODE:-1}"
while true; do
    read -rp "Вариант [1/2/3] [${DEF_CERT}]: " CERT_MODE
    CERT_MODE="${CERT_MODE:-$DEF_CERT}"
    case "$CERT_MODE" in 1|2|3) break ;; *) echo "  Введите 1, 2 или 3." ;; esac
done

LE_EMAIL="${LE_EMAIL:-}"
CF_TOKEN=""
if [[ "$CERT_MODE" == "2" || "$CERT_MODE" == "3" ]]; then
    if [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]]; then
        warn "Let's Encrypt не выдаёт сертификаты на IP-адрес ($SERVER_HOST). Переключаюсь на самоподписанный."
        CERT_MODE=1
    else
        DEF_EMAIL="${LE_EMAIL:-admin@$SERVER_HOST}"
        read -rp "E-mail для уведомлений Let's Encrypt [${DEF_EMAIL}]: " LE_EMAIL
        LE_EMAIL="${LE_EMAIL:-$DEF_EMAIL}"
    fi
fi

if [[ "$CERT_MODE" == "3" ]]; then
    if [[ -s "$CF_CREDS_FILE" ]]; then
        skip "API-токен Cloudflare уже сохранён ($CF_CREDS_FILE) — использую существующий"
    else
        echo "  Токен создаётся в Cloudflare: My Profile -> API Tokens -> шаблон \"Edit zone DNS\"."
        while true; do
            read -rsp "  API-токен Cloudflare (ввод скрыт): " CF_TOKEN; echo ""
            [[ -n "$CF_TOKEN" ]] && break
            echo "  Токен не может быть пустым."
        done
    fi
fi

deploy_file "$ANSWERS_FILE" 600 <<EOF >/dev/null || true
NEW_USER="$NEW_USER"
WG_PORT="$WG_PORT"
SERVER_HOST="$SERVER_HOST"
CERT_MODE="$CERT_MODE"
LE_EMAIL="$LE_EMAIL"
EOF

log "Параметры: пользователь=$NEW_USER, порт AmneziaWG=$WG_PORT/udp, адрес сервера=$SERVER_HOST, сертификат=режим$CERT_MODE"

# ==============================================================================
# ШАГ 1. Базовые пакеты
# ==============================================================================
log "--- Шаг 1: обновление списка пакетов и базовые утилиты ---"
apt-get update
apt_install curl ca-certificates gnupg openssl sudo ufw fail2ban

# ==============================================================================
# ШАГ 2. Новый пользователь вместо root
# ==============================================================================
log "--- Шаг 2: пользователь $NEW_USER ---"

if id -u "$NEW_USER" >/dev/null 2>&1; then
    skip "Пользователь $NEW_USER уже существует"
else
    log "Создаю пользователя $NEW_USER"
    useradd -m -s /bin/bash "$NEW_USER"
fi

if id -nG "$NEW_USER" | grep -qw sudo; then
    skip "Пользователь $NEW_USER уже в группе sudo"
else
    log "Добавляю $NEW_USER в группу sudo"
    usermod -aG sudo "$NEW_USER"
fi

# Переносим SSH-ключи root новому пользователю (если есть)
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
KEYS_PRESENT=0
if [[ -s "$USER_HOME/.ssh/authorized_keys" ]]; then
    KEYS_PRESENT=1
    skip "У $NEW_USER уже есть authorized_keys"
elif [[ -s /root/.ssh/authorized_keys ]]; then
    log "Копирую SSH-ключи root -> $NEW_USER"
    mkdir -p "$USER_HOME/.ssh"
    cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
    KEYS_PRESENT=1
else
    warn "SSH-ключи не найдены ни у root, ни у $NEW_USER — вход по паролю останется включён"
fi

# Пароль нужен в любом случае (для sudo). Спрашиваем, только если не задан.
PASS_STATUS=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' || true)
if [[ "$PASS_STATUS" == "P" ]]; then
    skip "Пароль для $NEW_USER уже задан"
else
    log "Задайте пароль для $NEW_USER (нужен для sudo и, при отсутствии ключей, для входа по SSH)"
    until passwd "$NEW_USER"; do
        warn "Пароль не принят, попробуйте ещё раз"
    done
fi

# ==============================================================================
# ШАГ 3. SSH hardening
# ==============================================================================
log "--- Шаг 3: усиление настроек SSH ---"

# Текущий порт SSH (на случай нестандартного) — нужен для ufw и fail2ban
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
SSH_PORT="${SSH_PORT:-22}"
log "Текущий порт SSH: $SSH_PORT"

if (( KEYS_PRESENT )); then
    PASSWORD_AUTH="no"
else
    PASSWORD_AUTH="yes"
    warn "Вход по паролю НЕ отключён (нет SSH-ключей). Добавьте ключ и перезапустите скрипт."
fi

# Убеждаемся, что drop-in каталог подключён в основном конфиге
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    log "Добавляю Include sshd_config.d в /etc/ssh/sshd_config"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

SSH_CHANGED=0
if deploy_file "$SSHD_DROPIN" 600 <<EOF
# Создано vps_setup.sh — не редактируйте вручную, файл перезаписывается
PermitRootLogin no
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
then
    SSH_CHANGED=1
fi

if (( SSH_CHANGED )); then
    sshd -t || die "Ошибка в конфигурации SSH — изменения НЕ применены, проверьте $SSHD_DROPIN"
    # reload/restart не разрывает текущие SSH-сессии
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || systemctl restart ssh 2>/dev/null || systemctl restart sshd
    log "SSH перенастроен: root-вход запрещён, вход по паролю: $PASSWORD_AUTH"
    warn "НЕ ЗАКРЫВАЙТЕ текущую сессию! Сначала проверьте в новом окне: ssh ${NEW_USER}@${SERVER_HOST}"
else
    skip "Конфигурация SSH уже актуальна"
fi

# ==============================================================================
# ШАГ 4. Файрвол ufw
# ==============================================================================
log "--- Шаг 4: файрвол ufw ---"

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp"  >/dev/null && log "ufw: разрешён $SSH_PORT/tcp (SSH)"
ufw allow 80/tcp           >/dev/null && log "ufw: разрешён 80/tcp (HTTP)"
ufw allow 443/tcp          >/dev/null && log "ufw: разрешён 443/tcp (HTTPS)"
ufw allow "$WG_PORT/udp"   >/dev/null && log "ufw: разрешён $WG_PORT/udp (AmneziaWG)"

if ufw status | grep -q "Status: active"; then
    skip "ufw уже активен"
else
    log "Включаю ufw"
    ufw --force enable
fi

# ==============================================================================
# ШАГ 5. fail2ban
# ==============================================================================
log "--- Шаг 5: fail2ban ---"

# backend=systemd работает и на Debian, и на Ubuntu (auth.log может отсутствовать)
apt_install python3-systemd

F2B_CHANGED=0
if deploy_file /etc/fail2ban/jail.local 644 <<EOF
# Создано vps_setup.sh
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
EOF
then
    F2B_CHANGED=1
fi

systemctl enable fail2ban >/dev/null 2>&1
if (( F2B_CHANGED )) || ! systemctl is-active --quiet fail2ban; then
    log "Перезапускаю fail2ban"
    systemctl restart fail2ban
else
    skip "fail2ban уже настроен и запущен"
fi

# ==============================================================================
# ШАГ 6. Модуль ядра AmneziaWG
# ==============================================================================
log "--- Шаг 6: модуль ядра AmneziaWG ---"

if modinfo amneziawg >/dev/null 2>&1; then
    skip "Модуль amneziawg уже установлен"
else
    log "Включаю deb-src репозитории (нужны для сборки модуля)"
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i -E 's/^#\s*(deb-src\s)/\1/' /etc/apt/sources.list
    fi
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.sources; do
        sed -i 's/^Types: deb$/Types: deb deb-src/' "$f"
    done
    shopt -u nullglob

    log "Устанавливаю заголовки ядра"
    if ! apt_install "linux-headers-$(uname -r)"; then
        warn "Пакет linux-headers-$(uname -r) недоступен, пробую generic-вариант"
        if [[ "$OS_ID" == "ubuntu" ]]; then
            apt_install linux-headers-generic
        else
            apt_install linux-headers-amd64
        fi
    fi

    # Подключаем PPA amnezia/ppa
    if ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi amnezia; then
        skip "Репозиторий Amnezia уже подключён"
    elif [[ "$OS_ID" == "ubuntu" ]]; then
        log "Подключаю PPA amnezia/ppa (Ubuntu)"
        apt_install software-properties-common python3-launchpadlib
        add-apt-repository -y ppa:amnezia/ppa
    else
        log "Подключаю PPA amnezia/ppa (Debian, вручную)"
        KEYRING=/usr/share/keyrings/amnezia-ppa.gpg
        if [[ ! -s "$KEYRING" ]]; then
            GPG_TMP=$(mktemp -d)
            gpg --homedir "$GPG_TMP" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$AMNEZIA_KEY_FPR"
            gpg --homedir "$GPG_TMP" --export "$AMNEZIA_KEY_FPR" > "$KEYRING"
            rm -rf "$GPG_TMP"
        fi
        cat > /etc/apt/sources.list.d/amnezia-ppa.list <<EOF
deb [signed-by=$KEYRING] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
deb-src [signed-by=$KEYRING] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF
    fi

    apt-get update
    log "Устанавливаю пакет amneziawg (сборка DKMS может занять пару минут)"
    apt-get install -y amneziawg
fi

if lsmod | grep -qw amneziawg; then
    skip "Модуль amneziawg уже загружен"
else
    log "Загружаю модуль amneziawg"
    modprobe amneziawg || die "Не удалось загрузить модуль amneziawg. Проверьте сборку DKMS: dkms status"
fi

# Автозагрузка модуля после перезагрузки
deploy_file /etc/modules-load.d/amneziawg.conf 644 <<EOF >/dev/null || true
amneziawg
EOF
log "Модуль amneziawg установлен и загружен"

# ==============================================================================
# ШАГ 7. Docker
# ==============================================================================
log "--- Шаг 7: Docker ---"

if command -v docker >/dev/null 2>&1; then
    skip "Docker уже установлен: $(docker --version)"
else
    log "Устанавливаю Docker (официальный скрипт get.docker.com)"
    curl -fsSL https://get.docker.com | sh
fi

# Некоторые хостеры ставят docker без compose-плагина — доустанавливаем
if docker compose version >/dev/null 2>&1; then
    skip "Плагин docker compose уже установлен"
else
    log "Доустанавливаю docker-compose-plugin"
    apt_install docker-compose-plugin
fi

systemctl enable --now docker >/dev/null 2>&1
log "Docker готов"

# ==============================================================================
# ШАГ 8. Секреты (путь панели, cookie-токен, пароль админа)
# ==============================================================================
log "--- Шаг 8: генерация секретов ---"

if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    skip "Использую секреты предыдущего запуска"
fi

PANEL_PATH="${PANEL_PATH:-$(openssl rand -hex 12)}"
COOKIE_TOKEN="${COOKIE_TOKEN:-$(openssl rand -hex 32)}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)}"

deploy_file "$SECRETS_FILE" 600 <<EOF >/dev/null || true
PANEL_PATH="$PANEL_PATH"
COOKIE_TOKEN="$COOKIE_TOKEN"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
EOF
log "Секретный путь панели: /$PANEL_PATH"

# ==============================================================================
# ШАГ 9. Панель wg-easy (Docker, режим AmneziaWG)
# ==============================================================================
log "--- Шаг 9: панель wg-easy ---"

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

WG_CHANGED=0

# Переменные (включая пароль) держим в .env с правами 600
if deploy_file "$WG_DIR/.env" 600 <<EOF
WG_PORT=$WG_PORT
INIT_HOST=$SERVER_HOST
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
then
    WG_CHANGED=1
fi

# Compose-файл по официальной документации wg-easy v15:
#  - EXPERIMENTAL_AWG=true: поддержка AmneziaWG (модуль ядра определяется автоматически)
#  - INSECURE=true: TLS терминирует nginx, панель слушает http только на 127.0.0.1
#  - INIT_*: автоматическая первичная настройка (применяется только при ПЕРВОМ запуске)
if deploy_file "$WG_DIR/docker-compose.yml" 600 <<'EOF'
volumes:
  etc_wireguard:

services:
  wg-easy:
    environment:
      - INSECURE=true
      - EXPERIMENTAL_AWG=true
      - INIT_ENABLED=true
      - INIT_USERNAME=${ADMIN_USERNAME}
      - INIT_PASSWORD=${ADMIN_PASSWORD}
      - INIT_HOST=${INIT_HOST}
      - INIT_PORT=${WG_PORT}
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "127.0.0.1:51821:51821/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF
then
    WG_CHANGED=1
fi

WG_RUNNING=$(docker inspect -f '{{.State.Running}}' wg-easy 2>/dev/null || echo "false")
if [[ "$WG_RUNNING" == "true" ]] && (( WG_CHANGED == 0 )); then
    skip "Контейнер wg-easy уже запущен, конфигурация не менялась"
else
    log "Запускаю wg-easy (docker compose up -d)"
    (cd "$WG_DIR" && docker compose up -d)
fi

# Ждём, пока веб-интерфейс начнёт отвечать
log "Жду ответа панели на 127.0.0.1:$WG_UI_PORT ..."
PANEL_UP=0
for _ in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WG_UI_PORT/" || true)
    if [[ "$HTTP_CODE" != "000" ]]; then
        PANEL_UP=1
        break
    fi
    sleep 2
done
if (( PANEL_UP )); then
    log "Панель wg-easy отвечает (HTTP $HTTP_CODE)"
else
    warn "Панель не ответила за 60 секунд. Проверьте: docker logs wg-easy"
fi

# ==============================================================================
# ШАГ 10. Nginx: заглушка + reverse-proxy по секретному пути + TLS
# ==============================================================================
log "--- Шаг 10: nginx + TLS-сертификат ---"

apt_install nginx

NGINX_CHANGED=0

# IPv6-listen добавляем, только если IPv6 включён в системе
LISTEN6_80=""
LISTEN6_443=""
if [[ -f /proc/net/if_inet6 ]]; then
    LISTEN6_80="listen [::]:80 default_server;"
    LISTEN6_443="listen [::]:443 ssl default_server;"
fi

# Перезагрузка nginx с проверкой конфигурации
reload_nginx() {
    nginx -t || die "Ошибка в конфигурации nginx — проверьте $NGINX_SITE"
    systemctl enable nginx >/dev/null 2>&1
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

# Рендер конфигурации сайта. $1 — путь к сертификату, $2 — путь к ключу.
# Схема доступа к панели:
#   GET /<секретный_путь>  -> ставится HttpOnly-cookie + redirect на /
#   запросы с верной cookie -> proxy_pass на панель wg-easy (127.0.0.1:51821)
#   все остальные запросы   -> статическая заглушка
# (wg-easy — SPA с абсолютными путями /api, /_nuxt — поэтому cookie-схема,
#  а не проксирование подпути, которое сломало бы интерфейс панели)
render_nginx() {
    local crt="$1" key="$2" tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
# Создано vps_setup.sh — не редактируйте вручную, файл перезаписывается

map $cookie_sid $panel_granted {
    default 0;
    "@COOKIE_TOKEN@" 1;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    @LISTEN6_80@
    server_name _;
    server_tokens off;

    # Каталог для HTTP-01 проверки Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        root @STUB_DIR@;
        default_type "text/plain";
        try_files $uri =404;
    }

    # Секретный путь по HTTP перенаправляем на HTTPS
    location = /@PANEL_PATH@ {
        return 301 https://$host$request_uri;
    }

    location / {
        root @STUB_DIR@;
        index index.html;
        try_files $uri $uri/ =404;
    }
}

server {
    listen 443 ssl default_server;
    @LISTEN6_443@
    server_name _;
    server_tokens off;

    ssl_certificate     @SSL_CRT@;
    ssl_certificate_key @SSL_KEY@;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 32m;

    # Секретный путь: выдаём cookie доступа и отправляем на панель
    location = /@PANEL_PATH@ {
        add_header Set-Cookie "sid=@COOKIE_TOKEN@; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=43200";
        return 302 /;
    }

    location / {
        error_page 418 = @panel;
        if ($panel_granted) {
            return 418;
        }
        root @STUB_DIR@;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location @panel {
        proxy_pass http://127.0.0.1:@WG_UI_PORT@;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
    }
}
EOF
    sed -i \
        -e "s|@PANEL_PATH@|$PANEL_PATH|g" \
        -e "s|@COOKIE_TOKEN@|$COOKIE_TOKEN|g" \
        -e "s|@STUB_DIR@|$STUB_DIR|g" \
        -e "s|@SSL_CRT@|$crt|g" \
        -e "s|@SSL_KEY@|$key|g" \
        -e "s|@WG_UI_PORT@|$WG_UI_PORT|g" \
        -e "s|@LISTEN6_80@|$LISTEN6_80|g" \
        -e "s|@LISTEN6_443@|$LISTEN6_443|g" \
        "$tmp"
    if deploy_file "$NGINX_SITE" 644 < "$tmp"; then
        NGINX_CHANGED=1
    fi
    rm -f "$tmp"
}

# --- Сайт-заглушка ---
mkdir -p "$STUB_DIR"
if deploy_file "$STUB_DIR/index.html" 644 <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>
  body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
       display:flex;align-items:center;justify-content:center;min-height:100vh;
       background:#f5f6f8;color:#333}
  .card{text-align:center;padding:48px}
  h1{font-size:28px;font-weight:600;margin:0 0 12px}
  p{color:#777;margin:0}
</style>
</head>
<body>
<div class="card">
  <h1>This site is under construction</h1>
  <p>Please check back later.</p>
</div>
</body>
</html>
EOF
then
    NGINX_CHANGED=1
fi

# --- Самоподписанный сертификат (всегда — как fallback и для первого старта) ---
mkdir -p "$SSL_DIR"
if [[ -s "$SSL_DIR/selfsigned.crt" && -s "$SSL_DIR/selfsigned.key" ]]; then
    skip "Самоподписанный сертификат уже существует"
else
    log "Генерирую самоподписанный сертификат для $SERVER_HOST"
    if [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]]; then
        SAN="IP:$SERVER_HOST"
    else
        SAN="DNS:$SERVER_HOST"
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$SSL_DIR/selfsigned.key" -out "$SSL_DIR/selfsigned.crt" \
        -subj "/CN=$SERVER_HOST" -addext "subjectAltName=$SAN"
    chmod 600 "$SSL_DIR/selfsigned.key"
fi

# --- Выбор итогового сертификата ---
LE_LIVE="/etc/letsencrypt/live/$SERVER_HOST"
CERT_CRT="$SSL_DIR/selfsigned.crt"
CERT_KEY="$SSL_DIR/selfsigned.key"
CERT_DESC="самоподписанный (браузер покажет предупреждение)"

# Если сертификат Let's Encrypt уже выпущен — используем его сразу
if [[ "$CERT_MODE" != "1" && -s "$LE_LIVE/fullchain.pem" ]]; then
    CERT_CRT="$LE_LIVE/fullchain.pem"
    CERT_KEY="$LE_LIVE/privkey.pem"
    CERT_DESC="Let's Encrypt"
    skip "Сертификат Let's Encrypt для $SERVER_HOST уже выпущен"
fi

# Первый рендер + включение сайта (nginx должен работать для HTTP-01 webroot)
render_nginx "$CERT_CRT" "$CERT_KEY"
if [[ ! -L /etc/nginx/sites-enabled/vpn-panel ]]; then
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/vpn-panel
    NGINX_CHANGED=1
fi
if [[ -e /etc/nginx/sites-enabled/default ]]; then
    log "Отключаю дефолтный сайт nginx"
    rm -f /etc/nginx/sites-enabled/default
    NGINX_CHANGED=1
fi
if (( NGINX_CHANGED )); then
    reload_nginx
    log "Nginx настроен (сертификат: $CERT_DESC)"
else
    skip "Конфигурация nginx уже актуальна"
fi

# --- Выпуск сертификата Let's Encrypt, если запрошен и ещё не выпущен ---
if [[ "$CERT_MODE" != "1" && ! -s "$LE_LIVE/fullchain.pem" ]]; then
    # Хук перезагрузки nginx после каждого обновления сертификата
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    deploy_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 755 <<'EOF' >/dev/null || true
#!/bin/sh
systemctl reload nginx
EOF

    if [[ "$CERT_MODE" == "2" ]]; then
        log "Выпускаю сертификат Let's Encrypt (HTTP-01) для $SERVER_HOST"
        apt_install certbot
        if certbot certonly --webroot -w "$STUB_DIR" -d "$SERVER_HOST" \
            --non-interactive --agree-tos -m "$LE_EMAIL"; then
            log "Сертификат Let's Encrypt получен"
        else
            warn "Не удалось получить сертификат (HTTP-01). Проверьте, что домен указывает на сервер и порт 80 открыт. Остаюсь на самоподписанном."
        fi
    elif [[ "$CERT_MODE" == "3" ]]; then
        log "Выпускаю сертификат Let's Encrypt (Cloudflare DNS-01) для $SERVER_HOST"
        apt_install certbot python3-certbot-dns-cloudflare
        mkdir -p "$(dirname "$CF_CREDS_FILE")"
        chmod 700 "$(dirname "$CF_CREDS_FILE")"
        if [[ -n "$CF_TOKEN" ]]; then
            printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_CREDS_FILE"
            chmod 600 "$CF_CREDS_FILE"
        fi
        if certbot certonly --dns-cloudflare \
            --dns-cloudflare-credentials "$CF_CREDS_FILE" \
            --dns-cloudflare-propagation-seconds 30 -d "$SERVER_HOST" \
            --non-interactive --agree-tos -m "$LE_EMAIL"; then
            log "Сертификат Let's Encrypt получен"
        else
            warn "Не удалось получить сертификат (DNS-01). Проверьте API-токен Cloudflare и зону DNS. Остаюсь на самоподписанном."
        fi
    fi

    # Если сертификат появился — переключаем nginx на него
    if [[ -s "$LE_LIVE/fullchain.pem" ]]; then
        CERT_CRT="$LE_LIVE/fullchain.pem"
        CERT_KEY="$LE_LIVE/privkey.pem"
        CERT_DESC="Let's Encrypt"
        NGINX_CHANGED=0
        render_nginx "$CERT_CRT" "$CERT_KEY"
        reload_nginx
        log "Nginx переключён на сертификат Let's Encrypt (автопродление — systemd-таймер certbot)"
    fi
fi

# ==============================================================================
# ШАГ 11. Памятка и итоговый вывод
# ==============================================================================
log "--- Шаг 11: сохранение памятки ---"

deploy_file "$PANEL_INFO_FILE" 600 <<EOF >/dev/null || true
============================================================
 Доступ к панели управления AmneziaWG (wg-easy)
============================================================
 Секретный путь:  /$PANEL_PATH
 URL панели:      https://$SERVER_HOST/$PANEL_PATH
 Логин:           $ADMIN_USER
 Пароль:          $ADMIN_PASSWORD

 Порт AmneziaWG:  $WG_PORT/udp
 TLS-сертификат:  $CERT_DESC
 SSH-пользователь: $NEW_USER (root-вход по SSH отключён, порт $SSH_PORT/tcp)

 Как это работает: заход на секретный URL выдаёт браузеру
 cookie на 12 часов и открывает панель. Без cookie на любом
 пути отдаётся сайт-заглушка. Когда cookie истечёт — просто
 снова откройте секретный URL.

 Примечание: параметры INIT_* (логин/пароль/порт) применяются
 только при ПЕРВОМ запуске wg-easy. Если позже захотите сменить
 порт VPN — меняйте его в настройках самой панели (Admin Panel),
 а затем перезапустите скрипт, чтобы обновить ufw и docker.
============================================================
EOF
log "Памятка сохранена: $PANEL_INFO_FILE"

echo ""
echo "=============================================================="
echo "  НАСТРОЙКА ЗАВЕРШЕНА"
echo "=============================================================="
echo ""
echo "  Панель wg-easy:   https://$SERVER_HOST/$PANEL_PATH"
echo "  Логин:            $ADMIN_USER"
echo "  Пароль:           $ADMIN_PASSWORD"
echo "  TLS-сертификат:   $CERT_DESC"
echo "  Памятка:          $PANEL_INFO_FILE"
echo "  Лог установки:    $LOG_FILE"
echo ""
echo "  ВАЖНО:"
echo "  1. НЕ закрывайте эту SSH-сессию. Сначала откройте новое окно"
echo "     и проверьте вход:  ssh $NEW_USER@$SERVER_HOST"
echo "     Вход под root по SSH запрещён, но порт $SSH_PORT/tcp открыт."
if [[ "$CERT_DESC" == "Let's Encrypt" ]]; then
echo "  2. Сертификат Let's Encrypt выпущен и продлевается автоматически"
echo "     (systemd-таймер certbot, перезагрузка nginx через deploy-hook)."
else
echo "  2. Сертификат самоподписанный — браузер покажет предупреждение."
echo "     Перезапустите скрипт и выберите вариант 2 или 3, чтобы выпустить"
echo "     бесплатный сертификат Let's Encrypt."
fi
echo "  3. Панель работает в режиме AmneziaWG (модуль ядра установлен,"
echo "     wg-easy определяет его автоматически)."
echo ""
log "Скрипт успешно завершён"
