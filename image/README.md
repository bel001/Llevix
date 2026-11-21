# image/

Scripts que construyen una imagen `.img` por cada variante de distribución
(debootstrap + btrfs con zstd). Se ejecutan en Linux o WSL2 con `sudo`.

- `distros/`: un archivo por variante (Ubuntu, Kubuntu, Xubuntu, Lubuntu, Mint...).
- `overlay/`: capa de portabilidad que Llevix agrega a todas las variantes.
- `firstboot/`: servicio systemd del primer arranque (lee `llevix-config.json`).
