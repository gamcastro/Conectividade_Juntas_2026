#Requires -Version 5.1
# Carregador do modulo. Faz dot-source dos arquivos na ordem de dependencia.

$ErrorActionPreference = 'Stop'

$ordem = @(
    'core\Config.ps1'
    'core\Log.ps1'
    'core\Elevacao.ps1'
    'core\Processos.ps1'
    'core\Ambiente.ps1'
    'core\RedeLocal.ps1'
    'core\Juntas.ps1'
    'core\Limiares.ps1'
    'core\Sessao.ps1'
    'core\Admin.ps1'
    'core\Roteiros.ps1'
    'ui\Modelos.ps1'
    'testes\Test-Latencia.ps1'
    'testes\Test-Banda.ps1'
    'testes\Test-CarregamentoWeb.ps1'
    'decisao\Invoke-MotorDecisao.ps1'
    'saida\New-ResultadoJson.ps1'
    'saida\Save-ResultadoLocal.ps1'
    'saida\Send-Resultado.ps1'
    'saida\Get-DiagnosticosRealizados.ps1'
    'saida\Export-RelatorioPdf.ps1'
    'core\Fluxo.ps1'
    'ui\Janela-Principal.ps1'
)

foreach ($rel in $ordem) {
    . (Join-Path $PSScriptRoot $rel)
}

# Versao do DICON. Fonte unica: barra lateral + login da GUI, JSON de resultado
# e relatorio PDF. Manter em sincronia com ModuleVersion em Conectividade.psd1.
$Global:VersaoApp = '0.6.49'

Export-ModuleMember -Function '*-*'
