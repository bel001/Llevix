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

# qga <json> → respuesta del agente de QEMU dentro de Llevix.
qga() {
    local sync
    sync="$(jq -cn --argjson id "$RANDOM" '{execute:"guest-sync", arguments:{id:$id}}')"
    printf '%s\n%s\n' "$sync" "$1" | socat -t 20 - "UNIX-CONNECT:$TRABAJO/qga.sock" 2>/dev/null | tail -n1
}

# qga_esperar <segundos> → 0 cuando el agente responde.
qga_esperar() {
    local limite="$1" inicio=$SECONDS
    while (( SECONDS - inicio < limite )); do
        if qga '{"execute":"guest-ping"}' | grep -q '"return"'; then
            return 0
        fi
        sleep 3
    done
    echo "El agente de QEMU no respondió" >&2
    return 1
}

# qga_ejecutar <comando sh> → imprime la salida y devuelve el código del comando.
qga_ejecutar() {
    local peticion respuesta pid estado salida codigo
    peticion="$(jq -cn --arg c "$1" \
        '{execute:"guest-exec", arguments:{path:"/bin/sh", arg:["-c",$c], "capture-output":true}}')"
    respuesta="$(qga "$peticion")"
    pid="$(jq -r '.return.pid // empty' <<<"$respuesta" 2>/dev/null || true)"
    [[ -n "$pid" ]] || { echo "guest-exec falló: $respuesta" >&2; return 125; }
    for _ in $(seq 120); do
        estado="$(qga "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")"
        if [[ "$(jq -r '.return.exited // false' <<<"$estado" 2>/dev/null)" == "true" ]]; then
            salida="$(jq -r '.return["out-data"] // ""' <<<"$estado" | base64 -d 2>/dev/null || true)"
            codigo="$(jq -r '.return.exitcode // 1' <<<"$estado")"
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
    qemu_vivo || return 0
    qga '{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}' >/dev/null || true
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
    if qemu_vivo; then
        kill -9 "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
}
