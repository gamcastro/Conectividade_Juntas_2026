#Requires -Version 5.1
<#
.SYNOPSIS
    Baixa o DICON do GitHub, extrai para a pasta de destino e roda o setup.
    Junta o "passo 1" (baixar + extrair) e o "passo 2" (Instalar-DICON.ps1).

.DESCRIPTION
    Uso rapido (PowerShell interativo, uma linha):
        iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')

    Para mudar destino/branch sem baixar o arquivo, defina antes:
        $env:DICON_DEST   = 'D:\DICON'       # padrao: C:\DICON
        $env:DICON_BRANCH = 'homologacao'    # padrao: homologacao

    Passando parametros (baixe o arquivo, ou use um scriptblock):
        & ([scriptblock]::Create((irm '<url-raw>'))) -Dest 'D:\DICON' -Endpoint 'https://.../exec' -Pin 1234

.PARAMETER Dest
    Pasta de instalacao (padrao C:\DICON, ou $env:DICON_DEST).

.PARAMETER Branch
    Branch do GitHub a baixar (padrao homologacao, ou $env:DICON_BRANCH).

.PARAMETER Endpoint / Pin / IperfServidor / DepsZip
    Repassados ao setup\Instalar-DICON.ps1 (modo nao interativo).

.PARAMETER SemSetup
    So baixa e extrai; nao roda o Instalar-DICON.ps1.
#>
[CmdletBinding()]
param(
    [string] $Dest   = $(if ($env:DICON_DEST)   { $env:DICON_DEST }   else { 'C:\DICON' }),
    [string] $Branch = $(if ($env:DICON_BRANCH) { $env:DICON_BRANCH } else { 'homologacao' }),
    [string] $Endpoint,
    [string] $Pin,
    [string] $IperfServidor,
    [string] $DepsZip,
    [switch] $SemSetup
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Repo = 'https://github.com/gamcastro/Conectividade_Juntas_2026'
Write-Host ("DICON: baixando a branch '{0}' para {1}" -f $Branch, $Dest) -ForegroundColor Cyan

if (Test-Path (Join-Path $Dest 'src')) {
    Write-Host "Ja existe um DICON em $Dest." -ForegroundColor Yellow
    Write-Host "Para atualizar: cd '$Dest'; .\setup\Atualizar-DICON.ps1 -Force" -ForegroundColor Yellow
    Write-Host "Para reinstalar do zero: apague a pasta e rode de novo." -ForegroundColor Yellow
    return
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-boot-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'dicon.zip'
try {
    Invoke-WebRequest -Uri "$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 180
    Unblock-File $zip -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $srcDir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'Conectividade_Juntas_2026*' } | Select-Object -First 1
    if (-not $srcDir) { throw 'O ZIP da branch nao extraiu como esperado.' }

    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    robocopy $srcDir.FullName $Dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou (codigo $LASTEXITCODE)." }
    $global:LASTEXITCODE = 0
    Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Codigo em $Dest." -ForegroundColor Green

if ($SemSetup) {
    Write-Host "Setup nao executado (-SemSetup). Rode depois: cd '$Dest'; .\setup\Instalar-DICON.ps1" -ForegroundColor DarkGray
    return
}

$setup = Join-Path $Dest 'setup\Instalar-DICON.ps1'
if (-not (Test-Path $setup)) { throw "Nao encontrei $setup" }

$p = @{}
if ($Endpoint)      { $p['Endpoint']      = $Endpoint }
if ($Pin)           { $p['Pin']           = $Pin }
if ($IperfServidor) { $p['IperfServidor'] = $IperfServidor }
if ($DepsZip)       { $p['DepsZip']       = $DepsZip }

Write-Host ''
Write-Host "Rodando o setup..." -ForegroundColor Cyan
Set-Location $Dest
& $setup @p
