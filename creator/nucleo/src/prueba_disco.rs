//! Prueba rápida del disco antes de escribir Llevix.
//!
//! Detecta dos problemas comunes de las memorias USB baratas:
//!
//! 1. **Memorias falsas**: dicen tener, por ejemplo, 128 GB pero guardan mucho menos.
//!    Lo que se escribe más allá de la capacidad real se pierde, devuelve un error o cae
//!    encima de otra parte del disco (la memoria "da la vuelta"). Llevix quedaría dañado
//!    en cuanto la carpeta Datos crezca hasta el final del disco.
//!    Se escriben bloques pequeños con datos únicos en posiciones repartidas por todo el
//!    disco (múltiplos de una potencia de dos, para que si la memoria "da la vuelta" un
//!    bloque caiga encima de otro) y se leen de vuelta.
//! 2. **Memorias muy lentas**: se mide la velocidad de escritura. Linux escribe muchos
//!    archivos pequeños; en una memoria lenta los programas tardan mucho en abrir.
//!
//! Al terminar, todos los bloques de prueba se dejan en cero (como las zonas vacías de
//! la imagen). El disco ya debe estar sin tabla de particiones: el primer MiB no se toca.

use crate::crear::TAM_CABECERA;
use crate::error::{Error, Resultado};
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

const MIB: u64 = 1024 * 1024;
const GB: f64 = 1_000_000_000.0;
/// Tamaño de cada bloque de la prueba de capacidad.
const TAM_BLOQUE: usize = 64 * 1024;
/// Distancia mínima entre bloques y cantidad máxima de bloques.
const PASO_MINIMO: u64 = 256 * MIB;
const MAX_BLOQUES: u64 = 2048;
/// Escrituras pequeñas (4 KiB) en posiciones al azar, como las que hace Linux.
const ESCRITURAS_PEQUENAS: usize = 128;
const TAM_PEQUENA: usize = 4096;
/// Por debajo de estas velocidades se avisa que el disco es lento.
const MB_S_LENTO: f64 = 5.0;
const IOPS_LENTO: f64 = 50.0;

/// Resultado de la prueba (solo si el disco guarda bien los datos).
#[derive(Debug, Clone)]
pub struct PruebaDisco {
    /// Escritura en bloques de 64 KiB, en MB/s.
    pub mb_s: f64,
    /// Escrituras de 4 KiB por segundo.
    pub iops: f64,
}

impl PruebaDisco {
    pub fn es_lento(&self) -> bool {
        self.mb_s < MB_S_LENTO || self.iops < IOPS_LENTO
    }

    /// Aviso para mostrar al usuario si el disco es lento.
    pub fn aviso(&self) -> Option<String> {
        self.es_lento().then(|| {
            format!(
                "Este disco es muy lento: escribe a {:.1} MB/s y hace {:.0} escrituras pequeñas por segundo. \
                 Llevix funcionará, pero los programas pueden tardar mucho en abrir. Para usarlo a diario \
                 conviene una memoria USB 3 de marca conocida o un SSD externo.",
                self.mb_s, self.iops
            )
        })
    }
}

/// Prueba el disco. `tamano` es el tamaño total del disco en bytes.
/// `progreso(hechos, total)` cuenta bytes escritos y leídos.
pub fn probar<D: Read + Write + Seek>(
    disco: &mut D,
    tamano: u64,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(u64, u64),
) -> Resultado<PruebaDisco> {
    let semilla = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x1234_5678);
    probar_con(disco, tamano, semilla, cancelar, progreso)
}

/// Posiciones de los bloques de la prueba de capacidad: múltiplos de una potencia de dos
/// (al menos 256 MiB) y el final del disco.
fn posiciones_bloques(tamano: u64) -> Vec<u64> {
    let mut paso = PASO_MINIMO;
    while tamano / paso > MAX_BLOQUES {
        paso *= 2;
    }
    let mut v: Vec<u64> = (1..).map(|k| k * paso).take_while(|&p| p + TAM_BLOQUE as u64 <= tamano).collect();
    let ultimo = (tamano - TAM_BLOQUE as u64) / 4096 * 4096;
    if ultimo >= TAM_CABECERA && v.last() != Some(&ultimo) {
        v.push(ultimo);
    }
    v
}

/// Posiciones (alineadas a 4 KiB, sin repetir) de las escrituras pequeñas: al azar
/// dentro de los primeros 256 MiB después de la cabecera.
fn posiciones_pequenas(tamano: u64, rng: &mut Azar) -> Vec<u64> {
    let zona = (tamano.saturating_sub(TAM_CABECERA) / 2).min(256 * MIB) / 4096;
    if zona == 0 {
        return vec![];
    }
    let mut v: Vec<u64> = Vec::with_capacity(ESCRITURAS_PEQUENAS);
    while v.len() < ESCRITURAS_PEQUENAS.min(zona as usize) {
        let p = TAM_CABECERA + (rng.siguiente() % zona) * 4096;
        if !v.contains(&p) {
            v.push(p);
        }
    }
    v
}

fn probar_con<D: Read + Write + Seek>(
    disco: &mut D,
    tamano: u64,
    semilla: u64,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(u64, u64),
) -> Resultado<PruebaDisco> {
    let mut rng = Azar(semilla | 1);
    let pequenas = posiciones_pequenas(tamano, &mut rng);
    let bloques = posiciones_bloques(tamano);
    let bytes_pequenas = (pequenas.len() * TAM_PEQUENA) as u64;
    let bytes_bloques = (bloques.len() * TAM_BLOQUE) as u64;
    // Escribir y leer los bloques, más dejar todo en cero al final.
    let total = 2 * bytes_pequenas + 3 * bytes_bloques;
    let mut hechos = 0u64;
    let revisar = || if cancelar.load(Ordering::Relaxed) { Err(Error::Cancelado) } else { Ok(()) };

    // 1. Velocidad de escrituras pequeñas.
    let mut buf = vec![0u8; TAM_PEQUENA];
    let t = Instant::now();
    for &p in &pequenas {
        revisar()?;
        llenar(&mut buf, semilla ^ p);
        disco.seek(SeekFrom::Start(p))?;
        disco.write_all(&buf)?;
        hechos += TAM_PEQUENA as u64;
        progreso(hechos, total);
    }
    disco.flush()?;
    let iops = pequenas.len() as f64 / t.elapsed().as_secs_f64().max(1e-6);

    // 2. Capacidad real: escribir todos los bloques y después leerlos.
    let mut buf = vec![0u8; TAM_BLOQUE];
    let t = Instant::now();
    for &p in &bloques {
        revisar()?;
        llenar(&mut buf, semilla ^ p.rotate_left(17));
        disco.seek(SeekFrom::Start(p))?;
        disco.write_all(&buf).map_err(|e| falso(p, &e.to_string()))?;
        hechos += TAM_BLOQUE as u64;
        progreso(hechos, total);
    }
    disco.flush()?;
    let mb_s = bytes_bloques as f64 / 1e6 / t.elapsed().as_secs_f64().max(1e-6);

    let mut esperado = vec![0u8; TAM_BLOQUE];
    for &p in &bloques {
        revisar()?;
        llenar(&mut esperado, semilla ^ p.rotate_left(17));
        disco.seek(SeekFrom::Start(p))?;
        disco.read_exact(&mut buf).map_err(|e| falso(p, &e.to_string()))?;
        if buf != esperado {
            return Err(falso(p, "lo que se leyó no es lo que se escribió"));
        }
        hechos += TAM_BLOQUE as u64;
        progreso(hechos, total);
    }

    // 3. Dejar en cero todo lo que se escribió.
    let ceros = vec![0u8; TAM_BLOQUE];
    for &p in &pequenas {
        revisar()?;
        disco.seek(SeekFrom::Start(p))?;
        disco.write_all(&ceros[..TAM_PEQUENA])?;
        hechos += TAM_PEQUENA as u64;
        progreso(hechos, total);
    }
    for &p in &bloques {
        revisar()?;
        disco.seek(SeekFrom::Start(p))?;
        disco.write_all(&ceros)?;
        hechos += TAM_BLOQUE as u64;
        progreso(hechos, total);
    }
    disco.flush()?;
    Ok(PruebaDisco { mb_s, iops })
}

/// Trozo de la prueba completa.
const TROZO_COMPLETO: usize = 4 * 1024 * 1024;
/// Cada cuánto, durante la escritura de la prueba completa, se releen muestras de lo
/// ya escrito (múltiplo de `TROZO_COMPLETO`).
const REVISAR_CADA: u64 = 1024 * MIB;
/// Bytes que se releen al comienzo de cada tramo ya escrito.
const MUESTRA: usize = 4096;

/// ¿El tamaño que informa el disco es típico de una memoria falsa? Los discos de verdad
/// tienen tamaños "irregulares" (una memoria de 64 GB guarda, por ejemplo, 61 530 439 680
/// bytes); las falsas suelen informar un número redondo programado a mano (100 000 MiB,
/// 2 TiB) o una capacidad enorme para una memoria USB.
pub fn capacidad_sospechosa(tamano: u64, extraible: bool) -> bool {
    const GIB: u64 = 1024 * MIB;
    let redondo = tamano % GIB == 0 || tamano % (1000 * MIB) == 0;
    (tamano >= 8 * GIB && redondo) || (extraible && tamano >= 1_000_000_000_000)
}

/// Prueba completa, como H2testw: escribe datos únicos en TODO el disco (menos el primer
/// MiB), después lo lee entero y lo compara. Es la única forma de detectar las memorias
/// falsas que "van llenando": guardan bien lo escrito en cualquier posición hasta que se
/// acaba su capacidad real y desde ahí pisan lo anterior. La prueba rápida no las ve.
///
/// Durante la escritura, cada 1 GiB se relee el comienzo de cada tramo ya escrito: en una
/// memoria falsa se detiene poco después de pasar su capacidad real, sin escribir todo.
/// Al terminar, el último MiB queda en cero (como lo deja `borrar_tablas`).
pub fn probar_completo<D: Read + Write + Seek>(
    disco: &mut D,
    tamano: u64,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(u64, u64),
) -> Resultado<()> {
    let semilla = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x8765_4321);
    probar_completo_con(disco, tamano, semilla, TROZO_COMPLETO, REVISAR_CADA, cancelar, progreso)
}

/// Datos únicos de un trozo: dependen de su posición en el disco. El comienzo del patrón
/// es el mismo aunque se genere solo una parte (sirve para las muestras).
fn patron(buf: &mut [u8], semilla: u64, posicion: u64) {
    llenar(buf, semilla ^ posicion.wrapping_mul(0x9E37_79B9_7F4A_7C15));
}

fn probar_completo_con<D: Read + Write + Seek>(
    disco: &mut D,
    tamano: u64,
    semilla: u64,
    trozo: usize,
    revisar_cada: u64,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(u64, u64),
) -> Resultado<()> {
    debug_assert!(trozo % 512 == 0 && revisar_cada % trozo as u64 == 0);
    let inicio = TAM_CABECERA;
    let fin = tamano / 512 * 512;
    if fin <= inicio {
        return Ok(());
    }
    let total = 2 * (fin - inicio);
    let mut hechos = 0u64;
    let revisar = || if cancelar.load(Ordering::Relaxed) { Err(Error::Cancelado) } else { Ok(()) };
    let mut buf = vec![0u8; trozo];
    let mut esperado = vec![0u8; trozo];

    // 1. Escribir todo, releyendo muestras cada `revisar_cada`.
    let mut pos = inicio;
    let mut proxima = inicio + revisar_cada;
    while pos < fin {
        revisar()?;
        let n = (fin - pos).min(trozo as u64) as usize;
        patron(&mut buf[..n], semilla, pos);
        disco.seek(SeekFrom::Start(pos))?;
        disco.write_all(&buf[..n]).map_err(|e| falsa(pos - inicio, tamano, Some(&e.to_string())))?;
        pos += n as u64;
        hechos += n as u64;
        progreso(hechos, total);

        if pos >= proxima || pos == fin {
            disco.flush()?;
            let mut p = inicio;
            while p < pos {
                let m = MUESTRA.min((pos - p) as usize);
                patron(&mut esperado[..m], semilla, p);
                disco.seek(SeekFrom::Start(p))?;
                disco.read_exact(&mut buf[..m]).map_err(|e| falsa(pos - inicio, tamano, Some(&e.to_string())))?;
                if buf[..m] != esperado[..m] {
                    // Lo escrito en el último tramo pisó datos anteriores: la capacidad
                    // real se acabó en ese tramo.
                    return Err(falsa(pos.saturating_sub(revisar_cada).max(inicio) - inicio, tamano, None));
                }
                p += revisar_cada;
            }
            proxima += revisar_cada;
        }
    }

    // 2. Leer todo y comparar.
    let mut pos = inicio;
    while pos < fin {
        revisar()?;
        let n = (fin - pos).min(trozo as u64) as usize;
        patron(&mut esperado[..n], semilla, pos);
        disco.seek(SeekFrom::Start(pos))?;
        disco.read_exact(&mut buf[..n]).map_err(|e| falsa(pos - inicio, tamano, Some(&e.to_string())))?;
        if buf[..n] != esperado[..n] {
            return Err(falsa(pos - inicio, tamano, None));
        }
        pos += n as u64;
        hechos += n as u64;
        progreso(hechos, total);
    }

    // 3. El último MiB en cero: que no quede nada parecido a una tabla de particiones.
    let desde = fin.saturating_sub(MIB).max(inicio);
    disco.seek(SeekFrom::Start(desde))?;
    disco.write_all(&vec![0u8; (fin - desde) as usize])?;
    disco.flush()?;
    Ok(())
}

/// Error de la prueba completa. `bien`: cuánto guardó bien la memoria (aproximado).
fn falsa(bien: u64, tamano: u64, detalle: Option<&str>) -> Error {
    let detalle = detalle.map(|d| format!(" ({d})")).unwrap_or_default();
    Error::DiscoDefectuoso(format!(
        "Esta memoria es falsa o está dañada: dice tener {:.1} GB, pero solo guarda bien unos {:.1} GB{detalle}. \
         Lo que se escribe más allá se pierde o borra lo anterior, y Llevix se dañaría al usarla. \
         Usa una memoria USB de marca conocida o un disco externo (y, si puedes, reclama al vendedor).",
        tamano as f64 / GB,
        bien as f64 / GB
    ))
}

fn falso(posicion: u64, detalle: &str) -> Error {
    Error::DiscoDefectuoso(format!(
        "Este disco no guarda bien los datos: lo escrito cerca de los {:.1} GB no se pudo leer de vuelta ({detalle}). \
         Suele pasar con memorias falsas, que dicen tener más capacidad de la que tienen. Llevix se dañaría en \
         este disco: usa otra memoria USB (de marca conocida) o un disco externo.",
        posicion as f64 / GB
    ))
}

/// Números pseudoaleatorios simples (xorshift64): datos distintos en cada bloque.
struct Azar(u64);
impl Azar {
    fn siguiente(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

fn llenar(buf: &mut [u8], semilla: u64) {
    let mut a = Azar(semilla | 1);
    for trozo in buf.chunks_mut(8) {
        let n = a.siguiente().to_le_bytes();
        trozo.copy_from_slice(&n[..trozo.len()]);
    }
}

#[cfg(test)]
mod pruebas {
    use super::*;
    use std::io::{self, Cursor};

    const GIB: u64 = 1024 * MIB;

    /// Disco disperso en memoria (solo guarda los bloques escritos), para simular
    /// discos grandes sin usar mucha RAM. `real` simula una memoria falsa.
    struct DiscoSimulado {
        tamano: u64,
        real: u64,
        falso: Falso,
        bloques: std::collections::HashMap<u64, Vec<u8>>,
        pos: u64,
        /// Solo para `Falso::Llena`: bloque lógico → hueco físico, y huecos ya usados.
        mapa: std::collections::HashMap<u64, u64>,
        usados: u64,
    }
    #[derive(Clone, Copy, PartialEq)]
    enum Falso {
        No,
        /// Lo escrito más allá de la capacidad real cae encima del comienzo.
        DaLaVuelta,
        /// Lo escrito más allá de la capacidad real se pierde (se lee cero).
        Pierde,
        /// Guarda bien cualquier posición hasta llenar su capacidad real; después cada
        /// bloque nuevo pisa el más antiguo (las falsas más comunes).
        Llena,
    }
    const B: u64 = 4096;
    impl DiscoSimulado {
        fn new(tamano: u64, real: u64, falso: Falso) -> Self {
            Self { tamano, real, falso, bloques: Default::default(), pos: 0, mapa: Default::default(), usados: 0 }
        }
        /// Posición física de `p` al leer (None: no se guardó nada ahí).
        fn real(&self, p: u64) -> Option<u64> {
            match self.falso {
                Falso::No => Some(p),
                Falso::DaLaVuelta => Some(p % self.real),
                Falso::Pierde => (p < self.real).then_some(p),
                Falso::Llena => self.mapa.get(&(p / B)).map(|h| h * B + p % B),
            }
        }
        /// Posición física de `p` al escribir.
        fn real_escribir(&mut self, p: u64) -> Option<u64> {
            if self.falso != Falso::Llena {
                return self.real(p);
            }
            let huecos = self.real / B;
            let usados = &mut self.usados;
            let h = *self.mapa.entry(p / B).or_insert_with(|| {
                *usados += 1;
                (*usados - 1) % huecos
            });
            Some(h * B + p % B)
        }
    }
    impl Read for DiscoSimulado {
        fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
            for (i, x) in b.iter_mut().enumerate() {
                let p = self.pos + i as u64;
                *x = self.real(p).and_then(|r| self.bloques.get(&(r / B)).map(|blk| blk[(r % B) as usize])).unwrap_or(0);
            }
            self.pos += b.len() as u64;
            Ok(b.len())
        }
    }
    impl Write for DiscoSimulado {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            assert!(self.pos + b.len() as u64 <= self.tamano, "escritura fuera del disco");
            assert!(self.pos >= TAM_CABECERA, "la prueba no debe tocar el primer MiB");
            for (i, &x) in b.iter().enumerate() {
                if let Some(r) = self.real_escribir(self.pos + i as u64) {
                    self.bloques.entry(r / B).or_insert_with(|| vec![0; B as usize])[(r % B) as usize] = x;
                }
            }
            self.pos += b.len() as u64;
            Ok(b.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Seek for DiscoSimulado {
        fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
            self.pos = match p {
                SeekFrom::Start(x) => x,
                _ => unimplemented!(),
            };
            Ok(self.pos)
        }
    }

    fn probar_simulado(d: &mut DiscoSimulado) -> Resultado<PruebaDisco> {
        let t = d.tamano;
        probar_con(d, t, 42, &AtomicBool::new(false), &mut |_, _| {})
    }

    #[test]
    fn un_disco_bueno_pasa_y_queda_en_cero() {
        let mut d = DiscoSimulado::new(64 * GIB, 0, Falso::No);
        let r = probar_simulado(&mut d).expect("un disco bueno debe pasar");
        assert!(r.mb_s > 0.0 && r.iops > 0.0);
        assert!(d.bloques.values().all(|b| b.iter().all(|&x| x == 0)), "todo debe quedar en cero");
    }

    #[test]
    fn detecta_una_memoria_que_da_la_vuelta() {
        // Dice 128 GB, guarda 8 GiB.
        let mut d = DiscoSimulado::new(128 * GIB, 8 * GIB, Falso::DaLaVuelta);
        let e = probar_simulado(&mut d).unwrap_err();
        assert!(matches!(e, Error::DiscoDefectuoso(_)), "{e}");
    }

    #[test]
    fn detecta_una_memoria_que_pierde_datos() {
        let mut d = DiscoSimulado::new(64 * GIB, 16 * GIB, Falso::Pierde);
        let e = probar_simulado(&mut d).unwrap_err();
        assert!(e.to_string().contains("memorias falsas"), "{e}");
    }

    #[test]
    fn detecta_una_memoria_falsa_con_capacidad_rara() {
        // Capacidad real que no es potencia de dos y pierde lo que pasa de ella.
        let mut d = DiscoSimulado::new(32 * GIB, 30 * GIB, Falso::Pierde);
        assert!(probar_simulado(&mut d).is_err());
    }

    #[test]
    fn posiciones_repartidas_y_limitadas() {
        let v = posiciones_bloques(2 * 1024 * GIB);
        assert!(v.len() as u64 <= MAX_BLOQUES + 1);
        assert_eq!(*v.last().unwrap(), 2 * 1024 * GIB - TAM_BLOQUE as u64);
        assert!(v.iter().all(|&p| p >= TAM_CABECERA && p % 4096 == 0));
        let v = posiciones_bloques(16 * GIB);
        assert_eq!(v[0], 256 * MIB);
    }

    #[test]
    fn el_aviso_de_lento() {
        assert!(PruebaDisco { mb_s: 2.0, iops: 300.0 }.aviso().is_some());
        assert!(PruebaDisco { mb_s: 40.0, iops: 20.0 }.aviso().is_some());
        assert!(PruebaDisco { mb_s: 40.0, iops: 300.0 }.aviso().is_none());
    }

    #[test]
    fn se_puede_cancelar() {
        let mut d = DiscoSimulado::new(16 * GIB, 0, Falso::No);
        let e = probar_con(&mut d, 16 * GIB, 1, &AtomicBool::new(true), &mut |_, _| {}).unwrap_err();
        assert!(matches!(e, Error::Cancelado));
    }

    #[test]
    fn funciona_con_un_archivo_pequeno() {
        let mut c = Cursor::new(vec![0u8; 300 * MIB as usize]);
        let r = probar_con(&mut c, 300 * MIB, 7, &AtomicBool::new(false), &mut |_, _| {});
        assert!(r.is_ok());
        assert!(c.into_inner().iter().all(|&x| x == 0));
    }

    // ---------- Prueba completa ----------
    // Con trozos y tramos chicos para que los discos simulados sean pequeños.

    const TROZO_P: usize = 64 * 1024;
    const TRAMO_P: u64 = MIB;

    fn completo<D: Read + Write + Seek>(d: &mut D, tamano: u64) -> Resultado<()> {
        probar_completo_con(d, tamano, 99, TROZO_P, TRAMO_P, &AtomicBool::new(false), &mut |_, _| {})
    }

    #[test]
    fn completo_pasa_un_disco_bueno() {
        let tamano = 24 * MIB + 3 * 512; // tamaño que no es múltiplo del trozo
        let mut c = Cursor::new(vec![0u8; tamano as usize]);
        let mut ultimo = (0, 0);
        probar_completo_con(&mut c, tamano, 99, TROZO_P, TRAMO_P, &AtomicBool::new(false), &mut |h, t| ultimo = (h, t))
            .expect("un disco bueno debe pasar");
        assert_eq!(ultimo.0, ultimo.1, "el progreso llega al 100 %");
        let datos = c.into_inner();
        assert!(datos[..TAM_CABECERA as usize].iter().all(|&x| x == 0), "el primer MiB no se toca");
        assert!(datos[(tamano - MIB) as usize..].iter().all(|&x| x == 0), "el último MiB queda en cero");
        assert!(datos[TAM_CABECERA as usize..(tamano - MIB) as usize].iter().any(|&x| x != 0));
    }

    #[test]
    fn completo_detecta_una_memoria_que_va_llenando() {
        // Dice 24 MiB, guarda 8 MiB en cualquier posición.
        let mut d = DiscoSimulado::new(24 * MIB, 8 * MIB, Falso::Llena);
        let e = completo(&mut d, 24 * MIB).unwrap_err();
        assert!(matches!(e, Error::DiscoDefectuoso(_)), "{e}");
        assert!(e.to_string().contains("falsa"), "{e}");
        // Se detuvo poco después de pasar la capacidad real, sin escribir todo el disco.
        assert!(d.usados * B < 8 * MIB + 2 * TRAMO_P, "escribió {} bytes", d.usados * B);
    }

    #[test]
    fn la_prueba_rapida_no_ve_una_memoria_que_va_llenando() {
        // Por eso existe la prueba completa: la rápida escribe poco y la memoria lo guarda.
        let mut d = DiscoSimulado::new(16 * GIB, 32 * MIB, Falso::Llena);
        assert!(probar_simulado(&mut d).is_ok());
    }

    #[test]
    fn completo_detecta_las_otras_memorias_falsas() {
        let mut d = DiscoSimulado::new(24 * MIB, 8 * MIB, Falso::DaLaVuelta);
        assert!(matches!(completo(&mut d, 24 * MIB), Err(Error::DiscoDefectuoso(_))));
        let mut d = DiscoSimulado::new(24 * MIB, 20 * MIB, Falso::Pierde);
        assert!(matches!(completo(&mut d, 24 * MIB), Err(Error::DiscoDefectuoso(_))));
    }

    #[test]
    fn completo_se_puede_cancelar() {
        let mut c = Cursor::new(vec![0u8; 8 * MIB as usize]);
        let r = probar_completo_con(&mut c, 8 * MIB, 1, TROZO_P, TRAMO_P, &AtomicBool::new(true), &mut |_, _| {});
        assert!(matches!(r, Err(Error::Cancelado)));
    }

    #[test]
    fn capacidades_sospechosas() {
        // Memoria de Temu: 100 000 MiB exactos.
        assert!(capacidad_sospechosa(104_857_600_000, true));
        // Memoria "de 2 TB".
        assert!(capacidad_sospechosa(2 * 1024 * GIB, true));
        assert!(capacidad_sospechosa(2_000_000_000_000 - 4096, true));
        // Discos de verdad.
        assert!(!capacidad_sospechosa(61_530_439_680, true)); // memoria de 64 GB
        assert!(!capacidad_sospechosa(123_060_879_360, true)); // memoria de 128 GB
        assert!(!capacidad_sospechosa(1_000_204_886_016, false)); // SSD externo de 1 TB
        // Discos virtuales chicos (pruebas): exactos pero pequeños.
        assert!(!capacidad_sospechosa(512 * MIB, false));
    }
}
