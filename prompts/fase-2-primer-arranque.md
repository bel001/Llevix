# Fase 2 — Primer arranque personalizado

**Objetivo:** el sistema crea la cuenta del usuario y amplía la partición de datos
a partir de `llevix-config.json`.
**Tiempo aprox.:** 1 semana.

## Prompt

```
Fase 2. Primero escribe el plan en docs/planes/fase-2.md.

1. Define el formato de llevix-config.json en docs/llevix-config.md (versión,
   usuario, hash SHA-512 de la contraseña, idioma, zona horaria, hostname,
   teclado, opciones de accesibilidad para el futuro).
2. Crea el servicio systemd llevix-firstboot (image/firstboot/), que se ejecute
   una sola vez antes del gestor de sesión:
   - lee /boot/efi/llevix-config.json y valida el formato;
   - crea el usuario con sudo, aplica idioma, zona horaria, teclado y hostname;
   - amplía la partición LLEVIX-DATOS (partición 1) al espacio libre del disco y
     la monta en ~/Datos;
   - borra el archivo de configuración y se desactiva;
   - si algo falla, muestra un mensaje claro en pantalla y no deja el sistema a
     medias (todo o nada).
3. Quita el usuario temporal "llevix" de la fase 1.
4. Crea tools/make-config.sh para generar un llevix-config.json de prueba.
5. Amplía las pruebas de QEMU: con un disco virtual de 32 GB, inyecta un config
   de prueba, arranca y verifica que el usuario existe, que LLEVIX-DATOS creció y
   que el archivo se borró. Reinicia y verifica que un archivo creado antes sigue
   ahí (persistencia).
Itera en GitHub Actions hasta que todo pase.
```

## Qué haces tú
- Nada obligatorio.

## Listo cuando
- [ ] El primer arranque crea el usuario y amplía los datos (prueba en CI)
- [ ] La persistencia tras reinicio pasa en CI
- [ ] Un config con errores muestra un mensaje claro y no rompe el sistema (prueba en CI)
