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
        # Na thread de UI: so adiciona a entrada. NAO faz mais "flush" via
        # $dispatcher.Invoke() aninhado - isso virava um pump reentrante que
        # processava eventos pendentes (clique, render de outra view) no meio de
        # um handler, causando reentrancia e "o fluxo nao era legivel". O feed
        # de log atualiza no proximo ciclo natural de render (imperceptivel);
        # operacao longa na UI deve ser assincrona (Start-TrabalhoHome), nao
        # depender deste flush.
        & $aplicar
    }

    # Espelho no console e no arquivo. Usa [Console]::Out (stdout do processo)
    # em vez de Write-Host: assim as chamadas feitas de dentro de um runspace
    # tambem aparecem na janela do PowerShell. NUNCA propaga erro.
    try { [Console]::Out.WriteLine("{0}  {1}" -f $hora, $Mensagem) }
    catch { try { Write-Host ("{0}  {1}" -f $hora, $Mensagem) } catch { } }
    $arq = Get-Variable -Name ArquivoLog -Scope Global -ErrorAction SilentlyContinue
    if ($arq -and $arq.Value) {
        try {
            "{0}  [{1}]  {2}" -f $hora, $Nivel, $Mensagem |
                Add-Content -Path $arq.Value -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }
}
