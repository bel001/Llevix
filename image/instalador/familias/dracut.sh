#!/usr/bin/env bash
# dracut.sh — Familia Fedora (dracut): ISOs live de Fedora y derivadas.
#
# Lo carga instalar-iso.sh (con `source`) cuando la ISO tiene las señales de esta familia
# (ver familias.json). Usa sus variables y funciones: T (montajes; la ISO en $T/iso),
# D (sistema nuevo), en_destino, monta, fallar, UUID_SIS. Rellena: capas, tipo_capa,
# quitar, kernel, version.
#
# Lo que trae la ISO de Fedora 45 Workstation (comprobado con tools/explorar-iso.sh):
# - el sistema en LiveOS/squashfs.img, que es EROFS (no squashfs, pese al nombre);
# - el kernel firmado por Fedora en boot/x86_64/loader/linux;
# - dentro del sistema: kernel e initramfs en /boot, el shim (firmado por Microsoft 2011 y
#   2023), GRUB y MokManager firmados en /boot/efi/EFI/fedora, dnf5/rpm, dracut con
#   hostonly="yes" (solo controladores de esa PC: hay que cambiarlo) y SELinux en enforcing;
# - del modo en vivo: anaconda (el instalador), livesys-scripts y dracut-live.
# shellcheck disable=SC2034  # las variables que rellena las usa instalar-iso.sh
set -euo pipefail

# Programas del modo en vivo y de la instalación con Anaconda (no sirven en un sistema
# instalado). dracut-config-rescue genera una imagen de rescate de ~270 MB en cada
# actualización del kernel: en una memoria USB sobra.
PAQUETES_VIVO_FEDORA="anaconda anaconda-core anaconda-gui anaconda-install-env-deps anaconda-live
    anaconda-tui anaconda-webui anaconda-widgets initial-setup initial-setup-gui
    kdump-anaconda-addon libreport-anaconda livesys-scripts dracut-live dracut-config-rescue"

# Dónde está el sistema dentro de la ISO.
familia_sistema() {
    capas=("$T/iso/LiveOS/squashfs.img")
    [[ -f "${capas[0]}" ]] || fallar "la ISO no trae el sistema en LiveOS/squashfs.img"
    # Algunas versiones guardan dentro una imagen ext4 (LiveOS/rootfs.img): no soportado aún.
    tipo_capa=""   # mount detecta el formato (EROFS en Fedora 42 y posteriores, squashfs antes)
    quitar=""
    kernel=""
    local k
    for k in "$T/iso/boot/x86_64/loader/linux" "$T/iso/images/pxeboot/vmlinuz" "$T/iso/isolinux/vmlinuz"; do
        if [[ -f "$k" ]]; then kernel="$k"; break; fi
    done
    [[ -n "$kernel" ]] || fallar "la ISO no trae el kernel donde lo guarda Fedora"
}

# Quita los programas del modo en vivo con rpm (sin internet: dnf querría descargar
# los índices de los repositorios).
familia_quitar_vivo() {
    [[ ! -e "$D/LiveOS/rootfs.img" ]] || fallar "esta ISO de Fedora guarda el sistema en una imagen ext4 (LiveOS/rootfs.img): todavía no es compatible"
    local lista p
    lista=""
    for p in $PAQUETES_VIVO_FEDORA; do
        if en_destino "rpm -q $p >/dev/null 2>&1"; then lista+="$p "; fi
    done
    if [[ -n "$lista" ]]; then
        echo "Quitando: $lista"
        # Primero respetando dependencias; si algún otro paquete los pide, igual se quitan
        # (son solo del instalador y del modo en vivo).
        en_destino "rpm -e $lista" || en_destino "rpm -e --nodeps $lista" || fallar "no se pudieron quitar los programas del modo en vivo"
    fi
    # Servicios del modo en vivo que hubieran quedado activados.
    rm -f "$D"/etc/systemd/system/*.wants/livesys*.service
    # Imágenes y entradas de rescate (dracut-config-rescue ya no está).
    rm -f "$D"/boot/vmlinuz-0-rescue-* "$D"/boot/initramfs-0-rescue-*.img "$D"/boot/loader/entries/*-0-rescue.conf
}

version_kernel() {
    find "$D/usr/lib/modules/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true
}

# Kernel (ya viene en el sistema de la ISO) y enlaces fijos que usa el menú de Llevix.
familia_kernel() {
    version="$(version_kernel)"
    [[ -n "$version" ]] || fallar "la ISO no trae módulos del kernel"
    if [[ ! -f "$D/boot/vmlinuz-$version" ]]; then
        if [[ -f "$D/usr/lib/modules/$version/vmlinuz" ]]; then
            cp "$D/usr/lib/modules/$version/vmlinuz" "$D/boot/vmlinuz-$version"
        else
            cp "$kernel" "$D/boot/vmlinuz-$version"
        fi
    fi
    ln -sf "vmlinuz-$version" "$D/boot/vmlinuz"
    ln -sf "initramfs-$version.img" "$D/boot/initrd.img"

    # Cuando Fedora instale un kernel nuevo (kernel-install), los enlaces pasan al más nuevo.
    mkdir -p "$D/etc/kernel/install.d"
    cat > "$D/etc/kernel/install.d/95-llevix-enlaces.install" <<'EOF'
#!/usr/bin/sh
# Llevix: el menú de arranque usa /boot/vmlinuz y /boot/initrd.img. Al instalar o quitar un
# kernel, se apuntan al más nuevo que tenga initramfs.
case "$1" in add|remove) ;; *) exit 0 ;; esac
for v in $(ls -1 /boot/vmlinuz-* 2>/dev/null | grep -v -- '-rescue-' | sed 's|^/boot/vmlinuz-||' | sort -rV); do
    if [ -f "/boot/initramfs-$v.img" ]; then
        ln -sf "vmlinuz-$v" /boot/vmlinuz
        ln -sf "initramfs-$v.img" /boot/initrd.img
        exit 0
    fi
done
exit 0
EOF
    chmod 0755 "$D/etc/kernel/install.d/95-llevix-enlaces.install"
}

# Initramfs portátil: Fedora trae hostonly="yes" (solo los controladores de la PC donde se
# genera). Llevix arranca en cualquier PC: hostonly="no" y siempre btrfs.
familia_initramfs() {
    mkdir -p "$D/etc/dracut.conf.d"
    cat > "$D/etc/dracut.conf.d/90-llevix.conf" <<'EOF'
# Llevix: el disco arranca en cualquier PC, así que el initramfs lleva los controladores
# de todas (no solo los de la PC donde se generó).
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" btrfs "
EOF
    rm -f "$D/boot/initramfs-$version.img"
    en_destino "dracut --force --no-hostonly /boot/initramfs-$version.img $version" \
        || fallar "no se pudo crear el initramfs"
    [[ -f "$D/boot/initramfs-$version.img" ]] || fallar "no se creó el initramfs"
}

# UEFI con Secure Boot: el shim, GRUB y MokManager firmados de Fedora (que trae el propio
# sistema) reemplazan a los del instalador (de Ubuntu, que solo aceptan kernels de
# Canonical). Modo "removable" (EFI/BOOT/BOOTX64.EFI): sin fbx64.efi, que registraría el
# arranque en la NVRAM de la PC. GRUB de Fedora busca su grub.cfg en EFI/fedora; ese archivo
# solo lleva al menú de Llevix, dentro del sistema (/@/boot/grub/grub.cfg).
# Al final, las etiquetas de SELinux de todo el sistema nuevo.
familia_arranque() {
    # /boot/efi del sistema nuevo está tapado por la partición EFI montada encima: los
    # archivos de Fedora se leen desde la copia en btrfs (el sistema nuevo ya es @).
    local origen="$T/tope/@/boot/efi/EFI/fedora" esp=/boot/efi d f firma
    for f in shimx64.efi grubx64.efi mmx64.efi; do
        [[ -f "$origen/$f" ]] || fallar "el sistema de Fedora no trae $f"
    done
    firma="$(sbverify --list "$origen/shimx64.efi" 2>/dev/null | sed -n 's/.*subject: //p' | tr '\n' ' ')"
    echo "shim firmado por: ${firma:-nadie}"
    [[ "$firma" == *Microsoft* ]] || fallar "el shim de Fedora no está firmado por Microsoft"
    install -m 0644 "$origen/shimx64.efi" "$esp/EFI/BOOT/BOOTX64.EFI"
    install -m 0644 "$origen/grubx64.efi" "$esp/EFI/BOOT/grubx64.efi"
    install -m 0644 "$origen/mmx64.efi" "$esp/EFI/BOOT/mmx64.efi"
    rm -f "$esp/EFI/BOOT/fbx64.efi"
    for d in EFI/BOOT EFI/fedora; do
        mkdir -p "$esp/$d"
        cat > "$esp/$d/grub.cfg" <<EOF
echo "Llevix: buscando el sistema..."
if search --no-floppy --fs-uuid --set=root $UUID_SIS; then
    set prefix=(\$root)'/@/boot/grub'
    configfile \$prefix/grub.cfg
else
    echo "Llevix: no se encontró la partición del sistema ($UUID_SIS)."
fi
EOF
    done

    # SELinux: los archivos que agregó Llevix (y los copiados) necesitan su etiqueta.
    # Si no se puede aquí, Fedora lo hace en el primer arranque (/.autorelabel).
    if en_destino "setfiles -F -e /proc -e /sys -e /dev -e /run -e /boot/efi \
            /etc/selinux/targeted/contexts/files/file_contexts /" >/dev/null 2>&1; then
        echo "Etiquetas de SELinux aplicadas."
    else
        echo "Aviso: las etiquetas de SELinux se aplicarán en el primer arranque."
        touch "$D/.autorelabel"
    fi
}
