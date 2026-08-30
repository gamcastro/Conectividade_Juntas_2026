#Requires -Version 5.1
<#
.SYNOPSIS
    Define o PIN do administrador (George Andre Melo Castro): pede o PIN e grava
    o hash SHA-256 em config/admin.json.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Global:RaizApp = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

$pin  = Read-Host -AsSecureString 'Novo PIN do administrador (4-6 digitos)'
$pin2 = Read-Host -AsSecureString 'Repita o PIN'

$b1 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin))
$b2 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pin2))

if ($b1 -ne $b2)               { Write-Host 'Os PINs nao conferem.' -ForegroundColor Red; exit 1 }
if ($b1 -notmatch '^\d{4,6}$') { Write-Host 'O PIN deve ter de 4 a 6 digitos.' -ForegroundColor Red; exit 1 }

$hash = Get-HashPin $b1
$destino = Join-Path $Global:RaizApp 'config\admin.json'
[pscustomobject]@{ pin_sha256 = $hash } | ConvertTo-Json | Set-Content -Path $destino -Encoding UTF8

Write-Host "PIN gravado em $destino" -ForegroundColor Green
Write-Host ""
Write-Host "Para o Web App aceitar 'Salvar limiares', cadastre UMA VEZ a propriedade" -ForegroundColor Yellow
Write-Host "no editor do Apps Script:" -ForegroundColor Yellow
Write-Host "  Engrenagem 'Configuracoes do projeto' > Propriedades do script >" -ForegroundColor Yellow
Write-Host "  Adicionar propriedade:" -ForegroundColor Yellow
Write-Host "    Propriedade : ADMIN_PIN_SHA256" -ForegroundColor Cyan
Write-Host "    Valor       : $hash" -ForegroundColor Cyan
