#!/usr/bin/env bash
# =============================================================================
# install-postgres18.sh
# PostgreSQL 18 + observabilidad + pgAdmin en CentOS Stream 10 / RHEL 10
# Instalacion 100% nativa (dnf + systemd). Sin Docker ni Podman.
#
# PENSADO PARA SERVIDORES DONDE YA CORRE OTRO SISTEMA
#   - No borra ni sobrescribe nada existente. Todo lo que se cambia se respalda.
#   - No usa initdb si ya hay un cluster en /var/lib/pgsql/18/data, y en ese caso
#     tampoco toca su postgresql.conf, pg_hba.conf ni su servicio.
#   - No deshabilita modulos de dnf ni toca otras versiones de PostgreSQL.
#   - Observabilidad aislada: usuario 'pgobs', binarios en /opt/pgobs, unidades
#     'pgobs-exporter' y 'pgobs-prometheus', rol de BD 'pgobs_monitor' (solo lectura).
#     Nada se comparte con un Prometheus/exporter que ya exista.
#   - Si ya hay un Grafana instalado, se respeta su puerto y configuracion (no se
#     reinicia); solo se agrega un datasource (no default) y un dashboard.
#   - Si Apache (httpd) ya esta activo, pgAdmin web se OMITE (agregaria /pgadmin4
#     a todos sus sitios) salvo que use --force-pgadmin.
#   - Si un puerto necesario esta ocupado, ese componente se omite sin tocar nada.
#   - Firewall: solo AGREGA puertos. Jamas hace reset ni quita reglas.
#   - Antes de cambiar algo guarda una foto del estado en /root/preinstall-snapshot-*.
#
# USO:
#   sudo bash install-postgres18.sh [opciones]
#
# OPCIONES (tambien se pueden pasar como variables de entorno).
# Si no se indican y hay terminal, el script PREGUNTA puerto, acceso remoto e IPs permitidas.
#
#  Puerto y acceso remoto a la base de datos
#   --pg-port N            Puerto de PostgreSQL (def: 5432)
#   --remote               Permite conexiones remotas: listen_addresses='*', reglas en pg_hba.conf,
#                          SSL y apertura del puerto en el firewall, todo de una vez
#   --allow-cidr LISTA     IPs o redes permitidas, separadas por coma (ej: 190.1.2.3,10.0.0.0/24).
#                          Sin lista, --remote permite CUALQUIER IP (exige una clave propia).
#                          Tambien limita el origen de los puertos que se abren (pgAdmin, Grafana)
#   --no-ssl-required      Acepta conexiones remotas sin cifrar (pg_hba 'host' en vez de 'hostssl')
#   --block-postgres-remote  El superusuario 'postgres' solo entra desde este servidor (la aplicacion
#                          usa el usuario 'jema')
#   --listen DIRS          listen_addresses explicito (def: localhost; distinto de localhost = --remote)
#   --local-only           Solo conexiones desde este servidor (no pregunta)
#   --configure-existing   Aplica puerto / acceso remoto / rendimiento a un cluster que YA existe:
#                          respalda, reinicia PostgreSQL y revierte solo si no arranca
#
#  Usuario y bases de la aplicacion (siempre en minusculas)
#   --app-user NOMBRE      Usuario con login para la aplicacion (def: jema)
#   --app-db LISTA         Bases del usuario, separadas por coma (def: jema; se pregunta).
#                          Si no existe se crea con el usuario como dueno; si YA existe se le dan
#                          permisos completos (tablas, secuencias, funciones y las futuras)
#   --app-owner            En bases existentes, ademas traspasa al usuario la propiedad de la base
#                          y de sus objetos (para que la aplicacion pueda hacer ALTER TABLE, etc.)
#   --app-password CLAVE   Clave del usuario (def: la clave de administracion; variable APP_PASSWORD)
#   --no-app-user          No crea el usuario de la aplicacion
#
#  Rendimiento
#   --tune / --no-tune     Ajusta memoria y paralelismo segun RAM y CPU (def: si, en cluster nuevo)
#   --max-connections N    (def: 100)
#   --ram-mb N             RAM a considerar en MB (def: la del servidor; util si comparte con otro sistema)
#   --no-pg-stat-statements  No activa pg_stat_statements (estadisticas de consultas)
#
#  Firewall
#   --open-pg              Abre el puerto de PostgreSQL aunque no use --remote
#   --open-pgadmin         Abre en firewall el puerto de pgAdmin   (def: no)
#   --open-observability   Abre en firewall el puerto de Grafana   (def: no)
#   --open-all             Abre PostgreSQL + Grafana + pgAdmin
#   --extra-ports LISTA    Puertos adicionales a abrir, separados por coma (ej: 8080,9000)
#   --enable-firewall      Si firewalld esta inactivo, lo activa (permitiendo antes SSH)
#
#  Componentes opcionales
#   --with-observability   Instala postgres_exporter + Prometheus + Grafana
#   --with-pgadmin         Instala pgAdmin 4 (modo web, via Apache httpd)
#   --all                  Equivale a las dos anteriores
#   --grafana-port N       (def: 3000)
#   --prometheus-port N    (def: 9090, solo localhost)
#   --exporter-port N      (def: 9187, solo localhost)
#   --pgadmin-port N       (def: 5050)  URL: http://IP:PUERTO/pgadmin4
#   --pgadmin-email E      (def: admin@example.com)
#   --force-pgadmin        Instala pgAdmin aunque httpd ya este activo (afecta a sus sitios)
#
#  General
#   --password CLAVE       Clave de administracion para postgres (si el cluster es nuevo),
#                          pgAdmin y Grafana (si se instala nuevo). Def: Jema2026#
#                          (tambien por variable ADMIN_PASSWORD, que evita dejarla en el historial)
#                          Si no la indica y hay terminal, el script le pregunta: Enter = Jema2026#
#   --yes                  No preguntar nada (usa los valores por defecto u opciones dadas)
#   --dry-run              Muestra lo que haria sin ejecutar
#   -h | --help
#
# EJEMPLOS:
#   sudo bash install-postgres18.sh --pg-port 5433 --remote --allow-cidr 190.1.2.3 \
#        --app-db erp_db_biovenezuela --app-owner --block-postgres-remote
#   sudo bash install-postgres18.sh --configure-existing --remote     # cluster ya instalado
# =============================================================================
set -Eeuo pipefail

# ----------------------------- Configuracion ---------------------------------
PG_VERSION="${PG_VERSION:-18}"
PG_PORT="${PG_PORT:-5432}"
PG_LISTEN="${PG_LISTEN:-localhost}"
ALLOW_CIDR="${ALLOW_CIDR:-}"
WITH_OBS="${WITH_OBS:-0}"
WITH_PGADMIN="${WITH_PGADMIN:-0}"
FORCE_PGADMIN="${FORCE_PGADMIN:-0}"
DEFAULT_PASS='Jema2026#'
ADMIN_PASS="${ADMIN_PASSWORD:-$DEFAULT_PASS}"
PASS_GIVEN=0; [[ -n "${ADMIN_PASSWORD:-}" ]] && PASS_GIVEN=1
NO_PROMPT=0
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
EXPORTER_PORT="${EXPORTER_PORT:-9187}"
PGADMIN_PORT="${PGADMIN_PORT:-5050}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-admin@example.com}"
OPEN_OBS="${OPEN_OBS:-0}"
OPEN_PGADMIN="${OPEN_PGADMIN:-0}"
OPEN_PG="${OPEN_PG:-0}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
DRY_RUN="${DRY_RUN:-0}"
REMOTE="${REMOTE:-}"                     # vacio = preguntar
HBA_TYPE="${HBA_TYPE:-hostssl}"
BLOCK_PG_REMOTE="${BLOCK_PG_REMOTE:-0}"
CONFIGURE_EXISTING="${CONFIGURE_EXISTING:-0}"
TUNE="${TUNE:-}"                         # vacio = solo en cluster nuevo
MAX_CONN="${MAX_CONN:-100}"
RAM_MB="${RAM_MB:-}"
PGSS="${PGSS:-1}"
APP_USER="${APP_USER-jema}"             # vacio = no crear (--no-app-user)
APP_DB="${APP_DB:-}"                     # vacio = preguntar (def: jema)
APP_PASS="${APP_PASSWORD:-}"            # vacio = la clave de administracion
APP_PASS_GIVEN=0; [[ -n "$APP_PASS" ]] && APP_PASS_GIVEN=1
APP_OWNER="${APP_OWNER:-}"
ENABLE_FW="${ENABLE_FW:-0}"
PORT_GIVEN=0

PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
PGBIN="/usr/pgsql-${PG_VERSION}/bin"
SVC="postgresql-${PG_VERSION}"
SCRIPT_NAME="install-postgres18.sh"
PG_CONF_FILE="${PGDATA}/postgresql.conf"
CONFD="${PGDATA}/conf.d"
HBA_FILE="${PGDATA}/pg_hba.conf"
SSL_DIR="${PGDATA}"
STAMP="$(date +%Y%m%d-%H%M%S)"
CRED_FILE="/root/.postgres${PG_VERSION}-credentials"
LOG_FILE="/var/log/install-postgres${PG_VERSION}-${STAMP}.log"
SNAP_DIR="/root/preinstall-snapshot-${STAMP}"
OBS_DIR="/opt/pgobs"
OBS_USER="pgobs"
MON_ROLE="pgobs_monitor"
FW_CHANGED=0
PG_UP=1
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----------------------------- Utilidades ------------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_ok}[+]${c_off} $*"; }
warn() { echo "${c_warn}[!]${c_off} $*"; }
die()  { echo "${c_err}[x]${c_off} $*" >&2; exit 1; }
run()  { if [[ "$DRY_RUN" == 1 ]]; then echo "DRY: $*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
gen_pass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-20; }
psql_pg() { runuser -u postgres -- "${PGBIN}/psql" -p "$PG_PORT" "$@"; }
selinux_on() { have getenforce && [[ "$(getenforce)" != "Disabled" ]]; }

backup() { # respalda un archivo si existe
  local f="$1"
  if [[ -f "$f" ]]; then run cp -a "$f" "${f}.bak-${STAMP}"; info "Respaldo: ${f}.bak-${STAMP}"; fi
  return 0
}

in_list() { local x="$1"; shift; local y; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }
port_in_use() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

usage() {
  if [[ -f "$0" ]]; then awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"
  else echo "Ayuda completa: https://github.com/eldescabellado/installposgretsql#readme"; fi
  exit 0
}

# ----------------------------- Argumentos ------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pg-port) PG_PORT="$2"; PORT_GIVEN=1; shift 2;;
    --listen) PG_LISTEN="$2"; shift 2;;
    --remote|--acceso-remoto) REMOTE=1; shift;;
    --local-only) REMOTE=0; shift;;
    --allow-cidr|--allow-ip) ALLOW_CIDR="${ALLOW_CIDR:+${ALLOW_CIDR},}$2"; shift 2;;
    --no-ssl-required) HBA_TYPE=host; shift;;
    --block-postgres-remote) BLOCK_PG_REMOTE=1; shift;;
    --configure-existing|--reconfigurar) CONFIGURE_EXISTING=1; shift;;
    --tune) TUNE=1; shift;;
    --no-tune) TUNE=0; shift;;
    --max-connections) MAX_CONN="$2"; shift 2;;
    --ram-mb) RAM_MB="$2"; shift 2;;
    --no-pg-stat-statements) PGSS=0; shift;;
    --app-user) APP_USER="$2"; shift 2;;
    --app-db) APP_DB="$2"; shift 2;;
    --app-password) APP_PASS="$2"; APP_PASS_GIVEN=1; shift 2;;
    --app-owner) APP_OWNER=1; shift;;
    --no-app-user) APP_USER=""; shift;;
    --enable-firewall) ENABLE_FW=1; shift;;
    --with-observability) WITH_OBS=1; shift;;
    --with-pgadmin) WITH_PGADMIN=1; shift;;
    --all) WITH_OBS=1; WITH_PGADMIN=1; shift;;
    --grafana-port) GRAFANA_PORT="$2"; shift 2;;
    --prometheus-port) PROMETHEUS_PORT="$2"; shift 2;;
    --exporter-port) EXPORTER_PORT="$2"; shift 2;;
    --pgadmin-port) PGADMIN_PORT="$2"; shift 2;;
    --pgadmin-email) PGADMIN_EMAIL="$2"; shift 2;;
    --force-pgadmin) FORCE_PGADMIN=1; shift;;
    --password) ADMIN_PASS="$2"; PASS_GIVEN=1; shift 2;;
    --yes|-y) NO_PROMPT=1; shift;;
    --open-observability) OPEN_OBS=1; shift;;
    --open-pgadmin) OPEN_PGADMIN=1; shift;;
    --open-pg) OPEN_PG=1; shift;;
    --open-all) OPEN_PG=1; OPEN_OBS=1; OPEN_PGADMIN=1; shift;;
    --extra-ports) EXTRA_PORTS="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    *) die "Opcion desconocida: $1 (use --help)";;
  esac
done

# ----------------------------- Pre-chequeos ----------------------------------
[[ $EUID -eq 0 ]] || die "Ejecute como root (sudo)."
[[ -r /etc/os-release ]] && . /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
  centos:10|rhel:10|rocky:10|almalinux:10) ;;
  *) warn "SO detectado: ${PRETTY_NAME:-desconocido}. Pensado para CentOS/RHEL 10; continuando bajo su riesgo.";;
esac
[[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] || die "Arquitectura no soportada."

# ----------------------------- Preguntas (puerto y acceso remoto) ------------
# Se lee del teclado (/dev/tty) para que tambien funcione con: curl ... | sudo bash
TTY_IN=""
if [[ -t 0 ]]; then TTY_IN=/dev/stdin
elif { : < /dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi
ask() { local __r=""; read -rp "$1" __r < "$TTY_IN" || true; printf '%s' "$__r"; }
PRE_EXISTS=0; [[ -f "${PGDATA}/PG_VERSION" ]] && PRE_EXISTS=1
if [[ -z "$REMOTE" && "$PG_LISTEN" != "localhost" ]]; then REMOTE=1; fi

if [[ $NO_PROMPT -eq 0 && -n "$TTY_IN" ]]; then
  if [[ $PORT_GIVEN -eq 0 && $PRE_EXISTS -eq 0 ]]; then
    _a="$(ask "Puerto de PostgreSQL [${PG_PORT}]: ")"; [[ -n "$_a" ]] && { PG_PORT="$_a"; PORT_GIVEN=1; }
  fi
  if [[ -z "$REMOTE" ]]; then
    _a="$(ask "¿Permitir conexiones remotas a la base de datos (desde otras PC/servidores)? [s/N]: ")"
    if [[ "$_a" =~ ^[sSyY] ]]; then REMOTE=1; else REMOTE=0; fi
  fi
  if [[ "$REMOTE" == 1 && -z "$ALLOW_CIDR" ]]; then
    ALLOW_CIDR="$(ask "IPs o redes permitidas, separadas por coma (ej: 190.1.2.3,10.0.0.0/24; Enter = cualquier IP): ")"
  fi
  if [[ -n "$APP_USER" && -z "$APP_DB" ]]; then
    APP_DB="$(ask "Base(s) de datos del usuario ${APP_USER,,}, separadas por coma (si ya existe se le dan permisos) [jema]: ")"
  fi
  if [[ $PRE_EXISTS -eq 1 && "$CONFIGURE_EXISTING" != 1 && ( "$REMOTE" == 1 || $PORT_GIVEN -eq 1 || "$TUNE" == 1 ) ]]; then
    _a="$(ask "El cluster ${PG_VERSION}/${PG_CLUSTER} ya existe. ¿Aplicarle estos cambios? Se respalda y se reinicia PostgreSQL [s/N]: ")"
    [[ "$_a" =~ ^[sSyY] ]] && CONFIGURE_EXISTING=1
  fi
  unset _a
fi
REMOTE="${REMOTE:-0}"

# ----------------------------- Validaciones ----------------------------------
for p in "$PG_PORT" "$GRAFANA_PORT" "$PROMETHEUS_PORT" "$EXPORTER_PORT" "$PGADMIN_PORT"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Puerto invalido: $p"
done
[[ "$MAX_CONN" =~ ^[0-9]+$ && "$MAX_CONN" -ge 10 ]] || die "--max-connections invalido: ${MAX_CONN} (minimo 10)"
[[ -z "$RAM_MB" || "$RAM_MB" =~ ^[0-9]+$ ]] || die "--ram-mb invalido: ${RAM_MB}"

# IPs/redes permitidas: acepta IPv4/IPv6 con o sin mascara (una IP sola = /32 o /128)
ALLOW_LIST=()
if [[ -n "$ALLOW_CIDR" ]]; then
  IFS=', ' read -ra _cl <<< "$ALLOW_CIDR"
  for c in "${_cl[@]}"; do
    [[ -z "$c" ]] && continue
    if [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
      [[ "$c" == */* ]] || c="${c}/32"
    elif [[ "$c" == *:* && "$c" =~ ^[0-9A-Fa-f:]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]; then
      [[ "$c" == */* ]] || c="${c}/128"
    else
      die "IP o red invalida en --allow-cidr: '${c}' (ej: 190.1.2.3 o 10.0.0.0/24)"
    fi
    ALLOW_LIST+=("$c")
  done
  unset _cl c
fi
if [[ "$REMOTE" == 1 && "$PG_LISTEN" == "localhost" ]]; then PG_LISTEN='*'; fi
if [[ "$REMOTE" != 1 && "$PG_LISTEN" != "localhost" ]]; then REMOTE=1; fi

# Usuario y bases de la aplicacion: siempre en minusculas (PostgreSQL distingue "JEMA" de jema)
APP_DBS=()
if [[ -n "$APP_USER" ]]; then
  [[ "$APP_USER" != "${APP_USER,,}" ]] && warn "Usuario '${APP_USER}' pasado a minusculas: ${APP_USER,,}"
  APP_USER="${APP_USER,,}"
  [[ "$APP_USER" == postgres ]] && die "--app-user no puede ser 'postgres'."
  IFS=', ' read -ra _dl <<< "${APP_DB:-jema}"
  for _n in "${_dl[@]}"; do
    [[ -z "$_n" ]] && continue
    [[ "$_n" != "${_n,,}" ]] && warn "Base '${_n}' pasada a minusculas: ${_n,,}"
    _n="${_n,,}"
    [[ "$_n" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "Nombre de base invalido '${_n}': use letras, numeros y _ (ej: erp_db)."
    in_list "$_n" ${APP_DBS[@]+"${APP_DBS[@]}"} || APP_DBS+=("$_n")
  done
  (( ${#APP_DBS[@]} )) || APP_DBS=(jema)
  for _n in "$APP_USER"; do
    [[ "$_n" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "Usuario invalido '${_n}': use letras, numeros y _ (ej: jema)."
  done
  APP_DB="${APP_DBS[0]}"
  unset _dl _n
fi

# ----------------------------- Clave de administracion -----------------------
# Por defecto Jema2026#. Si hay terminal y no se indico --password, se ofrece cambiarla.
# Remoto desde cualquier IP en un cluster nuevo: la clave por defecto (publica) no se acepta.
_need_own=0
[[ "$REMOTE" == 1 && ${#ALLOW_LIST[@]} -eq 0 && $PRE_EXISTS -eq 0 ]] && _need_own=1
if [[ $PASS_GIVEN -eq 0 && $NO_PROMPT -eq 0 && "$DRY_RUN" != 1 && -n "$TTY_IN" ]]; then
  echo "Clave de administracion (postgres${APP_USER:+, ${APP_USER}}, pgAdmin, Grafana)."
  [[ $_need_own -eq 1 ]] && echo "Permitio acceso remoto desde CUALQUIER IP: debe elegir una clave propia (la por defecto ${DEFAULT_PASS} es publica)."
  while :; do
    if [[ $_need_own -eq 1 ]]; then
      read -rsp "Nueva clave (minimo 8 caracteres): " _p1 < "$TTY_IN" || die "No se pudo leer la clave."; echo
      if [[ -z "$_p1" ]]; then warn "La clave no puede quedar vacia."; continue; fi
      if [[ "$_p1" == "$DEFAULT_PASS" ]]; then warn "Esa es la clave por defecto (publica). Elija otra."; continue; fi
    else
      read -rsp "Escriba otra clave o presione Enter para usar la por defecto (${DEFAULT_PASS}): " _p1 < "$TTY_IN" || die "No se pudo leer la clave."; echo
      [[ -z "$_p1" ]] && break
    fi
    if [[ ${#_p1} -lt 8 ]]; then warn "La clave debe tener al menos 8 caracteres. Intente de nuevo."; continue; fi
    read -rsp "Repita la clave: " _p2 < "$TTY_IN" || die "No se pudo leer la clave."; echo
    if [[ "$_p1" != "$_p2" ]]; then warn "Las claves no coinciden. Intente de nuevo."; continue; fi
    ADMIN_PASS="$_p1"; break
  done
  unset _p1 _p2
fi
[[ ${#ADMIN_PASS} -ge 8 ]] || die "La clave debe tener al menos 8 caracteres."
[[ -n "$APP_PASS" ]] || APP_PASS="$ADMIN_PASS"
if [[ $_need_own -eq 1 && "$ADMIN_PASS" == "$DEFAULT_PASS" ]]; then
  die "Acceso remoto desde CUALQUIER IP con la clave por defecto (es publica): indique otra con --password o al preguntar, o limite el origen con --allow-cidr."
fi
unset _need_own
# pgAdmin rechaza correos con dominios reservados (.local, .localhost, .test, ...): la cuenta no se crearia.
if [[ "$WITH_PGADMIN" == 1 ]]; then
  [[ "$PGADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || die "Correo de pgAdmin invalido: ${PGADMIN_EMAIL}"
  case "${PGADMIN_EMAIL##*.}" in
    local|localhost|test|invalid|arpa|onion|LOCAL|LOCALHOST|TEST|INVALID|ARPA|ONION)
      die "pgAdmin no acepta correos terminados en .${PGADMIN_EMAIL##*.} (${PGADMIN_EMAIL}). Use otro, ej: --pgadmin-email admin@example.com";;
  esac
fi
if [[ "$ADMIN_PASS" == "$DEFAULT_PASS" && ( ( $PRE_EXISTS -eq 0 && ( "$REMOTE" == 1 || "$OPEN_PG" == 1 ) ) || "$OPEN_PGADMIN" == 1 || "$OPEN_OBS" == 1 ) ]]; then
  CLAVE_DEFECTO_EXPUESTA=1
else
  CLAVE_DEFECTO_EXPUESTA=0
fi

exec > >(tee -a "$LOG_FILE") 2>&1
info "Log: $LOG_FILE"
if [[ $CLAVE_DEFECTO_EXPUESTA -eq 1 ]]; then
  warn "Se usara la clave por defecto con servicios accesibles por red: cambiela cuanto antes (--password o al preguntar)."
fi

# Conflictos de puerto
check_port() { # puerto, nombre
  if port_in_use "$1"; then
    warn "El puerto $1 ($2) ya esta en uso:"; ss -ltnp "sport = :$1" | tail -n +2 || true
    return 1
  fi
}
if [[ $PRE_EXISTS -eq 0 ]]; then
  if ! check_port "$PG_PORT" "PostgreSQL"; then
    die "Elija otro puerto con --pg-port. No se modifico nada."
  fi
fi

info "Plan: PG ${PG_VERSION} puerto ${PG_PORT}, remoto=$([[ "$REMOTE" == 1 ]] && echo "si, ${HBA_TYPE} desde ${ALLOW_LIST[*]:-cualquier IP}" || echo no), app=$([[ -n "$APP_USER" ]] && echo "${APP_USER} (${APP_DBS[*]})" || echo no), obs=${WITH_OBS}, pgadmin=${WITH_PGADMIN}"

# Foto del estado previo (para auditar o revertir a mano si hiciera falta)
if [[ "$DRY_RUN" != 1 ]]; then
  mkdir -p "$SNAP_DIR"; chmod 700 "$SNAP_DIR"
  rpm -qa | sort > "$SNAP_DIR/paquetes.txt" || true
  systemctl list-unit-files --state=enabled --no-legend > "$SNAP_DIR/servicios-habilitados.txt" 2>/dev/null || true
  ss -ltnp > "$SNAP_DIR/puertos-escuchando.txt" 2>/dev/null || true
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --list-all-zones > "$SNAP_DIR/firewall.txt" 2>/dev/null || true
  fi
  info "Foto del estado previo en ${SNAP_DIR}"
fi

# ----------------------------- 1) Repositorio PGDG ---------------------------
install_repo() {
  if rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
    info "Repositorio PGDG ya instalado."
  else
    info "Instalando repositorio PGDG (EL-10)..."
    run dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"
  fi
  # Nota: NO se deshabilita ningun modulo de AppStream. Los paquetes PGDG se llaman
  # postgresql18-* y no chocan con otros PostgreSQL instalados en el servidor.
}

# ----------------------------- 2) PostgreSQL ---------------------------------
# ----------------------------- Configuracion del cluster (comun) -------------
# Todo lo que se escribe se registra: si PostgreSQL no arranca con la configuracion
# nueva de un cluster EXISTENTE, se revierte sola (ver restart_or_rollback).
NEW_FILES=(); CHANGED_FILES=()
REMOTE_APPLIED=0; CONFIGURED=0; LIVE_PORT=""
HBA_BEGIN="# BEGIN install-postgres18: acceso remoto (bloque generado; se reemplaza al reconfigurar)"
HBA_END="# END install-postgres18: acceso remoto"

track_file() { # registra un archivo antes de modificarlo (respaldo una sola vez)
  local f="$1"
  if in_list "$f" ${NEW_FILES[@]+"${NEW_FILES[@]}"} ${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}; then return 0; fi
  if [[ -f "$f" ]]; then backup "$f"; CHANGED_FILES+=("$f"); else NEW_FILES+=("$f"); fi
}
write_pg_file() { # ruta ; contenido por stdin
  local f="$1"
  track_file "$f"
  cat > "$f"; chown postgres:postgres "$f"; chmod 640 "$f"
}

ensure_confd() {
  install -d -o postgres -g postgres -m 750 "$CONFD"
  if ! grep -Eq "^\s*include_dir\s*=\s*'conf.d'" "$PG_CONF_FILE"; then
    track_file "$PG_CONF_FILE"
    printf "\n# agregado por %s\ninclude_dir = 'conf.d'\n" "$SCRIPT_NAME" >> "$PG_CONF_FILE"
  fi
}

write_base_conf() { # solo cluster nuevo: registro de consultas lentas, bloqueos, etc.
  write_pg_file "${CONFD}/90-install-script.conf" < <(
    echo "# generado por ${SCRIPT_NAME} ${STAMP}"
    echo "track_io_timing = on"
    echo "log_line_prefix = '%m [%p] %q%u@%d '"
    echo "log_min_duration_statement = 1000"
    echo "log_checkpoints = on"
    echo "log_lock_waits = on"
    if [[ "$PGSS" == 1 ]]; then
      echo "shared_preload_libraries = 'pg_stat_statements'"
      echo "pg_stat_statements.track = all"
    fi
  )
}

write_tuning_conf() { # memoria y paralelismo segun la RAM y los CPU del servidor
  local ram cpus sb ecs mwm wm par
  ram="${RAM_MB:-$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)}"
  cpus="$(nproc 2>/dev/null || echo 1)"
  sb=$(( ram / 4 ));        (( sb < 128 )) && sb=128
  ecs=$(( ram * 3 / 4 ))
  mwm=$(( ram / 16 ));      (( mwm < 64 )) && mwm=64; (( mwm > 2048 )) && mwm=2048
  wm=$(( (ram - sb) / (MAX_CONN * 3) )); (( wm < 4 )) && wm=4; (( wm > 256 )) && wm=256
  par=$(( cpus / 2 ));      (( par > 4 )) && par=4
  info "Rendimiento: RAM ${ram} MB, ${cpus} CPU -> shared_buffers ${sb}MB, work_mem ${wm}MB, max_connections ${MAX_CONN}"
  write_pg_file "${CONFD}/80-rendimiento.conf" < <(
    echo "# generado por ${SCRIPT_NAME} ${STAMP} para RAM=${ram}MB CPU=${cpus}"
    echo "# (para recalcular: vuelva a ejecutar el instalador con --configure-existing --tune)"
    echo "max_connections = ${MAX_CONN}"
    echo "shared_buffers = ${sb}MB"
    echo "effective_cache_size = ${ecs}MB"
    echo "maintenance_work_mem = ${mwm}MB"
    echo "work_mem = ${wm}MB"
    echo "wal_buffers = 16MB"
    echo "checkpoint_completion_target = 0.9"
    echo "min_wal_size = 512MB"
    echo "max_wal_size = 2GB"
    echo "default_statistics_target = 100"
    echo "# discos SSD/NVMe (lo habitual en VPS)"
    echo "random_page_cost = 1.1"
    echo "effective_io_concurrency = 200"
    if (( cpus >= 2 )); then
      echo "max_worker_processes = ${cpus}"
      echo "max_parallel_workers = ${cpus}"
      echo "max_parallel_workers_per_gather = ${par}"
      echo "max_parallel_maintenance_workers = ${par}"
    fi
  )
}

write_listen_conf() {
  write_pg_file "${CONFD}/91-escucha.conf" < <(
    echo "# generado por ${SCRIPT_NAME} ${STAMP}"
    echo "listen_addresses = '${PG_LISTEN}'"
  )
  if grep -qsE "^\s*listen_addresses" "${PGDATA}/postgresql.auto.conf"; then
    warn "postgresql.auto.conf (ALTER SYSTEM) define listen_addresses y tiene prioridad sobre conf.d: reviselo."
  fi
}

ssl_on_in_config() {
  grep -hsE "^\s*ssl\s*=\s*'?(on|true|yes|1)'?\s*(#.*)?$" "$PG_CONF_FILE" "$CONFD"/*.conf "${PGDATA}/postgresql.auto.conf" | grep -q .
}
ensure_ssl() { # 'hostssl' exige SSL en el servidor; si no esta activo se crea un certificado autofirmado
  [[ "$HBA_TYPE" == hostssl ]] || return 0
  ssl_on_in_config && return 0
  local crt="${SSL_DIR}/server-install.crt" key="${SSL_DIR}/server-install.key" cn
  cn="$(hostname -f 2>/dev/null || hostname)"
  info "Activando SSL con certificado autofirmado (CN=${cn}, 10 anios)..."
  openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 -subj "/CN=${cn}" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1 || die "No se pudo generar el certificado SSL."
  chown postgres:postgres "$crt" "$key"; chmod 600 "$key"; chmod 644 "$crt"
  write_pg_file "${CONFD}/92-ssl.conf" < <(
    echo "# generado por ${SCRIPT_NAME} ${STAMP}"
    echo "ssl = on"
    echo "ssl_cert_file = '${crt}'"
    echo "ssl_key_file = '${key}'"
  )
}

write_hba_block() { # bloque propio al final de pg_hba.conf (las reglas locales siguen primero)
  local -a src=(${ALLOW_LIST[@]+"${ALLOW_LIST[@]}"}); local c tmp
  (( ${#src[@]} )) || src=("0.0.0.0/0" "::/0")
  track_file "$HBA_FILE"
  tmp="$(mktemp)"
  awk -v b="$HBA_BEGIN" -v e="$HBA_END" '$0==b {skip=1} !skip {print} $0==e {skip=0}' "$HBA_FILE" > "$tmp"
  {
    echo "$HBA_BEGIN"
    if [[ "$BLOCK_PG_REMOTE" == 1 ]]; then
      echo "# el superusuario 'postgres' solo puede entrar desde este servidor"
      for c in "${src[@]}"; do printf "%-8s %-6s %-10s %-43s %s\n" host all postgres "$c" reject; done
    fi
    for c in "${src[@]}"; do printf "%-8s %-6s %-10s %-43s %s\n" "$HBA_TYPE" all all "$c" scram-sha-256; done
    echo "$HBA_END"
  } >> "$tmp"
  cat "$tmp" > "$HBA_FILE"; rm -f "$tmp"
  info "pg_hba.conf: ${HBA_TYPE} desde ${src[*]}"
}

configure_cluster() { # $1 = 1 si el cluster es nuevo. Devuelve 0 si escribio configuracion.
  local fresh="$1" port_change=0
  if [[ $fresh -eq 0 && -n "$LIVE_PORT" && $PORT_GIVEN -eq 1 && "$PG_PORT" != "$LIVE_PORT" ]]; then port_change=1; fi

  if [[ $fresh -eq 0 && "$CONFIGURE_EXISTING" != 1 ]]; then
    if [[ -n "$LIVE_PORT" ]]; then
      [[ "$LIVE_PORT" != "$PG_PORT" ]] && warn "El cluster existente usa el puerto ${LIVE_PORT}; se usa ese y no ${PG_PORT}."
      PG_PORT="$LIVE_PORT"
    fi
    if [[ "$REMOTE" == 1 || $port_change -eq 1 || "$TUNE" == 1 ]]; then
      warn "Cluster existente: NO se aplicaron acceso remoto / puerto / rendimiento."
      warn "Para aplicarlos repita con --configure-existing (respalda, reinicia PostgreSQL y revierte si no arranca)."
    fi
    return 1
  fi
  [[ $fresh -eq 0 && -n "$LIVE_PORT" && $port_change -eq 0 ]] && PG_PORT="$LIVE_PORT"
  if [[ $port_change -eq 1 ]] && port_in_use "$PG_PORT"; then
    die "El puerto ${PG_PORT} ya esta en uso; el cluster sigue en ${LIVE_PORT}. No se modifico nada."
  fi

  local do_tune=0
  if [[ "$TUNE" == 1 || ( -z "$TUNE" && $fresh -eq 1 ) ]]; then do_tune=1; fi

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY: configurar cluster: nuevo=${fresh} puerto=${PG_PORT} cambio_puerto=${port_change} rendimiento=${do_tune} remoto=${REMOTE} (${HBA_TYPE} desde ${ALLOW_LIST[*]:-cualquier IP})"
    [[ "$REMOTE" == 1 ]] && REMOTE_APPLIED=1
    return 0
  fi

  ensure_confd
  if [[ $fresh -eq 1 ]]; then write_base_conf; fi
  if [[ $do_tune -eq 1 ]]; then write_tuning_conf; fi
  if [[ $fresh -eq 1 || $port_change -eq 1 ]]; then set_pg_port "$fresh"; fi
  if [[ "$REMOTE" == 1 ]]; then
    write_listen_conf
    ensure_ssl
    write_hba_block
    REMOTE_APPLIED=1
  elif [[ $fresh -eq 1 ]]; then
    write_listen_conf   # localhost
  fi
  (( ${#NEW_FILES[@]} + ${#CHANGED_FILES[@]} )) || return 1
  return 0
}

restart_or_rollback() {
  info "Reiniciando ${SVC} para aplicar la configuracion (corta las conexiones unos segundos)..."
  if systemctl restart "$SVC" && sleep 2 && systemctl is-active --quiet "$SVC"; then
    info "${SVC} reiniciado con la configuracion nueva."; return 0
  fi
  warn "PostgreSQL NO arranco con la configuracion nueva: revirtiendo los cambios..."
  local f
  for f in ${NEW_FILES[@]+"${NEW_FILES[@]}"}; do [[ -e "$f" ]] && mv -f "$f" "${f}.fallido-${STAMP}"; done
  for f in ${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}; do cp -a "${f}.bak-${STAMP}" "$f"; done
  systemctl restart "$SVC" || true
  die "Cambios revertidos y PostgreSQL reiniciado con la configuracion anterior. Detalle: journalctl -u ${SVC} -n 50"
}

start_cluster() { # $1 = 1 si el cluster es nuevo
  local fresh="$1"
  if [[ $fresh -eq 1 ]]; then
    enable_pg_service
    run systemctl start "$SVC" || die "No arranco ${SVC}. Detalle: journalctl -u ${SVC} -n 50"
  elif ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
    warn "El cluster existente en ${PGDATA} no esta activo: NO se inicia (puede ser de otro sistema)."
    [[ $CONFIGURED -eq 1 ]] && warn "La configuracion nueva se aplicara cuando lo inicie."
    PG_UP=0
  elif [[ $CONFIGURED -eq 1 ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "DRY: systemctl restart ${SVC}"; else restart_or_rollback; fi
  else
    info "Servicio ${SVC} ya activo: no se reinicia ni se recarga."
  fi
}

set_credentials() { # solo cluster nuevo
  [[ "$1" -eq 1 && "$DRY_RUN" != 1 ]] || return 0
  local pw_sql="${ADMIN_PASS//\'/\'\'}"
  psql_pg -qc "ALTER ROLE postgres PASSWORD '${pw_sql}'"
  if [[ "$PGSS" == 1 ]]; then psql_pg -qc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" || true; fi
  ( umask 077; { echo "# generado ${STAMP}"; echo "POSTGRES_PASSWORD=${ADMIN_PASS}"; } >> "$CRED_FILE" )
  info "Password de 'postgres' guardado en ${CRED_FILE}"
}

app_grant_sql() { # $1 = rol. Permisos completos en una base EXISTENTE (todos los esquemas de usuario)
  cat <<SQL
DO \$\$
DECLARE s text; o text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace
           WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema' LOOP
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', s, '$1');
    EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO %I', s, '$1');
    EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO %I', s, '$1');
    EXECUTE format('GRANT ALL ON ALL ROUTINES IN SCHEMA %I TO %I', s, '$1');
  END LOOP;
  -- lo que creen en el futuro los duenos actuales (y postgres) tambien queda accesible
  FOR o IN SELECT DISTINCT pg_get_userbyid(c.relowner) FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
           UNION SELECT 'postgres' LOOP
    CONTINUE WHEN o = '$1';
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT ALL ON TABLES TO %I', o, '$1');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT ALL ON SEQUENCES TO %I', o, '$1');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT ALL ON ROUTINES TO %I', o, '$1');
  END LOOP;
END
\$\$;
SQL
}

app_owner_sql() { # $1 = rol. Traspasa a $1 los objetos de 'postgres' (no los de extensiones)
  cat <<SQL
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname FROM pg_namespace n
            WHERE n.nspowner = 'postgres'::regrole AND n.nspname NOT LIKE 'pg\_%'
              AND n.nspname NOT IN ('information_schema', 'public') LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.nspname, '$1');
  END LOOP;
  -- tablas, vistas, vistas materializadas, tablas foraneas y secuencias sueltas
  FOR r IN SELECT c.oid::regclass AS obj, c.relkind FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relowner = 'postgres'::regrole
              AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
              AND c.relkind IN ('r','p','v','m','f','S')
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                               AND d.objid = c.oid AND d.deptype IN ('e','a','i')) LOOP
    EXECUTE format('ALTER %s %s OWNER TO %I',
      CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                     WHEN 'f' THEN 'FOREIGN TABLE' WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
      r.obj, '$1');
  END LOOP;
  -- funciones y procedimientos
  FOR r IN SELECT p.oid::regprocedure AS obj FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE p.proowner = 'postgres'::regrole
              AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                               AND d.objid = p.oid AND d.deptype = 'e') LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.obj, '$1');
  END LOOP;
  -- tipos propios (enum, dominio, rango)
  FOR r IN SELECT t.oid::regtype AS obj FROM pg_type t
             JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE t.typowner = 'postgres'::regrole AND t.typtype IN ('e','d','r')
              AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
                               AND d.objid = t.oid AND d.deptype = 'e') LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO %I', r.obj, '$1');
  END LOOP;
END
\$\$;
SQL
}

create_app() { # usuario propio para la aplicacion (por defecto 'jema') y sus bases
  [[ -n "$APP_USER" ]] || return 0
  if [[ "$PG_UP" != 1 ]]; then warn "Cluster inactivo: no se creo el usuario/base de la aplicacion."; return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY: rol ${APP_USER}; bases ${APP_DBS[*]} (nuevas: dueno ${APP_USER}; existentes: permisos${APP_OWNER:+ y traspaso de propiedad})"
    return 0
  fi
  local pw_sql="${APP_PASS//\'/\'\'}" db saved_pw=1
  if [[ "$(psql_pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='${APP_USER}'")" == 1 ]]; then
    if [[ $APP_PASS_GIVEN -eq 1 ]]; then
      psql_pg -qc "ALTER ROLE \"${APP_USER}\" LOGIN PASSWORD '${pw_sql}'"; info "Rol ${APP_USER}: clave actualizada."
    else
      info "El rol ${APP_USER} ya existe: se conserva su clave (use --app-password para cambiarla)."; saved_pw=0
    fi
  else
    psql_pg -qc "CREATE ROLE \"${APP_USER}\" LOGIN PASSWORD '${pw_sql}'"
    info "Rol ${APP_USER} creado."
  fi
  for db in "${APP_DBS[@]}"; do
    if [[ "$(psql_pg -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")" == 1 ]]; then
      psql_pg -qc "GRANT CONNECT, TEMPORARY, CREATE ON DATABASE \"${db}\" TO \"${APP_USER}\""
      app_grant_sql "$APP_USER" | psql_pg -d "$db" -q -v ON_ERROR_STOP=1 \
        || die "No se pudieron otorgar los permisos en ${db}."
      info "Base existente ${db}: ${APP_USER} tiene permisos completos (tablas, secuencias, funciones y las futuras)."
      if [[ -n "$APP_OWNER" ]]; then
        psql_pg -qc "ALTER DATABASE \"${db}\" OWNER TO \"${APP_USER}\""
        app_owner_sql "$APP_USER" | psql_pg -d "$db" -q -v ON_ERROR_STOP=1 \
          || die "No se pudo traspasar la propiedad de los objetos de ${db}."
        info "Base existente ${db}: dueno ${APP_USER} (base, esquemas, tablas, vistas, secuencias y funciones)."
      fi
    else
      psql_pg -qc "CREATE DATABASE \"${db}\" OWNER \"${APP_USER}\" ENCODING 'UTF8' TEMPLATE template0"
      info "Base ${db} creada (dueno ${APP_USER})."
    fi
  done
  ( umask 077
    { echo "APP_USER=${APP_USER}"; echo "APP_DB=${APP_DBS[*]}"
      if [[ $saved_pw -eq 1 ]]; then echo "APP_PASSWORD=${APP_PASS}"; fi; } >> "$CRED_FILE" )
}

ssh_ports() { # puertos de SSH (para no cortarse al activar el firewall)
  local ps
  ps="$( { sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
           ss -H -ltnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}'; } | sort -un)"
  echo "${ps:-22}"
}

# --- particular de CentOS/RHEL ---
PORT_IN_CONFD=1   # el puerto va en conf.d/91-puerto.conf
selinux_pg_port() {
  if [[ "$PG_PORT" != "5432" ]] && selinux_on; then
    run semanage port -a -t postgresql_port_t -p tcp "$PG_PORT" 2>/dev/null \
      || run semanage port -m -t postgresql_port_t -p tcp "$PG_PORT" || true
  fi
}
set_pg_port() { # $1 = 1 si el cluster es nuevo
  write_pg_file "${CONFD}/91-puerto.conf" < <(
    echo "# generado por ${SCRIPT_NAME} ${STAMP}"
    echo "port = ${PG_PORT}"
  )
  selinux_pg_port
  [[ "$1" -eq 1 ]] || info "Puerto del cluster: ${LIVE_PORT} -> ${PG_PORT}"
}
enable_pg_service() { run systemctl enable "$SVC"; }

install_postgres() {
  local fresh=0
  info "Instalando paquetes PostgreSQL ${PG_VERSION}..."
  run dnf install -y "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}" \
                     "postgresql${PG_VERSION}-contrib" openssl policycoreutils-python-utils

  if [[ $PRE_EXISTS -eq 1 ]]; then
    warn "Ya existe un cluster en ${PGDATA}: NO se ejecuta initdb (datos intactos)."
    LIVE_PORT="$(sed -n '4p' "${PGDATA}/postmaster.pid" 2>/dev/null || true)"
    if ! [[ "$LIVE_PORT" =~ ^[0-9]+$ ]]; then
      LIVE_PORT="$(runuser -u postgres -- "${PGBIN}/postgres" -C port -D "$PGDATA" 2>/dev/null || true)"
    fi
    [[ "$LIVE_PORT" =~ ^[0-9]+$ ]] || LIVE_PORT=""
    if [[ "$CONFIGURE_EXISTING" != 1 ]]; then
      warn "Cluster existente: NO se tocan su configuracion ni su servicio (use --configure-existing para cambiarlos)."
    fi
  else
    fresh=1
    info "Inicializando cluster nuevo en ${PGDATA}..."
    PGSETUP_INITDB_OPTIONS="--auth-local=peer --auth-host=scram-sha-256 --data-checksums --encoding=UTF8" \
      run "${PGBIN}/postgresql-${PG_VERSION}-setup" initdb
  fi

  if configure_cluster "$fresh"; then CONFIGURED=1; fi
  start_cluster "$fresh"
  set_credentials "$fresh"
}

# ----------------------------- 3) Firewall -----------------------------------
fw_enable() { # solo con --enable-firewall; permite SSH ANTES de activar
  [[ "$ENABLE_FW" == 1 ]] || return 0
  if systemctl is-active --quiet firewalld; then info "firewalld ya activo."; return 0; fi
  run dnf install -y firewalld
  local p
  run firewall-offline-cmd --add-service=ssh || true
  for p in $(ssh_ports); do run firewall-offline-cmd --add-port="${p}/tcp" || true; done
  run systemctl enable --now firewalld
  info "firewalld activado (SSH permitido en: $(ssh_ports | tr '\n' ' '))."
}
fw_open() { # puerto ; origen = ALLOW_LIST (vacia = cualquiera)
  local port="$1" c fam
  local -a src=(${ALLOW_LIST[@]+"${ALLOW_LIST[@]}"})
  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld inactivo: no se agrego regla para ${port}/tcp (queda accesible si no hay otro firewall). Use --enable-firewall para activarlo."
    return 0
  fi
  if (( ${#src[@]} == 0 )); then run firewall-cmd --permanent --add-port="${port}/tcp"
  else
    for c in "${src[@]}"; do
      fam=ipv4; [[ "$c" == *:* ]] && fam=ipv6
      run firewall-cmd --permanent --add-rich-rule="rule family=${fam} source address=${c} port port=${port} protocol=tcp accept"
    done
  fi
  FW_CHANGED=1; info "Firewall: abierto ${port}/tcp desde ${src[*]:-cualquier IP}"
}
fw_reload() { if [[ $FW_CHANGED -eq 1 ]]; then run firewall-cmd --reload; fi; }

# ----------------------------- 4) Observabilidad -----------------------------
gh_latest() { # owner/repo -> tag sin 'v'
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/'
}
arch_go() { if [[ "$(uname -m)" == "aarch64" ]]; then echo arm64; else echo amd64; fi; }

install_observability() {
  info "== Observabilidad: postgres_exporter + Prometheus + Grafana (aislados en ${OBS_DIR}) =="
  local A; A="$(arch_go)"

  # --- chequeo previo: si hay conflicto de puertos se omite TODO este bloque ---
  local graf_pre=0 conflict=0
  if rpm -q grafana >/dev/null 2>&1; then graf_pre=1; fi
  if ! systemctl is-active --quiet pgobs-exporter && ! check_port "$EXPORTER_PORT" "postgres_exporter"; then conflict=1; fi
  if ! systemctl is-active --quiet pgobs-prometheus && ! check_port "$PROMETHEUS_PORT" "Prometheus"; then conflict=1; fi
  if [[ $graf_pre -eq 0 ]] && ! check_port "$GRAFANA_PORT" "Grafana"; then conflict=1; fi
  if [[ $conflict -eq 1 ]]; then
    warn "Observabilidad omitida por conflicto de puertos. Use --grafana-port / --prometheus-port / --exporter-port."
    return 0
  fi
  if [[ $graf_pre -eq 1 ]]; then
    warn "Grafana ya esta instalado (otro sistema): se respeta su puerto y configuracion; solo se agrega datasource y dashboard de PostgreSQL, sin reiniciarlo."
  fi

  # --- usuario de monitoreo propio (rol pg_monitor, solo lectura) ---
  local mon_pw; mon_pw="$(gen_pass)"
  if [[ "$DRY_RUN" != 1 ]]; then
    local role_exists
    if ! role_exists="$(sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${MON_ROLE}'" 2>/dev/null)"; then
      warn "No se pudo consultar el cluster en el puerto ${PG_PORT}; observabilidad omitida."
      return 0
    fi
    if [[ "$role_exists" == "1" && -f /etc/pgobs/exporter.env ]]; then
      info "Rol ${MON_ROLE} ya existe: se reutiliza."
      mon_pw="$(grep -oP "(?<=${MON_ROLE}:)[^@]+" /etc/pgobs/exporter.env | head -1 || true)"
      [[ -n "$mon_pw" ]] || mon_pw="$(gen_pass)"
    elif [[ "$role_exists" == "1" ]]; then
      sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -qc "ALTER ROLE ${MON_ROLE} PASSWORD '${mon_pw}'"
    else
      sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -qc "CREATE ROLE ${MON_ROLE} LOGIN PASSWORD '${mon_pw}' CONNECTION LIMIT 5"
      sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -qc "GRANT pg_monitor TO ${MON_ROLE}"
    fi
  fi

  # --- usuario de sistema y carpetas propias ---
  if ! id "$OBS_USER" >/dev/null 2>&1; then run useradd --system --no-create-home --shell /sbin/nologin "$OBS_USER"; fi
  run install -d -m 755 "${OBS_DIR}" "${OBS_DIR}/bin"

  # --- postgres_exporter ---
  if [[ ! -x "${OBS_DIR}/bin/postgres_exporter" ]]; then
    local v; v="$(gh_latest prometheus-community/postgres_exporter || true)"
    if [[ -z "$v" ]]; then warn "No se pudo consultar la ultima version de postgres_exporter (GitHub). Observabilidad omitida."; return 0; fi
    info "Descargando postgres_exporter ${v}"
    run curl -fsSL -o "$TMP_DIR/pe.tgz" "https://github.com/prometheus-community/postgres_exporter/releases/download/v${v}/postgres_exporter-${v}.linux-${A}.tar.gz"
    run tar -xzf "$TMP_DIR/pe.tgz" -C "$TMP_DIR"
    run install -m 755 "$TMP_DIR"/postgres_exporter-*/postgres_exporter "${OBS_DIR}/bin/postgres_exporter"
  else warn "postgres_exporter propio ya instalado."; fi

  # --- Prometheus ---
  if [[ ! -x "${OBS_DIR}/bin/prometheus" ]]; then
    local pv; pv="$(gh_latest prometheus/prometheus || true)"
    if [[ -z "$pv" ]]; then warn "No se pudo consultar la ultima version de Prometheus (GitHub). Observabilidad omitida."; return 0; fi
    info "Descargando Prometheus ${pv}"
    run curl -fsSL -o "$TMP_DIR/prom.tgz" "https://github.com/prometheus/prometheus/releases/download/v${pv}/prometheus-${pv}.linux-${A}.tar.gz"
    run tar -xzf "$TMP_DIR/prom.tgz" -C "$TMP_DIR"
    run install -m 755 "$TMP_DIR"/prometheus-*/prometheus "${OBS_DIR}/bin/prometheus"
    run install -m 755 "$TMP_DIR"/prometheus-*/promtool "${OBS_DIR}/bin/promtool"
  else warn "Prometheus propio ya instalado."; fi

  if selinux_on; then
    run semanage fcontext -a -t bin_t "${OBS_DIR}/bin(/.*)?" 2>/dev/null || true
    run restorecon -R "${OBS_DIR}" || true
  fi

  if [[ "$DRY_RUN" != 1 ]]; then
    install -d -m 750 -o root -g "$OBS_USER" /etc/pgobs
    install -d -o "$OBS_USER" -g "$OBS_USER" /var/lib/pgobs-prometheus

    if [[ ! -f /etc/pgobs/exporter.env ]]; then
      echo "DATA_SOURCE_NAME=postgresql://${MON_ROLE}:${mon_pw}@127.0.0.1:${PG_PORT}/postgres?sslmode=disable" > /etc/pgobs/exporter.env
      chown root:"$OBS_USER" /etc/pgobs/exporter.env; chmod 640 /etc/pgobs/exporter.env
    fi
    if [[ ! -f /etc/pgobs/prometheus.yml ]]; then
      cat > /etc/pgobs/prometheus.yml <<EOF
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: postgres
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']
EOF
      chown "$OBS_USER":"$OBS_USER" /etc/pgobs/prometheus.yml
    fi
    if [[ ! -f /etc/systemd/system/pgobs-exporter.service ]]; then
      cat > /etc/systemd/system/pgobs-exporter.service <<EOF
[Unit]
Description=PostgreSQL exporter (pgobs)
After=network.target ${SVC}.service

[Service]
User=${OBS_USER}
EnvironmentFile=/etc/pgobs/exporter.env
ExecStart=${OBS_DIR}/bin/postgres_exporter --web.listen-address=127.0.0.1:${EXPORTER_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    fi
    if [[ ! -f /etc/systemd/system/pgobs-prometheus.service ]]; then
      cat > /etc/systemd/system/pgobs-prometheus.service <<EOF
[Unit]
Description=Prometheus (pgobs)
After=network.target

[Service]
User=${OBS_USER}
ExecStart=${OBS_DIR}/bin/prometheus --config.file=/etc/pgobs/prometheus.yml \\
  --storage.tsdb.path=/var/lib/pgobs-prometheus --storage.tsdb.retention.time=30d \\
  --web.listen-address=127.0.0.1:${PROMETHEUS_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    fi
  fi
  run systemctl daemon-reload
  run systemctl enable --now pgobs-exporter pgobs-prometheus

  # --- Grafana ---
  if [[ $graf_pre -eq 0 ]]; then
    if [[ ! -f /etc/yum.repos.d/grafana.repo && "$DRY_RUN" != 1 ]]; then
      cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
    fi
    run dnf install -y grafana
    if [[ "$DRY_RUN" != 1 ]]; then
      # puerto de Grafana en un drop-in (no edita grafana.ini)
      install -d /etc/systemd/system/grafana-server.service.d
      # clave de admin de Grafana (solo aplica en Grafana nuevo; escapada para systemd)
      local gf_pw="${ADMIN_PASS//\\/\\\\}"; gf_pw="${gf_pw//\"/\\\"}"; gf_pw="${gf_pw//\%/%%}"
      cat > /etc/systemd/system/grafana-server.service.d/port.conf <<EOF
[Service]
Environment=GF_SERVER_HTTP_PORT=${GRAFANA_PORT}
Environment="GF_SECURITY_ADMIN_PASSWORD=${gf_pw}"
EOF
      chmod 600 /etc/systemd/system/grafana-server.service.d/port.conf
      ( umask 077; { echo "GRAFANA_USER=admin"; echo "GRAFANA_PASSWORD=${ADMIN_PASS}"; } >> "$CRED_FILE" )
    fi
  fi

  if [[ "$DRY_RUN" != 1 && -d /etc/grafana ]]; then
    local is_def=true
    if [[ $graf_pre -eq 1 ]]; then is_def=false; fi
    install -d -o root -g grafana /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards-pgobs
    if [[ ! -f /etc/grafana/provisioning/datasources/pgobs-prometheus.yaml ]]; then
      cat > /etc/grafana/provisioning/datasources/pgobs-prometheus.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus-PG
    uid: prometheus-pg
    type: prometheus
    access: proxy
    url: http://127.0.0.1:${PROMETHEUS_PORT}
    isDefault: ${is_def}
EOF
    fi
    if [[ ! -f /etc/grafana/provisioning/dashboards/pgobs.yaml ]]; then
      cat > /etc/grafana/provisioning/dashboards/pgobs.yaml <<EOF
apiVersion: 1
providers:
  - name: pgobs-postgres
    folder: PostgreSQL
    type: file
    options: { path: /var/lib/grafana/dashboards-pgobs }
EOF
    fi
    # dashboard comunitario 9628 (PostgreSQL Database), mejor esfuerzo
    if curl -fsSL "https://grafana.com/api/dashboards/9628/revisions/latest/download" -o "$TMP_DIR/d.json" 2>/dev/null; then
      sed 's/\${DS_PROMETHEUS}/prometheus-pg/g' "$TMP_DIR/d.json" > /var/lib/grafana/dashboards-pgobs/postgres-9628.json
      chown -R grafana:grafana /var/lib/grafana/dashboards-pgobs
    else warn "No se pudo bajar el dashboard 9628; impórtelo desde Grafana (ID 9628)."; fi
  fi

  if [[ $graf_pre -eq 0 ]]; then
    run systemctl daemon-reload
    run systemctl enable --now grafana-server
    if [[ "$GRAFANA_PORT" != "3000" ]] && selinux_on; then
      run semanage port -a -t http_port_t -p tcp "$GRAFANA_PORT" 2>/dev/null || true
    fi
    if [[ "$OPEN_OBS" == 1 ]]; then fw_open "$GRAFANA_PORT"; fi
    info "Grafana: http://IP:${GRAFANA_PORT}  (usuario admin, con la clave configurada)"
  else
    info "Grafana existente: reinicie su servicio en una ventana de mantenimiento para cargar el datasource 'Prometheus-PG' y el dashboard."
  fi
  info "Prometheus y exporter quedan solo en localhost."
}

# ----------------------------- 5) pgAdmin ------------------------------------
install_pgadmin() {
  info "== pgAdmin 4 (modo web) =="

  # pgAdmin web usa Apache y agrega /pgadmin4 a sus sitios: no se mete en uno ajeno sin permiso explicito.
  local httpd_pre=0
  if systemctl is-active --quiet httpd; then httpd_pre=1; fi
  if [[ $httpd_pre -eq 1 && "$FORCE_PGADMIN" != 1 ]]; then
    warn "Apache (httpd) ya esta activo: pgAdmin web agregaria /pgadmin4 a TODOS sus sitios y podria afectar al otro sistema. Se OMITE."
    warn "Si lo acepta, repita con --force-pgadmin (se hace configtest antes de recargar, sin reiniciar)."
    return 0
  fi
  if [[ $httpd_pre -eq 0 ]]; then
    if port_in_use 80; then
      warn "El puerto 80 lo usa otro servidor web (httpd por defecto escucha en 80): pgAdmin web omitido."; return 0
    fi
    if [[ -f /etc/httpd/conf.d/ssl.conf ]] && port_in_use 443; then
      warn "El puerto 443 lo usa otro servidor web: pgAdmin web omitido."; return 0
    fi
  fi
  if [[ "$PGADMIN_PORT" != "80" ]] && port_in_use "$PGADMIN_PORT" && ! ss -ltnp "sport = :${PGADMIN_PORT}" | grep -q httpd; then
    warn "El puerto ${PGADMIN_PORT} esta ocupado por otro proceso: pgAdmin web omitido (use --pgadmin-port)."; return 0
  fi

  if ! rpm -q pgadmin4-redhat-repo >/dev/null 2>&1; then
    run dnf install -y "https://ftp.postgresql.org/pub/pgadmin/pgadmin4/yum/pgadmin4-redhat-repo-2-1.noarch.rpm" \
      || { warn "Repo pgAdmin no disponible para EL10. Alternativa nativa: pip install pgadmin4 dentro de un venv, o use solo Grafana."; return 0; }
  fi
  run dnf install -y pgadmin4-web || { warn "No se pudo instalar pgadmin4-web en esta version de SO."; return 0; }

  local pw="$ADMIN_PASS"
  if [[ ! -f /var/lib/pgadmin/pgadmin4.db && "$DRY_RUN" != 1 ]]; then
    if PGADMIN_SETUP_EMAIL="$PGADMIN_EMAIL" PGADMIN_SETUP_PASSWORD="$pw" /usr/pgadmin4/bin/setup-web.sh --yes; then
      ( umask 077; { echo "PGADMIN_EMAIL=${PGADMIN_EMAIL}"; echo "PGADMIN_PASSWORD=${pw}"; } >> "$CRED_FILE" )
      info "Credenciales de pgAdmin guardadas en ${CRED_FILE}"
    else
      warn "setup-web.sh fallo; revise la salida anterior."
    fi
  else
    warn "pgAdmin ya estaba configurado: no se re-ejecuta setup (evita tocar su base de usuarios)."
  fi

  # Puerto dedicado: solo AGREGA un archivo Listen propio (no edita httpd.conf ni sitios existentes)
  local created_listen=0
  if [[ "$PGADMIN_PORT" != "80" && "$DRY_RUN" != 1 ]]; then
    if ! grep -rqs "^Listen ${PGADMIN_PORT}\$" /etc/httpd/conf.d /etc/httpd/conf 2>/dev/null; then
      cat > /etc/httpd/conf.d/00-pgadmin-port.conf <<EOF
Listen ${PGADMIN_PORT}
<If "%{SERVER_PORT} == '${PGADMIN_PORT}' && %{REQUEST_URI} == '/'">
    Redirect "/pgadmin4/"
</If>
EOF
      created_listen=1
    fi
    if selinux_on; then semanage port -a -t http_port_t -p tcp "$PGADMIN_PORT" 2>/dev/null || true; fi
  fi
  if selinux_on && [[ "$(getsebool httpd_can_network_connect_db 2>/dev/null | awk '{print $3}')" == "off" ]]; then
    run setsebool -P httpd_can_network_connect_db 1 || true
  fi

  # Validar la configuracion de Apache antes de arrancar/recargar
  if [[ "$DRY_RUN" != 1 ]] && ! httpd -t >/dev/null 2>&1; then
    warn "La configuracion de Apache no valida (httpd -t); NO se reinicia ni recarga:"
    httpd -t || true
    if [[ $created_listen -eq 1 ]]; then rm -f /etc/httpd/conf.d/00-pgadmin-port.conf; warn "Se revirtio el Listen que agrego este script."; fi
    return 0
  fi
  if [[ $httpd_pre -eq 1 ]]; then
    run systemctl reload httpd
  else
    run systemctl enable --now httpd
  fi

  if [[ "$OPEN_PGADMIN" == 1 ]]; then fw_open "$PGADMIN_PORT"; fi
  info "pgAdmin: http://IP:${PGADMIN_PORT}/pgadmin4  (usuario ${PGADMIN_EMAIL})"
}

# ----------------------------- Ejecucion -------------------------------------
install_repo
fw_enable
install_postgres
create_app
if [[ $REMOTE_APPLIED -eq 1 || "$OPEN_PG" == 1 ]]; then fw_open "$PG_PORT"; fi
if [[ "$WITH_OBS" == 1 ]]; then
  if [[ "$PG_UP" == 1 ]]; then install_observability; else warn "Observabilidad omitida: el cluster no esta activo."; fi
fi
if [[ "$WITH_PGADMIN" == 1 ]]; then install_pgadmin; fi
if [[ -n "$EXTRA_PORTS" ]]; then
  IFS=',' read -ra _xp <<< "$EXTRA_PORTS"
  for p in "${_xp[@]}"; do
    p="${p// /}"
    if [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]]; then fw_open "$p"; else warn "Puerto extra invalido, se omite: '$p'"; fi
  done
fi
fw_reload

echo
info "================== RESUMEN =================="
info "PostgreSQL ${PG_VERSION}: puerto ${PG_PORT}, datos en ${PGDATA} (ajustes propios en conf.d/), servicio ${SVC}"
SUMMARY_PSQL="sudo -u postgres ${PGBIN}/psql -p ${PG_PORT}"
if [[ -f "$CRED_FILE" ]]; then info "Credenciales: ${CRED_FILE} (solo root)"; fi
info "Conexion local: ${SUMMARY_PSQL}"
if [[ $REMOTE_APPLIED -eq 1 ]]; then
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  info "Acceso remoto: SI (${HBA_TYPE}) desde ${ALLOW_LIST[*]:-CUALQUIER IP}"
  info "Desde otra PC: host=${SERVER_IP:-IP_DEL_SERVIDOR} port=${PG_PORT} dbname=${APP_DB:-postgres} user=${APP_USER:-postgres} sslmode=$([[ "$HBA_TYPE" == hostssl ]] && echo require || echo prefer)"
  [[ -z "$APP_USER" ]] && warn "Recomendado: un usuario propio para la aplicacion (--app-user) y --block-postgres-remote."
  [[ -n "$APP_USER" && "$APP_PASS" == "$DEFAULT_PASS" ]] && warn "El usuario ${APP_USER} usa la clave por defecto (publica) con acceso remoto: cambiela o limite las IPs."
  warn "Si su proveedor de VPS tiene un firewall propio (panel web), abra tambien alli el puerto ${PG_PORT}."
else
  [[ -n "$APP_USER" ]] && info "Usuario de la aplicacion: ${APP_USER} (bases: ${APP_DBS[*]}; clave en ${CRED_FILE})"
fi
if [[ $REMOTE_APPLIED -eq 1 ]]; then :
elif [[ $PRE_EXISTS -eq 0 || $CONFIGURED -eq 1 ]]; then
  info "Acceso remoto: NO (solo desde este servidor). Para activarlo: --configure-existing --remote"
fi
if [[ "$DRY_RUN" == 1 ]]; then
  warn "SIMULACION (--dry-run): no se instalo ni se cambio nada. Quite --dry-run para instalar."
else
  info "Respaldos de configuracion: *.bak-${STAMP}"
  info "Estado previo guardado en: ${SNAP_DIR}"
fi
info "Log completo: ${LOG_FILE}"
