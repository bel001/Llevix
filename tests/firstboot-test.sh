#!/usr/bin/env bash
# firstboot-test.sh — Prueba el primer arranque de Llevix en QEMU.
#
# Uso: ./tests/firstboot-test.sh <imagen.img>
#
# Casos:
#   1. Config válido en un disco virtual de 32 GB: se crea el usuario, LLEVIX-DATOS
#      crece, el archivo de configuración se borra y ~/Datos queda montado.
#   2. Persistencia: se crean archivos, se apaga, se vuelve a arrancar y siguen ahí.
#   3. Config con errores: mensaje claro (LLEVIX-ERROR.txt), no se crea nada y el
#      sistema igual llega al escritorio.
#
# No necesita root. Trabaja sobre copias de la imagen, nunca sobre la original.

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"
MODO="${LLEVIX_TEST_MODO:-uefi-sb}"
TAM_DISCO="32G"
USUARIO="prueba"

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -eq 1 ]] || { echo "uso: $0 <imagen.img>" >&2; exit 2; }
IMG="$(realpath "$1")"
[[ -f "$IMG" ]] || { echo "no existe la imagen: $IMG" >&2; exit 2; }
for h in mcopy mdir partx openssl; do
    command -v "$h" >/dev/null || { echo "falta $h (paquetes mtools, util-linux, openssl)" >&2; exit 2; }
done
qemu_requisitos

mkdir -p "$DIR_PRUEBAS"
# La copia del disco puede ser grande: se usa la carpeta de pruebas, no /tmp.
TRABAJO="$(mktemp -d "$DIR_PRUEBAS/trabajo.XXXXXX")"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT

fallos=0
ok()    { printf '  \e[32m[ok]\e[0m    %s\n' "$*"; }
falla() { printf '  \e[31m[falla]\e[0m %s\n' "$*"; fallos=$((fallos + 1)); }
# Procesos de la pantalla de inicio de sesión de cada escritorio.
SALUDO="slick-greeter|unity-greeter|lightdm-gtk-greeter|sddm-greeter|gnome-shell"

comprobar() {  # comprobar <descripción> <comando sh dentro de Llevix>
    # Sin $(...): la conexión con el agente no está disponible dentro de un subshell.
    if qga_ejecutar "$2" > "$TRABAJO/salida.txt" 2>&1; then
        ok "$1"
    else
        falla "$1"
        sed 's/^/          /' "$TRABAJO/salida.txt"
    fi
}

tam_datos_original="$(( $(partx -g -o SECTORS -n 1 "$IMG" | tr -d ' ') * 512 ))"
echo "Tamaño original de LLEVIX-DATOS: $tam_datos_original bytes"

# ---------- Caso 1 y 2: config válido y persistencia ----------

"$DIR_REPO/tools/make-config.sh" --usuario "$USUARIO" --nombre-completo "Usuaria de Prueba" \
    --contrasena "clave-de-prueba" --idioma es_MX.UTF-8 --zona America/Mexico_City \
    --teclado latam --hostname llevix-prueba > "$TRABAJO/config-valido.json"

preparar_disco "$IMG" "$TRABAJO/disco1.img" "$TAM_DISCO" "$TRABAJO/config-valido.json"

echo; echo "Caso 1: primer arranque con config válido"
qemu_iniciar valido "$MODO" "$TRABAJO/disco1.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    # Captura enseguida: más tarde la pantalla puede apagarse por inactividad.
    qemu_captura "$DIR_PRUEBAS/firstboot-valido.png"
    echo "  primer arranque: $INFORME_PRIMER_ARRANQUE"
    comprobar "la pantalla de inicio de sesión está en ejecución" "pgrep -f '$SALUDO' >/dev/null"
    if [[ "$INFORME_PRIMER_ARRANQUE" == *"resultado=ok"* ]]; then
        ok "llevix-firstboot terminó bien"
    else
        falla "llevix-firstboot no terminó bien ($INFORME_PRIMER_ARRANQUE)"
    fi
    if [[ "$INFORME_GESTOR" == "active" ]]; then ok "el gestor de sesión está activo"; else falla "gestor de sesión: $INFORME_GESTOR"; fi
    comprobar "existe el usuario $USUARIO" "id $USUARIO"
    comprobar "el usuario está en el grupo sudo" "id -nG $USUARIO | grep -qw sudo"
    comprobar "la contraseña es un hash SHA-512" "getent shadow $USUARIO | cut -d: -f2 | grep -q '^\\\$6\\\$'"
    comprobar "ya no existe el usuario temporal llevix" "! id llevix"
    comprobar "llevix-config.json se borró" "test ! -e /boot/efi/llevix-config.json"
    comprobar "nombre del equipo aplicado" "test \"\$(cat /etc/hostname)\" = llevix-prueba"
    comprobar "zona horaria aplicada" "readlink /etc/localtime | grep -q America/Mexico_City"
    comprobar "idioma aplicado" "grep -q 'LANG=es_MX.UTF-8' /etc/default/locale"
    comprobar "teclado aplicado" "grep -q 'XKBLAYOUT=\"latam\"' /etc/default/keyboard"
    comprobar "LLEVIX-DATOS creció" \
        "test \$(lsblk -bno SIZE /dev/disk/by-partlabel/LLEVIX-DATOS) -gt $((tam_datos_original + 1024 * 1024 * 1024))"
    comprobar "Datos está montado como exFAT" "findmnt -no FSTYPE /home/$USUARIO/Datos | grep -q exfat"
    comprobar "el usuario puede escribir en Datos" \
        "su $USUARIO -c 'touch /home/$USUARIO/Datos/.prueba-escritura && rm /home/$USUARIO/Datos/.prueba-escritura'"
    comprobar "se crean archivos para la prueba de persistencia" \
        "echo persistente > /home/$USUARIO/Datos/persistencia.txt && echo persistente > /home/$USUARIO/persistencia.txt && sync"
else
    falla "el primer arranque no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || falla "no se apagó ordenadamente"

echo; echo "Caso 2: segundo arranque (persistencia)"
qemu_iniciar valido "$MODO" "$TRABAJO/disco1.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    qemu_captura "$DIR_PRUEBAS/firstboot-segundo.png"
    comprobar "la pantalla de inicio de sesión está en ejecución" "pgrep -f '$SALUDO' >/dev/null"
    comprobar "el archivo en Datos sigue ahí" "grep -q persistente /home/$USUARIO/Datos/persistencia.txt"
    comprobar "el archivo en la carpeta personal sigue ahí" "grep -q persistente /home/$USUARIO/persistencia.txt"
    comprobar "el reporte de diagnóstico se genera en Datos"         "SUDO_USER=$USUARIO /usr/lib/llevix/report.sh >/dev/null && ls /home/$USUARIO/Datos/llevix-reporte-*.txt"
    comprobar "el reporte dice el modo de arranque y no tiene datos personales"         "f=\$(ls /home/$USUARIO/Datos/llevix-reporte-*.txt | head -n1); grep -q 'Arranque: UEFI' \"\$f\" && ! grep -q '$USUARIO' \"\$f\" && ! grep -Eq '([0-9a-f]{2}:){5}[0-9a-f]{2}' \"\$f\""
    comprobar "el primer arranque no se repitió" "test -e /var/lib/llevix/firstboot-hecho && ! systemctl is-enabled -q llevix-firstboot.service"
else
    falla "el segundo arranque no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || true
rm -f "$TRABAJO/disco1.img"

# ---------- Caso 3: config con errores ----------

"$DIR_REPO/tools/make-config.sh" --usuario "Nombre Invalido" --contrasena "x" > "$TRABAJO/config-malo.json"
preparar_disco "$IMG" "$TRABAJO/disco2.img" "$TAM_DISCO" "$TRABAJO/config-malo.json"

echo; echo "Caso 3: config con errores"
qemu_iniciar malo "$MODO" "$TRABAJO/disco2.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    qemu_captura "$DIR_PRUEBAS/firstboot-error.png"
    echo "  primer arranque: $INFORME_PRIMER_ARRANQUE"
    comprobar "la pantalla de inicio de sesión está en ejecución" "pgrep -f '$SALUDO' >/dev/null"
    if [[ "$INFORME_PRIMER_ARRANQUE" == *"resultado=error"* ]]; then
        ok "se detectó el error"
    else
        falla "no se informó el error ($INFORME_PRIMER_ARRANQUE)"
    fi
    if [[ "$INFORME_GESTOR" == "active" ]]; then ok "el sistema igual llegó al escritorio"; else falla "gestor de sesión: $INFORME_GESTOR"; fi
    comprobar "se explica el error en LLEVIX-ERROR.txt" "grep -q 'nombre de usuario no válido' /boot/efi/LLEVIX-ERROR.txt"
    comprobar "no se creó ninguna cuenta de usuario" "! getent passwd | awk -F: '\$3 >= 1000 && \$3 < 60000' | grep -q ."
    comprobar "el config con el hash se borró" "test ! -e /boot/efi/llevix-config.json"
    comprobar "el nombre del equipo no cambió" "test \"\$(cat /etc/hostname)\" = llevix"
else
    falla "con un config erróneo el sistema no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_apagar || true

echo
if (( fallos == 0 )); then
    printf '\e[32mPrimer arranque: todas las comprobaciones pasaron.\e[0m\n'
else
    printf '\e[31mPrimer arranque: %d comprobación(es) fallaron.\e[0m\n' "$fallos"
fi
(( fallos == 0 ))
