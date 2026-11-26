//! App de escritorio del creador de Llevix (Tauri 2).
//!
//! La interfaz (Svelte) llama a estos comandos:
//! - `obtener_manifest`: lista de variantes de la última versión publicada.
//! - `preparar_cuenta`: valida la cuenta y calcula el hash de la contraseña.
//! - `listar_discos`: discos USB aptos (nunca internos ni del sistema).
//! - `analizar_iso`: revisa si una ISO elegida por el usuario es compatible ("Trae tu ISO").
//! - `crear_usb`: descarga, escribe, verifica, deja la ISO del usuario (si eligió una) y
//!   llevix-config.json en la ESP.
//! - `cancelar`.
//! El progreso se informa con los eventos `llevix://progreso` y `llevix://fin`.

use llevix_nucleo::config::{ConfigLlevix, DatosCuenta};
use llevix_nucleo::disco::Disco;
use llevix_nucleo::manifest::{Manifest, Variante};
use llevix_nucleo::Error;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Default)]
struct Estado {
    cancelar: Arc<AtomicBool>,
    ocupado: Arc<AtomicBool>,
    config: Mutex<Option<ConfigLlevix>>,
}

#[derive(Clone, Serialize)]
struct Progreso {
    etapa: &'static str,
    hechos: u64,
    total: u64,
}

#[derive(Clone, Serialize)]
struct Fin {
    ok: bool,
    mensaje: String,
    /// Aviso para la pantalla final (por ejemplo, que el disco es muy lento).
    aviso: Option<String>,
}

#[derive(Serialize)]
struct ResumenCuenta {
    usuario: String,
    hostname: String,
}

#[derive(Serialize)]
struct ListaDiscos {
    aptos: Vec<Disco>,
    chicos: Vec<Disco>,
}

#[tauri::command]
async fn obtener_manifest() -> Result<Manifest, String> {
    tauri::async_runtime::spawn_blocking(llevix_nucleo::manifest::buscar_ultimo)
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn analizar_iso(ruta: String) -> Result<llevix_nucleo::iso::InfoIso, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let nombre = std::path::Path::new(&ruta)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let mut f = std::fs::File::open(&ruta).map_err(|e| format!("No se pudo abrir la ISO: {e}"))?;
        llevix_nucleo::iso::analizar(&mut f, &nombre, true).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn preparar_cuenta(datos: DatosCuenta, estado: State<'_, Estado>) -> Result<ResumenCuenta, String> {
    // Aquí se calcula el hash: la contraseña en texto no sale de esta función.
    let config = ConfigLlevix::desde_datos(datos).map_err(|e| e.to_string())?;
    let resumen = ResumenCuenta { usuario: config.usuario.nombre.clone(), hostname: config.hostname.clone() };
    *estado.config.lock().unwrap() = Some(config);
    Ok(resumen)
}

#[tauri::command]
async fn listar_discos(tamano_minimo: u64) -> Result<ListaDiscos, String> {
    #[cfg(windows)]
    {
        let discos = tauri::async_runtime::spawn_blocking(llevix_nucleo::windows::enumerar_discos)
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())?;
        let (aptos, chicos) = llevix_nucleo::disco::clasificar(discos, tamano_minimo);
        Ok(ListaDiscos { aptos, chicos })
    }
    #[cfg(not(windows))]
    {
        let _ = tamano_minimo;
        Err("El creador de Llevix solo escribe discos en Windows.".into())
    }
}

#[tauri::command]
fn cancelar(estado: State<'_, Estado>) {
    estado.cancelar.store(true, Ordering::Relaxed);
}

#[tauri::command]
fn crear_usb(
    app: AppHandle,
    variante: Variante,
    disco: u32,
    iso: Option<String>,
    prueba_completa: bool,
    estado: State<'_, Estado>,
) -> Result<(), String> {
    let config = estado
        .config
        .lock()
        .unwrap()
        .clone()
        .ok_or("Primero completa los datos de tu cuenta.")?;
    if estado.ocupado.swap(true, Ordering::SeqCst) {
        return Err("Ya se está creando un disco.".into());
    }
    estado.cancelar.store(false, Ordering::Relaxed);
    let cancelar = estado.cancelar.clone();
    let ocupado = estado.ocupado.clone();
    let cache = app
        .path()
        .app_local_data_dir()
        .map_err(|e| e.to_string())?
        .join("descargas");

    std::thread::spawn(move || {
        let iso = iso.map(std::path::PathBuf::from);
        let resultado = proceso(&app, &variante, disco, iso.as_deref(), prueba_completa, &config, &cache, &cancelar);
        ocupado.store(false, Ordering::SeqCst);
        let fin = match resultado {
            Ok(aviso) => Fin { ok: true, mensaje: "Listo".into(), aviso },
            Err(e) => Fin { ok: false, mensaje: e.to_string(), aviso: None },
        };
        let _ = app.emit("llevix://fin", fin);
    });
    Ok(())
}

fn avisar(app: &AppHandle, etapa: &'static str, hechos: u64, total: u64) {
    let _ = app.emit("llevix://progreso", Progreso { etapa, hechos, total });
}

/// Todo el proceso, en orden. Cualquier error lo detiene. Devuelve un aviso opcional
/// para la pantalla final.
#[allow(clippy::too_many_arguments)]
fn proceso(
    app: &AppHandle,
    variante: &Variante,
    disco: u32,
    iso: Option<&std::path::Path>,
    prueba_completa: bool,
    config: &ConfigLlevix,
    cache: &std::path::Path,
    cancelar: &AtomicBool,
) -> Result<Option<String>, Error> {
    use llevix_nucleo::{bmap::Bmap, descarga};

    // "Trae tu ISO": se revisa la ISO antes de descargar o borrar nada.
    if let Some(ruta) = iso {
        if variante.tipo != "instalador" {
            return Err(Error::Config("para usar una ISO propia se necesita la imagen del instalador".into()));
        }
        let nombre = ruta.file_name().unwrap_or_default().to_string_lossy().to_string();
        llevix_nucleo::iso::analizar(&mut std::fs::File::open(ruta)?, &nombre, false)?;
    }

    // 1. Descargar (o continuar) y verificar la imagen.
    let rutas = descarga::descargar_imagen(cache, &variante.id, &variante.partes, &variante.sha256, cancelar, &mut |p| {
        avisar(app, if p.verificando { "verificando_descarga" } else { "descarga" }, p.hechos, p.total)
    })?;

    // 2. Mapa de bloques, verificado.
    let texto_bmap = descarga::descargar_texto(&variante.bmap_url)?;
    let suma = descarga::sha256_hex(texto_bmap.as_bytes());
    if suma != variante.bmap_sha256.to_ascii_lowercase() {
        return Err(Error::Integridad("el mapa de bloques (.bmap) no coincide con su SHA256".into()));
    }
    Bmap::verificar_archivo(&texto_bmap)?;
    let bmap = Bmap::leer(&texto_bmap)?;
    if bmap.tamano_imagen != variante.tamano_imagen {
        return Err(Error::Integridad("el tamaño de la imagen no coincide con el mapa".into()));
    }

    escribir_en_disco(app, disco, &bmap, &rutas, iso, prueba_completa, config, cancelar)
}

#[cfg(windows)]
#[allow(clippy::too_many_arguments)]
fn escribir_en_disco(
    app: &AppHandle,
    disco: u32,
    bmap: &llevix_nucleo::bmap::Bmap,
    rutas: &[std::path::PathBuf],
    iso: Option<&std::path::Path>,
    prueba_completa: bool,
    config: &ConfigLlevix,
    cancelar: &AtomicBool,
) -> Result<Option<String>, Error> {
    use llevix_nucleo::crear::{self, IsoPropia, Paso};
    use llevix_nucleo::{descarga, prueba_disco};

    avisar(app, "preparando", 0, 0);
    // Vuelve a comprobar que el disco es USB, no es del sistema y alcanza el tamaño.
    // Bloquea y desmonta sus volúmenes y borra la tabla de particiones vieja.
    let mut destino = llevix_nucleo::windows::abrir_para_escribir(disco, bmap.tamano_imagen)?;
    destino.borrar_tablas()?;

    // Memorias falsas (menos capacidad de la que dicen) y muy lentas: ver prueba_disco.
    let tamano = destino.tamano;
    let prueba = prueba_disco::probar(&mut destino, tamano, cancelar, &mut |h, t| avisar(app, "prueba_disco", h, t))?;
    let aviso = prueba.aviso();
    if let Some(a) = &aviso {
        let _ = app.emit("llevix://aviso", a.clone());
    }
    // Prueba completa (opcional, la elige el usuario): detecta las memorias falsas que
    // la prueba rápida no ve. Escribe y lee todo el disco: puede tardar horas.
    if prueba_completa {
        prueba_disco::probar_completo(&mut destino, tamano, cancelar, &mut |h, t| avisar(app, "prueba_completa", h, t))?;
    }

    let nombre_iso = iso.map(|r| r.file_name().unwrap_or_default().to_string_lossy().to_string());
    let mut archivo_iso = match iso {
        Some(r) => Some(std::fs::File::open(r)?),
        None => None,
    };
    let iso_propia = match (archivo_iso.as_mut(), nombre_iso.as_deref()) {
        (Some(archivo), Some(nombre)) => Some(IsoPropia { archivo, nombre }),
        _ => None,
    };

    // Imagen (verificada), ISO propia y llevix-config.json; la tabla de particiones va
    // al final (ver llevix_nucleo::crear) para que Windows no monte nada a mitad de camino.
    let imagen = descarga::abrir_imagen(rutas)?;
    crear::escribir_todo(imagen, bmap, &mut destino, iso_propia, &config.a_json(), cancelar, &mut |paso, h, t| {
        let etapa = match paso {
            Paso::Escritura => "escritura",
            Paso::Verificacion => "verificacion",
            Paso::Iso => "iso",
            Paso::Config => "config",
        };
        avisar(app, etapa, h, t)
    })?;
    destino.actualizar_windows();
    Ok(aviso)
}

#[cfg(not(windows))]
#[allow(clippy::too_many_arguments)]
fn escribir_en_disco(
    _app: &AppHandle,
    _disco: u32,
    _bmap: &llevix_nucleo::bmap::Bmap,
    _rutas: &[std::path::PathBuf],
    _iso: Option<&std::path::Path>,
    _prueba_completa: bool,
    _config: &ConfigLlevix,
    _cancelar: &AtomicBool,
) -> Result<Option<String>, Error> {
    Err(Error::DiscoNoPermitido("el creador solo escribe discos en Windows".into()))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Estado::default())
        .invoke_handler(tauri::generate_handler![
            obtener_manifest,
            analizar_iso,
            preparar_cuenta,
            listar_discos,
            crear_usb,
            cancelar
        ])
        .run(tauri::generate_context!())
        .expect("no se pudo iniciar el creador de Llevix");
}
