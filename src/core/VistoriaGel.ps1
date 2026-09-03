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
    Remove-Item -LiteralPath (Get-PastaFotosGel -LocalId $LocalId -SemCriar) -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------- fotos da vistoria do GEL (por local)
# O tecnico baixa as fotos no GEL web e adiciona no DICON. Ficam reduzidas em
# data/vistoria-gel/<localid>/foto-NN.jpg e entram numa secao do relatorio PDF.
function Get-PastaFotosGel {
    param([string] $LocalId, [switch] $SemCriar)
    $san = ([string] $LocalId) -replace '[^\w\-]', '_'
    $p = Join-Path (Get-PastaDados) ('vistoria-gel\{0}' -f $san)
    if (-not $SemCriar -and -not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $p
}

function Get-FotosGel {
    param([string] $LocalId)
    if (-not $LocalId) { return @() }
    $p = Get-PastaFotosGel -LocalId $LocalId -SemCriar
    if (-not (Test-Path $p)) { return @() }
    @(Get-ChildItem -Path $p -Filter 'foto-*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
}

# Le uma imagem (jpg/jpeg/png), aplica a orientacao EXIF, reduz para MaxLado no
# maior lado e regrava como JPEG. WPF (PresentationCore) - roda na thread de UI.
function Resize-ImagemParaJpeg {
    param(
        [Parameter(Mandatory)] [string] $Origem,
        [Parameter(Mandatory)] [string] $Destino,
        [int] $MaxLado = 1600,
        [int] $Qualidade = 80
    )
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    $fs = [IO.File]::OpenRead($Origem)
    try {
        $dec = [Windows.Media.Imaging.BitmapDecoder]::Create(
            $fs, [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $dec.Frames[0]
        [Windows.Media.Imaging.BitmapSource] $img = $frame

        # orientacao EXIF (tag 274): 3=180  6=90  8=270
        $graus = 0
        try {
            $md = $frame.Metadata
            if ($md -and $md.ContainsQuery('/app1/ifd/{ushort=274}')) {
                switch ([int] $md.GetQuery('/app1/ifd/{ushort=274}')) {
                    3 { $graus = 180 } ; 6 { $graus = 90 } ; 8 { $graus = 270 }
                }
            }
        } catch { }
        if ($graus -ne 0) {
            $img = New-Object Windows.Media.Imaging.TransformedBitmap $img, (New-Object Windows.Media.RotateTransform $graus)
        }

        $maior = [Math]::Max($img.PixelWidth, $img.PixelHeight)
        if ($maior -gt $MaxLado) {
            $e = [double] $MaxLado / $maior
            $img = New-Object Windows.Media.Imaging.TransformedBitmap $img, (New-Object Windows.Media.ScaleTransform $e, $e)
        }

        $enc = New-Object Windows.Media.Imaging.JpegBitmapEncoder
        $enc.QualityLevel = [Math]::Max(1, [Math]::Min(100, $Qualidade))
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($img))
        $out = [IO.File]::Create($Destino)
        try { $enc.Save($out) } finally { $out.Dispose() }
    } finally { $fs.Dispose() }
}

# Adiciona uma foto ao local: reduz e grava como o proximo foto-NN.jpg. Devolve
# o caminho gravado (ou lanca se a imagem nao abrir).
function Add-FotoGel {
    param([Parameter(Mandatory)] [string] $LocalId, [Parameter(Mandatory)] [string] $Caminho)
    if (-not (Test-Path $Caminho)) { throw "imagem nao encontrada: $Caminho" }
    $pasta = Get-PastaFotosGel -LocalId $LocalId
    $nums = @(Get-ChildItem -Path $pasta -Filter 'foto-*.jpg' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match 'foto-(\d+)') { [int] $Matches[1] } })
    [int] $prox = 1
    if ($nums.Count) { $prox = [int] (($nums | Measure-Object -Maximum).Maximum) + 1 }
    $dest = Join-Path $pasta ('foto-{0:D2}.jpg' -f $prox)
    Resize-ImagemParaJpeg -Origem $Caminho -Destino $dest
    $dest
}

function Remove-FotoGel {
    param([string] $LocalId, [string] $Nome)
    if (-not $LocalId -or -not $Nome) { return }
    $alvo = Join-Path (Get-PastaFotosGel -LocalId $LocalId -SemCriar) (Split-Path $Nome -Leaf)
    Remove-Item -LiteralPath $alvo -Force -ErrorAction SilentlyContinue
}

# data: URI de uma foto ja reduzida (so le + base64). '' se sumiu / muito grande.
function Get-FotoGelDataUri {
    param([Parameter(Mandatory)] [string] $Caminho)
    try {
        if (-not (Test-Path $Caminho)) { return '' }
        $b = [IO.File]::ReadAllBytes($Caminho)
        if (-not $b -or $b.Length -lt 100 -or $b.Length -gt 4MB) { return '' }
        'data:image/jpeg;base64,' + [Convert]::ToBase64String($b)
    } catch { '' }
}

# Monta o bloco "vistoria_gel" do JSON de resultado (secoes + contagem de fotos).
# Usado por New-ResultadoJson e por "abrir relatorio" na tela do Local. Devolve
# $null so quando nao ha nada anexado (nem formulario nem fotos).
function New-BlocoVistoriaGel {
    param($VistoriaGel, [string] $LocalId)
    $nFotos = @(Get-FotosGel -LocalId $LocalId).Count
    if (-not $VistoriaGel -and -not $nFotos) { return $null }
    $g = { param([string] $n) $p = if ($VistoriaGel) { $VistoriaGel.PSObject.Properties[$n] } else { $null }; if ($p) { $p.Value } else { $null } }
    [pscustomobject]@{
        latitude          = (& $g 'lat')
        longitude         = (& $g 'long')
        precisao_m        = (& $g 'precisao_m')
        mapa_link         = [string] (& $g 'mapa_link')
        tipo_local        = [pscustomobject]@{
            esfera_administrativa = [string] (& $g 'esfera_administrativa')
            localizacao           = [string] (& $g 'localizacao')
            tipo                  = [string] (& $g 'tipo_local')
        }
        infraestrutura    = [pscustomobject]@{
            salas_necessarias = [string] (& $g 'salas_necessarias')
            agua              = [string] (& $g 'agua')
            climatizacao      = [string] (& $g 'climatizacao')
            iluminacao        = [string] (& $g 'iluminacao')
            agua_potavel      = [string] (& $g 'agua_potavel')
            predio_reforma    = [string] (& $g 'predio_reforma')
        }
        eletrica          = [pscustomobject]@{
            quadro_energia    = [string] (& $g 'quadro_energia')
            energia_eletrica  = [string] (& $g 'energia_eletrica')
            tomadas           = [string] (& $g 'eletrica_tomadas')
            tensao            = [string] (& $g 'eletrica_tensao')
            extensao          = [string] (& $g 'eletrica_extensao')
        }
        suporte_nome      = [string] (& $g 'suporte_nome')
        suporte_telefone  = [string] (& $g 'suporte_telefone')
        fotos             = $nFotos
        # compat: campos planos anteriores
        eletrica_tensao   = [string] (& $g 'eletrica_tensao')
        eletrica_tomadas  = [string] (& $g 'eletrica_tomadas')
        eletrica_extensao = [string] (& $g 'eletrica_extensao')
    }
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

    # 1 linha + sem diacriticos: o PDF do GEL mistura fontes e as vezes entrega
    # "eletrica" com o acento decomposto (e + U+0301), o que quebra classes tipo
    # [ee']. Normalizar aqui deixa todos os regex em ASCII simples.
    $t = ($Texto -replace '\s+', ' ').Trim()
    try {
        $t = -join ([char[]] $t.Normalize([Text.NormalizationForm]::FormD) |
            Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
    } catch { }

    $o = [pscustomobject]@{
        lat = $null; long = $null; precisao_m = $null
        # secao "Tipo do local"
        esfera_administrativa = ''; localizacao = ''; tipo_local = ''
        # secao "Infraestrutura"
        salas_necessarias = ''; agua = ''; climatizacao = ''
        iluminacao = ''; agua_potavel = ''; predio_reforma = ''
        # secao "Instalacoes eletricas"
        quadro_energia = ''; energia_eletrica = ''
        eletrica_tomadas = ''; eletrica_tensao = ''; eletrica_extensao = ''
        # secao "Junta Especial" (suporte ao link local)
        suporte_nome = ''; suporte_telefone = ''
        achou_algo = $false
    }

    # "-2.4997476o,-43.25344546o. Precisao 6.558" - no PDF do GEL o rotulo
    # "Coordenadas:" vem DEPOIS do valor, entao nao da pra ancorar nele. O par
    # numero,numero + Precisao ja e unico o suficiente no documento.
    if ($t -match '(-?\d+[.,]\d+)\s*[\u00B0\u00BAo]?\s*,\s*(-?\d+[.,]\d+)\s*[\u00B0\u00BAo]?\s*\.?\s*Precisao\s*:?\s*(\d+[.,]?\d*)') {
        $o.lat        = [double] (($Matches[1]) -replace ',', '.')
        $o.long       = [double] (($Matches[2]) -replace ',', '.')
        $o.precisao_m = [double] (($Matches[3]) -replace ',', '.')
    }

    # No PDF do GEL a RESPOSTA aparece ENTRE a pergunta e o marcador " R. :"
    # (o "R. :" e o rotulo do campo, que renderiza depois do valor):
    #   "<pergunta>? <resposta> R. :"  /  "<rotulo>: <resposta> R. :"  /
    #   "<rotulo sem pontuacao> <resposta> R. :"
    # A captura para no primeiro "?" para nao invadir a proxima pergunta quando a
    # resposta esta vazia.
    $resp = {
        param([string] $rxPergunta)
        $rx = $rxPergunta + '\s*[?:]?\s*([^?]{1,80}?)\s*R\s*\.?\s*:'
        $m = [regex]::Match($t, $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { (($m.Groups[1].Value) -replace '\s+', ' ').Trim() } else { '' }
    }

    # --- Tipo do local
    $o.esfera_administrativa = & $resp 'esfera administrativa do local vistoriado'
    if ($t -match '\bLocalizacao\s+(Urbano|Rural|Semi[ -]?urbano|Semiurbano)\b') { $o.localizacao = $Matches[1] }
    $m = [regex]::Match($t, 'Tipo de local\s+(?!que\b)([^?:]{1,38}?)\s*R\s*\.?\s*:', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { $o.tipo_local = ($m.Groups[1].Value -replace '\s+', ' ').Trim() }

    # --- Infraestrutura
    $o.salas_necessarias = & $resp 'Quantidade de salas necessarias para funcionar como secao eleitoral'
    $o.agua              = & $resp 'Ha abastecimento de agua'
    $o.climatizacao      = & $resp 'A climatizacao ou ventilacao e feita por'
    $o.iluminacao        = & $resp 'Ha iluminacao'
    $o.agua_potavel      = & $resp 'Ha agua potavel disponivel para mesarias\S* e eleitoras\S*'
    $o.predio_reforma    = & $resp 'O predio esta em reforma'

    # --- Instalacoes eletricas
    $o.quadro_energia    = & $resp 'Localizacao do Quadro de Energia'
    $o.energia_eletrica  = & $resp 'Ha energia eletrica'
    $o.eletrica_tomadas  = & $resp 'quantas tomadas funcionando'
    $o.eletrica_tensao   = & $resp 'tensao da rede eletrica'
    $o.eletrica_extensao = & $resp 'necessidade de extensao eletrica'

    # --- Suporte ao link local (secao "Junta Especial")
    $o.suporte_nome      = & $resp 'nome do tecnico ou empresa responsavel pelo suporte ao link local'
    $o.suporte_telefone  = & $resp 'telefone do tecnico ou empresa responsavel pelo suporte ao link local'

    $o.achou_algo = [bool] ($o.lat -or $o.esfera_administrativa -or $o.tipo_local -or $o.agua -or
        $o.eletrica_tensao -or $o.eletrica_tomadas -or $o.suporte_nome -or $o.suporte_telefone)
    $o
}
