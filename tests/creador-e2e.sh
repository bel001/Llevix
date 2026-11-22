#!/usr/bin/env bash
# creador-e2e.sh — Prueba de punta a punta del creador con un disco simulado.
#
# Uso: ./tests/creador-e2e.sh <variante>
#
# 1. Genera un llevix-config.json de prueba.
# 2. El núcleo del creador (ejemplo escribir_en_archivo) descarga la última versión
#    publicada, la escribe en un ARCHIVO de 32 GiB (disco simulado) y deja el config en la ESP.
# 3. Arranca ese disco en QEMU (UEFI + Secure Boot, como memoria USB) y comprueba que el
#    primer arranque creó la cuenta y amplió LLEVIX-DATOS.
#
# No necesita root y nunca toca discos reales.

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"
USUARIO="e2e"

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -eq 1 ]] || { echo "uso: $0 <variante>" >&2; exit 2; }
VARIANTE="$1"
qemu_requisitos
command -v cargo >/dev/null || { echo "falta cargo (Rust)" >&2; exit 2; }

mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d "$DIR_PRUEBAS/e2e.XXXXXX")"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT

fallos=0
ok()    { printf '  \e[32m[ok]\e[0m    %s\n' "$*"; }
falla() { printf '  \e[31m[falla]\e[0m %s\n' "$*"; fallos=$((fallos + 1)); }
comprobar() {
    if qga_ejecutar "$2" > "$TRABAJO/salida.txt" 2>&1; then ok "$1"; else falla "$1"; sed 's/^/          /' "$TRABAJO/salida.txt"; fi
}

"$DIR_REPO/tools/make-config.sh" --usuario "$USUARIO" --nombre-completo "Prueba Creador" \
    --contrasena "clave-e2e" --idioma es_AR.UTF-8 --zona America/Argentina/Buenos_Aires \
    --teclado latam --hostname llevix-e2e > "$TRABAJO/config.json"

echo "Escribiendo $VARIANTE con el núcleo del creador en un disco simulado de 32 GiB…"
(cd "$DIR_REPO/creator" && cargo run --quiet --release -p llevix-nucleo --example escribir_en_archivo -- \
    "$VARIANTE" "$TRABAJO/disco.img" 32 "$TRABAJO/config.json" "${LLEVIX_CACHE:-$DIR_PRUEBAS/cache}")

echo; echo "Arrancando el disco escrito por el creador"
qemu_iniciar e2e uefi-sb "$TRABAJO/disco.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    qemu_captura "$DIR_PRUEBAS/e2e-pantalla.png"
    if [[ "$INFORME_PRIMER_ARRANQUE" == *"resultado=ok"* ]]; then ok "el primer arranque aplicó la configuración del creador"; else falla "primer arranque: $INFORME_PRIMER_ARRANQUE"; fi
    if [[ "$INFORME_MODO" == "uefi-sb" ]]; then ok "arrancó con Secure Boot"; else falla "modo: $INFORME_MODO"; fi
    comprobar "existe la cuenta creada en el creador" "id $USUARIO"
    comprobar "la contraseña es la del creador (hash SHA-512)" "getent shadow $USUARIO | cut -d: -f2 | grep -q '^\\\$6\\\$'"
    comprobar "idioma y zona del creador" "grep -q es_AR /etc/default/locale && readlink /etc/localtime | grep -q Buenos_Aires"
    comprobar "LLEVIX-DATOS ocupa el resto del disco de 32 GiB" \
        "test \$(lsblk -bno SIZE /dev/disk/by-partlabel/LLEVIX-DATOS) -gt 6000000000"
    comprobar "Datos montado" "findmnt /home/$USUARIO/Datos >/dev/null"
else
    falla "el disco escrito por el creador no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || true

echo
if (( fallos == 0 )); then
    printf '\e[32mCreador de punta a punta: todo bien.\e[0m\n'
else
    printf '\e[31mCreador de punta a punta: %d comprobación(es) fallaron.\e[0m\n' "$fallos"
fi
(( fallos == 0 ))
