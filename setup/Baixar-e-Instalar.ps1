#Requires -Version 5.1
# =============================================================================
#  DICON - baixar + extrair + instalar num comando.
#
#  Uso (PowerShell normal, com internet):
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')
#
#  Opcoes: definir ANTES do comando (todas opcionais)
#      $env:DICON_DEST     = 'D:\DICON'          # padrao: C:\DICON
#      $env:DICON_BRANCH   = 'homologacao'       # padrao: homologacao
#      $env:DICON_ENDPOINT = 'https://.../exec'  # URL /exec do Web App
#      $env:DICON_PIN      = '1234'              # PIN do admin
#      $env:DICON_IPERF    = '10.11.9.20'        # servidor iperf3
#      $env:DICON_DEPSZIP  = 'D:\pen\DICON-deps.zip'
#
#  NAO usa param()/[CmdletBinding()] de proposito: isso quebra o `iex (irm ...)`.
# =============================================================================
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Dest     = if ($env:DICON_DEST)   { $env:DICON_DEST }   else { 'C:\DICON' }
$Branch   = if ($env:DICON_BRANCH) { $env:DICON_BRANCH } else { 'homologacao' }
$Endpoint = [string] $env:DICON_ENDPOINT
$Pin      = [string] $env:DICON_PIN
$Iperf    = [string] $env:DICON_IPERF
$DepsZip  = [string] $env:DICON_DEPSZIP
$Repo     = 'https://github.com/gamcastro/Conectividade_Juntas_2026'
$OoklaZip = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'

function Save-ZipRemoto {
    param([string] $Url, [string] $OutFile, [int] $Tentativas = 3)
    for ($i = 1; $i -le $Tentativas; $i++) {
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 180; return $true }
        catch { if ($i -lt $Tentativas) { Start-Sleep 3 } }
    }
    return $false
}

# --- 1. codigo: instala do zero ou atualiza o que ja existe --------------------
if (Test-Path (Join-Path $Dest 'src')) {
    Write-Host "Ja existe um DICON em $Dest - atualizando o codigo (Atualizar-DICON -Force)." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'setup\Atualizar-DICON.ps1') -Force -Branch $Branch
} else {
    Write-Host ("DICON: baixando a branch '{0}' para {1}" -f $Branch, $Dest) -ForegroundColor Cyan
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-boot-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'dicon.zip'
    try {
        if (-not (Save-ZipRemoto "$Repo/archive/refs/heads/$Branch.zip" $zip)) { throw "nao consegui baixar o codigo ($Branch)." }
        Unblock-File $zip -ErrorAction SilentlyContinue
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $srcDir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'Conectividade_Juntas_2026*' } | Select-Object -First 1
        if (-not $srcDir) { throw 'o ZIP da branch nao extraiu como esperado.' }
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        robocopy $srcDir.FullName $Dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falhou (codigo $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
        Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Codigo em $Dest." -ForegroundColor Green
}

# --- 2. speedtest.exe (Ookla CLI): garante que existe em tools\ e desbloqueia --
$stExe = Join-Path $Dest 'tools\speedtest.exe'
if (-not (Test-Path $stExe)) {
    Write-Host 'Baixando o Ookla Speedtest CLI...' -ForegroundColor Cyan
    $stZip = Join-Path ([IO.Path]::GetTempPath()) ('ookla-' + [guid]::NewGuid().ToString('N') + '.zip')
    $stX   = Join-Path ([IO.Path]::GetTempPath()) ('ookla-x-' + [guid]::NewGuid().ToString('N'))
    try {
        if (Save-ZipRemoto $OoklaZip $stZip) {
            Expand-Archive -Path $stZip -DestinationPath $stX -Force
            New-Item -ItemType Directory -Path (Split-Path $stExe) -Force | Out-Null
            foreach ($n in 'speedtest.exe', 'speedtest.md') {
                $f = Get-ChildItem $stX -Recurse -Filter $n -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($f) { Copy-Item $f.FullName (Join-Path (Join-Path $Dest 'tools') $n) -Force }
            }
        }
    } catch { } finally {
        Remove-Item $stZip, $stX -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (Test-Path $stExe) {
    Unblock-File $stExe -ErrorAction SilentlyContinue
    Write-Host "speedtest.exe OK e desbloqueado em $Dest\tools." -ForegroundColor Green
} else {
    Write-Host "NAO consegui o speedtest.exe. Baixe de https://www.speedtest.net/apps/cli e coloque em $Dest\tools\" -ForegroundColor Yellow
}

# --- 3. setup: so na instalacao nova (sem config\admin.json) ------------------
if (Test-Path (Join-Path $Dest 'config\admin.json')) {
    Write-Host ''
    Write-Host "DICON ja configurado. Para rebaixar binarios: cd '$Dest'; .\setup\Instalar-DICON.ps1 -Force" -ForegroundColor DarkGray
    Write-Host "Abrir: cd '$Dest'; .\Iniciar-Diagnostico.bat" -ForegroundColor White
} else {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dest 'setup\Instalar-DICON.ps1'))
    if ($Endpoint) { $psArgs += @('-Endpoint', $Endpoint) }
    if ($Pin)      { $psArgs += @('-Pin', $Pin) }
    if ($Iperf)    { $psArgs += @('-IperfServidor', $Iperf) }
    if ($DepsZip)  { $psArgs += @('-DepsZip', $DepsZip) }
    Write-Host ''
    Write-Host 'Rodando o setup...' -ForegroundColor Cyan
    Set-Location $Dest
    & powershell.exe @psArgs
}
