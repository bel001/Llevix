<script>
  // Asistente del creador de Llevix: 1) sistema, 2) cuenta, 3) disco; luego progreso y final.
  import { onMount } from "svelte";
  import { fade } from "svelte/transition";
  import { invoke, listen, elegirArchivo, esSimulacion } from "./lib/puente.js";
  import Icono from "./lib/Icono.svelte";
  import {
    IDIOMAS, ZONAS, TECLADOS, ZONA_POR_IDIOMA, TECLADO_POR_IDIOMA, TECLAS_ARRANQUE,
    formatoBytes, sugerirUsuario,
  } from "./lib/datos.js";

  let paso = $state(1); // 1 sistema, 2 cuenta, 3 disco, 4 progreso, 5 final

  // Paso 1
  let manifest = $state(null);
  let errorManifest = $state("");
  let cargandoManifest = $state(true);
  let variante = $state(null);
  let filtro = $state("todas");
  // "Trae tu ISO": ruta e información de la ISO elegida por el usuario.
  let isoRuta = $state(null);
  let isoInfo = $state(null);
  let errorIso = $state("");
  let revisandoIso = $state(false);
  const catalogo = $derived((manifest?.variantes ?? []).filter((v) => (v.tipo ?? "escritorio") === "escritorio"));
  const visibles = $derived(filtro === "ligeras" ? catalogo.filter((v) => v.ligera) : catalogo);
  const instalador = $derived((manifest?.variantes ?? []).find((v) => v.tipo === "instalador"));
  const nombreElegido = $derived(isoInfo ? isoInfo.nombre : variante?.nombre);

  // Paso 2
  let nombreCompleto = $state("");
  let usuario = $state("");
  let usuarioTocado = $state(false);
  let contrasena = $state("");
  let contrasena2 = $state("");
  let verContrasena = $state(false);
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
  let pruebaCompleta = $state(false);
  let confirmando = $state(false);

  // Progreso
  let etapa = $state("");
  let hechos = $state(0);
  let total = $state(0);
  let errorFinal = $state("");
  let avisoDisco = $state("");
  let inicioEtapa = $state(0);

  const ETAPAS = {
    descarga: "Descargando la imagen",
    verificando_descarga: "Comprobando la descarga",
    preparando: "Preparando el disco",
    prueba_disco: "Probando el disco",
    prueba_completa: "Prueba completa del disco",
    escritura: "Escribiendo en el disco",
    verificacion: "Comprobando lo escrito",
    iso: "Guardando tu ISO en el disco",
    config: "Guardando tu cuenta",
  };
  const ordenEtapas = $derived(
    ["descarga", "verificando_descarga", "preparando", "prueba_disco", ...(pruebaCompleta ? ["prueba_completa"] : []), "escritura", "verificacion", ...(isoRuta ? ["iso"] : []), "config"],
  );
  const indiceEtapa = $derived(ordenEtapas.indexOf(etapa));

  const PASOS = [
    { n: 1, titulo: "Sistema", icono: "disco" },
    { n: 2, titulo: "Tu cuenta", icono: "usuario" },
    { n: 3, titulo: "Disco", icono: "usb" },
  ];

  const porcentaje = $derived(total > 0 ? Math.min(100, Math.floor((hechos / total) * 100)) : 0);
  // Tiempo que falta en la etapa actual (se estima con lo que lleva hecho).
  const restante = $derived.by(() => {
    if (total <= 1 || hechos <= 0 || hechos >= total) return "";
    const s = (Date.now() - inicioEtapa) / 1000;
    if (s < 15) return "";
    const r = (s * (total - hechos)) / hechos;
    if (r < 90) return "menos de 2 minutos";
    if (r < 3600) return `unos ${Math.round(r / 60)} minutos`;
    return `unas ${Math.floor(r / 3600)} h ${Math.round((r % 3600) / 60)} min`;
  });
  const contrasenasOk = $derived(contrasena.length >= 4 && contrasena === contrasena2);
  const usuarioOk = $derived(/^[a-z][a-z0-9_-]{0,31}$/.test(usuario));
  const fuerza = $derived.by(() => {
    let p = 0;
    if (contrasena.length >= 8) p++;
    if (contrasena.length >= 12) p++;
    if (/[A-Z]/.test(contrasena) && /[a-z]/.test(contrasena)) p++;
    if (/\d/.test(contrasena)) p++;
    if (/[^A-Za-z0-9]/.test(contrasena)) p++;
    return Math.min(4, p);
  });
  const NOMBRES_FUERZA = ["Muy débil", "Débil", "Aceptable", "Buena", "Excelente"];

  // Aspecto de cada distro: iniciales y color de su familia (sin logos de marcas).
  function aspecto(v) {
    const id = v.id;
    if (id.startsWith("kubuntu")) return { letra: "K", color: "#1d99f3" };
    if (id.startsWith("xubuntu")) return { letra: "X", color: "#2284f2" };
    if (id.startsWith("lubuntu")) return { letra: "L", color: "#0068c8" };
    if (id.startsWith("ubuntu")) return { letra: "U", color: "#e95420" };
    if (id.startsWith("mint")) return { letra: "M", color: "#69b53f" };
    if (id.startsWith("debian")) return { letra: "D", color: "#d70751" };
    if (id.startsWith("zorin")) return { letra: "Z", color: "#15a6f0" };
    return { letra: v.nombre.replace(/^Llevix, basado en /, "")[0] ?? "?", color: "#7c3aed" };
  }
  const titulo = (v) => v.nombre.replace(/^Llevix, basado en /, "");
  const escritorio = (v) => (v.descripcion?.includes(":") ? v.descripcion.split(":")[0] : "");
  const mayuscula = (t) => (t ? t[0].toUpperCase() + t.slice(1) : t);
  const detalle = (v) => mayuscula(v.descripcion?.includes(":") ? v.descripcion.split(":").slice(1).join(":").trim() : v.descripcion);

  onMount(() => {
    cargarManifest();
    const quitar = [];
    listen("llevix://progreso", (e) => {
      if (e.payload.etapa !== etapa) inicioEtapa = Date.now();
      etapa = e.payload.etapa;
      hechos = e.payload.hechos;
      total = e.payload.total;
    }).then((f) => quitar.push(f));
    listen("llevix://aviso", (e) => {
      avisoDisco = e.payload;
    }).then((f) => quitar.push(f));
    listen("llevix://fin", (e) => {
      if (e.payload.aviso) avisoDisco = e.payload.aviso;
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
    if (esSimulacion) await prepararCaptura();
  }

  // SOLO en la vista previa del navegador: ?captura=2..5 abre ese paso con datos de
  // ejemplo, para sacar las capturas del README sin hacer clic.
  async function prepararCaptura() {
    const n = Number(new URLSearchParams(location.search).get("captura"));
    if (!(n >= 1)) return;
    variante = catalogo.find((v) => v.id === "kubuntu-24.04") ?? catalogo[0];
    if (n === 1) return;
    nombreCompleto = "Ana Pérez";
    usuario = "ana";
    contrasena = contrasena2 = "Clave-Segura-2026";
    resumenCuenta = { usuario: "ana" };
    paso = 2;
    if (n === 2) return;
    contrasena = contrasena2 = "";
    discos = await invoke("listar_discos", { tamanoMinimo: variante.tamano_imagen });
    discoElegido = discos.aptos[0];
    pruebaCompleta = !!discoElegido?.sospechoso;
    entiendoBorrado = true;
    paso = 3;
    if (n === 3) return;
    etapa = "escritura";
    hechos = 2.87e9;
    total = 4.4e9;
    paso = n === 4 ? 4 : 5;
  }

  function elegirVariante(v) {
    variante = v;
    isoRuta = null;
    isoInfo = null;
    errorIso = "";
  }

  async function elegirIso() {
    errorIso = "";
    const ruta = await elegirArchivo({ multiple: false, directory: false, filters: [{ name: "Imagen ISO", extensions: ["iso"] }] });
    if (!ruta) return;
    revisandoIso = true;
    try {
      isoInfo = await invoke("analizar_iso", { ruta });
      isoRuta = ruta;
      variante = instalador;
    } catch (e) {
      isoInfo = null;
      isoRuta = null;
      variante = null;
      errorIso = String(e);
    } finally {
      revisandoIso = false;
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
    avisoDisco = "";
    etapa = "descarga";
    inicioEtapa = Date.now();
    hechos = 0;
    total = 0;
    paso = 4;
    try {
      await invoke("crear_usb", { variante, disco: discoElegido.numero, iso: isoRuta, pruebaCompleta });
    } catch (e) {
      errorFinal = String(e);
    }
  }

  async function cancelar() {
    await invoke("cancelar");
  }

  function reiniciar() {
    paso = 1;
    discoElegido = null;
    entiendoBorrado = false;
  }

  const nombreDisco = (d) => d.modelo || "Disco USB";
  const tieneDatos = (d) => d.volumenes.some((v) => v.usado > 0 || v.muestra.length > 0) || d.particiones > 0;
  const usado = (d) => d.volumenes.reduce((s, v) => s + (v.usado || 0), 0);
</script>

<div class="app">
  <header class="cabecera">
    <div class="marca">
      <div class="logo" aria-hidden="true">
        <svg viewBox="0 0 512 512" width="30" height="30">
          <rect x="176" y="24" width="160" height="120" rx="16" fill="currentColor" opacity=".45" />
          <rect x="96" y="128" width="320" height="360" rx="48" fill="currentColor" />
          <path d="M196 208 h48 v176 h96 v48 h-144 z" fill="var(--superficie)" />
        </svg>
      </div>
      <div>
        <h1>Llevix</h1>
        <p>Tu Linux portátil en una memoria USB o un disco externo</p>
      </div>
      {#if esSimulacion && !location.search.includes("captura")}<span class="simulacion">Vista previa (simulación)</span>{/if}
    </div>

    {#if paso <= 3}
      <ol class="pasos">
        {#each PASOS as p, i}
          <li class:activo={paso === p.n} class:hecho={paso > p.n}>
            <span class="punto">
              {#if paso > p.n}<Icono nombre="check" tam={16} />{:else}{p.n}{/if}
            </span>
            <span class="titulo-paso">{p.titulo}</span>
          </li>
          {#if i < PASOS.length - 1}<li class="linea" class:hecho={paso > p.n} aria-hidden="true"></li>{/if}
        {/each}
      </ol>
    {/if}
  </header>

  <main class="contenido">
    {#key paso}
      <div class="pantalla" in:fade={{ duration: 150 }}>
        {#if paso === 1}
          <div class="encabezado-paso">
            <div>
              <h2>Elige tu sistema</h2>
              <p class="nota">Cada opción trae su escritorio tal como lo entrega la distribución.</p>
            </div>
            <div class="filtros" role="group" aria-label="Filtrar">
              <button class="chip" class:activo={filtro === "todas"} onclick={() => (filtro = "todas")}>Todas</button>
              <button class="chip" class:activo={filtro === "ligeras"} onclick={() => (filtro = "ligeras")}>
                <Icono nombre="rayo" tam={14} /> Para PCs con poca RAM
              </button>
            </div>
          </div>

          {#if cargandoManifest}
            <div class="tarjetas">
              {#each Array(6) as _}<div class="tarjeta esqueleto"></div>{/each}
            </div>
          {:else if errorManifest}
            <div class="vacio">
              <Icono nombre="alerta" tam={32} />
              <p>No se pudo obtener la lista de versiones.</p>
              <p class="nota">{errorManifest}</p>
              <button class="boton" onclick={cargarManifest}><Icono nombre="refrescar" tam={16} /> Reintentar</button>
            </div>
          {:else}
            <div class="tarjetas">
              {#each visibles as v (v.id)}
                {@const a = aspecto(v)}
                <button class="tarjeta distro" class:elegida={!isoInfo && variante?.id === v.id} onclick={() => elegirVariante(v)} style="--tono: {a.color}">
                  <div class="fila">
                    <span class="monograma">{a.letra}</span>
                    <div class="nombres">
                      <small>Llevix, basado en</small>
                      <strong>{titulo(v)}</strong>
                    </div>
                    <span class="marca-elegida"><Icono nombre="check" tam={14} /></span>
                  </div>
                  <div class="chips">
                    {#if escritorio(v)}<span class="etiqueta">{escritorio(v)}</span>{/if}
                    {#if v.ligera}<span class="etiqueta verde"><Icono nombre="rayo" tam={12} /> Ligera</span>{/if}
                  </div>
                  <p class="descripcion">{detalle(v)}</p>
                  <div class="pie-tarjeta">
                    <span><Icono nombre="descargar" tam={14} /> {formatoBytes(v.tamano_comprimido)}</span>
                    <span><Icono nombre="usb" tam={14} /> desde {formatoBytes(v.tamano_imagen)}</span>
                  </div>
                </button>
              {/each}

              {#if instalador && filtro === "todas"}
                <button class="tarjeta iso" class:elegida={!!isoInfo} onclick={elegirIso} disabled={revisandoIso}>
                  <div class="fila">
                    <span class="monograma neutro">
                      {#if revisandoIso}<span class="girando"><Icono nombre="refrescar" tam={18} /></span>{:else}<Icono nombre="archivo" tam={20} />{/if}
                    </span>
                    <div class="nombres">
                      <small>¿Ya tienes una ISO?</small>
                      <strong>Usar mi propia ISO</strong>
                    </div>
                    <span class="marca-elegida"><Icono nombre="check" tam={14} /></span>
                  </div>
                  <p class="descripcion">
                    {#if revisandoIso}Revisando la ISO (si es una de las probadas, se comprueba entera)…{:else if isoInfo}<strong>{isoInfo.nombre}</strong> · {formatoBytes(isoInfo.tamano)}{:else}Ubuntu y sus sabores, Linux Mint, Zorin OS, elementary OS…{/if}
                  </p>
                  {#if isoInfo && !revisandoIso}
                    <div class="pie-tarjeta">
                      {#if isoInfo.nivel === "probada"}
                        <span class="etiqueta verde"><Icono nombre="check" tam={12} /> Probada por Llevix{isoInfo.probada_como ? ` (${isoInfo.probada_como})` : ""}</span>
                      {:else}
                        <span class="etiqueta aviso-tamano">Debería funcionar: {isoInfo.nombre_familia}, esta ISO aún sin probar</span>
                      {/if}
                    </div>
                  {/if}
                  <div class="pie-tarjeta"><span>Se instala en el primer arranque · máximo 8 GB</span></div>
                </button>
              {/if}
            </div>
            {#if errorIso}
              <div class="aviso peligro" in:fade><Icono nombre="alerta" /><span>{errorIso}</span></div>
            {/if}
            {#if instalador && filtro === "todas"}
              <details class="compatibles" open={!!errorIso}>
                <summary>¿Qué ISOs puedo usar con «Usar mi propia ISO»?</summary>
                <div class="compatibles-cuerpo">
                  <p><strong>Probadas:</strong> Ubuntu 24.04 o posterior, Kubuntu, Linux Mint 22 (Cinnamon, MATE y Xfce) y Zorin OS 18.</p>
                  <p><strong>Deberían funcionar</strong> (misma familia, aún sin probar): Xubuntu, Lubuntu, Ubuntu MATE, Ubuntu Budgie y elementary OS.</p>
                  <p><strong>Todavía no</strong> (Llevix las reconoce y te avisa antes de borrar nada): Debian, Fedora, Arch, Manjaro, EndeavourOS, Pop!_OS y openSUSE. Para Debian elige una del catálogo.</p>
                  <p>Al elegir tu ISO verás si es una de las que Llevix probó tal cual («Probada por Llevix») o si es de una familia conocida pero aún sin probar.</p>
                  <p class="nota">La ISO debe ser de 64 bits y pesar 8 GB o menos.</p>
                </div>
              </details>
            {/if}
          {/if}
        {:else if paso === 2}
          <div class="encabezado-paso">
            <div>
              <h2>Tu cuenta</h2>
              <p class="nota">Con estos datos entrarás a tu Llevix en cualquier PC.</p>
            </div>
          </div>

          <div class="bloques">
            <section class="bloque">
              <h3><Icono nombre="usuario" tam={18} /> Quién eres</h3>
              <label class="campo">
                <span>Tu nombre</span>
                <input value={nombreCompleto} oninput={(e) => cambiarNombre(e.target.value)} placeholder="Ana Pérez" maxlength="100" />
              </label>
              <label class="campo">
                <span>Nombre de usuario</span>
                <input bind:value={usuario} oninput={() => (usuarioTocado = true)} placeholder="ana" maxlength="32" autocapitalize="off" class:invalido={usuario && !usuarioOk} />
                {#if usuario && !usuarioOk}<small class="error">Solo minúsculas, números, - o _, y que empiece con una letra.</small>{/if}
              </label>
              <label class="campo">
                <span>Contraseña</span>
                <div class="con-boton">
                  <input type={verContrasena ? "text" : "password"} bind:value={contrasena} autocomplete="new-password" />
                  <button type="button" class="ver" onclick={() => (verContrasena = !verContrasena)} aria-label={verContrasena ? "Ocultar contraseña" : "Mostrar contraseña"}>
                    <Icono nombre={verContrasena ? "ojo-no" : "ojo"} tam={18} />
                  </button>
                </div>
                {#if contrasena}
                  <div class="fuerza" data-nivel={fuerza}>
                    <div class="segmentos">{#each Array(4) as _, i}<span class:lleno={i < Math.max(1, fuerza)}></span>{/each}</div>
                    <small>{contrasena.length < 4 ? "Usa al menos 4 caracteres" : NOMBRES_FUERZA[fuerza]}</small>
                  </div>
                {/if}
              </label>
              <label class="campo">
                <span>Repite la contraseña</span>
                <input type={verContrasena ? "text" : "password"} bind:value={contrasena2} autocomplete="new-password" class:invalido={contrasena2 && contrasena !== contrasena2} />
                {#if contrasena2 && contrasena !== contrasena2}<small class="error">Las contraseñas no coinciden.</small>{/if}
              </label>
            </section>

            <section class="bloque">
              <h3><Icono nombre="globo" tam={18} /> Idioma y región</h3>
              <label class="campo">
                <span>Idioma</span>
                <select value={idioma} onchange={(e) => cambiarIdioma(e.target.value)}>
                  {#each IDIOMAS as i}<option value={i.valor}>{i.texto}</option>{/each}
                </select>
              </label>
              <label class="campo">
                <span>Zona horaria</span>
                <select bind:value={zona}>
                  {#each ZONAS as z}<option value={z.valor}>{z.texto}</option>{/each}
                </select>
              </label>
              <label class="campo">
                <span>Teclado</span>
                <select bind:value={teclado}>
                  {#each TECLADOS as t}<option value={t.valor}>{t.texto}</option>{/each}
                </select>
              </label>
              <div class="seguro">
                <Icono nombre="candado" tam={18} />
                <p>Tu contraseña no se guarda: se convierte en una huella cifrada (SHA-512) y solo eso va al disco.</p>
              </div>
            </section>
          </div>
          {#if errorCuenta}<div class="aviso peligro" in:fade><Icono nombre="alerta" /><span>{errorCuenta}</span></div>{/if}
        {:else if paso === 3}
          <div class="encabezado-paso">
            <div>
              <h2>Elige el disco</h2>
              <p class="nota">Solo aparecen discos conectados por USB. Los discos internos de tu PC nunca se muestran.</p>
            </div>
            <button class="boton suave" onclick={buscarDiscos} disabled={cargandoDiscos}>
              <span class:girando={cargandoDiscos}><Icono nombre="refrescar" tam={16} /></span> Buscar de nuevo
            </button>
          </div>

          {#if cargandoDiscos}
            <div class="tarjetas discos">{#each Array(2) as _}<div class="tarjeta esqueleto bajo"></div>{/each}</div>
          {:else if errorDiscos}
            <div class="aviso peligro"><Icono nombre="alerta" /><span>{errorDiscos}</span></div>
          {:else if discos.aptos.length === 0}
            <div class="vacio">
              <Icono nombre="usb" tam={36} />
              <p>No se encontró ningún disco USB de al menos {formatoBytes(variante.tamano_imagen)}.</p>
              <p class="nota">Conecta una memoria o un disco externo y pulsa «Buscar de nuevo».</p>
            </div>
          {/if}

          {#if !cargandoDiscos}
            <div class="tarjetas discos">
              {#each discos.aptos as d (d.numero)}
                <button class="tarjeta disco" class:elegida={discoElegido?.numero === d.numero} onclick={() => { discoElegido = d; entiendoBorrado = false; pruebaCompleta = !!d.sospechoso; }}>
                  <div class="fila">
                    <span class="monograma neutro"><Icono nombre={d.extraible ? "usb" : "ssd"} tam={22} /></span>
                    <div class="nombres">
                      <small>{d.extraible ? "Memoria USB" : "Disco externo USB"}</small>
                      <strong>{nombreDisco(d)}</strong>
                    </div>
                    <span class="capacidad">{formatoBytes(d.tamano)}</span>
                    <span class="marca-elegida"><Icono nombre="check" tam={14} /></span>
                  </div>
                  {#if tieneDatos(d)}
                    <div class="uso"><span style="width: {Math.max(2, Math.min(100, (usado(d) / d.tamano) * 100))}%"></span></div>
                    <div class="pie-tarjeta">
                      {#each d.volumenes as v}<span>{v.letra} {v.etiqueta || "(sin nombre)"} · {formatoBytes(v.usado)} usados</span>{/each}
                      {#if d.volumenes.length === 0}<span>{d.particiones} partición(es) sin letra</span>{/if}
                    </div>
                  {:else}
                    <div class="pie-tarjeta"><span class="etiqueta verde">Vacío</span></div>
                  {/if}
                  {#if d.sospechoso}<div class="pie-tarjeta"><span class="etiqueta aviso-tamano">Tamaño sospechoso</span></div>{/if}
                </button>
              {/each}
            </div>
            {#each discos.chicos as d}
              <p class="nota chico"><Icono nombre="alerta" tam={14} /> {nombreDisco(d)} ({formatoBytes(d.tamano)}) es demasiado chico: se necesita al menos {formatoBytes(variante.tamano_imagen)}.</p>
            {/each}
          {/if}

          {#if discoElegido}
            <div class="confirmacion">
              {#if tieneDatos(discoElegido)}
                <div class="aviso">
                  <Icono nombre="alerta" />
                  <div>
                    <strong>Este disco tiene datos y se borrará todo lo que contiene.</strong>
                    {#each discoElegido.volumenes as v}
                      {#if v.muestra.length}<p>{v.letra} {v.etiqueta}: {v.muestra.join(", ")}{v.muestra.length >= 8 ? "…" : ""}</p>{/if}
                    {/each}
                  </div>
                </div>
              {/if}
              {#if discoElegido.sospechoso}
                <div class="aviso">
                  <Icono nombre="alerta" />
                  <div>
                    <strong>Este tamaño ({formatoBytes(discoElegido.tamano)}) es típico de las memorias falsas.</strong>
                    <p>Dicen tener más espacio del real y, al llenarse, dañan lo que tienen guardado. Te recomendamos la prueba completa antes de crear Llevix.</p>
                  </div>
                </div>
              {/if}
              <label class="casilla suave">
                <input type="checkbox" bind:checked={pruebaCompleta} />
                <span><strong>Prueba completa de la memoria.</strong> Escribe y lee todo el disco para descubrir memorias falsas, como H2testw. Puede tardar varias horas en memorias grandes o lentas; si la memoria es falsa, se detiene apenas lo nota.</span>
              </label>
              <label class="casilla">
                <input type="checkbox" bind:checked={entiendoBorrado} />
                <span>Entiendo que se borrará todo el contenido de «{nombreDisco(discoElegido)}».</span>
              </label>
            </div>
          {/if}
        {:else if paso === 4}
          <div class="progreso">
            {#if errorFinal}
              <div class="circulo-estado error-circulo"><Icono nombre="x" tam={40} /></div>
              <h2>No se pudo terminar</h2>
              <p class="mensaje-error">{errorFinal}</p>
              <p class="nota">Si la descarga se cortó, al reintentar continúa donde quedó.</p>
            {:else}
              <div class="anillo">
                <svg viewBox="0 0 120 120">
                  <circle cx="60" cy="60" r="52" class="pista" />
                  <circle cx="60" cy="60" r="52" class="avance" style="stroke-dashoffset: {326.7 * (1 - porcentaje / 100)}" />
                </svg>
                <div class="cifra">
                  {#if total > 1}<strong>{porcentaje}%</strong>{:else}<span class="girando cifra-icono"><Icono nombre="refrescar" tam={34} /></span>{/if}
                  <small>{ETAPAS[etapa] ?? "Trabajando…"}</small>
                </div>
              </div>
              {#if total > 1}<p class="nota">{formatoBytes(hechos)} de {formatoBytes(total)}{#if etapa === "prueba_completa"} (escribir y leer todo){/if}{#if restante} · faltan {restante}{/if}</p>{/if}
              {#if etapa === "prueba_completa"}<p class="nota">Se escribe y se lee toda la memoria para comprobar que guarda lo que dice. Puedes cancelar cuando quieras.</p>{/if}
              <ol class="lista-etapas">
                {#each ordenEtapas as e, i}
                  <li class:hecha={i < indiceEtapa} class:actual={i === indiceEtapa}>
                    <span class="punto">{#if i < indiceEtapa}<Icono nombre="check" tam={12} />{/if}</span>{ETAPAS[e]}
                  </li>
                {/each}
              </ol>
              {#if avisoDisco}<div class="aviso" in:fade><Icono nombre="alerta" /><span>{avisoDisco}</span></div>{/if}
              <p class="nota"><Icono nombre="alerta" tam={14} /> No desconectes el disco hasta que termine.</p>
            {/if}
          </div>
        {:else if paso === 5}
          <div class="final">
            <div class="circulo-estado ok-circulo"><Icono nombre="check" tam={44} /></div>
            <h2>¡Tu Llevix está listo!</h2>
            <p>Está en <strong>{nombreDisco(discoElegido)}</strong>. Ya puedes desconectarlo.</p>
            {#if avisoDisco}
              <div class="aviso"><Icono nombre="alerta" /><span>{avisoDisco}</span></div>
            {/if}
            {#if isoInfo}
              <div class="aviso info">
                <Icono nombre="reloj" />
                <span>La primera vez que arranques, Llevix instalará <strong>{isoInfo.nombre}</strong>. Tarda entre 5 y 15 minutos y la PC se reinicia sola. No la apagues mientras tanto.</span>
              </div>
            {/if}

            <div class="pasos-arranque">
              <div><span>1</span><p>Conecta el disco y enciende (o reinicia) la PC.</p></div>
              <div><span>2</span><p>Pulsa varias veces la tecla del <strong>menú de arranque</strong>.</p></div>
              <div><span>3</span><p>Elige el disco USB y pulsa Enter.</p></div>
              <div><span>4</span><p>Entra con <strong>{resumenCuenta?.usuario}</strong> y tu contraseña.</p></div>
            </div>

            <h3>Tecla del menú de arranque</h3>
            <div class="teclas">
              {#each TECLAS_ARRANQUE as t}<div class="tecla"><small>{t.marca}</small><kbd>{t.tecla}</kbd></div>{/each}
            </div>

            <div class="aviso">
              <Icono nombre="escudo" />
              <span><strong>No desactives el Arranque seguro (Secure Boot).</strong> Llevix funciona con él activado; si lo desactivas, Windows puede pedirte la clave de recuperación de BitLocker.</span>
            </div>
            <p class="nota">Si la tecla no funciona: Configuración → Sistema → Recuperación → Inicio avanzado → Reiniciar ahora → Usar un dispositivo. Si la pantalla queda negra, elige «modo gráficos seguros» en el menú de Llevix.</p>
          </div>
        {/if}
      </div>
    {/key}
  </main>

  <footer class="barra-acciones">
    {#if paso === 1}
      <span class="resumen">{#if nombreElegido}<Icono nombre="check" tam={16} /> {nombreElegido.replace(/^Llevix, basado en /, "")}{/if}</span>
      <button class="boton principal" disabled={!variante || revisandoIso} onclick={() => (paso = 2)}>Siguiente <Icono nombre="flecha-der" tam={18} /></button>
    {:else if paso === 2}
      <button class="boton suave" onclick={() => (paso = 1)}><Icono nombre="flecha-izq" tam={18} /> Atrás</button>
      <button class="boton principal" disabled={!usuarioOk || !contrasenasOk} onclick={confirmarCuenta}>Siguiente <Icono nombre="flecha-der" tam={18} /></button>
    {:else if paso === 3}
      <button class="boton suave" onclick={() => (paso = 2)}><Icono nombre="flecha-izq" tam={18} /> Atrás</button>
      <button class="boton peligro" disabled={!discoElegido || !entiendoBorrado} onclick={() => (confirmando = true)}><Icono nombre="escribir" tam={18} /> Crear Llevix</button>
    {:else if paso === 4}
      {#if errorFinal}
        <button class="boton suave" onclick={() => (paso = 3)}><Icono nombre="flecha-izq" tam={18} /> Volver</button>
        <button class="boton principal" onclick={empezar}><Icono nombre="refrescar" tam={18} /> Reintentar</button>
      {:else}
        <span></span>
        <button class="boton suave" onclick={cancelar}>Cancelar</button>
      {/if}
    {:else}
      <span></span>
      <button class="boton principal" onclick={reiniciar}><Icono nombre="mas" tam={18} /> Crear otro</button>
    {/if}
  </footer>

  {#if confirmando}
    <div class="modal" transition:fade={{ duration: 150 }}>
      <div class="caja">
        <div class="circulo-estado peligro-circulo"><Icono nombre="alerta" tam={30} /></div>
        <h3>¿Borrar el disco y crear Llevix?</h3>
        <p>Se borrará todo el contenido de <strong>{nombreDisco(discoElegido)}</strong> ({formatoBytes(discoElegido.tamano)}) y se instalará <strong>{nombreElegido}</strong>. Esto no se puede deshacer.</p>
        {#if pruebaCompleta}<p>Antes se hará la prueba completa de la memoria (puede tardar horas).</p>{/if}
        <div class="acciones">
          <button class="boton suave" onclick={() => (confirmando = false)}>No, volver</button>
          <button class="boton peligro" onclick={empezar}>Sí, borrar y crear</button>
        </div>
      </div>
    </div>
  {/if}
</div>
