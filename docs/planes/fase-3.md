# Plan — Fase 3: portabilidad, resistencia y variantes

## Portabilidad
- `MODULES=most` en el initramfs (`/etc/initramfs-tools/conf.d/llevix.conf`).
- Entrada de GRUB "Llevix (modo gráficos seguros)" con `nomodeset`
  (`/etc/grub.d/15_llevix-graficos-seguros`, usa los enlaces `/boot/vmlinuz`).
- NetworkManager: se borran las conexiones guardadas durante la construcción; netplan
  solo dice "NetworkManager maneja todo".
- Nombres de interfaz: se dejan los nombres predecibles de systemd (enp…, wlp…). Ninguna
  configuración de Llevix usa un nombre concreto, así que funcionan en cualquier PC.

## Cuidar el disco
- journald en RAM (`Storage=volatile`), `noatime` (ya estaba), `/tmp` en RAM (`tmp.mount`).
- `fstrim.timer` activado. TRIM en SSD/NVMe por USB: regla udev que activa
  `provisioning_mode=unmap` solo si el disco anuncia UNMAP (`sg_vpd`, paquete sg3-utils).
- `llevix-disco-sistema.service`: desactiva la autosuspensión USB del disco de Llevix y,
  si es un HDD, el apagado por inactividad (`hdparm -S 0 -B 254`).
- Regla udev de planificador: bfq (giratorios), mq-deadline (SSD), none (NVMe).

## Resistencia
- Subvolumen `@snapshots` montado en `/.snapshots`.
- `guardar-estado.sh`: snapshot de `@` antes de cada `apt` (hook `DPkg::Pre-Invoke`),
  conserva 5, ajusta el fstab del snapshot y regenera el menú de GRUB.
- `/etc/grub.d/42_llevix-estados`: submenú "Llevix: volver a un estado anterior".
- `tests/resistencia-test.sh`: apagado brusco (matar QEMU durante una escritura grande),
  volver a arrancar, comprobar btrfs; instalar un paquete y comprobar que se guardó un
  estado y que aparece en el menú; comprobar journald, /tmp, TRIM y planificador.

## Variantes
- `image/distros/`: ubuntu, kubuntu, xubuntu, lubuntu (24.04) y mint-22-cinnamon,
  mint-22-mate, mint-22-xfce. Cada una con su metapaquete de escritorio sin cambios.
- Mint 22: base noble + repositorio `packages.linuxmint.com` (22.3 "zena"), llave
  `linuxmint-keyring` verificada por SHA256, prioridad 700 para los paquetes de Mint
  (como hace Mint). En Mint no se excluye Firefox (Mint lo trae como paquete .deb).
- El workflow construye y prueba todas las variantes en una matriz.
