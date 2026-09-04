#Requires -Version 5.1
<#
.SYNOPSIS
    Teste do envio de resultados (src/saida/Send-Resultado.ps1) contra um
    HttpListener local que simula o Apps Script. Valida que o arquivo so migra
    para resultados\enviados\ quando a resposta e {status:'ok'} -- e permanece
    em resultados\pendentes\ quando o servidor recusa (erro / ignorado).
#>
[CmdletBinding()]
param(
    [int] $Porta = 8477
)

$ErrorActionPreference = 'Stop'
$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null

Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force

# este teste nao exercita o OAuth do Web App; forca o modo sem autenticacao
# (o ambiente.exemplo.json do pacote pode vir com google_oauth.enabled = true)
$Global:OAuthConfigOverride = @{ enabled = $false }

$pendDir = Join-Path $Global:RaizApp 'resultados\pendentes'
$envDir  = Join-Path $Global:RaizApp 'resultados\enviados'
foreach ($d in $pendDir, $envDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$modeFile = Join-Path ([IO.Path]::GetTempPath()) 'dicon-testenvio-mode.txt'
$prefix   = "http://localhost:$Porta/"

# ---- listener num runspace: responde conforme o conteudo de $modeFile --------
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('listener', $listener)
$rs.SessionStateProxy.SetVariable('modeFile', $modeFile)
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void] $ps.AddScript({
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
            $null = $reader.ReadToEnd(); $reader.Dispose()
            $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw).Trim() } else { 'ok' }
            $body = switch ($mode) {
                'ok'       { '{"status":"ok","recebido_em":"2026-01-01T00:00:00Z"}' }
                'erro'     { '{"status":"erro","erro":"planilha indisponivel"}' }
                'ignorado' { '{"status":"ignorado","motivo":"PLANILHA_RESULTADOS_ID nao configurado"}' }
                default    { '{"status":"ok"}' }
            }
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
    $r1 = Send-Resultado -Caminho $p1 -Endpoint $prefix -Retentativas 2 -IntervaloS 1
    $moveu = -not (Test-Path $p1) -and (Test-Path (Join-Path $envDir (Split-Path $p1 -Leaf)))
    if ($r1 -and $moveu) { Write-Host "[1] ok -> migrou para enviados\  OK" }
    else { Write-Host "[1] FALHA: r=$r1 moveu=$moveu"; $falhas++ }

    # CASO 2: servidor responde erro -> permanece em pendentes\
    Set-Content $modeFile 'erro'
    $p2 = New-ResultadoFalso; $criados += (Split-Path $p2 -Leaf)
    $r2 = Send-Resultado -Caminho $p2 -Endpoint $prefix -Retentativas 2 -IntervaloS 1
    if (-not $r2 -and (Test-Path $p2)) { Write-Host "[2] erro -> ficou em pendentes\  OK" }
    else { Write-Host "[2] FALHA: r=$r2 existe=$([bool](Test-Path $p2))"; $falhas++ }

    # CASO 3: servidor responde ignorado -> permanece, sem insistir
    Set-Content $modeFile 'ignorado'
    $p3 = New-ResultadoFalso; $criados += (Split-Path $p3 -Leaf)
    $t0 = Get-Date
    $r3 = Send-Resultado -Caminho $p3 -Endpoint $prefix -Retentativas 3 -IntervaloS 5
    $dur = ((Get-Date) - $t0).TotalSeconds
    if (-not $r3 -and (Test-Path $p3) -and $dur -lt 4) { Write-Host ("[3] ignorado -> ficou em pendentes\ sem retentativa ({0:N1}s)  OK" -f $dur) }
    else { Write-Host "[3] FALHA: r=$r3 existe=$([bool](Test-Path $p3)) dur=$dur"; $falhas++ }

    # CASO 4: endpoint offline -> retentativa e mantem pendente
    Set-Content $modeFile 'ok'
    $p4 = New-ResultadoFalso; $criados += (Split-Path $p4 -Leaf)
    $r4 = Send-Resultado -Caminho $p4 -Endpoint "http://localhost:$($Porta + 1)/" -Retentativas 2 -IntervaloS 1
    if (-not $r4 -and (Test-Path $p4)) { Write-Host "[4] offline -> ficou em pendentes\  OK" }
    else { Write-Host "[4] FALHA: r=$r4 existe=$([bool](Test-Path $p4))"; $falhas++ }

    # CASO 5: Send-ResultadosPendentes devolve resumo
    Set-Content $modeFile 'ok'
    $resumo = Send-ResultadosPendentes -Endpoint $prefix
    if ($resumo.Enviados -ge 3 -and $resumo.Falhas -eq 0) { Write-Host "[5] Send-ResultadosPendentes: $($resumo.Enviados) enviado(s)  OK" }
    else { Write-Host "[5] FALHA: resumo T=$($resumo.Total) E=$($resumo.Enviados) F=$($resumo.Falhas)"; $falhas++ }
}
finally {
    $listener.Stop(); $listener.Close()
    try { $ps.EndInvoke($handle) } catch { }
    $ps.Dispose(); $rs.Dispose()
    if (Test-Path $modeFile) { Remove-Item $modeFile -Force }
    foreach ($n in $criados) {
        foreach ($d in $pendDir, $envDir) {
            $f = Join-Path $d $n
            if (Test-Path $f) { Remove-Item $f -Force }
        }
    }
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: OK"; exit 0 }
else { Write-Host "RESULTADO: $falhas FALHA(S)"; exit 1 }
