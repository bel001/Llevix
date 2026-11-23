//! Herramienta de pruebas: hace lo mismo que el creador, pero sobre un ARCHIVO de imagen
//! (un disco simulado), nunca sobre un disco real.
//!
//! Uso:
//!   cargo run --release --example escribir_en_archivo -- \
//!       <variante> <destino.img> <tamaño-en-GiB> <llevix-config.json> <carpeta-cache>
//!
//! Busca la última versión publicada, descarga (o reanuda) la imagen, verifica las
//! sumas, crea el archivo destino del tamaño indicado (disperso), escribe solo los
//! bloques del .bmap, verifica lo escrito y deja llevix-config.json en la ESP.

use llevix_nucleo::{bmap::Bmap, crear, descarga, manifest};
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;

fn main() {
    if let Err(e) = ejecutar() {
        eprintln!("ERROR: {e}");
        std::process::exit(1);
    }
}

fn ejecutar() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [variante, destino, gib, config, cache] = args.as_slice() else {
        return Err("uso: escribir_en_archivo <variante> <destino.img> <GiB> <config.json> <cache>".into());
    };
    let destino = PathBuf::from(destino);
    if destino.starts_with("/dev") || destino.to_string_lossy().starts_with(r"\\.\") {
        return Err("esta herramienta solo escribe en archivos, nunca en dispositivos".into());
    }
    let tamano: u64 = gib.parse::<u64>()? * 1024 * 1024 * 1024;
    let cancelar = AtomicBool::new(false);

    let m = manifest::buscar_ultimo()?;
    println!("Versión {}", m.version);
    let v = m
        .variantes
        .iter()
        .find(|x| &x.id == variante)
        .ok_or_else(|| format!("no existe la variante {variante}"))?;
    if tamano < v.tamano_imagen {
        return Err(format!("el destino debe tener al menos {} bytes", v.tamano_imagen).into());
    }

    let mut ultimo = 0u64;
    let rutas = descarga::descargar_imagen(cache.as_ref(), &v.id, &v.partes, &v.sha256, &cancelar, &mut |p| {
        let pct = if p.total > 0 { p.hechos * 100 / p.total } else { 0 };
        if pct >= ultimo + 10 || (p.hechos == p.total && pct != ultimo) {
            ultimo = pct;
            println!("{} {pct}%", if p.verificando { "verificando descarga" } else { "descargando" });
        }
    })?;

    let texto = descarga::descargar_texto(&v.bmap_url)?;
    if descarga::sha256_hex(texto.as_bytes()) != v.bmap_sha256 {
        return Err("el .bmap no coincide con su SHA256".into());
    }
    Bmap::verificar_archivo(&texto)?;
    let bmap = Bmap::leer(&texto)?;

    let mut disco = OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&destino)?;
    disco.set_len(tamano)?;
    // Igual que el creador: primero se prueba el disco (memorias falsas o muy lentas).
    let prueba = llevix_nucleo::prueba_disco::probar(&mut disco, tamano, &cancelar, &mut |_, _| {})?;
    println!("Prueba del disco: {:.1} MB/s, {:.0} escrituras pequeñas por segundo", prueba.mb_s, prueba.iops);
    // El mismo proceso que el creador: la tabla de particiones se escribe al final.
    let json = std::fs::read(config)?;
    let mut ultimo = (crear::Paso::Escritura, 0u64);
    crear::escribir_todo(descarga::abrir_imagen(&rutas)?, &bmap, &mut disco, None, &json, &cancelar, &mut |paso, h, t| {
        let pct = h * 100 / t.max(1);
        if paso != ultimo.0 || pct >= ultimo.1 + 10 {
            ultimo = (paso, pct);
            println!("{paso:?} {pct}%");
        }
    })?;
    println!("Listo: {} ({} GiB) con llevix-config.json en la ESP", destino.display(), gib);
    Ok(())
}
