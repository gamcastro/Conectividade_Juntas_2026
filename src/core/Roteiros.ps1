# Tecnicos e roteiros (guia de bordo). Vem do Web App (?recurso=tecnicos /
# ?recurso=roteiros), cacheados em data/tecnicos.json e data/roteiros.json.

# ---------------------------------------------------------------- TECNICOS

function Sync-Tecnicos {
    Write-Log 'Baixando lista de tecnicos...' -Nivel Info
    $resp = Invoke-RecursoWebApp -Recurso 'tecnicos'
    $itens = @($resp.tecnicos)
    if (-not $itens.Count) { throw "Resposta de 'tecnicos' vazia." }
    Write-CacheJson -Nome 'tecnicos.json' -Campo 'tecnicos' -Itens $itens -Origem 'recurso=tecnicos'
    return $itens.Count
}

function Get-Tecnicos {
    return Read-CacheJson -Nome 'tecnicos.json' -Campo 'tecnicos'
}

# Normaliza nome para comparacao: minusculas, sem acento, espacos colapsados.
# Evita "roteiro nao encontrado" por diferenca boba de encoding/espaco entre a
# sessao (login) e o cache (sync mais recente).
function ConvertTo-NomeChave {
    param([string] $Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return '' }
    $d  = $Nome.Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void] $sb.Append($ch)
        }
    }
    ($sb.ToString() -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function Get-TecnicoPorNome {
    param([string] $Nome)
    $tec = @(Get-Tecnicos) | Where-Object { $_.nome -eq $Nome } | Select-Object -First 1
    if ($tec) { return $tec }
    $alvo = ConvertTo-NomeChave $Nome
    @(Get-Tecnicos) | Where-Object { (ConvertTo-NomeChave $_.nome) -eq $alvo } | Select-Object -First 1
}

# ---------------------------------------------------------------- ROTEIROS

function Sync-Roteiros {
    Write-Log 'Baixando roteiros...' -Nivel Info
    $resp = Invoke-RecursoWebApp -Recurso 'roteiros' -TimeoutS 90   # e a chamada mais pesada
    $itens = @($resp.roteiros)
    if (-not $itens.Count) { throw "Resposta de 'roteiros' vazia." }
    Write-CacheJson -Nome 'roteiros.json' -Campo 'roteiros' -Itens $itens -Origem 'recurso=roteiros'
    return $itens.Count
}

function Get-Roteiros {
    return Read-CacheJson -Nome 'roteiros.json' -Campo 'roteiros'
}

# Roteiro do tecnico, com as Juntas ja hidratadas a partir do cache de juntas.
# Devolve $null se nao houver roteiro para o nome.
function Get-RoteiroDoTecnico {
    param([string] $Nome)

    $tec = Get-TecnicoPorNome -Nome $Nome
    if (-not $tec) { return $null }

    $rot = @(Get-Roteiros) | Where-Object { $_.numero -eq $tec.roteiro_numero } | Select-Object -First 1
    if (-not $rot) { return $null }

    $juntas = @(Get-Juntas)
    $locais = @()
    foreach ($id in @($rot.juntas_ids)) {
        $j = $juntas | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if ($j) { $locais += $j }
    }

    # Agrupa por Junta (zona + municipio_termo), principal antes de contingencia.
    $grupos = $locais |
        Group-Object -Property { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo } |
        ForEach-Object {
            $ordenados = $_.Group |
                Sort-Object { if ($_.tipo -eq 'principal') { 0 } else { 1 } } |
                ForEach-Object {
                    $_ | Select-Object *, @{
                        n = 'tipo_rotulo'
                        e = { if ($_.tipo -eq 'principal') { 'Principal' } else { 'Contingencia' } }
                    }
                }
            [pscustomobject]@{
                zona_eleitoral  = $ordenados[0].zona_eleitoral
                municipio_termo = $ordenados[0].municipio_termo
                municipio_sede  = $ordenados[0].municipio_sede
                locais          = @($ordenados)
            }
        }

    [pscustomobject]@{
        numero            = $rot.numero
        nome              = $rot.nome
        rotulo            = $rot.rotulo
        tecnico           = $rot.tecnico
        etapa             = $rot.etapa
        ida               = $rot.ida
        retorno           = $rot.retorno
        dias              = $rot.dias
        total_km          = $rot.total_km
        total_tempo       = $rot.total_tempo
        total_locais      = $rot.total_locais
        trechos           = @($rot.trechos)
        cidades           = @($rot.cidades)
        cidades_sem_junta = @($rot.cidades_sem_junta)
        juntas            = @($grupos)
    }
}
