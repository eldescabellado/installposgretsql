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
#   sudo ./install-postgres18.sh [opciones]
#
# OPCIONES (tambien se pueden pasar como variables de entorno):
#   --pg-port N            Puerto de PostgreSQL            (def: 5432)
#   --listen DIRS          listen_addresses                (def: localhost)
#   --allow-cidr CIDR      Red permitida remota, ej 10.0.0.0/24 (def: vacio = sin restriccion
#                          de origen en el firewall; en pg_hba solo si se define)
#   --with-observability   Instala postgres_exporter + Prometheus + Grafana
#   --with-pgadmin         Instala pgAdmin 4 (modo web, via Apache httpd)
#   --all                  Equivale a las dos anteriores
#   --grafana-port N       (def: 3000)
#   --prometheus-port N    (def: 9090, solo localhost)
#   --exporter-port N      (def: 9187, solo localhost)
#   --pgadmin-port N       (def: 5050)  URL: http://IP:PUERTO/pgadmin4
#   --pgadmin-email E      (def: admin@localhost.local)
#   --password CLAVE       Clave de administracion para postgres (si el cluster es nuevo),
#                          pgAdmin y Grafana (si se instala nuevo). Def: Jema2026#
#                          (tambien por variable ADMIN_PASSWORD, que evita dejarla en el historial)
#                          Si no la indica y hay terminal, el script le pregunta: Enter = Jema2026#
#   --yes                  No preguntar nada (usa la clave por defecto o la de --password)
#   --force-pgadmin        Instala pgAdmin aunque httpd ya este activo (afecta a sus sitios)
#   --open-observability   Abre en firewall el puerto de Grafana (def: no)
#   --open-pgadmin         Abre en firewall el puerto de pgAdmin   (def: no)
#   --open-pg              Abre en firewall el puerto de PostgreSQL (se abre solo si listen != localhost)
#   --open-all             Abre PostgreSQL + Grafana + pgAdmin en el firewall
#   --extra-ports LISTA    Puertos adicionales a abrir, separados por coma (ej: 8080,9000)
#   --dry-run              Muestra lo que haria sin ejecutar
#   -h | --help
#
# EJEMPLO:
#   sudo ./install-postgres18.sh --all --pg-port 5433 --listen '*' \
#        --allow-cidr 192.168.1.0/24 --open-all
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
PGADMIN_EMAIL="${PGADMIN_EMAIL:-admin@localhost.local}"
OPEN_OBS="${OPEN_OBS:-0}"
OPEN_PGADMIN="${OPEN_PGADMIN:-0}"
OPEN_PG="${OPEN_PG:-0}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
DRY_RUN="${DRY_RUN:-0}"

PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
PGBIN="/usr/pgsql-${PG_VERSION}/bin"
SVC="postgresql-${PG_VERSION}"
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
selinux_on() { have getenforce && [[ "$(getenforce)" != "Disabled" ]]; }

backup() { # respalda un archivo si existe
  local f="$1"
  if [[ -f "$f" ]]; then run cp -a "$f" "${f}.bak-${STAMP}"; info "Respaldo: ${f}.bak-${STAMP}"; fi
  return 0
}

port_in_use() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

usage() {
  if [[ -f "$0" ]]; then awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"
  else echo "Ayuda completa: https://github.com/eldescabellado/installposgretsql#readme"; fi
  exit 0
}

# ----------------------------- Argumentos ------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pg-port) PG_PORT="$2"; shift 2;;
    --listen) PG_LISTEN="$2"; shift 2;;
    --allow-cidr) ALLOW_CIDR="$2"; shift 2;;
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

for p in "$PG_PORT" "$GRAFANA_PORT" "$PROMETHEUS_PORT" "$EXPORTER_PORT" "$PGADMIN_PORT"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Puerto invalido: $p"
done

# ----------------------------- Clave de administracion -----------------------
# Por defecto Jema2026#. Si hay terminal y no se indico --password, se ofrece cambiarla.
# Se lee del teclado (/dev/tty) para que tambien funcione con: curl ... | sudo bash
TTY_IN=""
if [[ -t 0 ]]; then TTY_IN=/dev/stdin
elif { : < /dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi
if [[ $PASS_GIVEN -eq 0 && $NO_PROMPT -eq 0 && "$DRY_RUN" != 1 && -n "$TTY_IN" ]]; then
  echo "Clave de administracion (postgres, pgAdmin, Grafana)."
  read -rsp "Escriba otra clave o presione Enter para usar la por defecto (${DEFAULT_PASS}): " _p1 < "$TTY_IN"; echo
  if [[ -n "$_p1" ]]; then
    read -rsp "Repita la clave: " _p2 < "$TTY_IN"; echo
    [[ "$_p1" == "$_p2" ]] || die "Las claves no coinciden. No se modifico nada."
    ADMIN_PASS="$_p1"
  fi
  unset _p1 _p2
fi
[[ ${#ADMIN_PASS} -ge 8 ]] || die "La clave debe tener al menos 8 caracteres."
if [[ "$ADMIN_PASS" == "$DEFAULT_PASS" && ( "$PG_LISTEN" != "localhost" || "$OPEN_PG" == 1 || "$OPEN_PGADMIN" == 1 || "$OPEN_OBS" == 1 ) ]]; then
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
if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
  if ! check_port "$PG_PORT" "PostgreSQL"; then
    die "Elija otro puerto con --pg-port. No se modifico nada."
  fi
fi

info "Plan: PG ${PG_VERSION} puerto ${PG_PORT}, listen='${PG_LISTEN}', cidr='${ALLOW_CIDR:-ninguno}', obs=${WITH_OBS}, pgadmin=${WITH_PGADMIN}"

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
install_postgres() {
  info "Instalando paquetes PostgreSQL ${PG_VERSION}..."
  run dnf install -y "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}" \
                     "postgresql${PG_VERSION}-contrib" openssl policycoreutils-python-utils

  local fresh=0
  if [[ -f "${PGDATA}/PG_VERSION" ]]; then
    warn "Ya existe un cluster en ${PGDATA}: NO se ejecuta initdb (datos intactos)."
    warn "Cluster existente: NO se tocan su postgresql.conf, pg_hba.conf ni su servicio (puede ser de otro sistema)."
    local live; live="$(sed -n '4p' "${PGDATA}/postmaster.pid" 2>/dev/null || true)"
    if [[ "$live" =~ ^[0-9]+$ ]]; then
      if [[ "$live" != "$PG_PORT" ]]; then warn "El cluster existente escucha en el puerto ${live}; se usa ese y no ${PG_PORT}."; fi
      PG_PORT="$live"
    fi
  else
    fresh=1
    info "Inicializando cluster nuevo en ${PGDATA}..."
    PGSETUP_INITDB_OPTIONS="--auth-local=peer --auth-host=scram-sha-256 --data-checksums --encoding=UTF8" \
      run "${PGBIN}/postgresql-${PG_VERSION}-setup" initdb
  fi

  # --- configuracion modular via conf.d (solo cluster nuevo) ---
  local conf="${PGDATA}/postgresql.conf" confd="${PGDATA}/conf.d"
  if [[ "$DRY_RUN" != 1 && $fresh -eq 1 ]]; then
    install -d -o postgres -g postgres -m 700 "$confd"
    if ! grep -Eq "^\s*include_dir\s*=\s*'conf.d'" "$conf"; then
      backup "$conf"
      printf "\n# agregado por install-postgres18.sh\ninclude_dir = 'conf.d'\n" >> "$conf"
    fi
    local mine="${confd}/90-install-script.conf"
    {
      echo "# generado por install-postgres18.sh ${STAMP}"
      echo "port = ${PG_PORT}"
      echo "listen_addresses = '${PG_LISTEN}'"
      echo "track_io_timing = on"
      echo "log_line_prefix = '%m [%p] %q%u@%d '"
      echo "log_min_duration_statement = 1000"
      echo "log_checkpoints = on"
      echo "log_lock_waits = on"
      echo "shared_preload_libraries = 'pg_stat_statements'"
      echo "pg_stat_statements.track = all"
    } > "$mine"
    chown postgres:postgres "$mine"; chmod 600 "$mine"
  fi

  # --- acceso remoto en pg_hba (solo cluster nuevo y solo si se definio CIDR) ---
  if [[ -n "$ALLOW_CIDR" && "$DRY_RUN" != 1 && $fresh -eq 1 ]]; then
    local hba="${PGDATA}/pg_hba.conf"
    if ! grep -q "install-postgres18.sh ${ALLOW_CIDR}" "$hba"; then
      backup "$hba"
      printf "\n# install-postgres18.sh %s\nhost    all    all    %s    scram-sha-256\n" "$ALLOW_CIDR" "$ALLOW_CIDR" >> "$hba"
    fi
  elif [[ "$PG_LISTEN" != "localhost" && -z "$ALLOW_CIDR" && $fresh -eq 1 ]]; then
    warn "Escucha en '${PG_LISTEN}' sin --allow-cidr: pg_hba no se modifico, solo conexiones locales hasta que agregue una regla."
  fi

  # --- SELinux: puerto no estandar (solo cluster nuevo) ---
  if [[ "$PG_PORT" != "5432" && $fresh -eq 1 ]] && selinux_on; then
    run semanage port -a -t postgresql_port_t -p tcp "$PG_PORT" 2>/dev/null \
      || run semanage port -m -t postgresql_port_t -p tcp "$PG_PORT" || true
  fi

  # --- servicio ---
  if [[ $fresh -eq 1 ]]; then
    run systemctl enable "$SVC"
    run systemctl start "$SVC"
  elif systemctl is-active --quiet "$SVC"; then
    info "Servicio ${SVC} ya activo: no se reinicia ni se recarga."
  else
    warn "El cluster existente en ${PGDATA} no esta activo: NO se inicia (puede ser de otro sistema). La observabilidad se omitira."
    PG_UP=0
  fi

  # --- credenciales (solo cluster nuevo) ---
  if [[ $fresh -eq 1 && "$DRY_RUN" != 1 ]]; then
    local pw="$ADMIN_PASS" pw_sql="${ADMIN_PASS//\'/\'\'}"
    sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -qc "ALTER ROLE postgres PASSWORD '${pw_sql}'"
    sudo -u postgres "${PGBIN}/psql" -p "$PG_PORT" -qc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" || true
    ( umask 077; { echo "# generado ${STAMP}"; echo "POSTGRES_PASSWORD=${pw}"; } >> "$CRED_FILE" )
    info "Password de 'postgres' guardado en ${CRED_FILE}"
  fi
}

# ----------------------------- 3) Firewall -----------------------------------
fw_open() { # puerto
  local port="$1"
  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld inactivo: no se abre ${port}/tcp (revise su firewall)."; return 0
  fi
  if [[ -n "$ALLOW_CIDR" ]]; then
    run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOW_CIDR} port port=${port} protocol=tcp accept"
  else
    run firewall-cmd --permanent --add-port="${port}/tcp"
  fi
  FW_CHANGED=1; info "Firewall: abierto ${port}/tcp ${ALLOW_CIDR:+(origen ${ALLOW_CIDR})}"
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
      echo "Listen ${PGADMIN_PORT}" > /etc/httpd/conf.d/00-pgadmin-port.conf
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
install_postgres
if [[ "$PG_LISTEN" != "localhost" || "$OPEN_PG" == 1 ]]; then fw_open "$PG_PORT"; fi
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
info "PostgreSQL ${PG_VERSION}: puerto ${PG_PORT}, datos en ${PGDATA}, servicio ${SVC}"
if [[ -f "$CRED_FILE" ]]; then info "Credenciales: ${CRED_FILE} (solo root)"; fi
info "Conexion local: sudo -u postgres ${PGBIN}/psql -p ${PG_PORT}"
if [[ "$DRY_RUN" == 1 ]]; then
  warn "SIMULACION (--dry-run): no se instalo ni se cambio nada. Quite --dry-run para instalar."
else
  info "Respaldos de configuracion: *.bak-${STAMP}"
  info "Estado previo guardado en: ${SNAP_DIR}"
fi
info "Log completo: ${LOG_FILE}"
