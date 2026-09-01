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
      Roda um binario e aguarda o termino com timeout. NAO captura stdout
      (o unico chamador - Export-RelatorioPdf com o navegador headless - so
      precisa do arquivo gerado). Usa Start-Process -PassThru + WaitForExit,
      sem redirecionar streams: assim nao ha [IO.StreamReader] sobre pipe, que
      estoura "o fluxo nao era legivel" no runspace MTA.
    #>
    param(
        [Parameter(Position = 0)] [string] $Caminho,
        [string[]] $Argumentos = @(),
        [int] $TimeoutS = 60,
        [System.Text.Encoding] $Encoding   # mantido por compatibilidade; ignorado
    )

    if (-not (Test-Path $Caminho)) {
        Write-Log "Binario nao encontrado: $Caminho" -Nivel Erro
        return $null
    }

    $sp = @{ FilePath = $Caminho; NoNewWindow = $true; PassThru = $true; ErrorAction = 'Stop' }
    $joined = ($Argumentos -join ' ')          # o chamador ja poe as aspas dos paths
    if ($joined) { $sp['ArgumentList'] = $joined }

    try {
        $p = Start-Process @sp
        if (-not $p.WaitForExit($TimeoutS * 1000)) {
            try { $p.Kill() } catch { }
            Write-Log "Processo excedeu ${TimeoutS}s e foi encerrado: $Caminho" -Nivel Erro
        }
    } catch {
        Write-Log "Falha ao executar ${Caminho}: $_" -Nivel Erro
    }
    return $null
}
