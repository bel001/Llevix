//! Acceso a discos reales en Windows: enumerarlos y abrir uno para escribir.
//!
//! Se usan directamente funciones de kernel32 (DeviceIoControl y otras) declaradas a
//! mano, con las estructuras leídas byte a byte según la documentación de Microsoft.
//!
//! SEGURIDAD:
//! - [`enumerar_discos`] solo LEE información; abre los discos sin permiso de escritura.
//! - [`abrir_para_escribir`] vuelve a enumerar y exige que el disco siga siendo apto
//!   (USB, no del sistema, tamaño suficiente) antes de abrirlo con escritura.

use crate::disco::{self, Bus, Disco, Volumen};
use crate::error::{Error, Resultado};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::c_void;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;

// ---------- Declaraciones de kernel32 ----------

#[link(name = "kernel32")]
extern "system" {
    fn DeviceIoControl(
        dispositivo: *mut c_void,
        codigo: u32,
        entrada: *const c_void,
        tam_entrada: u32,
        salida: *mut c_void,
        tam_salida: u32,
        devueltos: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn GetLogicalDrives() -> u32;
    fn GetDriveTypeW(raiz: *const u16) -> u32;
    fn GetVolumeInformationW(
        raiz: *const u16,
        nombre: *mut u16,
        tam_nombre: u32,
        serie: *mut u32,
        max_componente: *mut u32,
        banderas: *mut u32,
        sistema: *mut u16,
        tam_sistema: u32,
    ) -> i32;
    fn GetDiskFreeSpaceExW(dir: *const u16, libre_usuario: *mut u64, total: *mut u64, libre: *mut u64) -> i32;
    fn GetSystemWindowsDirectoryW(buffer: *mut u16, tam: u32) -> u32;
    fn FindFirstVolumeW(nombre: *mut u16, tam: u32) -> *mut c_void;
    fn FindNextVolumeW(busqueda: *mut c_void, nombre: *mut u16, tam: u32) -> i32;
    fn FindVolumeClose(busqueda: *mut c_void) -> i32;
}

const IOCTL_STORAGE_QUERY_PROPERTY: u32 = 0x002D_1400;
const IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: u32 = 0x0007_00A0;
const IOCTL_DISK_GET_DRIVE_LAYOUT_EX: u32 = 0x0007_0050;
const IOCTL_DISK_UPDATE_PROPERTIES: u32 = 0x0007_0140;
const IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS: u32 = 0x0056_0000;
const FSCTL_LOCK_VOLUME: u32 = 0x0009_0018;
const FSCTL_DISMOUNT_VOLUME: u32 = 0x0009_0020;

const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;

const DRIVE_REMOVABLE: u32 = 2;
const DRIVE_FIXED: u32 = 3;

const MIB: u64 = 1024 * 1024;

fn ancho(texto: &str) -> Vec<u16> {
    texto.encode_utf16().chain(std::iter::once(0)).collect()
}

fn de_ancho(buf: &[u16]) -> String {
    let fin = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..fin])
}

/// Llama a DeviceIoControl y devuelve los bytes de salida.
fn ioctl(archivo: &File, codigo: u32, entrada: &[u8], tam_salida: usize) -> io::Result<Vec<u8>> {
    let mut salida = vec![0u8; tam_salida];
    let mut devueltos = 0u32;
    let ok = unsafe {
        DeviceIoControl(
            archivo.as_raw_handle() as *mut c_void,
            codigo,
            if entrada.is_empty() { std::ptr::null() } else { entrada.as_ptr() as *const c_void },
            entrada.len() as u32,
            if tam_salida == 0 { std::ptr::null_mut() } else { salida.as_mut_ptr() as *mut c_void },
            tam_salida as u32,
            &mut devueltos,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    salida.truncate(devueltos as usize);
    Ok(salida)
}

fn u32_en(b: &[u8], o: usize) -> u32 {
    b.get(o..o + 4).map(|s| u32::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}

fn u64_en(b: &[u8], o: usize) -> u64 {
    b.get(o..o + 8).map(|s| u64::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}

fn texto_ascii(b: &[u8], desplazamiento: u32) -> String {
    if desplazamiento == 0 || desplazamiento as usize >= b.len() {
        return String::new();
    }
    let resto = &b[desplazamiento as usize..];
    let fin = resto.iter().position(|&c| c == 0).unwrap_or(resto.len());
    String::from_utf8_lossy(&resto[..fin]).trim().to_string()
}

fn bus_de(valor: u32) -> Bus {
    match valor {
        7 => Bus::Usb,
        11 => Bus::Sata,
        17 => Bus::Nvme,
        10 => Bus::Sas,
        1 => Bus::Scsi,
        2 | 3 => Bus::Ata,
        12 => Bus::Sd,
        13 => Bus::Mmc,
        14 | 15 => Bus::Virtual,
        8 | 16 => Bus::Raid,
        _ => Bus::Otro,
    }
}

/// Abre un dispositivo solo para consultas (sin permiso de lectura ni escritura de datos).
fn abrir_consulta(ruta: &str) -> io::Result<File> {
    OpenOptions::new()
        .access_mode(0)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .open(ruta)
}

/// Números de disco que ocupa un volumen (por ejemplo "C:").
fn discos_de_volumen(letra: char) -> Vec<u32> {
    discos_de_ruta(&format!(r"\\.\{letra}:"))
}

/// Números de disco que ocupa el volumen abierto con `ruta` (\\.\E: o \\?\Volume{…}).
fn discos_de_ruta(ruta: &str) -> Vec<u32> {
    let Ok(v) = abrir_consulta(ruta) else { return vec![] };
    let Ok(b) = ioctl(&v, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, &[], 8 + 24 * 32) else { return vec![] };
    let n = u32_en(&b, 0) as usize;
    (0..n.min(32)).map(|i| u32_en(&b, 8 + i * 24)).collect()
}

/// Todos los volúmenes que Windows conoce en el disco `numero`, TENGAN O NO LETRA
/// (por ejemplo la partición EFI de un Llevix anterior). Rutas \\?\Volume{…} sin la
/// barra final, listas para abrir.
fn volumenes_del_disco(numero: u32) -> Vec<String> {
    let mut rutas = Vec::new();
    let mut nombre = [0u16; 261];
    let busqueda = unsafe { FindFirstVolumeW(nombre.as_mut_ptr(), nombre.len() as u32) };
    if busqueda as isize == -1 {
        return rutas;
    }
    loop {
        let ruta = de_ancho(&nombre);
        let ruta = ruta.trim_end_matches('\\').to_string();
        if discos_de_ruta(&ruta).contains(&numero) {
            rutas.push(ruta);
        }
        if unsafe { FindNextVolumeW(busqueda, nombre.as_mut_ptr(), nombre.len() as u32) } == 0 {
            break;
        }
    }
    unsafe { FindVolumeClose(busqueda) };
    rutas
}

struct InfoVolumen {
    discos: Vec<u32>,
    volumen: Volumen,
    es_sistema: bool,
}

fn leer_volumenes() -> Vec<InfoVolumen> {
    let mascara = unsafe { GetLogicalDrives() };
    let windir = {
        let mut buf = [0u16; 260];
        let n = unsafe { GetSystemWindowsDirectoryW(buf.as_mut_ptr(), buf.len() as u32) };
        de_ancho(&buf[..n as usize])
    };
    let letra_windows = windir.chars().next().map(|c| c.to_ascii_uppercase());

    let mut volumenes = Vec::new();
    for i in 0..26u32 {
        if mascara & (1 << i) == 0 {
            continue;
        }
        let letra = (b'A' + i as u8) as char;
        let raiz = format!("{letra}:\\");
        let raiz_w = ancho(&raiz);
        // Solo discos locales: nunca unidades de red ni lectores de CD (pueden demorar).
        let tipo = unsafe { GetDriveTypeW(raiz_w.as_ptr()) };
        if tipo != DRIVE_REMOVABLE && tipo != DRIVE_FIXED {
            continue;
        }
        let discos = discos_de_volumen(letra);
        if discos.is_empty() {
            continue;
        }
        let mut nombre = [0u16; 261];
        let mut sistema = [0u16; 261];
        let (mut serie, mut maxc, mut banderas) = (0u32, 0u32, 0u32);
        unsafe {
            GetVolumeInformationW(
                raiz_w.as_ptr(), nombre.as_mut_ptr(), 261, &mut serie, &mut maxc, &mut banderas,
                sistema.as_mut_ptr(), 261,
            );
        }
        let (mut libre_u, mut total, mut libre) = (0u64, 0u64, 0u64);
        unsafe { GetDiskFreeSpaceExW(raiz_w.as_ptr(), &mut libre_u, &mut total, &mut libre) };
        let muestra: Vec<String> = std::fs::read_dir(&raiz)
            .map(|it| {
                it.filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .filter(|n| n != "System Volume Information" && n != "$RECYCLE.BIN")
                    .take(8)
                    .collect()
            })
            .unwrap_or_default();
        let es_sistema = Some(letra) == letra_windows
            || Path::new(&format!("{raiz}pagefile.sys")).exists()
            || Path::new(&format!("{raiz}Windows\\System32")).exists();
        volumenes.push(InfoVolumen {
            discos,
            es_sistema,
            volumen: Volumen {
                letra: format!("{letra}:"),
                etiqueta: de_ancho(&nombre),
                sistema_archivos: de_ancho(&sistema),
                tamano: total,
                usado: total.saturating_sub(libre),
                muestra,
            },
        });
    }
    volumenes
}

fn contar_particiones(disco: &File) -> u32 {
    let Ok(b) = ioctl(disco, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, &[], 64 * 1024) else { return 0 };
    let n = u32_en(&b, 4) as usize;
    (0..n.min(256)).filter(|i| u64_en(&b, 48 + i * 144 + 16) > 0).count() as u32
}

/// Enumera todos los discos físicos (solo lectura de información).
pub fn enumerar_discos() -> Resultado<Vec<Disco>> {
    let volumenes = leer_volumenes();
    let mut sistema: BTreeSet<u32> = BTreeSet::new();
    let mut por_disco: BTreeMap<u32, Vec<Volumen>> = BTreeMap::new();
    for v in &volumenes {
        for &d in &v.discos {
            if v.es_sistema {
                sistema.insert(d);
            }
            por_disco.entry(d).or_default().push(v.volumen.clone());
        }
    }

    let mut discos = Vec::new();
    for numero in 0..64u32 {
        let Ok(f) = abrir_consulta(&format!(r"\\.\PhysicalDrive{numero}")) else { continue };

        // Consulta: StorageDeviceProperty (0), PropertyStandardQuery (0).
        let consulta = [0u8; 12];
        let Ok(desc) = ioctl(&f, IOCTL_STORAGE_QUERY_PROPERTY, &consulta, 1024) else { continue };
        let extraible = desc.get(10).copied().unwrap_or(0) != 0;
        let vendedor = texto_ascii(&desc, u32_en(&desc, 12));
        let producto = texto_ascii(&desc, u32_en(&desc, 16));
        let bus = bus_de(u32_en(&desc, 28));

        let Ok(geo) = ioctl(&f, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, &[], 256) else { continue };
        let sector_logico = u32_en(&geo, 20);
        let tamano = u64_en(&geo, 24);
        if tamano == 0 {
            continue; // lector de tarjetas vacío, por ejemplo
        }

        discos.push(Disco {
            numero,
            modelo: format!("{vendedor} {producto}").trim().to_string(),
            tamano,
            bus,
            extraible,
            sector_logico,
            es_sistema: sistema.contains(&numero),
            es_arranque: false,
            particiones: contar_particiones(&f),
            volumenes: por_disco.remove(&numero).unwrap_or_default(),
            sospechoso: crate::prueba_disco::capacidad_sospechosa(tamano, extraible),
        });
    }
    Ok(discos)
}

/// Disco físico abierto para escribir, con sus volúmenes bloqueados y desmontados
/// para que Windows no los use mientras tanto.
pub struct DiscoAbierto {
    archivo: File,
    _volumenes: Vec<File>,
    pub tamano: u64,
}

impl Read for DiscoAbierto {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        self.archivo.read(b)
    }
}
impl Write for DiscoAbierto {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        self.archivo.write(b).map_err(|e| {
            if e.raw_os_error() == Some(5) {
                // Acceso denegado: Windows bloquea escribir dentro de una partición que
                // tiene montada. Se explica dónde ocurrió para poder diagnosticarlo.
                let mib = self.archivo.stream_position().unwrap_or(0) / MIB;
                io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "Windows no permitió escribir en el disco (acceso denegado, en el MiB {mib}). \
                         Desconecta el disco, vuelve a conectarlo y reintenta. Si sigue pasando, \
                         revisa que el antivirus o el «Acceso controlado a carpetas» no bloqueen al creador"
                    ),
                )
            } else {
                e
            }
        })
    }
    fn flush(&mut self) -> io::Result<()> {
        self.archivo.flush()?;
        self.archivo.sync_all()
    }
}
impl Seek for DiscoAbierto {
    fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
        self.archivo.seek(p)
    }
}

impl DiscoAbierto {
    /// Borra el primer y el último MiB del disco (tablas de particiones viejas, incluida
    /// la copia de la GPT que queda al final de un disco más grande que la imagen) y
    /// avisa a Windows: así el disco queda sin particiones mientras se escribe.
    pub fn borrar_tablas(&mut self) -> Resultado<()> {
        self.borrar_tablas_sin_avisar()?;
        self.actualizar_windows();
        Ok(())
    }

    fn borrar_tablas_sin_avisar(&mut self) -> Resultado<()> {
        let ceros = vec![0u8; MIB as usize];
        self.archivo.seek(SeekFrom::Start(0))?;
        self.archivo.write_all(&ceros)?;
        if self.tamano >= 2 * MIB {
            let ultimo = (self.tamano - MIB) / 512 * 512;
            self.archivo.seek(SeekFrom::Start(ultimo))?;
            self.archivo.write_all(&ceros[..(self.tamano - ultimo) as usize])?;
        }
        self.flush()?;
        Ok(())
    }

    /// Avisa a Windows que vuelva a leer la tabla de particiones.
    pub fn actualizar_windows(&self) {
        let _ = ioctl(&self.archivo, IOCTL_DISK_UPDATE_PROPERTIES, &[], 0);
    }
}

/// Abre el disco `numero` para escribir, solo si sigue siendo apto.
pub fn abrir_para_escribir(numero: u32, tamano_minimo: u64) -> Resultado<DiscoAbierto> {
    let discos = enumerar_discos()?;
    let elegido = disco::confirmar_destino(numero, &discos, tamano_minimo).map_err(Error::DiscoNoPermitido)?;
    abrir_elegido(&elegido, false)
}

/// Bloquea y desmonta los volúmenes del disco ya comprobado y lo abre para escribir.
/// `solo_con_letra` reproduce el comportamiento anterior (solo para la prueba con VHD).
fn abrir_elegido(elegido: &Disco, solo_con_letra: bool) -> Resultado<DiscoAbierto> {
    let numero = elegido.numero;
    // Todos los volúmenes del disco, también los que no tienen letra (una partición EFI
    // vieja puede estar montada sin letra y Windows bloquearía escribir sobre ella).
    let mut rutas = if solo_con_letra { vec![] } else { volumenes_del_disco(numero) };
    if rutas.is_empty() {
        rutas = elegido.volumenes.iter().map(|v| format!(r"\\.\{}", v.letra)).collect();
    }

    let mut volumenes = Vec::new();
    for ruta in &rutas {
        let nombre = elegido
            .volumenes
            .iter()
            .find(|v| ruta.ends_with(&v.letra))
            .map(|v| v.letra.clone())
            .unwrap_or_else(|| "una partición del disco".to_string());
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .open(ruta)
            .map_err(|e| Error::DiscoNoPermitido(format!("no se pudo abrir {nombre}: {e}")))?;
        let mut bloqueado = false;
        for _ in 0..20 {
            if ioctl(&f, FSCTL_LOCK_VOLUME, &[], 0).is_ok() {
                bloqueado = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        if !bloqueado {
            return Err(Error::DiscoNoPermitido(format!(
                "{nombre} está en uso: cierra el Explorador de archivos y los programas que lo estén usando"
            )));
        }
        ioctl(&f, FSCTL_DISMOUNT_VOLUME, &[], 0)
            .map_err(|e| Error::DiscoNoPermitido(format!("no se pudo desmontar {nombre}: {e}")))?;
        volumenes.push(f);
    }

    let archivo = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_WRITE_THROUGH)
        .open(format!(r"\\.\PhysicalDrive{numero}"))
        .map_err(|e| Error::DiscoNoPermitido(format!("no se pudo abrir el disco (¿falta permiso de administrador?): {e}")))?;

    Ok(DiscoAbierto { archivo, _volumenes: volumenes, tamano: elegido.tamano })
}

#[cfg(test)]
mod pruebas {
    use super::*;

    /// En la máquina de pruebas (GitHub Actions, Windows) no hay discos USB: la lista de
    /// discos aptos debe quedar vacía y nunca incluir el disco del sistema.
    #[test]
    fn enumerar_nunca_ofrece_el_disco_del_sistema() {
        let discos = enumerar_discos().unwrap();
        assert!(!discos.is_empty(), "debería ver al menos el disco del sistema");
        assert!(discos.iter().any(|d| d.es_sistema), "no detectó el disco del sistema: {discos:?}");
        let (aptos, _) = disco::clasificar(discos.clone(), 1);
        for d in &aptos {
            assert_eq!(d.bus, Bus::Usb);
            assert!(!d.es_sistema);
        }
        for d in discos.iter().filter(|d| d.es_sistema) {
            assert!(abrir_para_escribir(d.numero, 1).is_err(), "permitió abrir el disco del sistema");
        }
    }
}

/// Prueba con un disco VIRTUAL (archivo .vhdx conectado en la máquina de pruebas de
/// GitHub, Windows). Recorre el mismo camino que el creador con un disco físico de
/// verdad: \\.\PhysicalDriveN, bloqueo de volúmenes, escritura y verificación.
///
/// Solo existe con la característica `prueba-vhd` (nunca en el creador) y solo acepta
/// un disco virtual de Microsoft ("Msft Virtual Disk") que no sea del sistema.
#[cfg(all(test, feature = "prueba-vhd"))]
mod prueba_vhd {
    use super::*;
    use crate::bmap::{pruebas::crear_bmap, Bmap};
    use crate::esp::VistaParticion;
    use crate::{crear, esp, escritura, gpt};
    use std::io::Cursor;
    use std::sync::atomic::AtomicBool;

    const DATOS: [u8; 16] = [0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7];

    fn crc32(datos: &[u8]) -> u32 {
        let mut crc = 0xFFFF_FFFFu32;
        for &b in datos {
            crc ^= b as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
            }
        }
        !crc
    }

    /// GPT completa y válida (MBR protector, cabeceras con CRC, copia al final), como la
    /// de las imágenes de Llevix, para que Windows la reconozca.
    fn escribir_gpt_valida(img: &mut [u8], particiones: &[([u8; 16], &str, u64, u64)]) {
        let sectores = (img.len() / 512) as u64;
        let ultimo = sectores - 1;
        // MBR protector.
        img[446 + 4] = 0xEE;
        img[446 + 8..446 + 12].copy_from_slice(&1u32.to_le_bytes());
        img[446 + 12..446 + 16].copy_from_slice(&((sectores - 1).min(0xFFFF_FFFF) as u32).to_le_bytes());
        img[510] = 0x55;
        img[511] = 0xAA;
        // Entradas.
        let mut entradas = vec![0u8; 128 * 128];
        for (i, (tipo, nombre, a, b)) in particiones.iter().enumerate() {
            let e = &mut entradas[i * 128..(i + 1) * 128];
            e[0..16].copy_from_slice(tipo);
            e[16..32].copy_from_slice(&[0x4C, 0x4C, 0x45, 0x56, 0x49, 0x58, 0, 0, 0, 0, 0, 0, 0, 0, 0, i as u8 + 1]);
            e[32..40].copy_from_slice(&a.to_le_bytes());
            e[40..48].copy_from_slice(&b.to_le_bytes());
            for (j, c) in nombre.encode_utf16().enumerate() {
                e[56 + j * 2..58 + j * 2].copy_from_slice(&c.to_le_bytes());
            }
        }
        let crc_entradas = crc32(&entradas);
        let cabecera = |actual: u64, otra: u64, lba_entradas: u64| {
            let mut c = [0u8; 512];
            c[0..8].copy_from_slice(b"EFI PART");
            c[8..12].copy_from_slice(&0x0001_0000u32.to_le_bytes());
            c[12..16].copy_from_slice(&92u32.to_le_bytes());
            c[24..32].copy_from_slice(&actual.to_le_bytes());
            c[32..40].copy_from_slice(&otra.to_le_bytes());
            c[40..48].copy_from_slice(&34u64.to_le_bytes());
            c[48..56].copy_from_slice(&(ultimo - 33).to_le_bytes());
            c[56..72].copy_from_slice(b"LLEVIX-PRUEBAVHD");
            c[72..80].copy_from_slice(&lba_entradas.to_le_bytes());
            c[80..84].copy_from_slice(&128u32.to_le_bytes());
            c[84..88].copy_from_slice(&128u32.to_le_bytes());
            c[88..92].copy_from_slice(&crc_entradas.to_le_bytes());
            let crc = crc32(&c[..92]);
            c[16..20].copy_from_slice(&crc.to_le_bytes());
            c
        };
        img[512..1024].copy_from_slice(&cabecera(1, ultimo, 2));
        img[1024..1024 + entradas.len()].copy_from_slice(&entradas);
        let ini = ((ultimo - 32) * 512) as usize;
        img[ini..ini + entradas.len()].copy_from_slice(&entradas);
        img[(ultimo * 512) as usize..].copy_from_slice(&cabecera(ultimo, 1, ultimo - 32));
    }

    fn formatear_fat32(img: &mut Vec<u8>, primer: u64, ultimo: u64, etiqueta: &[u8; 11], archivo: &str) {
        let mut cursor = Cursor::new(std::mem::take(img));
        {
            let mut vista = VistaParticion::new(&mut cursor, primer * 512, (ultimo - primer + 1) * 512);
            fatfs::format_volume(
                &mut vista,
                fatfs::FormatVolumeOptions::new().fat_type(fatfs::FatType::Fat32).volume_label(*etiqueta),
            )
            .unwrap();
            let fs = fatfs::FileSystem::new(&mut vista, fatfs::FsOptions::new()).unwrap();
            let mut f = fs.root_dir().create_file(archivo).unwrap();
            // Datos que ocupan varios MiB, para que la escritura dentro de la partición sea larga.
            for i in 0..(8 * 1024u32) {
                f.write_all(&[(i % 251) as u8 + 1; 1024]).unwrap();
            }
            drop(f);
            fs.unmount().unwrap();
        }
        *img = cursor.into_inner();
    }

    /// Imagen de 192 MiB con la forma de Llevix: partición 1 de datos (FAT32, al final)
    /// y partición 2 EFI (FAT32, al principio), ambas con archivos.
    fn imagen_de_prueba() -> Vec<u8> {
        let mut img = vec![0u8; 192 * 1024 * 1024];
        let esp = (2048u64, 2048 + 64 * 2048 - 1);
        let datos = (esp.1 + 1 + 2048, esp.1 + 2048 + 100 * 2048);
        escribir_gpt_valida(&mut img, &[(DATOS, "LLEVIX-DATOS", datos.0, datos.1), (gpt::TIPO_ESP, "LLEVIX-EFI", esp.0, esp.1)]);
        formatear_fat32(&mut img, esp.0, esp.1, b"LLEVIX-EFI ", "efi.bin");
        formatear_fat32(&mut img, datos.0, datos.1, b"LLEVIX     ", "datos.bin");
        img
    }

    /// Escribe la imagen de prueba en el disco virtual indicado por LLEVIX_VHD_DISCO.
    /// LLEVIX_VHD_MODO=antiguo repite cómo escribía el creador hasta v0.0.6-test (para
    /// comprobar que la prueba reproduce el problema); por defecto, el camino actual.
    #[test]
    #[ignore = "necesita un disco virtual conectado (lo prepara creador.yml)"]
    fn escribe_en_un_disco_virtual() {
        let numero: u32 = std::env::var("LLEVIX_VHD_DISCO").expect("falta LLEVIX_VHD_DISCO").parse().unwrap();
        let antiguo = std::env::var("LLEVIX_VHD_MODO").as_deref() == Ok("antiguo");

        let discos = enumerar_discos().unwrap();
        let elegido = discos.iter().find(|d| d.numero == numero).expect("no existe ese disco").clone();
        println!("disco elegido: {elegido:?}");
        assert_eq!(elegido.bus, Bus::Virtual, "solo se prueba con discos virtuales");
        assert!(elegido.modelo.contains("Msft") && elegido.modelo.contains("Virtual"), "{}", elegido.modelo);
        assert!(!elegido.es_sistema);

        let imagen = imagen_de_prueba();
        assert!(elegido.tamano >= imagen.len() as u64);
        let bmap = Bmap::leer(&crear_bmap(&imagen, 4096)).unwrap();
        let zst = zstd::stream::encode_all(Cursor::new(&imagen), 3).unwrap();
        let config = br#"{"version":1,"usuario":{"nombre":"prueba"}}"#;
        let cancelar = AtomicBool::new(false);

        let mut destino = abrir_elegido(&elegido, antiguo).unwrap();
        if antiguo {
            destino.borrar_tablas_sin_avisar().unwrap();
            escritura::escribir_y_verificar(Cursor::new(zst), &bmap, &mut destino, &cancelar, &mut |_| {}).unwrap();
            esp::escribir_config(&mut destino, config).unwrap();
            assert_eq!(esp::leer_config(&mut destino).unwrap(), config);
        } else {
            destino.borrar_tablas().unwrap();
            // Igual que el creador: primero la prueba del disco (escribe por todo el disco,
            // también donde estaba la partición montada de antes).
            let tamano = destino.tamano;
            let prueba = crate::prueba_disco::probar(&mut destino, tamano, &cancelar, &mut |_, _| {}).unwrap();
            println!("prueba del disco: {:.1} MB/s, {:.0} escrituras pequeñas por segundo", prueba.mb_s, prueba.iops);
            // Y la prueba completa (el disco virtual es chico: 512 MB).
            crate::prueba_disco::probar_completo(&mut destino, tamano, &cancelar, &mut |_, _| {}).unwrap();
            println!("prueba completa del disco: correcta");
            crear::escribir_todo(Cursor::new(zst), &bmap, &mut destino, None, config, &cancelar, &mut |_, _, _| {})
                .unwrap();
        }
        destino.actualizar_windows();
        assert_eq!(contar_particiones(&destino.archivo), 2, "Windows no ve las 2 particiones nuevas");
        println!("escritura correcta en el disco virtual {numero} (modo {})", if antiguo { "antiguo" } else { "actual" });
    }
}
