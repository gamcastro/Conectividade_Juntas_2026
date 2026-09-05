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

    $resumo = [pscustomobject]@{ NoServidor = 0; Baixados = 0; JaTinha = 0; Falhas = 0 }

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

    $itens = @($idx.itens)
    $resumo.NoServidor = $itens.Count
    if (-not $itens.Count) {
        Write-Log 'Nenhum resultado transmitido encontrado para este roteiro.' -Nivel Info
        return $resumo
    }

    $locais  = Get-DiagnosticosRealizados     # hashtable local_id -> { Quando; ... }
    $destino = Join-Path $Global:RaizApp 'resultados\enviados'
    if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }

    foreach ($it in $itens) {
        $id = [string] $it.local_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

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
        } catch {
            Write-Log ("Falha ao baixar o resultado de {0}: {1}" -f $id, $_) -Nivel Erro
            $resumo.Falhas++
        }
    }

    Write-Log ("Sync de resultados: {0} baixado(s), {1} ja no computador, {2} falha(s)." -f `
               $resumo.Baixados, $resumo.JaTinha, $resumo.Falhas) `
              -Nivel $(if ($resumo.Falhas) { 'Aviso' } else { 'Ok' })
    return $resumo
}
