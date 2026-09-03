#Requires -Version 5.1
<#
.SYNOPSIS
    Atualiza o codigo do DICON (src\, lib\mahapps\, assets\, bin\iperf3\,
    tools\*.ps1, Iniciar-Diagnostico.*) SEM tocar em config\, data\,
    bin\geckodriver\, bin\chromedriver\, lib\Selenium\, resultados\ e relatorios\.

.DESCRIPTION
    Usa 'git pull' se a pasta for um clone; senao baixa o ZIP da branch e
    sobrescreve apenas as pastas de codigo.

.PARAMETER Branch
    Branch a puxar. Se omitido, usa o canal desta instalacao (config\canal:
    'main' = producao, 'homologacao' = homologacao); sem o arquivo, homologacao.

.PARAMETER Force
    Com git: descarta alteracoes locais (git reset --hard) antes de puxar.
#>
[CmdletBinding()]
param(
    [string] $Branch,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$RaizApp = Split-Path $PSScriptRoot -Parent
$Repo    = 'https://github.com/gamcastro/Conectividade_Juntas_2026'

# Baixa um arquivo com varias tentativas e 3 metodos (BITS retoma quedas; depois
# Invoke-WebRequest; depois WebClient). O zip da branch tem ~11 MB (o iperf3 vai
# versionado), entao numa conexao instavel de campo uma queda no meio e comum -
# "Uma conexao estabelecida foi anulada pelo software no computador host".
function Get-ArquivoComRetry {
    param([string] $Url, [string] $Destino, [int] $Tentativas = 4)
    for ($i = 1; $i -le $Tentativas; $i++) {
        Remove-Item $Destino -Force -ErrorAction SilentlyContinue
        foreach ($metodo in 'bits', 'iwr', 'wc') {
            try {
                switch ($metodo) {
                    'bits' {
                        if (-not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) { throw 'BITS indisponivel' }
                        Start-BitsTransfer -Source $Url -Destination $Destino -ErrorAction Stop
                    }
                    'iwr' { Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing -TimeoutSec 300 }
                    'wc'  { (New-Object Net.WebClient).DownloadFile($Url, $Destino) }
                }
                if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 10000) { return $true }
            } catch {
                Write-Host ("  {0} tentativa {1}/{2}: {3}" -f $metodo, $i, $Tentativas, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
        if ($i -lt $Tentativas) { Start-Sleep -Seconds (3 * $i) }
    }
    return $false
}

# Canal desta instalacao (gravado pelo instalador em config\canal).
if (-not $Branch) {
    $arqCanal = Join-Path $RaizApp 'config\canal'
    if (Test-Path $arqCanal) {
        try { $Branch = ([string] (Get-Content $arqCanal -Raw)).Trim() } catch { }
    }
    if (-not $Branch) { $Branch = 'homologacao' }
}
Write-Host "Atualizando: $RaizApp  (canal: $Branch)" -ForegroundColor Cyan

$temGit = (Test-Path (Join-Path $RaizApp '.git')) -and [bool](Get-Command git -ErrorAction SilentlyContinue)

if ($temGit) {
    Push-Location $RaizApp
    try {
        git fetch origin
        if ($Force) { git reset --hard ("origin/{0}" -f $Branch) }
        else {
            $sujo = git status --porcelain
            if ($sujo) { Write-Host "Ha alteracoes locais. Use -Force para descarta-las ou faca commit." -ForegroundColor Yellow; return }
            git checkout $Branch
            git pull --ff-only origin $Branch
        }
        Write-Host "git: agora em $(git rev-parse --short HEAD)" -ForegroundColor Green
    } finally { Pop-Location }
} else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-upd-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'branch.zip'
    Write-Host "Baixando $Repo/archive/refs/heads/$Branch.zip (~11 MB)"
    if (-not (Get-ArquivoComRetry -Url "$Repo/archive/refs/heads/$Branch.zip" -Destino $zip)) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw ("nao consegui baixar o codigo do canal '$Branch' (conexao instavel?). " +
               "Tente de novo com uma internet melhor, ou rode manualmente:`n" +
               "  iex (irm https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/$Branch/setup/Baixar-e-Instalar.ps1)")
    }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $novo = Get-ChildItem -Path $tmp -Directory | Where-Object { $_.Name -like 'Conectividade_Juntas_2026*' } | Select-Object -First 1
    if (-not $novo) { throw 'ZIP da branch nao extraiu como esperado.' }

    # pastas de codigo (+ iperf3, que agora vai no repo): espelha (remove sumidos)
    foreach ($d in 'src', 'lib\mahapps', 'assets', 'apps-script', 'docs', 'setup', 'bin\iperf3') {
        $orig = Join-Path $novo.FullName $d
        $dest = Join-Path $RaizApp $d
        if (-not (Test-Path $orig)) { continue }
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        robocopy $orig $dest /MIR /NJH /NJS /NFL /NDL /R:1 /W:1 | Out-Null
    }
    # arquivos soltos
    foreach ($f in 'Iniciar-Diagnostico.ps1', 'Iniciar-Diagnostico.bat', 'CLAUDE.md', 'README.md', '.gitignore') {
        $o = Join-Path $novo.FullName $f
        if (Test-Path $o) { Copy-Item $o (Join-Path $RaizApp $f) -Force }
    }
    # tools\*.ps1 (NUNCA tools\speedtest.exe)
    Get-ChildItem (Join-Path $novo.FullName 'tools') -Filter '*.ps1' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $RaizApp ('tools\' + $_.Name)) -Force }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "codigo atualizado a partir do ZIP." -ForegroundColor Green
}

Get-ChildItem -Path $RaizApp -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

$verNova = ''
try {
    $psm1 = Get-Content -Raw (Join-Path $RaizApp 'src\Conectividade.psm1') -ErrorAction Stop
    if ($psm1 -match "VersaoApp\s*=\s*'([^']+)'") { $verNova = $Matches[1] }
} catch { }

Write-Host ''
if ($verNova) { Write-Host ("Codigo agora na versao DICON v{0}." -f $verNova) -ForegroundColor Green }
Write-Host "Pronto. config\, data\, bin\geckodriver|chromedriver\ e resultados\ preservados; bin\iperf3\ atualizado." -ForegroundColor Green
Write-Host "Se o Chrome/Firefox mudou de versao, rode: .\setup\Instalar-DICON.ps1 -PularDeps:`$false -Force" -ForegroundColor DarkGray
Write-Host "Abrir: .\Iniciar-Diagnostico.bat" -ForegroundColor White
