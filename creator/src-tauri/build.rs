// El creador escribe discos físicos: en Windows necesita permisos de administrador.
// El manifiesto pide esos permisos al abrir la app (aparece el aviso de Windows).
fn main() {
    let ventanas = tauri_build::WindowsAttributes::new()
        .app_manifest(include_str!("llevix-creador.exe.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(ventanas))
        .expect("no se pudo preparar la compilación de Tauri");
}
