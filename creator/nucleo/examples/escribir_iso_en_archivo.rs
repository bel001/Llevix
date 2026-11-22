//! Herramienta de pruebas de "Trae tu ISO": hace lo mismo que el creador, pero sobre un
//! ARCHIVO de imagen (disco simulado), nunca sobre un disco real.
//!
//! Uso:
//!   cargo run --release --example escribir_iso_en_archivo -- \
//!       <instalador.img.zst> <instalador.img.bmap> <distro.iso> <destino.img> <GiB> <llevix-config.json>
//!
//! 1. Revisa la ISO (iso::analizar). 2. Escribe la imagen del instalador según el bmap.
//! 3. Deja la ISO en la zona reservada (iso::escribir_iso). 4. Escribe el config en la ESP.

use llevix_nucleo::{bmap::Bmap, escritura, esp, iso};
use std::fs::{File, OpenOptions};
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
    let [zst, bmap, ruta_iso, destino, gib, config] = args.as_slice() else {
        return Err("uso: escribir_iso_en_archivo <img.zst> <img.bmap> <iso> <destino.img> <GiB> <config.json>".into());
    };
    let destino = PathBuf::from(destino);
    if destino.starts_with("/dev") || destino.to_string_lossy().starts_with(r"\\.\") {
        return Err("esta herramienta solo escribe en archivos, nunca en dispositivos".into());
    }
    let cancelar = AtomicBool::new(false);

    let nombre_iso = PathBuf::from(ruta_iso).file_name().unwrap_or_default().to_string_lossy().to_string();
    let info = iso::analizar(&mut File::open(ruta_iso)?, &nombre_iso)?;
    println!("ISO compatible: {} ({:?}, {} MiB)", info.nombre, info.tipo, info.tamano / 1024 / 1024);

    let texto = std::fs::read_to_string(bmap)?;
    Bmap::verificar_archivo(&texto)?;
    let mapa = Bmap::leer(&texto)?;

    let mut disco = OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&destino)?;
    disco.set_len(gib.parse::<u64>()? * 1024 * 1024 * 1024)?;
    escritura::escribir_y_verificar(File::open(zst)?, &mapa, &mut disco, &cancelar, &mut |_| {})?;
    println!("Instalador escrito y verificado");

    let mut ultimo = 0;
    iso::escribir_iso(&mut File::open(ruta_iso)?, &nombre_iso, &mut disco, &cancelar, &mut |h, t| {
        let pct = h * 100 / t.max(1);
        if pct >= ultimo + 20 {
            ultimo = pct;
            println!("ISO {pct}%");
        }
    })?;
    println!("ISO guardada y verificada en la zona reservada");

    let json = std::fs::read(config)?;
    esp::escribir_config(&mut disco, &json)?;
    if esp::leer_config(&mut disco)? != json {
        return Err("llevix-config.json no se guardó bien".into());
    }
    println!("Listo: {} con la ISO y llevix-config.json", destino.display());
    Ok(())
}
