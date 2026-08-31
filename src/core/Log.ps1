# Log colorido. Alimenta uma ObservableCollection ligada por binding a lista da
# janela WPF (fundo preto) e espelha em arquivo texto.
#
# Convencao do projeto: nunca [Parameter(Mandatory=$true)] em parametro string
# de funcao de log.

if (-not (Get-Variable -Name LogEntries -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:LogEntries = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
}
# Feed curto de atividade da tela inicial (mais novo no topo). Nao e limpo
# pelo fluxo de diagnostico, ao contrario de $Global:LogEntries.
if (-not (Get-Variable -Name LogHome -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:LogHome = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
}
$Global:LogHomeMax = 12

# Nivel -> cor (nomes de cor do WPF; o binding string->Brush resolve sozinho).
$Global:LogCores = @{
    Info     = 'SkyBlue'
    Ok       = 'LightGreen'
    Aviso    = 'Yellow'
    Erro     = 'OrangeRed'
    Destaque = 'DeepPink'
    Neutro   = 'Cyan'
}

function Write-Log {
    param(
        [string] $Mensagem = '',

        [ValidateSet('Info', 'Ok', 'Aviso', 'Erro', 'Destaque', 'Neutro')]
        [string] $Nivel = 'Info'
    )

    $hora = (Get-Date).ToString('HH:mm:ss')
    $cor  = $Global:LogCores[$Nivel]
    $entrada = New-LogEntry -Hora $hora -Texto $Mensagem -Cor $cor

    # Se ha janela e estamos fora da thread de UI, marshalla para o Dispatcher.
    $janela = Get-Variable -Name JanelaPrincipal -Scope Global -ErrorAction SilentlyContinue
    $dispatcher = if ($janela) { $janela.Value.Dispatcher } else { $null }

    $aplicar = {
        $Global:LogEntries.Add($entrada)
        $Global:LogHome.Insert(0, $entrada)
        while ($Global:LogHome.Count -gt $Global:LogHomeMax) {
            $Global:LogHome.RemoveAt($Global:LogHome.Count - 1)
        }
    }
    if ($dispatcher -and -not $dispatcher.CheckAccess()) {
        $dispatcher.Invoke([action] $aplicar)
    } else {
        & $aplicar
        # Operacoes sincronas na thread de UI (sync, reenvio) travam o redesenho
        # ate terminarem. Um flush aqui faz o feed "ATIVIDADE" atualizar ao vivo.
        if ($dispatcher -and -not $Global:ModoTeste) {
            try {
                $dispatcher.Invoke([action] { }, [Windows.Threading.DispatcherPriority]::Background)
            } catch { }
        }
    }

    # Espelho no console (modo -SemUI) e no arquivo.
    Write-Host ("{0}  {1}" -f $hora, $Mensagem)
    $arq = Get-Variable -Name ArquivoLog -Scope Global -ErrorAction SilentlyContinue
    if ($arq -and $arq.Value) {
        "{0}  [{1}]  {2}" -f $hora, $Nivel, $Mensagem |
            Add-Content -Path $arq.Value -Encoding UTF8
    }
}
