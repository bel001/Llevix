#!/usr/bin/env bash
# tests/lib/qemu.sh — Funciones comunes para las pruebas en QEMU (se carga con "source").
#
# Antes de usarla, el script que la carga debe definir:
#   TRABAJO       carpeta temporal (sockets, variables UEFI)
#   DIR_PRUEBAS   carpeta para registros y capturas
# y puede definir LLEVIX_TEST_BUS (usb|virtio) y LLEVIX_TEST_MEM (MiB).
#
# Funciones principales:
#   qemu_iniciar <nombre> <modo> <disco> <formato>   arranca QEMU en segundo plano
#   qemu_esperar_informe <segundos>                    espera el informe del puerto serie
#   qga_ejecutar <comando>                             ejecuta un comando dentro de Llevix
#   qemu_apagar / qemu_matar / qemu_captura <png>

# Los argumentos de QEMU llevan comas a propósito (por ejemplo q35,smm=on).
# Las variables QEMU_* e INFORME_* las usan los scripts que cargan esta biblioteca.
# shellcheck disable=SC2054,SC2034

QEMU_PID=""
QEMU_SERIE=""
QEMU_NOMBRE=""
INFORME_MODO=""
INFORME_GESTOR=""
INFORME_PRIMER_ARRANQUE=""

_primero_que_exista() {
    local f
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}

qemu_requisitos() {
    local h
    for h in qemu-system-x86_64 qemu-img socat jq; do
        command -v "$h" >/dev/null || { echo "Falta $h (ejecuta ./tools/check-env.sh)" >&2; return 1; }
    done
    OVMF_CODE_SB="$(_primero_que_exista /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd)" \
        || { echo "Falta OVMF con Secure Boot (paquete ovmf)" >&2; return 1; }
    OVMF_VARS_MS="$(_primero_que_exista /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd)" \
        || { echo "Faltan las variables OVMF con claves de Microsoft (paquete ovmf)" >&2; return 1; }
    OVMF_CODE="$(_primero_que_exista /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd)" \
        || { echo "Falta OVMF (paquete ovmf)" >&2; return 1; }
    OVMF_VARS="$(_primero_que_exista /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd)" \
        || { echo "Faltan las variables OVMF (paquete ovmf)" >&2; return 1; }
    QEMU_ACEL=(-cpu max)
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        QEMU_ACEL=(-enable-kvm -cpu host)
    else
        echo "Aviso: sin KVM, el arranque será lento." >&2
    fi
}

# qemu_iniciar <nombre> <modo> <disco> <formato>
# El nombre identifica los archivos de registro; las variables UEFI se guardan por
# nombre, así que dos arranques con el mismo nombre comparten la NVRAM (como una PC real).
qemu_iniciar() {
    local nombre="$1" modo="$2" disco="$3" formato="$4"
    local args=()
    QEMU_NOMBRE="$nombre"
    QEMU_SERIE="$DIR_PRUEBAS/$nombre-serie.log"
    : > "$QEMU_SERIE"

    case "$modo" in
        uefi-sb)
            [[ -f "$TRABAJO/vars-$nombre.fd" ]] || cp "$OVMF_VARS_MS" "$TRABAJO/vars-$nombre.fd"
            args+=(-machine q35,smm=on
                   -global driver=cfi.pflash01,property=secure,value=on
                   -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE_SB"
                   -drive "if=pflash,format=raw,unit=1,file=$TRABAJO/vars-$nombre.fd")
            ;;
        uefi)
            [[ -f "$TRABAJO/vars-$nombre.fd" ]] || cp "$OVMF_VARS" "$TRABAJO/vars-$nombre.fd"
            args+=(-machine q35
                   -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
                   -drive "if=pflash,format=raw,unit=1,file=$TRABAJO/vars-$nombre.fd")
            ;;
        bios)
            args+=(-machine q35)
            ;;
        *) echo "modo desconocido: $modo" >&2; return 2 ;;
    esac

    case "${LLEVIX_TEST_BUS:-usb}" in
        usb)
            args+=(-device qemu-xhci,id=xhci
                   -drive "if=none,id=disco,format=$formato,file=$disco"
                   -device usb-storage,bus=xhci.0,drive=disco,bootindex=1)
            ;;
        virtio)
            args+=(-drive "if=virtio,format=$formato,file=$disco")
            ;;
        *) echo "bus desconocido: $LLEVIX_TEST_BUS" >&2; return 2 ;;
    esac

    rm -f "$TRABAJO/monitor.sock" "$TRABAJO/qga.sock"
    args+=("${QEMU_ACEL[@]}" -smp 2 -m "${LLEVIX_TEST_MEM:-4096}" -vga std -display none
           -nic user,model=virtio-net-pci
           -serial "file:$QEMU_SERIE"
           -monitor "unix:$TRABAJO/monitor.sock,server,nowait"
           -device virtio-serial
           -chardev "socket,path=$TRABAJO/qga.sock,server=on,wait=off,id=qga0"
           -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0)

    printf '\n\e[1m--- %s: modo %s, disco %s ---\e[0m\n' "$nombre" "$modo" "${LLEVIX_TEST_BUS:-usb}"
    qemu-system-x86_64 "${args[@]}" &
    QEMU_PID=$!
}

qemu_vivo() { [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; }

qemu_monitor() {
    printf '%s\n' "$1" | socat - "UNIX-CONNECT:$TRABAJO/monitor.sock" >/dev/null 2>&1 || true
}

qemu_captura() {
    qemu_vivo || return 0
    qemu_monitor "screendump $1 -f png"
    sleep 2
}

# qemu_esperar_informe <segundos> → 0 si llegó el informe completo.
# Deja en INFORME_MODO, INFORME_GESTOR e INFORME_PRIMER_ARRANQUE lo que informó Llevix.
# Para un segundo arranque, el informe nuevo se busca después de la marca QEMU_MARCA.
qemu_esperar_informe() {
    local limite="$1" inicio=$SECONDS
    INFORME_MODO=""; INFORME_GESTOR=""; INFORME_PRIMER_ARRANQUE=""
    while (( SECONDS - inicio < limite )); do
        qemu_vivo || { echo "QEMU terminó antes de tiempo" >&2; return 1; }
        if grep -q "LLEVIX-ARRANQUE-FIN" "$QEMU_SERIE" 2>/dev/null; then
            local linea
            # Sin "^": el firmware puede dejar códigos de pantalla antes del texto.
            linea="$(grep -a -o -m1 'LLEVIX-ARRANQUE modo=[^ ]* gestor=[^ [:cntrl:]]*' "$QEMU_SERIE" || true)"
            INFORME_MODO="$(sed -n 's/.* modo=\([^ ]*\).*/\1/p' <<<"$linea")"
            INFORME_GESTOR="$(sed -n 's/.* gestor=\([^ ]*\).*/\1/p' <<<"$linea")"
            INFORME_PRIMER_ARRANQUE="$(grep -a -o -m1 'LLEVIX-PRIMER-ARRANQUE [^[:cntrl:]]*' "$QEMU_SERIE" | cut -d' ' -f2- || true)"
            echo "Informe recibido en $((SECONDS - inicio)) s: modo=$INFORME_MODO gestor=$INFORME_GESTOR"
            return 0
        fi
        sleep 5
    done
    echo "Tiempo agotado (${limite}s) esperando el informe de arranque" >&2
    return 1
}

# ---------- Agente de QEMU (qemu-guest-agent dentro de Llevix) ----------
# Se usa UNA conexión persistente (coproc) y se sincroniza antes de cada petición
# con guest-sync-delimited, para no mezclar respuestas viejas con nuevas.
# Las respuestas se dejan en la variable QGA_RESPUESTA (no en la salida estándar,
# porque los descriptores del coproc no están disponibles dentro de $(...)).

QGA_PID=""
QGA_RESPUESTA=""

qga_desconectar() {
    if [[ -n "$QGA_PID" ]]; then
        kill "$QGA_PID" 2>/dev/null || true
        wait "$QGA_PID" 2>/dev/null || true
    fi
    QGA_PID=""
}

qga_conectar() {
    qga_desconectar
    [[ -S "$TRABAJO/qga.sock" ]] || return 1
    coproc QGA_CONEXION { socat - "UNIX-CONNECT:$TRABAJO/qga.sock" 2>/dev/null; }
    QGA_PID="$QGA_CONEXION_PID"
}

# _qga_leer <segundos> → deja una línea en QGA_RESPUESTA.
_qga_leer() {
    QGA_RESPUESTA=""
    [[ -n "$QGA_PID" ]] || return 1
    IFS= read -r -t "$1" QGA_RESPUESTA <&"${QGA_CONEXION[0]}" || return 1
    # guest-sync-delimited antepone el byte 0xFF: se quita.
    QGA_RESPUESTA="${QGA_RESPUESTA//$'\xff'/}"
}

_qga_enviar() {
    [[ -n "$QGA_PID" ]] || return 1
    local fd="${QGA_CONEXION[1]}"
    { printf '%s\n' "$1" 1>&"$fd"; } 2>/dev/null
}

# qga_sincronizar → 0 si el agente respondió a la sincronización.
qga_sincronizar() {
    local id=$(( RANDOM * 32768 + RANDOM )) inicio=$SECONDS
    _qga_enviar "{\"execute\":\"guest-sync-delimited\",\"arguments\":{\"id\":$id}}" || return 1
    while (( SECONDS - inicio < 10 )); do
        _qga_leer 10 || return 1
        [[ "$QGA_RESPUESTA" == *"\"return\": $id"* || "$QGA_RESPUESTA" == *"\"return\":$id"* ]] && return 0
    done
    return 1
}

# qga <json> → deja la respuesta en QGA_RESPUESTA.
qga() {
    qga_sincronizar || { qga_conectar && qga_sincronizar; } || return 1
    _qga_enviar "$1" || return 1
    _qga_leer 30
}

# qga_esperar <segundos> → 0 cuando el agente responde.
qga_esperar() {
    local limite="$1" inicio=$SECONDS
    while (( SECONDS - inicio < limite )); do
        if qga_conectar && qga_sincronizar; then
            return 0
        fi
        sleep 3
    done
    echo "El agente de QEMU no respondió" >&2
    return 1
}

# qga_ejecutar <comando sh> [segundos] → imprime la salida y devuelve el código del comando.
qga_ejecutar() {
    local peticion pid salida codigo limite="${2:-120}"
    peticion="$(jq -cn --arg c "$1" \
        '{execute:"guest-exec", arguments:{path:"/bin/sh", arg:["-c",$c], "capture-output":true}}')"
    qga "$peticion" || true
    pid="$(jq -r '.return.pid // empty' <<<"$QGA_RESPUESTA" 2>/dev/null || true)"
    [[ -n "$pid" ]] || { echo "guest-exec falló: $QGA_RESPUESTA" >&2; return 125; }
    for _ in $(seq "$limite"); do
        qga "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" || true
        if [[ "$(jq -r '.return.exited // false' <<<"$QGA_RESPUESTA" 2>/dev/null)" == "true" ]]; then
            salida="$(jq -r '.return["out-data"] // ""' <<<"$QGA_RESPUESTA" | base64 -d 2>/dev/null || true)"
            codigo="$(jq -r '.return.exitcode // 1' <<<"$QGA_RESPUESTA")"
            [[ -n "$salida" ]] && printf '%s\n' "$salida"
            return "$codigo"
        fi
        sleep 1
    done
    echo "guest-exec no terminó a tiempo: $1" >&2
    return 124
}

# qemu_apagar → apaga Llevix ordenadamente (como el botón de apagar).
qemu_apagar() {
    qemu_vivo || { qga_desconectar; return 0; }
    # guest-shutdown no responde si funciona: solo se envía.
    { qga_sincronizar || { qga_conectar && qga_sincronizar; }; } \
        && _qga_enviar '{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}'
    qga_desconectar
    local inicio=$SECONDS
    while qemu_vivo && (( SECONDS - inicio < 180 )); do sleep 2; done
    if qemu_vivo; then
        echo "Llevix no se apagó a tiempo; se detiene QEMU" >&2
        qemu_matar
        return 1
    fi
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
}

# qemu_matar → corta la "corriente" de golpe.
qemu_matar() {
    qga_desconectar
    if qemu_vivo; then
        kill -9 "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
}

# preparar_disco <imagen> <destino> <tamaño> [config.json]
# Copia la imagen (dispersa), la agranda al tamaño dado (como una memoria real más
# grande que la imagen) e inyecta el config en la partición EFI con mtools, sin montar
# nada y sin root.
preparar_disco() {
    local imagen="$1" destino="$2" tam="$3" config="${4:-}" inicio
    cp --sparse=always "$imagen" "$destino"
    truncate -s "$tam" "$destino"
    if [[ -n "$config" ]]; then
        inicio="$(partx -g -o START -n 3 "$imagen" | tr -d ' ')"
        mcopy -o -i "$destino@@$((inicio * 512))" "$config" ::/llevix-config.json
    fi
}
