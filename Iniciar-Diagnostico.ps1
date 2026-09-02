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
    [string] $JuntaId,
    # guardas anti-loop: setados no proprio relaunch, NAO passar a mao.
    [switch] $StaFeito,
    [switch] $ElevacaoFeita
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Reencaminhamento dos parametros no relaunch STA / elevacao UAC. NAO usar
# $args: em script [CmdletBinding()] + StrictMode Latest ele nao existe e
# lanca "A variavel '$args' nao pode ser recuperada" (sessao de usuario comum).
$fwdArgs = @()
if ($SemUI)   { $fwdArgs += '-SemUI' }
if ($JuntaId) { $fwdArgs += @('-JuntaId', $JuntaId) }

# --- 1. Garante STA (pwsh roda como MTA por padrao) --------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $StaFeito) {
    $exe = (Get-Process -Id $PID).Path
    $lista = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $PSCommandPath), '-StaFeito') + $fwdArgs
    Start-Process -FilePath $exe -ArgumentList $lista
    return
}

# --- 2. Auto-elevacao UAC (best-effort; NUNCA em loop) --------------------
. "$PSScriptRoot\src\core\Elevacao.ps1"
if (-not (Test-Administrador)) {
    if (-not $ElevacaoFeita -and (Test-PodeElevar)) {
        if (Invoke-AutoElevacao -Script $PSCommandPath -Argumentos (@('-StaFeito', '-ElevacaoFeita') + $fwdArgs)) {
            return   # a instancia elevada assume
        }
    }
    Write-Warning ('DICON sem privilegio de administrador. O diagnostico funciona ' +
        'normalmente; conecte o Wi-Fi do local pela bandeja do Windows.')
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
