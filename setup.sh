#!/usr/bin/env bash
#
# Supabase self-hosted installer — Ubuntu 22.04 / 24.04
#
# Instala Docker, clona supabase/supabase, genera secretos seguros en .env,
# levanta el stack con docker compose y opcionalmente configura Caddy como
# reverse proxy con Let's Encrypt automático.
#
# Uso: sudo ./setup.sh --help
#

set -euo pipefail

# ---------------------------------------------------------------- defaults ---
INSTALL_DIR="/opt/supabase"
DOMAIN=""
EMAIL=""
USE_TLS=1
USE_UFW=1
ASSUME_YES=0
FORCE=0

# ------------------------------------------------------------------ colors ---
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

trap 'rc=$?; die "Falló en línea $LINENO (exit $rc): $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Supabase self-hosted installer (Ubuntu 22.04 / 24.04)

Uso: sudo $0 [opciones]

Opciones:
  --domain DOMINIO     Dominio público (ej. supabase.tudominio.com).
                       Si se pasa, instala Caddy + Let's Encrypt automático.
  --email  EMAIL       Email para Let's Encrypt (requerido con --domain).
  --no-tls             No instalar reverse proxy. Expone Kong en :8000 y
                       Studio en :3000 directamente sobre la IP del servidor.
  --no-ufw             No tocar UFW.
  --dir    RUTA        Directorio de instalación (default: /opt/supabase).
  --force              Sobrescribir instalación existente (destructivo).
  -y, --yes            No preguntar, aceptar todo.
  -h, --help           Mostrar esta ayuda.

Ejemplos:
  # Producción con dominio + SSL automático:
  sudo $0 --domain supabase.midominio.com --email admin@midominio.com -y

  # Lab interno, sin dominio:
  sudo $0 --no-tls -y
EOF
}

# ----------------------------------------------------------- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)  DOMAIN="${2:-}"; shift 2 ;;
        --email)   EMAIL="${2:-}";  shift 2 ;;
        --no-tls)  USE_TLS=0; shift ;;
        --no-ufw)  USE_UFW=0; shift ;;
        --dir)     INSTALL_DIR="${2:-}"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        -y|--yes)  ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         die "Opción desconocida: $1 (usa --help)" ;;
    esac
done

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local prompt="$1" reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[yY]$ ]]
}

# ------------------------------------------------------------- pre-flight ---
[[ $EUID -eq 0 ]] || die "Este script debe ejecutarse como root (usa sudo)."

[[ -f /etc/os-release ]] || die "No se encontró /etc/os-release."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Solo soportado en Ubuntu (detectado: ${ID:-?})."
case "${VERSION_ID:-}" in
    22.04|24.04) ok "Ubuntu ${VERSION_ID} (${VERSION_CODENAME}) detectado." ;;
    *) die "Versión Ubuntu no soportada: ${VERSION_ID:-?} (solo 22.04 y 24.04)." ;;
esac

if [[ $USE_TLS -eq 1 ]]; then
    [[ -n "$DOMAIN" ]] || die "Falta --domain (usa --no-tls si no quieres SSL/dominio)."
    [[ -n "$EMAIL"  ]] || die "Falta --email (necesario para Let's Encrypt)."
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Dominio inválido: $DOMAIN"
    [[ "$EMAIL"  =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
        || die "Email inválido: $EMAIL"
fi

if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/.env" && $FORCE -eq 0 ]]; then
    die "Ya existe una instalación en $INSTALL_DIR. Usa --force para sobrescribir."
fi

# --------------------------------------------------------------- helpers ---
b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

gen_secret() {
    # genera una cadena alfanumérica de longitud $1.
    # Evitamos `tr </dev/urandom | head -c N` porque head cierra el pipe
    # temprano y tr recibe SIGPIPE → con `set -o pipefail` el script aborta.
    local len="${1:-32}"
    local out
    out=$(openssl rand -base64 $((len * 2)) | LC_ALL=C tr -dc 'A-Za-z0-9')
    printf '%s' "${out:0:$len}"
}

gen_hex() { openssl rand -hex "${1:-32}"; }

gen_jwt() {
    # gen_jwt <role> <secret>  → JWT firmado HS256 con exp a 10 años
    local role="$1" secret="$2"
    local iat exp header payload h p sig
    iat=$(date +%s)
    exp=$((iat + 315360000))
    header='{"alg":"HS256","typ":"JWT"}'
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$role" "$iat" "$exp")
    h=$(printf '%s' "$header"  | b64url)
    p=$(printf '%s' "$payload" | b64url)
    sig=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)
    printf '%s.%s.%s' "$h" "$p" "$sig"
}

set_env() {
    # set_env KEY VALUE FILE — reemplaza línea KEY=... o la añade. Safe ante
    # caracteres especiales (no usa sed sobre el valor).
    local key="$1" val="$2" file="$3" tmp
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
        BEGIN { found = 0 }
        $0 ~ "^"k"=" { print k"="v; found = 1; next }
        { print }
        END { if (!found) print k"="v }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ============================================================================
# 1. Dependencias del sistema
# ============================================================================
log "Actualizando apt e instalando dependencias del sistema..."

# Silenciar todos los prompts de apt/dpkg/needrestart (Ubuntu 24.04 lanza un
# menú TUI por needrestart al instalar paquetes que tocan servicios — sin
# estas vars el script se queda atorado esperando input).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
APT_OPTS=(
    -y -q
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Dpkg::Use-Pty=0
)

apt-get update -q
apt-get install "${APT_OPTS[@]}" --no-install-recommends \
    curl ca-certificates gnupg lsb-release git openssl jq ufw \
    apt-transport-https dnsutils
ok "Dependencias instaladas."

# ============================================================================
# 2. Docker Engine + Compose plugin
# ============================================================================
if ! command -v docker >/dev/null 2>&1; then
    log "Instalando Docker desde el repositorio oficial..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install "${APT_OPTS[@]}" \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker instalado: $(docker --version)"
else
    ok "Docker ya estaba instalado: $(docker --version)"
fi
docker compose version >/dev/null 2>&1 \
    || die "El plugin docker compose no está disponible."

# ============================================================================
# 3. Verificar DNS si vamos a emitir cert
# ============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ $USE_TLS -eq 1 ]]; then
    DNS_IP=$(dig +short +time=3 +tries=1 "$DOMAIN" A | tail -n1 || true)
    if [[ -z "$DNS_IP" ]]; then
        warn "No se resolvió $DOMAIN. Caddy reintentará el certificado cuando el DNS propague."
        confirm "¿Continuar de todas formas?" || die "Cancelado por el usuario."
    elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
        warn "$DOMAIN apunta a $DNS_IP, pero este servidor tiene IP $SERVER_IP."
        warn "Let's Encrypt fallará hasta que el DNS apunte correctamente."
        confirm "¿Continuar de todas formas?" || die "Cancelado por el usuario."
    else
        ok "DNS de $DOMAIN apunta correctamente a $SERVER_IP."
    fi
fi

# ============================================================================
# 4. Clonar supabase/supabase y preparar directorio
# ============================================================================
log "Preparando $INSTALL_DIR..."
if [[ -d "$INSTALL_DIR" && $FORCE -eq 1 ]]; then
    warn "--force: deteniendo y eliminando instalación previa en $INSTALL_DIR"
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        (cd "$INSTALL_DIR" && docker compose down -v) || true
    fi
    rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR"
TMP_CLONE=$(mktemp -d)
log "Clonando supabase/supabase (shallow)..."
git clone --quiet --depth 1 https://github.com/supabase/supabase "$TMP_CLONE/supabase"
cp -rf "$TMP_CLONE/supabase/docker/." "$INSTALL_DIR/"
cp "$TMP_CLONE/supabase/docker/.env.example" "$INSTALL_DIR/.env"
rm -rf "$TMP_CLONE"
ok "Stack copiado a $INSTALL_DIR."

# ============================================================================
# 5. Generar secretos en .env
# ============================================================================
log "Generando secretos y poblando .env..."
ENV_FILE="$INSTALL_DIR/.env"

POSTGRES_PASSWORD=$(gen_secret 32)
JWT_SECRET=$(gen_secret 48)
SECRET_KEY_BASE=$(gen_hex 32)
VAULT_ENC_KEY=$(gen_secret 32)
DASHBOARD_PASSWORD=$(gen_secret 24)
POOLER_TENANT_ID=$(gen_secret 12 | tr '[:upper:]' '[:lower:]')
ANON_KEY=$(gen_jwt anon "$JWT_SECRET")
SERVICE_ROLE_KEY=$(gen_jwt service_role "$JWT_SECRET")

if [[ $USE_TLS -eq 1 ]]; then
    PUBLIC_URL="https://$DOMAIN"
    STUDIO_URL="https://$DOMAIN"
else
    PUBLIC_URL="http://${SERVER_IP}:8000"
    STUDIO_URL="http://${SERVER_IP}:3000"
fi

set_env POSTGRES_PASSWORD   "$POSTGRES_PASSWORD"   "$ENV_FILE"
set_env JWT_SECRET          "$JWT_SECRET"          "$ENV_FILE"
set_env ANON_KEY            "$ANON_KEY"            "$ENV_FILE"
set_env SERVICE_ROLE_KEY    "$SERVICE_ROLE_KEY"    "$ENV_FILE"
set_env DASHBOARD_USERNAME  "admin"                "$ENV_FILE"
set_env DASHBOARD_PASSWORD  "$DASHBOARD_PASSWORD"  "$ENV_FILE"
set_env SECRET_KEY_BASE     "$SECRET_KEY_BASE"     "$ENV_FILE"
set_env VAULT_ENC_KEY       "$VAULT_ENC_KEY"       "$ENV_FILE"
set_env POOLER_TENANT_ID    "$POOLER_TENANT_ID"    "$ENV_FILE"
set_env API_EXTERNAL_URL    "$PUBLIC_URL"          "$ENV_FILE"
set_env SUPABASE_PUBLIC_URL "$PUBLIC_URL"          "$ENV_FILE"
set_env SITE_URL            "$STUDIO_URL"          "$ENV_FILE"

chmod 600 "$ENV_FILE"
ok ".env generado (permisos 600)."

# ============================================================================
# 6. docker-compose.override.yml — bind a localhost cuando hay reverse proxy
# ============================================================================
# Docker manipula iptables y se salta UFW: si publicamos 0.0.0.0:8000 quedaría
# expuesto al mundo aunque UFW lo "bloquee". Con reverse proxy bindeamos solo
# a 127.0.0.1 para que únicamente Caddy llegue.
if [[ $USE_TLS -eq 1 ]]; then
    cat > "$INSTALL_DIR/docker-compose.override.yml" <<'EOF'
# Generado por setup.sh — bindeo a localhost cuando hay reverse proxy delante.
services:
    kong:
        ports:
            - "127.0.0.1:8000:8000/tcp"
            - "127.0.0.1:8443:8443/tcp"
    studio:
        ports:
            - "127.0.0.1:3000:3000/tcp"
EOF
    ok "docker-compose.override.yml escrito (puertos solo localhost)."
fi

# ============================================================================
# 7. Caddy reverse proxy + Let's Encrypt
# ============================================================================
if [[ $USE_TLS -eq 1 ]]; then
    # Detectar si 80/443 ya están ocupados por otro servicio (nginx, apache,
    # un proxy custom). Caddy no podrá arrancar si están en uso.
    BUSY_PORTS=()
    for port in 80 443; do
        if ss -ltnH "sport = :$port" 2>/dev/null | grep -q LISTEN; then
            BUSY_PORTS+=("$port")
        fi
    done
    if (( ${#BUSY_PORTS[@]} > 0 )); then
        warn "Puertos en uso por otro proceso: ${BUSY_PORTS[*]}"
        warn "Detalle:"
        ss -ltnp '( sport = :80 or sport = :443 )' 2>&1 | sed 's/^/    /' >&2
        warn "Caddy no podrá iniciar hasta que liberes esos puertos."
        warn "Opciones: detener el otro servicio, o reinstalar con --no-tls"
        warn "y poner Caddy/Nginx existente delante manualmente."
        confirm "¿Continuar de todas formas?" || die "Cancelado por el usuario."
    fi

    if ! command -v caddy >/dev/null 2>&1; then
        log "Instalando Caddy..."
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -q
        apt-get install "${APT_OPTS[@]}" caddy
    fi

    log "Configurando /etc/caddy/Caddyfile..."
    cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
}

$DOMAIN {
    encode zstd gzip

    # Endpoints expuestos por Kong (REST, Auth, Realtime, Storage, Functions, GraphQL, pg-meta)
    @api path /auth/* /rest/* /realtime/* /storage/* /functions/* /pg/* /graphql/v1*
    handle @api {
        reverse_proxy 127.0.0.1:8000
    }

    # Todo lo demás → Studio (dashboard)
    handle {
        reverse_proxy 127.0.0.1:3000
    }
}
EOF

    # Validar el Caddyfile antes de intentar arrancar — error temprano y claro.
    if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1; then
        die "Caddyfile inválido. Revisa el error arriba."
    fi

    systemctl enable caddy >/dev/null 2>&1 || true
    if ! systemctl restart caddy; then
        warn "Caddy no arrancó. Logs del servicio:"
        journalctl -xeu caddy.service --no-pager -n 40 2>&1 | sed 's/^/    /' >&2 || true
        warn "Puertos ocupados:"
        ss -ltnp '( sport = :80 or sport = :443 )' 2>&1 | sed 's/^/    /' >&2 || true
        die "Caddy falló al iniciar. Causas comunes: puerto 80/443 ocupado por otro servicio (nginx, apache, ...) o DNS no propaga aún."
    fi
    ok "Caddy activo. Let's Encrypt emitirá el cert al primer request a https://$DOMAIN."
fi

# ============================================================================
# 8. UFW
# ============================================================================
if [[ $USE_UFW -eq 1 ]]; then
    log "Configurando UFW..."
    if ! ufw status | grep -q "Status: active"; then
        ufw default deny incoming  >/dev/null
        ufw default allow outgoing >/dev/null
    fi
    ufw allow 22/tcp >/dev/null
    if [[ $USE_TLS -eq 1 ]]; then
        ufw allow 80/tcp  >/dev/null
        ufw allow 443/tcp >/dev/null
    else
        ufw allow 8000/tcp >/dev/null
        ufw allow 3000/tcp >/dev/null
    fi
    ufw --force enable >/dev/null
    ok "UFW activo."
fi

# ============================================================================
# 9. Levantar el stack
# ============================================================================
log "Descargando imágenes (puede tardar varios minutos)..."
cd "$INSTALL_DIR"
docker compose pull --quiet
log "Arrancando servicios..."
docker compose up -d
ok "Stack arrancado."

log "Esperando 20s antes de mostrar el estado..."
sleep 20
docker compose ps

# ============================================================================
# 10. Guardar credenciales
# ============================================================================
CREDS_FILE="$INSTALL_DIR/credentials.txt"
cat > "$CREDS_FILE" <<EOF
# ============================================================================
# Supabase — credenciales generadas
# Host:    $(hostname -f 2>/dev/null || hostname)
# Fecha:   $(date -Iseconds)
# Dir:     $INSTALL_DIR
# ============================================================================

Studio (dashboard):     $STUDIO_URL
Public API URL:         $PUBLIC_URL

Studio user:            admin
Studio password:        $DASHBOARD_PASSWORD

Postgres password:      $POSTGRES_PASSWORD
JWT secret:             $JWT_SECRET

ANON_KEY:
$ANON_KEY

SERVICE_ROLE_KEY:
$SERVICE_ROLE_KEY

Vault encryption key:   $VAULT_ENC_KEY
Realtime SECRET_KEY_BASE:
$SECRET_KEY_BASE
Pooler tenant id:       $POOLER_TENANT_ID

# ----------------------------------------------------------------------------
# Comandos útiles (ejecutar dentro de $INSTALL_DIR):
#   docker compose ps                       # estado
#   docker compose logs -f kong             # logs de un servicio
#   docker compose restart                  # reiniciar todo
#   docker compose down                     # detener
#   docker compose pull && docker compose up -d   # actualizar
# ----------------------------------------------------------------------------
EOF
chmod 600 "$CREDS_FILE"

# ============================================================================
# Resumen final
# ============================================================================
echo
ok "Instalación completa."
echo
echo "  Studio:        $STUDIO_URL"
echo "  Usuario:       admin"
echo "  Contraseña:    $DASHBOARD_PASSWORD"
echo
echo "  ANON_KEY:"
echo "    $ANON_KEY"
echo
echo "  Credenciales completas: $CREDS_FILE  ${C_DIM}(chmod 600)${C_RST}"
echo "  ${C_YLW}Guárdalas en un manager seguro y considera borrar el archivo después.${C_RST}"
echo
if [[ $USE_TLS -eq 1 ]]; then
    echo "  ${C_DIM}Si DNS aún no propaga, espera un par de minutos y refresca https://$DOMAIN${C_RST}"
fi
