#Requires -Version 5.1
<#
.SYNOPSIS
    Ponto de entrada do diagnostico de conectividade das Juntas Eleitorais
    Especiais 2026 (TRE-MA).

.DESCRIPTION
    Garante modo STA (exigido pelo WPF), faz auto-elevacao UAC quando necessario,
    ajusta o encoding para UTF-8, importa o modulo e abre a janela principal.

.PARAMETER SemUI
    Executa a bateria completa em modo texto, sem abrir a interface. Exige -JuntaId.

.PARAMETER JuntaId
    Id do local (ex.: ZE6-SENADOR_ALEXANDRE_COSTA-PRINCIPAL), conforme o cache
    data/juntas.json. Use Get-Juntas para listar. So e usado com -SemUI.
#>
[CmdletBinding()]
param(
    [switch] $SemUI,
    [string] $JuntaId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- 1. Garante STA (pwsh roda como MTA por padrao) --------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    $lista = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $PSCommandPath)) + $args
    Start-Process -FilePath $exe -ArgumentList $lista
    return
}

# --- 2. Auto-elevacao UAC ---------------------------------------------------
. "$PSScriptRoot\src\core\Elevacao.ps1"
if (-not (Test-Administrador)) {
    Invoke-AutoElevacao -Script $PSCommandPath -Argumentos $args
    return
}

# --- 3. Encoding UTF-8 -----------------------------------------------------
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [Text.UTF8Encoding]::new($false)
} catch { }

# --- 4. Contexto e modulo ------------------------------------------------
$Global:RaizApp = $PSScriptRoot
$rotuloLog = if ($JuntaId) { $JuntaId -replace '[^\w\-]', '_' } else { 'sessao' }
$Global:ArquivoLog = Join-Path $PSScriptRoot ('logs\{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $rotuloLog)
$pastaLog = Split-Path $Global:ArquivoLog -Parent
if (-not (Test-Path $pastaLog)) { New-Item -ItemType Directory -Path $pastaLog -Force | Out-Null }

Import-Module "$PSScriptRoot\src\Conectividade.psd1" -Force
Write-Host ("DICON v{0}" -f $Global:VersaoApp) -ForegroundColor Cyan

# --- 5. Dispara ---------------------------------------------------------
if ($SemUI) {
    if (-not $JuntaId) { throw "Modo -SemUI exige -JuntaId. Rode Get-Juntas para listar os ids." }
    $junta = Get-JuntaPorId -Id $JuntaId
    if (-not $junta) { throw "Junta '$JuntaId' nao encontrada em data/juntas.json. Rode Sync-Juntas com internet." }
    $p = Invoke-DiagnosticoCompleto -Local $junta
    Save-Diagnostico -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local -TecnicoNome ''
} else {
    Show-JanelaPrincipal
}
