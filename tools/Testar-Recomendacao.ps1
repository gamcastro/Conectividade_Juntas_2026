#Requires -Version 5.1
<#
    Testes de Get-ConexaoRecomendada (regra multi-meio). Nao abre janela.
    Roda: powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Testar-Recomendacao.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raiz = Split-Path $PSScriptRoot -Parent
. (Join-Path $raiz 'src\decisao\Invoke-MotorDecisao.ps1')

$falhas = 0
function Checar($nome, $cond, $detalhe) {
    if ($cond) { Write-Host "[ok]   $nome" }
    else { Write-Host "[FALHA] $nome  --  $detalhe"; $script:falhas++ }
}

function M {
    param($meio, $operadora = '', $veredito = 'nao_testado', $naoAplic = $false,
          $rlOk = $false, $rlDown = $null, $vpnOk = $false, $f2Ok = $false, $vpnDown = $null)
    [pscustomobject]@{
        meio = $meio; operadora = $operadora; nao_aplicavel = $naoAplic
        veredito = $veredito
        rede_local_ok = $rlOk; rede_local_download = $rlDown
        vpn_conectou = $vpnOk; fase2_ok = $f2Ok; vpn_download = $vpnDown
    }
}

# 1) LAN nao aplicavel; Wi-Fi local inviavel (VPN nao conectou); celular Vivo viavel_com_ressalva
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -naoAplic $true)
    (M 'wifi_local' -veredito 'inviavel' -rlOk $true -rlDown 30 -vpnOk $false)
    (M 'celular' -operadora 'Vivo' -veredito 'viavel_com_ressalva' -rlOk $true -rlDown 18 -vpnOk $true -f2Ok $true -vpnDown 12)
)
Checar 'cenario 1: recomenda o celular Vivo' ($r.meio -eq 'celular' -and $r.operadora -eq 'Vivo') $r.meio
Checar 'cenario 1: nao provisorio'            (-not $r.provisoria) "$($r.provisoria)"
Checar 'cenario 1: veredito = ressalva'       ($r.veredito -eq 'viavel_com_ressalva') $r.veredito

# 2) LAN viavel e Wi-Fi local viavel -> desempate por maior download VPN (LAN 40 > Wi-Fi 25)
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -veredito 'viavel' -rlOk $true -rlDown 90 -vpnOk $true -f2Ok $true -vpnDown 40)
    (M 'wifi_local' -veredito 'viavel' -rlOk $true -rlDown 80 -vpnOk $true -f2Ok $true -vpnDown 25)
)
Checar 'cenario 2: dois viaveis -> maior download VPN (LAN)' ($r.meio -eq 'lan') $r.meio

# 3) viavel (Wi-Fi, VPN down 15) vs ressalva (LAN, VPN down 50) -> veredito ganha do download
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -veredito 'viavel_com_ressalva' -rlOk $true -rlDown 90 -vpnOk $true -f2Ok $true -vpnDown 50)
    (M 'wifi_local' -veredito 'viavel'              -rlOk $true -rlDown 40 -vpnOk $true -f2Ok $true -vpnDown 15)
)
Checar 'cenario 3: viavel ganha de ressalva mesmo com download menor' ($r.meio -eq 'wifi_local') $r.meio

# 4) Ninguem fechou a VPN; Rede Local rodou (Wi-Fi 22 > LAN 8) -> provisorio, inviavel
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -veredito 'inviavel' -rlOk $true -rlDown 8  -vpnOk $false)
    (M 'wifi_local' -veredito 'inviavel' -rlOk $true -rlDown 22 -vpnOk $false)
)
Checar 'cenario 4: fallback Rede Local -> Wi-Fi (22 Mbps)' ($r.meio -eq 'wifi_local') $r.meio
Checar 'cenario 4: provisorio'                              ($r.provisoria) "$($r.provisoria)"
Checar 'cenario 4: base = rede_local'                       ($r.base -eq 'rede_local') $r.base
Checar 'cenario 4: veredito = inviavel'                     ($r.veredito -eq 'inviavel') $r.veredito

# 5) Nada rodou (todos nao aplicavel / nao testado) -> nenhuma
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -naoAplic $true)
    (M 'wifi_local' -veredito 'nao_testado')
    (M 'celular'    -veredito 'nao_testado')
)
Checar 'cenario 5: nada testado -> nenhuma' ($r.meio -eq 'nenhuma' -and $r.veredito -eq 'inviavel') $r.meio

# 6) So o Ookla rodou num meio, sem VPN em nenhum -> esse meio, provisorio
$r = Get-ConexaoRecomendada @(
    (M 'lan'        -naoAplic $true)
    (M 'wifi_local' -veredito 'inviavel' -rlOk $true -rlDown 15 -vpnOk $false)
    (M 'celular'    -operadora 'Claro' -veredito 'nao_testado')
)
Checar 'cenario 6: unico com Rede Local -> Wi-Fi provisorio' ($r.meio -eq 'wifi_local' -and $r.provisoria) $r.meio

Write-Host ''
if ($falhas -eq 0) { Write-Host 'RESULTADO: OK' -ForegroundColor Green }
else { Write-Host "RESULTADO: $falhas FALHA(S)" -ForegroundColor Red; exit 1 }
