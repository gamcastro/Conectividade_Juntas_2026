# Limiares de decisao. Vem da planilha de config via ?recurso=limiares, cacheados
# em data/limiares.json. O admin edita e salva (POST autenticado por PIN).

function Sync-Limiares {
    Write-Log 'Baixando limiares...' -Nivel Info
    $resp = Invoke-RecursoWebApp -Recurso 'limiares'
    if (-not $resp.limiares) { throw "Resposta de 'limiares' sem dados." }
    Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $resp.limiares -Origem "recurso=limiares ($($resp.origem))"
    return $resp.limiares
}

# Objeto no shape que Invoke-MotorDecisao espera:
#   { latencia_ms:{viavel_ate,ressalva_ate}, ..., banda_download_mbps:{viavel_min,ressalva_min} }
function Get-LimiaresConfig {
    $arq = Join-Path (Get-PastaDados) 'limiares.json'
    if (Test-Path $arq) {
        try {
            $doc = Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($doc.limiares) { return $doc.limiares }
        } catch {
            Write-Log "Cache de limiares corrompido, usando o local: $_" -Nivel Aviso
        }
    }
    return Get-Config 'limiares'
}

# Envia os limiares para a planilha. $Limiares no mesmo shape do motor.
# Retorna 'ok' | 'negado' | 'erro:<msg>'.
function Save-Limiares {
    param(
        [Parameter(Mandatory)] $Limiares,
        [Parameter(Mandatory)] [string] $Pin
    )
    $cfg = Get-Config 'juntas'
    $endpoint = $cfg.endpoint
    if ([string]::IsNullOrWhiteSpace($endpoint) -or $endpoint -like '*COLOQUE_O_ID*') {
        return 'erro:endpoint do Web App nao configurado'
    }

    $corpo = @{ acao = 'limiares.salvar'; pin = $Pin; limiares = $Limiares } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $corpo `
                                  -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    } catch {
        return "erro:$_"
    }

    switch ($resp.status) {
        'ok'     {
            Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $Limiares -Origem 'salvo pelo admin'
            return 'ok'
        }
        'negado' { return 'negado' }
        default  { return "erro:$($resp.erro)" }
    }
}
