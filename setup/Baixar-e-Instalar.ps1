# =============================================================================
#  DICON - baixar + extrair + instalar num comando.
#  (sem #Requires/param(): este script tambem roda via `iex (irm ...)`.)
#
#  HOMOLOGACAO (padrao desta copia, branch homologacao):
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/homologacao/setup/Baixar-e-Instalar.ps1')
#  PRODUCAO (a copia em main tem $CanalPadrao = 'main'):
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/setup/Baixar-e-Instalar.ps1')
#
#  Pasta padrao: C:\Aplic\DICON  (producao)  /  C:\Aplic\DICON-HOMOLOG  (homolog).
#  Cria C:\Aplic se nao existir (usuario comum consegue criar na raiz do C:).
#  Se nao der, cai em %LOCALAPPDATA%\DICON[-HOMOLOG]. Sobrescreve com $env:DICON_DEST.
#
#  O deploymentId do Apps Script (implantacao "Executavel de API") ja vem
#  embutido por canal ($DeploymentIdPadrao); so precisa de
#  $env:DICON_DEPLOYMENT_ID para apontar para outro projeto.
#
#  Outras opcoes (definir ANTES do comando, todas opcionais):
#      $env:DICON_BRANCH        = 'main'    # forca o canal
#      $env:DICON_DEPLOYMENT_ID = '...'     # outro deploymentId do Apps Script
#      $env:DICON_PIN           = '1234'    # PIN do admin
#      $env:DICON_IPERF         = '10.11.9.20'   # servidor iperf3
#      $env:DICON_DEPSZIP       = 'D:\pen\DICON-deps.zip'
#
#  NAO usa param()/[CmdletBinding()] de proposito: isso quebra o `iex (irm ...)`.
# =============================================================================
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

# Canal + deploymentId do Apps Script desta copia (chamado pela Execution API,
# script.googleapis.com/v1/scripts/{deploymentId}:run -- ver docs/oauth-google.md).
# Na branch 'main' estes dois valores sao 'main' e o deploymentId de PRODUCAO
# (o merge homologacao->main resolve o conflito mantendo os valores de 'main').
# NAO e' o deploymentId da URL /exec antiga (essa ficou congelada, anonima, pra
# clientes que ainda nao atualizaram -- ver apps-script/CLASP.md "dois
# deployments em producao").
$CanalPadrao        = 'main'
$DeploymentIdPadrao = 'AKfycbya1hdu7dgLzXd8U2Totm8cffCtiAnIjJptppe7AuxfvbuHhkNGOAXlCa90QCE_-HOApQ'

function Save-ZipRemoto {
    param([string] $Url, [string] $OutFile, [int] $Tentativas = 3)
    for ($i = 1; $i -le $Tentativas; $i++) {
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 180; return $true }
        catch { if ($i -lt $Tentativas) { Start-Sleep 3 } }
    }
    return $false
}

# Extrai um .zip/.nupkg de forma resiliente contra antivirus corporativo
# (Trend/etc.) que trava arquivos recem-escritos:
#  - itera entrada por entrada (System.IO.Compression), com retentativa por
#    arquivo, e PULA os dotfiles do repo (.gitattributes/.gitignore/.git*) que
#    o DICON nao usa e que sao justamente os que o AV costuma segurar;
#  - tolera algumas falhas isoladas em vez de abortar tudo;
#  - Expand-Archive so' de reserva (engole o erro de limpeza dos .nupkg).
function Expand-ZipSafe {
    param([string] $Zip, [string] $Destino, [int] $Tentativas = 6)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    if (Test-Path $Destino) { Remove-Item $Destino -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null

    $za = $null
    try { $za = [System.IO.Compression.ZipFile]::OpenRead($Zip) } catch { $za = $null }
    if ($za) {
        $okCount = 0; $falhas = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($ent in $za.Entries) {
                if (-not $ent.Name) { continue }                 # entrada de diretorio
                if ($ent.Name -match '^\.git') { continue }      # .gitattributes/.gitignore/... -> pula
                $alvo = Join-Path $Destino ($ent.FullName -replace '/', '\')
                $dir  = Split-Path $alvo -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $feito = $false
                for ($t = 1; $t -le $Tentativas -and -not $feito; $t++) {
                    try {
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $alvo, $true)
                        $feito = $true; $okCount++
                    } catch {
                        if ($t -lt $Tentativas) { Start-Sleep -Milliseconds (250 * $t) }
                    }
                }
                if (-not $feito) { $falhas.Add($ent.FullName) }
            }
        } finally { $za.Dispose() }
        if ($falhas.Count) { Write-Host ("  [!]    {0} arquivo(s) nao extraido(s) (antivirus?): {1}" -f $falhas.Count, ($falhas -join ', ')) -ForegroundColor DarkYellow }
        if ($okCount -gt 0) { return }
    }

    # reserva
    try { Expand-Archive -Path $Zip -DestinationPath $Destino -Force -ErrorAction Stop } catch { }
    if (Get-ChildItem -Path $Destino -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return }
    throw ("nao consegui extrair " + (Split-Path $Zip -Leaf) + " -- o antivirus esta' bloqueando. " +
           "Peca a exclusao de C:\Aplic e da pasta Temp no console do antivirus, ou instale o Git for Windows.")
}

# A pasta (ou o pai dela) e gravavel por este usuario?
function Test-CaminhoGravavel {
    param([string] $Dir)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Dir ('.w-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# Pasta padrao por canal: C:\Aplic\... (cria C:\Aplic se der); senao %LOCALAPPDATA%.
function Get-DestPadrao {
    param([string] $Canal)
    $nome  = if ($Canal -eq 'main') { 'DICON' } else { 'DICON-HOMOLOG' }
    $cands = @(
        (Join-Path 'C:\Aplic' $nome)
        (Join-Path $env:LOCALAPPDATA $nome)   # sempre gravavel pelo usuario
    )
    foreach ($c in $cands) {
        if (Test-CaminhoGravavel (Split-Path $c -Parent)) { return $c }
    }
    return $cands[-1]
}

# Test-Path que nao estoura em "Acesso negado" (pasta de outro usuario/admin).
function Test-PathSeguro {
    param([string] $Caminho)
    try { return [bool] (Test-Path -LiteralPath $Caminho) } catch { return $null }
}

$Branch       = if ($env:DICON_BRANCH) { $env:DICON_BRANCH } else { $CanalPadrao }
$Dest         = if ($env:DICON_DEST)   { $env:DICON_DEST }   else { Get-DestPadrao $Branch }
$DeploymentId = if ($env:DICON_DEPLOYMENT_ID) { $env:DICON_DEPLOYMENT_ID } else { $DeploymentIdPadrao }
$Pin          = [string] $env:DICON_PIN
$Iperf    = [string] $env:DICON_IPERF
$DepsZip  = [string] $env:DICON_DEPSZIP
$Repo     = 'https://github.com/gamcastro/Conectividade_Juntas_2026'
$OoklaZip = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'

# --- 1. codigo: instala do zero ou atualiza o que ja existe --------------------
$temSrc = Test-PathSeguro (Join-Path $Dest 'src')
if ($null -eq $temSrc -and -not $env:DICON_DEST) {
    $alt = Join-Path $env:LOCALAPPDATA (Split-Path $Dest -Leaf)
    Write-Host "Sem acesso a '$Dest'. Instalando em '$alt'." -ForegroundColor Yellow
    Write-Host "  (para usar '$Dest', rode antes o Preparar-Maquina.ps1 como admin)" -ForegroundColor DarkGray
    $Dest   = $alt
    $temSrc = Test-PathSeguro (Join-Path $Dest 'src')
}
if ($null -eq $temSrc) {
    Write-Host "Sem acesso a '$Dest'. Defina `$env:DICON_DEST para uma pasta gravavel e rode de novo." -ForegroundColor Red
    return
}
if ($temSrc) {
    Write-Host "Ja existe um DICON em $Dest - atualizando o codigo (Atualizar-DICON -Force)." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'setup\Atualizar-DICON.ps1') -Force -Branch $Branch
} else {
    Write-Host ("DICON: baixando a branch '{0}' para {1}" -f $Branch, $Dest) -ForegroundColor Cyan
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dicon-boot-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $srcDir = $null
    $temGit = [bool] (Get-Command git -ErrorAction SilentlyContinue)

    # 1o tenta 'git clone' -- nao passa por Expand-Archive e o git.exe costuma
    # estar na allowlist do antivirus (o ZIP -> Expand-Archive trava em
    # '.gitattributes em uso'). Deixa o .git pra o Atualizar-DICON usar 'git pull'.
    if ($temGit) {
        try {
            $clone = Join-Path $tmp 'repo'
            Write-Host "  (via git clone)" -ForegroundColor DarkGray
            git clone --quiet --branch $Branch --single-branch "$Repo.git" $clone 2>&1 | Out-Null
            if ((Test-Path (Join-Path $clone 'src')) -and (Test-Path (Join-Path $clone '.git'))) { $srcDir = Get-Item $clone }
        } catch { $srcDir = $null }
    }

    # 2o cai no ZIP + Expand-ZipSafe
    if (-not $srcDir) {
        $zip = Join-Path $tmp 'dicon.zip'
        if (-not (Save-ZipRemoto "$Repo/archive/refs/heads/$Branch.zip" $zip)) { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue; throw "nao consegui baixar o codigo ($Branch)." }
        Unblock-File $zip -ErrorAction SilentlyContinue
        $extr = Join-Path $tmp 'x'
        try { Expand-ZipSafe -Zip $zip -Destino $extr }
        catch {
            Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
            throw ("$_`n`nO antivirus esta' travando os arquivos durante a extracao. " +
                   "Adicione C:\Aplic e a pasta Temp nas exclusoes do Windows Defender " +
                   "(ou pause a protecao em tempo real) e rode o comando de novo.")
        }
        $srcDir = Get-ChildItem $extr -Directory | Where-Object { $_.Name -like 'Conectividade_Juntas_2026*' } | Select-Object -First 1
        if (-not $srcDir) { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue; throw 'o ZIP da branch nao extraiu como esperado.' }
    }

    try {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        robocopy $srcDir.FullName $Dest /E /NFL /NDL /NJH /NJS /NP /R:3 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falhou (codigo $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
        Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Codigo em $Dest." -ForegroundColor Green
}

# --- marcador de canal: Atualizar-DICON.ps1 le daqui pra saber de onde puxar --
try {
    $cfgDir = Join-Path $Dest 'config'
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    Set-Content -Path (Join-Path $cfgDir 'canal') -Value $Branch -Encoding ascii -NoNewline
    Write-Host "Canal desta instalacao: $Branch" -ForegroundColor Green
} catch { }

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
    # garante/atualiza o atalho na area de trabalho (o setup nao roda de novo)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'setup\Criar-Atalho.ps1')
    Write-Host "Abrir: cd '$Dest'; .\Iniciar-Diagnostico.bat" -ForegroundColor White
} else {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dest 'setup\Instalar-DICON.ps1'))
    if ($DeploymentId) { $psArgs += @('-DeploymentId', $DeploymentId) }
    if ($Pin)          { $psArgs += @('-Pin', $Pin) }
    if ($Iperf)    { $psArgs += @('-IperfServidor', $Iperf) }
    if ($DepsZip)  { $psArgs += @('-DepsZip', $DepsZip) }
    Write-Host ''
    Write-Host 'Rodando o setup...' -ForegroundColor Cyan
    Set-Location $Dest
    & powershell.exe @psArgs
}
