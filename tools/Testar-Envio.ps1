#Requires -Version 5.1
<#
.SYNOPSIS
    Teste do envio de resultados (src/saida/Send-Resultado.ps1) contra um
    HttpListener local que simula a Apps Script Execution API
    (script.googleapis.com/v1/scripts/{id}/run, envelope {done,response.result}).
    Valida que o arquivo so migra para resultados\enviados\ quando a resposta
    interna e {status:'ok'} -- e permanece em resultados\pendentes\ quando o
    servidor recusa (erro / ignorado).
#>
[CmdletBinding()]
param(
    [int] $Porta = 8477
)

$ErrorActionPreference = 'Stop'
$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null

Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

# liga o header OAuth sem precisar de um /token real: token ja "em cache" e
# valido, Get-CabecalhoAuthWebApp devolve Bearer direto (ver Get-TokenGoogle).
$Global:OAuthConfigOverride = @{ enabled = $true; client_id = 'cid.apps.googleusercontent.com'; client_secret = 'sec'; scopes = 'openid' }
$Global:GoogleToken = @{ access = 'AT-teste'; expira_em = (Get-Date).AddHours(1); email = 'teste@tre-ma.jus.br' }

$pendDir = Join-Path $Global:RaizApp 'resultados\pendentes'
$envDir  = Join-Path $Global:RaizApp 'resultados\enviados'
foreach ($d in $pendDir, $envDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$modeFile = Join-Path ([IO.Path]::GetTempPath()) 'dicon-testenvio-mode.txt'
$prefix   = "http://localhost:$Porta/"
$Global:AppsScriptEndpointOverride = $prefix

# ---- listener num runspace: responde conforme o conteudo de $modeFile --------
# corpo no envelope da Execution API: {"done":true,"response":{"result":{...}}}
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('listener', $listener)
$rs.SessionStateProxy.SetVariable('modeFile', $modeFile)
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void] $ps.AddScript({
    # "planilha" de Resultados falsa p/ as acoes resultados.listar / resultados.obter
    $sheet = @(
        [pscustomobject]@{ local_id = 'ZE99-SYNC-UM-PRINCIPAL'; tipo = 'principal'; zona = 99
            municipio_termo = 'SyncUm'; classificacao_final = 'viavel'
            recebido_em = '01/09/2026 09:00:00'; enviado_por = 'george@tre-ma.jus.br'; tecnico = 'SYNC TESTE'; linha = 2 }
        [pscustomobject]@{ local_id = 'ZE99-SYNC-DOIS-CONTINGENCIA'; tipo = 'contingencia'; zona = 99
            municipio_termo = 'SyncDois'; classificacao_final = 'inviavel'
            recebido_em = '02/09/2026 14:30:00'; enviado_por = 'george@tre-ma.jus.br'; tecnico = 'SYNC TESTE'; linha = 3 }
        [pscustomobject]@{ local_id = 'ZE99-SYNC-VAZIO'; tipo = 'principal'; zona = 99
            municipio_termo = 'SyncVazio'; classificacao_final = 'viavel'
            recebido_em = '03/09/2026 08:00:00'; enviado_por = 'george@tre-ma.jus.br'; tecnico = 'SYNC VAZIO'; linha = 4 }
    )
    function New-JsonResultado($id) {
        @{ versao_ferramenta = 'sync'; coletado_em = '2026-09-02T14:30:00'
           tecnico = @{ nome = 'SYNC TESTE' }
           local = @{ id = $id; zona_eleitoral = 99; municipio_termo = 'SyncTeste'; tipo = 'principal' }
           metricas = @{ latencia_ms = 12; jitter_ms = 2; perda_percentual = 0; banda_download_mbps = 40; banda_upload_mbps = 12 }
           classificacao = @{ automatica = 'viavel'; final = 'viavel'; ajustada = $false }
        } | ConvertTo-Json -Depth 8 -Compress
    }

    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
            $raw = $reader.ReadToEnd(); $reader.Dispose()

            $acao = ''; $p0 = $null
            try { $p0 = ($raw | ConvertFrom-Json).parameters[0]; $acao = [string] $p0.acao } catch { }

            $resultObj = $null
            if ($acao -eq 'resultados.listar') {
                $itens = $sheet
                if ($p0.tecnico) {
                    $t = [string] $p0.tecnico
                    $itens = $itens | Where-Object { $_.tecnico -eq $t -or $_.enviado_por -eq $t }
                }
                if ($p0.local_ids) {
                    $ids = @($p0.local_ids)
                    $itens = $itens | Where-Object { $ids -contains $_.local_id }
                }
                $itens = @($itens)
                $resultObj = @{ itens = $itens; total = $itens.Count; atualizado_em = '2026-09-05T00:00:00Z' }
            }
            elseif ($acao -eq 'resultados.obter') {
                $id = [string] $p0.local_id
                if ($id -eq 'ZE99-SYNC-VAZIO') {
                    $resultObj = @{ local_id = $id; recebido_em = ''; enviado_por = ''; json = '' }
                } else {
                    $resultObj = @{ local_id = $id; recebido_em = '02/09/2026 14:30:00'
                                    enviado_por = 'george@tre-ma.jus.br'; json = (New-JsonResultado $id) }
                }
            }
            else {
                $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw).Trim() } else { 'ok' }
                $resultObj = switch ($mode) {
                    'ok'       { @{ status = 'ok'; recebido_em = '2026-01-01T00:00:00Z' } }
                    'erro'     { @{ status = 'erro'; erro = 'planilha indisponivel' } }
                    'ignorado' { @{ status = 'ignorado'; motivo = 'PLANILHA_RESULTADOS_ID nao configurado' } }
                    default    { @{ status = 'ok' } }
                }
            }

            $body = @{ done = $true; response = @{ result = $resultObj } } | ConvertTo-Json -Depth 12 -Compress
            $buf = [Text.Encoding]::UTF8.GetBytes($body)
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
        } catch { }
        finally { $ctx.Response.Close() }
    }
})
$handle = $ps.BeginInvoke()

function New-ResultadoFalso {
    $nome = '{0}_ZE99-TESTE-PRINCIPAL.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    $p = Join-Path $pendDir $nome
    @{ versao_ferramenta = 'teste'; coletado_em = (Get-Date).ToString('o')
       tecnico = @{ nome = 'TESTE ENVIO' }
       local = @{ id = 'ZE99-TESTE-PRINCIPAL'; zona_eleitoral = 99; municipio_termo = 'Teste'; tipo = 'principal' }
       metricas = @{ latencia_ms = 10; jitter_ms = 1; perda_percentual = 0; banda_download_mbps = 50; banda_upload_mbps = 20; carregamento_web_s = 2 }
       classificacao = @{ automatica = 'viavel'; final = 'viavel'; ajustada = $false }
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
    return $p
}

$falhas = 0
$criados = @()
try {
    # CASO 1: servidor responde ok -> arquivo migra para enviados\
    Set-Content $modeFile 'ok'
    $p1 = New-ResultadoFalso; $criados += (Split-Path $p1 -Leaf)
    $r1 = Send-Resultado -Caminho $p1 -Retentativas 2 -IntervaloS 1
    $moveu = -not (Test-Path $p1) -and (Test-Path (Join-Path $envDir (Split-Path $p1 -Leaf)))
    if ($r1 -and $moveu) { Write-Host "[1] ok -> migrou para enviados\  OK" }
    else { Write-Host "[1] FALHA: r=$r1 moveu=$moveu"; $falhas++ }

    # CASO 2: servidor responde erro -> permanece em pendentes\
    Set-Content $modeFile 'erro'
    $p2 = New-ResultadoFalso; $criados += (Split-Path $p2 -Leaf)
    $r2 = Send-Resultado -Caminho $p2 -Retentativas 2 -IntervaloS 1
    if (-not $r2 -and (Test-Path $p2)) { Write-Host "[2] erro -> ficou em pendentes\  OK" }
    else { Write-Host "[2] FALHA: r=$r2 existe=$([bool](Test-Path $p2))"; $falhas++ }

    # CASO 3: servidor responde ignorado -> permanece, sem insistir
    Set-Content $modeFile 'ignorado'
    $p3 = New-ResultadoFalso; $criados += (Split-Path $p3 -Leaf)
    $t0 = Get-Date
    $r3 = Send-Resultado -Caminho $p3 -Retentativas 3 -IntervaloS 5
    $dur = ((Get-Date) - $t0).TotalSeconds
    if (-not $r3 -and (Test-Path $p3) -and $dur -lt 4) { Write-Host ("[3] ignorado -> ficou em pendentes\ sem retentativa ({0:N1}s)  OK" -f $dur) }
    else { Write-Host "[3] FALHA: r=$r3 existe=$([bool](Test-Path $p3)) dur=$dur"; $falhas++ }

    # CASO 4: endpoint offline -> retentativa e mantem pendente
    Set-Content $modeFile 'ok'
    $p4 = New-ResultadoFalso; $criados += (Split-Path $p4 -Leaf)
    $Global:AppsScriptEndpointOverride = "http://localhost:$($Porta + 1)/"
    $r4 = Send-Resultado -Caminho $p4 -Retentativas 2 -IntervaloS 1
    $Global:AppsScriptEndpointOverride = $prefix
    if (-not $r4 -and (Test-Path $p4)) { Write-Host "[4] offline -> ficou em pendentes\  OK" }
    else { Write-Host "[4] FALHA: r=$r4 existe=$([bool](Test-Path $p4))"; $falhas++ }

    # CASO 5: Send-ResultadosPendentes devolve resumo
    Set-Content $modeFile 'ok'
    $resumo = Send-ResultadosPendentes
    if ($resumo.Enviados -ge 3 -and $resumo.Falhas -eq 0) { Write-Host "[5] Send-ResultadosPendentes: $($resumo.Enviados) enviado(s)  OK" }
    else { Write-Host "[5] FALHA: resumo T=$($resumo.Total) E=$($resumo.Enviados) F=$($resumo.Falhas)"; $falhas++ }

    # ---- Sync-Resultados (sync de volta, 2 camadas) --------------------------
    # limpa qualquer resquicio de rodada anterior
    Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

    # CASO 6: nenhum resultado local -> baixa os 2 do "servidor" e grava em enviados\
    $s6 = Sync-Resultados -TecnicoNome 'SYNC TESTE'
    $arqs6 = @(Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-*' -EA SilentlyContinue)
    if ($s6.NoServidor -eq 2 -and $s6.Baixados -eq 2 -and $s6.JaTinha -eq 0 -and $arqs6.Count -eq 2) {
        Write-Host "[6] Sync-Resultados: baixou 2 e gravou 2 arquivos em enviados\  OK"
    } else { Write-Host "[6] FALHA: serv=$($s6.NoServidor) baix=$($s6.Baixados) jatinha=$($s6.JaTinha) arqs=$($arqs6.Count)"; $falhas++ }

    # CASO 7: rodar de novo -> reconhece que ja tem, nao rebaixa
    $s7 = Sync-Resultados -TecnicoNome 'SYNC TESTE'
    $arqs7 = @(Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-*' -EA SilentlyContinue)
    if ($s7.Baixados -eq 0 -and $s7.JaTinha -eq 2 -and $arqs7.Count -eq 2) {
        Write-Host "[7] Sync-Resultados idempotente: 0 baixado, 2 ja no computador  OK"
    } else { Write-Host "[7] FALHA: baix=$($s7.Baixados) jatinha=$($s7.JaTinha) arqs=$($arqs7.Count)"; $falhas++ }

    # CASO 8: filtro por tecnico que nao existe -> indice vazio, nada baixado
    $s8 = Sync-Resultados -TecnicoNome 'NINGUEM'
    if ($s8.NoServidor -eq 0 -and $s8.Baixados -eq 0) { Write-Host "[8] Sync-Resultados: filtro por tecnico sem resultados -> nada baixado  OK" }
    else { Write-Host "[8] FALHA: serv=$($s8.NoServidor) baix=$($s8.Baixados)"; $falhas++ }

    # CASO 9: camada 2 devolve json vazio -> conta como falha, sem gravar arquivo
    Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    $s9 = Sync-Resultados -TecnicoNome 'SYNC VAZIO'
    $arqs9 = @(Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-VAZIO*' -EA SilentlyContinue)
    if ($s9.NoServidor -eq 1 -and $s9.Baixados -eq 0 -and $s9.Falhas -eq 1 -and $arqs9.Count -eq 0) {
        Write-Host "[9] Sync-Resultados: JSON vazio na camada 2 -> falha contada, nada gravado  OK"
    } else { Write-Host "[9] FALHA: serv=$($s9.NoServidor) baix=$($s9.Baixados) falhas=$($s9.Falhas) arqs=$($arqs9.Count)"; $falhas++ }
}
finally {
    $listener.Stop(); $listener.Close()
    try { $ps.EndInvoke($handle) } catch { }
    $ps.Dispose(); $rs.Dispose()
    if (Test-Path $modeFile) { Remove-Item $modeFile -Force }
    Get-ChildItem $envDir -Filter 'sync_*ZE99-SYNC-*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    foreach ($n in $criados) {
        foreach ($d in $pendDir, $envDir) {
            $f = Join-Path $d $n
            if (Test-Path $f) { Remove-Item $f -Force }
        }
    }
    $Global:OAuthConfigOverride = $null
    $Global:GoogleToken = $null
    $Global:AppsScriptEndpointOverride = $null
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: OK"; exit 0 }
else { Write-Host "RESULTADO: $falhas FALHA(S)"; exit 1 }
