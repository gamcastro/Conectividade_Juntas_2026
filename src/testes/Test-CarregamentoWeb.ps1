# Tempo de carregamento do sistema de totalizacao (app web) via Selenium
# WebDriver, testado no Firefox customizado de producao e no Chrome.
#
# STUB: implementar a carga do Selenium.WebDriver.dll (lib\Selenium) e a medicao
# via Navigation Timing API:
#   performance.timing.loadEventEnd - performance.timing.navigationStart
# Os drivers (geckodriver/chromedriver) ficam em bin\ e devem ser lancados com
# Start-ProcessoNaoElevado.

function Test-CarregamentoWeb {
    param(
        [string]   $Url,
        [string[]] $Navegadores = @('firefox', 'chrome'),
        [int]      $TimeoutS = 60
    )

    Write-Log "Medindo carregamento de $Url em: $($Navegadores -join ', ')" -Nivel Info

    $medicoes = foreach ($nav in $Navegadores) {
        # TODO: substituir pela medicao real com Selenium.
        Write-Log "[STUB] carregamento de $Url no $nav ainda nao implementado" -Nivel Aviso
        [pscustomobject]@{ Navegador = $nav; TempoS = $null; Erro = 'nao implementado' }
    }

    $validos = @($medicoes | Where-Object { $null -ne $_.TempoS } | Select-Object -ExpandProperty TempoS)
    $medio   = if ($validos.Count) { [math]::Round((($validos | Measure-Object -Average).Average), 2) } else { $null }

    [pscustomobject]@{
        Url         = $Url
        Medicoes    = $medicoes
        TempoMedioS = $medio
    }
}
