#!/usr/bin/env bash
# ==============================================================================
#  setup.sh — ОДИН VPS: VPN (AmneziaWG/wg-easy) + MTProto-прокси (внешний движок)
#
#  Идея: НЕ переписывать анти-DPI руками. Скрипт ставит:
#    1. Базовую безопасность (пользователь, SSH hardening, ufw, fail2ban)
#    2. wg-easy + AmneziaWG  — VPN (UDP). Панель только на 127.0.0.1 -> доступ по SSH.
#    3. На выбор один из ГОТОВЫХ движков MTProto-прокси, скачиваемых В ПОСЛЕДНЕЙ версии:
#         - MTProxyL  (telemt + zapret2-десинк + PQ self-mask/cloak)  <- рекомендуется
#         - MEKO      (MTPROTO_FIX_By_MEKO)
#    Движок сам владеет :443 (fake-TLS + десинк ServerHello) и обслуживает
#    сайт-прикрытие (self-SNI). Мы его НЕ вендорим — тянем свежий на каждом запуске.
#
#  Двойной прыжок НЕ нужен: реальный фикс DPI — десинк ServerHello (доказано
#  tcpdump'ом), а не топология. Один VPS, single-hop.
#
#  ОС: Ubuntu 22.04/24.04, Debian 12.   Запуск: sudo bash setup.sh
# ==============================================================================
set -Eeuo pipefail

LOG_FILE="/var/log/vps_setup.log"
STATE_DIR="/var/lib/vps_setup"
ANSWERS_FILE="$STATE_DIR/answers.env"
INSTALLED_FILE="$STATE_DIR/installed.env"     # что и какой версии реально поставили
WG_DIR="/opt/wg-easy"
WG_IMAGE="ghcr.io/wg-easy/wg-easy:15"
WG_UI_PORT="51821"                            # веб-панель wg-easy (только на loopback)
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-vps-setup.conf"

# Пин модуля AmneziaWG: PPA с 2026-07-30 отдаёт v3.0, ломающую wg-easy.
# Собираем последнюю v1.0 из git (полностью AWG-2.0-совместима).
AWG_MOD_TAG="v1.0.20260725"
AWG_MOD_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"

# Апстрим-движки MTProto (тянем последнюю версию на запуске — анти-DPI НЕ пинуют)
MTPROXYL_INSTALL_URL="https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh"
MEKO_REPO="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO.git"

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] [INFO ] $*"; }
skip() { echo "[$(ts)] [SKIP ] $*"; }
warn() { echo "[$(ts)] [WARN ] $*"; }
die()  { echo "[$(ts)] [ERROR] $*"; exit 1; }
trap 'echo "[$(ts)] [ERROR] Остановлено на строке $LINENO (команда: $BASH_COMMAND). Лог: $LOG_FILE"' ERR

apt_install() {
    local missing=() p
    for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && { skip "Пакеты уже стоят: $*"; return 0; }
    log "Ставлю: ${missing[*]}"; apt-get install -y "${missing[@]}"
}

deploy_file() {
    local dest="$1" mode="${2:-644}" tmp; tmp=$(mktemp); cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
    mkdir -p "$(dirname "$dest")"; mv "$tmp" "$dest"; chmod "$mode" "$dest"; return 0
}

is_host() { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }

# Скачать скрипт во временный файл, залогировать его SHA и выполнить (аудит вместо curl|bash)
run_remote() {   # run_remote <url> [args...]
    local url="$1"; shift
    local f; f=$(mktemp)
    curl -fsSL "$url" -o "$f" || die "Не удалось скачать $url"
    log "Загружен установщик $url  sha256=$(sha256sum "$f" | cut -c1-16)…"
    bash "$f" "$@"
    rm -f "$f"
}

# ------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
[[ -f /etc/os-release ]] || die "Нет /etc/os-release"
. /etc/os-release; OS_ID="${ID:-}"
case "$OS_ID" in ubuntu|debian) ;; *) die "Только Ubuntu/Debian (обнаружено: ${PRETTY_NAME:-$OS_ID})";; esac

log "=============================================================="
log "setup.sh (single-VPS: AWG VPN + MTProto engine) на ${PRETTY_NAME}"
log "=============================================================="

# ==============================================================================
# ШАГ 0. Вопросы
# ==============================================================================
[[ -f "$ANSWERS_FILE" ]] && { . "$ANSWERS_FILE"; log "Подставлены ответы прошлого запуска"; }

DEF_USER="${NEW_USER:-vpnadmin}"
DEF_PORT="${WG_PORT:-51820}"
DEF_HOST="${SERVER_HOST:-}"
DEF_CLOAK="${CLOAK_DOMAIN:-}"

echo ""; echo "================  НАСТРОЙКА (один VPS)  ================"

while true; do
    read -rp "Имя пользователя (вместо root) [${DEF_USER}]: " NEW_USER
    NEW_USER="${NEW_USER:-$DEF_USER}"
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    echo "  Строчные латинские буквы, цифры, '-', '_'."
done

while true; do
    if [[ -n "$DEF_HOST" ]]; then read -rp "Публичный IP/домен этого VPS [${DEF_HOST}]: " SERVER_HOST; SERVER_HOST="${SERVER_HOST:-$DEF_HOST}"
    else read -rp "Публичный IP/домен этого VPS: " SERVER_HOST; fi
    [[ -n "$SERVER_HOST" ]] && is_host "$SERVER_HOST" && break
    echo "  Латиница/цифры/точки/дефис."
done

# --- VPN? ---
[[ "${INSTALL_VPN:-yes}" == "no" ]] && DEF_VPN="N" || DEF_VPN="y"
read -rp "Ставить VPN (wg-easy + AmneziaWG)? [y/N] [${DEF_VPN}]: " v; v="${v:-$DEF_VPN}"
case "$v" in y|Y|yes|да|1) INSTALL_VPN=yes ;; *) INSTALL_VPN=no ;; esac
if [[ "$INSTALL_VPN" == "yes" ]]; then
    while true; do
        read -rp "Порт AmneziaWG (UDP) [${DEF_PORT}]: " WG_PORT; WG_PORT="${WG_PORT:-$DEF_PORT}"
        [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT>=1 && WG_PORT<=65535 )) && break
        echo "  Число 1..65535."
    done
fi

# --- Движок MTProto ---
echo ""
echo "MTProto-прокси (движок ставится СВЕЖИМ из апстрима на каждом запуске):"
echo "  1) MTProxyL — telemt + zapret2-десинк + PQ self-mask/cloak  (рекомендуется)"
echo "  2) MEKO     — MTPROTO_FIX_By_MEKO"
echo "  3) нет      — только VPN"
DEF_ENG="${ENGINE_N:-1}"
while true; do
    read -rp "Вариант [1/2/3] [${DEF_ENG}]: " ENGINE_N; ENGINE_N="${ENGINE_N:-$DEF_ENG}"
    case "$ENGINE_N" in
        1) ENGINE=mtproxyl; break ;;
        2) ENGINE=meko;     break ;;
        3) ENGINE=none;     break ;;
        *) echo "  1, 2 или 3." ;;
    esac
done

# --- Домен-прикрытие (self-SNI) для движка ---
CLOAK_DOMAIN="${CLOAK_DOMAIN:-}"
if [[ "$ENGINE" != "none" ]]; then
    echo ""
    echo "Домен-прикрытие / self-SNI для прокси (напр. cdn.example.com):"
    echo "  - A-запись -> ЭТОТ VPS, БЕЗ Cloudflare-прокси (серое облако / DNS-only)."
    echo "  - Движок обслуживает по нему сайт-заглушку и маскирует под него fake-TLS."
    echo "  - Проверьте пост-квантовость (@Sni_checker_bot) перед боем."
    while true; do
        if [[ -n "$DEF_CLOAK" ]]; then read -rp "Домен-прикрытие [${DEF_CLOAK}]: " v; v="${v:-$DEF_CLOAK}"
        else read -rp "Домен-прикрытие: " v; fi
        [[ -n "$v" ]] && is_host "$v" && { CLOAK_DOMAIN="$v"; break; }
        echo "  Латиница/цифры/точки/дефис."
    done
fi

# --- fail2ban whitelist ---
F2B_DETECTED=""; [[ -n "${SSH_CONNECTION:-}" ]] && F2B_DETECTED=$(awk '{print $1}' <<<"$SSH_CONNECTION")
echo ""
echo "fail2ban — чьи IP НЕ банить (Enter — ваш $F2B_DETECTED; 'no' — никого):"
DEF_WL="${F2B_IGNORE:-$F2B_DETECTED}"
read -rp "Whitelist [${DEF_WL:-no}]: " v; v="${v:-${DEF_WL:-no}}"
case "$v" in no|No|NO|нет|none) F2B_IGNORE="" ;; *) F2B_IGNORE="$v" ;; esac

deploy_file "$ANSWERS_FILE" 600 <<EOF >/dev/null || true
NEW_USER="$NEW_USER"
SERVER_HOST="$SERVER_HOST"
INSTALL_VPN="$INSTALL_VPN"
WG_PORT="${WG_PORT:-51820}"
ENGINE="$ENGINE"
ENGINE_N="$ENGINE_N"
CLOAK_DOMAIN="$CLOAK_DOMAIN"
F2B_IGNORE="$F2B_IGNORE"
EOF
log "Параметры: user=$NEW_USER host=$SERVER_HOST vpn=$INSTALL_VPN engine=$ENGINE cloak=${CLOAK_DOMAIN:-—}"

# ==============================================================================
# ШАГ 1..5. База: пакеты, пользователь, SSH, ufw, fail2ban
# ==============================================================================
log "--- Шаг 1: пакеты ---"
apt-get update
apt_install curl ca-certificates gnupg openssl sudo ufw fail2ban git

log "--- Шаг 2: пользователь $NEW_USER ---"
id -u "$NEW_USER" >/dev/null 2>&1 || { log "Создаю $NEW_USER"; useradd -m -s /bin/bash "$NEW_USER"; }
id -nG "$NEW_USER" | grep -qw sudo || usermod -aG sudo "$NEW_USER"
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6); KEYS_PRESENT=0
if [[ -s "$USER_HOME/.ssh/authorized_keys" ]]; then KEYS_PRESENT=1
elif [[ -s /root/.ssh/authorized_keys ]]; then
    mkdir -p "$USER_HOME/.ssh"; cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
    chmod 700 "$USER_HOME/.ssh"; chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"; KEYS_PRESENT=1
else warn "SSH-ключей нет — вход по паролю останется"; fi
PASS_STATUS=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' || true)
if [[ "$PASS_STATUS" != "P" ]]; then
    log "Задайте пароль для $NEW_USER"; until passwd "$NEW_USER"; do warn "ещё раз"; done
fi

log "--- Шаг 3: SSH hardening ---"
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true); SSH_PORT="${SSH_PORT:-22}"
(( KEYS_PRESENT )) && PASSWORD_AUTH="no" || { PASSWORD_AUTH="yes"; warn "Пароль-вход НЕ отключён (нет ключей)"; }
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
if deploy_file "$SSHD_DROPIN" 600 <<EOF
# setup.sh — не редактировать вручную
PermitRootLogin no
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 6
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
then
    sshd -t || die "Ошибка sshd_config — не применено"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
    warn "НЕ закрывайте сессию! Проверьте вход: ssh ${NEW_USER}@${SERVER_HOST}"
else skip "SSH уже настроен"; fi

log "--- Шаг 4: ufw ---"
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" >/dev/null && log "ufw: $SSH_PORT/tcp (SSH)"
# :443/tcp нужен ДВИЖКУ (fake-TLS). :80 — для выпуска сертификата движком.
if [[ "$ENGINE" != "none" ]]; then
    ufw allow 80/tcp  >/dev/null && log "ufw: 80/tcp"
    ufw allow 443/tcp >/dev/null && log "ufw: 443/tcp (движок MTProto)"
fi
[[ "$INSTALL_VPN" == "yes" ]] && { ufw allow "$WG_PORT/udp" >/dev/null && log "ufw: $WG_PORT/udp (AmneziaWG)"; }
ufw status | grep -q "Status: active" || { log "Включаю ufw"; ufw --force enable; }

log "--- Шаг 5: fail2ban ---"
apt_install python3-systemd
IGNORE_IPS="127.0.0.1/8 ::1"; [[ -n "${F2B_IGNORE:-}" ]] && IGNORE_IPS="$IGNORE_IPS $F2B_IGNORE"
if deploy_file /etc/fail2ban/jail.local 644 <<EOF
[DEFAULT]
backend = systemd
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
findtime = 10m
maxretry = 8
ignoreip = $IGNORE_IPS

[sshd]
enabled = true
port = $SSH_PORT
EOF
then systemctl restart fail2ban; fi
systemctl enable fail2ban >/dev/null 2>&1 || true

# ==============================================================================
# ШАГ 6. VPN: модуль AmneziaWG (пин v1.0 из git) + wg-easy
# ==============================================================================
if [[ "$INSTALL_VPN" == "yes" ]]; then
    log "--- Шаг 6: модуль AmneziaWG (пин $AWG_MOD_TAG) ---"
    if modinfo amneziawg >/dev/null 2>&1 && lsmod | grep -qw amneziawg; then
        skip "Модуль amneziawg уже загружен"
    else
        AWG_MOD_VER="${AWG_MOD_TAG#v}"
        apt_install dkms build-essential "linux-headers-$(uname -r)"
        apt-get remove -y amneziawg-dkms 2>/dev/null || true
        rm -rf /tmp/awg-km
        git clone --depth 1 --branch "$AWG_MOD_TAG" "$AWG_MOD_REPO" /tmp/awg-km
        AWG_SRC="/usr/src/amneziawg-$AWG_MOD_VER"
        rm -rf "$AWG_SRC"; cp -r /tmp/awg-km/src "$AWG_SRC"
        sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$AWG_MOD_VER\"/" "$AWG_SRC/dkms.conf"
        dkms add     -m amneziawg -v "$AWG_MOD_VER" 2>/dev/null || true
        dkms build   -m amneziawg -v "$AWG_MOD_VER" --force
        dkms install -m amneziawg -v "$AWG_MOD_VER" --force
        apt-mark hold amneziawg amneziawg-dkms 2>/dev/null || true
        modprobe amneziawg || die "modprobe amneziawg не удался — проверьте dkms status"
    fi
    deploy_file /etc/modules-load.d/amneziawg.conf 644 <<<"amneziawg" >/dev/null || true

    log "--- Шаг 7: Docker ---"
    command -v docker >/dev/null 2>&1 || { log "Ставлю Docker"; curl -fsSL https://get.docker.com | sh; }
    docker compose version >/dev/null 2>&1 || apt_install docker-compose-plugin
    systemctl enable --now docker >/dev/null 2>&1 || true

    log "--- Шаг 8: wg-easy (AmneziaWG). Панель ТОЛЬКО на 127.0.0.1:$WG_UI_PORT ---"
    mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
    ADMIN_USER="${ADMIN_USER:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)}"
    deploy_file "$WG_DIR/.env" 600 <<EOF >/dev/null || true
WG_PORT=$WG_PORT
INIT_HOST=$SERVER_HOST
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
    # Панель НЕ публикуется наружу: биндим на loopback, доступ по SSH-туннелю.
    # :443 не занимаем — он нужен MTProto-движку.
    deploy_file "$WG_DIR/docker-compose.yml" 600 <<'EOF'
volumes:
  etc_wireguard:
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      - INSECURE=true
      - EXPERIMENTAL_AWG=true
      - INIT_ENABLED=true
      - INIT_USERNAME=${ADMIN_USERNAME}
      - INIT_PASSWORD=${ADMIN_PASSWORD}
      - INIT_HOST=${INIT_HOST}
      - INIT_PORT=${WG_PORT}
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "127.0.0.1:51821:51821/tcp"
    restart: unless-stopped
    cap_add: [NET_ADMIN, SYS_MODULE]
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF
    ( cd "$WG_DIR" && docker compose pull && docker compose up -d )
    log "wg-easy поднят. Панель: SSH-туннель  ->  ssh -L 51821:127.0.0.1:51821 ${NEW_USER}@${SERVER_HOST}  ->  http://localhost:51821  ($ADMIN_USER / см. $WG_DIR/.env)"
fi

# ==============================================================================
# ШАГ 9. MTProto-движок (свежий из апстрима). Он владеет :443 + прикрытием.
# ==============================================================================
if [[ "$ENGINE" != "none" ]]; then
    command -v docker >/dev/null 2>&1 || { log "Ставлю Docker (нужен движку)"; curl -fsSL https://get.docker.com | sh; }
    echo ""
    log "--- Шаг 9: движок MTProto = $ENGINE (последняя версия) ---"
    echo ">>> Дальше запустится ИНТЕРАКТИВНЫЙ установщик движка."
    echo ">>> Указывайте: домен/self-mask = $CLOAK_DOMAIN, режим десинка (zapret2) ВКЛ."
    echo ""
    case "$ENGINE" in
        mtproxyl)
            run_remote "$MTPROXYL_INSTALL_URL"
            RESOLVED="MTProxyL@$(curl -fsSL https://api.github.com/repos/Liafanx/MTProxyL/commits/main 2>/dev/null | grep -oP '"sha":\s*"\K[0-9a-f]{7}' | head -1 || echo main)"
            ;;
        meko)
            rm -rf /opt/meko; git clone --depth 1 "$MEKO_REPO" /opt/meko
            RESOLVED="MEKO@$(git -C /opt/meko rev-parse --short HEAD)"
            ( cd /opt/meko && bash install.sh )
            ;;
    esac
    deploy_file "$INSTALLED_FILE" 600 <<EOF >/dev/null || true
ENGINE="$ENGINE"
ENGINE_VERSION="$RESOLVED"
INSTALLED_AT="$(ts)"
EOF
    log "Движок установлен: $RESOLVED (записано в $INSTALLED_FILE)"
fi

# ==============================================================================
# ИТОГ
# ==============================================================================
echo ""
echo "================  ГОТОВО  ================"
[[ "$INSTALL_VPN" == "yes" ]] && {
    echo " VPN (AmneziaWG):  порт $WG_PORT/udp, клиенты — в панели wg-easy"
    echo " Панель wg-easy:   ssh -L 51821:127.0.0.1:51821 ${NEW_USER}@${SERVER_HOST}  затем  http://localhost:51821"
}
[[ "$ENGINE" != "none" ]] && {
    echo " MTProto-движок:   $ENGINE (владеет :443, десинк + прикрытие $CLOAK_DOMAIN)"
    echo " Домен $CLOAK_DOMAIN -> A-запись на этот VPS, DNS-only (СЕРОЕ облако, НЕ Cloudflare-прокси!)"
    echo " Проверка маски:   отправьте $CLOAK_DOMAIN боту @Sni_checker_bot (должно быть PQ ✓)"
    echo " tg-ссылку выдаёт установщик движка (см. его вывод выше / его меню)."
}
echo " Лог: $LOG_FILE"
echo "=========================================="
