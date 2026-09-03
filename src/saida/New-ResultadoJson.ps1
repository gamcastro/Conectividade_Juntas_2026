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

# Avaliacao da Fase 1 (rede local, sem VPN) para o JSON: classifica o resultado
# do Speedtest contra os limiares e aplica os ajustes do tecnico (chaves "rl_").
function Get-AvaliacaoRedeLocalJson {
    param($Internet, $Overrides)
    $det = @(Get-DetalhesRedeLocal -Internet $Internet -Limiares (Get-LimiaresConfig))
    $out = @()
    foreach ($d in $det) {
        $o  = if ($Overrides) { $Overrides[$d.metrica] } else { $null }
        $cf = if ($o -and $o.classe_final) { [string] $o.classe_final } else { [string] $d.classe }
        $ju = if ($o) { [string] $o.justificativa } else { '' }
        $out += [pscustomobject]@{
            metrica           = $d.metrica
            rotulo            = $d.rotulo
            valor             = $d.valor
            unidade           = $d.unidade
            direcao           = $d.direcao
            limiar_viavel     = $d.limiar_viavel
            limiar_ressalva   = $d.limiar_ressalva
            classe_automatica = $d.classe
            classe_final      = $cf
            ajustada          = ($cf -ne $d.classe)
            justificativa     = $ju
        }
    }
    return $out
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
        [string]   $Operadora,
        # Nao foi possivel conectar a VPN da JE no local (bateria nao rodou).
        [bool]     $VpnImpossivel,
        [string]   $VpnMotivo,
        # Multi-meio: lista de medicoes (uma por meio de conexao) e a
        # recomendacao final (objeto de Get-ConexaoRecomendada). Opcionais.
        $Medicoes,
        $ConexaoRecomendada,
        [string]   $MotivoRecomendacao,
        # Anexo do formulario GEL (coordenadas / suporte / eletrica). Opcional.
        $VistoriaGel
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
        # placa efetivamente usada: os campos ip/mascara/gateway/dns/mac saem
        # dela (LAN ou Wi-Fi).
        $tipoUsado = [string] (Get-Prop $FaseLocal 'TipoUsado')
        $ativa = if ($tipoUsado -eq 'wifi') { $wf }
                 elseif ($tipoUsado -eq 'lan') { $lan }
                 elseif ([string] (Get-Prop $lan 'ipv4')) { $lan }
                 else { $wf }
        $redeLocal = [pscustomobject]@{
            coletado_em            = (Get-Prop $FaseLocal 'Quando')
            host                   = [string] (Get-Prop $FaseLocal 'Host')
            placa_usada            = $tipoUsado
            lan_conectada          = [bool] (Get-Prop $lan 'conectado')
            lan_adaptador          = [string] (Get-Prop $lan 'nome')
            lan_descricao          = [string] (Get-Prop $lan 'descricao')
            lan_rede_je            = [bool] (Test-RedeJusticaEleitoral ([string] (Get-Prop $lan 'ipv4')))
            tethering_celular      = [bool] $Tethering
            operadora              = [string] $Operadora
            ip_local               = [string] (Get-Prop $ativa 'ipv4')
            ip_origem              = [string] (Get-Prop $ativa 'ip_origem')
            mascara                = [string] (Get-Prop $ativa 'mascara')
            gateway                = [string] (Get-Prop $ativa 'gateway')
            dns                    = @(Get-Prop $ativa 'dns')
            mac                    = [string] (Get-Prop $ativa 'mac')
            velocidade_mbps        = (Get-Prop $ativa 'velocidade_mbps')
            wireless_presente      = [bool] (Get-Prop $wf 'presente')
            wireless_conectado     = [bool] (Get-Prop $wf 'conectado')
            wireless_ssid          = [string] (Get-Prop $wf 'ssid')
            wireless_sinal_pct     = (Get-Prop $wf 'sinal_pct')
            wireless_ip_local      = [string] (Get-Prop $wf 'ipv4')
            wireless_redes         = @(Get-Prop $wf 'redes_disponiveis')
            speedtest_ok           = [bool] (Get-Prop $it 'speedtest_ok')
            speedtest_erro         = [string] (Get-Prop $it 'speedtest_erro')
            speedtest_falha_tipo   = [string] (Get-Prop $it 'speedtest_falha_tipo')
            speedtest_diagnostico  = [string] (Get-Prop $it 'speedtest_diagnostico')
            internet_provedor      = [string] (Get-Prop $it 'isp')
            internet_ip_externo    = [string] (Get-Prop $it 'ip_externo')
            internet_servidor      = ((([string] (Get-Prop $it 'servidor_nome')) + ' - ' + ([string] (Get-Prop $it 'servidor_local'))).Trim(' -'))
            internet_servidor_id   = (Get-Prop $it 'servidor_id')
            internet_ping_ms       = (Get-Prop $it 'ping_ms')
            internet_jitter_ms     = (Get-Prop $it 'jitter_ms')
            internet_perda_pct     = (Get-Prop $it 'perda_pct')
            internet_download_mbps = (Get-Prop $it 'download_mbps')
            internet_upload_mbps   = (Get-Prop $it 'upload_mbps')
            internet_resultado_url = [string] (Get-Prop $it 'resultado_url')
            internet_avaliacao     = @(Get-AvaliacaoRedeLocalJson $it $ovr)
        }
    }

    # --- multi-meio: medicoes + recomendacao ------------------------------
    $medicoesJson = @()
    foreach ($m in @($Medicoes)) {
        if (-not $m) { continue }
        $mIt  = Get-Prop (Get-Prop $m 'fase_local') 'Internet'
        $mMet = Get-Prop $m 'metricas'
        $mOvr = @{}
        foreach ($a in @(Get-Prop $m 'avaliacoes')) { if ($a -and $a.metrica) { $mOvr[[string] $a.metrica] = $a } }
        $medicoesJson += [pscustomobject]@{
            meio                 = [string] (Get-Prop $m 'meio')
            operadora            = [string] (Get-Prop $m 'operadora')
            rotulo               = [string] (Get-Prop $m 'rotulo')
            nao_aplicavel        = [bool] (Get-Prop $m 'nao_aplicavel')
            motivo_nao_aplicavel = [string] (Get-Prop $m 'motivo_na')
            rede_local_ok        = [bool] (Get-Prop $m 'rede_local_ok')
            rede_local_download  = (Get-Prop $m 'rede_local_download')
            rede_local_provedor  = [string] (Get-Prop $mIt 'isp')
            rede_local_falha_tipo  = [string] (Get-Prop $mIt 'speedtest_falha_tipo')
            rede_local_diagnostico = [string] (Get-Prop $mIt 'speedtest_diagnostico')
            rede_local_avaliacao   = @(Get-AvaliacaoRedeLocalJson $mIt $mOvr)
            vpn_conectou         = [bool] (Get-Prop $m 'vpn_conectou')
            vpn_motivo           = [string] (Get-Prop $m 'vpn_motivo')
            vpn_download_mbps     = (Get-Prop $mMet 'BandaDownloadMbps')
            vpn_upload_mbps       = (Get-Prop $mMet 'BandaUploadMbps')
            latencia_ms           = (Get-Prop $mMet 'LatenciaMediaMs')
            jitter_ms             = (Get-Prop $mMet 'JitterMs')
            perda_percentual      = (Get-Prop $mMet 'PerdaPercentual')
            veredito             = [string] (Get-Prop $m 'veredito')
            quando               = [string] (Get-Prop $m 'quando')
        }
    }

    $recJson = $null
    if ($ConexaoRecomendada) {
        $recJson = [pscustomobject]@{
            meio       = [string] (Get-Prop $ConexaoRecomendada 'meio')
            operadora  = [string] (Get-Prop $ConexaoRecomendada 'operadora')
            rotulo     = [string] (Get-Prop $ConexaoRecomendada 'rotulo')
            veredito   = [string] (Get-Prop $ConexaoRecomendada 'veredito')
            provisoria = [bool] (Get-Prop $ConexaoRecomendada 'provisoria')
            base       = [string] (Get-Prop $ConexaoRecomendada 'base')
            motivo     = [string] $MotivoRecomendacao
        }
        # a decisao final do local passa a ser o veredito do meio recomendado,
        # salvo override explicito do tecnico.
        if (-not ($ClassificacaoFinal -and $ClassificacaoFinal.final)) {
            $finalDecisao = [string] (Get-Prop $ConexaoRecomendada 'veredito')
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
        vistoria_gel       = $(if ($VistoriaGel) {
            [pscustomobject]@{
                latitude          = (Get-Prop $VistoriaGel 'lat')
                longitude         = (Get-Prop $VistoriaGel 'long')
                precisao_m        = (Get-Prop $VistoriaGel 'precisao_m')
                mapa_link         = [string] (Get-Prop $VistoriaGel 'mapa_link')
                tipo_local        = [pscustomobject]@{
                    esfera_administrativa = [string] (Get-Prop $VistoriaGel 'esfera_administrativa')
                    localizacao           = [string] (Get-Prop $VistoriaGel 'localizacao')
                    tipo                  = [string] (Get-Prop $VistoriaGel 'tipo_local')
                }
                infraestrutura    = [pscustomobject]@{
                    salas_necessarias = [string] (Get-Prop $VistoriaGel 'salas_necessarias')
                    agua              = [string] (Get-Prop $VistoriaGel 'agua')
                    climatizacao      = [string] (Get-Prop $VistoriaGel 'climatizacao')
                    iluminacao        = [string] (Get-Prop $VistoriaGel 'iluminacao')
                    agua_potavel      = [string] (Get-Prop $VistoriaGel 'agua_potavel')
                    predio_reforma    = [string] (Get-Prop $VistoriaGel 'predio_reforma')
                }
                eletrica          = [pscustomobject]@{
                    quadro_energia    = [string] (Get-Prop $VistoriaGel 'quadro_energia')
                    energia_eletrica  = [string] (Get-Prop $VistoriaGel 'energia_eletrica')
                    tomadas           = [string] (Get-Prop $VistoriaGel 'eletrica_tomadas')
                    tensao            = [string] (Get-Prop $VistoriaGel 'eletrica_tensao')
                    extensao          = [string] (Get-Prop $VistoriaGel 'eletrica_extensao')
                }
                suporte_nome      = [string] (Get-Prop $VistoriaGel 'suporte_nome')
                suporte_telefone  = [string] (Get-Prop $VistoriaGel 'suporte_telefone')
                fotos             = @(Get-FotosGel -LocalId ([string] (Get-Prop $Local 'id'))).Count
                # compat: campos planos anteriores
                eletrica_tensao   = [string] (Get-Prop $VistoriaGel 'eletrica_tensao')
                eletrica_tomadas  = [string] (Get-Prop $VistoriaGel 'eletrica_tomadas')
                eletrica_extensao = [string] (Get-Prop $VistoriaGel 'eletrica_extensao')
            }
        } else { $null })
        vpn               = [pscustomobject]@{ impossivel = [bool] $VpnImpossivel; motivo = [string] $VpnMotivo }
        medicoes          = @($medicoesJson)
        conexao_recomendada = $recJson
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
