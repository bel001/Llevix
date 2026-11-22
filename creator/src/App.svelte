<script>
  // Asistente del creador de Llevix: 1) distro, 2) cuenta, 3) destino; luego progreso y final.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { onMount } from "svelte";
  import {
    IDIOMAS, ZONAS, TECLADOS, ZONA_POR_IDIOMA, TECLADO_POR_IDIOMA, TECLAS_ARRANQUE,
    formatoBytes, sugerirUsuario,
  } from "./lib/datos.js";

  let paso = $state(1); // 1 distro, 2 cuenta, 3 destino, 4 progreso, 5 final

  // Paso 1
  let manifest = $state(null);
  let errorManifest = $state("");
  let cargandoManifest = $state(true);
  let variante = $state(null);

  // Paso 2
  let nombreCompleto = $state("");
  let usuario = $state("");
  let usuarioTocado = $state(false);
  let contrasena = $state("");
  let contrasena2 = $state("");
  let idioma = $state("es_ES.UTF-8");
  let zona = $state("Europe/Madrid");
  let teclado = $state("es");
  let errorCuenta = $state("");
  let resumenCuenta = $state(null);

  // Paso 3
  let discos = $state({ aptos: [], chicos: [] });
  let cargandoDiscos = $state(false);
  let errorDiscos = $state("");
  let discoElegido = $state(null);
  let entiendoBorrado = $state(false);
  let confirmando = $state(false);

  // Progreso
  let etapa = $state("");
  let hechos = $state(0);
  let total = $state(0);
  let errorFinal = $state("");

  const ETAPAS = {
    descarga: "Descargando la imagen",
    verificando_descarga: "Comprobando la descarga (SHA256)",
    preparando: "Preparando el disco",
    escritura: "Escribiendo en el disco",
    verificacion: "Comprobando lo escrito",
    config: "Guardando tu cuenta en el disco",
  };

  const porcentaje = $derived(total > 0 ? Math.min(100, Math.floor((hechos / total) * 100)) : 0);
  const contrasenasOk = $derived(contrasena.length >= 4 && contrasena === contrasena2);
  const usuarioOk = $derived(/^[a-z][a-z0-9_-]{0,31}$/.test(usuario));

  onMount(() => {
    cargarManifest();
    const quitar = [];
    listen("llevix://progreso", (e) => {
      etapa = e.payload.etapa;
      hechos = e.payload.hechos;
      total = e.payload.total;
    }).then((f) => quitar.push(f));
    listen("llevix://fin", (e) => {
      if (e.payload.ok) {
        paso = 5;
      } else {
        errorFinal = e.payload.mensaje;
      }
    }).then((f) => quitar.push(f));
    return () => quitar.forEach((f) => f());
  });

  async function cargarManifest() {
    cargandoManifest = true;
    errorManifest = "";
    try {
      manifest = await invoke("obtener_manifest");
    } catch (e) {
      errorManifest = String(e);
    } finally {
      cargandoManifest = false;
    }
  }

  function cambiarNombre(v) {
    nombreCompleto = v;
    if (!usuarioTocado) usuario = sugerirUsuario(v);
  }

  function cambiarIdioma(v) {
    idioma = v;
    if (ZONA_POR_IDIOMA[v]) zona = ZONA_POR_IDIOMA[v];
    teclado = TECLADO_POR_IDIOMA[v] || "latam";
  }

  async function confirmarCuenta() {
    errorCuenta = "";
    try {
      // El hash SHA-512 se calcula en Rust; aquí se olvida la contraseña enseguida.
      resumenCuenta = await invoke("preparar_cuenta", {
        datos: {
          usuario, nombre_completo: nombreCompleto.trim(), contrasena,
          idioma, zona_horaria: zona, teclado, variante_teclado: "", hostname: "",
        },
      });
      contrasena = "";
      contrasena2 = "";
      paso = 3;
      buscarDiscos();
    } catch (e) {
      errorCuenta = String(e);
    }
  }

  async function buscarDiscos() {
    cargandoDiscos = true;
    errorDiscos = "";
    discoElegido = null;
    entiendoBorrado = false;
    try {
      discos = await invoke("listar_discos", { tamanoMinimo: variante.tamano_imagen });
    } catch (e) {
      errorDiscos = String(e);
    } finally {
      cargandoDiscos = false;
    }
  }

  async function empezar() {
    confirmando = false;
    errorFinal = "";
    etapa = "descarga";
    hechos = 0;
    total = 0;
    paso = 4;
    try {
      await invoke("crear_usb", { variante, disco: discoElegido.numero });
    } catch (e) {
      errorFinal = String(e);
    }
  }

  async function cancelar() {
    await invoke("cancelar");
  }

  function nombreDisco(d) {
    return `${d.modelo || "Disco USB"} — ${formatoBytes(d.tamano)}`;
  }
</script>

<main>
  <header>
    <h1>Creador de Llevix</h1>
    <p class="sub">Tu Linux portátil en una memoria USB o un disco externo</p>
    {#if paso <= 3}
      <ol class="pasos">
        <li class:activo={paso === 1} class:hecho={paso > 1}>1. Sistema</li>
        <li class:activo={paso === 2} class:hecho={paso > 2}>2. Tu cuenta</li>
        <li class:activo={paso === 3}>3. Disco</li>
      </ol>
    {/if}
  </header>

  {#if paso === 1}
    <section>
      <h2>Elige el sistema</h2>
      {#if cargandoManifest}
        <p>Buscando la última versión de Llevix…</p>
      {:else if errorManifest}
        <p class="error">No se pudo obtener la lista de versiones: {errorManifest}</p>
        <button onclick={cargarManifest}>Reintentar</button>
      {:else}
        <p class="nota">Versión {manifest.version}. Cada opción trae su escritorio tal como lo hace la distribución.</p>
        <div class="tarjetas">
          {#each manifest.variantes as v (v.id)}
            <button class="tarjeta" class:elegida={variante?.id === v.id} onclick={() => (variante = v)}>
              <strong>{v.nombre}</strong>
              {#if v.ligera}<span class="etiqueta">Ligera</span>{/if}
              <span>{v.descripcion}</span>
              <small>Descarga: {formatoBytes(v.tamano_comprimido)} · Disco mínimo: {formatoBytes(v.tamano_imagen)}</small>
            </button>
          {/each}
        </div>
        <div class="acciones">
          <button class="principal" disabled={!variante} onclick={() => (paso = 2)}>Siguiente</button>
        </div>
      {/if}
    </section>
  {:else if paso === 2}
    <section>
      <h2>Tu cuenta</h2>
      <div class="formulario">
        <label>Tu nombre
          <input value={nombreCompleto} oninput={(e) => cambiarNombre(e.target.value)} placeholder="Ana Pérez" maxlength="100" />
        </label>
        <label>Nombre de usuario
          <input bind:value={usuario} oninput={() => (usuarioTocado = true)} placeholder="ana" maxlength="32" autocapitalize="off" />
          {#if usuario && !usuarioOk}<small class="error">Solo minúsculas, números, - o _, y que empiece con una letra.</small>{/if}
        </label>
        <label>Contraseña
          <input type="password" bind:value={contrasena} autocomplete="new-password" />
        </label>
        <label>Repite la contraseña
          <input type="password" bind:value={contrasena2} autocomplete="new-password" />
          {#if contrasena2 && contrasena !== contrasena2}<small class="error">Las contraseñas no coinciden.</small>{/if}
          {#if contrasena && contrasena.length < 4}<small class="error">Usa al menos 4 caracteres.</small>{/if}
        </label>
        <label>Idioma
          <select value={idioma} onchange={(e) => cambiarIdioma(e.target.value)}>
            {#each IDIOMAS as i}<option value={i.valor}>{i.texto}</option>{/each}
          </select>
        </label>
        <label>Zona horaria
          <select bind:value={zona}>
            {#each ZONAS as z}<option value={z.valor}>{z.texto}</option>{/each}
          </select>
        </label>
        <label>Teclado
          <select bind:value={teclado}>
            {#each TECLADOS as t}<option value={t.valor}>{t.texto}</option>{/each}
          </select>
        </label>
      </div>
      <p class="nota">Tu contraseña no se guarda: se convierte en una huella cifrada (SHA-512) y solo eso va al disco.</p>
      {#if errorCuenta}<p class="error">{errorCuenta}</p>{/if}
      <div class="acciones">
        <button onclick={() => (paso = 1)}>Atrás</button>
        <button class="principal" disabled={!usuarioOk || !contrasenasOk} onclick={confirmarCuenta}>Siguiente</button>
      </div>
    </section>
  {:else if paso === 3}
    <section>
      <h2>Elige el disco</h2>
      <p class="nota">Solo se muestran discos conectados por USB. Los discos internos de tu PC nunca aparecen aquí.</p>
      {#if cargandoDiscos}
        <p>Buscando discos USB…</p>
      {:else if errorDiscos}
        <p class="error">{errorDiscos}</p>
      {:else if discos.aptos.length === 0}
        <p>No se encontró ningún disco USB de al menos {formatoBytes(variante.tamano_imagen)}.
          Conecta una memoria o un disco externo y pulsa «Buscar de nuevo».</p>
      {/if}
      <div class="tarjetas">
        {#each discos.aptos as d (d.numero)}
          <button class="tarjeta" class:elegida={discoElegido?.numero === d.numero}
            onclick={() => { discoElegido = d; entiendoBorrado = false; }}>
            <strong>{nombreDisco(d)}</strong>
            {#if d.volumenes.length === 0 && d.particiones === 0}
              <span>Vacío</span>
            {:else}
              {#each d.volumenes as v}
                <span>{v.letra} {v.etiqueta || "(sin nombre)"} · {v.sistema_archivos} · {formatoBytes(v.usado)} usados</span>
              {/each}
              {#if d.volumenes.length === 0}<span>{d.particiones} partición(es) sin letra</span>{/if}
            {/if}
          </button>
        {/each}
      </div>
      {#each discos.chicos as d}
        <p class="nota">{nombreDisco(d)}: no sirve (necesita al menos {formatoBytes(variante.tamano_imagen)}).</p>
      {/each}

      {#if discoElegido && discoElegido.volumenes.some((v) => v.usado > 0 || v.muestra.length > 0)}
        <div class="aviso">
          <strong>Este disco tiene datos. Se borrará TODO lo que contiene:</strong>
          {#each discoElegido.volumenes as v}
            <p>{v.letra} {v.etiqueta}: {v.muestra.join(", ")}{v.muestra.length >= 8 ? "…" : ""}</p>
          {/each}
        </div>
      {/if}
      {#if discoElegido}
        <label class="casilla">
          <input type="checkbox" bind:checked={entiendoBorrado} />
          Entiendo que se borrará todo el contenido de «{nombreDisco(discoElegido)}».
        </label>
      {/if}

      <div class="acciones">
        <button onclick={() => (paso = 2)}>Atrás</button>
        <button onclick={buscarDiscos}>Buscar de nuevo</button>
        <button class="principal peligro" disabled={!discoElegido || !entiendoBorrado} onclick={() => (confirmando = true)}>
          Crear Llevix
        </button>
      </div>
    </section>

    {#if confirmando}
      <div class="modal">
        <div class="caja">
          <h3>¿Seguro?</h3>
          <p>Se borrará todo el contenido de <strong>{nombreDisco(discoElegido)}</strong> y se instalará
            {variante.nombre}. Esto no se puede deshacer.</p>
          <div class="acciones">
            <button onclick={() => (confirmando = false)}>No, volver</button>
            <button class="principal peligro" onclick={empezar}>Sí, borrar y crear</button>
          </div>
        </div>
      </div>
    {/if}
  {:else if paso === 4}
    <section>
      <h2>Creando tu Llevix</h2>
      {#if errorFinal}
        <p class="error">{errorFinal}</p>
        <p class="nota">Si la descarga se cortó, al reintentar continúa donde quedó.</p>
        <div class="acciones">
          <button onclick={() => (paso = 3)}>Volver</button>
          <button class="principal" onclick={empezar}>Reintentar</button>
        </div>
      {:else}
        <p>{ETAPAS[etapa] || "Trabajando…"}</p>
        <div class="barra"><div style="width: {porcentaje}%"></div></div>
        <p class="nota">{porcentaje}% {total > 0 ? `(${formatoBytes(hechos)} de ${formatoBytes(total)})` : ""}</p>
        <p class="nota">No desconectes el disco hasta que termine.</p>
        <div class="acciones">
          <button onclick={cancelar}>Cancelar</button>
        </div>
      {/if}
    </section>
  {:else if paso === 5}
    <section>
      <h2>¡Listo!</h2>
      <p>Tu Llevix está en <strong>{nombreDisco(discoElegido)}</strong>. Ya puedes desconectarlo.</p>
      <h3>Cómo arrancar desde el USB</h3>
      <ol>
        <li>Conecta el disco y enciende (o reinicia) la PC.</li>
        <li>Pulsa varias veces la tecla del <strong>menú de arranque</strong> según la marca.</li>
        <li>Elige el disco USB en la lista. En el menú de Llevix pulsa Enter.</li>
        <li>Entra con tu usuario <strong>{resumenCuenta?.usuario}</strong> y tu contraseña.</li>
      </ol>
      <table>
        <thead><tr><th>Marca</th><th>Tecla</th></tr></thead>
        <tbody>
          {#each TECLAS_ARRANQUE as t}<tr><td>{t.marca}</td><td>{t.tecla}</td></tr>{/each}
        </tbody>
      </table>
      <div class="aviso">
        <strong>No desactives el Arranque seguro (Secure Boot).</strong>
        Llevix funciona con él activado. Si lo desactivas, Windows puede pedirte la clave de
        recuperación de BitLocker. Usa siempre el menú de arranque de una sola vez.
      </div>
      <p class="nota">Si la tecla no funciona, en Windows: Configuración → Sistema → Recuperación →
        Inicio avanzado → Reiniciar ahora → Usar un dispositivo → elige el USB.</p>
      <p class="nota">Si la pantalla queda negra, elige «Llevix (modo gráficos seguros)» en el menú.</p>
      <div class="acciones">
        <button class="principal" onclick={() => { paso = 1; discoElegido = null; }}>Crear otro</button>
      </div>
    </section>
  {/if}
</main>
