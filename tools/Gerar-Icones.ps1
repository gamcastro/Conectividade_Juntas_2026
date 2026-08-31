#Requires -Version 5.1
<#
.SYNOPSIS
    Rasteriza o icone do DICON (a partir da geometria, sem depender de SVG) para
    assets/marca/icones/*.png e monta assets/marca/dicon.ico (PNG-in-ICO).
.DESCRIPTION
    A geometria e a mesma de assets/marca/dicon-icone.svg (viewBox 0..120).
    Nos tamanhos pequenos (<= 32) usa a versao simplificada (2 arcos, sem estrelas),
    igual a assets/marca/dicon-favicon.svg.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$saida = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\marca'
$dirPng = Join-Path $saida 'icones'
if (-not (Test-Path $dirPng)) { New-Item -ItemType Directory -Path $dirPng -Force | Out-Null }

$AZUL   = [System.Drawing.ColorTranslator]::FromHtml('#123FA8')
$CLARO  = [System.Drawing.ColorTranslator]::FromHtml('#EAF0FF')
$EST    = @('#7FE0A0', '#F2D272', '#F2A79C') | ForEach-Object { [System.Drawing.ColorTranslator]::FromHtml($_) }

# vertices da estrela unitaria (ponta para cima)
$estrela = @(
    @(0, -1), @(0.2245, -0.309), @(0.9511, -0.309), @(0.3633, 0.1181), @(0.5878, 0.809),
    @(0, 0.382), @(-0.5878, 0.809), @(-0.3633, 0.1181), @(-0.9511, -0.309), @(-0.2245, -0.309)
)

function New-DiconIcone {
    param([int] $Size, [switch] $Simples)

    $k  = $Size / 120.0
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # fundo arredondado
    $r = 24.0 * $k
    $d = 2 * $r
    $rr = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rr.AddArc(0, 0, $d, $d, 180, 90)
    $rr.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $rr.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $rr.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $rr.CloseFigure()
    $bg = New-Object System.Drawing.SolidBrush($AZUL)
    $g.FillPath($bg, $rr)

    # centro do no (coords 0..120, ja com o translate do simbolo)
    $cx = 52.0 * $k
    $cy = 80.0 * $k

    $espessura = ($(if ($Simples) { 7.0 } else { 3.6 }) * $k)
    $pen = New-Object System.Drawing.Pen($CLARO, $espessura)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    $raios = if ($Simples) { @(36, 50) } else { @(22, 36, 50) }
    foreach ($rad in $raios) {
        $rp = $rad * $k
        $g.DrawArc($pen, [float]($cx - $rp), [float]($cy - $rp), [float](2 * $rp), [float](2 * $rp), -80, 70)
    }

    # no central
    $noR = ($(if ($Simples) { 8.0 } else { 5.4 }) * $k)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($CLARO)), [float]($cx - $noR), [float]($cy - $noR), [float](2 * $noR), [float](2 * $noR))

    # estrelas (so na versao completa)
    if (-not $Simples) {
        $pos = @(@(67.56, 64.44), @(77.46, 54.54), @(87.36, 44.64))
        for ($i = 0; $i -lt 3; $i++) {
            $tx = $pos[$i][0] * $k; $ty = $pos[$i][1] * $k; $s = 5.6 * $k
            $pts = foreach ($v in $estrela) {
                New-Object System.Drawing.PointF([float]($tx + $v[0] * $s), [float]($ty + $v[1] * $s))
            }
            $g.FillPolygon((New-Object System.Drawing.SolidBrush($EST[$i])), ([System.Drawing.PointF[]]$pts))
        }
    }

    $g.Dispose()
    return $bmp
}

# --- PNGs ---
$tamanhos = @(256, 128, 64, 48, 32, 16)
$bytesPorTamanho = @{}
foreach ($t in $tamanhos) {
    $bmp = New-DiconIcone -Size $t -Simples:($t -le 32)
    $arq = Join-Path $dirPng ("dicon-{0}.png" -f $t)
    $bmp.Save($arq, [System.Drawing.Imaging.ImageFormat]::Png)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytesPorTamanho[$t] = $ms.ToArray()
    $ms.Dispose(); $bmp.Dispose()
    Write-Host ("PNG  {0,3}px  ->  {1}" -f $t, $arq)
}

# --- .ico (PNG embutido; Windows Vista+) ---
$icoTamanhos = @(256, 64, 48, 32, 16)
$ico = Join-Path $saida 'dicon.ico'
$fs  = [System.IO.File]::Create($ico)
$bw  = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$icoTamanhos.Count)
    $offset = 6 + 16 * $icoTamanhos.Count
    foreach ($t in $icoTamanhos) {
        $b = $bytesPorTamanho[$t]
        $bw.Write([byte]($(if ($t -ge 256) { 0 } else { $t })))
        $bw.Write([byte]($(if ($t -ge 256) { 0 } else { $t })))
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$b.Length); $bw.Write([uint32]$offset)
        $offset += $b.Length
    }
    foreach ($t in $icoTamanhos) { $bw.Write($bytesPorTamanho[$t]) }
} finally { $bw.Dispose(); $fs.Dispose() }
Write-Host "ICO  -> $ico  ($($icoTamanhos -join ', ') px)"
