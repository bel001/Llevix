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
    let Ok(v) = abrir_consulta(&format!(r"\\.\{letra}:")) else { return vec![] };
    let Ok(b) = ioctl(&v, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, &[], 8 + 24 * 32) else { return vec![] };
    let n = u32_en(&b, 0) as usize;
    (0..n.min(32)).map(|i| u32_en(&b, 8 + i * 24)).collect()
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
        self.archivo.write(b)
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
    /// la copia de la GPT que queda al final de un disco más grande que la imagen).
    pub fn borrar_tablas(&mut self) -> Resultado<()> {
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

    // Bloquear y desmontar cada volumen del disco.
    let mut volumenes = Vec::new();
    for v in &elegido.volumenes {
        let ruta = format!(r"\\.\{}", v.letra);
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .open(&ruta)
            .map_err(|e| Error::DiscoNoPermitido(format!("no se pudo abrir {}: {e}", v.letra)))?;
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
                "{} está en uso: cierra los programas y ventanas que lo estén usando",
                v.letra
            )));
        }
        ioctl(&f, FSCTL_DISMOUNT_VOLUME, &[], 0)
            .map_err(|e| Error::DiscoNoPermitido(format!("no se pudo desmontar {}: {e}", v.letra)))?;
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
