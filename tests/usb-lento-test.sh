#!/usr/bin/env bash
# usb-lento-test.sh — Llevix en una memoria USB lenta (como las más baratas).
#
# Uso: ./tests/usb-lento-test.sh <imagen.img>
#
# QEMU limita la velocidad del disco virtual a la de una memoria USB barata
# (lectura ~20 MB/s, escritura ~3 MB/s). Con esa velocidad se mide:
#   1. Cuánto tarda en abrir el navegador por primera vez (crea su perfil).
#   2. Mientras otro programa escribe un archivo grande: cuánto tarda en guardarse un
#      archivo pequeño y cuánto tarda en abrir el navegador. Sin el ajuste de Llevix
#      (image/overlay/etc/sysctl.d/60-llevix-escritura.conf) el sistema se congela
#      minutos; se mide también sin el ajuste, solo para comparar.
#
# No necesita root. Trabaja sobre una copia de la imagen.
#
# Los comandos que corren dentro de Llevix van entre comillas simples a propósito:
# sus $(...) y $variables se expanden allá, no aquí.
# shellcheck disable=SC2016

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"
MODO="${LLEVIX_TEST_MODO:-uefi-sb}"
USUARIO="prueba"
# Velocidad de una memoria USB barata (bytes por segundo y operaciones de escritura).
LENTO="throttling.bps-read=20971520,throttling.bps-write=3145728,throttling.iops-write=60"
# Límites (segundos) con el ajuste de Llevix activo.
MAX_NAVEGADOR=240
MAX_GUARDAR=30
MAX_NAVEGADOR_CARGA=300

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -eq 1 ]] || { echo "uso: $0 <imagen.img>" >&2; exit 2; }
IMG="$(realpath "$1")"
[[ -f "$IMG" ]] || { echo "no existe la imagen: $IMG" >&2; exit 2; }
for h in mcopy partx openssl; do
    command -v "$h" >/dev/null || { echo "falta $h (paquetes mtools, util-linux, openssl)" >&2; exit 2; }
done
qemu_requisitos

mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d "$DIR_PRUEBAS/trabajo.XXXXXX")"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT

fallos=0
ok()    { printf '  \e[32m[ok]\e[0m    %s\n' "$*"; }
falla() { printf '  \e[31m[falla]\e[0m %s\n' "$*"; fallos=$((fallos + 1)); }
info()  { printf '  [info]  %s\n' "$*"; }

# en_llevix <comando> [segundos] → deja la salida en $TRABAJO/salida.txt.
# Sin $(...): la conexión con el agente no está disponible dentro de un subshell.
en_llevix() {
    qga_ejecutar "$1" "${2:-120}" > "$TRABAJO/salida.txt" 2>&1
}
salida() { tail -n 1 "$TRABAJO/salida.txt"; }

# Abre el navegador sin pantalla, con un perfil nuevo, y escribe "<segundos> <código>".
NAVEGADOR='ff=""
for b in /usr/lib/firefox/firefox /usr/lib/firefox-esr/firefox-esr /usr/bin/firefox; do
    [ -x "$b" ] && { ff="$b"; break; }
done
[ -n "$ff" ] || { echo "0 99"; exit 0; }
rm -rf /home/'"$USUARIO"'/.mozilla /home/'"$USUARIO"'/.config/mozilla /home/'"$USUARIO"'/.cache/mozilla
sync; echo 3 > /proc/sys/vm/drop_caches
s=$(date +%s)
su - '"$USUARIO"' -c "MOZ_HEADLESS=1 timeout 280 $ff --headless --screenshot /tmp/llevix-ff.png about:blank" >/dev/null 2>&1
r=$?
echo "$(( $(date +%s) - s )) $r"'

# Guarda un archivo pequeño (con fsync, como hace cualquier programa al guardar) y
# escribe los segundos que tardó.
GUARDAR='s=$(date +%s)
echo prueba > /home/'"$USUARIO"'/pequeno.txt
timeout 590 sync /home/'"$USUARIO"'/pequeno.txt || { echo 600; exit 0; }
echo $(( $(date +%s) - s ))'

# Otro programa escribe 1,5 GB (datos aleatorios: la compresión no los achica).
CARGA_INICIAR='setsid nohup su - '"$USUARIO"' -c "head -c 1536M /dev/urandom > /home/'"$USUARIO"'/grande.bin" >/dev/null 2>&1 < /dev/null &
sleep 20'
CARGA_PARAR='pkill -f "head -c 1536M" || true
sleep 2
rm -f /home/'"$USUARIO"'/grande.bin /home/'"$USUARIO"'/pequeno.txt
sync'

# medir_con_carga <etiqueta> → deja T_GUARDAR y T_NAV (segundos) y C_NAV (código).
medir_con_carga() {
    T_GUARDAR=600; T_NAV=999; C_NAV=1
    en_llevix "$CARGA_INICIAR" 60 || true
    if en_llevix "$GUARDAR" 620; then T_GUARDAR="$(salida)"; fi
    info "$1: guardar un archivo pequeño tardó ${T_GUARDAR} s"
    if en_llevix "$NAVEGADOR" 320; then read -r T_NAV C_NAV <<<"$(salida)"; fi
    info "$1: el navegador abrió en ${T_NAV} s (código $C_NAV)"
    en_llevix "$CARGA_PARAR" 900 || info "$1: limpiar la carga tardó demasiado"
}

"$DIR_REPO/tools/make-config.sh" --usuario "$USUARIO" --contrasena "clave-de-prueba" \
    > "$TRABAJO/config.json"
preparar_disco "$IMG" "$TRABAJO/disco.img" 32G "$TRABAJO/config.json"

# ---------- Primer arranque a velocidad normal (crea el usuario) ----------

echo; echo "Primer arranque (velocidad normal): se crea el usuario"
qemu_iniciar usb-lento-1 "$MODO" "$TRABAJO/disco.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    if [[ "$INFORME_PRIMER_ARRANQUE" == *"resultado=ok"* ]]; then
        ok "llevix-firstboot terminó bien"
    else
        falla "llevix-firstboot no terminó bien ($INFORME_PRIMER_ARRANQUE)"
    fi
else
    falla "el primer arranque no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || falla "no se apagó ordenadamente"

# ---------- Arranque con el disco a velocidad de USB barato ----------

echo; echo "Arranque con el disco lento (lectura 20 MB/s, escritura 3 MB/s)"
inicio=$SECONDS
LLEVIX_TEST_DISCO_OPC="$LENTO" LLEVIX_TEST_MEM=8192 \
    qemu_iniciar usb-lento-2 "$MODO" "$TRABAJO/disco.img" raw
if qemu_esperar_informe $((TIMEOUT * 2)) && qga_esperar 300; then
    info "llegó al escritorio en $((SECONDS - inicio)) s"
    qemu_captura "$DIR_PRUEBAS/usb-lento.png"

    if en_llevix "sysctl -n vm.dirty_bytes vm.dirty_background_bytes | tr '\n' ' '"; then
        valores="$(salida)"
        if [[ "$valores" == "50331648 16777216"* ]]; then
            ok "el ajuste de escritura de a poco está activo ($valores)"
        else
            falla "el ajuste de escritura no está activo ($valores)"
        fi
    else
        falla "no se pudo leer el ajuste de escritura"
    fi

    echo; echo "1. Abrir el navegador por primera vez"
    t=999; c=1
    if en_llevix "$NAVEGADOR" 320; then read -r t c <<<"$(salida)"; fi
    if [[ "$c" == 99 ]]; then
        info "no hay Firefox en esta variante: se omite la medición del navegador"
    elif [[ "$c" == 0 ]] && (( t <= MAX_NAVEGADOR )); then
        ok "el navegador abrió en $t s (límite $MAX_NAVEGADOR s)"
    else
        falla "el navegador tardó $t s o falló (código $c; límite $MAX_NAVEGADOR s)"
    fi

    echo; echo "2. Con otro programa escribiendo un archivo grande (ajuste de Llevix)"
    medir_con_carga "con el ajuste"
    if (( T_GUARDAR <= MAX_GUARDAR )); then
        ok "guardar un archivo no se congela: ${T_GUARDAR} s (límite $MAX_GUARDAR s)"
    else
        falla "guardar un archivo tardó ${T_GUARDAR} s (límite $MAX_GUARDAR s)"
    fi
    if [[ "$C_NAV" == 99 ]]; then
        :
    elif [[ "$C_NAV" == 0 ]] && (( T_NAV <= MAX_NAVEGADOR_CARGA )); then
        ok "el navegador abre aunque se esté escribiendo: ${T_NAV} s (límite $MAX_NAVEGADOR_CARGA s)"
    else
        falla "con escritura de fondo el navegador tardó ${T_NAV} s o falló (código $C_NAV)"
    fi

    echo; echo "3. Lo mismo SIN el ajuste (valores normales de Linux), solo para comparar"
    if en_llevix "sysctl -q -w vm.dirty_ratio=20 vm.dirty_background_ratio=10"; then
        medir_con_carga "sin el ajuste"
    else
        info "no se pudieron poner los valores normales"
    fi
else
    falla "con el disco lento no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || true

echo
if (( fallos == 0 )); then
    printf '\e[32mUSB lento: todas las comprobaciones pasaron.\e[0m\n'
else
    printf '\e[31mUSB lento: %d comprobación(es) fallaron.\e[0m\n' "$fallos"
fi
(( fallos == 0 ))
