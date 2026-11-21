# Guía completa para construir Llevix

Esta guía te lleva desde una computadora vacía hasta publicar Llevix en GitHub.
Síguela en orden. Cada paso dice qué hace Claude Code y qué haces tú.

---

## Índice

1. Lo que necesitas
2. Preparar tu computadora
3. Crear el repositorio
4. Cómo trabajar con Claude Code
5. Fases de desarrollo (0 a 7)
6. Cómo probar en una PC real
7. Beta y lanzamiento
8. Decisiones pendientes
9. Problemas comunes

---

## 1. Lo que necesitas

**Hardware**

| Qué | Mínimo | Ideal |
| --- | --- | --- |
| Tu PC de trabajo | 8 GB RAM, 80 GB libres | 16 GB RAM, 150 GB libres, SSD |
| USB de pruebas | 1 memoria USB 3.x de 64 GB | 2 memorias + 1 SSD externo USB-C |
| PCs para probar | 3 distintas (familia, amigos) | 10 distintas: Intel, AMD, NVIDIA, una vieja con BIOS |
| Celular Android con USB-C | 1 | 2 de marcas distintas |

**Cuentas**

- GitHub (gratis): https://github.com
- Claude con plan que incluya Claude Code (Pro o superior)

**Sistema operativo para desarrollar**

Construir imágenes de Linux necesita Linux. Opciones, de mejor a peor:

1. **Ubuntu 24.04 instalado** (en una PC vieja o en arranque doble). Lo más confiable.
2. **WSL2 con Ubuntu 24.04** dentro de Windows 11. Funciona bien; usar Windows 11, no 10.
3. **Máquina virtual** (VirtualBox o VMware) con Ubuntu 24.04. Más lenta.

Esta guía usa WSL2 porque es lo más común. Si usas Ubuntu instalado, sáltate el paso 2.1.

---

## 2. Preparar tu computadora

### 2.1 Instalar WSL2 con Ubuntu (solo si usas Windows)

1. Abre **PowerShell como administrador** (clic derecho en Inicio → Terminal (Administrador)).
2. Ejecuta:
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
3. Reinicia la PC cuando lo pida.
4. Se abrirá Ubuntu y te pedirá crear un usuario y contraseña de Linux. Anótalos.
5. A partir de aquí, todo se hace dentro de la ventana de **Ubuntu**.

Importante: trabaja siempre dentro de la carpeta de Linux (`~/llevix`), no en `/mnt/c/...`.
Es mucho más rápido.

### 2.2 Actualizar Ubuntu e instalar herramientas básicas

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl build-essential
```

### 2.3 Configurar Git

```bash
git config --global user.name "Tu Nombre"
git config --global user.email "tu-correo@ejemplo.com"
git config --global init.defaultBranch main
```

### 2.4 Instalar la herramienta de GitHub (gh) e iniciar sesión

```bash
sudo apt install -y gh
gh auth login
```

Elige: GitHub.com → HTTPS → Login with a web browser. Sigue las instrucciones.

### 2.5 Instalar Claude Code

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Cierra y vuelve a abrir la terminal de Ubuntu. Comprueba:

```bash
claude --version
```

Si dice "command not found", revisa:
https://code.claude.com/docs/en/troubleshoot-install

### 2.6 Instalar en Windows (para probar USBs)

- **Rufus** (https://rufus.ie) o **balenaEtcher** (https://etcher.balena.io): para escribir
  la imagen al USB mientras el creador de Llevix no existe.

---

## 3. Crear el repositorio

```bash
cd ~
mkdir llevix && cd llevix
git init
```

Copia dentro de `~/llevix` todo el contenido de este kit:

```
llevix/
├── CLAUDE.md               (instrucciones que Claude Code lee siempre)
├── AUTOPILOTO.md           (prompt y reglas del modo automático)
├── GUIA.md                 (esta guía)
├── PENDIENTES.md           (lo que la IA necesita de ti)
├── prompts/                (un archivo por fase, 0 a 7)
├── tests/hardware-matrix.md
├── .claude/settings.json   (permisos: qué puede hacer la IA sin preguntar)
└── .gitignore
```

Ojo: `.claude` y `.gitignore` empiezan con punto y Windows puede ocultarlos.
En el Explorador activa Vista → Mostrar → Elementos ocultos.

La primera vez que abras Claude Code en la carpeta te preguntará si confías en ella:
responde que sí, para que se apliquen los permisos de `.claude/settings.json`.

Desde Windows puedes abrir la carpeta de Linux escribiendo en el Explorador:
`\\wsl$\Ubuntu-24.04\home\TU_USUARIO\llevix` y arrastrar los archivos ahí.

Opcional: exporta como Markdown los documentos "Llevix — Definición del producto" y
"Llevix — Plan de desarrollo con Claude Code" y guárdalos en `docs/` como
`definicion-producto.md` y `plan-desarrollo.md`.

Primer commit y subida a GitHub:

```bash
git add .
git commit -m "Kit inicial de Llevix"
gh repo create llevix --public --source=. --push
```

---

## 4. Cómo trabajar con Claude Code

### Opción recomendada: piloto automático (la IA hace todo lo que puede sola)

```bash
cd ~/llevix
claude --permission-mode auto
```

(Si tu plan no permite `auto`, usa `claude --permission-mode acceptEdits`.)

Pega el prompt que está en `AUTOPILOTO.md`. Claude Code:
- avanza por las fases 0 a 5 sin preguntarte entre fases;
- escribe el código, lo prueba en GitHub Actions (en la nube, sin pedirte contraseña)
  y corrige los errores solo;
- hace los commits, actualiza CLAUDE.md y escribe una bitácora en `docs/BITACORA.md`;
- cuando necesita algo de ti, lo anota en `PENDIENTES.md` y se detiene.

Tu trabajo en este modo:
1. Revisar `PENDIENTES.md` cada vez que se detenga.
2. Resolver lo que pida y volver a pegar el prompt de `AUTOPILOTO.md`.
3. Hacer las pruebas físicas: después de la fase 3 y de la fase 5 (ver sección 6).

Lo que la IA **no puede** hacer: conectar USBs a computadoras y reiniciarlas,
crear cuentas o pagar servicios, elegir la licencia por ti, conseguir testers.

Si Claude Code alcanza el límite de uso de tu plan, se detendrá; cuando se renueve,
vuelve a pegar el prompt y sigue donde quedó.

### Opción manual: una fase a la vez

### Abrirlo

```bash
cd ~/llevix
claude
```

### La rutina de cada fase

1. Abre Claude Code en `~/llevix`.
2. Abre el archivo de la fase en `prompts/` y copia el bloque "Prompt".
3. Pégalo en Claude Code.
4. Si te muestra un plan: léelo. Si algo no te queda claro, pregunta. Luego apruébalo.
5. Claude Code te pedirá permiso para ejecutar comandos. Lee cada uno antes de aceptar,
   sobre todo los que usan `sudo`, `dd`, `rm` o mencionan discos (`/dev/sd...`).
6. Cuando termine, revisa la lista "Listo cuando" del archivo de la fase.
7. Si algo falla, copia el error completo y pégaselo.
8. Cuando todo esté bien: pídele "haz commit y actualiza Estado actual en CLAUDE.md".
9. Sube los cambios: `git push`.

### Consejos

- **Modo plan:** presiona `Shift+Tab` hasta ver "plan mode" para que Claude Code solo
  planifique sin tocar archivos. Úsalo al empezar cada fase grande.
- **Una fase por sesión.** Para empezar limpio, cierra Claude Code (`/exit`) y ábrelo de nuevo.
- **Si se confunde o da vueltas:** dile "para, resume qué intentaste y qué falló" y luego
  decide tú el siguiente paso.
- **Si no entiendes algo:** "explícame esto como si fuera principiante".
- **Nunca le des contraseñas** de tus cuentas en el chat.

---

## 5. Fases de desarrollo

| Fase | Qué se logra | Tiempo aprox. | Archivo |
| --- | --- | --- | --- |
| 0 | Repositorio ordenado y entorno verificado | 1 día | prompts/fase-0-inicio.md |
| 1 | Primera imagen que arranca en QEMU | 1–2 semanas | prompts/fase-1-imagen.md |
| 2 | Primer arranque crea usuario y amplía datos | 1 semana | prompts/fase-2-primer-arranque.md |
| 3 | Portable entre PCs y resistente | 1–2 semanas | prompts/fase-3-portabilidad.md |
| 4 | GitHub construye y publica solo | 3–5 días | prompts/fase-4-ci.md |
| 5 | Creador para Windows | 2–3 semanas | prompts/fase-5-creador.md |
| 6 | Pruebas en PCs reales y beta | 2–4 semanas | prompts/fase-6-beta.md |
| 7 | Funciones después de la v1 | continuo | prompts/fase-7-extras.md |

**Regla de oro:** no pases a la siguiente fase hasta que la actual cumpla su "Listo cuando".

Hito importante: al terminar la **fase 3** ya tienes un USB de Llevix funcionando,
aunque todavía lo escribas con Rufus o Etcher. Pruébalo en PCs reales en ese momento.

---

## 6. Cómo probar en una PC real

### 6.1 Escribir la imagen al USB (antes de que exista el creador)

En Windows con **Rufus**:
1. Selecciona el USB (¡revisa que sea el correcto!).
2. Selecciona el archivo `llevix-....img` (cópialo desde `\\wsl$\...\llevix\out\`).
3. Si pregunta el modo, elige **"Escribir en modo imagen DD"**.
4. Empezar. Todo lo que tenía el USB se borra.

Con **balenaEtcher**: Flash from file → elige el USB → Flash.

### 6.2 Arrancar desde el USB

Usa siempre el **menú de arranque de una sola vez**. **No desactives Secure Boot**:
en PCs con BitLocker puede pedir la clave de recuperación de Windows.

| Marca | Tecla al encender |
| --- | --- |
| HP | Esc y luego F9 |
| Lenovo | F12 (o el botón Novo) |
| Dell | F12 |
| Asus | Esc (laptops) o F8 (escritorio) |
| Acer | F12 |
| MSI | F11 |
| Toshiba | F12 |
| Samsung | Esc o F10 |

Si la tecla no funciona, en Windows: Configuración → Sistema → Recuperación →
Inicio avanzado → Reiniciar ahora → Usar un dispositivo → elige el USB.

### 6.3 Qué anotar en cada PC

Llena una fila en `tests/hardware-matrix.md` por cada PC. Si algo falla:
1. Toma foto de la pantalla con el error.
2. Si llegas al escritorio, ejecuta `tools/report.sh` (existe desde la fase 6).
3. Pásale a Claude Code la foto descrita o el reporte.

---

## 7. Beta y lanzamiento

### Antes de la beta
- [ ] Fases 0 a 5 completas
- [ ] Probado en al menos 5 PCs distintas sin errores graves
- [ ] README con GIF del asistente y del arranque
- [ ] Guía de arranque por marca publicada en la web (fase 7i)
- [ ] Licencia elegida (ver sección 8)

### Beta (20–50 personas)
- Busca voluntarios en grupos de Linux en español (Telegram, Discord, Reddit r/linuxesp).
- Pídeles que llenen la matriz de hardware o abran un issue con `tools/report.sh`.
- Responde los issues rápido; es lo que más fideliza.

### Lanzamiento v1
- [ ] Release en GitHub con imágenes, SHA256 y el instalador de Windows
- [ ] Publicar en: Reddit (r/linux, r/opensource, r/linuxesp), Hacker News ("Show HN"),
      comunidades de Linux en español, YouTube (video corto mostrando el uso)
- [ ] Activar GitHub Sponsors

---

## 8. Decisiones pendientes

| Decisión | Opciones | Cuándo decidir |
| --- | --- | --- |
| Licencia | GPL-3.0 (recomendada) o MIT | Antes de la beta |
| Nombre definitivo | Confirmar que "Llevix" está libre (marca, dominio, redes) | Antes de la beta |
| Firma del instalador de Windows | SignPath Foundation (gratis para open source), certificado OV ($300–500/año) o sin firma | Fase 5 |
| Partición de datos cifrada o no | Sin cifrar (el celular la lee) o cifrada (más privada) | Fase 7a |
| Vender USBs preparados | Sí / No | Después del lanzamiento |

Mientras la licencia no esté decidida: no copiar código GPL de otros proyectos.

---

## 9. Problemas comunes

| Problema | Qué hacer |
| --- | --- |
| `claude: command not found` | Cerrar y abrir la terminal; ver https://code.claude.com/docs/en/troubleshoot-install |
| WSL2 muy lento | Trabajar en `~/llevix`, no en `/mnt/c/` |
| `losetup` o `mount` falla en WSL2 | Pedirle a Claude Code que lo diagnostique; como alternativa usar Ubuntu en máquina virtual |
| QEMU muy lento en WSL2 | Normal sin aceleración KVM; en Windows 11 activar virtualización anidada, o probar menos seguido |
| El USB no aparece en el menú de arranque | Probar otro puerto USB (mejor USB 2.0 o directo en la placa), revisar que el USB se escribió en modo DD |
| Pantalla negra al arrancar | Elegir en GRUB "Modo gráficos seguros" (existe desde la fase 3) |
| "Secure Boot violation" | Anotar el modelo de PC en la matriz y pasárselo a Claude Code; no desactivar Secure Boot en PCs con BitLocker |
| Windows pide clave de BitLocker | Volver a dejar la configuración de BIOS como estaba; la clave está en https://account.microsoft.com/devices/recoverykey |
| Claude Code da vueltas sin resolver | "Para. Resume qué intentaste y qué falló." Luego reducir la tarea a algo más pequeño |
| Se rompió algo que funcionaba | `git log` para ver el último commit bueno; pedir a Claude Code volver a ese estado |

---

## Enlaces útiles

- Claude Code: https://code.claude.com/docs/en/overview
- Buenas prácticas de Claude Code: https://code.claude.com/docs/en/best-practices
- Curso gratis Claude Code 101: https://academy.claude.com/courses/claude-code-101
- WSL: https://learn.microsoft.com/windows/wsl/install
- Tauri: https://tauri.app
- Svelte: https://svelte.dev
