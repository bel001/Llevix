# Fase 6 — Pruebas reales y beta

**Objetivo:** Llevix probado en al menos 10 PCs y con 20–50 usuarios beta.
**Tiempo aprox.:** 2–4 semanas.

## Prompt

```
Fase 6. Prepara todo lo necesario para la beta y luego detente:
1. tools/report.sh: desde Llevix, recopila marca, modelo, CPU, GPU, modo de
   arranque (UEFI/BIOS), Secure Boot, logs de arranque y errores; quita datos
   personales; guarda un .txt en ~/Datos para adjuntarlo a un issue.
2. Plantillas de issues de GitHub en español: "Funcionó en mi PC", "No arranca",
   "Algo no funciona".
3. docs/BETA.md: guía para testers (qué probar, cómo reportar).
4. Mejora el README: sección de descarga, requisitos, capturas (deja espacios
   marcados para que el dueño agregue GIFs) y preguntas frecuentes.
5. Escribe en PENDIENTES.md la lista de tareas humanas de la beta.
Después, cada vez que te pase un issue o reporte, diagnostica y corrige.
```

## Qué haces tú (esta fase es sobre todo humana)
- Probar en 10 PCs distintas y llenar `tests/hardware-matrix.md`.
- Grabar 2 GIFs para el README: el asistente y el arranque.
- Conseguir testers en comunidades de Linux en español.
- Pasarle a Claude Code cada issue: "revisa el issue #N y corrígelo".

## Listo cuando
- [ ] 10 PCs probadas, sin errores graves abiertos
- [ ] 20 o más testers lo usaron
- [ ] Licencia elegida y nombre confirmado
