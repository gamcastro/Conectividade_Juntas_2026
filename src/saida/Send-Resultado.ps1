# Envio dos resultados ao endpoint do Apps Script do Painel de Vistoria.
# Em caso de sucesso, o arquivo migra de resultados\pendentes\ para
# resultados\enviados\.

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
    if (-not (Test-Path $Caminho)) {
        throw "Send-Resultado: arquivo nao encontrado: $Caminho"
    }

    $corpo = Get-Content -Path $Caminho -Raw -Encoding UTF8

    for ($i = 1; $i -le $Retentativas; $i++) {
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $Endpoint -Body $corpo `
                                      -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
            Write-Log ("Enviado ({0}/{1})" -f $i, $Retentativas) -Nivel Ok
            Move-ParaEnviados -Caminho $Caminho
            return $true
        } catch {
            Write-Log ("Tentativa {0}/{1} falhou: {2}" -f $i, $Retentativas, $_) -Nivel Aviso
            if ($i -lt $Retentativas) { Start-Sleep -Seconds $IntervaloS }
        }
    }

    Write-Log "Envio esgotou as $Retentativas tentativas; resultado permanece em pendentes" -Nivel Erro
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

function Send-ResultadosPendentes {
    param(
        [string] $Endpoint
    )
    $pasta    = Join-Path $Global:RaizApp 'resultados\pendentes'
    $arquivos = @(Get-ChildItem -Path $pasta -Filter '*.json' -ErrorAction SilentlyContinue)

    if (-not $arquivos.Count) {
        Write-Log 'Nenhum resultado pendente para enviar' -Nivel Info
        return
    }

    Write-Log "Reenviando $($arquivos.Count) resultado(s) pendente(s)..." -Nivel Info
    foreach ($a in $arquivos) {
        Send-Resultado -Caminho $a.FullName -Endpoint $Endpoint
    }
}
