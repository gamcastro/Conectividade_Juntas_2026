#Requires -Version 5.1
<#
.SYNOPSIS
    Prepara a pasta do DICON num computador/notebook standalone: destrava os
    arquivos baixados, cria as pastas de runtime, materializa as configuracoes,
    define o PIN do administrador e baixa os binarios de terceiros.

.EXAMPLE
    .\setup\Instalar-DICON.ps1
        Modo interativo (pergunta endpoint, PIN e servidor iperf3).

.EXAMPLE
    .\setup\Instalar-DICON.ps1 -Endpoint "https://script.google.com/macros/s/XXX/exec" -Pin 1234 -IperfServidor 10.11.9.20

.EXAMPLE
    .\setup\Instalar-DICON.ps1 -SoConfig
        So configuracoes + PIN (nao baixa binarios).

.EXAMPLE
    .\setup\Instalar-DICON.ps1 -DepsZip C:\pendrive\DICON-deps.zip
        Instala os binarios a partir de um zip preparado (uso offline).
#>
[CmdletBinding()]
param(
    [string] $Endpoint,
    [string] $Pin,
    [string] $IperfServidor,
    [string] $DepsZip,
    [switch] $PularDeps,
    [switch] $SoConfig,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$RaizApp = Split-Path $PSScriptRoot -Parent
$Cfg     = Join-Path $RaizApp 'config'
$Tmp     = Join-Path ([IO.Path]::GetTempPath()) ('dicon-setup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
$faltando = New-Object System.Collections.Generic.List[string]

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function OK($t)     { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Aviso($t)  { Write-Host "  [!]    $t" -ForegroundColor Yellow }
function Erro($t)   { Write-Host "  [x]    $t" -ForegroundColor Red }

# ---------------------------------------------------------------- pre-requisitos
Titulo 'Pre-requisitos'
Write-Host "  Pasta: $RaizApp"
if ($PSVersionTable.PSVersion.Major -lt 5) { Erro "PowerShell $($PSVersionTable.PSVersion) - precisa de 5.1+"; exit 1 }
OK "PowerShell $($PSVersionTable.PSVersion)"
try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; OK 'WPF (.NET Framework) disponivel' }
catch { Aviso 'WPF nao carregou - a interface pode nao abrir neste Windows.' }

# ---------------------------------------------------------------- destrava (MOTW)
Titulo 'Destravando arquivos baixados (Mark of the Web)'
Get-ChildItem -Path $RaizApp -Recurse -File -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue
OK 'Unblock-File aplicado na pasta'

# ---------------------------------------------------------------- pastas runtime
Titulo 'Pastas de runtime'
foreach ($d in 'bin\iperf3', 'bin\geckodriver', 'bin\chromedriver', 'lib\Selenium',
    'data', 'resultados\pendentes', 'resultados\enviados', 'relatorios', 'logs') {
    $p = Join-Path $RaizApp $d
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
OK 'bin\, data\, resultados\, relatorios\, logs\ prontas'

# ---------------------------------------------------------------- configuracoes
Titulo 'Configuracoes (config\*.json)'
Get-ChildItem -Path $Cfg -Filter '*.exemplo.json' | ForEach-Object {
    $real = $_.FullName -replace '\.exemplo\.json$', '.json'
    if (-not (Test-Path $real)) {
        Copy-Item $_.FullName $real
        OK "criado $(Split-Path $real -Leaf) (a partir do exemplo)"
    } else {
        Write-Host "  ...    $(Split-Path $real -Leaf) ja existe (mantido)"
    }
}

function Set-JsonCampo {
    param([string] $Arquivo, [string] $Caminho, $Valor)
    if (-not (Test-Path $Arquivo)) { return }
    $doc = Get-Content -Path $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
    $partes = $Caminho -split '\.'
    $alvo = $doc
    for ($i = 0; $i -lt $partes.Count - 1; $i++) { $alvo = $alvo.$($partes[$i]) }
    $alvo.$($partes[-1]) = $Valor
    $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $Arquivo -Encoding UTF8
}

if (-not $Endpoint) {
    $atual = ''
    try { $atual = (Get-Content (Join-Path $Cfg 'juntas.json') -Raw -Encoding UTF8 | ConvertFrom-Json).endpoint } catch { }
    Write-Host ''
    $Endpoint = Read-Host "  URL /exec do Web App (Enter para manter '$atual')"
}
if ($Endpoint -and $Endpoint -notlike '*COLOQUE_O_ID*') {
    Set-JsonCampo (Join-Path $Cfg 'juntas.json') 'endpoint' $Endpoint
    Set-JsonCampo (Join-Path $Cfg 'envio.json')  'endpoint_apps_script' $Endpoint
    OK "endpoint do Web App gravado"
} else {
    Aviso "endpoint nao configurado - ajuste config\juntas.json e config\envio.json depois"
}

if (-not $IperfServidor) {
    Write-Host ''
    $IperfServidor = Read-Host "  IP/host do servidor iperf3 no CPD (Enter para pular)"
}
if ($IperfServidor) {
    Set-JsonCampo (Join-Path $Cfg 'ambiente.json') 'iperf3.servidor' $IperfServidor
    Set-JsonCampo (Join-Path $Cfg 'ambiente.json') 'ping.alvo'       $IperfServidor
    OK "servidor iperf3 = $IperfServidor (editavel depois na tela de Administracao)"
}

# ---------------------------------------------------------------- PIN admin
Titulo 'PIN do administrador'
$arqAdmin = Join-Path $Cfg 'admin.json'
$precisaPin = $Force -or $Pin -or -not (Test-Path $arqAdmin)
if ($precisaPin) {
    if (-not $Pin) {
        $s1 = Read-Host -AsSecureString '  Novo PIN (4-6 digitos)'
        $s2 = Read-Host -AsSecureString '  Repita o PIN'
        $Pin  = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
        $pinB = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
        if ($Pin -ne $pinB) { Erro 'os PINs nao conferem - rode o setup de novo'; exit 1 }
    }
    if ($Pin -notmatch '^\d{4,6}$') { Erro 'o PIN deve ter de 4 a 6 digitos'; exit 1 }
    $sha  = [Security.Cryptography.SHA256]::Create()
    try { $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Pin)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    [pscustomobject]@{ pin_sha256 = $hash } | ConvertTo-Json | Set-Content -Path $arqAdmin -Encoding UTF8
    OK "PIN gravado em config\admin.json"
    Write-Host "  (Web App: cadastre a propriedade ADMIN_PIN_SHA256 = $hash no Apps Script)" -ForegroundColor DarkGray
} else {
    Write-Host "  ...    config\admin.json ja existe (use -Force para redefinir)"
}

# ---------------------------------------------------------------- binarios
if ($SoConfig -or $PularDeps) {
    Titulo 'Binarios de terceiros'
    Aviso 'pulado (-SoConfig / -PularDeps). Coloque a mao: tools\speedtest.exe e bin\iperf3\iperf3.exe'
} else {
    Titulo 'Binarios de terceiros'
    $man = Get-Content (Join-Path $PSScriptRoot 'dependencias.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    function Instalar-Dep {
        param($Dep, [string] $ZipLocal)
        $destDir = Join-Path $RaizApp ($Dep.destino -replace '/', '\')
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $primeiro = @($Dep.extrair)[0] -replace '\*', ''
        $jaTem = Get-ChildItem -Path $destDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ("*{0}*" -f ($primeiro.TrimStart('.','/'))) }
        if ($jaTem -and -not $Force) { Write-Host "  ...    $($Dep.nome) ja instalado (mantido)"; return }

        $zip = $ZipLocal
        if (-not $zip) {
            $url = [string] $Dep.url
            if ($Dep.tipo -eq 'nupkg' -or $url -match '^https?://') { }
            elseif ($url -eq 'chrome-for-testing') {
                $url = Get-UrlChromeDriver
            }
            elseif ($url -like 'github:*') {
                $partes = $url.Substring(7) -split ':'
                $rel = Invoke-RestMethod "https://api.github.com/repos/$($partes[0])/releases/latest" -Headers @{ 'User-Agent' = 'DICON-setup' }
                $url = ($rel.assets | Where-Object { $_.name -like ("*{0}" -f $partes[1]) } | Select-Object -First 1).browser_download_url
            }
            if (-not $url) {
                Erro "$($Dep.nome): sem URL. Baixe de $($Dep.pagina) e coloque em $($Dep.destino)"
                $faltando.Add("$($Dep.nome)  ->  $($Dep.destino)  (pagina: $($Dep.pagina))")
                return
            }
            $zip = Join-Path $Tmp ("{0}{1}" -f $Dep.id, $(if ($Dep.tipo -eq 'nupkg') { '.zip' } else { '.zip' }))
            try {
                Write-Host "  ...    baixando $($Dep.nome)"
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 120
            } catch {
                Erro "$($Dep.nome): download falhou ($_). Baixe de $($Dep.pagina) e coloque em $($Dep.destino)"
                $faltando.Add("$($Dep.nome)  ->  $($Dep.destino)  (pagina: $($Dep.pagina))")
                return
            }
        }
        if ($Dep.sha256) {
            $h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
            if ($h -ne ([string] $Dep.sha256).ToLower()) { Erro "$($Dep.nome): SHA-256 nao confere"; return }
        }
        $ext = Join-Path $Tmp ("x-" + $Dep.id)
        if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $ext -Force
        foreach ($padrao in $Dep.extrair) {
            $achou = Get-ChildItem -Path $ext -Recurse -File -Filter (Split-Path $padrao -Leaf) -ErrorAction SilentlyContinue
            foreach ($f in $achou) { Copy-Item $f.FullName (Join-Path $destDir $f.Name) -Force }
        }
        Get-ChildItem -Path $destDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        OK "$($Dep.nome) -> $($Dep.destino)"
    }

    function Get-UrlChromeDriver {
        $chrome = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $chrome) { Aviso 'Chrome nao encontrado - chromedriver pulado'; return $null }
        $ver = (Get-Item $chrome).VersionInfo.ProductVersion
        $maj = ($ver -split '\.')[0]
        try {
            $j = Invoke-RestMethod 'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json'
            $cand = $j.versions | Where-Object { ($_.version -split '\.')[0] -eq $maj -and $_.downloads.chromedriver } |
                Select-Object -Last 1
            if (-not $cand) { $cand = $j.versions | Where-Object { $_.downloads.chromedriver } | Select-Object -Last 1 }
            return ($cand.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).url
        } catch { Aviso "chromedriver: nao resolveu ($_)"; return $null }
    }

    if ($DepsZip) {
        if (-not (Test-Path $DepsZip)) { Erro "DepsZip nao encontrado: $DepsZip"; }
        else {
            $raizDeps = Join-Path $Tmp 'deps'
            Expand-Archive -Path $DepsZip -DestinationPath $raizDeps -Force
            foreach ($sub in 'tools', 'bin', 'lib') {
                $o = Join-Path $raizDeps $sub
                if (Test-Path $o) { Copy-Item (Join-Path $o '*') (Join-Path $RaizApp $sub) -Recurse -Force }
            }
            Get-ChildItem -Path $RaizApp -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
            OK "binarios copiados de $DepsZip"
        }
    } else {
        foreach ($d in $man.dependencias) { Instalar-Dep -Dep $d }
    }
}

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- resumo
Titulo 'Resumo'
$checa = @(
    @{ n = 'speedtest.exe (Fase 1)'; p = 'tools\speedtest.exe' }
    @{ n = 'iperf3.exe (Fase 2)';    p = 'bin\iperf3\iperf3.exe' }
    @{ n = 'config\admin.json';      p = 'config\admin.json' }
    @{ n = 'config\juntas.json';     p = 'config\juntas.json' }
)
foreach ($c in $checa) {
    if (Test-Path (Join-Path $RaizApp $c.p)) { OK $c.n } else { Aviso "$($c.n) - AUSENTE ($($c.p))" }
}
if ($faltando.Count) {
    Write-Host ''
    Write-Host '  Baixe a mao e coloque na pasta:' -ForegroundColor Yellow
    $faltando | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host 'Setup concluido. Para abrir a ferramenta:' -ForegroundColor Green
Write-Host '    .\Iniciar-Diagnostico.bat' -ForegroundColor White
Write-Host 'Na 1a vez, com internet, clique em "Atualizar dados" para baixar a lista das Juntas.' -ForegroundColor Green
