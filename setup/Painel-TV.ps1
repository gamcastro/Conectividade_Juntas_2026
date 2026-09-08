# =============================================================================
#  DICON - Painel de TV (quiosque do Chrome) num comando.
#  (sem #Requires/param(): roda tambem via `iex (irm ...)`.)
#
#      iex (irm 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/setup/Painel-TV.ps1')
#
#  Cria: o .bat lancador (o Destino de um .lnk nao aguenta a URL longa; o .bat
#  aguenta), um atalho "Painel DICON TV" na Area de Trabalho de TODOS os
#  usuarios (precisa rodar como admin; senao cai no seu desktop) e, se pedido,
#  no Iniciar automatico. O login do Google fica salvo num perfil dedicado do
#  Chrome, isolado da navegacao normal.
#
#  Opcoes (definir ANTES do comando, todas opcionais):
#      $env:DICON_TV_AMBIENTE  = 'prod'    # 'prod' (padrao) | 'homolog'
#      $env:DICON_TV_TEMA      = 'escuro'  # 'escuro' (padrao) | 'claro'
#      $env:DICON_TV_ZOOM      = '7.2'     # zoom fixo do mapa (ex.: 6.5..8); vazio = automatico
#      $env:DICON_TV_AUTOSTART = '1'       # inicia junto com o Windows
#      $env:DICON_TV_DEST      = 'C:\dicon-tv'   # pasta do perfil + .bat
# =============================================================================
$ErrorActionPreference = 'Stop'

$WEBAPP = @{
    homolog = 'AKfycby4rGyTNWzgl6FxYkdAmnTQpO1zSsmolqJll6psftuH2S-SZQh76s6j2qLWYypZi6wM-w'
    prod    = 'AKfycbylhIAahOf0coAHwpOH2OCMbySmfeZR1feT-JFG5aw69GGrtRWYAnxtcL4b3carWYNy0w'
}
$amb  = ([string] $env:DICON_TV_AMBIENTE).ToLower(); if ($amb -ne 'homolog') { $amb = 'prod' }
$tema = ([string] $env:DICON_TV_TEMA).ToLower();     if ($tema -ne 'claro')   { $tema = 'escuro' }
$dest = if ($env:DICON_TV_DEST) { $env:DICON_TV_DEST } else { 'C:\dicon-tv' }
$zoom = ([string] $env:DICON_TV_ZOOM).Trim()
$url  = "https://script.google.com/a/macros/tre-ma.jus.br/s/$($WEBAPP[$amb])/exec?app=tv&tema=$tema"
if ($zoom -match '^\d+(\.\d+)?$') { $url += "&zoom=$zoom" }

Write-Host ("Painel de TV do DICON  --  {0}  --  tema {1}" -f $amb.ToUpper(), $tema) -ForegroundColor Cyan

# --- Chrome -------------------------------------------------------------------
$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Google Chrome nao encontrado. Instale o Chrome e rode de novo.' }

# --- pasta do perfil + .bat lancador ---------------------------------------
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$perfil = Join-Path $dest 'perfil'
$bat    = Join-Path $dest 'painel-tv.bat'
$linhaBat = ('@echo off' + "`r`n" +
    'start "" "' + $chrome + '" --user-data-dir="' + $perfil + '" --kiosk ' +
    '--app="' + $url + '" --noerrdialogs --disable-infobars ' +
    '--disable-session-crashed-bubble --overscroll-history-navigation=0' + "`r`n")
[IO.File]::WriteAllText($bat, $linhaBat, [Text.Encoding]::ASCII)
Write-Host "  [ok]  lancador: $bat" -ForegroundColor Green

# --- icone do DICON (baixa; se falhar, usa o do Chrome) -------------------
$ico = Join-Path $dest 'dicon.ico'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 `
        -Uri 'https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/main/assets/marca/dicon.ico' `
        -OutFile $ico
} catch { $ico = $null }

# --- atalho .lnk (aponta pro .bat) ----------------------------------------
function New-AtalhoLnk {
    param([string] $Lnk, [string] $Alvo, [string] $Icone)
    $dirLnk = Split-Path $Lnk -Parent
    if (-not (Test-Path $dirLnk)) { New-Item -ItemType Directory -Path $dirLnk -Force | Out-Null }
    $ws = New-Object -ComObject WScript.Shell
    $s  = $ws.CreateShortcut($Lnk)
    $s.TargetPath       = $Alvo
    $s.WorkingDirectory = Split-Path $Alvo -Parent
    $s.WindowStyle      = 7                          # minimizado (o cmd fecha na hora)
    $s.Description       = "Painel de TV do DICON ($amb)"
    if ($Icone) { $s.IconLocation = $Icone }
    $s.Save()
}

$nome  = 'Painel DICON TV.lnk'
$icone = if ($ico -and (Test-Path $ico)) { $ico } else { "$chrome,0" }
$feitos = New-Object System.Collections.Generic.List[string]

# 1) Area de Trabalho de TODOS os usuarios (precisa admin)
$deskPub = Join-Path $env:PUBLIC 'Desktop'
$deskUsr = [Environment]::GetFolderPath('Desktop')
$paraTodos = $false
try {
    New-AtalhoLnk (Join-Path $deskPub $nome) $bat $icone
    $feitos.Add((Join-Path $deskPub $nome)); $paraTodos = $true
} catch {
    New-AtalhoLnk (Join-Path $deskUsr $nome) $bat $icone
    $feitos.Add((Join-Path $deskUsr $nome))
    Write-Host "  [!]   sem permissao pro desktop de todos os usuarios -- criei so' no seu." -ForegroundColor Yellow
    Write-Host "        (rode este comando num PowerShell 'como administrador' pra valer pra todos)" -ForegroundColor DarkGray
}
# tira o atalho antigo do seu desktop se o novo foi pro de todos (evita duplicata quebrada)
if ($paraTodos) { Remove-Item (Join-Path $deskUsr $nome) -Force -ErrorAction SilentlyContinue }

# 2) Iniciar automatico
if ($env:DICON_TV_AUTOSTART -eq '1') {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-AtalhoLnk (Join-Path $startup $nome) $bat $icone
    $feitos.Add((Join-Path $startup $nome))
    Write-Host "  [ok]  vai iniciar junto com o Windows" -ForegroundColor Green
}

# --- energia: nao apagar a tela / nao suspender (best-effort) --------------
try {
    powercfg /change monitor-timeout-ac 0     | Out-Null
    powercfg /change standby-timeout-ac  0     | Out-Null
    Write-Host "  [ok]  tela/suspensao (na tomada): nunca" -ForegroundColor Green
} catch { }

Write-Host ''
$feitos | ForEach-Object { Write-Host "  Atalho: $_" -ForegroundColor Green }
Write-Host "  URL:    $url" -ForegroundColor DarkGray
Write-Host ''
Write-Host "Abra o atalho 'Painel DICON TV'. No 1o uso, faca o login do Google" -ForegroundColor White
Write-Host "(conta que esta' na aba Acesso). Para sair do quiosque: Alt+F4." -ForegroundColor White
