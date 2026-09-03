# Sessao local do tecnico (login simplificado por nome). data/sessao.json.

function Get-CaminhoSessao {
    return Join-Path (Get-PastaDados) 'sessao.json'
}

function Get-Sessao {
    $arq = Get-CaminhoSessao
    if (-not (Test-Path $arq)) { return $null }
    try {
        return Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Sessao corrompida, ignorando: $_" -Nivel Aviso
        return $null
    }
}

function Set-Sessao {
    param(
        [string] $TecnicoNome,
        [ValidateSet('operador', 'admin')]
        [string] $Papel = 'operador'
    )
    $doc = [pscustomobject]@{
        tecnico_nome = $TecnicoNome
        papel        = $Papel
        ultimo_login = (Get-Date).ToString('o')
    }
    # Write-TextoArquivo (nao Set-Content): evita o "O fluxo nao era legivel" do
    # provider FileSystem do PS 5.1 quando o antivirus esta com o handle do arquivo.
    Write-TextoArquivo -Caminho (Get-CaminhoSessao) -Conteudo ($doc | ConvertTo-Json)
    return $doc
}

function Clear-Sessao {
    $arq = Get-CaminhoSessao
    if (Test-Path $arq) { Remove-Item $arq -Force }
}
