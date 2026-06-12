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

WG_DIR="/opt/wg-easy"                    # docker-compose стека (wg-easy + nginx [+ telemt])
WG_IMAGE="ghcr.io/wg-easy/wg-easy:15"
NGINX_IMAGE="nginx:stable"
WG_UI_PORT="51821"                       # порт веб-интерфейса панели (внутри docker-сети)

# Ассеты nginx на хосте (монтируются в контейнер). Слева — путь на ХОСТЕ,
# справа в комментарии — путь ВНУТРИ контейнера, который пишется в конфиг.
NGINX_DIR="$WG_DIR/nginx"
STUB_DIR="$NGINX_DIR/stub"               # в контейнере: /var/www/stub
SSL_DIR="$NGINX_DIR/ssl"                 # в контейнере: /etc/nginx/ssl
NGINX_CONF="$NGINX_DIR/conf.d/default.conf"  # в контейнере: /etc/nginx/conf.d/default.conf

# --- telemt (Telegram-выход на OUTBOUND; double-hop) ---
TELEMT_IMAGE="ghcr.io/telemt/telemt:latest"
TELEMT_DIR="$WG_DIR/telemt"              # конфиг telemt (монтируется ДИРЕКТОРИЕЙ)
TELEMT_API_PORT="9091"                   # API telemt (loopback в netns wg-easy)
TELEMT_PANEL_PORT="8080"                 # telemt_panel (в netns wg-easy)
TELEMT_PANEL_REPO="https://github.com/amirotin/telemt_panel"
TELEMT_PANEL_DIR="$WG_DIR/telemt-panel"  # исходники + config.toml панели telemt

# --- INBOUND (вход в РФ): AmneziaWG-клиент + HAProxy + nginx-легит-сайт ---
AWG_CONF_DIR="/etc/amnezia/amneziawg"    # каталог конфигов awg-quick
AWG_IFACE="awg0"
INB_DIR="/opt/inbound"                   # ассеты inbound (haproxy.cfg, nginx, сайт, ssl)
INB_STUB_DIR="$INB_DIR/site"
INB_SSL_DIR="$INB_DIR/ssl"
INB_SITE_TLS_PORT="8443"                 # nginx-TLS легит-сайта (за HAProxy)

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

# Развернуть статическую заглушку (index.html) в каталог $1.
# Возвращает 0, если файл изменился (как deploy_file).
deploy_stub() {
    local dir="$1"
    mkdir -p "$dir"
    deploy_file "$dir/index.html" 644 <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Northwind Studio — Digital Product Design</title>
<meta name="description" content="Northwind Studio is a small independent team designing and building thoughtful digital products.">
<style>
  :root{
    --bg:#0f1115; --panel:#161922; --ink:#eef1f6; --muted:#9aa3b2;
    --line:#262b36; --brand:#5b8def; --brand-2:#7c5cff;
  }
  *{box-sizing:border-box}
  html,body{margin:0;padding:0}
  body{
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    background:var(--bg); color:var(--ink); line-height:1.6;
    -webkit-font-smoothing:antialiased;
  }
  a{color:inherit;text-decoration:none}
  .wrap{max-width:1080px;margin:0 auto;padding:0 24px}
  header{
    display:flex;align-items:center;justify-content:space-between;
    padding:22px 0;border-bottom:1px solid var(--line);
  }
  .brand{display:flex;align-items:center;gap:12px;font-weight:650;letter-spacing:.2px}
  .brand svg{display:block}
  nav a{color:var(--muted);margin-left:26px;font-size:15px;transition:color .15s}
  nav a:hover{color:var(--ink)}
  .nav-cta{
    color:var(--ink)!important;border:1px solid var(--line);
    padding:8px 16px;border-radius:9px;
  }
  .nav-cta:hover{border-color:var(--brand)}
  .hero{padding:96px 0 80px;text-align:center}
  .eyebrow{
    display:inline-block;color:var(--brand);font-size:13px;font-weight:600;
    letter-spacing:1.4px;text-transform:uppercase;margin-bottom:18px;
  }
  .hero h1{
    font-size:52px;line-height:1.1;margin:0 0 20px;font-weight:720;
    letter-spacing:-.5px;
  }
  .hero h1 span{
    background:linear-gradient(90deg,var(--brand),var(--brand-2));
    -webkit-background-clip:text;background-clip:text;color:transparent;
  }
  .hero p{font-size:19px;color:var(--muted);max-width:620px;margin:0 auto 34px}
  .btns{display:flex;gap:14px;justify-content:center;flex-wrap:wrap}
  .btn{
    padding:13px 26px;border-radius:11px;font-weight:600;font-size:15px;
    border:1px solid transparent;transition:transform .12s,opacity .15s;
  }
  .btn:hover{transform:translateY(-1px)}
  .btn-primary{background:linear-gradient(90deg,var(--brand),var(--brand-2));color:#fff}
  .btn-ghost{border-color:var(--line);color:var(--ink)}
  .btn-ghost:hover{border-color:var(--brand)}
  .grid{
    display:grid;grid-template-columns:repeat(3,1fr);gap:20px;
    padding:24px 0 96px;
  }
  .card{
    background:var(--panel);border:1px solid var(--line);border-radius:16px;
    padding:28px;transition:border-color .15s,transform .15s;
  }
  .card:hover{border-color:#34405a;transform:translateY(-2px)}
  .card .ic{
    width:42px;height:42px;border-radius:11px;display:flex;align-items:center;
    justify-content:center;background:rgba(91,141,239,.12);margin-bottom:18px;
  }
  .card h3{margin:0 0 8px;font-size:18px}
  .card p{margin:0;color:var(--muted);font-size:15px}
  footer{
    border-top:1px solid var(--line);padding:30px 0;
    display:flex;align-items:center;justify-content:space-between;
    color:var(--muted);font-size:14px;flex-wrap:wrap;gap:12px;
  }
  @media(max-width:780px){
    .hero{padding:64px 0 48px}
    .hero h1{font-size:38px}
    .grid{grid-template-columns:1fr;padding-bottom:64px}
    nav a:not(.nav-cta){display:none}
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand">
      <svg width="28" height="28" viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect width="28" height="28" rx="8" fill="url(#g)"/>
        <path d="M8 19V9l6 7 6-7v10" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
        <defs><linearGradient id="g" x1="0" y1="0" x2="28" y2="28">
          <stop stop-color="#5b8def"/><stop offset="1" stop-color="#7c5cff"/>
        </linearGradient></defs>
      </svg>
      <span>Northwind Studio</span>
    </div>
    <nav>
      <a href="#work">Work</a>
      <a href="#services">Services</a>
      <a href="#contact" class="nav-cta">Contact</a>
    </nav>
  </header>

  <section class="hero">
    <span class="eyebrow">Independent Design &amp; Engineering</span>
    <h1>We build <span>calm, careful</span><br>digital products.</h1>
    <p>Northwind is a small studio partnering with founders and teams to design,
       prototype and ship software that feels effortless to use.</p>
    <div class="btns">
      <a href="#contact" class="btn btn-primary">Start a project</a>
      <a href="#work" class="btn btn-ghost">See our work</a>
    </div>
  </section>

  <section class="grid" id="services">
    <div class="card">
      <div class="ic">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#5b8def" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3"/><path d="M3 9h18M9 21V9"/></svg>
      </div>
      <h3>Product Design</h3>
      <p>Research, interface design and design systems that scale with your team.</p>
    </div>
    <div class="card">
      <div class="ic">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#5b8def" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6 2 12l6 6M16 6l6 6-6 6"/></svg>
      </div>
      <h3>Web Engineering</h3>
      <p>Fast, accessible and maintainable front-ends built on modern tooling.</p>
    </div>
    <div class="card">
      <div class="ic">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#5b8def" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v6m0 8v6M2 12h6m8 0h6"/><circle cx="12" cy="12" r="3"/></svg>
      </div>
      <h3>Strategy</h3>
      <p>From positioning to roadmap, we help you decide what to build next.</p>
    </div>
  </section>

  <footer>
    <span>&copy; Northwind Studio</span>
    <span id="contact">hello@northwind.studio</span>
  </footer>
</div>
</body>
</html>
EOF
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
DEF_ROLE="${ROLE:-outbound}"

echo ""
echo "================  НАСТРОЙКА  ================"

# --- Роль сервера ---
echo ""
echo "Роль этого сервера в схеме двойного прыжка (double-hop):"
echo "  1) outbound — сервер ЗА РУБЕЖОМ (точка выхода): AmneziaWG (wg-easy) + панель"
echo "                + опционально telemt (выход к Telegram)"
echo "  2) inbound  — сервер В РФ (точка входа): HAProxy + nginx + AmneziaWG-клиент к outbound"
echo "  Для обычного VPN без двойного прыжка выбирайте 1 (outbound)."
[[ "$DEF_ROLE" == "inbound" ]] && DEF_ROLE_N=2 || DEF_ROLE_N=1
while true; do
    read -rp "Вариант [1/2] [${DEF_ROLE_N}]: " ROLE_N
    ROLE_N="${ROLE_N:-$DEF_ROLE_N}"
    case "$ROLE_N" in
        1) ROLE=outbound; break ;;
        2) ROLE=inbound;  break ;;
        *) echo "  Введите 1 или 2." ;;
    esac
done
log "Роль сервера: $ROLE"

while true; do
    read -rp "Имя нового пользователя (вместо root) [${DEF_USER}]: " NEW_USER
    NEW_USER="${NEW_USER:-$DEF_USER}"
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    echo "  Некорректное имя. Допустимы строчные латинские буквы, цифры, '-' и '_'."
done

# Порт AmneziaWG нужен только outbound (он — WG-сервер). На inbound оставляем для памяти.
if [[ "$ROLE" == "outbound" ]]; then
    while true; do
        read -rp "Порт AmneziaWG (UDP) [${DEF_PORT}]: " WG_PORT
        WG_PORT="${WG_PORT:-$DEF_PORT}"
        [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) && break
        echo "  Некорректный порт. Введите число от 1 до 65535."
    done
else
    WG_PORT="${WG_PORT:-$DEF_PORT}"
fi

while true; do
    if [[ -n "$DEF_HOST" ]]; then
        read -rp "Публичный IP или домен ЭТОГО сервера [${DEF_HOST}]: " SERVER_HOST
        SERVER_HOST="${SERVER_HOST:-$DEF_HOST}"
    else
        read -rp "Публичный IP или домен ЭТОГО сервера: " SERVER_HOST
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

# --- Вопросы под роль (double-hop) ---
ENABLE_TELEMT="${ENABLE_TELEMT:-no}"
INBOUND_ADDR="${INBOUND_ADDR:-}"
TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-www.microsoft.com}"
TELEMT_PORT="${TELEMT_PORT:-8443}"
OUTBOUND_WG_IP="${OUTBOUND_WG_IP:-}"
AWG_PASTE=""

if [[ "$ROLE" == "outbound" ]]; then
    echo ""
    [[ "$ENABLE_TELEMT" == "yes" ]] && DEF_TG="y" || DEF_TG="N"
    read -rp "Включить Telegram-выход telemt (double-hop)? [y/N] [${DEF_TG}]: " ans
    ans="${ans:-$DEF_TG}"
    case "$ans" in y|Y|yes|YES|да|on|1|true) ENABLE_TELEMT=yes ;; *) ENABLE_TELEMT=no ;; esac
    if [[ "$ENABLE_TELEMT" == "yes" ]]; then
        while true; do
            read -rp "Публичный IP/домен INBOUND-сервера (точка входа в РФ) [${INBOUND_ADDR}]: " v
            INBOUND_ADDR="${v:-$INBOUND_ADDR}"
            [[ -n "$INBOUND_ADDR" ]] && break
            echo "  Нужен адрес inbound — он попадёт в ссылки Telegram (telemt public_host)."
        done
        read -rp "Маска fake-TLS для Telegram (чужой популярный домен, НЕ ваш) [${TELEMT_TLS_DOMAIN}]: " v
        TELEMT_TLS_DOMAIN="${v:-$TELEMT_TLS_DOMAIN}"
        read -rp "Порт telemt внутри туннеля [${TELEMT_PORT}]: " v
        TELEMT_PORT="${v:-$TELEMT_PORT}"
        log "telemt включён: вход=$INBOUND_ADDR, маска=$TELEMT_TLS_DOMAIN, порт=$TELEMT_PORT (панель ставится)"
    fi
else
    # inbound: параметры берутся из печати outbound-скрипта
    echo ""
    echo "Параметры для подключения к OUTBOUND (их напечатал outbound-скрипт в конце):"
    read -rp "Маска fake-TLS Telegram (как на outbound) [${TELEMT_TLS_DOMAIN}]: " v
    TELEMT_TLS_DOMAIN="${v:-$TELEMT_TLS_DOMAIN}"
    while true; do
        read -rp "WG-IP telemt на outbound (например 10.8.0.1) [${OUTBOUND_WG_IP}]: " v
        OUTBOUND_WG_IP="${v:-$OUTBOUND_WG_IP}"
        [[ "$OUTBOUND_WG_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo "  Введите IPv4-адрес туннеля telemt (его печатает outbound-скрипт)."
    done
    read -rp "Порт telemt внутри туннеля [${TELEMT_PORT}]: " v
    TELEMT_PORT="${v:-$TELEMT_PORT}"

    if [[ -s "$AWG_CONF_DIR/$AWG_IFACE.conf" ]]; then
        skip "AmneziaWG-конфиг клиента уже есть ($AWG_CONF_DIR/$AWG_IFACE.conf) — переиспользую"
    else
        echo ""
        echo "Вставьте AmneziaWG-конфиг клиента целиком."
        echo "  (в панели wg-easy на outbound: New Client → скачать .conf, открыть, скопировать)"
        echo "  Завершите ввод строкой:  END"
        AWG_PASTE=""
        while IFS= read -r line; do
            [[ "$line" == "END" ]] && break
            AWG_PASTE+="$line"$'\n'
        done
        [[ -n "$AWG_PASTE" ]] || die "Пустой AmneziaWG-конфиг — повторите запуск и вставьте конфиг клиента."
    fi
fi

deploy_file "$ANSWERS_FILE" 600 <<EOF >/dev/null || true
ROLE="$ROLE"
NEW_USER="$NEW_USER"
WG_PORT="$WG_PORT"
SERVER_HOST="$SERVER_HOST"
CERT_MODE="$CERT_MODE"
LE_EMAIL="$LE_EMAIL"
ENABLE_TELEMT="$ENABLE_TELEMT"
INBOUND_ADDR="$INBOUND_ADDR"
TELEMT_TLS_DOMAIN="$TELEMT_TLS_DOMAIN"
TELEMT_PORT="$TELEMT_PORT"
OUTBOUND_WG_IP="$OUTBOUND_WG_IP"
EOF

log "Параметры: роль=$ROLE, пользователь=$NEW_USER, адрес=$SERVER_HOST, сертификат=режим$CERT_MODE"

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
if [[ "$ROLE" == "outbound" ]]; then
    ufw allow "$WG_PORT/udp" >/dev/null && log "ufw: разрешён $WG_PORT/udp (AmneziaWG)"
fi

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

# Секреты telemt + панели telemt (только outbound с включённым telemt)
TELEMT_SECRET="${TELEMT_SECRET:-}"
TELEMT_PANEL_PATH="${TELEMT_PANEL_PATH:-}"
TELEMT_PANEL_COOKIE="${TELEMT_PANEL_COOKIE:-}"
TELEMT_PANEL_PASS="${TELEMT_PANEL_PASS:-}"
TELEMT_PANEL_HASH="${TELEMT_PANEL_HASH:-}"
TELEMT_JWT="${TELEMT_JWT:-}"
if [[ "$ROLE" == "outbound" && "$ENABLE_TELEMT" == "yes" ]]; then
    TELEMT_SECRET="${TELEMT_SECRET:-$(openssl rand -hex 16)}"
    TELEMT_PANEL_PATH="${TELEMT_PANEL_PATH:-$(openssl rand -hex 12)}"
    TELEMT_PANEL_COOKIE="${TELEMT_PANEL_COOKIE:-$(openssl rand -hex 32)}"
    TELEMT_PANEL_PASS="${TELEMT_PANEL_PASS:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)}"
    TELEMT_JWT="${TELEMT_JWT:-$(openssl rand -hex 32)}"
    if [[ -z "$TELEMT_PANEL_HASH" ]]; then
        apt_install apache2-utils
        # htpasswd выдаёт $2y$ — заменяем на $2a$ для совместимости с Go-bcrypt панели
        TELEMT_PANEL_HASH=$(htpasswd -nbBC 10 "" "$TELEMT_PANEL_PASS" | cut -d: -f2- | sed 's/^\$2y\$/\$2a\$/')
    fi
fi

# В файле значения с '$' (bcrypt-хеш) храним в ОДИНАРНЫХ кавычках, чтобы при
# повторном source их не разворачивал bash.
deploy_file "$SECRETS_FILE" 600 <<EOF >/dev/null || true
PANEL_PATH="$PANEL_PATH"
COOKIE_TOKEN="$COOKIE_TOKEN"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
TELEMT_SECRET="$TELEMT_SECRET"
TELEMT_PANEL_PATH="$TELEMT_PANEL_PATH"
TELEMT_PANEL_COOKIE="$TELEMT_PANEL_COOKIE"
TELEMT_PANEL_PASS="$TELEMT_PANEL_PASS"
TELEMT_PANEL_HASH='$TELEMT_PANEL_HASH'
TELEMT_JWT="$TELEMT_JWT"
EOF
log "Секретный путь панели: /$PANEL_PATH"

# ##############################################################################
# ВЕТКА OUTBOUND (сервер за рубежом): wg-easy + nginx [+ telemt]
# ##############################################################################
if [[ "$ROLE" == "outbound" ]]; then

# ==============================================================================
# ШАГ 9. Стек wg-easy + nginx [+ telemt]: .env и docker-compose
# ==============================================================================
log "--- Шаг 9: подготовка стека (.env + docker-compose) ---"

mkdir -p "$WG_DIR" "$NGINX_DIR/conf.d" "$STUB_DIR" "$SSL_DIR"
chmod 700 "$WG_DIR"

STACK_CHANGED=0

# Переменные стека (включая пароль) держим в .env с правами 600
if deploy_file "$WG_DIR/.env" 600 <<EOF
WG_PORT=$WG_PORT
INIT_HOST=$SERVER_HOST
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
then
    STACK_CHANGED=1
fi

# Единый docker-compose: wg-easy + nginx в общей сети wg (+ telemt при $1==1).
#  - Панель НЕ публикуется на хост — nginx ходит к ней по имени сервиса
#    (wg-easy:51821) внутри docker-сети; наружу торчат только 80/443 и WG/udp.
#  - EXPERIMENTAL_AWG=true: поддержка AmneziaWG (модуль ядра определяется автоматически).
#  - INSECURE=true: TLS терминирует nginx, к панели идёт http по внутренней сети.
#  - INIT_*: первичная настройка (применяется только при ПЕРВОМ запуске).
#  - telemt и telemt-panel делят netns wg-easy (network_mode: service:wg-easy):
#    telemt слушает WG-IP туннеля, панель достаёт его API по loopback.
compose_yml() {
    local with_telemt="${1:-0}"
    cat <<'EOF'
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

  nginx:
    image: nginx:stable
    container_name: wg-nginx
    depends_on:
      - wg-easy
    networks:
      - wg
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
      - ./nginx/stub:/var/www/stub:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    restart: unless-stopped
EOF
    if [[ "$with_telemt" == "1" ]]; then
        cat <<'EOF'

  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    depends_on:
      - wg-easy
    network_mode: "service:wg-easy"
    working_dir: /run/telemt
    command: ["/etc/telemt/config.toml"]
    volumes:
      - ./telemt:/etc/telemt:rw
    tmpfs:
      - /run/telemt:rw,mode=1777,size=16m
    restart: unless-stopped

  telemt-panel:
    build: ./telemt-panel/src
    container_name: telemt-panel
    depends_on:
      - telemt
    network_mode: "service:wg-easy"
    volumes:
      - ./telemt-panel/config.toml:/etc/telemt-panel/config.toml:ro
    restart: unless-stopped
EOF
    fi
    cat <<'EOF'

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
}

# Базовый compose (без telemt) — telemt добавим после определения WG-IP (Шаг 10б)
if deploy_file "$WG_DIR/docker-compose.yml" 600 < <(compose_yml 0); then
    STACK_CHANGED=1
fi

# ==============================================================================
# ШАГ 10. Конфигурация nginx, запуск стека и TLS-сертификат
# ==============================================================================
log "--- Шаг 10: nginx, запуск стека и TLS ---"

# Управление nginx внутри контейнера
nginx_test()   { docker exec wg-nginx nginx -t; }
nginx_reload() { docker exec wg-nginx nginx -s reload; }

# IPv6-listen добавляем, только если IPv6 включён в системе
LISTEN6_80=""
LISTEN6_443=""
if [[ -f /proc/net/if_inet6 ]]; then
    LISTEN6_80="listen [::]:80 default_server;"
    LISTEN6_443="listen [::]:443 ssl default_server;"
fi

# Рендер конфигурации nginx. $1/$2 — пути к сертификату/ключу ВНУТРИ контейнера.
# Схема доступа к панели:
#   GET /<секретный_путь>  -> ставится HttpOnly-cookie + redirect на /
#   запросы с верной cookie -> proxy_pass на панель (wg-easy:51821 по docker-сети)
#   все остальные запросы   -> статическая заглушка
# (wg-easy — SPA с абсолютными путями /api, /_nuxt — поэтому cookie-схема,
#  а не проксирование подпути, которое сломало бы интерфейс панели)
render_nginx() {
    local crt="$1" key="$2" tmp tpanel=0
    [[ "$ENABLE_TELEMT" == "yes" && -n "$TELEMT_PANEL_PATH" ]] && tpanel=1
    tmp=$(mktemp)
    {
        cat <<'EOF'
# Создано vps_setup.sh — не редактируйте вручную, файл перезаписывается

# токен cookie длиной 64 символа не влезает в дефолтный бакет (64)
map_hash_bucket_size 128;

# cookie panel=<токен> выбирает backend панели; пусто -> заглушка.
# Переменный upstream резолвится docker-DNS (127.0.0.11) в момент запроса.
map $cookie_panel $panel_upstream {
    default "";
    "@COOKIE_WG@" "wg-easy:@WG_UI_PORT@";
EOF
        [[ $tpanel == 1 ]] && cat <<'EOF'
    "@COOKIE_TELEMT@" "wg-easy:@TELEMT_PANEL_PORT@";
EOF
        cat <<'EOF'
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
        root /var/www/stub;
        default_type "text/plain";
        try_files $uri =404;
    }

    location = /@PANEL_PATH@ { return 301 https://$host$request_uri; }
EOF
        [[ $tpanel == 1 ]] && cat <<'EOF'
    location = /@TELEMT_PANEL_PATH@ { return 301 https://$host$request_uri; }
EOF
        cat <<'EOF'
    location / {
        root /var/www/stub;
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

    # Секретный путь панели wg-easy: ставим cookie и шлём на /
    location = /@PANEL_PATH@ {
        add_header Set-Cookie "panel=@COOKIE_WG@; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=43200";
        return 302 /;
    }
EOF
        [[ $tpanel == 1 ]] && cat <<'EOF'
    # Секретный путь панели telemt
    location = /@TELEMT_PANEL_PATH@ {
        add_header Set-Cookie "panel=@COOKIE_TELEMT@; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=43200";
        return 302 /;
    }
EOF
        cat <<'EOF'
    location / {
        error_page 418 = @panel;
        if ($panel_upstream) { return 418; }
        root /var/www/stub;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location @panel {
        resolver 127.0.0.11 ipv6=off;
        proxy_pass http://$panel_upstream;
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
    } > "$tmp"
    sed -i \
        -e "s|@PANEL_PATH@|$PANEL_PATH|g" \
        -e "s|@TELEMT_PANEL_PATH@|$TELEMT_PANEL_PATH|g" \
        -e "s|@COOKIE_WG@|$COOKIE_TOKEN|g" \
        -e "s|@COOKIE_TELEMT@|$TELEMT_PANEL_COOKIE|g" \
        -e "s|@SSL_CRT@|$crt|g" \
        -e "s|@SSL_KEY@|$key|g" \
        -e "s|@WG_UI_PORT@|$WG_UI_PORT|g" \
        -e "s|@TELEMT_PANEL_PORT@|$TELEMT_PANEL_PORT|g" \
        -e "s|@LISTEN6_80@|$LISTEN6_80|g" \
        -e "s|@LISTEN6_443@|$LISTEN6_443|g" \
        "$tmp"
    if deploy_file "$NGINX_CONF" 644 < "$tmp"; then
        STACK_CHANGED=1
    fi
    rm -f "$tmp"
}

# --- Сайт-заглушка ---
if deploy_stub "$STUB_DIR"; then
    STACK_CHANGED=1
fi

# --- Самоподписанный сертификат (bootstrap: nginx должен стартовать до certbot) ---
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
    STACK_CHANGED=1
fi

# --- Выбор итогового сертификата (пути ВНУТРИ контейнера) ---
LE_LIVE="/etc/letsencrypt/live/$SERVER_HOST"   # путь одинаков на хосте и в контейнере
CERT_CRT="/etc/nginx/ssl/selfsigned.crt"
CERT_KEY="/etc/nginx/ssl/selfsigned.key"
CERT_DESC="самоподписанный (браузер покажет предупреждение)"

# Если сертификат Let's Encrypt уже выпущен — используем его сразу
if [[ "$CERT_MODE" != "1" && -s "$LE_LIVE/fullchain.pem" ]]; then
    CERT_CRT="$LE_LIVE/fullchain.pem"
    CERT_KEY="$LE_LIVE/privkey.pem"
    CERT_DESC="Let's Encrypt"
    skip "Сертификат Let's Encrypt для $SERVER_HOST уже выпущен"
fi
render_nginx "$CERT_CRT" "$CERT_KEY"

# --- Освобождаем 80/443 от системного nginx (мог остаться от старой версии скрипта) ---
# Раньше nginx ставился на хост; теперь его роль выполняет контейнер wg-nginx.
# Иначе host-nginx удержит порты 80/443 и контейнер не сможет их забиндить.
if dpkg -s nginx >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
    if systemctl is-enabled --quiet nginx 2>/dev/null || systemctl is-active --quiet nginx 2>/dev/null; then
        warn "Обнаружен системный nginx на хосте — останавливаю и отключаю (порты 80/443 займёт контейнер wg-nginx)"
        systemctl disable --now nginx 2>/dev/null || true
    fi
fi

# --- Запуск/обновление стека ---
NGINX_RUNNING=$(docker inspect -f '{{.State.Running}}' wg-nginx 2>/dev/null || echo "false")
WG_RUNNING=$(docker inspect -f '{{.State.Running}}' wg-easy 2>/dev/null || echo "false")
if (( STACK_CHANGED )) || [[ "$NGINX_RUNNING" != "true" || "$WG_RUNNING" != "true" ]]; then
    log "Запускаю стек (docker compose up -d)"
    (cd "$WG_DIR" && docker compose up -d)
else
    skip "Стек уже запущен, конфигурация не менялась"
fi

# Ждём, пока nginx начнёт отвечать на 443
log "Жду запуска nginx на https://127.0.0.1 ..."
NGINX_UP=0
for _ in $(seq 1 30); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1/" || true)
    if [[ "$code" != "000" ]]; then NGINX_UP=1; break; fi
    sleep 2
done
if (( NGINX_UP )); then
    log "Nginx отвечает (HTTP $code)"
else
    warn "Nginx не ответил за 60 секунд. Проверьте: docker logs wg-nginx; docker logs wg-easy"
fi

# Применяем изменения конфига к уже работающему nginx (docker не перечитывает
# смонтированный конфиг при правке — нужен reload)
if (( STACK_CHANGED )) && [[ "$(docker inspect -f '{{.State.Running}}' wg-nginx 2>/dev/null || echo false)" == "true" ]]; then
    if nginx_test; then
        nginx_reload
        log "Конфигурация nginx применена (сертификат: $CERT_DESC)"
    else
        die "Ошибка конфигурации nginx — проверьте $NGINX_CONF (docker exec wg-nginx nginx -t)"
    fi
fi

# --- Выпуск сертификата Let's Encrypt, если запрошен и ещё не выпущен ---
if [[ "$CERT_MODE" != "1" && ! -s "$LE_LIVE/fullchain.pem" ]]; then
    # Хук перезагрузки nginx после каждого обновления сертификата
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    deploy_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 755 <<'EOF' >/dev/null || true
#!/bin/sh
docker exec wg-nginx nginx -s reload
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
        CERT_DESC="Let's Encrypt"
        STACK_CHANGED=0
        render_nginx "$LE_LIVE/fullchain.pem" "$LE_LIVE/privkey.pem"
        if nginx_test; then
            nginx_reload
            log "Nginx переключён на сертификат Let's Encrypt (автопродление — systemd-таймер certbot, hook перезагружает контейнер)"
        else
            die "Ошибка конфигурации nginx после переключения на LE — проверьте $NGINX_CONF"
        fi
    fi
fi

# ==============================================================================
# ШАГ 10б. telemt (Telegram-выход) — только при ENABLE_TELEMT
# ==============================================================================
if [[ "$ENABLE_TELEMT" == "yes" ]]; then
    log "--- Шаг 10б: telemt (Telegram-выход) ---"

    # 1. WG-IP туннеля внутри wg-easy (ретраим — wg0 поднимается не мгновенно)
    WG_TUN_IP=""
    for _ in $(seq 1 30); do
        WG_TUN_IP=$(docker exec wg-easy ip -4 -o addr show 2>/dev/null \
            | awk '$2 ~ /^wg/ {print $4}' | cut -d/ -f1 | head -n1 || true)
        [[ -n "$WG_TUN_IP" ]] && break
        sleep 2
    done
    [[ -n "$WG_TUN_IP" ]] || die "Не удалось определить WG-IP внутри wg-easy (docker exec wg-easy ip addr)."
    log "WG-IP туннеля (на нём слушает telemt): $WG_TUN_IP"

    # 2. Конфиг telemt (монтируется директорией; рабочая папка — tmpfs из compose)
    mkdir -p "$TELEMT_DIR"
    deploy_file "$TELEMT_DIR/config.toml" 600 <<EOF >/dev/null || true
[general]
fast_mode        = true
use_middle_proxy = true
log_level        = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show        = "*"
public_host = "$INBOUND_ADDR"
public_port = 443

[network]
ipv4   = true
ipv6   = false
prefer = 4

[server]
port           = $TELEMT_PORT
proxy_protocol = true
client_mss     = "tspu"

[server.api]
enabled   = true
listen    = "127.0.0.1:$TELEMT_API_PORT"
whitelist = ["127.0.0.1/32", "::1/128"]

[[server.listeners]]
ip = "$WG_TUN_IP"

[censorship]
tls_domain         = "$TELEMT_TLS_DOMAIN"
mask               = true
mask_port          = 443
tls_emulation      = true
tls_front_dir      = "tlsfront"
unknown_sni_action = "reject_handshake"
fake_cert_len      = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
user1 = "$TELEMT_SECRET"
EOF

    # 3. telemt_panel — собираем из исходников, рендерим конфиг
    command -v git >/dev/null 2>&1 || apt_install git
    if [[ -d "$TELEMT_PANEL_DIR/src/.git" ]]; then
        skip "Исходники telemt_panel уже склонированы"
    else
        log "Клонирую telemt_panel ($TELEMT_PANEL_REPO)"
        rm -rf "$TELEMT_PANEL_DIR/src"
        git clone --depth 1 "$TELEMT_PANEL_REPO" "$TELEMT_PANEL_DIR/src" \
            || die "Не удалось склонировать telemt_panel"
    fi
    deploy_file "$TELEMT_PANEL_DIR/config.toml" 600 <<EOF >/dev/null || true
listen = "0.0.0.0:$TELEMT_PANEL_PORT"

[telemt]
url         = "http://127.0.0.1:$TELEMT_API_PORT"
auth_header = ""

[auth]
username      = "admin"
password_hash = "$TELEMT_PANEL_HASH"
jwt_secret    = "$TELEMT_JWT"
session_ttl   = "24h"
EOF

    # 4. Перезаписываем compose с telemt + поднимаем (сборка панели — пара минут)
    deploy_file "$WG_DIR/docker-compose.yml" 600 < <(compose_yml 1) >/dev/null || true
    log "Поднимаю telemt + telemt-panel (docker compose up -d)"
    (cd "$WG_DIR" && docker compose up -d)

    sleep 3
    if [[ "$(docker inspect -f '{{.State.Running}}' telemt 2>/dev/null || echo false)" == "true" ]]; then
        log "telemt запущен (слушает $WG_TUN_IP:$TELEMT_PORT в туннеле)"
    else
        warn "telemt не запустился сразу — он retry'ит, пока поднимется wg0. Проверьте: docker logs telemt"
    fi
fi

# Сохраняем WG-IP в ответы (печатается в памятке, нужен для inbound)
deploy_file "$ANSWERS_FILE" 600 <<EOF >/dev/null || true
ROLE="$ROLE"
NEW_USER="$NEW_USER"
WG_PORT="$WG_PORT"
SERVER_HOST="$SERVER_HOST"
CERT_MODE="$CERT_MODE"
LE_EMAIL="$LE_EMAIL"
ENABLE_TELEMT="$ENABLE_TELEMT"
INBOUND_ADDR="$INBOUND_ADDR"
TELEMT_TLS_DOMAIN="$TELEMT_TLS_DOMAIN"
TELEMT_PORT="$TELEMT_PORT"
OUTBOUND_WG_IP="${WG_TUN_IP:-$OUTBOUND_WG_IP}"
EOF

else
# ##############################################################################
# ВЕТКА INBOUND (РФ): AmneziaWG-клиент + nginx (легит-сайт) + HAProxy (SNI)
# ##############################################################################

# ==============================================================================
# ШАГ 9и. AmneziaWG-клиент к outbound
# ==============================================================================
log "--- Шаг 9и: AmneziaWG-клиент к outbound ---"

mkdir -p "$AWG_CONF_DIR"; chmod 700 "$AWG_CONF_DIR"
if [[ -n "$AWG_PASTE" ]]; then
    printf '%s' "$AWG_PASTE" > "$AWG_CONF_DIR/$AWG_IFACE.conf"
    chmod 600 "$AWG_CONF_DIR/$AWG_IFACE.conf"
    log "AmneziaWG-конфиг клиента сохранён: $AWG_CONF_DIR/$AWG_IFACE.conf"
fi
[[ -s "$AWG_CONF_DIR/$AWG_IFACE.conf" ]] || die "Нет конфига $AWG_CONF_DIR/$AWG_IFACE.conf"

# Сужаем AllowedIPs до подсети туннеля, чтобы свой трафик inbound не уходил в туннель
TUN_SUBNET="${OUTBOUND_WG_IP%.*}.0/24"
if grep -q '0\.0\.0\.0/0' "$AWG_CONF_DIR/$AWG_IFACE.conf"; then
    log "Сужаю AllowedIPs до $TUN_SUBNET"
    sed -i -E "s#^AllowedIPs\s*=.*#AllowedIPs = $TUN_SUBNET#" "$AWG_CONF_DIR/$AWG_IFACE.conf"
fi
# Держим туннель живым (важно для стабильности прыжка)
if ! grep -qi 'PersistentKeepalive' "$AWG_CONF_DIR/$AWG_IFACE.conf"; then
    sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$AWG_CONF_DIR/$AWG_IFACE.conf"
fi

awg-quick down "$AWG_IFACE" 2>/dev/null || true
awg-quick up "$AWG_IFACE" || die "Не удалось поднять $AWG_IFACE — проверьте конфиг и доступность outbound по UDP."
systemctl enable "awg-quick@$AWG_IFACE" >/dev/null 2>&1 || true

if timeout 5 bash -c "exec 3<>/dev/tcp/$OUTBOUND_WG_IP/$TELEMT_PORT" 2>/dev/null; then
    log "telemt доступен по туннелю ($OUTBOUND_WG_IP:$TELEMT_PORT)"
else
    warn "telemt пока недоступен ($OUTBOUND_WG_IP:$TELEMT_PORT) — проверьте handshake: awg show $AWG_IFACE"
fi

# ==============================================================================
# ШАГ 10и. Легит-сайт (nginx) + HAProxy (SNI-роутер) + TLS
# ==============================================================================
log "--- Шаг 10и: nginx (легит-сайт) + HAProxy ---"

mkdir -p "$INB_DIR" "$INB_SSL_DIR"
deploy_stub "$INB_STUB_DIR" >/dev/null || true

# bootstrap самоподписанный
if [[ ! -s "$INB_SSL_DIR/selfsigned.crt" ]]; then
    log "Генерирую самоподписанный сертификат для $SERVER_HOST"
    if [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]]; then SAN="IP:$SERVER_HOST"; else SAN="DNS:$SERVER_HOST"; fi
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$INB_SSL_DIR/selfsigned.key" -out "$INB_SSL_DIR/selfsigned.crt" \
        -subj "/CN=$SERVER_HOST" -addext "subjectAltName=$SAN"
    chmod 600 "$INB_SSL_DIR/selfsigned.key"
fi

INB_LE_LIVE="/etc/letsencrypt/live/$SERVER_HOST"
INB_CRT="/etc/nginx/ssl/selfsigned.crt"; INB_KEY="/etc/nginx/ssl/selfsigned.key"
INB_CERT_DESC="самоподписанный (браузер покажет предупреждение)"
if [[ "$CERT_MODE" != "1" && -s "$INB_LE_LIVE/fullchain.pem" ]]; then
    INB_CRT="$INB_LE_LIVE/fullchain.pem"; INB_KEY="$INB_LE_LIVE/privkey.pem"; INB_CERT_DESC="Let's Encrypt"
fi

# nginx легит-сайта: :80 (ACME) + 127.0.0.1:8443 (TLS, за HAProxy)
render_inb_nginx() {
    deploy_file "$INB_DIR/nginx.conf" 644 <<EOF
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ { root /var/www/site; default_type "text/plain"; try_files \$uri =404; }
    location / { root /var/www/site; index index.html; try_files \$uri \$uri/ =404; }
}
server {
    listen 127.0.0.1:$INB_SITE_TLS_PORT ssl default_server;
    server_name _;
    server_tokens off;
    ssl_certificate     $INB_CRT;
    ssl_certificate_key $INB_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { root /var/www/site; index index.html; try_files \$uri \$uri/ =404; }
}
EOF
}
render_inb_nginx >/dev/null || true

# HAProxy: SNI=маска telemt → туннель (send-proxy-v2), иначе → легит-сайт
deploy_file "$INB_DIR/haproxy.cfg" 644 <<EOF >/dev/null || true
global
    log stdout format raw local0
    maxconn 10000
defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout check   5s
frontend fe_443
    bind 0.0.0.0:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl sni_tg req.ssl_sni -i $TELEMT_TLS_DOMAIN
    use_backend be_tg if sni_tg
    default_backend be_site
backend be_tg
    server tg $OUTBOUND_WG_IP:$TELEMT_PORT send-proxy-v2 check
backend be_site
    server site 127.0.0.1:$INB_SITE_TLS_PORT check
EOF

deploy_file "$INB_DIR/docker-compose.yml" 600 <<'EOF' >/dev/null || true
services:
  nginx:
    image: nginx:stable
    container_name: inb-nginx
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./site:/var/www/site:ro
      - ./ssl:/etc/nginx/ssl:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    restart: unless-stopped
  haproxy:
    image: haproxy:lts-alpine
    container_name: inb-haproxy
    user: "root"
    network_mode: host
    depends_on:
      - nginx
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: unless-stopped
EOF

# освобождаем 80/443 от системного nginx, если он остался
if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "Останавливаю системный nginx (порты 80/443 займут контейнеры)"
    systemctl disable --now nginx 2>/dev/null || true
fi

log "Поднимаю inbound-стек (docker compose up -d)"
(cd "$INB_DIR" && docker compose up -d)

inb_nginx_reload() { docker exec inb-nginx nginx -t && docker exec inb-nginx nginx -s reload; }

# certbot для домена inbound (если выбран LE)
if [[ "$CERT_MODE" != "1" && ! -s "$INB_LE_LIVE/fullchain.pem" ]]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    deploy_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 755 <<'EOF' >/dev/null || true
#!/bin/sh
docker exec inb-nginx nginx -s reload
EOF
    if [[ "$CERT_MODE" == "2" ]]; then
        log "Выпускаю сертификат Let's Encrypt (HTTP-01) для $SERVER_HOST"
        apt_install certbot
        certbot certonly --webroot -w "$INB_STUB_DIR" -d "$SERVER_HOST" \
            --non-interactive --agree-tos -m "$LE_EMAIL" \
            || warn "Не удалось получить сертификат (HTTP-01). Остаюсь на самоподписанном."
    elif [[ "$CERT_MODE" == "3" ]]; then
        log "Выпускаю сертификат Let's Encrypt (Cloudflare DNS-01) для $SERVER_HOST"
        apt_install certbot python3-certbot-dns-cloudflare
        mkdir -p "$(dirname "$CF_CREDS_FILE")"; chmod 700 "$(dirname "$CF_CREDS_FILE")"
        if [[ -n "$CF_TOKEN" ]]; then
            printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_CREDS_FILE"
            chmod 600 "$CF_CREDS_FILE"
        fi
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS_FILE" \
            --dns-cloudflare-propagation-seconds 30 -d "$SERVER_HOST" \
            --non-interactive --agree-tos -m "$LE_EMAIL" \
            || warn "Не удалось получить сертификат (DNS-01). Остаюсь на самоподписанном."
    fi
    if [[ -s "$INB_LE_LIVE/fullchain.pem" ]]; then
        INB_CRT="$INB_LE_LIVE/fullchain.pem"; INB_KEY="$INB_LE_LIVE/privkey.pem"; INB_CERT_DESC="Let's Encrypt"
        render_inb_nginx >/dev/null || true
        inb_nginx_reload || true
        log "Inbound nginx переключён на сертификат Let's Encrypt"
    fi
fi

CERT_DESC="$INB_CERT_DESC"

fi  # конец ветки по роли (outbound/inbound)

# ==============================================================================
# ШАГ 11. Памятка и итоговый вывод
# ==============================================================================
log "--- Шаг 11: сохранение памятки ---"

if [[ "$ROLE" == "outbound" ]]; then
    # tg://-ссылка (fake-TLS): ee + secret + hex(маска)
    TELEMT_INFO=""
    if [[ "$ENABLE_TELEMT" == "yes" ]]; then
        TLS_HEX=$(printf '%s' "$TELEMT_TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
        TG_LINK="tg://proxy?server=${INBOUND_ADDR}&port=443&secret=ee${TELEMT_SECRET}${TLS_HEX}"
        TELEMT_INFO=$(cat <<EOF2

 ----- Telegram double-hop (telemt) -----
 Маска fake-TLS:    $TELEMT_TLS_DOMAIN
 WG-IP telemt:      ${WG_TUN_IP:-?}  (порт $TELEMT_PORT) — укажите его на INBOUND
 Секрет telemt:     $TELEMT_SECRET
 Ссылка Telegram:   $TG_LINK
 Панель telemt:     https://$SERVER_HOST/$TELEMT_PANEL_PATH  (admin / $TELEMT_PANEL_PASS)

 Дальше на INBOUND-сервере (в РФ):
   1) в панели wg-easy (выше) создайте клиента: New Client -> скачать .conf
   2) запустите этот же скрипт, роль = inbound, вставьте .conf и укажите:
      WG-IP telemt=${WG_TUN_IP:-?}, порт=$TELEMT_PORT, маска=$TELEMT_TLS_DOMAIN
EOF2
)
    fi

    OUT_TITLE_TELEMT=""
    [[ "$ENABLE_TELEMT" == "yes" ]] && OUT_TITLE_TELEMT=" + telemt"
    deploy_file "$PANEL_INFO_FILE" 600 <<EOF >/dev/null || true
============================================================
 OUTBOUND (за рубежом) — wg-easy + nginx$OUT_TITLE_TELEMT
============================================================
 Панель wg-easy:    https://$SERVER_HOST/$PANEL_PATH
 Логин / пароль:    $ADMIN_USER / $ADMIN_PASSWORD
 Порт AmneziaWG:    $WG_PORT/udp
 TLS-сертификат:    $CERT_DESC
 SSH-пользователь:  $NEW_USER (root по SSH отключён, порт $SSH_PORT/tcp)
$TELEMT_INFO

 Доступ к панелям: заход на секретный URL ставит cookie на 12 ч и
 открывает соответствующую панель; без cookie на любом пути — заглушка.
============================================================
EOF
    log "Памятка сохранена: $PANEL_INFO_FILE"

    echo ""
    echo "=============================================================="
    echo "  OUTBOUND ГОТОВ"
    echo "=============================================================="
    echo ""
    echo "  Панель wg-easy:   https://$SERVER_HOST/$PANEL_PATH"
    echo "  Логин / пароль:   $ADMIN_USER / $ADMIN_PASSWORD"
    echo "  TLS-сертификат:   $CERT_DESC"
    if [[ "$ENABLE_TELEMT" == "yes" ]]; then
        echo ""
        echo "  Telegram (double-hop):"
        echo "    Панель telemt:  https://$SERVER_HOST/$TELEMT_PANEL_PATH  (admin / $TELEMT_PANEL_PASS)"
        echo "    Ссылка:         $TG_LINK"
        echo "    WG-IP telemt:   ${WG_TUN_IP:-?}:$TELEMT_PORT  (понадобится на INBOUND)"
        echo ""
        echo "  Дальше: создайте клиента в панели wg-easy, скачайте .conf и"
        echo "  запустите скрипт на INBOUND-сервере (роль inbound)."
    fi
    echo ""
    echo "  Памятка: $PANEL_INFO_FILE   Лог: $LOG_FILE"
else
    deploy_file "$PANEL_INFO_FILE" 600 <<EOF >/dev/null || true
============================================================
 INBOUND (в РФ) — HAProxy + nginx + AmneziaWG-клиент
============================================================
 Точка входа:       $SERVER_HOST:443
 Легит-сайт:        https://$SERVER_HOST/   (TLS: $CERT_DESC)
 SSH-пользователь:  $NEW_USER (root по SSH отключён, порт $SSH_PORT/tcp)

 Туннель к outbound: AmneziaWG ($AWG_IFACE) -> telemt $OUTBOUND_WG_IP:$TELEMT_PORT
 Маршрут Telegram:  HAProxy :443, SNI=$TELEMT_TLS_DOMAIN -> туннель -> telemt
                    остальной SNI -> легит-сайт (nginx 127.0.0.1:$INB_SITE_TLS_PORT)

 Проверка туннеля:  awg show $AWG_IFACE   (должен быть свежий handshake)
 Логи:              docker logs inb-haproxy ; docker logs inb-nginx
 Ссылку Telegram tg://... печатал OUTBOUND-скрипт (server=$SERVER_HOST).
============================================================
EOF
    log "Памятка сохранена: $PANEL_INFO_FILE"

    echo ""
    echo "=============================================================="
    echo "  INBOUND ГОТОВ"
    echo "=============================================================="
    echo ""
    echo "  Точка входа:      $SERVER_HOST:443"
    echo "  Легит-сайт:       https://$SERVER_HOST/   (TLS: $CERT_DESC)"
    echo "  Туннель telemt:   $OUTBOUND_WG_IP:$TELEMT_PORT (через $AWG_IFACE)"
    echo "  Проверка:         awg show $AWG_IFACE"
    echo ""
    echo "  Telegram-ссылку (tg://proxy?server=$SERVER_HOST...) печатал outbound-скрипт."
    echo "  Памятка: $PANEL_INFO_FILE   Лог: $LOG_FILE"
fi

echo ""
echo "  ВАЖНО: НЕ закрывайте эту SSH-сессию, пока не проверите вход в новом окне:"
echo "         ssh $NEW_USER@$SERVER_HOST   (root по SSH запрещён, порт $SSH_PORT/tcp открыт)"
if [[ "$CERT_DESC" != "Let's Encrypt" ]]; then
    echo "         Сертификат самоподписанный — для нормального перезапустите скрипт"
    echo "         и выберите способ TLS 2 (Let's Encrypt) или 3 (Cloudflare)."
fi
echo ""
log "Скрипт успешно завершён"
