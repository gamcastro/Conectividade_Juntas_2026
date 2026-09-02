# =============================================================================
#  DICON - preparo UNICO da maquina (ADMINISTRADOR).
#
#  Cria <D|C>:\Aplic e da escrita ao grupo "Usuarios", pra a instalacao
#  (Baixar-e-Instalar.ps1) rodar depois como usuario comum, no layout
#  <D|C>:\Aplic\DICON (producao) / ...\DICON-HOMOLOG (homologacao).
#
#  PowerShell ABERTO COMO ADMINISTRADOR:
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Preparar-Maquina.ps1')
#
#  Para tambem apagar instalacoes anteriores travadas, antes do comando:
#      $env:DICON_LIMPAR = '1'
#
#  (sem #Requires/param()/BOM: roda via `iex (irm ...)`.)
# =============================================================================
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$souAdmin = ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $souAdmin) {
    Write-Host 'Este preparo precisa de ADMINISTRADOR.' -ForegroundColor Red
    Write-Host 'Abra o PowerShell com "Executar como administrador" e rode o comando de novo.' -ForegroundColor Yellow
    return
}

# base: D: se for disco fixo, senao C:
$base = 'C:'
try {
    $di = [System.IO.DriveInfo]::new('D:\')
    if ($di.IsReady -and $di.DriveType -eq 'Fixed') { $base = 'D:' }
} catch { }
$aplic = Join-Path "$base\" 'Aplic'
$limpar = [bool] $env:DICON_LIMPAR

Write-Host "Preparando $aplic ..." -ForegroundColor Cyan
if (-not (Test-Path $aplic)) {
    New-Item -ItemType Directory -Path $aplic -Force | Out-Null
    Write-Host "  criada $aplic" -ForegroundColor Green
}

foreach ($n in 'DICON', 'DICON-HOMOLOG') {
    $p = Join-Path $aplic $n
    if ($limpar -and (Test-Path $p)) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removida instalacao anterior: $p" -ForegroundColor Green
    }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# grupo "Usuarios" = SID *S-1-5-32-545 (independe de idioma); Modify + heranca
& icacls $aplic /grant '*S-1-5-32-545:(OI)(CI)M' /T | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  icacls retornou $LASTEXITCODE - verifique manualmente." -ForegroundColor Yellow
} else {
    Write-Host "  escrita concedida ao grupo Usuarios em $aplic (e subpastas)" -ForegroundColor Green
}
$global:LASTEXITCODE = 0

Write-Host ''
Write-Host "Pronto. Agora, como USUARIO COMUM (nao admin):" -ForegroundColor Green
Write-Host "  Producao:    iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/setup/Baixar-e-Instalar.ps1')" -ForegroundColor White
Write-Host "  Homologacao: iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')" -ForegroundColor White
