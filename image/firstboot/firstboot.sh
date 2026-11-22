#!/usr/bin/env bash
# firstboot.sh — Primer arranque de Llevix.
#
# Lo ejecuta el servicio llevix-firstboot.service UNA sola vez, antes del gestor de
# sesión. Lee /boot/efi/llevix-config.json (formato en docs/llevix-config.md) y:
#   1. valida TODO el archivo antes de cambiar nada;
#   2. amplía la partición LLEVIX-DATOS al espacio libre del disco;
#   3. aplica nombre del equipo, zona horaria, idioma y teclado;
#   4. crea la cuenta del usuario (con sudo) con el hash SHA-512 recibido;
#   5. monta LLEVIX-DATOS en ~/Datos;
#   6. borra el archivo de configuración y se desactiva.
# Si algo falla, deshace lo hecho, explica el motivo en pantalla y en
# LLEVIX-ERROR.txt (en la partición EFI) y deja que el sistema siga arrancando.
#
# SEGURIDAD DE DISCOS: este script solo modifica la tabla de particiones del disco
# desde el que arrancó Llevix, y solo la partición número 1 con nombre LLEVIX-DATOS.

set -euo pipefail

ESP=/boot/efi
CONFIG="$ESP/llevix-config.json"
ERROR_TXT="$ESP/LLEVIX-ERROR.txt"
DIR_ESTADO=/var/lib/llevix
HECHO="$DIR_ESTADO/firstboot-hecho"
RESULTADO="$DIR_ESTADO/firstboot-resultado"
RESPALDO="$DIR_ESTADO/firstboot-respaldo"

DESHACER=()   # comandos para deshacer, en orden de ejecución

log() { echo "llevix-firstboot: $*"; }

en_pantalla() {
    # Mensaje en la pantalla de arranque (plymouth) si está activa.
    if command -v plymouth >/dev/null && plymouth --ping 2>/dev/null; then
        plymouth display-message --text="$1" || true
    fi
}

marcar_hecho() {
    mkdir -p "$DIR_ESTADO"
    touch "$HECHO"
    systemctl disable llevix-firstboot.service >/dev/null 2>&1 || true
}

deshacer() {
    local i
    for (( i=${#DESHACER[@]}-1; i>=0; i-- )); do
        log "deshaciendo: ${DESHACER[i]}"
        bash -c "${DESHACER[i]}" || log "no se pudo deshacer: ${DESHACER[i]}"
    done
    DESHACER=()
}

fallar() {
    local motivo="$1"
    trap - ERR
    set +e
    log "ERROR: $motivo"
    deshacer
    {
        printf 'Llevix no pudo terminar la configuración inicial.\r\n\r\n'
        printf 'Motivo: %s\r\n\r\n' "$motivo"
        printf 'No se cambió nada en el sistema. Vuelve a preparar el disco con el\r\n'
        printf 'creador de Llevix, o crea tu cuenta en la pantalla de bienvenida.\r\n'
    } > "$ERROR_TXT"
    # El archivo contiene el hash de la contraseña: no se deja en el disco.
    rm -f "$CONFIG"
    mkdir -p "$DIR_ESTADO"
    echo "error: $motivo" > "$RESULTADO"
    marcar_hecho
    en_pantalla "Llevix: no se pudo aplicar la configuración inicial. $motivo"
    sleep 8
    exit 0
}

# Cualquier comando que falle sin control también lleva a "fallar".
trap 'fallar "falló un comando inesperadamente (línea $LINENO)"' ERR

# ---------- Lectura y validación ----------

if [[ -f "$HECHO" ]]; then
    log "el primer arranque ya se hizo antes; no hay nada que hacer"
    exit 0
fi

if [[ ! -f "$CONFIG" ]]; then
    mkdir -p "$DIR_ESTADO"
    echo "sin-config" > "$RESULTADO"
    # GNOME (gdm3) ofrece crear la cuenta en su bienvenida. Los demás escritorios
    # (KDE, Xfce, LXQt, Cinnamon, MATE) no: se crea una cuenta "llevix" con contraseña
    # "llevix" que hay que cambiar en el primer inicio de sesión.
    if grep -q gdm3 /etc/X11/default-display-manager 2>/dev/null; then
        log "no hay $CONFIG; se usará la bienvenida de la distribución para crear la cuenta"
    elif ! getent passwd llevix >/dev/null; then
        log "no hay $CONFIG; se crea la cuenta 'llevix' (contraseña 'llevix', hay que cambiarla)"
        grupos=""
        for g in adm cdrom sudo dip plugdev lpadmin users; do
            getent group "$g" >/dev/null && grupos+="${grupos:+,}$g"
        done
        useradd --create-home --shell /bin/bash --comment "Llevix" --groups "$grupos" \
            --password "$(openssl passwd -6 llevix)" llevix
        chage -d 0 llevix
        printf '%s\r\n' \
            "Llevix arrancó sin configuración del creador." \
            "Se creó la cuenta: usuario 'llevix', contraseña 'llevix'." \
            "Al iniciar sesión por primera vez te pedirá elegir una contraseña nueva." > "$ESP/LLEVIX-LEEME.txt"
        echo "sin-config: cuenta llevix" > "$RESULTADO"
        en_pantalla "Llevix: usuario 'llevix', contraseña 'llevix' (te pedirá cambiarla)"
    fi
    marcar_hecho
    exit 0
fi

en_pantalla "Llevix: preparando tu cuenta…"

jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1 || fallar "llevix-config.json no es un JSON válido"

# texto <ruta jq> <por defecto> → imprime el valor; devuelve error si existe y no es texto.
# (Se usa dentro de $(...), así que no puede llamar a "fallar" directamente.)
texto() {
    case "$(jq -r "$1 | type" "$CONFIG")" in
        string) jq -r "$1" "$CONFIG" ;;
        null)   printf '%s' "$2" ;;
        *)      return 1 ;;
    esac
}

[[ "$(jq -r '.version' "$CONFIG")" == "1" ]] || fallar "versión de configuración no soportada"

usuario="$(texto .usuario.nombre "")"                    || fallar "usuario.nombre debe ser texto"
nombre_completo="$(texto .usuario.nombre_completo "")"   || fallar "usuario.nombre_completo debe ser texto"
hash="$(texto .usuario.hash_contrasena "")"              || fallar "usuario.hash_contrasena debe ser texto"
idioma="$(texto .idioma "es_ES.UTF-8")"                  || fallar "idioma debe ser texto"
zona="$(texto .zona_horaria "UTC")"                      || fallar "zona_horaria debe ser texto"
teclado="$(texto .teclado.distribucion "es")"            || fallar "teclado.distribucion debe ser texto"
variante="$(texto .teclado.variante "")"                 || fallar "teclado.variante debe ser texto"
nombre_equipo="$(texto .hostname "llevix")"              || fallar "hostname debe ser texto"

for campo in lector_pantalla texto_grande; do
    case "$(jq -r ".accesibilidad.$campo | type" "$CONFIG")" in
        boolean|null) ;;
        *) fallar "accesibilidad.$campo debe ser true o false" ;;
    esac
done

[[ "$usuario" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
    || fallar "nombre de usuario no válido: usa minúsculas, números, - o _ y empieza con una letra"
getent passwd "$usuario" >/dev/null && fallar "el usuario '$usuario' ya existe en el sistema"
getent group "$usuario" >/dev/null && fallar "el nombre '$usuario' está reservado por el sistema"

(( ${#nombre_completo} <= 100 )) || fallar "el nombre completo es demasiado largo"
[[ "$nombre_completo" != *:* && "$nombre_completo" != *,* && "$nombre_completo" != *$'\n'* ]] \
    || fallar "el nombre completo no puede tener ':', ',' ni saltos de línea"

[[ "$hash" =~ ^\$6\$(rounds=[0-9]+\$)?[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$ ]] \
    || fallar "la contraseña no tiene un hash SHA-512 válido"

if ! [[ "$idioma" =~ ^[a-z]{2,3}(_[A-Z]{2})?\.UTF-8$ ]] \
    || ! grep -q "^$idioma UTF-8\$" /usr/share/i18n/SUPPORTED; then
    fallar "idioma no soportado: $idioma"
fi

[[ "$zona" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/$zona" ]] \
    || fallar "zona horaria desconocida: $zona"

[[ "$teclado" =~ ^[a-z]{2,8}$ && -f "/usr/share/X11/xkb/symbols/$teclado" ]] \
    || fallar "distribución de teclado desconocida: $teclado"
if [[ -n "$variante" ]]; then
    if ! [[ "$variante" =~ ^[A-Za-z0-9_-]+$ ]] \
        || ! grep -q "xkb_symbols \"$variante\"" "/usr/share/X11/xkb/symbols/$teclado"; then
        fallar "variante de teclado desconocida: $variante"
    fi
fi

[[ "$nombre_equipo" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || fallar "nombre de equipo no válido: $nombre_equipo"

log "configuración válida para el usuario $usuario"

# ---------- Partición de datos ----------

# Disco desde el que arrancó Llevix (el que contiene /).
raiz="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
disco="/dev/$(lsblk -no PKNAME "$raiz" | head -n1)"
[[ -b "$disco" ]] || fallar "no se encontró el disco de Llevix"
datos="$(lsblk -lnpo NAME,PARTLABEL "$disco" | awk '$2 == "LLEVIX-DATOS" {print $1}')"
[[ -n "$datos" && -b "$datos" ]] || fallar "no se encontró la partición LLEVIX-DATOS"
[[ "$(cat "/sys/class/block/$(basename "$datos")/partition")" == "1" ]] \
    || fallar "LLEVIX-DATOS no es la partición 1"

# Solo se reformatea si está vacía (en el primer arranque siempre lo está).
punto_tmp="$(mktemp -d)"
mount -o ro "$datos" "$punto_tmp"
contenido="$(find "$punto_tmp" -mindepth 1 -maxdepth 1 ! -name 'System Volume Information' | head -n1)"
umount "$punto_tmp"
rmdir "$punto_tmp"

if [[ -z "$contenido" ]]; then
    log "ampliando LLEVIX-DATOS en $disco"
    en_pantalla "Llevix: ampliando el espacio para tus archivos…"
    # Mueve la copia de respaldo de la tabla GPT al final real del disco.
    sgdisk -e "$disco" >/dev/null 2>&1 || true
    inicio="$(sgdisk -i 1 "$disco" | awk '/^First sector:/ {print $3}')"
    [[ "$inicio" =~ ^[0-9]+$ ]] || fallar "no se pudo leer el inicio de LLEVIX-DATOS"
    sgdisk -d 1 -n "1:$inicio:0" -t 1:0700 -c 1:LLEVIX-DATOS "$disco" >/dev/null 2>&1 || true
    partx -u "$disco"
    udevadm settle
    [[ "$(sgdisk -i 1 "$disco" | awk '/^First sector:/ {print $3}')" == "$inicio" ]] \
        || fallar "no se pudo recrear la partición LLEVIX-DATOS"
    mkfs.exfat -L LLEVIX "$datos" >/dev/null
    udevadm settle
else
    log "LLEVIX-DATOS ya tiene archivos: no se amplía"
fi

uuid_datos="$(blkid -s UUID -o value "$datos")"
[[ -n "$uuid_datos" ]] || fallar "no se pudo leer el UUID de LLEVIX-DATOS"

# ---------- Ajustes del sistema (con respaldo para poder deshacer) ----------

mkdir -p "$RESPALDO"
for f in /etc/hostname /etc/hosts /etc/timezone /etc/default/locale /etc/default/keyboard /etc/fstab; do
    if [[ -e "$f" ]]; then
        cp -a "$f" "$RESPALDO/"
        DESHACER+=("cp -a '$RESPALDO/$(basename "$f")' '$f'")
    fi
done
cp -a /etc/localtime "$RESPALDO/localtime" 2>/dev/null || true
DESHACER+=("cp -a '$RESPALDO/localtime' /etc/localtime 2>/dev/null || true")

log "nombre del equipo: $nombre_equipo"
echo "$nombre_equipo" > /etc/hostname
sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1   $nombre_equipo/" /etc/hosts
hostname "$nombre_equipo"

log "zona horaria: $zona"
ln -sf "/usr/share/zoneinfo/$zona" /etc/localtime
echo "$zona" > /etc/timezone

log "idioma: $idioma"
locale-gen "$idioma" >/dev/null
idioma_corto="${idioma%%.*}"
update-locale LANG="$idioma" LANGUAGE="$idioma_corto:${idioma_corto%%_*}"

log "teclado: $teclado $variante"
cat > /etc/default/keyboard <<EOF
# Configurado por Llevix en el primer arranque.
XKBMODEL="pc105"
XKBLAYOUT="$teclado"
XKBVARIANT="$variante"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# ---------- Usuario ----------

grupos=""
for g in adm cdrom sudo dip plugdev lpadmin users; do
    getent group "$g" >/dev/null && grupos+="${grupos:+,}$g"
done

log "creando el usuario $usuario"
useradd --create-home --shell /bin/bash --comment "$nombre_completo" \
    --groups "$grupos" --password "$hash" "$usuario"
DESHACER+=("userdel --remove '$usuario'")

# ---------- ~/Datos ----------

casa="$(getent passwd "$usuario" | cut -d: -f6)"
uid="$(id -u "$usuario")"
gid="$(id -g "$usuario")"
install -d -o "$uid" -g "$gid" "$casa/Datos"

sed -i '/# llevix-datos$/d' /etc/fstab
echo "UUID=$uuid_datos  $casa/Datos  exfat  uid=$uid,gid=$gid,umask=0022,nofail,x-systemd.device-timeout=10s  0  0  # llevix-datos" >> /etc/fstab
systemctl daemon-reload
mount "$casa/Datos"
DESHACER+=("umount '$casa/Datos' 2>/dev/null || true")

# ---------- Final ----------

rm -f "$CONFIG" "$ERROR_TXT"
rm -rf "$RESPALDO"
DESHACER=()
echo "ok" > "$RESULTADO"
marcar_hecho
trap - ERR
log "primer arranque terminado"
en_pantalla "Llevix: listo."
