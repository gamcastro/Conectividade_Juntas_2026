# Log colorido. Alimenta uma ObservableCollection ligada por binding a lista da
# janela WPF (fundo preto) e espelha em arquivo texto.
#
# Convencao do projeto: nunca [Parameter(Mandatory=$true)] em parametro string
# de funcao de log.

if (-not (Get-Variable -Name LogEntries -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:LogEntries = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
}

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

    if ($dispatcher -and -not $dispatcher.CheckAccess()) {
        $dispatcher.Invoke([action] { $Global:LogEntries.Add($entrada) })
    } else {
        $Global:LogEntries.Add($entrada)
    }

    # Espelho no console (modo -SemUI) e no arquivo.
    Write-Host ("{0}  {1}" -f $hora, $Mensagem)
    $arq = Get-Variable -Name ArquivoLog -Scope Global -ErrorAction SilentlyContinue
    if ($arq -and $arq.Value) {
        "{0}  [{1}]  {2}" -f $hora, $Nivel, $Mensagem |
            Add-Content -Path $arq.Value -Encoding UTF8
    }
}
