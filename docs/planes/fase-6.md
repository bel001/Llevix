# Plan — Fase 6: preparar la beta (y detenerse)

1. `tools/report.sh`: reporte de diagnóstico (PC, CPU, GPU, memoria, UEFI/BIOS, Secure
   Boot, versión de Llevix, discos sin números de serie, red, servicios con fallo,
   errores del arranque). Quita usuario, nombre del equipo, MAC, IP, UUID, series y
   nombres de WiFi. Se instala en la imagen como `/usr/lib/llevix/report.sh` y guarda el
   `.txt` en `~/Datos`. Se prueba en CI dentro de `firstboot-test.sh`.
2. Plantillas de issues en español (`.github/ISSUE_TEMPLATE/`): "Funcionó en mi PC",
   "No arranca" y "Algo no funciona".
3. `docs/BETA.md`: guía para testers (qué probar y cómo reportar).
4. README: descarga, requisitos, variantes, cómo arrancar, preguntas frecuentes y
   espacios marcados para los GIFs.
5. `PENDIENTES.md`: tareas humanas de la beta. Después de esto, el piloto automático se detiene.
