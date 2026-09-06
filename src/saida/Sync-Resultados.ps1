# Sincroniza de VOLTA os resultados ja transmitidos (planilha de Resultados) para
# resultados\enviados\ deste computador -- pra recuperar o "verdinho" do painel
# depois de formatar / trocar de notebook.
#
# Duas camadas (leve -> pesada):
#   1. 'resultados.listar'  -> indice leve (local_id + data + veredito), filtrado
#      pelo tecnico logado; nao traz o JSON.
#   2. 'resultados.obter'   -> o JSON completo, chamado SO' para os locais que
#      faltam aqui (ou que o servidor tem mais novo).
#
# Regras: nunca toca em resultados\pendentes\; so' ADICIONA em resultados\enviados\
# o que ainda nao existe localmente. As fotos da vistoria do GEL NAO voltam (so' a
# contagem vai no JSON) -- reanexar pelo GEL web depois, se precisar.
#
# RECONCILIACAO (opcional, config/envio.json > reconciliar_resultados = true;
# DESLIGADA por padrao): quando ligada e a chamada a planilha teve SUCESSO,
# arquivos em resultados\enviados\ deste tecnico cujo local_id NAO existe mais na
# planilha sao MOVIDOS para resultados\enviados\obsoletos\ (nao apagados) -- o
# painel para de conta-los. Util no ambiente de homologacao, onde a planilha e'
# zerada entre rodadas de teste. Nunca toca em pendentes\; nunca roda se a
# chamada falhou ou se -LocalIds foi passado.

function Test-ReconciliarResultadosLigado {
    if ($null -ne $Global:ReconciliarResultadosOverride) { return [bool] $Global:ReconciliarResultadosOverride }
    try {
        $cfg = Get-Config 'envio'
        if ($cfg -and $cfg.PSObject.Properties['reconciliar_resultados']) { return [bool] $cfg.reconciliar_resultados }
    } catch { }
    return $false   # padrao: DESLIGADA (seguro p/ producao)
}

# "dd/MM/yyyy HH:mm:ss" (formato de recebido_em do Codigo.gs) -> datetime. $null se nao der.
function ConvertFrom-DataResultado {
    param([string] $Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($f in @('dd/MM/yyyy HH:mm:ss', 'dd/MM/yyyy HH:mm', 'dd/MM/yyyy', "yyyy-MM-dd'T'HH:mm:ss", 'o')) {
        try { return [datetime]::ParseExact($Texto.Trim(), $f, $inv) } catch { }
    }
    try { return [datetime] $Texto } catch { return $null }
}

function Sync-Resultados {
    param(
        [string]   $TecnicoNome,
        [string[]] $LocalIds,
        [switch]   $Force        # rebaixa tudo, mesmo o que ja existe local
    )

    $resumo = [pscustomobject]@{ NoServidor = 0; Baixados = 0; JaTinha = 0; Falhas = 0; Obsoletos = 0 }

    $payload = @{}
    if (-not [string]::IsNullOrWhiteSpace($TecnicoNome)) { $payload['tecnico'] = [string] $TecnicoNome }
    if ($LocalIds -and $LocalIds.Count) { $payload['local_ids'] = [string[]] @($LocalIds) }

    Write-Log 'Sincronizando resultados ja transmitidos...' -Nivel Info

    $idx = $null
    try {
        $idx = Invoke-FuncaoAppsScript -Acao 'resultados.listar' -Payload $payload
    } catch {
        $m = "$_"
        if ($m -match 'acao desconhecida' -or $m -match 'resultados\.listar') {
            Write-Log 'O servidor ainda nao tem o recurso de sincronizacao de resultados (redeploy pendente).' -Nivel Aviso
            return $resumo
        }
        throw
    }

    # Chegar aqui = a chamada 'resultados.listar' teve SUCESSO (o catch acima
    # trata "recurso ausente" e re-lanca o resto). Base para a reconciliacao.
    $itens = @($idx.itens)
    $resumo.NoServidor = $itens.Count

    $locais  = Get-DiagnosticosRealizados     # hashtable local_id -> { Quando; ... }
    $destino = Join-Path $Global:RaizApp 'resultados\enviados'
    if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }

    if (-not $itens.Count) {
        Write-Log 'Nenhum resultado transmitido encontrado para este roteiro.' -Nivel Info
    }

    # ids p/ tentar puxar o GEL (Escopo 2): quando -LocalIds foi dado, todos os da
    # lista (poucos, explicito); senao so' os que forem baixados agora.
    $idsGel = New-Object System.Collections.Generic.List[string]

    foreach ($it in $itens) {
        $id = [string] $it.local_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($LocalIds -and $LocalIds.Count) { $idsGel.Add($id) }

        if (-not $Force -and $locais.ContainsKey($id)) {
            $qLocal = $null; try { $qLocal = [datetime] $locais[$id].Quando } catch { }
            $qServ  = ConvertFrom-DataResultado ([string] $it.recebido_em)
            # ja tem local e o do servidor nao e' comprovadamente mais novo -> pula
            if (-not $qServ -or ($qLocal -and $qServ -le $qLocal)) { $resumo.JaTinha++; continue }
        }

        try {
            $full = Invoke-FuncaoAppsScript -Acao 'resultados.obter' -Payload @{ local_id = $id; linha = [int] $it.linha }
            if (-not $full -or $full.erro -or [string]::IsNullOrWhiteSpace([string] $full.json)) {
                Write-Log ("Sem JSON para {0}: {1}" -f $id, $(if ($full) { $full.erro } else { 'resposta vazia' })) -Nivel Aviso
                $resumo.Falhas++; continue
            }
            $obj = $null
            try { $obj = $full.json | ConvertFrom-Json } catch {
                Write-Log ("JSON invalido para {0}: {1}" -f $id, $_) -Nivel Aviso
                $resumo.Falhas++; continue
            }
            $idSan = $id -replace '[^\w\-]', '_'
            $nome  = 'sync_{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $idSan
            Write-TextoArquivo -Caminho (Join-Path $destino $nome) -Conteudo ($obj | ConvertTo-Json -Depth 12)
            $resumo.Baixados++
            if (-not ($LocalIds -and $LocalIds.Count)) { $idsGel.Add($id) }
        } catch {
            Write-Log ("Falha ao baixar o resultado de {0}: {1}" -f $id, $_) -Nivel Erro
            $resumo.Falhas++
        }
    }

    # --- GEL (Escopo 2): puxa o formulario + fotos dos locais relevantes -------
    # Best-effort: nao sobrescreve anexo local, degrada quieto se o servidor nao
    # tiver o recurso. So' fora do modo de teste.
    if (-not $Global:ModoTeste -and $idsGel.Count) {
        $baixGel = 0
        foreach ($gid in ($idsGel | Select-Object -Unique)) {
            try { if (Get-VistoriaGelRemoto -LocalId $gid) { $baixGel++ } } catch { }
        }
        if ($baixGel) { Write-Log ("GEL: {0} formulario(s)/fotos baixado(s) da console." -f $baixGel) -Nivel Info }
    }

    # --- Reconciliacao (opcional, ver cabecalho) --------------------------------
    # So' roda com o toggle ligado, sem -LocalIds (senao a lista viria filtrada) e
    # depois de um 'resultados.listar' que SUCEDEU (garantido: chegamos ate aqui).
    if ((Test-ReconciliarResultadosLigado) -and -not $LocalIds) {
        try {
            $noServidor = @{}
            foreach ($it in $itens) {
                $sid = [string] $it.local_id
                if ($sid) { $noServidor[$sid.Trim().ToLower()] = $true }
            }
            $alvoTec = ([string] $TecnicoNome).Trim().ToLower()
            $obsDir  = Join-Path $destino 'obsoletos'

            foreach ($f in @(Get-ChildItem -Path $destino -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                $o = $null
                try { $o = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                $fid = ([string] $o.local.id).Trim()
                if (-not $fid) { continue }
                # so' julga arquivos DESTE tecnico (a lista do servidor veio filtrada por ele);
                # sem -TecnicoNome, julga todos.
                if ($alvoTec) {
                    $ftec = ([string] $o.tecnico.nome).Trim().ToLower()
                    if ($ftec -and $ftec -ne $alvoTec) { continue }
                }
                if ($noServidor.ContainsKey($fid.ToLower())) { continue }   # ainda existe na planilha

                if (-not (Test-Path $obsDir)) { New-Item -ItemType Directory -Path $obsDir -Force | Out-Null }
                Move-Item -Path $f.FullName -Destination (Join-Path $obsDir $f.Name) -Force
                $resumo.Obsoletos++
            }
            if ($resumo.Obsoletos) {
                Write-Log ("Reconciliacao: {0} resultado(s) local(is) sem correspondencia na planilha movido(s) para enviados\obsoletos\." -f $resumo.Obsoletos) -Nivel Aviso
            }
        } catch {
            Write-Log ("Reconciliacao de resultados nao concluida: {0}" -f $_) -Nivel Aviso
        }
    }

    $extra = if ($resumo.Obsoletos) { ", $($resumo.Obsoletos) obsoleto(s) arquivado(s)" } else { '' }
    Write-Log ("Sync de resultados: {0} baixado(s), {1} ja no computador, {2} falha(s){3}." -f `
               $resumo.Baixados, $resumo.JaTinha, $resumo.Falhas, $extra) `
              -Nivel $(if ($resumo.Falhas) { 'Aviso' } else { 'Ok' })
    return $resumo
}
