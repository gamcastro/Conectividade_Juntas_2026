#Requires -Version 5.1
<#
.SYNOPSIS
    Abre a janela WPF isolada, para desenvolvimento da interface.

.DESCRIPTION
    Nao faz auto-elevacao UAC. Forca modo STA.

.PARAMETER SoLayout
    Pre-popula o log com uma linha de cada nivel de cor (para ajustar cores).

.PARAMETER Seed
    Se faltar algum cache (data/juntas|tecnicos|roteiros.json), baixa os dados
    reais do Web App (endpoint de config/juntas.json).

.PARAMETER Sair
    Comeca deslogado (remove data/sessao.json), abrindo a tela de login.
#>
[CmdletBinding()]
param(
    [switch] $SoLayout,
    [switch] $Seed,
    [switch] $Sair
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe   = (Get-Process -Id $PID).Path
    $lista = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($SoLayout) { $lista += '-SoLayout' }
    if ($Seed)     { $lista += '-Seed' }
    if ($Sair)     { $lista += '-Sair' }
    Start-Process -FilePath $exe -ArgumentList $lista -Wait
    return
}

$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null

Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

if ($Sair) {
    $s = Join-Path $Global:RaizApp 'data\sessao.json'
    if (Test-Path $s) { Remove-Item $s -Force }
}

if ($Seed) {
    $faltando = @('juntas', 'tecnicos', 'roteiros') | Where-Object {
        -not (Test-Path (Join-Path $Global:RaizApp "data\$_.json"))
    }
    if ($faltando.Count) {
        Write-Host "[Testar-Gui] baixando dados ($($faltando -join ', '))..."
        Sync-TudoOnline | Out-Null
    }
}

if ($SoLayout) {
    foreach ($n in 'Destaque', 'Info', 'Neutro', 'Ok', 'Aviso', 'Erro') {
        Write-Log "Linha de exemplo no nivel $n" -Nivel $n
    }
}

Show-JanelaPrincipal
