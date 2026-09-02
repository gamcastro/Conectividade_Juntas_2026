#Requires -Version 5.1
# Cria/atualiza o atalho do DICON na area de trabalho do usuario atual, com o
# icone da marca (assets\marca\dicon.ico). Idempotente. Nome do atalho segue o
# canal (config\canal): "DICON" para producao, "DICON (Homologacao)" para homolog.
# Chamado pelo Instalar-DICON.ps1 e pelo Baixar-e-Instalar.ps1; roda sozinho tambem.
$ErrorActionPreference = 'Stop'

$raiz = Split-Path $PSScriptRoot -Parent

$canal = ''
try { $canal = ([string] (Get-Content (Join-Path $raiz 'config\canal') -Raw -ErrorAction Stop)).Trim() } catch { }
$nome = if ($canal -eq 'homologacao') { 'DICON (Homologacao)' } else { 'DICON' }

try {
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if (-not $desktop -or -not (Test-Path $desktop)) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    $lnk   = Join-Path $desktop ($nome + '.lnk')
    $icone = Join-Path $raiz 'assets\marca\dicon.ico'

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath       = Join-Path $raiz 'Iniciar-Diagnostico.bat'
    $sc.WorkingDirectory = $raiz
    $sc.WindowStyle      = 7   # minimizado: o console nao "pisca" na tela
    $sc.Description       = "DICON - Diagnostico de Conectividade ($nome)"
    if (Test-Path $icone) { $sc.IconLocation = "$icone,0" }
    $sc.Save()
    Write-Host "  [ok]   atalho: $lnk" -ForegroundColor Green
} catch {
    Write-Host "  [!]    nao consegui criar o atalho ($_)" -ForegroundColor Yellow
}
