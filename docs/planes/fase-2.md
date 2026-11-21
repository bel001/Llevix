# Plan — Fase 2: primer arranque personalizado

## Objetivo
Con un `llevix-config.json` en la partición EFI, el primer arranque crea la cuenta del
usuario, aplica idioma, zona horaria, teclado y nombre del equipo, amplía LLEVIX-DATOS
y la monta en `~/Datos`. Sin archivo, o con un archivo erróneo, el sistema igual arranca.

## Archivos
- `docs/llevix-config.md`: formato del archivo.
- `image/firstboot/firstboot.sh` + `llevix-firstboot.service`: el servicio (una vez,
  antes del gestor de sesión). Se copia a `/usr/lib/llevix/` en la imagen.
- `tools/make-config.sh`: genera un config de prueba (hash con `openssl passwd -6`).
- `tests/lib/qemu.sh`: funciones comunes de QEMU, incluido el agente de QEMU
  (`qemu-guest-agent`) para ejecutar comandos dentro de Llevix durante las pruebas.
- `tests/firstboot-test.sh`: pruebas del primer arranque.

## Diseño de firstboot.sh
1. Si ya se hizo (`/var/lib/llevix/firstboot-hecho`), salir.
2. Sin config: anotar `sin-config` y dejar que la distro muestre su bienvenida.
3. Validar TODO antes de tocar nada (tipos, nombre de usuario, hash `$6$`, locale,
   zona, teclado, hostname).
4. Ampliar LLEVIX-DATOS: solo en el disco que contiene `/`, solo la partición 1 con
   nombre LLEVIX-DATOS y solo si está vacía. `sgdisk -e` (GPT al final real del disco),
   recrear la partición con el mismo inicio hasta el final, `partx -u` y `mkfs.exfat`
   (exFAT no se puede agrandar; como está vacía, se vuelve a formatear).
5. Ajustes con respaldo, crear usuario con `useradd --password <hash>`, montar
   `~/Datos` por UUID en fstab (`nofail`, dueño el usuario).
6. Borrar el config y desactivar el servicio.
7. Si algo falla: deshacer en orden inverso, `LLEVIX-ERROR.txt` en la ESP, mensaje en
   plymouth, borrar el config (tiene el hash) y seguir arrancando.

## Cambios en la imagen
- Se quita el usuario temporal `llevix` y el inicio automático.
- Paquetes nuevos: `jq`, `gdisk`, `qemu-guest-agent` (solo se activa dentro de una
  máquina virtual) y paquetes de idioma español.
- El informe por puerto serie agrega `LLEVIX-PRIMER-ARRANQUE resultado=...`.

## Pruebas (CI)
- Disco virtual de 32 GB a partir de la imagen de 28 GiB, con el config inyectado en
  la ESP usando `mtools` (sin montar, sin root).
- Caso válido: usuario, sudo, hash, config borrado, ajustes, LLEVIX-DATOS creció,
  `~/Datos` montado y escribible.
- Persistencia: crear archivos, apagar, volver a arrancar y comprobarlos.
- Config erróneo: resultado=error, LLEVIX-ERROR.txt, sin usuarios, el escritorio igual arranca.
