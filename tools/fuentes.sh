#!/usr/bin/env bash
# fuentes.sh — Descarga el código fuente de todos los paquetes de unas imágenes de Llevix.
#
# Uso (DENTRO de un contenedor desechable, como root):
#   ./tools/fuentes.sh <base> <carpeta-salida> <llevix-variante.paquetes.txt>...
#
#   base: ubuntu | mint | debian | zorin  (mismo sistema que las imágenes)
#
# Lee las columnas 3 y 4 de cada paquetes.txt (paquete fuente y versión exacta), configura
# los repositorios de código fuente (deb-src) de esa base y descarga cada paquete con
# `apt-get source --download-only paquete=versión`. Firefox (repositorio de Mozilla, sin
# deb-src) se descarga de archive.mozilla.org.
#
# Sale en <carpeta-salida>:
#   <paquete>/…            archivos .dsc, .orig.tar.*, .debian.tar.* de cada paquete
#   descargados.txt        "paquete versión" que se obtuvieron
#   faltantes.txt          "paquete versión motivo" que no se pudieron obtener
#
# Lo usa .github/workflows/fuentes.yml para cumplir la GPL: cada versión publicada guarda
# el código fuente de lo que distribuye (ver docs/CODIGO-FUENTE.md).

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -ge 3 ]] || { echo "uso: $0 <ubuntu|mint|debian|zorin> <salida> <paquetes.txt>..." >&2; exit 2; }
BASE="$1"; SALIDA="$2"; shift 2
[[ "$BASE" =~ ^(ubuntu|mint|debian|zorin)$ ]] || { echo "base desconocida: $BASE" >&2; exit 2; }
# Cambia la configuración de apt del sistema: solo dentro de un contenedor.
[[ -f /.dockerenv || -f /run/.containerenv ]] || { echo "ejecutar solo dentro de un contenedor" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "necesita root (dentro del contenedor)" >&2; exit 2; }

# Datos de los repositorios, los mismos que usa la construcción de las imágenes.
eval "$(grep -E '^(MINT_REPO|MINT_LLAVE_URL|MINT_LLAVE_SHA256)=' "$DIR_REPO/image/build.sh")"
MINT_SUITE="$(sed -n 's/^MINT_SUITE="\(.*\)"/\1/p' "$DIR_REPO/image/distros/mint-22-cinnamon.conf")"
ZORIN_REPO="https://packages.zorinos.com"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$SALIDA"
SALIDA="$(realpath "$SALIDA")"
: > "$SALIDA/descargados.txt"
: > "$SALIDA/faltantes.txt"

# ---------- Repositorios de código fuente ----------

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*

case "$BASE" in
    debian)
        cat > /etc/apt/sources.list.d/fuentes.sources <<'EOF'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        ;;
    ubuntu|mint|zorin)
        cat > /etc/apt/sources.list.d/fuentes.sources <<'EOF'
Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        ;;
esac

apt-get -o Acquire::Retries=5 update -qq
apt-get install -y -qq ca-certificates curl dpkg-dev jq >/dev/null

if [[ "$BASE" == "mint" ]]; then
    curl -fsSL --retry 5 --retry-all-errors -o /tmp/mint-llave.deb "$MINT_LLAVE_URL"
    echo "$MINT_LLAVE_SHA256  /tmp/mint-llave.deb" | sha256sum -c -
    dpkg -i /tmp/mint-llave.deb >/dev/null
    echo "deb-src $MINT_REPO $MINT_SUITE main upstream import backport" > /etc/apt/sources.list.d/mint.list
fi
if [[ "$BASE" == "zorin" ]]; then
    # Zorin publica su repositorio por https; su llave no está en Ubuntu. El código se
    # guarda solo para archivo (la conexión https protege la descarga).
    for r in stable patches apps drivers; do
        echo "deb-src [trusted=yes] $ZORIN_REPO/$r noble main" >> /etc/apt/sources.list.d/zorin.list
    done
fi

# Un repositorio que no responda no detiene todo: lo que falte queda en faltantes.txt.
apt-get -o Acquire::Retries=5 update || echo "Aviso: algún repositorio de código fuente no respondió"

# ---------- Lista de paquetes fuente ----------

lista="$(mktemp)"
cat "$@" | awk -F'\t' 'NF >= 4 && $3 != "" {print $3 "\t" $4}' | sort -u > "$lista"
echo "Paquetes fuente distintos: $(wc -l < "$lista")"

# Firefox y sus idiomas vienen del repositorio de Mozilla, que no tiene deb-src.
firefox_version="$(awk -F'\t' '$1 == "firefox" && $2 ~ /~build/ {print $2; exit}' "$lista")"
if [[ -n "$firefox_version" ]]; then
    v="${firefox_version%%~*}"
    mkdir -p "$SALIDA/firefox"
    if curl -fsSL --retry 5 --retry-all-errors -o "$SALIDA/firefox/firefox-$v.source.tar.xz" \
        "https://archive.mozilla.org/pub/firefox/releases/$v/source/firefox-$v.source.tar.xz"; then
        printf 'firefox\t%s\n' "$firefox_version" >> "$SALIDA/descargados.txt"
    else
        printf 'firefox\t%s\tno se pudo descargar de archive.mozilla.org\n' "$firefox_version" >> "$SALIDA/faltantes.txt"
    fi
    awk -F'\t' '$1 ~ /^firefox-l10n-/ && $2 ~ /~build/ {print $1 "\t" $2 "\ttraducciones de Mozilla: https://github.com/mozilla-l10n/firefox-l10n"}' \
        "$lista" >> "$SALIDA/faltantes.txt"
    awk -F'\t' '!($1 ~ /^firefox(-l10n-.*)?$/ && $2 ~ /~build/)' "$lista" > "$lista.resto"
    mv "$lista.resto" "$lista"
fi

# ---------- Descarga ----------

uri() { jq -rn --arg t "$1" '$t|@uri'; }

bajar() {  # bajar <url> <carpeta>: guarda con el nombre del archivo (sin %2B, %3A…)
    local nombre
    nombre="$(basename "$1")"
    nombre="$(printf '%b' "${nombre//%/\x}")"
    curl -fsSL --retry 5 --retry-all-errors -o "$2/$nombre" "$1"
}

# Respaldo 1 (Ubuntu, Mint y Zorin): Launchpad guarda para siempre el código de cada
# versión publicada en Ubuntu, aunque ya haya una más nueva en los repositorios.
respaldo_launchpad() {  # <paquete> <versión> <carpeta>
    local enlace u
    enlace="$(curl -fsS --retry 3 "https://api.launchpad.net/1.0/ubuntu/+archive/primary?ws.op=getPublishedSources&exact_match=true&source_name=$(uri "$1")&version=$(uri "$2")" \
        | jq -r '.entries[0].self_link // empty')" || return 1
    [[ -n "$enlace" ]] || return 1
    for u in $(curl -fsS --retry 3 "$enlace?ws.op=sourceFileUrls" | jq -r '.[]'); do
        bajar "$u" "$3" || return 1
    done
    compgen -G "$3/*.dsc" >/dev/null
}

# Respaldo 2 (Mint): el "pool" del repositorio de Mint conserva versiones anteriores.
respaldo_mint() {  # <paquete> <versión> <carpeta>
    local p="$1" v="${2#*:}" pre comp dsc f
    if [[ "$p" == lib* ]]; then pre="${p:0:4}"; else pre="${p:0:1}"; fi
    for comp in main upstream import backport; do
        dsc="$MINT_REPO/pool/$comp/$pre/$p/${p}_${v}.dsc"
        bajar "$dsc" "$3" 2>/dev/null || continue
        # Los demás archivos están listados en la sección Files: del .dsc.
        while read -r f; do
            bajar "$MINT_REPO/pool/$comp/$pre/$p/$f" "$3" || return 1
        done < <(awk '/^Files:/ {e=1; next} /^[^ ]/ {e=0} e {print $3}' "$3/${p}_${v}.dsc")
        return 0
    done
    return 1
}

# Respaldo 3 (Debian): snapshot.debian.org guarda todas las versiones de Debian.
respaldo_debian() {  # <paquete> <versión> <carpeta>
    local hash nombre
    curl -fsS --retry 3 "https://snapshot.debian.org/mr/package/$(uri "$1")/$(uri "$2")/srcfiles?fileinfo=1" \
        | jq -r '.fileinfo | to_entries[] | "\(.key) \(.value[0].name)"' > "$3/.lista" || return 1
    [[ -s "$3/.lista" ]] || return 1
    while read -r hash nombre; do
        curl -fsSL --retry 5 --retry-all-errors -o "$3/$nombre" "https://snapshot.debian.org/file/$hash" || return 1
    done < "$3/.lista"
    rm -f "$3/.lista"
}

descargar() {  # descargar <paquete> <versión>
    local p="$1" v="$2" d="$SALIDA/$1" ok=no
    mkdir -p "$d"
    if (cd "$d" && apt-get source -qq --download-only -o Acquire::Retries=5 "$p=$v" >/dev/null 2>&1); then
        ok=si
    else
        case "$BASE" in
            debian) respaldo_debian "$p" "$v" "$d" && ok=si ;;
            mint) { respaldo_mint "$p" "$v" "$d" || respaldo_launchpad "$p" "$v" "$d"; } && ok=si ;;
            *) respaldo_launchpad "$p" "$v" "$d" && ok=si ;;
        esac
    fi
    if [[ "$ok" == si ]]; then
        printf '%s\t%s\n' "$p" "$v" >> "$SALIDA/descargados.txt"
        return 0
    fi
    rm -rf "$d"
    local motivo="no está en los repositorios de código fuente"
    [[ "$BASE" == zorin && "$v" != *ubuntu* ]] && motivo="código de Zorin OS: https://github.com/ZorinOS"
    printf '%s\t%s\t%s\n' "$p" "$v" "$motivo" >> "$SALIDA/faltantes.txt"
}
export -f uri bajar respaldo_launchpad respaldo_mint respaldo_debian descargar
export SALIDA BASE MINT_REPO

# Varias descargas a la vez; cada línea se escribe completa (son líneas cortas).
# shellcheck disable=SC2016  # $0 y $1 los expande el bash hijo, no este
tr '\t' ' ' < "$lista" | xargs -P 6 -n 2 bash -c 'descargar "$0" "$1"'

sort -o "$SALIDA/descargados.txt" "$SALIDA/descargados.txt"
sort -o "$SALIDA/faltantes.txt" "$SALIDA/faltantes.txt"
echo "Descargados: $(wc -l < "$SALIDA/descargados.txt")  Faltantes: $(wc -l < "$SALIDA/faltantes.txt")"
du -sh "$SALIDA"
