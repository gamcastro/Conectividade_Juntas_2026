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

function New-ResultadoJson {
    param(
        [psobject] $Ambiente,
        [psobject] $Metricas,
        [psobject] $Decisao,
        $Local,
        $Avaliacoes,
        $ClassificacaoFinal,
        [string]   $TecnicoNome
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
