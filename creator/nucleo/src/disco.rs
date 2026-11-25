//! Qué discos puede elegir el usuario.
//!
//! REGLA DE ORO: el creador nunca muestra ni escribe discos internos ni el disco del
//! sistema. Solo discos conectados por USB (memorias y discos externos HDD/SSD/NVMe en
//! caja USB). En Windows muchos discos externos no figuran como "extraíbles", por eso
//! se filtra por el tipo de bus y no por esa marca.
//!
//! Este módulo es lógica pura: recibe la descripción de los discos (de Windows o de
//! una prueba) y decide. Así se puede probar con discos simulados.

use serde::Serialize;

/// Tipo de conexión del disco (STORAGE_BUS_TYPE de Windows, simplificado).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Bus {
    Usb,
    Sata,
    Nvme,
    Sas,
    Scsi,
    Ata,
    Sd,
    Mmc,
    Virtual,
    Raid,
    Otro,
}

#[derive(Debug, Clone, Serialize)]
pub struct Volumen {
    /// Letra en Windows, por ejemplo "E:" (vacío si no tiene).
    pub letra: String,
    pub etiqueta: String,
    pub sistema_archivos: String,
    pub tamano: u64,
    pub usado: u64,
    /// Algunos nombres de archivos y carpetas de la raíz, para que el usuario reconozca el disco.
    pub muestra: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Disco {
    /// Número de disco de Windows (\\.\PhysicalDriveN).
    pub numero: u32,
    pub modelo: String,
    pub tamano: u64,
    pub bus: Bus,
    pub extraible: bool,
    /// Tamaño de sector lógico en bytes (las imágenes de Llevix usan 512).
    pub sector_logico: u32,
    /// Contiene Windows, el arranque o el archivo de paginación.
    pub es_sistema: bool,
    /// Windows lo marcó como disco de arranque o de sistema por otra vía.
    pub es_arranque: bool,
    /// Cantidad de particiones (algunas pueden no tener letra en Windows).
    pub particiones: u32,
    pub volumenes: Vec<Volumen>,
    /// El tamaño que informa es típico de una memoria falsa (ver
    /// `prueba_disco::capacidad_sospechosa`): el creador sugiere la prueba completa.
    pub sospechoso: bool,
}

impl Disco {
    /// ¿Tiene datos visibles? (volúmenes con espacio usado o con archivos).
    pub fn tiene_datos(&self) -> bool {
        self.particiones > 0 || self.volumenes.iter().any(|v| v.usado > 0 || !v.muestra.is_empty())
    }
}

/// Motivo por el que un disco no se puede usar (para registro y pruebas; los discos
/// internos ni siquiera se muestran).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Exclusion {
    NoEsUsb,
    EsDelSistema,
    MuyChico { necesario: u64 },
    SectorNoSoportado(u32),
}

pub fn motivo_exclusion(d: &Disco, tamano_minimo: u64) -> Option<Exclusion> {
    if d.bus != Bus::Usb {
        return Some(Exclusion::NoEsUsb);
    }
    if d.es_sistema || d.es_arranque {
        return Some(Exclusion::EsDelSistema);
    }
    if d.sector_logico != 512 {
        return Some(Exclusion::SectorNoSoportado(d.sector_logico));
    }
    if d.tamano < tamano_minimo {
        return Some(Exclusion::MuyChico { necesario: tamano_minimo });
    }
    None
}

/// Discos USB que se muestran en la lista. Los demás (internos, del sistema) se descartan.
/// Los USB muy chicos se devuelven aparte para poder explicar por qué no sirven.
pub fn clasificar(discos: Vec<Disco>, tamano_minimo: u64) -> (Vec<Disco>, Vec<Disco>) {
    let mut aptos = Vec::new();
    let mut usb_no_aptos = Vec::new();
    for d in discos {
        match motivo_exclusion(&d, tamano_minimo) {
            None => aptos.push(d),
            Some(Exclusion::MuyChico { .. }) | Some(Exclusion::SectorNoSoportado(_)) => usb_no_aptos.push(d),
            Some(Exclusion::NoEsUsb) | Some(Exclusion::EsDelSistema) => {}
        }
    }
    aptos.sort_by_key(|d| d.numero);
    (aptos, usb_no_aptos)
}

/// Comprobación final justo antes de escribir: el disco elegido debe seguir siendo apto
/// en una enumeración nueva (por si el usuario cambió discos mientras tanto).
pub fn confirmar_destino(numero: u32, discos_actuales: &[Disco], tamano_minimo: u64) -> Result<Disco, String> {
    let d = discos_actuales
        .iter()
        .find(|d| d.numero == numero)
        .ok_or_else(|| "el disco elegido ya no está conectado".to_string())?;
    match motivo_exclusion(d, tamano_minimo) {
        None => Ok(d.clone()),
        Some(Exclusion::NoEsUsb) => Err("el disco no está conectado por USB".into()),
        Some(Exclusion::EsDelSistema) => Err("es el disco del sistema".into()),
        Some(Exclusion::MuyChico { necesario }) => Err(format!(
            "el disco es demasiado chico (necesita al menos {:.1} GB)",
            necesario as f64 / 1e9
        )),
        Some(Exclusion::SectorNoSoportado(s)) => Err(format!("sectores de {s} bytes no soportados")),
    }
}

#[cfg(test)]
mod pruebas {
    use super::*;

    const GB: u64 = 1_000_000_000;
    const MINIMO: u64 = 30_064_771_072; // 28 GiB

    fn disco(numero: u32, bus: Bus, tamano: u64) -> Disco {
        Disco {
            numero,
            modelo: format!("Disco {numero}"),
            tamano,
            bus,
            extraible: bus == Bus::Usb,
            sector_logico: 512,
            es_sistema: false,
            es_arranque: false,
            particiones: 0,
            volumenes: vec![],
            sospechoso: false,
        }
    }

    /// Una PC típica: SSD NVMe con Windows, HDD SATA, lector SD interno, memoria USB,
    /// SSD externo USB (no "extraíble"), memoria USB chica y un disco virtual.
    fn pc_de_prueba() -> Vec<Disco> {
        let mut windows = disco(0, Bus::Nvme, 512 * GB);
        windows.es_sistema = true;
        windows.es_arranque = true;
        let mut ssd_externo = disco(4, Bus::Usb, 1000 * GB);
        ssd_externo.extraible = false;
        vec![
            windows,
            disco(1, Bus::Sata, 2000 * GB),
            disco(2, Bus::Sd, 64 * GB),
            disco(3, Bus::Usb, 64 * GB),
            ssd_externo,
            disco(5, Bus::Usb, 8 * GB),
            disco(6, Bus::Virtual, 100 * GB),
            disco(7, Bus::Raid, 4000 * GB),
        ]
    }

    #[test]
    fn nunca_muestra_discos_internos() {
        let (aptos, no_aptos) = clasificar(pc_de_prueba(), MINIMO);
        let todos: Vec<_> = aptos.iter().chain(no_aptos.iter()).collect();
        assert!(todos.iter().all(|d| d.bus == Bus::Usb), "{todos:?}");
        for interno in [0, 1, 2, 6, 7] {
            assert!(todos.iter().all(|d| d.numero != interno), "mostró el disco {interno}");
        }
    }

    #[test]
    fn muestra_memorias_y_discos_externos_usb_aunque_no_sean_extraibles() {
        let (aptos, _) = clasificar(pc_de_prueba(), MINIMO);
        let numeros: Vec<u32> = aptos.iter().map(|d| d.numero).collect();
        assert_eq!(numeros, vec![3, 4]);
    }

    #[test]
    fn nunca_muestra_el_disco_del_sistema_aunque_sea_usb() {
        // Windows instalado en un disco USB (Windows To Go).
        let mut d = disco(0, Bus::Usb, 256 * GB);
        d.es_sistema = true;
        let mut e = disco(1, Bus::Usb, 256 * GB);
        e.es_arranque = true;
        let (aptos, no_aptos) = clasificar(vec![d, e], MINIMO);
        assert!(aptos.is_empty() && no_aptos.is_empty());
    }

    #[test]
    fn los_usb_chicos_se_explican_pero_no_se_pueden_elegir() {
        let (aptos, no_aptos) = clasificar(pc_de_prueba(), MINIMO);
        assert!(aptos.iter().all(|d| d.numero != 5));
        assert_eq!(no_aptos.iter().map(|d| d.numero).collect::<Vec<_>>(), vec![5]);
        assert_eq!(motivo_exclusion(&no_aptos[0], MINIMO), Some(Exclusion::MuyChico { necesario: MINIMO }));
    }

    #[test]
    fn una_memoria_de_32_gb_real_sirve() {
        // Una memoria "de 32 GB" tiene en la práctica unos 30,7 GB.
        let (aptos, _) = clasificar(vec![disco(3, Bus::Usb, 30_752_000_000)], MINIMO);
        assert_eq!(aptos.len(), 1);
    }

    #[test]
    fn rechaza_discos_con_sectores_de_4k() {
        let mut d = disco(3, Bus::Usb, 2000 * GB);
        d.sector_logico = 4096;
        assert_eq!(motivo_exclusion(&d, MINIMO), Some(Exclusion::SectorNoSoportado(4096)));
    }

    #[test]
    fn la_confirmacion_final_vuelve_a_comprobar() {
        let discos = pc_de_prueba();
        assert!(confirmar_destino(3, &discos, MINIMO).is_ok());
        assert!(confirmar_destino(0, &discos, MINIMO).is_err()); // sistema
        assert!(confirmar_destino(1, &discos, MINIMO).is_err()); // SATA interno
        assert!(confirmar_destino(9, &discos, MINIMO).is_err()); // ya no está
    }

    #[test]
    fn detecta_si_tiene_datos() {
        let mut d = disco(3, Bus::Usb, 64 * GB);
        assert!(!d.tiene_datos());
        d.volumenes.push(Volumen {
            letra: "E:".into(),
            etiqueta: "FOTOS".into(),
            sistema_archivos: "exFAT".into(),
            tamano: 64 * GB,
            usado: 3 * GB,
            muestra: vec!["Vacaciones".into()],
        });
        assert!(d.tiene_datos());
    }
}
