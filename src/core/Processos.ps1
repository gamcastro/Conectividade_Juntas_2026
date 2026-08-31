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
      com timeout. Usado pelos testes (ex.: iperf3 -J).

      TODO: para saidas grandes, ler stdout/stderr de forma assincrona para
      evitar deadlock de buffer. Suficiente para o JSON compacto do iperf3.
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

    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutS * 1000)) {
        try { $p.Kill() } catch { }
        Write-Log "Processo excedeu ${TimeoutS}s e foi encerrado: $Caminho" -Nivel Erro
        return $null
    }

    $saida = $p.StandardOutput.ReadToEnd()
    $erro  = $p.StandardError.ReadToEnd()
    if ($erro.Trim()) { Write-Log $erro.Trim() -Nivel Aviso }
    return $saida
}
