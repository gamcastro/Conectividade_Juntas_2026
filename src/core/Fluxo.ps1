# Orquestracao da bateria. Invoke-DiagnosticoCompleto SO coleta + classifica e
# devolve o payload; a gravacao/envio fica em Save-Diagnostico (chamado pela GUI
# no botao "Salvar resultado", depois dos ajustes do tecnico).

function Invoke-DiagnosticoCompleto {
    param(
        # Objeto do local selecionado (uma entrada de Get-Juntas).
        $Local
    )

    if ($null -eq $Local) {
        $Local = [pscustomobject]@{ id = 'SEM_ID'; nome = ''; tipo = ''; municipio_termo = '' }
    }

    $cfgAmbiente = Get-Config 'ambiente'
    $limiares    = Get-LimiaresConfig

    Write-Log 'Iniciando diagnostico de conectividade' -Nivel Destaque
    Write-Log ("Local: ZE {0} - {1} / {2} ({3})" -f $Local.zona_eleitoral, $Local.municipio_termo, $Local.nome, $Local.tipo) -Nivel Info

    $ambiente = Get-EstadoAmbiente
    if ($ambiente.vpn_ativa -eq $false) {
        Write-Log 'VPN nao detectada - os resultados podem nao refletir a rede da JE' -Nivel Aviso
    }

    # --- Coleta (so roda o teste se alguma metrica dele estiver ativa) -----
    function Test-LimiarAtivo { param([string] $M)
        $o = $limiares.$M
        if ($null -eq $o) { return $true }
        $p = $o.PSObject.Properties['ativo']
        if (-not $p) { return $true }
        return [bool] $p.Value
    }
    $usaPing  = (Test-LimiarAtivo 'latencia_ms') -or (Test-LimiarAtivo 'jitter_ms') -or (Test-LimiarAtivo 'perda_percentual')
    $usaBanda = (Test-LimiarAtivo 'banda_download_mbps') -or (Test-LimiarAtivo 'banda_upload_mbps')
    $usaWeb   = (Test-LimiarAtivo 'carregamento_web_s')

    $lat = if ($usaPing) {
        Test-Latencia -Alvo $cfgAmbiente.ping.alvo -Amostras $cfgAmbiente.ping.amostras
    } else { Write-Log 'Ping desativado pela configuracao (admin).' -Nivel Aviso; [pscustomobject]@{ LatenciaMediaMs = $null; JitterMs = $null; PerdaPercentual = $null } }

    $band = if ($usaBanda) {
        Test-BandaVpn -Servidor $cfgAmbiente.iperf3.servidor -Porta $cfgAmbiente.iperf3.porta `
                      -Duracao $cfgAmbiente.iperf3.duracao_s
    } else { Write-Log 'Teste de banda (iperf3) desativado pela configuracao (admin).' -Nivel Aviso; [pscustomobject]@{ DownloadMbps = $null; UploadMbps = $null } }

    $web = if ($usaWeb) {
        Test-CarregamentoWeb -Url $cfgAmbiente.totalizacao.url `
                             -Navegadores $cfgAmbiente.totalizacao.navegadores `
                             -TimeoutS $cfgAmbiente.totalizacao.timeout_s
    } else { Write-Log 'Teste de carregamento web desativado pela configuracao (admin).' -Nivel Aviso; [pscustomobject]@{ TempoMedioS = $null } }

    $metricas = [pscustomobject]@{
        LatenciaMediaMs   = $lat.LatenciaMediaMs
        JitterMs          = $lat.JitterMs
        PerdaPercentual   = $lat.PerdaPercentual
        BandaDownloadMbps = $band.DownloadMbps
        BandaUploadMbps   = $band.UploadMbps
        CarregamentoWebS  = $web.TempoMedioS
    }

    $decisao = Invoke-MotorDecisao -Metricas $metricas -Limiares $limiares
    Write-Log ("Classificacao automatica: {0}" -f $decisao.Classificacao) -Nivel Destaque
    Write-Log 'Ajuste o painel se necessario e clique em "Salvar resultado".' -Nivel Info

    return [pscustomobject]@{
        Ambiente = $ambiente
        Metricas = $metricas
        Decisao  = $decisao
        Local    = $Local
        Iperf    = $band
    }
}

# Grava o resultado (com os ajustes do tecnico) e envia conforme config/envio.json.
#   -Avaliacoes: lista de @{ metrica; classe_final; justificativa }  (opcional)
#   -ClassificacaoFinal: @{ final; justificativa }                   (opcional)
function Save-Diagnostico {
    param(
        [Parameter(Mandatory)] $Ambiente,
        [Parameter(Mandatory)] $Metricas,
        [Parameter(Mandatory)] $Decisao,
        [Parameter(Mandatory)] $Local,
        $Avaliacoes,
        $ClassificacaoFinal,
        [string] $TecnicoNome,
        $FaseLocal,
        [bool] $Tethering,
        [string] $Operadora,
        [bool] $VpnImpossivel,
        [string] $VpnMotivo
    )

    $cfgEnvio = Get-Config 'envio'
    $Global:ConfigEnvio = $cfgEnvio

    $resultado = New-ResultadoJson -Ambiente $Ambiente -Metricas $Metricas -Decisao $Decisao `
        -Local $Local -Avaliacoes $Avaliacoes -ClassificacaoFinal $ClassificacaoFinal -TecnicoNome $TecnicoNome `
        -FaseLocal $FaseLocal -Tethering $Tethering -Operadora $Operadora `
        -VpnImpossivel $VpnImpossivel -VpnMotivo $VpnMotivo
    $caminho = Save-ResultadoLocal -Resultado $resultado

    if ($cfgEnvio.modo -eq 'na-hora') {
        try {
            Send-Resultado -Caminho $caminho -Endpoint $cfgEnvio.endpoint_apps_script `
                           -Retentativas $cfgEnvio.retentativas -IntervaloS $cfgEnvio.intervalo_retentativa_s
        } catch {
            Write-Log "Envio falhou; resultado ficou em pendentes: $_" -Nivel Erro
        }
    } else {
        Write-Log 'Modo offline-first: resultado salvo localmente. Reenviar com Send-ResultadosPendentes.' -Nivel Info
    }

    return $caminho
}
