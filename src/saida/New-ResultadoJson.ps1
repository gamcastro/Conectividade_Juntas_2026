# Monta o objeto de resultado. Contrato em docs/formato-json.md.
#   -Avaliacoes:         lista de @{ metrica; classe_final; justificativa }  (ajustes do tecnico; opcional)
#   -ClassificacaoFinal: @{ final; justificativa }                          (override da decisao; opcional)

# Acesso seguro a um campo do local (cache externo pode nao ter a chave;
# a GUI roda com Set-StrictMode).
function Get-CampoLocal {
    param($Local, [string] $Nome)
    if ($null -eq $Local) { return '' }
    $p = $Local.PSObject.Properties[$Nome]
    if ($p) { return [string] $p.Value }
    return ''
}

# Acesso seguro a uma propriedade qualquer (objetos vindos da GUI, StrictMode).
function Get-Prop {
    param($Obj, [string] $Nome)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Nome]
    if ($p) { return $p.Value }
    return $null
}

function New-ResultadoJson {
    param(
        [psobject] $Ambiente,
        [psobject] $Metricas,
        [psobject] $Decisao,
        $Local,
        $Avaliacoes,
        $ClassificacaoFinal,
        [string]   $TecnicoNome,
        # Payload da fase 1 (rede local, sem VPN) - de Invoke-FaseLocal. Opcional.
        $FaseLocal,
        # Rede do local veio do roteamento (tethering) do celular do tecnico?
        [bool]     $Tethering,
        [string]   $Operadora
    )

    # index metrica -> override do tecnico
    $ovr = @{}
    foreach ($a in @($Avaliacoes)) {
        if ($a -and $a.metrica) { $ovr[$a.metrica] = $a }
    }

    $avaliacao = foreach ($d in @($Decisao.Detalhes)) {
        $o           = $ovr[$d.metrica]
        $classeFinal = if ($o -and $o.classe_final) { [string] $o.classe_final } else { [string] $d.classe }
        $just        = if ($o) { [string] $o.justificativa } else { '' }
        [pscustomobject]@{
            metrica           = $d.metrica
            rotulo            = $d.rotulo
            valor             = $d.valor
            unidade           = $d.unidade
            direcao           = $d.direcao
            limiar_viavel     = $d.limiar_viavel
            limiar_ressalva   = $d.limiar_ressalva
            classe_automatica = $d.classe
            classe_final      = $classeFinal
            ajustada          = ($classeFinal -ne $d.classe)
            justificativa     = $just
        }
    }
    $avaliacao = @($avaliacao)

    $recalc = Get-ClassificacaoFinal ($avaliacao | Select-Object -ExpandProperty classe_final)
    $finalDecisao = if ($ClassificacaoFinal -and $ClassificacaoFinal.final) { [string] $ClassificacaoFinal.final } else { $recalc }
    $justDecisao  = if ($ClassificacaoFinal) { [string] $ClassificacaoFinal.justificativa } else { '' }

    # --- fase 1: rede local (sem VPN) ---------------------------------------
    $redeLocal = $null
    if ($FaseLocal) {
        $lan = Get-Prop $FaseLocal 'Lan'
        $wf  = Get-Prop $FaseLocal 'Wireless'
        $it  = Get-Prop $FaseLocal 'Internet'
        $redeLocal = [pscustomobject]@{
            coletado_em            = (Get-Prop $FaseLocal 'Quando')
            host                   = [string] (Get-Prop $FaseLocal 'Host')
            lan_conectada          = [bool] (Get-Prop $lan 'conectado')
            lan_adaptador          = [string] (Get-Prop $lan 'nome')
            lan_descricao          = [string] (Get-Prop $lan 'descricao')
            tethering_celular      = [bool] $Tethering
            operadora              = [string] $Operadora
            ip_local               = [string] (Get-Prop $lan 'ipv4')
            mascara                = [string] (Get-Prop $lan 'mascara')
            gateway                = [string] (Get-Prop $lan 'gateway')
            dns                    = @(Get-Prop $lan 'dns')
            mac                    = [string] (Get-Prop $lan 'mac')
            velocidade_mbps        = (Get-Prop $lan 'velocidade_mbps')
            wireless_presente      = [bool] (Get-Prop $wf 'presente')
            wireless_conectado     = [bool] (Get-Prop $wf 'conectado')
            wireless_ssid          = [string] (Get-Prop $wf 'ssid')
            wireless_sinal_pct     = (Get-Prop $wf 'sinal_pct')
            wireless_redes         = @(Get-Prop $wf 'redes_disponiveis')
            internet_ping_alvo     = [string] (Get-Prop $it 'ping_alvo')
            internet_ping_ms       = (Get-Prop $it 'ping_latencia_ms')
            internet_ping_min_ms   = (Get-Prop $it 'ping_min_ms')
            internet_ping_max_ms   = (Get-Prop $it 'ping_max_ms')
            internet_perda_pct     = (Get-Prop $it 'ping_perda_pct')
            internet_ping_saida    = @(Get-Prop $it 'ping_saida')
            internet_dns_nome      = [string] (Get-Prop $it 'dns_nome')
            internet_dns_ms        = (Get-Prop $it 'dns_ms')
            internet_tracert_host  = [string] (Get-Prop $it 'tracert_host')
            internet_tracert_saltos = (Get-Prop $it 'tracert_saltos')
            internet_tracert_saida = @(Get-Prop $it 'tracert_saida')
            internet_download_url  = [string] (Get-Prop $it 'download_url')
            internet_download_bytes = (Get-Prop $it 'download_bytes')
            internet_download_seg  = (Get-Prop $it 'download_seg')
            internet_download_mbps = (Get-Prop $it 'download_mbps')
            internet_download_saida = @(Get-Prop $it 'download_saida')
        }
    }

    [pscustomobject]@{
        versao_ferramenta = $Global:VersaoApp
        coletado_em       = (Get-Date).ToString('o')
        tecnico           = [pscustomobject]@{ nome = $TecnicoNome }
        local             = [pscustomobject]@{
            id                  = $Local.id
            zona_eleitoral      = $Local.zona_eleitoral
            municipio_sede      = $Local.municipio_sede
            municipio_termo     = $Local.municipio_termo
            tipo                = $Local.tipo
            nome                = $Local.nome
            endereco            = $Local.endereco
            unidade_consumidora = (Get-CampoLocal $Local 'unidade_consumidora')
            responsavel         = (Get-CampoLocal $Local 'responsavel')
            funcao              = (Get-CampoLocal $Local 'funcao')
            telefone            = (Get-CampoLocal $Local 'telefone')
            tipo_internet       = $Local.tipo_internet
        }
        rede_local        = $redeLocal
        ambiente          = $Ambiente
        metricas          = [pscustomobject]@{
            latencia_ms         = $Metricas.LatenciaMediaMs
            jitter_ms           = $Metricas.JitterMs
            perda_percentual    = $Metricas.PerdaPercentual
            banda_download_mbps = $Metricas.BandaDownloadMbps
            banda_upload_mbps   = $Metricas.BandaUploadMbps
            carregamento_web_s  = $Metricas.CarregamentoWebS
        }
        avaliacao         = $avaliacao
        metricas_desativadas = @(if ($Decisao.PSObject.Properties['MetricasDesativadas']) { $Decisao.MetricasDesativadas })
        classificacao     = [pscustomobject]@{
            automatica    = $Decisao.Classificacao
            recalculada   = $recalc
            final         = $finalDecisao
            ajustada      = ($finalDecisao -ne $recalc)
            justificativa = $justDecisao
        }
        envio             = [pscustomobject]@{
            status     = 'pendente'
            tentativas = 0
            enviado_em = $null
        }
    }
}
