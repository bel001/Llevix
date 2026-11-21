# Fase 4 — Publicación automática

**Objetivo:** al crear una etiqueta de versión, GitHub construye, prueba y publica
todas las imágenes listas para descargar.
**Tiempo aprox.:** 3–5 días.

## Prompt

```
Fase 4. Primero escribe el plan en docs/planes/fase-4.md.

Crea .github/workflows/release.yml que, al hacer push de una etiqueta vX.Y.Z:
1. construya todas las variantes;
2. ejecute todas las pruebas de QEMU;
3. por cada variante genere: .img.zst, .bmap (con bmaptool create), SHA256;
4. genere manifest.json con: versión, variantes (nombre visible, si es ligera,
   descripción corta en español, URL, tamaño, SHA256, URL del bmap);
5. cree un GitHub Release con todo eso y notas de cambios en español;
6. en las notas, enlace al código fuente de los paquetes de la distro
   (cumplimiento de licencias GPL).
Si las imágenes superan el tamaño máximo de un asset de GitHub Releases,
divídelas en partes o propón otra opción y anótalo en PENDIENTES.md.
Haz una versión de prueba v0.0.1-test y verifica que el Release se crea bien.
```

## Qué haces tú
- Nada obligatorio. Revisa que el Release de prueba se vea bien en GitHub.

## Listo cuando
- [ ] La etiqueta de prueba genera un Release con imágenes, bmap, SHA256 y manifest.json
- [ ] manifest.json es válido y tiene todas las variantes
