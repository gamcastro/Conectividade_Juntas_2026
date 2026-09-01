# Execucao de processos externos (iperf3.exe, geckodriver, chromedriver).

function Start-ProcessoNaoElevado {
    <#
      Lanca um processo SEM herdar a elevacao atual, usando o Explorer
      (integridade media) como pai via Shell COM. Fire-and-forget: nao captura
      saida nem aguarda o termino. Use quando o processo escreve o resultado em
      arquivo/porta e nao no stdout.
    #>
    param(
        [Parameter(Position = 0)] [string] $Caminho,
        [string[]] $Argumentos = @(),
        [string] $DiretorioTrabalho = "$PWD"
    )
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($Caminho, ($Argumentos -join ' '), $DiretorioTrabalho, '', 1)
}

function Invoke-ProcessoComSaida {
    <#
      Executa um binario e devolve o stdout como string, aguardando o termino
      com timeout. Usado pelos testes (ex.: iperf3 -J) e pelo inventario de rede
      (netsh wlan ...).

      stdout/stderr sao lidos de forma ASSINCRONA (ReadToEndAsync) ANTES do
      WaitForExit: se nao, uma saida maior que o buffer do pipe (~4 KB - acontece
      com 'netsh wlan show networks' num local com muitas redes) trava o processo
      filho no write, o WaitForExit estoura o timeout e o stream fica sem ser
      lido ("o fluxo nao era legivel" ao tentar ler depois).
    #>
    param(
        [Parameter(Position = 0)] [string] $Caminho,
        [string[]] $Argumentos = @(),
        [int] $TimeoutS = 60,
        # Encoding do stdout/stderr. Util p/ apps de console (ping.exe usa OEM).
        [System.Text.Encoding] $Encoding
    )

    if (-not (Test-Path $Caminho)) {
        Write-Log "Binario nao encontrado: $Caminho" -Nivel Erro
        return $null
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Caminho
    $psi.Arguments              = ($Argumentos -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    if ($Encoding) {
        $psi.StandardOutputEncoding = $Encoding
        $psi.StandardErrorEncoding  = $Encoding
    }

    $p = $null
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit($TimeoutS * 1000)) {
            try { $p.Kill() } catch { }
            Write-Log "Processo excedeu ${TimeoutS}s e foi encerrado: $Caminho" -Nivel Erro
            return $null
        }

        try { [void] [Threading.Tasks.Task]::WaitAll(([Threading.Tasks.Task[]] @($tOut, $tErr)), 5000) } catch { }
        $saida = if ($tOut.Status -eq 'RanToCompletion') { $tOut.Result } else { '' }
        $erro  = if ($tErr.Status -eq 'RanToCompletion') { $tErr.Result } else { '' }
        if ($erro -and $erro.Trim()) { Write-Log $erro.Trim() -Nivel Aviso }
        return $saida
    } catch {
        Write-Log "Falha ao executar ${Caminho}: $_" -Nivel Erro
        return $null
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
    }
}
