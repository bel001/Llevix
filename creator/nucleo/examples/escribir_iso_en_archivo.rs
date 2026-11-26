//! Herramienta de pruebas de "Trae tu ISO": hace lo mismo que el creador, pero sobre un
//! ARCHIVO de imagen (disco simulado), nunca sobre un disco real.
//!
//! Uso:
//!   cargo run --release --example escribir_iso_en_archivo -- \
//!       <instalador.img.zst> <instalador.img.bmap> <distro.iso> <destino.img> <GiB> <llevix-config.json>
//!
//! 1. Revisa la ISO (iso::analizar). 2. Escribe la imagen del instalador según el bmap.
//! 3. Deja la ISO en la zona reservada (iso::escribir_iso). 4. Escribe el config en la ESP.

use llevix_nucleo::{bmap::Bmap, crear, iso};
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
    // Como el creador al elegir la ISO: familia y si es una de las ISOs probadas.
    let info = iso::analizar(&mut File::open(ruta_iso)?, &nombre_iso, true)?;
    println!(
        "ISO compatible: {} ({}, {:?}, nivel {:?}{}, {} MiB)",
        info.nombre,
        info.nombre_familia,
        info.tipo,
        info.nivel,
        info.probada_como.as_deref().map(|p| format!(": {p}")).unwrap_or_default(),
        info.tamano / 1024 / 1024
    );

    let texto = std::fs::read_to_string(bmap)?;
    Bmap::verificar_archivo(&texto)?;
    let mapa = Bmap::leer(&texto)?;

    let mut disco = OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&destino)?;
    disco.set_len(gib.parse::<u64>()? * 1024 * 1024 * 1024)?;
    // El mismo proceso que el creador: imagen, ISO, config y, al final, la tabla de particiones.
    let json = std::fs::read(config)?;
    let mut archivo_iso = File::open(ruta_iso)?;
    let propia = crear::IsoPropia { archivo: &mut archivo_iso, nombre: &nombre_iso };
    let mut ultimo = (crear::Paso::Escritura, 0u64);
    crear::escribir_todo(File::open(zst)?, &mapa, &mut disco, Some(propia), &json, &cancelar, &mut |paso, h, t| {
        let pct = h * 100 / t.max(1);
        if paso != ultimo.0 || pct >= ultimo.1 + 20 {
            ultimo = (paso, pct);
            println!("{paso:?} {pct}%");
        }
    })?;
    println!("Listo: {} con la ISO y llevix-config.json", destino.display());
    Ok(())
}
