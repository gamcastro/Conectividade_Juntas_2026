# Latencia, jitter e perda via ping nativo do Windows.

function Test-Latencia {
    param(
        [string] $Alvo,
        [int]    $Amostras = 20
    )

    Write-Log "Medindo latencia para $Alvo ($Amostras amostras)..." -Nivel Info

    # Test-Connection: PS 7 usa -TargetName/-Count e .Latency; PS 5.1 usa
    # -ComputerName/-Count e .ResponseTime. Tratamos os dois.
    $respostas = $null
    try {
        $respostas = Test-Connection -TargetName $Alvo -Count $Amostras -ErrorAction Stop
    } catch {
        try {
            $respostas = Test-Connection -ComputerName $Alvo -Count $Amostras -ErrorAction Stop
        } catch {
            Write-Log "Sem resposta de $Alvo" -Nivel Erro
            return [pscustomobject]@{ Alvo = $Alvo; LatenciaMediaMs = $null; JitterMs = $null; PerdaPercentual = 100; Amostras = $Amostras; AmostrasMs = @() }
        }
    }

    # amostrasOrdenadas preserva a posicao de cada ping (1..N), com $null nas
    # que nao responderam -- e' o que vai pro grafico "latencia por amostra"
    # do relatorio (perda = buraco na linha; ver Get-GraficoLinhaHtml).
    $amostrasOrdenadas = foreach ($r in $respostas) {
        if ($null -ne $r.Latency)          { [double] $r.Latency }
        elseif ($null -ne $r.ResponseTime) { [double] $r.ResponseTime }
        else                                { $null }
    }
    $amostrasOrdenadas = @($amostrasOrdenadas)
    $tempos = @($amostrasOrdenadas | Where-Object { $_ -ne $null })

    $perda  = [math]::Round(100 * (1 - ($tempos.Count / [double]$Amostras)), 1)
    $media  = if ($tempos.Count) { [math]::Round((($tempos | Measure-Object -Average).Average), 1) } else { $null }

    $jitter = 0
    if ($tempos.Count -gt 1) {
        $difs = for ($i = 1; $i -lt $tempos.Count; $i++) { [math]::Abs($tempos[$i] - $tempos[$i - 1]) }
        $jitter = [math]::Round((($difs | Measure-Object -Average).Average), 1)
    }

    Write-Log ("Latencia {0} ms | jitter {1} ms | perda {2}%" -f $media, $jitter, $perda) -Nivel Neutro

    [pscustomobject]@{
        Alvo            = $Alvo
        LatenciaMediaMs = $media
        JitterMs        = $jitter
        PerdaPercentual = $perda
        Amostras        = $Amostras
        AmostrasMs      = $amostrasOrdenadas
    }
}
