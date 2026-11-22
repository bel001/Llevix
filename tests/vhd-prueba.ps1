# vhd-prueba.ps1 — Prueba la escritura del creador en Windows con un disco VIRTUAL.
#
# Solo para GitHub Actions (Windows, administrador). Crea un archivo .vhdx, lo conecta
# como disco y lo deja como una memoria USB que ya tenía un Llevix: una partición EFI
# FAT32 SIN letra y una partición exFAT con letra y un archivo. Luego ejecuta la prueba
# `escribe_en_un_disco_virtual` del núcleo, que escribe en \\.\PhysicalDriveN igual
# que el creador. Nunca toca discos reales: el núcleo solo acepta "Msft Virtual Disk".
#
# 1. Modo "antiguo" (cómo escribía el creador hasta v0.0.6-test): solo se informa si
#    falla, para saber si la prueba reproduce el "Acceso denegado".
# 2. Modo actual: debe pasar.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$vhd = Join-Path $env:RUNNER_TEMP 'prueba-llevix.vhdx'
$guion = Join-Path $env:RUNNER_TEMP 'diskpart.txt'

function Quitar-Vhd {
    if (Test-Path $vhd) {
        "select vdisk file=`"$vhd`"`r`ndetach vdisk" | Set-Content -Encoding ascii $guion
        diskpart /s $guion | Out-Null
        Remove-Item -Force $vhd
    }
}

function Preparar-Vhd {
    Quitar-Vhd
    @(
        "create vdisk file=`"$vhd`" maximum=512 type=expandable"
        "select vdisk file=`"$vhd`""
        "attach vdisk"
        "convert gpt"
        "create partition efi size=64"
        "format quick fs=fat32 label=VIEJAEFI"
        "create partition primary"
        "format quick fs=exfat label=VIEJO"
        "assign letter=V"
    ) | Set-Content -Encoding ascii $guion
    diskpart /s $guion | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "diskpart falló ($LASTEXITCODE)" }
    Set-Content -Path 'V:\archivo-viejo.txt' -Value 'hola'
    $numero = (Get-DiskImage -ImagePath $vhd | Get-Disk).Number
    Write-Host "Disco virtual conectado como PhysicalDrive$numero"
    Get-Partition -DiskNumber $numero | Format-Table PartitionNumber, DriveLetter, Size, Type | Out-Host
    return $numero
}

function Probar([string]$modo) {
    $env:LLEVIX_VHD_DISCO = Preparar-Vhd
    $env:LLEVIX_VHD_MODO = $modo
    Write-Host "`n=== Escritura en el disco virtual, modo $modo ==="
    cargo test -p llevix-nucleo --features prueba-vhd --lib escribe_en_un_disco_virtual -- --ignored --nocapture | Out-Host
    $codigo = $LASTEXITCODE
    if ($codigo -eq 0) {
        Get-Partition -DiskNumber $env:LLEVIX_VHD_DISCO | Format-Table PartitionNumber, DriveLetter, Size, Type | Out-Host
    }
    return $codigo
}

try {
    $antiguo = Probar 'antiguo'
    if ($antiguo -ne 0) {
        Write-Host "Modo antiguo: FALLÓ (la prueba reproduce el problema que se corrige)."
    } else {
        Write-Host "Modo antiguo: pasó (esta prueba no reproduce el problema)."
    }
    $actual = Probar 'actual'
    if ($actual -ne 0) { throw "La escritura actual en el disco virtual falló." }
    Write-Host "Modo actual: la escritura en el disco virtual funcionó."
} finally {
    Quitar-Vhd
}
