# Bitácora de Llevix

Lo más reciente arriba. Cada fase anota qué se hizo, qué se decidió y qué quedó pendiente.

## Fase 0 — Arranque del proyecto (2026-11-21)

**Qué se hizo**
- Estructura de carpetas, README.md, CONTRIBUTING.md, .gitignore y .gitattributes.
- `tools/check-env.sh`: revisa el entorno en Windows (creador), WSL/Linux (imágenes y
  pruebas) y lo común (git, gh, Node.js). Dentro de WSL ignora los programas de Windows
  que WSL comparte en el PATH (antes daba `npm` por instalado cuando no lo estaba).
- `.github/workflows/lint.yml`: shellcheck en todos los `.sh`.

**Decisiones**
- `.gitattributes` fuerza LF en todo el repositorio (se trabaja desde Windows).
- shellcheck local se ejecuta con Docker (`koalaman/shellcheck`) porque no está instalado.

**Pendiente**
- `check-env.sh` todavía marca faltantes en la PC del dueño (Rust en Windows; paquetes
  de imagen y Node.js en WSL). Instalarlos necesita la contraseña de sudo: ver PENDIENTES.md.
  No bloquea el avance porque la construcción y las pruebas corren en GitHub Actions.
- La WSL del dueño tiene Ubuntu 26.04, no 24.04 (la base de Llevix). Para desarrollar
  sirve igual.
