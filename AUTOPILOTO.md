# Piloto automático de Llevix

Este archivo es el prompt para que Claude Code construya Llevix por su cuenta,
fase tras fase, sin esperar instrucciones entre una y otra.

## Cómo usarlo

```bash
cd ~/llevix
claude --permission-mode auto
```

Si tu plan no permite el modo `auto`, usa `claude --permission-mode acceptEdits`
(te preguntará solo por algunos comandos).

Pega esto en Claude Code:

```
Lee CLAUDE.md, AUTOPILOTO.md y la carpeta prompts/. Trabaja en modo piloto
automático siguiendo las reglas de AUTOPILOTO.md, empezando por la fase que
indique "Estado actual" en CLAUDE.md. No me preguntes entre fases.
```

Si se detiene (por límite de uso, por cerrar la terminal o porque necesita algo),
revisa `PENDIENTES.md`, resuelve lo que pida y vuelve a pegar el mismo prompt.
Continúa donde quedó.

---

## Reglas del piloto automático (para Claude Code)

### Orden de trabajo
1. Lee "Estado actual" en CLAUDE.md para saber en qué fase estás.
2. Abre `prompts/fase-N-*.md` y cumple su sección "Prompt".
3. Antes de escribir código en una fase nueva, escribe un plan corto en
   `docs/planes/fase-N.md` y síguelo. No esperes aprobación.
4. Implementa en una rama `fase-N`, con commits pequeños y mensajes en español.
5. Prueba (ver "Cómo probar sin ayuda").
6. Cuando se cumpla todo lo verificable automáticamente de "Listo cuando":
   - fusiona la rama en `main` y haz `git push`;
   - actualiza "Estado actual" en CLAUDE.md;
   - escribe en `docs/BITACORA.md` qué se hizo, qué se decidió y qué quedó pendiente;
   - pasa a la siguiente fase sin preguntar.
7. Las fases automáticas son 0, 1, 2, 3, 4 y 5. En la fase 6 prepara todo
   (scripts, matriz, guía) y luego detente: requiere personas y PCs reales.

### Cómo probar sin ayuda
- Primero intenta probar localmente lo que no necesita `sudo` (shellcheck, pruebas
  unitarias, `cargo test`, `npm test`).
- Todo lo que necesita `sudo`, loop devices o QEMU se prueba en **GitHub Actions**:
  1. Crea o actualiza el workflow en `.github/workflows/`.
  2. `git push` de la rama.
  3. `gh run watch` para esperar el resultado.
  4. Si falla: `gh run view --log-failed`, corrige y repite.
- La app de Windows se compila y se prueba en un runner `windows-latest`.
  La lógica que elige el disco se prueba con discos simulados (mocks), nunca reales.

### Cuándo detenerte
Detente y escribe en `PENDIENTES.md` (qué necesitas, por qué y cómo hacerlo, en
pasos simples) solo si:
- necesitas una decisión del dueño que no está en CLAUDE.md ni en docs/;
- necesitas credenciales, pagos, cuentas o secretos;
- necesitas una prueba en hardware físico;
- el mismo problema falló 5 veces seguidas con enfoques distintos;
- vas a hacer algo que no se puede deshacer fuera del repositorio.

Al detenerte, deja el repositorio en un estado que compile, con commit y push.

### Prohibido siempre
- Escribir en discos físicos (`/dev/sd*`, `/dev/nvme*`, `/dev/mmcblk*`,
  `\\.\PhysicalDrive*`). Solo archivos de imagen y loop devices.
- Usar `dd` contra dispositivos. Para crear imágenes vacías usa `truncate` o `fallocate`.
- `git push --force` a `main`, borrar ramas remotas o cambiar la configuración del
  repositorio en GitHub.
- Guardar contraseñas, tokens o secretos en el repositorio.
- Copiar código GPL de otros proyectos mientras la licencia esté pendiente.
- Desactivar o saltarse pruebas para que algo "pase".
