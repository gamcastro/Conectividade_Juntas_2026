# Anexo do GEL: le o PDF do "Sistema de Georreferenciamento Eleitoral" e extrai
# os poucos campos que o DICON usa no relatorio (coordenadas + link/mapa do
# Google, suporte ao link local, eletrica). O layout do GEL e fixo -> regex nas
# perguntas conhecidas. Sempre passa por uma tela de conferencia do tecnico.

# --------------------------------- persistencia do anexo GEL por local (disco)
# Fica em data/vistoria-gel/<localid>.json - independente do momento do teste.
function Get-CaminhoVistoriaGel {
    param([string] $LocalId)
    $san = ([string] $LocalId) -replace '[^\w\-]', '_'
    Join-Path (Get-PastaDados) ('vistoria-gel\{0}.json' -f $san)
}

function Get-VistoriaGel {
    param([string] $LocalId)
    if (-not $LocalId) { return $null }
    $f = Get-CaminhoVistoriaGel -LocalId $LocalId
    if (-not (Test-Path $f)) { return $null }
    try { Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Save-VistoriaGel {
    param([string] $LocalId, $Dados)
    if (-not $LocalId) { return $null }
    $f = Get-CaminhoVistoriaGel -LocalId $LocalId
    Write-TextoArquivo -Caminho $f -Conteudo ($Dados | ConvertTo-Json -Depth 6)
    $f
}

function Remove-VistoriaGel {
    param([string] $LocalId)
    if (-not $LocalId) { return }
    Remove-Item -LiteralPath (Get-CaminhoVistoriaGel -LocalId $LocalId) -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------- chave do Google Maps (Static)
# Salva em config/ambiente.json (bloco "google_maps") pela tela de Administracao.
function Get-ChaveMapsStatic {
    try {
        $amb = Get-Config 'ambiente'
        $gm = $amb.PSObject.Properties['google_maps']
        if ($gm -and $gm.Value) {
            $k = $gm.Value.PSObject.Properties['static_key']
            if ($k) { return [string] $k.Value }
        }
    } catch { }
    return ''
}

# ---------------------------------------------------------------- links de mapa
function Get-LinkGoogleMaps {
    param($Lat, $Long)
    $la = ("$Lat") -replace ',', '.'
    $lo = ("$Long") -replace ',', '.'
    'https://www.google.com/maps?q={0},{1}' -f $la, $lo
}

function Get-UrlMapaEstatico {
    param($Lat, $Long, [string] $Chave, [int] $Largura = 640, [int] $Altura = 300, [int] $Zoom = 16)
    if (-not $Chave) { return '' }
    $la = ("$Lat") -replace ',', '.'
    $lo = ("$Long") -replace ',', '.'
    ('https://maps.googleapis.com/maps/api/staticmap?center={0},{1}&zoom={2}&size={3}x{4}&scale=2' +
     '&markers=color:red%7C{0},{1}&key={5}') -f $la, $lo, $Zoom, $Largura, $Altura, $Chave
}

# Baixa o PNG do mapa estatico e devolve um data: URI (assim a chave NAO aparece
# no HTML/PDF final). '' se sem chave / offline / a resposta nao for imagem.
function Get-MapaEstaticoDataUri {
    param($Lat, $Long, [string] $Chave)
    $url = Get-UrlMapaEstatico -Lat $Lat -Long $Long -Chave $Chave
    if (-not $url) { return '' }
    try {
        $wc = New-Object System.Net.WebClient
        try { $bytes = $wc.DownloadData($url) } finally { $wc.Dispose() }
        if (-not $bytes -or $bytes.Length -lt 500) { return '' }
        # PNG = 89 50 4E 47 ; erro do Google vem como texto/JSON pequeno
        if (-not ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)) {
            Write-Log 'Mapa estatico: a resposta nao e um PNG (chave/faturamento?).' -Nivel Aviso
            return ''
        }
        return 'data:image/png;base64,' + [Convert]::ToBase64String($bytes)
    } catch {
        Write-Log ("Mapa estatico nao baixou: {0}" -f $_) -Nivel Aviso
        return ''
    }
}

# --------------------------------------------------------------- leitura do PDF
# PdfPig (Apache-2.0) em lib\pdfpig\. As DLLs vao versionadas no repo, mas uma
# instalacao que atualizou de uma versao ANTIGA do Atualizar-DICON.ps1 (antes de
# 'lib\pdfpig' entrar na lista de espelhamento) pode nao te-las - por isso o
# Restore-PdfLib abaixo baixa direto do GitHub quando faltarem e ha internet.
function Get-CaminhoPdfLib {
    $dll = Join-Path $Global:RaizApp 'lib\pdfpig\UglyToad.PdfPig.dll'
    if (Test-Path $dll) { return $dll }
    return $null
}

$script:PdfLibArquivos = @(
    'UglyToad.PdfPig.dll', 'UglyToad.PdfPig.Core.dll', 'UglyToad.PdfPig.Fonts.dll'
    'UglyToad.PdfPig.Tokenization.dll', 'UglyToad.PdfPig.Tokens.dll'
    'System.Memory.dll', 'System.Buffers.dll', 'System.Numerics.Vectors.dll'
    'System.Runtime.CompilerServices.Unsafe.dll', 'Microsoft.Bcl.HashCode.dll'
)

# Baixa as DLLs do PdfPig do canal desta instalacao para lib\pdfpig\. Best-effort:
# devolve $true se ao final a pasta tem a DLL principal. Nao lanca.
function Restore-PdfLib {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $canal = try { Get-CanalInstalacao } catch { 'main' }
    $pasta = Join-Path $Global:RaizApp 'lib\pdfpig'
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    $base = "https://raw.githubusercontent.com/gamcastro/Conectividade_Juntas_2026/$canal/lib/pdfpig"
    Write-Log 'Biblioteca de PDF ausente - tentando baixar do GitHub...' -Nivel Aviso
    foreach ($nome in $script:PdfLibArquivos) {
        $alvo = Join-Path $pasta $nome
        if (Test-Path $alvo) { continue }
        try {
            (New-Object Net.WebClient).DownloadFile("$base/$nome", $alvo)
        } catch {
            Write-Log ("  falhou {0}: {1}" -f $nome, $_.Exception.Message) -Nivel Aviso
            Remove-Item $alvo -Force -ErrorAction SilentlyContinue
        }
    }
    $ok = Test-Path (Join-Path $pasta 'UglyToad.PdfPig.dll')
    if ($ok) { Write-Log 'Biblioteca de PDF baixada.' -Nivel Ok }
    $ok
}

# Carrega os .dll de lib\pdfpig e instala (uma vez) um resolvedor de assembly por
# nome simples. O .NET Framework do PowerShell 5.1 nao unifica versoes sozinho: o
# PdfPig pede System.Buffers 4.0.2.0 / System.Runtime.CompilerServices.Unsafe etc.
# e nos temos outras builds na pasta - sem o handler abaixo da "Nao foi possivel
# carregar arquivo ou assembly".
$script:PdfLibMapa = $null

function Register-ResolucaoPdfLib {
    param([Parameter(Mandatory)] [string] $Pasta)
    if ($null -eq $script:PdfLibMapa) {
        $script:PdfLibMapa = @{}
        [AppDomain]::CurrentDomain.add_AssemblyResolve({
            param($fonte, $ev)
            $simples = ($ev.Name -split ',')[0].Trim()
            if ($script:PdfLibMapa.ContainsKey($simples)) { return $script:PdfLibMapa[$simples] }
            return $null
        })
    }
    foreach ($d in @(Get-ChildItem -Path $Pasta -Filter *.dll -File -ErrorAction SilentlyContinue)) {
        try {
            $asm = [Reflection.Assembly]::LoadFrom($d.FullName)
            $script:PdfLibMapa[$asm.GetName().Name] = $asm
        } catch { }
    }
}

function Read-TextoPdf {
    param([Parameter(Mandatory)] [string] $Caminho)
    if (-not (Test-Path $Caminho)) { throw "PDF nao encontrado: $Caminho" }
    $dll = Get-CaminhoPdfLib
    if (-not $dll) {
        if (Restore-PdfLib) { $dll = Get-CaminhoPdfLib }
    }
    if (-not $dll) {
        throw 'biblioteca de leitura de PDF ausente e nao consegui baixar - rode setup\Atualizar-DICON.ps1 -Force com internet (veja lib\pdfpig\LEIA-ME.txt).'
    }
    Register-ResolucaoPdfLib -Pasta (Split-Path $dll -Parent)
    $sb  = [Text.StringBuilder]::new()
    $doc = [UglyToad.PdfPig.PdfDocument]::Open($Caminho)
    try {
        foreach ($pg in $doc.GetPages()) {
            $palavras = @($pg.GetWords() | ForEach-Object { $_.Text })
            [void] $sb.AppendLine(($palavras -join ' '))
        }
    } finally { $doc.Dispose() }
    $sb.ToString()
}

# ------------------------------------------------------------ extrator de campos
# Recebe o texto do PDF do GEL e devolve so o que o DICON usa. Campos nao
# encontrados voltam vazios/nulos - a tela de conferencia deixa o tecnico ajustar.
function ConvertFrom-VistoriaGel {
    param([Parameter(Mandatory)] [string] $Texto)

    $t = ($Texto -replace '\s+', ' ').Trim()

    $o = [pscustomobject]@{
        lat = $null; long = $null; precisao_m = $null
        suporte_nome = ''; suporte_telefone = ''
        eletrica_tensao = ''; eletrica_tomadas = ''; eletrica_extensao = ''
        achou_algo = $false
    }

    # "Coordenadas: -2.4997476o,-43.25344546o. Precisao 6.558"
    if ($t -match 'Coordenadas\s*:?\s*(-?\d+[.,]\d+)\s*[°ºo]?\s*,\s*(-?\d+[.,]\d+)\s*[°ºo]?\s*\.?\s*Precis[aã]o\s*:?\s*(\d+[.,]?\d*)') {
        $o.lat        = [double] (($Matches[1]) -replace ',', '.')
        $o.long       = [double] (($Matches[2]) -replace ',', '.')
        $o.precisao_m = [double] (($Matches[3]) -replace ',', '.')
    }

    # resposta "R. : <texto>" logo apos uma pergunta (fragmento regex, sem acento exato)
    $resp = {
        param([string] $rxPergunta)
        $rx = $rxPergunta + '.{0,80}?\bR\.?\s*:\s*(.{1,120}?)\s*(?=(?:Qual\b|H[aá]\b|Possui\b|Selecione\b|Descreva\b|Observa\w*\b|Localiza\w*\b|Se houver\b|Existe\b|Data \d|$))'
        $m = [regex]::Match($t, $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { (($m.Groups[1].Value) -replace '\s+', ' ').Trim() } else { '' }
    }

    $o.suporte_nome      = & $resp 'nome do t.cnico ou empresa respons.vel pelo suporte ao link local'
    $o.suporte_telefone  = & $resp 'telefone do t.cnico ou empresa respons.vel pelo suporte ao link local'
    $o.eletrica_tensao   = & $resp 'tens.o da rede el.trica'
    $o.eletrica_tomadas  = & $resp 'quantas tomadas funcionando'
    $o.eletrica_extensao = & $resp 'necessidade de extens.o el.trica'

    $o.achou_algo = [bool] ($o.lat -or $o.suporte_nome -or $o.suporte_telefone -or $o.eletrica_tensao -or $o.eletrica_tomadas)
    $o
}
