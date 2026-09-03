# Grava o resultado em resultados\pendentes\ (sempre salva local antes de enviar).

function Save-ResultadoLocal {
    param(
        [psobject] $Resultado
    )

    $pasta = Join-Path $Global:RaizApp 'resultados\pendentes'
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }

    $id      = if ($Resultado.local.id) { $Resultado.local.id } else { 'local' }
    $id      = ($id -replace '[^\w\-]', '_')
    $nome    = '{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $id
    $caminho = Join-Path $pasta $nome

    Write-TextoArquivo -Caminho $caminho -Conteudo ($Resultado | ConvertTo-Json -Depth 10)
    Write-Log "Resultado salvo em $caminho" -Nivel Ok
    return $caminho
}
