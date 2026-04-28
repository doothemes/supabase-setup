#!/usr/bin/env bash
#
# Supabase self-hosted uninstaller — Ubuntu 22.04 / 24.04
#
# Por defecto: detiene el stack, borra volúmenes Docker y elimina el directorio
# de instalación. Con flags opcionales también purga Caddy, Docker y reglas UFW.
#
# Uso: sudo ./uninstall.sh --help
#

set -euo pipefail

# ---------------------------------------------------------------- defaults ---
INSTALL_DIR="/opt/supabase"
KEEP_VOLUMES=0
PURGE_CADDY=0
PURGE_DOCKER=0
RESET_UFW=0
ASSUME_YES=0

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

usage() {
    cat <<EOF
Supabase self-hosted uninstaller (Ubuntu 22.04 / 24.04)

Uso: sudo $0 [opciones]

Por defecto detiene el stack, borra volúmenes Docker (¡pierdes los datos!)
y elimina $INSTALL_DIR. NO toca Caddy, Docker ni UFW salvo que lo pidas.

Opciones:
  --dir RUTA           Directorio a desinstalar (default: /opt/supabase).
  --keep-volumes       NO borrar los volúmenes Docker (conserva datos de Postgres
                       y archivos de Storage en el daemon Docker — útil si vas
                       a reinstalar y quieres conservar los datos).
  --purge-caddy        Desinstalar Caddy + borrar /etc/caddy y su repo apt.
  --purge-docker       Desinstalar Docker + borrar /var/lib/docker (¡borra
                       TODOS los contenedores e imágenes del servidor, no solo
                       Supabase!).
  --reset-ufw          Quitar reglas UFW de Supabase (8000/3000) y de Caddy
                       si se purgó (80/443). NO desactiva UFW.
  -y, --yes            No preguntar confirmación.
  -h, --help           Mostrar esta ayuda.

Ejemplos:
  # Borrar solo Supabase, conservar Caddy y Docker:
  sudo $0 -y

  # Borrar todo lo que el instalador puso:
  sudo $0 --purge-caddy --purge-docker --reset-ufw -y

  # Reinstalar conservando datos:
  sudo $0 --keep-volumes -y
  sudo ./setup.sh --domain ... --email ... -y
EOF
}

# ----------------------------------------------------------- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)            INSTALL_DIR="${2:-}"; shift 2 ;;
        --keep-volumes)   KEEP_VOLUMES=1; shift ;;
        --purge-caddy)    PURGE_CADDY=1;  shift ;;
        --purge-docker)   PURGE_DOCKER=1; shift ;;
        --reset-ufw)      RESET_UFW=1;    shift ;;
        -y|--yes)         ASSUME_YES=1;   shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "Opción desconocida: $1 (usa --help)" ;;
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

echo
warn "Vas a desinstalar Supabase de este servidor."
echo "  Directorio:        $INSTALL_DIR"
if [[ $KEEP_VOLUMES -eq 1 ]]; then
    echo "  Volúmenes Docker:  ${C_GRN}se conservan${C_RST} (--keep-volumes)"
else
    echo "  Volúmenes Docker:  ${C_RED}BORRADOS${C_RST} (todos los datos de Postgres y Storage)"
fi
echo "  Caddy:             $([[ $PURGE_CADDY  -eq 1 ]] && echo "${C_RED}desinstalar${C_RST}" || echo "conservar")"
echo "  Docker:            $([[ $PURGE_DOCKER -eq 1 ]] && echo "${C_RED}desinstalar (afecta a TODO Docker)${C_RST}" || echo "conservar")"
echo "  Reglas UFW:        $([[ $RESET_UFW    -eq 1 ]] && echo "quitar las añadidas por setup.sh" || echo "conservar")"
echo

confirm "${C_YLW}¿Confirmas que quieres continuar? Esta acción es IRREVERSIBLE.${C_RST}" \
    || die "Cancelado por el usuario."

# ============================================================================
# 1. Detener el stack y borrar el directorio
# ============================================================================
if [[ -d "$INSTALL_DIR" ]]; then
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
        log "Deteniendo el stack..."
        if [[ $KEEP_VOLUMES -eq 1 ]]; then
            (cd "$INSTALL_DIR" && docker compose down) || warn "docker compose down falló (continuando)"
        else
            (cd "$INSTALL_DIR" && docker compose down -v) || warn "docker compose down -v falló (continuando)"
        fi
        ok "Stack detenido."
    else
        warn "$INSTALL_DIR no parece tener docker-compose.yml o docker no está instalado — saltando 'compose down'."
    fi

    log "Borrando $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    ok "$INSTALL_DIR eliminado."
else
    warn "$INSTALL_DIR no existe — nada que borrar."
fi

# ============================================================================
# 2. Caddy
# ============================================================================
if [[ $PURGE_CADDY -eq 1 ]]; then
    if command -v caddy >/dev/null 2>&1 || [[ -f /etc/caddy/Caddyfile ]]; then
        log "Desinstalando Caddy..."
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        export NEEDRESTART_SUSPEND=1
        APT_OPTS=(-y -q -o Dpkg::Use-Pty=0)
        systemctl disable --now caddy 2>/dev/null || true
        apt-get remove --purge "${APT_OPTS[@]}" caddy 2>/dev/null || true
        rm -rf /etc/caddy
        rm -f /etc/apt/sources.list.d/caddy-stable.list
        rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        apt-get autoremove "${APT_OPTS[@]}" 2>/dev/null || true
        ok "Caddy desinstalado."
    else
        warn "Caddy no está instalado — saltando."
    fi
fi

# ============================================================================
# 3. Docker
# ============================================================================
if [[ $PURGE_DOCKER -eq 1 ]]; then
    if command -v docker >/dev/null 2>&1; then
        warn "Esto desinstala Docker entero — ${C_RED}TODOS los contenedores e imágenes del servidor desaparecen${C_RST}, no solo los de Supabase."
        confirm "¿Seguro?" || { warn "Saltando purga de Docker."; PURGE_DOCKER=0; }
    fi

    if [[ $PURGE_DOCKER -eq 1 ]] && command -v docker >/dev/null 2>&1; then
        log "Desinstalando Docker..."
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        export NEEDRESTART_SUSPEND=1
        APT_OPTS=(-y -q -o Dpkg::Use-Pty=0)
        systemctl disable --now docker 2>/dev/null || true
        systemctl disable --now docker.socket 2>/dev/null || true
        systemctl disable --now containerd 2>/dev/null || true
        apt-get remove --purge "${APT_OPTS[@]}" \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
            2>/dev/null || true
        rm -rf /var/lib/docker /var/lib/containerd
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
        apt-get autoremove "${APT_OPTS[@]}" 2>/dev/null || true
        ok "Docker desinstalado."
    fi
fi

# ============================================================================
# 4. UFW
# ============================================================================
if [[ $RESET_UFW -eq 1 ]]; then
    if command -v ufw >/dev/null 2>&1; then
        log "Quitando reglas UFW del instalador..."
        ufw delete allow 8000/tcp >/dev/null 2>&1 || true
        ufw delete allow 3000/tcp >/dev/null 2>&1 || true
        if [[ $PURGE_CADDY -eq 1 ]]; then
            ufw delete allow 80/tcp  >/dev/null 2>&1 || true
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi
        ok "Reglas UFW eliminadas (UFW sigue activo, conserva tus otras reglas)."
    else
        warn "UFW no está instalado — saltando."
    fi
fi

echo
ok "Desinstalación completa."
echo
if [[ $KEEP_VOLUMES -eq 1 ]]; then
    echo "  ${C_DIM}Los volúmenes Docker se conservaron. Para verlos:${C_RST}"
    echo "  ${C_DIM}    docker volume ls | grep supabase${C_RST}"
fi
