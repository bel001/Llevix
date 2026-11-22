//! `llevix-config.json`: lo que el primer arranque necesita para crear la cuenta.
//!
//! El formato está en `docs/llevix-config.md`. La contraseña NUNCA se guarda: se
//! convierte a hash SHA-512 (`$6$...`) en el momento, y el texto original se descarta.
//! Las reglas de validación son las mismas que aplica `image/firstboot/firstboot.sh`,
//! para avisar al usuario antes de escribir el disco.

use crate::error::{Error, Resultado};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Usuario {
    pub nombre: String,
    pub nombre_completo: String,
    pub hash_contrasena: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Teclado {
    pub distribucion: String,
    pub variante: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Accesibilidad {
    pub lector_pantalla: bool,
    pub texto_grande: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ConfigLlevix {
    pub version: u32,
    pub usuario: Usuario,
    pub idioma: String,
    pub zona_horaria: String,
    pub teclado: Teclado,
    pub hostname: String,
    pub accesibilidad: Accesibilidad,
}

/// Datos que escribe el usuario en el asistente (la contraseña en texto solo vive aquí,
/// en memoria, el tiempo justo para calcular el hash).
#[derive(Debug, Clone, Deserialize)]
pub struct DatosCuenta {
    pub usuario: String,
    pub nombre_completo: String,
    pub contrasena: String,
    pub idioma: String,
    pub zona_horaria: String,
    pub teclado: String,
    #[serde(default)]
    pub variante_teclado: String,
    #[serde(default)]
    pub hostname: String,
}

const RESERVADOS: &[&str] = &[
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp",
    "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody", "systemd-network",
    "systemd-resolve", "messagebus", "syslog", "admin", "sudo", "adm", "users", "llevix",
];

/// Calcula el hash SHA-512 de crypt (`$6$...`) con una sal aleatoria.
pub fn hash_contrasena(contrasena: &str) -> Resultado<String> {
    if contrasena.is_empty() {
        return Err(Error::Config("la contraseña no puede estar vacía".into()));
    }
    let parametros = sha_crypt::Sha512Params::new(sha_crypt::ROUNDS_DEFAULT)
        .map_err(|_| Error::Config("parámetros de hash inválidos".into()))?;
    sha_crypt::sha512_simple(contrasena, &parametros)
        .map_err(|_| Error::Config("no se pudo calcular el hash de la contraseña".into()))
}

pub fn validar_usuario(nombre: &str) -> Resultado<()> {
    let mut chars = nombre.chars();
    let primero_ok = chars.next().is_some_and(|c| c.is_ascii_lowercase());
    let resto_ok = chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_');
    if !primero_ok || !resto_ok || nombre.len() > 32 {
        return Err(Error::Config(
            "el nombre de usuario debe empezar con una letra minúscula y usar solo minúsculas, números, - o _ (máximo 32)".into(),
        ));
    }
    if RESERVADOS.contains(&nombre) {
        return Err(Error::Config(format!("el nombre '{nombre}' está reservado por el sistema")));
    }
    Ok(())
}

pub fn validar_hostname(h: &str) -> Resultado<()> {
    let ok = !h.is_empty()
        && h.len() <= 63
        && h.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        && !h.starts_with('-')
        && !h.ends_with('-');
    if ok {
        Ok(())
    } else {
        Err(Error::Config("el nombre del equipo solo puede tener letras, números y -".into()))
    }
}

/// Convierte un nombre de usuario en un nombre de equipo válido: "llevix-<usuario>".
pub fn hostname_por_defecto(usuario: &str) -> String {
    let limpio: String = usuario
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    let h = format!("llevix-{limpio}");
    h.trim_end_matches('-').chars().take(63).collect()
}

impl ConfigLlevix {
    /// Arma la configuración a partir de lo que escribió el usuario, validando todo.
    pub fn desde_datos(d: DatosCuenta) -> Resultado<ConfigLlevix> {
        validar_usuario(&d.usuario)?;
        if d.nombre_completo.chars().count() > 100
            || d.nombre_completo.contains([':', ',', '\n', '\r'])
        {
            return Err(Error::Config(
                "el nombre completo no puede tener ':', ',' ni saltos de línea (máximo 100 caracteres)".into(),
            ));
        }
        if d.contrasena.chars().count() < 4 {
            return Err(Error::Config("la contraseña debe tener al menos 4 caracteres".into()));
        }
        let idioma_ok = d.idioma.ends_with(".UTF-8")
            && d.idioma.len() <= 16
            && d.idioma.trim_end_matches(".UTF-8").chars().all(|c| c.is_ascii_alphabetic() || c == '_');
        if !idioma_ok {
            return Err(Error::Config(format!("idioma no válido: {}", d.idioma)));
        }
        let zona_ok = !d.zona_horaria.is_empty()
            && !d.zona_horaria.contains("..")
            && d.zona_horaria.chars().all(|c| c.is_ascii_alphanumeric() || "_+-/".contains(c));
        if !zona_ok {
            return Err(Error::Config(format!("zona horaria no válida: {}", d.zona_horaria)));
        }
        if d.teclado.is_empty() || d.teclado.len() > 8 || !d.teclado.chars().all(|c| c.is_ascii_lowercase()) {
            return Err(Error::Config(format!("teclado no válido: {}", d.teclado)));
        }
        if !d.variante_teclado.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err(Error::Config("variante de teclado no válida".into()));
        }
        let hostname = if d.hostname.trim().is_empty() {
            hostname_por_defecto(&d.usuario)
        } else {
            d.hostname.trim().to_string()
        };
        validar_hostname(&hostname)?;

        let hash = hash_contrasena(&d.contrasena)?;
        Ok(ConfigLlevix {
            version: 1,
            usuario: Usuario {
                nombre: d.usuario,
                nombre_completo: d.nombre_completo,
                hash_contrasena: hash,
            },
            idioma: d.idioma,
            zona_horaria: d.zona_horaria,
            teclado: Teclado { distribucion: d.teclado, variante: d.variante_teclado },
            hostname,
            accesibilidad: Accesibilidad::default(),
        })
    }

    pub fn a_json(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(self).expect("la configuración siempre se puede serializar")
    }
}

#[cfg(test)]
mod pruebas {
    use super::*;

    fn datos() -> DatosCuenta {
        DatosCuenta {
            usuario: "ana".into(),
            nombre_completo: "Ana Pérez".into(),
            contrasena: "clave segura".into(),
            idioma: "es_MX.UTF-8".into(),
            zona_horaria: "America/Mexico_City".into(),
            teclado: "latam".into(),
            variante_teclado: String::new(),
            hostname: String::new(),
        }
    }

    /// Mismo patrón que usa image/firstboot/firstboot.sh para aceptar el hash.
    fn hash_valido_para_firstboot(h: &str) -> bool {
        let Some(resto) = h.strip_prefix("$6$") else { return false };
        let resto = match resto.strip_prefix("rounds=") {
            Some(r) => {
                let (n, r) = r.split_once('$').unwrap_or(("", ""));
                if n.is_empty() || !n.chars().all(|c| c.is_ascii_digit()) {
                    return false;
                }
                r
            }
            None => resto,
        };
        let Some((sal, hash)) = resto.split_once('$') else { return false };
        let b64 = |s: &str| s.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '/');
        (1..=16).contains(&sal.len()) && b64(sal) && hash.len() == 86 && b64(hash)
    }

    #[test]
    fn el_hash_es_sha512_y_comprobable() {
        let h = hash_contrasena("clave segura").unwrap();
        assert!(hash_valido_para_firstboot(&h), "{h}");
        assert!(sha_crypt::sha512_check("clave segura", &h).is_ok());
        assert!(sha_crypt::sha512_check("otra", &h).is_err());
        // Dos hashes de la misma contraseña son distintos (sal aleatoria).
        assert_ne!(h, hash_contrasena("clave segura").unwrap());
    }

    #[test]
    fn el_json_no_contiene_la_contrasena() {
        let cfg = ConfigLlevix::desde_datos(datos()).unwrap();
        let json = String::from_utf8(cfg.a_json()).unwrap();
        assert!(!json.contains("clave segura"));
        assert!(json.contains("\"hash_contrasena\": \"$6$"));
        assert_eq!(cfg.hostname, "llevix-ana");
        let leido: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(leido["version"], 1);
        assert_eq!(leido["teclado"]["distribucion"], "latam");
        assert_eq!(leido["accesibilidad"]["lector_pantalla"], false);
    }

    #[test]
    fn rechaza_datos_invalidos() {
        for usuario in ["Ana", "1ana", "ana perez", "root", "llevix", ""] {
            let mut d = datos();
            d.usuario = usuario.into();
            assert!(ConfigLlevix::desde_datos(d).is_err(), "aceptó usuario {usuario:?}");
        }
        let mut d = datos();
        d.nombre_completo = "Ana: la jefa".into();
        assert!(ConfigLlevix::desde_datos(d).is_err());
        let mut d = datos();
        d.contrasena = "abc".into();
        assert!(ConfigLlevix::desde_datos(d).is_err());
        let mut d = datos();
        d.zona_horaria = "../../etc/passwd".into();
        assert!(ConfigLlevix::desde_datos(d).is_err());
        let mut d = datos();
        d.hostname = "-malo-".into();
        assert!(ConfigLlevix::desde_datos(d).is_err());
    }

    #[test]
    fn hostname_por_defecto_valido() {
        assert_eq!(hostname_por_defecto("ana_maria"), "llevix-ana-maria");
        assert!(validar_hostname(&hostname_por_defecto(&"a".repeat(32))).is_ok());
    }
}
