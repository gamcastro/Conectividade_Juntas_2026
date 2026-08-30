# Lista de Juntas Especiais e seus locais (principal / contingencia), e o
# transporte compartilhado com o Web App do Apps Script (apps-script/Codigo.gs).
#
# Tudo e baixado por Sync-* e cacheado em data/*.json. Em campo (sem internet)
# so se le o cache com Get-*.

function Get-PastaDados {
    $p = Join-Path $Global:RaizApp 'data'
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

# GET generico ao Web App: ?recurso=<nome>. Devolve o objeto ja convertido.
function Invoke-RecursoWebApp {
    param(
        [Parameter(Mandatory)] [string] $Recurso,
        [int] $TimeoutS = 25
    )
    $cfg = Get-Config 'juntas'
    $endpoint = $cfg.endpoint
    if ([string]::IsNullOrWhiteSpace($endpoint) -or $endpoint -like '*COLOQUE_O_ID*') {
        throw "Endpoint do Web App nao configurado (config/juntas.json > endpoint)."
    }
    $sep = if ($endpoint -match '\?') { '&' } else { '?' }
    $uri = "{0}{1}recurso={2}" -f $endpoint, $sep, $Recurso

    $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec $TimeoutS
    if ($resp.erro) { throw "Web App retornou erro ($Recurso): $($resp.erro)" }
    return $resp
}

function Read-CacheJson {
    param([string] $Nome, [string] $Campo)
    $arq = Join-Path (Get-PastaDados) $Nome
    if (-not (Test-Path $arq)) { return @() }
    try {
        $doc = Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Cache $Nome corrompido: $_" -Nivel Erro
        return @()
    }
    $itens = $doc.$Campo
    if ($null -eq $itens) { return @() }
    return @($itens)
}

function Write-CacheJson {
    param([string] $Nome, [string] $Campo, $Itens, [string] $Origem)
    $doc = [pscustomobject]@{
        atualizado_em = (Get-Date).ToString('o')
        origem        = $Origem
        $Campo        = @($Itens)
    }
    $doc | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path (Get-PastaDados) $Nome) -Encoding UTF8
}

# ---------------------------------------------------------------- JUNTAS

function Sync-Juntas {
    Write-Log 'Baixando lista de Juntas...' -Nivel Info
    $resp = Invoke-RecursoWebApp -Recurso 'juntas'
    $locais = @($resp.juntas)
    if (-not $locais.Count) { throw "Resposta de 'juntas' vazia." }
    Write-CacheJson -Nome 'juntas.json' -Campo 'juntas' -Itens $locais -Origem 'recurso=juntas'
    return $locais.Count
}

function Get-Juntas {
    $arq = Join-Path (Get-PastaDados) 'juntas.json'
    if (-not (Test-Path $arq)) {
        Write-Log "Cache de Juntas ausente. Use 'Atualizar dados' com internet." -Nivel Aviso
        return @()
    }
    try {
        $doc = Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Cache de Juntas corrompido: $_" -Nivel Erro
        return @()
    }

    try { $validadeH = [double](Get-Config 'juntas').validade_cache_horas } catch { $validadeH = 336 }
    if ($validadeH -le 0) { $validadeH = 336 }
    if ($doc.atualizado_em) {
        $idadeH = ((Get-Date) - [datetime]$doc.atualizado_em).TotalHours
        if ($idadeH -gt $validadeH) {
            Write-Log ("Cache de Juntas com {0:N0} h (limite {1:N0} h). Atualize quando possivel." -f $idadeH, $validadeH) -Nivel Aviso
        }
    }
    return @($doc.juntas)
}

function Get-JuntaPorId {
    param([string] $Id)
    @(Get-Juntas) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

# ---------------------------------------------------------------- SYNC GERAL

function Sync-TudoOnline {
    $r = [ordered]@{ juntas = 0; tecnicos = 0; roteiros = 0; limiares = 0; erros = @() }
    foreach ($par in @(
            @{ nome = 'Juntas';   fn = { Sync-Juntas } },
            @{ nome = 'Tecnicos'; fn = { Sync-Tecnicos } },
            @{ nome = 'Roteiros'; fn = { Sync-Roteiros } },
            @{ nome = 'Limiares'; fn = { (Sync-Limiares) | Out-Null; 1 } })) {
        try {
            $n = & $par.fn
            $r[$par.nome.ToLower()] = $n
        } catch {
            $r.erros += "$($par.nome): $_"
            Write-Log "Falha ao sincronizar $($par.nome): $_" -Nivel Erro
        }
    }
    return [pscustomobject]$r
}
