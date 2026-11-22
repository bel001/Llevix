# Guía para testers de la beta de Llevix

¡Gracias por ayudar! Llevix convierte una memoria USB o un disco externo en un Linux
portátil que arranca en cualquier PC y guarda tus archivos. Tu prueba nos dice en qué
computadoras funciona y qué hay que arreglar.

## Antes de empezar

- Usa una memoria o disco **sin datos importantes**: se borra todo.
- **Desconecta cualquier otro disco externo** mientras usas el creador.
- Necesitas una memoria de **32 GB o más** (mejor USB 3).
- **No desactives el Arranque seguro (Secure Boot).** Llevix funciona con él activado.
  Si lo desactivas, Windows puede pedir la clave de recuperación de BitLocker.

## 1. Crear el USB

1. Descarga **Llevix-Creador-…-setup.exe** de la [última versión](https://github.com/bel001/Llevix/releases).
2. Instálalo y ábrelo (Windows pedirá permiso de administrador: es para escribir el USB).
3. Elige el sistema, escribe tu usuario y contraseña, y elige el disco USB.
4. Espera a que termine (descarga ~3–4 GB la primera vez).

## 2. Arrancar

Conecta el USB, enciende la PC y pulsa la tecla del **menú de arranque de una sola vez**:

| Marca | Tecla |
| --- | --- |
| HP | Esc y luego F9 |
| Lenovo | F12 (o el botón Novo) |
| Dell | F12 |
| Asus | Esc (portátiles) o F8 (escritorio) |
| Acer | F12 |
| MSI | F11 |
| Toshiba | F12 |
| Samsung | Esc o F10 |

Si la pantalla queda negra, reinicia y elige **«Llevix (modo gráficos seguros)»**.

## 3. Qué probar (marca lo que puedas)

- [ ] Llega a la pantalla de inicio de sesión y entras con tu usuario.
- [ ] WiFi y cable de red.
- [ ] Sonido (parlantes y auriculares).
- [ ] Brillo de pantalla, segundo monitor.
- [ ] Teclado (ñ, tildes) y touchpad.
- [ ] Guardar un archivo en **Datos**, apagar, volver a arrancar y que siga ahí.
- [ ] Abrir la partición **LLEVIX** en Windows y, si puedes, en un celular Android con USB-C.
- [ ] Arrancar el mismo USB en **otra PC** y ver que tus archivos siguen ahí.
- [ ] Suspender y despertar.

## 4. Contarnos cómo fue

1. Dentro de Llevix, abre una terminal y ejecuta:
   ```bash
   sudo /usr/lib/llevix/report.sh
   ```
   Guarda un archivo `llevix-reporte-….txt` en tu carpeta **Datos**. Quita tus datos
   personales (usuario, nombre del equipo, direcciones de red, números de serie), pero
   revísalo antes de compartirlo.
2. Abre un issue en <https://github.com/bel001/Llevix/issues/new/choose>:
   - **✅ Funcionó en mi PC** — si todo anduvo bien (¡también sirve!).
   - **🛑 No arranca** — si no llega al escritorio.
   - **🔧 Algo no funciona** — si arranca pero algo falla.
3. Adjunta el reporte y, si hay un error en pantalla, una foto.

¡Gracias!
