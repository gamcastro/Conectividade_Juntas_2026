# Acompanhamento de campo: quais locais o tecnico ja diagnosticou.
# Varre resultados\pendentes\ + resultados\enviados\ e devolve um mapa
#   localId -> { LocalId; Quando; ClassificacaoFinal; Enviado; Arquivo }
# guardando sempre o teste MAIS RECENTE de cada local.

function Get-DiagnosticosRealizados {
    param(
        [string] $TecnicoNome   # opcional: filtra pelos resultados desse tecnico
    )

    $map = @{}
    $fontes = @(
        @{ dir = (Join-Path $Global:RaizApp 'resultados\pendentes'); enviado = $false }
        @{ dir = (Join-Path $Global:RaizApp 'resultados\enviados');  enviado = $true }
    )

    foreach ($fonte in $fontes) {
        if (-not (Test-Path $fonte.dir)) { continue }
        foreach ($f in @(Get-ChildItem -Path $fonte.dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $doc = $null
            try { $doc = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }

            $id = [string] $doc.local.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($TecnicoNome -and $doc.tecnico.nome -and ($doc.tecnico.nome -ne $TecnicoNome)) { continue }

            $quando = $null
            try { $quando = [datetime] $doc.coletado_em } catch { $quando = $f.LastWriteTime }

            $anterior = $map[$id]
            if ($anterior -and $anterior.Quando -ge $quando) { continue }

            $map[$id] = [pscustomobject]@{
                LocalId            = $id
                Quando             = $quando
                ClassificacaoFinal = [string] $doc.classificacao.final
                Enviado            = [bool] $fonte.enviado
                Arquivo            = $f.Name
            }
        }
    }

    return $map
}

# Conta quantos dos locais de um roteiro ja foram testados (e o total).
function Get-ProgressoRoteiro {
    param($Roteiro, [string] $TecnicoNome)

    $feitos = Get-DiagnosticosRealizados -TecnicoNome $TecnicoNome
    $total = 0; $testados = 0
    foreach ($grupo in @($Roteiro.juntas)) {
        foreach ($loc in @($grupo.locais)) {
            $total++
            if ($feitos.ContainsKey([string] $loc.id)) { $testados++ }
        }
    }
    [pscustomobject]@{ Total = $total; Testados = $testados; Mapa = $feitos }
}
