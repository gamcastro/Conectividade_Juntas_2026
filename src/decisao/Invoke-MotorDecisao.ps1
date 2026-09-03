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

# ----------------------------------------------------------------------------
# RECOMENDACAO DE CONEXAO (regra multi-meio)
#
# Cada local pode ter varias "medicoes", uma por meio de conexao. A ferramenta
# recomenda qual meio a Junta Especial deve usar naquele local.
# ----------------------------------------------------------------------------

# Rotulo de exibicao de um meio.
function Get-RotuloMeio {
    param([string] $Meio, [string] $Operadora)
    switch ($Meio) {
        'lan'        { 'Rede cabeada (LAN)' }
        'wifi_local' { 'Wi-Fi do proprio local' }
        'celular'    { if ($Operadora) { "Wi-Fi roteada de celular - $Operadora" } else { 'Wi-Fi roteada de celular' } }
        'nenhuma'    { 'Nenhuma - local inviavel por qualquer meio' }
        default      { [string] $Meio }
    }
}

# Ordem para o pior caso: viavel < ressalva < inviavel < (sem veredito).
function Get-RankVeredito {
    param([string] $V)
    switch ($V) {
        'viavel'              { 0 }
        'viavel_com_ressalva' { 1 }
        'ressalva'            { 1 }
        'inviavel'            { 2 }
        default               { 3 }
    }
}

# Escolhe o meio de conexao recomendado a partir das medicoes do local.
# Cada $Medicao (pscustomobject) precisa expor:
#   meio              'lan' | 'wifi_local' | 'celular'
#   operadora         string (so p/ celular)
#   nao_aplicavel     bool  (o meio nao pode ser usado nesse local)
#   veredito          'viavel' | 'viavel_com_ressalva' | 'inviavel' | 'nao_testado'
#   rede_local_ok     bool  (a checagem de Rede Local / Ookla rodou e deu numero)
#   rede_local_download  Mbps | $null
#   vpn_conectou      bool  (a VPN conectou por esse meio)
#   fase2_ok          bool  (a bateria com VPN - iperf3 + ping - rodou)
#   vpn_download      Mbps | $null
#
# Regra:
#   1) candidato = fechou Rede Local + VPN + Fase 2. Recomenda o de melhor
#      veredito; desempate = maior download pela VPN.
#   2) se NINGUEM fechou a VPN mas algum rodou a Rede Local -> recomenda o de
#      maior download na Rede Local, marcado como PROVISORIO e local inviavel.
#   3) nada -> "nenhuma".
function Get-ConexaoRecomendada {
    param([object[]] $Medicoes)

    $validas = @($Medicoes | Where-Object { $_ -and -not [bool] $_.nao_aplicavel -and $_.veredito -ne 'nao_testado' })

    $cand = @($validas | Where-Object { [bool] $_.rede_local_ok -and [bool] $_.vpn_conectou -and [bool] $_.fase2_ok })
    if ($cand.Count) {
        $rec = $cand |
            Sort-Object `
                @{ Expression = { Get-RankVeredito ([string] $_.veredito) } }, `
                @{ Expression = { if ($null -eq $_.vpn_download) { -1 } else { [double] $_.vpn_download } }; Descending = $true } |
            Select-Object -First 1
        return [pscustomobject]@{
            meio       = [string] $rec.meio
            operadora  = [string] $rec.operadora
            rotulo     = Get-RotuloMeio ([string] $rec.meio) ([string] $rec.operadora)
            veredito   = [string] $rec.veredito
            provisoria = $false
            base       = 'vpn'
        }
    }

    $comRl = @($validas | Where-Object { [bool] $_.rede_local_ok })
    if ($comRl.Count) {
        $rec = $comRl |
            Sort-Object @{ Expression = { if ($null -eq $_.rede_local_download) { -1 } else { [double] $_.rede_local_download } }; Descending = $true } |
            Select-Object -First 1
        return [pscustomobject]@{
            meio       = [string] $rec.meio
            operadora  = [string] $rec.operadora
            rotulo     = Get-RotuloMeio ([string] $rec.meio) ([string] $rec.operadora)
            veredito   = 'inviavel'   # nao fechou a bateria com a VPN
            provisoria = $true
            base       = 'rede_local'
        }
    }

    return [pscustomobject]@{
        meio = 'nenhuma'; operadora = ''
        rotulo = Get-RotuloMeio 'nenhuma' ''
        veredito = 'inviavel'; provisoria = $false; base = 'nenhuma'
    }
}

# Avaliacao da FASE 1 (rede local, sem VPN) a partir do resultado do Speedtest
# (Ookla). Mesma forma de Invoke-MotorDecisao().Detalhes, com a metrica prefixada
# "rl_" (p/ nao colidir com as linhas da Fase 2) e sem 'carregamento_web' (nao ha
# Selenium sem a VPN). So devolve linhas se o Speedtest tiver medido.
function Get-DetalhesRedeLocal {
    param($Internet, [psobject] $Limiares)
    if (-not $Internet -or -not $Limiares) { return @() }
    $g = {
        param($o, $n)
        $p = $o.PSObject.Properties[$n]
        if ($p) { $p.Value } else { $null }
    }
    if (-not (& $g $Internet 'speedtest_ok')) { return @() }
    $met = [pscustomobject]@{
        LatenciaMediaMs   = (& $g $Internet 'ping_ms')
        JitterMs          = (& $g $Internet 'jitter_ms')
        PerdaPercentual   = (& $g $Internet 'perda_pct')
        BandaDownloadMbps = (& $g $Internet 'download_mbps')
        BandaUploadMbps   = (& $g $Internet 'upload_mbps')
        CarregamentoWebS  = $null
    }
    $dec = Invoke-MotorDecisao -Metricas $met -Limiares $Limiares
    $out = @()
    foreach ($d in @($dec.Detalhes)) {
        if ($d.metrica -eq 'carregamento_web_s') { continue }
        $out += [pscustomobject]@{
            metrica         = 'rl_' + $d.metrica
            rotulo          = $d.rotulo
            unidade         = $d.unidade
            direcao         = $d.direcao
            valor           = $d.valor
            limiar_viavel   = $d.limiar_viavel
            limiar_ressalva = $d.limiar_ressalva
            classe          = $d.classe
            motivo          = $d.motivo
        }
    }
    return $out
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
