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
    param($Internet, $Overrides, [string] $Meio = 'lan')
    $mp = if ($Meio -in @('lan', 'wifi_local', 'celular')) { $Meio } else { 'lan' }
    $det = @(Get-DetalhesRedeLocal -Internet $Internet -Limiares (Get-PerfilLimiares -Meio $mp -Cenario 'sem_vpn'))
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
        # perfil de limiares SEM VPN para a avaliacao top-level: meio recomendado,
        # ou a placa usada na Fase 1 (wifi->wifi_local; senao lan).
        $limiaresMeioTop = if ($ConexaoRecomendada -and (Get-Prop $ConexaoRecomendada 'meio') -in @('lan', 'wifi_local', 'celular')) {
            [string] (Get-Prop $ConexaoRecomendada 'meio')
        } elseif ($tipoUsado -eq 'wifi') { 'wifi_local' } else { 'lan' }
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
            internet_avaliacao     = @(Get-AvaliacaoRedeLocalJson $it $ovr $limiaresMeioTop)
        }
    }

    # --- multi-meio: medicoes + recomendacao ------------------------------
    $medicoesJson = @()
    foreach ($m in @($Medicoes)) {
        if (-not $m) { continue }
        $mIt   = Get-Prop (Get-Prop $m 'fase_local') 'Internet'
        $mMet  = Get-Prop $m 'metricas'
        $mMeio = [string] (Get-Prop $m 'meio')
        $mOvr = @{}
        foreach ($a in @(Get-Prop $m 'avaliacoes')) { if ($a -and $a.metrica) { $mOvr[[string] $a.metrica] = $a } }
        # Dados da placa usada neste meio, do snapshot congelado no momento do
        # teste (nao do inventario ao vivo, que pode ter mudado depois com
        # outro meio ja testado ou um probe geral). Velocidade do link entra
        # para LAN e Wi-Fi do local; banda/sinal/SSID so' para Wi-Fi do local
        # (no roteamento de celular nao faz sentido informar isso).
        $mSnap = Get-Prop $m 'snapshot_adaptador'
        $mVelocidadeLink = if ($mMeio -in @('lan', 'wifi_local')) { Get-Prop $mSnap 'velocidade_mbps' } else { $null }
        $mWifiBanda = ''; $mWifiSinal = $null; $mWifiSsid = ''
        if ($mMeio -eq 'wifi_local') {
            $mWifiBanda = [string] (Get-Prop $mSnap 'banda_ghz')
            $mWifiSinal = Get-Prop $mSnap 'sinal_pct'
            $mWifiSsid  = [string] (Get-Prop $mSnap 'ssid')
        }
        $medicoesJson += [pscustomobject]@{
            meio                 = $mMeio
            operadora            = [string] (Get-Prop $m 'operadora')
            rotulo               = [string] (Get-Prop $m 'rotulo')
            nao_aplicavel        = [bool] (Get-Prop $m 'nao_aplicavel')
            motivo_nao_aplicavel = [string] (Get-Prop $m 'motivo_na')
            rede_local_ok        = [bool] (Get-Prop $m 'rede_local_ok')
            rede_local_download  = (Get-Prop $m 'rede_local_download')
            rede_local_provedor  = [string] (Get-Prop $mIt 'isp')
            rede_local_falha_tipo  = [string] (Get-Prop $mIt 'speedtest_falha_tipo')
            rede_local_diagnostico = [string] (Get-Prop $mIt 'speedtest_diagnostico')
            rede_local_velocidade_link_mbps = $mVelocidadeLink
            rede_local_wifi_banda           = $mWifiBanda
            rede_local_wifi_sinal_pct       = $mWifiSinal
            rede_local_wifi_ssid            = $mWifiSsid
            limiares_meio          = $mMeio
            rede_local_avaliacao   = @(Get-AvaliacaoRedeLocalJson $mIt $mOvr $mMeio)
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

    $modoAval = try { Get-ModoAvaliacao } catch { 'medicao' }

    $recJson = $null
    if ($ConexaoRecomendada) {
        $recJson = [pscustomobject]@{
            meio          = [string] (Get-Prop $ConexaoRecomendada 'meio')
            operadora     = [string] (Get-Prop $ConexaoRecomendada 'operadora')
            rotulo        = [string] (Get-Prop $ConexaoRecomendada 'rotulo')
            veredito      = [string] (Get-Prop $ConexaoRecomendada 'veredito')
            provisoria    = [bool] (Get-Prop $ConexaoRecomendada 'provisoria')
            base          = [string] (Get-Prop $ConexaoRecomendada 'base')
            informativo   = [bool] (Get-Prop $ConexaoRecomendada 'informativo')
            download_mbps = (Get-Prop $ConexaoRecomendada 'download_mbps')
            motivo        = [string] $MotivoRecomendacao
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
        modo_avaliacao    = $modoAval
        rede_local        = $redeLocal
        vistoria_gel       = (New-BlocoVistoriaGel -VistoriaGel $VistoriaGel -LocalId ([string] (Get-Prop $Local 'id')))
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
