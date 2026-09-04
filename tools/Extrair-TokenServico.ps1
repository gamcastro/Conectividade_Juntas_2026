#Requires -Version 5.1
<#
.SYNOPSIS
    Imprime o refresh token da conta Google ja conectada nesta maquina (via
    Administracao > Conta Google > Conectar), para colar UMA VEZ no editor do
    Apps Script:

        setupServiceAuth('<client_id>', '<client_secret>', '<refresh_token>')

    client_id/client_secret = os mesmos de config/ambiente.json (ou .exemplo)
    > google_oauth. O Codigo.gs usa esse token pra gravar Resultados sempre
    "como George", nao importa qual tecnico chamou (ver docs/oauth-google.md).

.DESCRIPTION
    So funciona depois de "Conectar" com o escopo 'spreadsheets' (v0.6.73+).
    Nao imprime nada em log/arquivo -- so no console, pra colar direto.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

$rt = Get-RefreshTokenGoogle
if (-not $rt -or -not $rt.rt) {
    Write-Host 'Nenhuma conta Google conectada nesta maquina.' -ForegroundColor Red
    Write-Host 'Abra o DICON -> Administracao -> Conta Google -> Conectar, e rode de novo.' -ForegroundColor Yellow
    exit 1
}

$cfg = Get-ConfigOAuth
Write-Host ''
Write-Host "Conta conectada : $($rt.email)" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Cole no editor do Apps Script (Executar > setupServiceAuth), com os 3 argumentos:'
Write-Host ''
Write-Host "  setupServiceAuth(" -NoNewline
Write-Host "'$($cfg.client_id)', " -NoNewline -ForegroundColor Green
Write-Host "'$($cfg.client_secret)', " -NoNewline -ForegroundColor Green
Write-Host "'$($rt.rt)'" -NoNewline -ForegroundColor Green
Write-Host ")"
Write-Host ''
Write-Host 'O refresh token acima da acesso de leitura/escrita as planilhas do Google' -ForegroundColor Yellow
Write-Host 'Sheets desta conta -- nao cole em nenhum outro lugar alem do editor do Apps Script.' -ForegroundColor Yellow
