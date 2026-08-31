# Motor de decisao: compara as metricas coletadas com os limiares configuraveis
# e gera a classificacao final.
#
#   viavel               -> todas as metricas na faixa ideal
#   viavel_com_ressalva  -> ao menos uma na faixa de ressalva, nenhuma inviavel
#   inviavel             -> ao menos uma fora da faixa de ressalva (ou sem medida)

# Pior caso de uma lista de classes de metrica {viavel, ressalva, inviavel}.
function Get-ClassificacaoFinal {
    param([string[]] $Classes)
    if ($Classes -contains 'inviavel')     { return 'inviavel' }
    elseif ($Classes -contains 'ressalva') { return 'viavel_com_ressalva' }
    else                                   { return 'viavel' }
}

function Invoke-MotorDecisao {
    param(
        [psobject] $Metricas,
        [psobject] $Limiares
    )

    if ($null -eq $Metricas) { throw 'Invoke-MotorDecisao: -Metricas nao informado.' }
    if ($null -eq $Limiares) { throw 'Invoke-MotorDecisao: -Limiares nao informado.' }

    # "menor e melhor": latencia, jitter, perda, tempo de carregamento.
    function Test-Maximo {
        param($Valor, $ViavelAte, $RessalvaAte, $Nome, $Rotulo, $Unidade)
        $classe = if ($null -eq $Valor)      { 'inviavel' }
                  elseif ($Valor -le $ViavelAte)   { 'viavel' }
                  elseif ($Valor -le $RessalvaAte) { 'ressalva' }
                  else                             { 'inviavel' }
        $motivo = if ($null -eq $Valor) { 'sem medida' }
                  elseif ($classe -eq 'viavel')   { "<= $ViavelAte" }
                  elseif ($classe -eq 'ressalva') { "<= $RessalvaAte" }
                  else                            { "> $RessalvaAte" }
        [pscustomobject]@{
            metrica = $Nome; rotulo = $Rotulo; unidade = $Unidade; direcao = 'max'
            valor = $Valor; limiar_viavel = $ViavelAte; limiar_ressalva = $RessalvaAte
            classe = $classe; motivo = $motivo
        }
    }

    # "maior e melhor": banda de download e upload.
    function Test-Minimo {
        param($Valor, $ViavelMin, $RessalvaMin, $Nome, $Rotulo, $Unidade)
        $classe = if ($null -eq $Valor)       { 'inviavel' }
                  elseif ($Valor -ge $ViavelMin)   { 'viavel' }
                  elseif ($Valor -ge $RessalvaMin) { 'ressalva' }
                  else                             { 'inviavel' }
        $motivo = if ($null -eq $Valor) { 'sem medida' }
                  elseif ($classe -eq 'viavel')   { ">= $ViavelMin" }
                  elseif ($classe -eq 'ressalva') { ">= $RessalvaMin" }
                  else                            { "< $RessalvaMin" }
        [pscustomobject]@{
            metrica = $Nome; rotulo = $Rotulo; unidade = $Unidade; direcao = 'min'
            valor = $Valor; limiar_viavel = $ViavelMin; limiar_ressalva = $RessalvaMin
            classe = $classe; motivo = $motivo
        }
    }

    $L = $Limiares

    # Metrica ativa? (o admin pode tirar itens da bateria; ausente = ativa)
    function Test-MetricaAtiva {
        param([string] $Metrica)
        $m = $L.$Metrica
        if ($null -eq $m) { return $true }
        $p = $m.PSObject.Properties['ativo']
        if (-not $p) { return $true }
        return [bool] $p.Value
    }

    $todas = @(
        @{ fn = { Test-Maximo $Metricas.LatenciaMediaMs   $L.latencia_ms.viavel_ate         $L.latencia_ms.ressalva_ate         'latencia_ms'         'Latencia'          'ms' };   m = 'latencia_ms' }
        @{ fn = { Test-Maximo $Metricas.JitterMs          $L.jitter_ms.viavel_ate           $L.jitter_ms.ressalva_ate           'jitter_ms'          'Jitter'           'ms' };   m = 'jitter_ms' }
        @{ fn = { Test-Maximo $Metricas.PerdaPercentual   $L.perda_percentual.viavel_ate    $L.perda_percentual.ressalva_ate    'perda_percentual'   'Perda de pacotes' '%' };    m = 'perda_percentual' }
        @{ fn = { Test-Minimo $Metricas.BandaDownloadMbps $L.banda_download_mbps.viavel_min $L.banda_download_mbps.ressalva_min 'banda_download_mbps' 'Download'         'Mbps' }; m = 'banda_download_mbps' }
        @{ fn = { Test-Minimo $Metricas.BandaUploadMbps   $L.banda_upload_mbps.viavel_min   $L.banda_upload_mbps.ressalva_min   'banda_upload_mbps'   'Upload'          'Mbps' }; m = 'banda_upload_mbps' }
        @{ fn = { Test-Maximo $Metricas.CarregamentoWebS  $L.carregamento_web_s.viavel_ate  $L.carregamento_web_s.ressalva_ate  'carregamento_web_s' 'Carregamento web' 's' };   m = 'carregamento_web_s' }
    )

    $avaliacoes  = @()
    $desativadas = @()
    foreach ($item in $todas) {
        if (Test-MetricaAtiva $item.m) { $avaliacoes += (& $item.fn) }
        else { $desativadas += $item.m }
    }

    $classeFinal = Get-ClassificacaoFinal ($avaliacoes | Select-Object -ExpandProperty classe)

    [pscustomobject]@{
        Classificacao      = $classeFinal
        Detalhes           = $avaliacoes
        MetricasDesativadas = @($desativadas)
    }
}
