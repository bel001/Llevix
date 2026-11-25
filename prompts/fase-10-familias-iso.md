# Fase 10 — "Trae tu ISO" por familias

**Objetivo:** que "Trae tu ISO" instale (de verdad, con persistencia) las distros más
conocidas, reconociéndolas por cómo están hechas y no por su nombre.
Plan: docs/planes/familias-iso.md.

## Prompt
```
Fase 10. Sigue docs/planes/familias-iso.md, sección 8, en orden: 10.1 (casper como módulo,
sin cambiar el comportamiento), 10.2 (detector por características y niveles de
compatibilidad), 10.3 (Debian live), 10.4 (Fedora live). No hagas 10.5 (Arch) hasta que
el dueño decida lo de la llave de Secure Boot en PENDIENTES.md. Nada de arrancar ISOs en
vivo: siempre se instalan. Verifica cada ruta y nombre de paquete con la ISO real antes de
usarlo. Itera hasta que todo pase.
```

## Listo cuando
- [ ] Mint, Kubuntu, Ubuntu y Zorin siguen verdes después de 10.1 (sin cambios para el usuario)
- [ ] El creador muestra la familia y el nivel de compatibilidad de la ISO antes de borrar nada
- [ ] Una ISO sin familia conocida se rechaza en el creador con un motivo claro
- [ ] Debian live y Fedora live se instalan y llegan al escritorio en UEFI+SB, UEFI y BIOS
- [ ] Cuenta, persistencia y arranque en otra "PC" (otro hardware en QEMU) verdes en las dos
- [ ] `tests/compatibilidad-isos.json` tiene el resultado de cada ISO probada
