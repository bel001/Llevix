# Plan — Fase 9: catálogo más grande

## Idea
Las distros de la familia Ubuntu se construyen **desde su ISO oficial** reutilizando el
instalador de la fase 8 (`image/desde-iso.sh`): en CI se instala la ISO en una copia de la
imagen del instalador (encabezado `modo=imagen`: no amplía datos y apaga al terminar),
después, con loop devices, se borra el instalador, se aplica la marca, se agregan las
herramientas de Llevix y el agente de QEMU, se comprueba el escritorio completo y se
libera el espacio. Las pruebas son las mismas que las de las otras variantes.

`TIPO=desde-iso` en `image/distros/<variante>.conf` con `ISO_URL` e `ISO_SUMAS`.

## Distros
| Distro | Estado |
| --- | --- |
| Zorin OS 18 Core | Primera (ISO oficial con SHA256 en mirrors.edge.kernel.org). |
| elementary OS 8 | Su descarga usa enlaces temporales; buscar una fuente estable. |
| Pop!_OS | Fuera: su kernel no está firmado por Canonical y no arrancaría con Secure Boot. |
| Debian 13 | Aparte: `BASE=debian` en build.sh (debootstrap, shim/GRUB firmados por Debian). |
| Fedora | Último: herramientas distintas (dnf), se evalúa después. |
