# Envio dos resultados ao endpoint do Apps Script do Painel de Vistoria.
# Offline-first: sempre grava local primeiro (Save-ResultadoLocal); aqui e so a
# tentativa de POST. Em caso de sucesso REAL ({status:'ok'}) o arquivo migra de
# resultados\pendentes\ para resultados\enviados\.

# Probe rapido: o endpoint esta acessivel agora? (evita travar no start offline)
function Test-EnvioDisponivel {
    param(
        [string] $Endpoint,
        [int]    $TimeoutS = 4
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        try { $Endpoint = (Get-Config 'envio').endpoint_apps_script } catch { return $false }
    }
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $Endpoint -match 'COLOQUE_O_ID_AQUI') { return $false }
    try {
        $null = Invoke-WebRequest -Method Head -Uri $Endpoint -TimeoutSec $TimeoutS -UseBasicParsing -ErrorAction Stop
        return $true
    } catch [System.Net.WebException] {
        # respondeu algo (405/302/403...) => host acessivel
        if ($_.Exception.Response) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Send-Resultado {
    param(
        [string] $Caminho,
        [string] $Endpoint,
        [int]    $Retentativas = 3,
        [int]    $IntervaloS   = 5
    )

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        $Endpoint = (Get-Config 'envio').endpoint_apps_script
    }
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $Endpoint -match 'COLOQUE_O_ID_AQUI') {
        Write-Log 'Endpoint de envio nao configurado (config/envio.json). Resultado fica em pendentes.' -Nivel Erro
        return $false
    }
    if (-not (Test-Path $Caminho)) {
        throw "Send-Resultado: arquivo nao encontrado: $Caminho"
    }

    $corpo = Get-Content -Path $Caminho -Raw -Encoding UTF8
    $nome  = Split-Path $Caminho -Leaf

    for ($i = 1; $i -le $Retentativas; $i++) {
        $resp  = $null
        $falha = $null
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $Endpoint -Body $corpo `
                                      -ContentType 'application/json; charset=utf-8' `
                                      -TimeoutSec 30 -MaximumRedirection 5
        } catch {
            $falha = "$_"
        }

        if ($null -ne $resp) {
            $status = [string] $resp.status
            if ($status -eq 'ok') {
                Write-Log ("Enviado: {0}" -f $nome) -Nivel Ok
                Move-ParaEnviados -Caminho $Caminho
                return $true
            }
            # O Apps Script responde HTTP 200 mesmo recusando. Se ele recusou,
            # insistir nao adianta -- mantem em pendentes e para de tentar.
            $motivo = if ($resp.motivo) { $resp.motivo } elseif ($resp.erro) { $resp.erro } else { 'resposta sem status ok' }
            Write-Log ("Servidor recusou {0}: {1} ({2}). Fica em pendentes." -f $nome, $status, $motivo) -Nivel Erro
            return $false
        }

        Write-Log ("Tentativa {0}/{1} de enviar {2} falhou: {3}" -f $i, $Retentativas, $nome, $falha) -Nivel Aviso
        if ($i -lt $Retentativas) { Start-Sleep -Seconds $IntervaloS }
    }

    Write-Log ("Envio de {0} esgotou {1} tentativa(s); permanece em pendentes." -f $nome, $Retentativas) -Nivel Erro
    return $false
}

function Move-ParaEnviados {
    param(
        [string] $Caminho
    )
    $destino = Join-Path $Global:RaizApp 'resultados\enviados'
    if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }
    Move-Item -Path $Caminho -Destination (Join-Path $destino (Split-Path $Caminho -Leaf)) -Force
}

# Reenvia tudo que estiver em resultados\pendentes\. Devolve um resumo.
#   -SomenteSeDisponivel: faz um probe rapido antes; se offline, nem tenta.
function Send-ResultadosPendentes {
    param(
        [string] $Endpoint,
        [switch] $SomenteSeDisponivel
    )

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        try { $Endpoint = (Get-Config 'envio').endpoint_apps_script } catch { }
    }

    $pasta    = Join-Path $Global:RaizApp 'resultados\pendentes'
    $arquivos = @(Get-ChildItem -Path $pasta -Filter '*.json' -ErrorAction SilentlyContinue)

    $resumo = [pscustomobject]@{ Total = $arquivos.Count; Enviados = 0; Falhas = 0 }

    if (-not $arquivos.Count) {
        Write-Log 'Nenhum resultado pendente para enviar.' -Nivel Info
        return $resumo
    }

    if ($SomenteSeDisponivel -and -not (Test-EnvioDisponivel -Endpoint $Endpoint)) {
        Write-Log ("{0} resultado(s) pendente(s) -- sem conexao com o endpoint agora." -f $arquivos.Count) -Nivel Aviso
        $resumo.Falhas = $arquivos.Count
        return $resumo
    }

    Write-Log ("Reenviando {0} resultado(s) pendente(s)..." -f $arquivos.Count) -Nivel Info
    foreach ($a in $arquivos) {
        if (Send-Resultado -Caminho $a.FullName -Endpoint $Endpoint) { $resumo.Enviados++ } else { $resumo.Falhas++ }
    }
    Write-Log ("Reenvio: {0} enviado(s), {1} pendente(s)." -f $resumo.Enviados, $resumo.Falhas) `
              -Nivel $(if ($resumo.Falhas) { 'Aviso' } else { 'Ok' })
    return $resumo
}
