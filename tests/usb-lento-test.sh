#!/usr/bin/env bash
# usb-lento-test.sh — Llevix en una memoria USB lenta (como las más baratas).
#
# Uso: ./tests/usb-lento-test.sh <imagen.img>
#
# QEMU limita la velocidad del disco virtual a la de una memoria USB barata
# (lectura ~20 MB/s, escritura ~3 MB/s). Con esa velocidad se mide:
#   1. Cuánto tarda en abrir el navegador por primera vez (crea su perfil), cuánto lee
#      y cuánto escribe. También a velocidad normal, para comparar.
#   2. Mientras otro programa escribe un archivo grande: cuánto tarda en guardarse un
#      archivo pequeño y cuánto tarda en abrir el navegador (solo para comparar).
#   3. Lo mismo con la escritura en prioridad de disco baja, como quedan las
#      actualizaciones en Llevix: el navegador debe abrir.
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
# Velocidad de una memoria USB barata: lectura 20 MB/s, escritura 3 MB/s y, como en una
# memoria real, lecturas y escrituras se reparten el mismo canal (100 operaciones de
# 64 KiB por segundo entre las dos).
LENTO="throttling.bps-read=20971520,throttling.bps-write=3145728,throttling.iops-total=100,throttling.iops-size=65536"
# Límites (segundos).
MAX_NAVEGADOR=120
MAX_GUARDAR=30
MAX_NAVEGADOR_CARGA=240

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

# Abre el navegador sin pantalla, con un perfil nuevo (como la primera vez), y escribe
# en la última línea "<segundos> <código> <MB leídos> <MB escritos>" (del disco del
# sistema). Si tarda o falla, antes muestra el final de lo que dijo el navegador.
# Firefox en casi todas las variantes; Brave en Zorin OS.
NAVEGADOR='h=/home/'"$USUARIO"'
cmd=""
for b in /usr/lib/firefox/firefox /usr/lib/firefox-esr/firefox-esr /usr/bin/firefox; do
    [ -x "$b" ] && { cmd="env MOZ_HEADLESS=1 $b --headless --screenshot /tmp/llevix-nav.png about:blank"; break; }
done
if [ -z "$cmd" ]; then
    for b in /usr/bin/brave-browser /usr/bin/chromium /usr/bin/google-chrome; do
        [ -x "$b" ] && { cmd="$b --headless=new --no-sandbox --disable-gpu --no-first-run --screenshot=/tmp/llevix-nav.png about:blank"; break; }
    done
fi
[ -n "$cmd" ] || { echo "0 99 0 0"; exit 0; }
rm -rf "$h/.mozilla" "$h/.config/mozilla" "$h/.cache/mozilla" "$h/.config/BraveSoftware" "$h/.cache/BraveSoftware" "$h/.config/chromium" "$h/.cache/chromium"
d=$(lsblk -no PKNAME "$(findmnt -no SOURCE / | sed "s/\[.*//")")
echo 3 > /proc/sys/vm/drop_caches
set -- $(cat /sys/block/$d/stat); l0=$3; e0=$7
s=$(date +%s)
su - '"$USUARIO"' -c "timeout 280 $cmd" > /tmp/llevix-nav.log 2>&1
r=$?
t=$(( $(date +%s) - s ))
set -- $(cat /sys/block/$d/stat)
if [ "$r" != 0 ] || [ "$t" -gt 60 ]; then echo "navegador: $cmd"; tail -n 12 /tmp/llevix-nav.log; fi
echo "$t $r $(( ($3 - l0) / 2048 )) $(( ($7 - e0) / 2048 ))"'

# Guarda un archivo pequeño (con fsync, como hace cualquier programa al guardar) y
# escribe los segundos que tardó.
GUARDAR='s=$(date +%s)
echo prueba > /home/'"$USUARIO"'/pequeno.txt
timeout 590 sync /home/'"$USUARIO"'/pequeno.txt || { echo 600; exit 0; }
echo $(( $(date +%s) - s ))'

# Otro programa escribe 1,5 GB (datos aleatorios: la compresión no los achica).
CARGA_INICIAR='setsid nohup su - '"$USUARIO"' -c "head -c 1536M /dev/urandom > /home/'"$USUARIO"'/grande.bin" >/dev/null 2>&1 < /dev/null &
sleep 20'
# "pkill -x head": por nombre exacto (con -f se mataría a sí mismo, porque este mismo
# comando contiene el texto buscado).
CARGA_PARAR='pkill -x head || true
sleep 2
rm -f /home/'"$USUARIO"'/grande.bin /home/'"$USUARIO"'/pequeno.txt
sync'

# Deja Llevix quieto 5 minutos y cuenta qué se escribe solo: total del disco y los
# programas que más escriben. Muestra también el planificador del disco y qué
# actualizaciones automáticas están activas.
QUIETO='d=$(lsblk -no PKNAME "$(findmnt -no SOURCE / | sed "s/\[.*//")")
echo "planificador: $(cat /sys/block/$d/queue/scheduler) (rotacional=$(cat /sys/block/$d/queue/rotational))"
for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service packagekit.service fwupd-refresh.timer man-db.timer; do
    printf "%s=%s " "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo no)"
done; echo
grep -hs "APT::Periodic" /etc/apt/apt.conf.d/* | tr "\n" " "; echo
foto() { for p in /proc/[0-9]*; do
    w=$(awk "/^write_bytes/{print \$2}" "$p/io" 2>/dev/null) || continue
    echo "${p#/proc/} $(cat "$p/comm" 2>/dev/null | tr " " "_") ${w:-0}"
done; }
foto > /tmp/io0
set -- $(cat /sys/block/$d/stat); l0=$3; e0=$7
sleep 300
foto > /tmp/io1
set -- $(cat /sys/block/$d/stat)
echo "en 5 minutos sin tocar nada: leyó $(( ($3 - l0) / 2048 )) MB y escribió $(( ($7 - e0) / 2048 )) MB"
echo "programas que más escribieron:"
awk "NR==FNR{a[\$1]=\$3;next} {x=\$3-((\$1 in a)?a[\$1]:0); if (x>=1048576) printf \"  %s %d MB\n\", \$2, x/1048576}" /tmp/io0 /tmp/io1 | sort -k2 -nr | head -n 10
echo "servicios en marcha relacionados:"
systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -Ei "apt|packagekit|unattended|update|tracker|localsearch|flatpak|fwupd|snap" | sed "s/^/  /"
echo fin'

# medir_navegador <etiqueta> → deja T_NAV (segundos) y C_NAV (código; 99 = no hay).
medir_navegador() {
    T_NAV=999; C_NAV=1
    local leidos="?" escritos="?"
    if en_llevix "$NAVEGADOR" 400; then
        read -r T_NAV C_NAV leidos escritos <<<"$(salida)"
    fi
    if [[ "$C_NAV" == 99 ]]; then
        info "$1: no se encontró el navegador"
        return
    fi
    info "$1: el navegador abrió en ${T_NAV} s (código $C_NAV; leyó $leidos MB y escribió $escritos MB)"
    if [[ "$C_NAV" != 0 ]] || (( T_NAV > 60 )); then
        sed '$d; s/^/          /' "$TRABAJO/salida.txt"
    fi
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
    # Para comparar: el mismo navegador con el disco a velocidad normal.
    medir_navegador "velocidad normal"
else
    falla "el primer arranque no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || falla "no se apagó ordenadamente"

# ---------- Arranque con el disco a velocidad de USB barato ----------

echo; echo "Arranque con el disco lento (lectura 20 MB/s, escritura 3 MB/s)"
inicio=$SECONDS
LLEVIX_TEST_DISCO_OPC="$LENTO" LLEVIX_TEST_MEM=8192     qemu_iniciar usb-lento-2 "$MODO" "$TRABAJO/disco.img" raw
if qemu_esperar_informe $((TIMEOUT * 2)) && qga_esperar 300; then
    info "llegó al escritorio en $((SECONDS - inicio)) s"
    qemu_captura "$DIR_PRUEBAS/usb-lento.png"

    echo; echo "0. Qué se escribe solo, sin tocar nada (5 minutos)"
    if en_llevix "$QUIETO" 420; then
        sed 's/^/  /' "$TRABAJO/salida.txt"
    else
        info "no se pudo medir"; sed 's/^/          /' "$TRABAJO/salida.txt"
    fi

    echo; echo "1. Abrir el navegador por primera vez"
    medir_navegador "USB lento"
    if [[ "$C_NAV" == 99 ]]; then
        :
    elif [[ "$C_NAV" == 0 ]] && (( T_NAV <= MAX_NAVEGADOR )); then
        ok "el navegador abrió en $T_NAV s (límite $MAX_NAVEGADOR s)"
    else
        falla "el navegador tardó $T_NAV s o falló (código $C_NAV; límite $MAX_NAVEGADOR s)"
    fi

    echo; echo "2. Con otro programa escribiendo un archivo grande (prioridad normal)"
    # Como copiar un archivo enorme al USB: en una memoria de 3 MB/s eso ocupa todo el
    # disco y el navegador espera. Es un límite de la memoria; se mide solo para comparar.
    T_GUARDAR=600
    en_llevix "$CARGA_INICIAR" 60 || true
    if en_llevix "$GUARDAR" 620; then T_GUARDAR="$(salida)"; fi
    if (( T_GUARDAR <= MAX_GUARDAR )); then
        ok "guardar un archivo no se congela: ${T_GUARDAR} s (límite $MAX_GUARDAR s)"
    else
        falla "guardar un archivo tardó ${T_GUARDAR} s (límite $MAX_GUARDAR s)"
    fi
    medir_navegador "escritura de fondo con prioridad normal"
    en_llevix "$CARGA_PARAR" 900 || info "limpiar la carga tardó demasiado"

    echo; echo "3. La misma escritura con prioridad de disco baja (como quedan las actualizaciones)"
    if en_llevix 'systemctl show -p IOWeight -p IOSchedulingClass apt-daily.service packagekit.service | tr "\n" " "'; then
        if grep -q "IOWeight=1 " "$TRABAJO/salida.txt" && grep -Eq "IOSchedulingClass=(3|idle)" "$TRABAJO/salida.txt"; then
            ok "las actualizaciones tienen prioridad de disco baja ($(salida))"
        else
            falla "las actualizaciones no tienen prioridad de disco baja ($(salida))"
        fi
    fi
    if en_llevix 'd=$(lsblk -no PKNAME "$(findmnt -no SOURCE / | sed "s/\[.*//")"); cat /sys/block/$d/queue/scheduler' \
        && grep -q "\[bfq\]" "$TRABAJO/salida.txt"; then
        ok "el disco USB usa el planificador bfq"
    else
        falla "el disco USB no usa bfq ($(salida))"
    fi
    en_llevix 'systemd-run --quiet --unit=llevix-carga -p IOWeight=1 -p IOSchedulingClass=idle -p Nice=19 \
        sh -c "head -c 1536M /dev/urandom > /home/'"$USUARIO"'/grande.bin"; sleep 20' 60 || true
    medir_navegador "escritura de fondo con prioridad baja"
    if [[ "$C_NAV" == 99 ]]; then
        :
    elif [[ "$C_NAV" == 0 ]] && (( T_NAV <= MAX_NAVEGADOR_CARGA )); then
        ok "con una actualización de fondo el navegador abre: ${T_NAV} s (límite $MAX_NAVEGADOR_CARGA s)"
    else
        falla "con una actualización de fondo el navegador tardó ${T_NAV} s o falló (código $C_NAV)"
    fi
    if en_llevix 'echo $(( $(stat -c %s /home/'"$USUARIO"'/grande.bin 2>/dev/null || echo 0) / 1048576 ))'; then
        info "mientras tanto, la tarea de fondo siguió y escribió $(salida) MB"
    fi
    en_llevix 'systemctl stop llevix-carga 2>/dev/null; rm -f /home/'"$USUARIO"'/grande.bin; sync' 900 \
        || info "limpiar la carga tardó demasiado"
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
