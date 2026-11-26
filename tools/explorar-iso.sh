#!/usr/bin/env bash
# explorar-iso.sh — Muestra cómo está armada una ISO de Linux por dentro, para escribir el
# módulo de su familia en image/instalador/familias/ sin adivinar (fase 10).
#
# Uso (en CI, necesita root para montar): sudo ./tools/explorar-iso.sh <distro.iso>
#
# Solo LEE: monta la ISO y sus imágenes internas en modo solo lectura (loop devices) y
# nunca escribe en discos.
set -euo pipefail

ISO="${1:?uso: sudo $0 <distro.iso>}"
[[ -f "$ISO" ]] || { echo "no existe $ISO" >&2; exit 1; }
T="$(mktemp -d)"
MONTADOS=()
limpiar() {
    local i
    for (( i=${#MONTADOS[@]}-1; i>=0; i-- )); do umount -l "${MONTADOS[i]}" 2>/dev/null || true; done
}
trap limpiar EXIT
monta() { mkdir -p "$2"; mount -o ro,loop "$1" "$2"; MONTADOS+=("$2"); }
titulo() { echo; echo "===== $* ====="; }

monta "$ISO" "$T/iso"

titulo "Árbol de la ISO (3 niveles, sin pool/ ni módulos de GRUB)"
(cd "$T/iso" && find . -maxdepth 3 \( -path ./pool -o -path ./pool-udeb -o -path '*/x86_64-efi' -o -path '*/i386-pc' \) -prune -o -print | sort | head -200)

titulo "Archivos grandes de la ISO"
(cd "$T/iso" && find . -type f -size +20M -printf '%10s  %p\n' | sort -rn | head -20)

titulo ".disk/info y parámetros del kernel en los menús"
cat "$T/iso/.disk/info" 2>/dev/null || echo "(sin .disk/info)"
grep -rhoE '(linux|linuxefi|append|kernel)[[:space:]].*' "$T/iso/boot" "$T/iso/EFI" "$T/iso/isolinux" "$T/iso/loader" 2>/dev/null | sort -u | head -20 || true

titulo "Firmas de los .efi y kernels de la ISO"
while IFS= read -r f; do
    echo "-- ${f#"$T/iso/"}"
    sbverify --list "$f" 2>/dev/null | sed -n 's/.*subject: /   firmado por: /p' | head -3 || true
done < <(find "$T/iso" -maxdepth 4 -type f \( -iname '*.efi' -o -iname 'vmlinuz*' -o -iname 'linux' \) | head -20)

titulo "Sistema de la ISO"
sq="$(find "$T/iso" -maxdepth 3 -type f \( -name 'filesystem.squashfs' -o -name 'squashfs.img' -o -name '*.sfs' -o -name '*.erofs' \) | head -n1)"
echo "imagen del sistema: ${sq#"$T/iso/"}"
case "$sq" in
    *.erofs) monta "$sq" "$T/sq" ;;
    *) mkdir -p "$T/sq"; mount -t squashfs -o ro,loop "$sq" "$T/sq"; MONTADOS+=("$T/sq") ;;
esac
R="$T/sq"
ls -la "$R" | head -30
if [[ -f "$R/LiveOS/rootfs.img" ]]; then
    echo "-> contiene LiveOS/rootfs.img: $(file -b "$R/LiveOS/rootfs.img")"
    monta "$R/LiveOS/rootfs.img" "$T/raiz"
    R="$T/raiz"
fi

titulo "os-release"
cat "$R/etc/os-release" 2>/dev/null || cat "$R/usr/lib/os-release"

titulo "/boot, módulos y archivos EFI dentro del sistema"
ls -la "$R/boot" 2>/dev/null | head -30 || true
ls "$R/usr/lib/modules" 2>/dev/null || true
find "$R/boot/efi" -maxdepth 4 2>/dev/null | head -30 || true
find "$R/usr/lib/shim" "$R/usr/lib/grub" "$R/usr/lib/grub2" "$R/usr/share/shim" -maxdepth 3 2>/dev/null | head -40 || true
ls "$R/boot/loader/entries" 2>/dev/null || echo "(sin entradas BLS)"

titulo "Gestor de paquetes, initramfs y arranque"
for c in dpkg rpm dnf dnf5 pacman zypper update-initramfs dracut mkinitcpio kernel-install \
         grub-mkconfig grub2-mkconfig grubby useradd chpasswd locale-gen update-locale localectl \
         sgdisk mkfs.exfat btrfs restorecon setfiles; do
    if p="$(chroot "$R" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c "command -v $c" 2>/dev/null)"; then
        echo "  sí  $c ($p)"
    else
        echo "  no  $c"
    fi
done

titulo "Paquetes relacionados con el modo en vivo, el instalador y el arranque"
if [[ -x "$R/usr/bin/rpm" ]]; then
    chroot "$R" rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | grep -Ei 'anaconda|live|initial-setup|shim|grub2|dracut|kernel-core|kernel-modules|selinux-policy|glibc-.*langpack|langpacks|firefox|NetworkManager-wifi|gdm|exfat|gdisk|btrfs|sudo' | sort | head -80 || true
    echo "paquetes en total: $(chroot "$R" rpm -qa 2>/dev/null | wc -l)"
elif [[ -x "$R/usr/bin/dpkg-query" ]]; then
    chroot "$R" dpkg-query -W -f='${Package} ${Version}\n' | grep -Ei 'live|calamares|shim|grub|initramfs|casper|ubiquity' | head -60 || true
elif [[ -x "$R/usr/bin/pacman" ]]; then
    chroot "$R" pacman -Q | grep -Ei 'archiso|live|calamares|shim|grub|mkinitcpio|linux ' | head -60 || true
fi

titulo "Configuración que afecta a Llevix"
for f in etc/selinux/config etc/default/grub etc/dracut.conf etc/fstab etc/locale.conf \
         etc/vconsole.conf etc/X11/xorg.conf.d/00-keyboard.conf etc/kernel/install.conf \
         etc/mkinitcpio.conf; do
    if [[ -f "$R/$f" ]]; then echo "--- /$f"; grep -v '^\s*#' "$R/$f" | grep -v '^\s*$' | head -15 || true; fi
done
ls "$R/etc/dracut.conf.d" "$R/usr/lib/dracut/dracut.conf.d" 2>/dev/null || true
cat "$R"/etc/dracut.conf.d/*.conf "$R"/usr/lib/dracut/dracut.conf.d/*.conf 2>/dev/null | grep -v '^\s*#' | head -30 || true
ls "$R/etc/kernel/install.d" "$R/usr/lib/kernel/install.d" 2>/dev/null || true
echo "grupos: $(grep -E '^(sudo|wheel|adm|users|lpadmin|plugdev):' "$R/etc/group" | cut -d: -f1 | tr '\n' ' ' || true)"
echo "usuarios >= 1000: $(awk -F: '$3>=1000 && $3<65000 {print $1}' "$R/etc/passwd" | tr '\n' ' ')"

titulo "Servicios del modo en vivo"
find "$R/etc/systemd/system" "$R/usr/lib/systemd/system" -maxdepth 2 -iname '*live*' 2>/dev/null | head -20 || true
echo
echo "Exploración terminada."
