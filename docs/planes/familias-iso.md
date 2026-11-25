# Plan — "Trae tu ISO" para la mayoría de las distros (familias de ISO)

Pedido del dueño (2026-11-25): que "Trae tu ISO" funcione con cualquier ISO, o con las
más conocidas, tomando ideas de un motor de arranque universal tipo Ventoy, **pero sin el
modo en vivo**: Llevix sigue **instalando de verdad** la distro, con persistencia completa
(actualizaciones, programas y archivos se conservan).

## 1. Qué tomamos del prompt "motor universal" y qué no

El prompt describe un gestor que arranca las ISO **sin instalarlas** (emulación de CD,
INT 13h, drivers UEFI de bloque, entregar la ISO al kernel después de ExitBootServices).
Todo eso existe para un problema que Llevix **no tiene**: Llevix saca el sistema de la ISO
y lo instala en btrfs, así que después del arranque no hace falta "volver a encontrar"
la ISO. Por eso:

| Idea del prompt | ¿Se usa? | Cómo queda en Llevix |
| --- | --- | --- |
| Compatibilidad por **familias técnicas**, no por nombres de distro | ✅ | Núcleo de este plan (sección 3) |
| Detectar por **características internas** (carpetas, parámetros del kernel, initramfs), no por el nombre del archivo | ✅ | Detector en el creador y en el instalador (sección 4) |
| **Perfiles declarativos** (JSON) con versión y validación | ✅ | `image/instalador/familias.json`, lo leen el creador (Rust) y el instalador (`jq`) |
| **Niveles de compatibilidad** (reconocida, verificada, incompatible…) | ✅ | Sección 5; nunca "compatible" solo porque se reconoce la estructura |
| **Base de datos de pruebas** (ISO, hash, firmware, resultado, fecha) | ✅ | `tests/compatibilidad-isos.json`, la llena CI |
| La ISO es **entrada no confiable**: validar tamaños, rutas y límites | ✅ | Ya en `iso.rs`; se extiende a lo nuevo |
| Secure Boot con componentes firmados; nunca desactivarlo | ✅ | Sección 6 |
| Diagnóstico de en qué paso falló | ✅ | Ya existe (puerto serie + LLEVIX-ERROR.txt); se agrega la familia y el paso |
| QEMU + OVMF, BIOS y UEFI, criterio verificable (escritorio) | ✅ | Ya existe; se agrega una ISO real por familia |
| Varias ISO en la misma memoria con menú de arranque | ❌ | Llevix es un sistema por disco |
| Arrancar la ISO en vivo, emulación de CD, INT 13h, EDK2 Block IO, ExitBootServices | ❌ | No se arranca la ISO: se instala |
| Windows PE / instaladores de Windows, BSD, FreeDOS | ❌ | Llevix es Linux portátil; fuera de alcance |
| Copiar código de Ventoy o GRUB | ❌ | Son GPL (regla de licencia). Se usan los binarios firmados de cada distro, sin copiar código |

## 2. Cómo funciona hoy (solo familia Ubuntu)

`image/instalador/instalar-iso.sh`, en el primer arranque, en el propio disco:
1. Encuentra la ISO guardada por el creador y comprueba su SHA256.
2. Busca el sistema en `casper/` (squashfs o capas de Ubuntu 24.04+).
3. Lo copia a un subvolumen btrfs nuevo.
4. Quita los paquetes del modo en vivo con `apt`.
5. Kernel e initramfs con `update-initramfs`.
6. Capa de Llevix, `fstab`, GRUB (`grub-mkconfig` o menú escrito a mano).
7. Arranca con el shim y GRUB **de Ubuntu** que ya están en la ESP: por eso solo sirven
   kernels firmados por Canonical.

Los pasos 2, 4, 5 y 7 son los que cambian de una familia a otra.

## 3. Familias

Cada familia implementa los mismos pasos (un archivo `image/instalador/familias/<id>.sh`
con funciones de nombre fijo). El resto del instalador es común.

| Paso | casper (hoy) | live-boot (Debian) | dracut (Fedora) | archiso (Arch) |
| --- | --- | --- | --- | --- |
| Dónde está el sistema | `casper/*.squashfs` | `live/filesystem.squashfs` | `LiveOS/squashfs.img` (a veces con `LiveOS/rootfs.img` dentro) | `arch/x86_64/airootfs.sfs` o `.erofs`; Manjaro: varias capas `*.sfs` |
| Parámetro que la delata | `boot=casper` | `boot=live` | `rd.live.image` | `archisobasedir=` / `misobasedir=` |
| Paquetes del modo en vivo | `apt purge` (casper, ubiquity…) | `apt purge` (live-boot, live-config, calamares…) | `dnf remove` sin red (anaconda, livesys-scripts…) | `pacman -R` (archiso, calamares…) + quitar usuario/servicios del live |
| Initramfs | `update-initramfs` | `update-initramfs` | `dracut` con `hostonly="no"` | `mkinitcpio` **sin** el hook `autodetect` |
| Secure Boot | shim de Ubuntu (ya en la ESP) | shim + GRUB **de Debian**, desde la ISO | shim + GRUB **de Fedora**, desde la ISO | no traen shim firmado (sección 6) |
| Otros | — | — | SELinux: reetiquetar (`/.autorelabel`); GRUB con BLS | — |
| Distros que cubre | Ubuntu y sabores, Mint, Zorin, elementary, KDE neon, Linux Lite | Debian live; MX Linux más tarde (usa otra carpeta) | Fedora Workstation/KDE, Nobara; openSUSE a revisar (también usa `LiveOS/`) | EndeavourOS, Manjaro, CachyOS |

**Portabilidad, lo más importante:** el initramfs debe traer los controladores de
cualquier PC. `update-initramfs` ya lo hace (`MODULES=most`), pero `dracut` y
`mkinitcpio`, por defecto, solo meten los de la PC donde se generan. Por eso
`hostonly="no"` y quitar `autodetect`. Si no, el disco arrancaría solo en una PC.

**Todo lo de las columnas nuevas se verifica con la ISO real antes de darlo por bueno**
(rutas exactas, nombres de paquetes, dónde busca su GRUB el `grub.cfg`). Lo de esta tabla
es el punto de partida, no un resultado.

**Pop!_OS** usa `casper_<versión>/` y `systemd-boot` y su kernel no está firmado para
Secure Boot: entra como "requiere llave propia" (sección 6) o queda fuera.

## 4. Detector por características (sin lista de nombres)

`image/instalador/familias.json` (versión 1), una entrada por familia:
- **Señales en la ISO** (sin montar el squashfs): carpetas y archivos (`casper/`, `live/`,
  `LiveOS/squashfs.img`, `*/x86_64/*.sfs`) y parámetros del kernel encontrados en
  `boot/grub/grub.cfg`, `isolinux/*.cfg` o `loader/entries/*.conf`.
- **Señales en el sistema** (el instalador, ya montado el squashfs): gestor de paquetes
  (`dpkg`, `rpm`, `pacman`), generador de initramfs (`update-initramfs`, `dracut`,
  `mkinitcpio`) y arquitectura de `/usr/bin/bash` (solo x86_64).
- Secure Boot esperado: quién firma el kernel y si la ISO trae shim firmado por Microsoft.

Dos niveles de detección:
1. **Creador (Windows, Rust, `iso.rs`)**: solo lee la ISO. Decide la familia con las señales
   de la ISO y la muestra antes de borrar nada. Si ninguna familia coincide, no escribe.
2. **Instalador (Linux)**: confirma con las señales del sistema. Si no coinciden, se detiene
   y deja el disco como instalador, con el motivo (como hoy).

Una distro nueva que use un mecanismo conocido funciona sin cambiar código.

## 5. Niveles de compatibilidad (lo que ve el usuario)

| Nivel | Cuándo | Qué muestra el creador |
| --- | --- | --- |
| Verificada | Su familia y versión pasaron las pruebas de CI (`tests/compatibilidad-isos.json`) | "Probada por Llevix" |
| Compatible por familia | Familia reconocida y soportada, pero esa distro no se probó | "Debería funcionar (familia Debian); no probada todavía" |
| Requiere llave de Secure Boot | Familia archiso o kernel sin firma reconocida | Explicación de la pantalla azul de una sola vez (sección 6), o "no soportada" mientras no se decida |
| No compatible | Ninguna familia coincide, 32 bits o más de 8 GB | Motivo claro y sugerir el catálogo |

`tests/compatibilidad-isos.json`: nombre, versión, sha256 de la ISO, familia, firmware
(UEFI+SB, UEFI, BIOS), resultado, paso donde falló, versión de Llevix y fecha. CI lo
actualiza; el creador incluye una copia para mostrar "Verificada".

## 6. Secure Boot por familia (riesgo principal)

- **casper:** como hoy, shim de Ubuntu.
- **live-boot y dracut:** se copian a la ESP el shim, el GRUB y `mmx64.efi` **de la propia
  ISO** (firmados por Microsoft y por la distro), con un `grub.cfg` donde ese GRUB lo
  busca. Así cada distro arranca con su propia cadena de confianza, sin desactivar nada.
  BIOS sigue con el GRUB del instalador y el menú escrito a mano (el GRUB de Ubuntu no
  entiende el formato BLS de Fedora).
- **archiso (y Pop!_OS):** no hay shim firmado. La única forma sin desactivar Secure Boot
  es que Llevix firme el kernel con una llave propia y el usuario la registre **una vez**
  en una pantalla azul (MOK) al primer arranque. **Decisión del dueño** (PENDIENTES.md):
  - es más difícil para un usuario nuevo;
  - la llave privada queda en el disco para firmar cada actualización del kernel: quien
    tenga la memoria podría firmar otro kernel que esa PC aceptaría.
  Hasta decidir, la familia archiso se reconoce pero se marca "no soportada con Secure Boot".
- Certificado Microsoft 2011 vencido (junio 2026): cada shim copiado de una ISO se prueba
  en firmware con solo 2011, solo 2023 y ambos, como pide CLAUDE.md.

## 7. Pruebas (CI)

Por cada familia, una ISO real descargada en CI (como hoy Mint, Kubuntu y Zorin) con
el mismo recorrido: creador simulado → instalador → QEMU en UEFI+SB, UEFI y BIOS →
escritorio, red, sonido, navegador, cuenta, persistencia tras reiniciar y arranque en una
"PC distinta" (otro modelo de CPU/disco en QEMU, para probar que el initramfs es portátil).
Cada resultado se agrega a `tests/compatibilidad-isos.json`. Las ISO de cada familia
siguen probándose en cada cambio de `image/instalador/` (regresión).

## 8. Fases

Cada fase termina con todo en verde en CI antes de seguir.

1. **10.1 Familias como módulos:** pasar la lógica de casper a `familias/casper.sh` y crear
   `familias.json`, sin cambiar el comportamiento. Mint, Kubuntu, Ubuntu y Zorin siguen verdes.
2. **10.2 Detector y niveles:** detector por señales en `iso.rs` y en el instalador;
   `tests/compatibilidad-isos.json`; el creador muestra el nivel. Pruebas unitarias con
   ISOs de prueba armadas a mano (sin descargar).
3. **10.3 Familia live-boot:** Debian 13 live (GNOME o Xfce). Incluye shim de la ISO.
4. **10.4 Familia dracut:** Fedora Workstation Live. SELinux, `hostonly=no`, GRUB con BLS.
5. **10.5 Familia archiso:** solo si el dueño aprueba la llave propia (sección 6).
   EndeavourOS primero, después Manjaro (capas).
6. **10.6 Ampliar:** openSUSE (revisar si cabe en dracut), MX Linux, Pop!_OS.

## 9. Riesgos conocidos

- Cada familia cambia su formato de ISO con el tiempo (Ubuntu ya lo hizo en 24.04).
  Mitigación: las pruebas con ISO real detectan el cambio.
- Distros sin paquetes dentro de la ISO (Fedora live) no pueden instalar nada sin
  internet durante la instalación: todo lo necesario debe estar en el sistema de la ISO
  o lo debe traer el instalador de Llevix.
- Algunas ISO superan 8 GB (límite actual de la zona reservada).
- Sin la decisión de la sección 6, Arch y derivados no se pueden ofrecer.
