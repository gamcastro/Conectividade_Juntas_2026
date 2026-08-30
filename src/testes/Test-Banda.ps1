# Banda real via iperf3 (client Windows) contra o servidor no CPD.

function Test-Banda {
    param(
        [string] $Servidor,
        [int]    $Porta   = 5201,
        [int]    $Duracao = 10,
        [switch] $Reverso
    )

    $iperf = Join-Path $Global:RaizApp 'bin\iperf3\iperf3.exe'
    if (-not (Test-Path $iperf)) {
        Write-Log "iperf3.exe nao encontrado em $iperf" -Nivel Erro
        return [pscustomobject]@{ Servidor = $Servidor; DownloadMbps = $null; UploadMbps = $null }
    }

    $lista = @('-c', $Servidor, '-p', "$Porta", '-t', "$Duracao", '-J')
    if ($Reverso) { $lista += '-R' }

    Write-Log ("Medindo banda: iperf3 -c {0} -p {1} -t {2}{3}" -f $Servidor, $Porta, $Duracao, $(if ($Reverso) { ' -R' } else { '' })) -Nivel Info

    $bruto = Invoke-ProcessoComSaida -Caminho $iperf -Argumentos $lista -TimeoutS ($Duracao + 25)
    if ([string]::IsNullOrWhiteSpace($bruto)) {
        Write-Log 'iperf3 nao retornou saida' -Nivel Erro
        return [pscustomobject]@{ Servidor = $Servidor; DownloadMbps = $null; UploadMbps = $null }
    }

    try {
        $j    = $bruto | ConvertFrom-Json
        $bps  = $j.end.sum_received.bits_per_second
        $mbps = [math]::Round($bps / 1e6, 1)

        # Com -R o iperf3 mede o sentido servidor -> cliente (download).
        # Sem -R, mede cliente -> servidor (upload).
        $resultado = [pscustomobject]@{ Servidor = $Servidor; DownloadMbps = $null; UploadMbps = $null }
        if ($Reverso) { $resultado.DownloadMbps = $mbps } else { $resultado.UploadMbps = $mbps }

        Write-Log ("Banda medida: {0} Mbps ({1})" -f $mbps, $(if ($Reverso) { 'download' } else { 'upload' })) -Nivel Neutro
        return $resultado
    } catch {
        Write-Log "Falha ao interpretar a saida do iperf3: $_" -Nivel Erro
        return [pscustomobject]@{ Servidor = $Servidor; DownloadMbps = $null; UploadMbps = $null }
    }
}
