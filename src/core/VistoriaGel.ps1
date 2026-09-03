# Anexo do GEL: le o PDF do "Sistema de Georreferenciamento Eleitoral" e extrai
# os poucos campos que o DICON usa no relatorio (coordenadas + link/mapa do
# Google, suporte ao link local, eletrica). O layout do GEL e fixo -> regex nas
# perguntas conhecidas. Sempre passa por uma tela de conferencia do tecnico.

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
# PdfPig (Apache-2.0) em lib\pdfpig\. Sem ele, o upload avisa e nao le.
function Get-CaminhoPdfLib {
    $dll = Join-Path $Global:RaizApp 'lib\pdfpig\UglyToad.PdfPig.dll'
    if (Test-Path $dll) { return $dll }
    return $null
}

function Read-TextoPdf {
    param([Parameter(Mandatory)] [string] $Caminho)
    if (-not (Test-Path $Caminho)) { throw "PDF nao encontrado: $Caminho" }
    $dll = Get-CaminhoPdfLib
    if (-not $dll) {
        throw 'biblioteca de leitura de PDF ausente - copie os arquivos do PdfPig para lib\pdfpig\ (veja lib\pdfpig\LEIA-ME.txt).'
    }
    $pasta = Split-Path $dll -Parent
    foreach ($d in @(Get-ChildItem -Path $pasta -Filter *.dll -File -ErrorAction SilentlyContinue)) {
        try { [Reflection.Assembly]::LoadFrom($d.FullName) | Out-Null } catch { }
    }
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
