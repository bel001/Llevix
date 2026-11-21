#!/usr/bin/env bash
# check-env.sh — Revisa que el entorno tenga todo lo necesario para desarrollar Llevix.
#
# No instala nada: solo informa qué falta y qué comando usar para instalarlo.
#
# - En Linux o WSL2 revisa lo necesario para construir y probar imágenes (image/, tests/).
# - En Windows (Git Bash) revisa lo necesario para el creador (creator/) y si WSL2 está listo.
# - En ambos revisa lo común (git, Node.js para el sitio web).
#
# Uso: ./tools/check-env.sh
# Sale con código 0 si no falta nada obligatorio, y 1 si falta algo.

set -euo pipefail

# ---------- Presentación ----------

if [[ -t 1 ]]; then
    VERDE=$'\e[32m'; ROJO=$'\e[31m'; AMARILLO=$'\e[33m'; NEGRITA=$'\e[1m'; NORMAL=$'\e[0m'
else
    VERDE=""; ROJO=""; AMARILLO=""; NEGRITA=""; NORMAL=""
fi

faltan=0           # cantidad de cosas obligatorias que faltan
avisos=0           # cantidad de cosas opcionales que faltan
paquetes_apt=()    # paquetes de apt que hay que instalar
instrucciones=()   # otras instrucciones de instalación (winget, rustup, etc.)

titulo() { printf '\n%s== %s ==%s\n' "$NEGRITA" "$1" "$NORMAL"; }
ok()     { printf '  %s[ok]%s    %s\n' "$VERDE" "$NORMAL" "$1"; }
falta()  { printf '  %s[falta]%s %s\n' "$ROJO" "$NORMAL" "$1"; faltan=$((faltan + 1)); }
aviso()  { printf '  %s[aviso]%s %s\n' "$AMARILLO" "$NORMAL" "$1"; avisos=$((avisos + 1)); }

agregar_apt() {
    # Agrega un paquete a la lista sin repetirlo.
    local p
    for p in "${paquetes_apt[@]:-}"; do [[ "$p" == "$1" ]] && return 0; done
    paquetes_apt+=("$1")
}

agregar_instruccion() {
    local i
    for i in "${instrucciones[@]:-}"; do [[ "$i" == "$1" ]] && return 0; done
    instrucciones+=("$1")
}

# Busca un comando en el PATH y también en /usr/sbin y /sbin, donde suelen estar
# herramientas como debootstrap o mkfs.* aunque el usuario no sea root.
#
# En WSL, el PATH incluye programas de Windows (en /mnt/c/...). Esos no sirven para
# trabajar dentro de Linux, así que se ignoran.
tiene_comando() {
    local ruta
    ruta="$(command -v "$1" 2>/dev/null || true)"
    if [[ -n "$ruta" ]] && ! { [[ "$SISTEMA" == "wsl" ]] && [[ "$ruta" == /mnt/* ]]; }; then
        return 0
    fi
    [[ -x "/usr/sbin/$1" || -x "/sbin/$1" ]]
}

# Compara versiones "a.b.c": devuelve éxito si $1 >= $2.
version_mayor_o_igual() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# revisar_comando <comando> <paquete apt> <descripción>
revisar_comando_apt() {
    if tiene_comando "$1"; then
        ok "$1 ($3)"
    else
        falta "$1 ($3) — paquete: $2"
        agregar_apt "$2"
    fi
}

# ---------- Detectar el sistema ----------

detectar_sistema() {
    case "$(uname -s)" in
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "otro" ;;
    esac
}

SISTEMA="$(detectar_sistema)"

# ---------- Comunes ----------

revisar_comunes() {
    titulo "Herramientas comunes"

    if tiene_comando git; then
        ok "git ($(git --version | awk '{print $3}'))"
    else
        falta "git"
        if [[ "$SISTEMA" == "windows" ]]; then
            agregar_instruccion "winget install --id Git.Git -e"
        else
            agregar_apt git
        fi
    fi

    # Node.js: lo usan el creador (Svelte/Vite) y el sitio web (Astro). Se pide 20 o más.
    if tiene_comando node; then
        local v
        v="$(node --version | tr -d 'v')"
        if version_mayor_o_igual "$v" "20.0.0"; then
            ok "node $v"
        else
            falta "node $v es antiguo; se necesita 20 o más"
            agregar_instruccion_node
        fi
    else
        falta "node (Node.js 20 o más, para el creador y el sitio web)"
        agregar_instruccion_node
    fi

    if tiene_comando npm; then
        ok "npm $(npm --version 2>/dev/null)"
    else
        falta "npm (viene con Node.js)"
        agregar_instruccion_node
    fi
}

agregar_instruccion_node() {
    if [[ "$SISTEMA" == "windows" ]]; then
        agregar_instruccion "winget install --id OpenJS.NodeJS.LTS -e"
    else
        # La versión de Node en apt de Ubuntu 24.04 es la 18; se recomienda nvm.
        agregar_instruccion "Node.js 20+: curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && nvm install --lts"
    fi
}

# ---------- Imágenes y pruebas (Linux / WSL) ----------

revisar_imagen() {
    titulo "Construcción de imágenes (image/)"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
            ok "sistema: ${PRETTY_NAME:-desconocido}"
        else
            aviso "sistema ${PRETTY_NAME:-desconocido}: el proyecto se prueba en Ubuntu 24.04; los nombres de paquetes pueden cambiar"
        fi
    fi

    revisar_comando_apt debootstrap     debootstrap  "crea el sistema base"
    revisar_comando_apt sgdisk          gdisk        "tabla de particiones GPT"
    revisar_comando_apt partprobe       parted       "relee las particiones"
    revisar_comando_apt mkfs.vfat       dosfstools   "formatea la ESP en FAT32"
    revisar_comando_apt mkfs.exfat      exfatprogs   "formatea LLEVIX-DATOS en exFAT"
    revisar_comando_apt mkfs.btrfs      btrfs-progs  "formatea el sistema en btrfs"
    revisar_comando_apt losetup         util-linux   "monta la imagen como disco"
    revisar_comando_apt zstd            zstd         "comprime la imagen"
    revisar_comando_apt bmaptool        bmap-tools   "genera el mapa .bmap"
    revisar_comando_apt sha256sum       coreutils    "suma SHA256"
    revisar_comando_apt jq              jq           "genera manifest.json"
    revisar_comando_apt shellcheck      shellcheck   "revisa los scripts de bash"

    # El kernel debe poder montar estos sistemas de archivos durante la construcción.
    local fs
    for fs in btrfs vfat exfat; do
        if grep -qw "$fs" /proc/filesystems 2>/dev/null \
            || modinfo "$fs" >/dev/null 2>&1 \
            || [[ -d "/sys/module/$fs" ]]; then
            ok "el kernel soporta $fs"
        else
            aviso "no se pudo confirmar que el kernel soporte $fs (se sabrá al construir)"
        fi
    done

    titulo "Pruebas de arranque (tests/)"

    revisar_comando_apt qemu-system-x86_64 qemu-system-x86 "emulador QEMU"
    revisar_comando_apt qemu-img           qemu-utils      "manejo de discos virtuales"

    # Firmware UEFI con Secure Boot (OVMF) y BIOS antiguo (SeaBIOS).
    revisar_archivo_alguno "OVMF con Secure Boot (código)" ovmf \
        /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd
    revisar_archivo_alguno "OVMF con claves de Microsoft (variables)" ovmf \
        /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd
    revisar_archivo_alguno "SeaBIOS (arranque BIOS)" seabios \
        /usr/share/seabios/bios.bin /usr/share/qemu/bios.bin

    # KVM acelera mucho las pruebas; sin él funcionan, pero lento.
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        ok "KVM disponible (pruebas rápidas)"
    elif [[ -e /dev/kvm ]]; then
        aviso "/dev/kvm existe pero tu usuario no tiene permiso; ejecuta: sudo usermod -aG kvm \$USER (y vuelve a entrar)"
    else
        aviso "KVM no disponible: las pruebas en QEMU funcionarán, pero lentas"
    fi
}

# revisar_archivo_alguno <descripción> <paquete apt> <ruta1> [ruta2...]
revisar_archivo_alguno() {
    local desc="$1" paquete="$2" ruta
    shift 2
    for ruta in "$@"; do
        if [[ -f "$ruta" ]]; then
            ok "$desc: $ruta"
            return 0
        fi
    done
    falta "$desc — paquete: $paquete"
    agregar_apt "$paquete"
}

# ---------- Creador (Windows) ----------

revisar_creador_windows() {
    titulo "Creador para Windows (creator/)"

    # Rust: Tauri 2 necesita rustc 1.77.2 o más.
    if tiene_comando rustc && tiene_comando cargo; then
        local v
        v="$(rustc --version | awk '{print $2}')"
        if version_mayor_o_igual "$v" "1.77.2"; then
            ok "rustc $v y cargo"
        else
            falta "rustc $v es antiguo; Tauri 2 necesita 1.77.2 o más (ejecuta: rustup update)"
            agregar_instruccion "rustup update"
        fi
    else
        falta "Rust (rustc y cargo)"
        agregar_instruccion "winget install --id Rustlang.Rustup -e   (luego abre una terminal nueva)"
    fi

    # Compilador de C++ de Microsoft (MSVC): Rust lo usa para enlazar en Windows.
    local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if [[ -x "$vswhere" ]] && [[ -n "$("$vswhere" -latest -products '*' \
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
            -property installationPath 2>/dev/null | tr -d '\r')" ]]; then
        ok "Visual Studio Build Tools con C++ (MSVC)"
    else
        falta "Visual Studio Build Tools con 'Desarrollo para el escritorio con C++'"
        agregar_instruccion 'winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'
    fi

    # WebView2: Tauri lo usa para mostrar la interfaz. Windows 11 ya lo trae.
    local clave='HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    if MSYS_NO_PATHCONV=1 reg query "$clave" /v pv >/dev/null 2>&1 \
        || MSYS_NO_PATHCONV=1 reg query "${clave/HKLM/HKCU}" /v pv >/dev/null 2>&1; then
        ok "WebView2"
    else
        falta "WebView2 Runtime"
        agregar_instruccion "winget install --id Microsoft.EdgeWebView2Runtime -e"
    fi
}

# ---------- WSL (desde Windows) ----------

revisar_wsl_desde_windows() {
    titulo "WSL2 (para construir imágenes desde Windows)"

    if ! tiene_comando wsl.exe; then
        falta "WSL no está instalado"
        agregar_instruccion "wsl --install -d Ubuntu-24.04   (en PowerShell como administrador; luego reinicia)"
        return 0
    fi

    # wsl.exe escribe en UTF-16; se quitan los bytes nulos para poder leerlo.
    local lista
    lista="$(wsl.exe -l -v 2>/dev/null | tr -d '\0\r' || true)"
    if grep -Eq 'Ubuntu.*[[:space:]]2[[:space:]]*$' <<<"$lista"; then
        ok "WSL2 con una distribución Ubuntu"
        printf '        Para revisar la parte de imágenes, ejecuta este script también dentro de WSL:\n'
        printf '        wsl -d Ubuntu -- ./tools/check-env.sh\n'
    elif grep -q 'Ubuntu' <<<"$lista"; then
        falta "Ubuntu está en WSL versión 1; se necesita WSL2"
        agregar_instruccion "wsl --set-version Ubuntu 2"
    else
        falta "WSL no tiene Ubuntu"
        agregar_instruccion "wsl --install -d Ubuntu-24.04"
    fi
}

# ---------- Programa principal ----------

printf '%sLlevix — revisión del entorno%s\n' "$NEGRITA" "$NORMAL"

case "$SISTEMA" in
    linux) printf 'Sistema detectado: Linux\n' ;;
    wsl)   printf 'Sistema detectado: Linux en WSL2\n' ;;
    windows) printf 'Sistema detectado: Windows (Git Bash)\n' ;;
    *)
        printf 'Sistema no reconocido (%s). Llevix se desarrolla en Linux, WSL2 o Windows.\n' "$(uname -s)"
        exit 1
        ;;
esac

revisar_comunes

case "$SISTEMA" in
    linux|wsl)
        revisar_imagen
        titulo "Creador para Windows (creator/)"
        printf '        El creador se compila en Windows: ejecuta este script también en Git Bash.\n'
        ;;
    windows)
        revisar_creador_windows
        revisar_wsl_desde_windows
        ;;
esac

# ---------- Resumen ----------

titulo "Resumen"

if (( faltan == 0 )); then
    printf '  %sTodo lo obligatorio está instalado.%s' "$VERDE" "$NORMAL"
    (( avisos > 0 )) && printf ' Hay %d aviso(s) opcional(es).' "$avisos"
    printf '\n'
    exit 0
fi

printf '  %sFaltan %d cosa(s).%s Para instalarlas:\n\n' "$ROJO" "$faltan" "$NORMAL"

if (( ${#paquetes_apt[@]} > 0 )); then
    printf '  sudo apt update && sudo apt install -y %s\n' "${paquetes_apt[*]}"
fi
if (( ${#instrucciones[@]} > 0 )); then
    for i in "${instrucciones[@]}"; do
        printf '  %s\n' "$i"
    done
fi

printf '\n  Después vuelve a ejecutar ./tools/check-env.sh\n'
exit 1
