#!/usr/bin/env bash
# =============================================================================
# instalar.sh - instalador de un solo comando (sin clonar el repositorio)
#
#   curl -fsSL https://raw.githubusercontent.com/eldescabellado/installposgretsql/main/instalar.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/eldescabellado/installposgretsql/main/instalar.sh | sudo bash -s -- --all --open-all
#
# Detecta el sistema operativo, descarga el script que corresponde y lo ejecuta
# con las opciones que se pasen despues de 'bash -s --':
#   CentOS / RHEL / Rocky / Alma 10  -> install-postgres18.sh
#   Ubuntu / Debian                  -> install-postgres18-ubuntu.sh
#
# Opciones propias de este lanzador (el resto pasa tal cual al instalador):
#   --ref RAMA_O_TAG   Rama o tag del repositorio a usar (def: main)
#   --solo-descargar   Solo descarga el instalador a /root para revisarlo antes
# =============================================================================
# Todo va dentro de main(): si la descarga de este archivo se corta a la mitad,
# bash no ejecuta nada parcial.
set -Eeuo pipefail

main() {
  local repo="eldescabellado/installposgretsql"
  local ref="${INSTALL_REF:-main}" solo_descargar=0
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref) ref="$2"; shift 2;;
      --solo-descargar) solo_descargar=1; shift;;
      *) args+=("$1"); shift;;
    esac
  done

  err() { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }
  [[ $EUID -eq 0 ]] || err "Ejecute como root:  curl -fsSL ... | sudo bash"
  [[ -r /etc/os-release ]] || err "No se encontro /etc/os-release; sistema no soportado."
  # shellcheck disable=SC1091
  . /etc/os-release

  local script
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*) script="install-postgres18-ubuntu.sh";;
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) script="install-postgres18.sh";;
    *) err "Sistema no soportado: ${PRETTY_NAME:-desconocido}. Soportados: Ubuntu/Debian y CentOS/RHEL 10.";;
  esac

  local url="https://raw.githubusercontent.com/${repo}/${ref}/${script}"
  local tmp; tmp="$(mktemp /tmp/pg18-installer.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT

  echo -e "\e[32m[+]\e[0m Sistema: ${PRETTY_NAME:-?}  ->  ${script} (${ref})"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$tmp" "$url" || err "No se pudo descargar ${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$url" || err "No se pudo descargar ${url}"
  else
    err "Se necesita curl o wget."
  fi

  # Validaciones minimas: que sea el script esperado y no una pagina de error
  sed -i 's/\r$//' "$tmp"
  head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || err "La descarga no parece un script valido (${url})."
  bash -n "$tmp" || err "El script descargado tiene errores de sintaxis; no se ejecuta."

  if [[ $solo_descargar -eq 1 ]]; then
    install -m 700 "$tmp" "/root/${script}"
    echo -e "\e[32m[+]\e[0m Descargado en /root/${script}. Reviselo y ejecute:  sudo bash /root/${script} --help"
    return 0
  fi

  # Con 'curl | bash' la entrada estandar es el propio script: el instalador se
  # conecta al teclado (/dev/tty) si existe; si no, no recibe entrada (modo --yes implicito).
  if { : < /dev/tty; } 2>/dev/null; then
    bash "$tmp" "${args[@]}" < /dev/tty
  else
    bash "$tmp" "${args[@]}" < /dev/null
  fi
}

main "$@"
