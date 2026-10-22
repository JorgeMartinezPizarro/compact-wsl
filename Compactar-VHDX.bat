@echo off
rem ============================================================
rem  Compactar-VHDX.bat  -  autocontenido
rem  Extrae el script PowerShell incrustado al final de este
rem  fichero a un .ps1 temporal y lo ejecuta (se borra al acabar).
rem ============================================================
setlocal
set "SELF=%~f0"
set "PS1=%TEMP%\Compactar-VHDX-%RANDOM%%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-Content -LiteralPath $env:SELF -Raw; $m = '#' + '#PS1#'; $t.Substring($t.IndexOf($m) + $m.Length) | Set-Content -LiteralPath $env:PS1 -Encoding UTF8"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b

##PS1#
param(
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [string]$AppData      = $env:APPDATA,
    [string]$Sid          = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    [string]$Flag         = ''   # fichero para avisar a la ventana normal de que reinicie Docker
)

# ------------------------------------------------------------
# Docker Desktop: parar y arrancar en segundo plano
# ------------------------------------------------------------
function Get-DockerCli {
    $c = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($c) { $c.Source } else { $null }
}

function Stop-DockerDesktop {
    $cli = Get-DockerCli
    if ($cli) {
        & $cli desktop stop 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    }
    # Docker Desktop antiguo sin "docker desktop": cierre forzado
    Get-Process "Docker Desktop", "com.docker.backend", "com.docker.build" -ErrorAction SilentlyContinue |
        Stop-Process -Force
    Start-Sleep -Seconds 5
}

function Start-DockerDesktopBackground([string]$exe) {
    $cli = Get-DockerCli
    if ($cli) {
        & $cli desktop start --detach 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    }
    # Docker Desktop antiguo: solo se puede abrir la aplicacion
    if ($exe) { Start-Process $exe }
}

# ------------------------------------------------------------
# Ventana normal: elevar, esperar y reiniciar Docker sin privilegios
# ------------------------------------------------------------
$yo = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $flagPath = Join-Path $env:TEMP "Compactar-VHDX-$PID.flag"
    $argumentos = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
                  "-LocalAppData `"$LocalAppData`" -AppData `"$AppData`" -Sid $Sid -Flag `"$flagPath`""
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argumentos -PassThru -ErrorAction Stop
    } catch {
        Write-Host "Se necesitan permisos de administrador. Cancelado." -ForegroundColor Red
        Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
        Read-Host "Pulsa Enter para cerrar"
        exit
    }

    Write-Host "Compactando en la ventana de administrador..."
    while (-not $p.HasExited -and -not (Test-Path -LiteralPath $flagPath)) { Start-Sleep -Seconds 1 }

    if (Test-Path -LiteralPath $flagPath) {
        $exe = (Get-Content -LiteralPath $flagPath -Raw).Trim()
        Remove-Item -LiteralPath $flagPath -ErrorAction SilentlyContinue
        Start-DockerDesktopBackground $exe
    }
    exit
}

# ------------------------------------------------------------
# Ventana de administrador: buscar y compactar
# ------------------------------------------------------------
function Get-SizeGB($ruta) { [math]::Round((Get-Item -LiteralPath $ruta).Length / 1GB, 2) }

function Find-Vhdx {
    $lista = New-Object System.Collections.Generic.List[string]

    # 1) Todas las distros de WSL registradas (estan donde esten)
    $lxss = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $lxss) {
        foreach ($k in Get-ChildItem $lxss) {
            $p = Get-ItemProperty $k.PSPath
            if ($p.BasePath) {
                $base = $p.BasePath -replace '^\\\\\?\\', ''
                $nombre = if ($p.VhdFileName) { $p.VhdFileName } else { 'ext4.vhdx' }
                $ruta = Join-Path $base $nombre
                if (Test-Path -LiteralPath $ruta) { $lista.Add($ruta) }
            }
        }
    }

    # 2) Carpetas de Docker Desktop y de apps de la Store
    $carpetas = @("$LocalAppData\Docker", "$LocalAppData\Packages")

    # 3) Ubicacion personalizada de los discos de Docker, si la hay
    foreach ($cfg in "$AppData\Docker\settings-store.json", "$AppData\Docker\settings.json") {
        if (Test-Path -LiteralPath $cfg) {
            try {
                $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
                if ($j.CustomWslDistroDir) { $carpetas += $j.CustomWslDistroDir }
            } catch {}
        }
    }

    foreach ($c in $carpetas) {
        if (Test-Path -LiteralPath $c) {
            Get-ChildItem -LiteralPath $c -Filter *.vhdx -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { $lista.Add($_.FullName) }
        }
    }

    $lista | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
}

try {
    Write-Host "Buscando discos virtuales (.vhdx)..." -ForegroundColor Cyan
    $discos = @(Find-Vhdx)

    if ($discos.Count -eq 0) {
        Write-Host "No se ha encontrado ningun .vhdx." -ForegroundColor Yellow
        Read-Host "Pulsa Enter para cerrar"
        return
    }

    Write-Host ""
    Write-Host "Encontrados $($discos.Count) discos:" -ForegroundColor Green
    foreach ($d in $discos) { Write-Host ("  {0,8} GB  {1}" -f (Get-SizeGB $d), $d) }
    Write-Host ""
    Read-Host "Pulsa Enter para compactarlos (o cierra la ventana para cancelar)"

    # --- Liberar los discos: parar Docker Desktop y apagar WSL ---
    $dockerExe = $null
    $docker = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
    if ($docker) {
        $dockerExe = $docker[0].Path
        Write-Host "Parando Docker Desktop..." -ForegroundColor Cyan
        Stop-DockerDesktop
    }
    Write-Host "Apagando WSL (wsl --shutdown)..." -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 3

    # --- Compactar uno a uno (un fallo no detiene el resto) ---
    $tmp = Join-Path $env:TEMP "compact_vhdx_diskpart.txt"
    $i = 0
    $resultados = foreach ($d in $discos) {
        $i++
        Write-Host ""
        Write-Host "[$i/$($discos.Count)] $d" -ForegroundColor Cyan
        $antes = Get-SizeGB $d

        @("select vdisk file=`"$d`"", "attach vdisk readonly", "compact vdisk", "detach vdisk") |
            Set-Content -LiteralPath $tmp -Encoding Default
        $salida = diskpart.exe /s $tmp 2>&1
        $ok = ($LASTEXITCODE -eq 0)

        if ($ok) {
            Write-Host "   OK" -ForegroundColor Green
        } else {
            Write-Host "   ERROR (en uso o no compactable). Salida de diskpart:" -ForegroundColor Red
            Write-Host (($salida | Out-String).Trim()) -ForegroundColor DarkGray
            # por si se quedo montado
            @("select vdisk file=`"$d`"", "detach vdisk noerr") | Set-Content -LiteralPath $tmp -Encoding Default
            diskpart.exe /s $tmp | Out-Null
        }

        $despues = Get-SizeGB $d
        [pscustomobject]@{
            Estado     = if ($ok) { 'OK' } else { 'ERROR' }
            'Antes GB' = $antes
            'Ahora GB' = $despues
            'Libre GB' = [math]::Round($antes - $despues, 2)
            Disco      = $d
        }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

    # --- Resetear WSL: tras desmontar los discos intenta levantarse solo
    #     y queda inestable; un segundo shutdown lo deja limpio ---
    Write-Host ""
    Write-Host "Reseteando WSL (wsl --shutdown)..." -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 3

    # --- Reiniciar Docker Desktop en segundo plano ---
    if ($dockerExe) {
        Write-Host ""
        Write-Host "Reiniciando Docker Desktop en segundo plano..." -ForegroundColor Cyan
        if ($Flag) {
            # lo hace la ventana normal, sin privilegios de administrador
            Set-Content -LiteralPath $Flag -Value $dockerExe
        } else {
            # el .bat se lanzo ya como administrador: no queda otra que hacerlo aqui
            Start-DockerDesktopBackground $dockerExe
        }
    }

    # --- Resumen ---
    Write-Host ""
    Write-Host "=== Resultado ===" -ForegroundColor Green
    $resultados | Format-Table -AutoSize -Wrap | Out-Host
    $total = [math]::Round(($resultados | Measure-Object 'Libre GB' -Sum).Sum, 2)
    Write-Host "Total liberado: $total GB" -ForegroundColor Green

    Write-Host ""
    Read-Host "Pulsa Enter para cerrar"
}
finally {
    Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
}
