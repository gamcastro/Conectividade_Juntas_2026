# Testa os graficos novos do relatorio (itens 1, 2, 5, 6 e 7 do pedido do
# usuario): os 2 helpers de SVG isolados, e o pipeline completo
# (New-ResultadoJson -> New-RelatorioHtml) com dado sintetico controlado,
# cobrindo tanto o caso "com dado" quanto o caso "sem dado" (JSON antigo,
# sem os campos novos -- nao pode quebrar, so' nao mostra o grafico).
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    & $exe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
$Global:ModoTeste  = $true
Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

$falhas = 0
function Checar { param([string] $Nome, [bool] $Ok, [string] $Detalhe = '')
    if ($Ok) { Write-Host "[OK] $Nome" }
    else { Write-Host "    FALHA: $Nome $Detalhe"; $script:falhas++ }
}

# ------------------------------------------------------- 1) helpers de SVG
$barras = @(
    [pscustomobject]@{ Rotulo = 'LAN'; Valor = 855.6; Cor = '#123FA8' }
    [pscustomobject]@{ Rotulo = 'Wi-Fi'; Valor = 42.1; Cor = '#1B7F3B' }
    [pscustomobject]@{ Rotulo = 'Celular'; Valor = $null }
)
$htmlBarras = Get-GraficoBarrasHtml -Barras $barras -Titulo 'Download (Mbps)' -Unidade 'Mbps'
Checar 'Get-GraficoBarrasHtml: svg com barras + rotulos + sem medida' `
    ($htmlBarras -match '<svg' -and $htmlBarras -match 'LAN' -and $htmlBarras -match 'sem medida')
Checar 'Get-GraficoBarrasHtml: vazio sem barras' (-not (Get-GraficoBarrasHtml -Barras @()))
if ($htmlBarras -match 'width="([\d.]+)"[^>]*fill="#123FA8"') { $wLan = [double] $Matches[1] } else { $wLan = 0 }
if ($htmlBarras -match 'width="([\d.]+)"[^>]*fill="#1B7F3B"') { $wWifi = [double] $Matches[1] } else { $wWifi = 0 }
Checar 'Get-GraficoBarrasHtml: barra maior valor fica mais larga' ($wLan -gt $wWifi -and $wWifi -gt 0) "(wLan=$wLan wWifi=$wWifi)"

$serieDown = [pscustomobject]@{ Nome = 'Download'; Cor = '#123FA8'; Pontos = @(
    [pscustomobject]@{ T = 0; V = 10 }; [pscustomobject]@{ T = 1; V = 40 }
    [pscustomobject]@{ T = 2; V = $null }   # buraco (amostra perdida)
    [pscustomobject]@{ T = 3; V = 70 }; [pscustomobject]@{ T = 4; V = 80 }
) }
$htmlLinha = Get-GraficoLinhaHtml -Series @($serieDown) -Titulo 'Velocidade' -EixoY 'Mbps'
Checar 'Get-GraficoLinhaHtml: svg com 2 trechos (buraco separa a linha)' `
    (([regex]::Matches($htmlLinha, '<polyline')).Count -eq 2) "(html=$htmlLinha)"
Checar 'Get-GraficoLinhaHtml: legenda sem bug de parsing ([string] literal)' ($htmlLinha -notmatch '\[string\]')
Checar 'Get-GraficoLinhaHtml: vazio sem pontos validos' (-not (Get-GraficoLinhaHtml -Series @([pscustomobject]@{ Nome='X'; Cor='#000'; Pontos=@() })))

# ------------------------------------------ 1b) captura das series (campo real)
# ConvertTo-SerieVelocidadeSpeedtest recebe a lista de eventos JSONL do Ookla
# EXATAMENTE como Invoke-SpeedtestStreaming devolve: um [Generic.List[object]].
# No PowerShell 5.1 recente (build 26100.8875+), @($umaList[object]) estoura
# "Os tipos de argumento nao correspondem" -- por isso a funcao NAO pode usar
# @() sobre a lista. Este teste guarda contra a regressao (v0.6.105 quebrou
# a Fase 1 em campo por causa disso; os outros suites nao pegam porque usam
# $Global:FaseLocalSimulada e nunca chegam no speedtest real).
$evtList = New-Object System.Collections.Generic.List[object]
$evtList.Add(([pscustomobject]@{ type = 'testStart'; server = [pscustomobject]@{ name = 'X' } }))
foreach ($p in 0.0, 0.2, 0.55, 0.8, 1) {
    $evtList.Add(([pscustomobject]@{ type = 'download'; download = [pscustomobject]@{ bandwidth = [int64]3700000; progress = $p } }))
}
foreach ($p in 0.0, 0.5, 1) {
    $evtList.Add(([pscustomobject]@{ type = 'upload'; upload = [pscustomobject]@{ bandwidth = [int64]3250000; progress = $p } }))
}
$evtList.Add(([pscustomobject]@{ type = 'result'; download = [pscustomobject]@{ bandwidth = 3730000 } }))
$serieOk = $true
try { $sv = ConvertTo-SerieVelocidadeSpeedtest $evtList } catch { $serieOk = $false; $svErr = "$_" }
Checar 'ConvertTo-SerieVelocidadeSpeedtest: aceita List[object] sem estourar' $serieOk $svErr
Checar 'ConvertTo-SerieVelocidadeSpeedtest: 8 pontos (5 download + 3 upload)' ($serieOk -and @($sv).Count -eq 8) "(count=$(@($sv).Count))"
Checar 'ConvertTo-SerieVelocidadeSpeedtest: T em 0-100 e Fase preenchida' `
    ($serieOk -and -not (@($sv) | Where-Object { $_.T -lt 0 -or $_.T -gt 100 -or -not $_.Fase }))
$svNull = $true
try { $x = ConvertTo-SerieVelocidadeSpeedtest $null } catch { $svNull = $false }
Checar 'ConvertTo-SerieVelocidadeSpeedtest: null -> vazio, sem estourar' ($svNull -and @($x).Count -eq 0)

# Invoke-IperfStreaming acumula Serie num [Generic.List[object]] tambem -- mesma
# armadilha do @(). Stub que imita a saida de intervalo + resumo do iperf3.
$stub = Join-Path $env:TEMP ("dicon-iperf-stub-{0}.cmd" -f ([guid]::NewGuid().ToString('N')))
@(
    '@echo off'
    'echo [  5]   0.00-1.00   sec  11.2 MBytes  94.1 Mbits/sec'
    'echo [  5]   1.00-2.00   sec  11.5 MBytes  96.4 Mbits/sec'
    'echo [  5]   0.00-2.00   sec  22.7 MBytes  95.2 Mbits/sec    0             receiver'
) | Set-Content -Path $stub -Encoding Ascii
try {
    $ip = Invoke-IperfStreaming -Iperf $stub -Argumentos '' -Fase 'download' -Duracao 2
    Checar 'Invoke-IperfStreaming: Serie e array com 2 intervalos' (@($ip.Serie).Count -eq 2) "(count=$(@($ip.Serie).Count))"
    Checar 'Invoke-IperfStreaming: cada ponto tem T/Fase/Mbps' `
        (-not (@($ip.Serie) | Where-Object { $null -eq $_.T -or -not $_.Fase -or $null -eq $_.Mbps }))
} catch {
    Checar 'Invoke-IperfStreaming: nao estoura montando a Serie' $false "$_"
} finally {
    Remove-Item $stub -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------ 2) pipeline completo (com dado)
# Monta 2 medicoes com TODOS os campos novos preenchidos, pra exercitar os
# itens 1 (comparacao entre meios), 2 (sem/com VPN), 5 (curva speedtest),
# 6 (curva iperf3 + latencia por amostra) e 7 (tentativas do "Refazer").
function New-MedicaoSintetica {
    param([string] $Meio, [string] $Rotulo, [double] $DownloadSemVpn, [double] $UploadSemVpn,
          [double] $DownloadComVpn, [double] $UploadComVpn, [double] $LatenciaMs,
          [int] $NTentativasFase1 = 1, [int] $NTentativasFase2 = 1)
    $serieVelocidade = @(
        [pscustomobject]@{ T = 0; Fase = 'download'; Mbps = $DownloadSemVpn * 0.3 }
        [pscustomobject]@{ T = 50; Fase = 'download'; Mbps = $DownloadSemVpn }
        [pscustomobject]@{ T = 100; Fase = 'download'; Mbps = $DownloadSemVpn }
        [pscustomobject]@{ T = 50; Fase = 'upload'; Mbps = $UploadSemVpn }
    )
    $serieBanda = @(
        [pscustomobject]@{ T = 1; Fase = 'download'; Mbps = $DownloadComVpn * 0.8 }
        [pscustomobject]@{ T = 2; Fase = 'download'; Mbps = $DownloadComVpn }
        [pscustomobject]@{ T = 12; Fase = 'upload'; Mbps = $UploadComVpn }
    )
    $serieLatencia = @(($LatenciaMs - 2), $null, $LatenciaMs, ($LatenciaMs + 1))   # 1 amostra perdida
    $fase1Detalhe = @(1..$NTentativasFase1 | ForEach-Object {
        [pscustomobject]@{ download_mbps = $DownloadSemVpn - $_; upload_mbps = $UploadSemVpn; ping_ms = 20; jitter_ms = 2 }
    })
    $fase2Detalhe = @(1..$NTentativasFase2 | ForEach-Object {
        [pscustomobject]@{ latencia_ms = $LatenciaMs; jitter_ms = 2; perda_pct = 0; download_mbps = $DownloadComVpn - $_; upload_mbps = $UploadComVpn }
    })
    [pscustomobject]@{
        meio = $Meio; operadora = ''; rotulo = $Rotulo; nao_aplicavel = $false; motivo_na = ''
        fase_local = [pscustomobject]@{
            Internet = [pscustomobject]@{ upload_mbps = $UploadSemVpn; isp = 'ISP-TESTE'; serie_velocidade = $serieVelocidade }
        }
        rede_local_ok = $true; rede_local_download = $DownloadSemVpn
        vpn_conectou = $true; vpn_motivo = ''
        metricas = [pscustomobject]@{
            LatenciaMediaMs = $LatenciaMs; JitterMs = 2; PerdaPercentual = 0
            BandaDownloadMbps = $DownloadComVpn; BandaUploadMbps = $UploadComVpn; CarregamentoWebS = 3
            SerieLatenciaMs = $serieLatencia
        }
        iperf = [pscustomobject]@{ iperf_ok = $true; DownloadMbps = $DownloadComVpn; UploadMbps = $UploadComVpn; SerieBanda = $serieBanda }
        decisao = [pscustomobject]@{ Classificacao = 'viavel'; Detalhes = @() }
        ambiente = [pscustomobject]@{ vpn_ativa = $true }
        avaliacoes = @()
        veredito = 'viavel'; quando = (Get-Date).ToString('o')
        fase1_tentativas = $NTentativasFase1; fase2_tentativas = $NTentativasFase2
        fase1_tentativas_detalhe = $fase1Detalhe; fase2_tentativas_detalhe = $fase2Detalhe
    }
}

$medLan  = New-MedicaoSintetica -Meio 'lan' -Rotulo 'Rede cabeada (LAN)' -DownloadSemVpn 800 -UploadSemVpn 300 -DownloadComVpn 90 -UploadComVpn 30 -LatenciaMs 45 -NTentativasFase1 2 -NTentativasFase2 2
$medWifi = New-MedicaoSintetica -Meio 'wifi_local' -Rotulo 'Wi-Fi do proprio local' -DownloadSemVpn 60 -UploadSemVpn 20 -DownloadComVpn 15 -UploadComVpn 5 -LatenciaMs 90 -NTentativasFase1 1 -NTentativasFase2 1

$localObj = [pscustomobject]@{ id='ZE99-TESTE'; zona_eleitoral=99; municipio_termo='Teste'; municipio_sede='Teste'; nome='Local de Teste'; tipo='principal'; endereco='Rua X'; tipo_internet='' }
$metTop = [pscustomobject]@{ LatenciaMediaMs=45; JitterMs=2; PerdaPercentual=0; BandaDownloadMbps=90; BandaUploadMbps=30; CarregamentoWebS=3 }
$decTop = [pscustomobject]@{ Classificacao='viavel'; Detalhes=@() }
$recTop = [pscustomobject]@{ meio='lan'; operadora=''; rotulo='Rede cabeada (LAN)'; veredito='viavel'; provisoria=$false; base='vpn' }

$docCompleto = New-ResultadoJson -Ambiente ([pscustomobject]@{ vpn_ativa=$true }) -Metricas $metTop -Decisao $decTop `
    -Local $localObj -TecnicoNome 'TESTE' -FaseLocal $medLan.fase_local -Medicoes @($medLan, $medWifi) `
    -ConexaoRecomendada $recTop -MotivoRecomendacao 'melhor download'
$htmlCompleto = New-RelatorioHtml -Resultado $docCompleto

Checar 'item 1: comparacao entre os meios aparece no Painel de Viabilidade' ($htmlCompleto -match 'Compara..o entre os meios')
Checar 'item 2: barras Sem VPN / Com VPN aparecem no bloco do meio' ($htmlCompleto -match 'Sem VPN' -and $htmlCompleto -match 'Com VPN')
Checar 'item 5: curva de velocidade do speedtest aparece' ($htmlCompleto -match 'Velocidade ao longo do teste')
Checar 'item 6a: curva de banda do iperf3 aparece' ($htmlCompleto -match 'Banda pela VPN ao longo do teste')
Checar 'item 6b: latencia por amostra do ping aparece' ($htmlCompleto -match 'lat.ncia por amostra do ping')
Checar 'item 7: tentativas do Refazer aparecem so no meio com 2+ tentativas (LAN)' `
    (([regex]::Matches($htmlCompleto, 'Tentativas do')).Count -eq 1)
$nSvg = ([regex]::Matches($htmlCompleto, '<svg')).Count
Checar "graficos totais gerados (>= 8, 2 medicoes x varios itens)" ($nSvg -ge 8) "(nSvg=$nSvg)"

# modo medicao/referencia tambem devem mostrar os graficos (Painel de Medicoes)
$docMedicao = $docCompleto.PSObject.Copy()
$docMedicao | Add-Member -NotePropertyName modo_avaliacao -NotePropertyValue 'medicao' -Force
$htmlMedicao = New-RelatorioHtml -Resultado $docMedicao
Checar 'modo medicao: comparacao entre os meios tambem aparece no Painel de Medicoes' ($htmlMedicao -match 'Compara..o entre os meios')
Checar 'modo medicao: curva de velocidade tambem aparece' ($htmlMedicao -match 'Velocidade ao longo do teste')

# ------------------------------------------------ 3) pipeline sem os campos novos
# Simula um resultado "antigo" (de antes desta versao) -- os campos novos nao
# existem nas medicoes. Nao pode quebrar; os graficos so' ficam ausentes.
$medAntiga = [pscustomobject]@{
    meio = 'lan'; operadora = ''; rotulo = 'Rede cabeada (LAN)'; nao_aplicavel = $false; motivo_na = ''
    fase_local = [pscustomobject]@{ Internet = [pscustomobject]@{ upload_mbps = 300; isp = 'ISP-TESTE' } }
    rede_local_ok = $true; rede_local_download = 800
    vpn_conectou = $true; vpn_motivo = ''
    metricas = [pscustomobject]@{ LatenciaMediaMs = 45; JitterMs = 2; PerdaPercentual = 0; BandaDownloadMbps = 90; BandaUploadMbps = 30; CarregamentoWebS = 3 }
    iperf = [pscustomobject]@{ iperf_ok = $true; DownloadMbps = 90; UploadMbps = 30 }
    decisao = [pscustomobject]@{ Classificacao = 'viavel'; Detalhes = @() }
    ambiente = [pscustomobject]@{ vpn_ativa = $true }
    avaliacoes = @(); veredito = 'viavel'; quando = (Get-Date).ToString('o')
    fase1_tentativas = 1; fase2_tentativas = 1
}
try {
    $docAntigo = New-ResultadoJson -Ambiente ([pscustomobject]@{ vpn_ativa=$true }) -Metricas $metTop -Decisao $decTop `
        -Local $localObj -TecnicoNome 'TESTE' -FaseLocal $medAntiga.fase_local -Medicoes @($medAntiga) `
        -ConexaoRecomendada $recTop -MotivoRecomendacao 'unico meio'
    $htmlAntigo = New-RelatorioHtml -Resultado $docAntigo
    Checar 'JSON sem os campos novos: nao quebra e os graficos de curva ficam ausentes' `
        ($htmlAntigo -notmatch 'Velocidade ao longo do teste' -and $htmlAntigo -notmatch 'Banda pela VPN ao longo do teste')
} catch {
    Checar 'JSON sem os campos novos: nao quebra' $false "erro: $_"
}

Write-Host ("`nRESULTADO: {0}" -f $(if ($falhas -eq 0) { 'OK' } else { "$falhas FALHA(S)" }))
if ($falhas -gt 0) { exit 1 }
