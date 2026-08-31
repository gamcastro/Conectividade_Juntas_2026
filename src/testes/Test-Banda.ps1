# Banda real pela VPN via iperf3 (client Windows) contra o servidor no CPD.
# Le a saida linha a linha (-f m, texto) e transmite cada intervalo para o
# velocimetro da GUI (Write-EventoIperf -> Update-IperfGauge).

# Repassa um evento do iperf3 para a GUI. Invoke SINCRONO em prioridade
# Background (mesmo padrao do speedtest: nao trava, mantem $Evento no escopo).
function Write-EventoIperf {
    param([hashtable] $Evento)
    $janela = Get-Variable -Name JanelaPrincipal -Scope Global -ErrorAction SilentlyContinue
    $dispatcher = if ($janela -and $janela.Value) { $janela.Value.Dispatcher } else { $null }
    if (-not $dispatcher) { return }
    $aplicar = { Update-IperfGauge $Evento }
    if ($dispatcher.CheckAccess()) { & $aplicar }
    else { $dispatcher.Invoke([action] $aplicar, [Windows.Threading.DispatcherPriority]::Background) }
}

# Roda uma passada do iperf3 (um sentido) lendo o stdout linha a linha.
#   -Fase: 'download' (com -R) ou 'upload'
function Invoke-IperfStreaming {
    param([string] $Iperf, [string] $Argumentos, [string] $Fase, [int] $Duracao = 10)
    $r = [pscustomobject]@{ ok = $false; mbps = $null; retrans = $null; erro = '' }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Iperf
    $psi.Arguments              = $Argumentos
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $reSum = '^\[\s*\d+\]\s+[\d.]+-[\d.]+\s+sec\s+[\d.]+\s+\wBytes\s+([\d.]+)\s+Mbits/sec(?:\s+(\d+))?\s+(sender|receiver)\s*$'
    $reInt = '^\[\s*\d+\]\s+[\d.]+-\s*([\d.]+)\s+sec\s+[\d.]+\s+\wBytes\s+([\d.]+)\s+Mbits/sec'
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $errAsync = $p.StandardError.ReadToEndAsync()
        while ($null -ne ($ln = $p.StandardOutput.ReadLine())) {
            $t = $ln.TrimEnd()
            if ($t -match $reSum) {
                if ($Matches[3] -eq 'receiver') { $r.mbps = [double] $Matches[1] }
                elseif ($Matches[2]) { $r.retrans = [int] $Matches[2] }
            }
            elseif ($t -match $reInt) {
                Write-EventoIperf @{ fase = $Fase; estado = 'andamento'; mbps = [double] $Matches[2]; t = [double] $Matches[1]; dur = $Duracao }
            }
            elseif ($t -match 'iperf3:\s*error\s*-\s*(.+)$') { $r.erro = $Matches[1].Trim() }
        }
        if (-not $p.WaitForExit(($Duracao + 25) * 1000)) { try { $p.Kill() } catch { } }
        $se = try { $errAsync.Result } catch { '' }
        if (-not $r.erro -and $se -and $se.Trim()) {
            $r.erro = @($se -split "`r?`n" | Where-Object { $_ -match 'error|refused|unable|failed' } | Select-Object -First 1)
        }
    } catch { $r.erro = "$_" }
    if ($null -ne $r.mbps) { $r.ok = $true }
    $r
}

# Mede download (-R) e upload contra o servidor iperf3 do CPD, ao vivo.
function Test-BandaVpn {
    param(
        [string] $Servidor,
        [int]    $Porta   = 5201,
        [int]    $Duracao = 10
    )
    $out = [pscustomobject]@{
        iperf_ok = $false; iperf_erro = ''
        servidor = ('{0}:{1}' -f $Servidor, $Porta)
        DownloadMbps = $null; UploadMbps = $null
        retrans_down = $null; retrans_up = $null
    }
    $iperf = Join-Path $Global:RaizApp 'bin\iperf3\iperf3.exe'
    if (-not (Test-Path $iperf)) {
        $out.iperf_erro = 'iperf3.exe nao esta em bin\iperf3\. Copie o binario e rode de novo.'
        Write-Log $out.iperf_erro -Nivel Erro
        Write-EventoIperf @{ fase = 'fim'; estado = 'fim'; ok = $false; erro = $out.iperf_erro }
        return $out
    }

    Write-EventoIperf @{ fase = 'download'; estado = 'inicio'; servidor = $out.servidor; dur = $Duracao }
    Write-Log ("Banda VPN: iperf3 -c {0} -p {1} -t {2} -R (download)" -f $Servidor, $Porta, $Duracao) -Nivel Info
    $dl = Invoke-IperfStreaming -Iperf $iperf -Fase 'download' -Duracao $Duracao `
        -Argumentos ("-c {0} -p {1} -t {2} -R -f m" -f $Servidor, $Porta, $Duracao)

    Write-EventoIperf @{ fase = 'upload'; estado = 'inicio'; dur = $Duracao }
    Write-Log ("Banda VPN: iperf3 -c {0} -p {1} -t {2} (upload)" -f $Servidor, $Porta, $Duracao) -Nivel Info
    $ul = Invoke-IperfStreaming -Iperf $iperf -Fase 'upload' -Duracao $Duracao `
        -Argumentos ("-c {0} -p {1} -t {2} -f m" -f $Servidor, $Porta, $Duracao)

    $out.DownloadMbps = if ($null -ne $dl.mbps) { [math]::Round($dl.mbps, 1) } else { $null }
    $out.UploadMbps   = if ($null -ne $ul.mbps) { [math]::Round($ul.mbps, 1) } else { $null }
    $out.retrans_down = $dl.retrans
    $out.retrans_up   = $ul.retrans
    $out.iperf_ok     = ($dl.ok -or $ul.ok)
    $out.iperf_erro   = @($dl.erro, $ul.erro | Where-Object { $_ }) | Select-Object -First 1

    Write-EventoIperf @{
        fase = 'fim'; estado = 'fim'
        download = $out.DownloadMbps; upload = $out.UploadMbps
        retrans_down = $out.retrans_down; retrans_up = $out.retrans_up
        servidor = $out.servidor; ok = $out.iperf_ok; erro = $out.iperf_erro
    }
    Write-Log ("Banda VPN medida: down {0} / up {1} Mbps" -f $out.DownloadMbps, $out.UploadMbps) -Nivel Ok
    $out
}
