# Relatorio de diagnostico em PDF (paisagem, no padrao "Painel da Vistoria" da
# SEMAP, adaptado para conectividade). Monta um HTML e converte com o Microsoft
# Edge / Chrome headless (--print-to-pdf). Sem navegador, salva o proprio HTML.
#
# Secoes: 1 cabecalho JE | 2 titulo + ZE/municipio | 3 Painel de Viabilidade
# (identificacao + indicadores + situacao por meio + conclusao) | 4 testes por
# meio (LAN / Wi-Fi do local / Celular) | 5 dados da vistoria do GEL |
# 6 registro fotografico.

function ConvertTo-HtmlSafe {
    param([string] $Texto)
    if ($null -eq $Texto) { return '' }
    $Texto -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

# Brasao da Republica como data URI (assets/brasao-republica.png|jpg). Vazio se ausente.
function Get-BrasaoDataUri {
    foreach ($n in 'brasao-republica.png', 'brasao.png', 'brasao-republica.jpg', 'brasao.jpg') {
        $p = Join-Path $Global:RaizApp "assets\$n"
        if (Test-Path $p) {
            $mime = if ($p -match '\.jpe?g$') { 'image/jpeg' } else { 'image/png' }
            try {
                $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
                return 'data:{0};base64,{1}' -f $mime, $b64
            } catch { return '' }
        }
    }
    return ''
}

function Get-CaminhoNavegadorPdf {
    $cands = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        (Join-Path $env:ProgramFiles          'Microsoft\Edge\Application\msedge.exe')
        (Join-Path $env:LOCALAPPDATA          'Microsoft\Edge\Application\msedge.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
        (Join-Path $env:ProgramFiles          'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command msedge.exe, chrome.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Format-ValorMetrica {
    param($Valor, [string] $Unidade)
    if ($null -eq $Valor -or "$Valor" -eq '') { return 'sem medida' }
    (('{0} {1}' -f $Valor, $Unidade)).Trim()
}

function Get-RotuloVeredito {
    param([string] $Classe)
    switch ($Classe) {
        'viavel'              { 'Vi' + [char]0x00E1 + 'vel' }
        'ressalva'            { 'Ressalva' }
        'viavel_com_ressalva' { 'Vi' + [char]0x00E1 + 'vel c/ ressalva' }
        'inviavel'            { 'Invi' + [char]0x00E1 + 'vel' }
        default               { [string] $Classe }
    }
}

# Faixa aceitavel por extenso (sem simbolos <= / >=), p/ o relatorio.
function Get-FaixaEmPalavras {
    param($Direcao, $LimiarViavel, $LimiarRessalva, $Unidade)
    $u = [string] $Unidade
    $a = [char]0x00E1
    if ($Direcao -eq 'max') {
        return ('vi{0}vel: menor que {1} {3} / ressalva: menor que {2} {3}' -f $a, $LimiarViavel, $LimiarRessalva, $u)
    }
    return ('vi{0}vel: maior que {1} {3} / ressalva: maior que {2} {3}' -f $a, $LimiarViavel, $LimiarRessalva, $u)
}

function Get-CorVeredito {
    param([string] $Classe)
    switch ($Classe) {
        'viavel'              { '#1B7F3B' }
        'ressalva'            { '#B77F00' }
        'viavel_com_ressalva' { '#B77F00' }
        'inviavel'            { '#BC352A' }
        default               { '#444' }
    }
}

# --------------------------------------------------------------- graficos (SVG)
# Sem biblioteca nenhuma (o PDF e' impresso por um Chrome/Edge headless a
# partir do HTML) -- so' string building de <svg>, no mesmo espirito do resto
# deste arquivo. As duas funcoes sao puras (recebem dado pronto, sem tocar em
# $Global:*), pra serem faceis de testar isoladas.

# Numero para atributo/coordenada SVG: SEMPRE com ponto decimal. Sem isto, no
# Windows em pt-BR o "{0}" -f 38.7 vira "38,7" e o parser de SVG le a virgula
# como separador de coordenada -> a <polyline> vira um rabisco (bug de campo
# no relatorio de "velocidade ao longo do teste").
function Format-NumSvg {
    param($N)
    ([double] $N).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

# "Teto bonito" para o eixo Y: arredonda pra cima para 1/2/2,5/5/10 x 10^n.
function Get-NiceMax {
    param([double] $V)
    if ($V -le 0) { return 1.0 }
    $exp  = [math]::Floor([math]::Log10($V))
    $base = [math]::Pow(10, $exp)
    $frac = $V / $base
    $nice = if ($frac -le 1) { 1 } elseif ($frac -le 2) { 2 } elseif ($frac -le 2.5) { 2.5 } elseif ($frac -le 5) { 5 } else { 10 }
    return [double] ($nice * $base)
}

# Limiar (viavel) + direcao de uma metrica, a partir das linhas de avaliacao de
# uma medicao. $Chaves: nomes possiveis da metrica (ex.: 'rl_download','download').
# Devolve @{ limiar; direcao } ('max' = maior e' melhor / 'min' = menor e' melhor)
# ou $null se nao achar / sem limiar.
function Get-LimiarMetrica {
    param($Avaliacao, [string[]] $Chaves)
    foreach ($a in @($Avaliacao | Where-Object { $_ })) {
        $mk = [string] $a.metrica
        if ($Chaves -contains $mk -and $null -ne $a.limiar_viavel -and "$($a.limiar_viavel)" -ne '') {
            $dir = [string] $a.direcao
            return @{ limiar = [double] $a.limiar_viavel; direcao = $(if ($dir -eq 'min') { 'min' } else { 'max' }) }
        }
    }
    return $null
}

# Leitura automatica de uma curva (banda ao longo do tempo, ou latencia por
# amostra) -- a frase-laudo que ajuda a bater o olho e ver gargalo / instabilidade.
# $Pontos: lista {T; V} (V $null = amostra perdida). $Metrica: 'banda' | 'latencia'.
function Get-LaudoCurva {
    param(
        [array] $Pontos, [string] $Unidade = 'Mbps',
        [double] $Limiar = -1, [string] $Direcao = 'max',
        [string] $Metrica = 'banda'
    )
    $ordenados = @($Pontos | Where-Object { $_ } | Sort-Object { [double] $_.T })
    $vs = @($ordenados | Where-Object { $null -ne $_.V } | ForEach-Object { [double] $_.V })
    $n  = $vs.Count
    if ($n -lt 4) { return '' }

    $max   = ($vs | Measure-Object -Maximum).Maximum
    $min   = ($vs | Measure-Object -Minimum).Minimum
    $media = ($vs | Measure-Object -Average).Average
    $terco = [math]::Max(2, [int]($n / 3))
    $fim   = @($vs[($n - $terco)..($n - 1)])
    $mediaFim = ($fim | Measure-Object -Average).Average
    $sdFim = if ($fim.Count -gt 1) {
        [math]::Sqrt((($fim | ForEach-Object { ($_ - $mediaFim) * ($_ - $mediaFim) } | Measure-Object -Sum).Sum) / $fim.Count)
    } else { 0 }
    $cvFim = if ($mediaFim -gt 0) { $sdFim / $mediaFim } else { 0 }

    if ($Metrica -eq 'latencia') {
        $perdidas = @($ordenados | Where-Object { $null -eq $_.V }).Count
        $totAm    = $ordenados.Count
        $picos = @($vs | Where-Object { $_ -gt ($media + 2 * [math]::Max($sdFim, $media * 0.15)) }).Count
        $p = @()
        if ($cvFim -lt 0.25 -and $perdidas -eq 0 -and $picos -eq 0) {
            $p += ('lat' + [char]0x00EA + 'ncia estavel (~{0:0} ms)' -f $mediaFim)
        } else {
            $p += ('lat' + [char]0x00EA + 'ncia {0:0}-{1:0} ms' -f $min, $max)
        }
        if ($perdidas -ge 1) { $p += ('{0} amostra(s) perdida(s) (~{1:0}%)' -f $perdidas, ([math]::Round(100 * $perdidas / [math]::Max($totAm, 1)))) }
        if ($picos -ge 1)    { $p += ('{0} pico(s) acima da media' -f $picos) }
        if ($Limiar -ge 0)   { $p += ('media ' + $(if ($mediaFim -le $Limiar) { 'abaixo' } else { 'acima' }) + (' do teto de {0:0} ms' -f $Limiar)) }
        return (($p -join '; ') + '.')
    }

    # oscilacao (dente-de-serra): trocas de sinal relevantes na diferenca ponto-a-ponto
    $difs = @(for ($i = 1; $i -lt $n; $i++) { $vs[$i] - $vs[$i - 1] })
    $trocas = 0
    for ($i = 1; $i -lt $difs.Count; $i++) {
        if ((($difs[$i] -gt 0) -ne ($difs[$i - 1] -gt 0)) -and [math]::Abs($difs[$i]) -gt ($media * 0.06)) { $trocas++ }
    }
    $oscila = ($trocas -ge ($n * 0.30)) -and (($max - $min) -gt ($media * 0.4))
    # "quedas" so' contam DEPOIS que a curva chegou perto do pico (a rampa
    # inicial nao e' queda); a % usa o menor valor desse trecho.
    $iniPos = 0
    for ($i = 0; $i -lt $n; $i++) { if ($vs[$i] -ge ($max * 0.7)) { $iniPos = $i; break } }
    if ($iniPos -ge ($n - 2)) { $iniPos = [int]($n * 0.3) }
    $posArr = @($vs[$iniPos..($n - 1)])
    $minPos = ($posArr | Measure-Object -Minimum).Minimum
    $quedas = @($posArr | Where-Object { $_ -lt ($max * 0.6) }).Count

    $p = @()
    if ($oscila) {
        $p += ('oscilou entre {0:0.#} e {1:0.#} {2} (dente-de-serra)' -f $min, $max, $Unidade)
    } elseif ($cvFim -lt 0.12 -and $mediaFim -ge ($media * 0.9)) {
        $p += ('estabilizou em ~{0:0.#} {1}' -f $mediaFim, $Unidade)
    } elseif ($mediaFim -gt ($media * 1.15)) {
        $p += 'ainda subindo no fim do teste (nao estabilizou)'
    } else {
        $p += ('variou de {0:0.#} a {1:0.#} {2}' -f $min, $max, $Unidade)
    }
    if ($quedas -ge 1 -and $max -gt 0 -and $minPos -lt ($max * 0.7)) {
        $p += ('queda de ate -{0:0}% no meio do teste' -f [math]::Round((1 - $minPos / $max) * 100))
    }
    if ($Limiar -ge 0) {
        $ok = if ($Direcao -eq 'min') { $mediaFim -le $Limiar } else { $mediaFim -ge $Limiar }
        $p += ('media ' + $(if ($ok) { 'acima' } else { 'abaixo' }) + (' do alvo de {0:0.#} {1}' -f $Limiar, $Unidade))
    }
    return (($p -join '; ') + '.')
}

# Grafico de barras horizontais. $Barras: lista de {Rotulo; Valor; Cor?} --
# Valor $null vira uma linha "sem medida" (sem barra). Devolve '' se nao
# houver nenhuma barra (o chamador so' inclui o grafico se vier algo).
function Get-GraficoBarrasHtml {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Barras,
        [string] $Titulo = '',
        [string] $Unidade = '',
        [int] $Largura = 300,
        [int] $AlturaBarra = 16,
        [int] $EspacoBarra = 8
    )
    $itens = @($Barras | Where-Object { $_ })
    if (-not $itens.Count) { return '' }
    $comValor = @($itens | Where-Object { $null -ne $_.Valor -and "$($_.Valor)" -ne '' })
    $max = if ($comValor.Count) { ($comValor | ForEach-Object { [double] $_.Valor } | Measure-Object -Maximum).Maximum } else { 0 }
    if ($max -le 0) { $max = 1 }

    $margemRotulo = 92
    $margemValor  = 58
    $areaBarra = [math]::Max(20, $Largura - $margemRotulo - $margemValor)
    $passo = $AlturaBarra + $EspacoBarra
    $alturaSvg = ($itens.Count * $passo) + $EspacoBarra

    $y = $EspacoBarra
    $partes = foreach ($b in $itens) {
        $rotulo = ConvertTo-HtmlSafe ([string] $b.Rotulo)
        $meioY  = Format-NumSvg ([math]::Round($y + $AlturaBarra * 0.72, 1))
        if ($null -eq $b.Valor -or "$($b.Valor)" -eq '') {
            @"
<text x="0" y="$meioY" font-size="9" fill="#8891A0">$rotulo</text>
<text x="$margemRotulo" y="$meioY" font-size="9" fill="#8891A0" font-style="italic">sem medida</text>
"@
        } else {
            $cor = if ($b.PSObject.Properties['Cor'] -and $b.Cor) { [string] $b.Cor } else { '#123FA8' }
            $w = [math]::Round(($areaBarra * ([math]::Min(1.0, [double] $b.Valor / $max))), 1)
            if ($w -lt 1) { $w = 1 }
            $w = Format-NumSvg $w
            $valTxt = ConvertTo-HtmlSafe (('{0:N1} {1}' -f [double] $b.Valor, $Unidade).Trim())
            @"
<text x="0" y="$meioY" font-size="9" fill="#14181F">$rotulo</text>
<rect x="$margemRotulo" y="$y" width="$w" height="$AlturaBarra" rx="2" fill="$cor"/>
<text x="$($margemRotulo + $areaBarra + 6)" y="$meioY" font-size="9" fill="#14181F">$valTxt</text>
"@
        }
        $y += $passo
    }
    $tit = if ($Titulo) { '<div class="graftit">' + (ConvertTo-HtmlSafe $Titulo) + '</div>' } else { '' }
    @"
<div class="grafico">
  $tit
  <svg width="$Largura" height="$alturaSvg" viewBox="0 0 $Largura $alturaSvg" xmlns="http://www.w3.org/2000/svg">
    $($partes -join "`n")
  </svg>
</div>
"@
}

# Grafico de linha (curva ao longo do tempo). $Series: lista de {Nome; Cor;
# Pontos:[{T;V}]} -- T/V numericos; V=$null vira um "buraco" na linha (sem
# interpolar, e' assim que uma amostra perdida/falha aparece). Devolve ''
# se nenhuma serie tiver ponto valido.
function Get-GraficoLinhaHtml {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Series,
        [string] $Titulo = '',
        [string] $EixoY = '',
        [string] $EixoXUnidade = '',        # ex.: 's' -> ticks "0 s", "3 s"...
        [int] $Largura = 300,
        [int] $Altura = 110,
        [double] $Limiar = -1,              # linha de alvo horizontal (>= 0 desenha)
        [string] $DirecaoLimiar = 'max',    # 'max' = alvo e' piso / 'min' = alvo e' teto
        [switch] $MarcarExtremos,           # ponto + rotulo no minimo e no pico (1a serie)
        [switch] $Media,                    # linha pontilhada na media (1a serie)
        [string] $Laudo = ''               # frase de leitura da curva (Get-LaudoCurva)
    )
    $comPonto = @($Series | Where-Object { $_ -and $_.Pontos } | ForEach-Object { $_.Pontos } | Where-Object { $_ -and $null -ne $_.V -and $null -ne $_.T })
    if (-not $comPonto.Count) { return '' }

    $margemEsq = 40; $margemDir = 12; $margemTopo = 10; $margemBaixo = 26
    $areaW = [math]::Max(20, $Largura - $margemEsq - $margemDir)
    $areaH = [math]::Max(20, $Altura - $margemTopo - $margemBaixo)
    $x0 = $margemEsq; $x1 = $margemEsq + $areaW
    $y0 = $margemTopo; $y1 = $margemTopo + $areaH
    $tMin = ($comPonto | ForEach-Object { [double] $_.T } | Measure-Object -Minimum).Minimum
    $tMax = ($comPonto | ForEach-Object { [double] $_.T } | Measure-Object -Maximum).Maximum
    if ($tMax -le $tMin) { $tMax = $tMin + 1 }
    $vMaxDado = ($comPonto | ForEach-Object { [double] $_.V } | Measure-Object -Maximum).Maximum
    if ($Limiar -ge 0 -and $Limiar -gt $vMaxDado) { $vMaxDado = $Limiar }
    $vMax = Get-NiceMax ($vMaxDado * 1.08)
    if ($vMax -le 0) { $vMax = 1 }
    $escX = { param($t) Format-NumSvg ([math]::Round($x0 + ((([double] $t - $tMin) / ($tMax - $tMin)) * $areaW), 1)) }
    $escY = { param($v) Format-NumSvg ([math]::Round($y0 + $areaH - (([double] $v / $vMax) * $areaH), 1)) }

    # --- grade + rotulos do eixo Y (4 divisoes) ---
    $gradeY = for ($k = 0; $k -le 4; $k++) {
        $v = $vMax * $k / 4
        $y = & $escY $v
        $vTxt = if ($vMax -ge 20) { '{0:0}' -f $v } else { '{0:0.#}' -f $v }
        "<line x1=""$x0"" y1=""$y"" x2=""$x1"" y2=""$y"" stroke=""#EDF0F5"" stroke-width=""1""/>" +
        "<text x=""$($x0 - 4)"" y=""$([double]$y + 3)"" font-size=""8"" text-anchor=""end"" fill=""#8891A0"">$vTxt</text>"
    }
    $rotEixoY = if ($EixoY) { "<text x=""2"" y=""$($y0 - 2)"" font-size=""8"" fill=""#8891A0"">$(ConvertTo-HtmlSafe $EixoY)</text>" } else { '' }

    # --- ticks do eixo X (5 marcas) ---
    $ticksX = for ($k = 0; $k -le 4; $k++) {
        $t = $tMin + ($tMax - $tMin) * $k / 4
        $x = & $escX $t
        $tTxt = ('{0:0.#}' -f $t) + $(if ($EixoXUnidade) { ' ' + $EixoXUnidade } else { '' })
        "<line x1=""$x"" y1=""$y1"" x2=""$x"" y2=""$([double]$y1 + 3)"" stroke=""#D6DBE6"" stroke-width=""1""/>" +
        "<text x=""$x"" y=""$([double]$y1 + 13)"" font-size=""8"" text-anchor=""middle"" fill=""#8891A0"">$tTxt</text>"
    }

    # --- linha do limiar (alvo) ---
    $limHtml = ''
    if ($Limiar -ge 0 -and $Limiar -le $vMax) {
        $yl = & $escY $Limiar
        $rot = if ($DirecaoLimiar -eq 'min') { 'teto' } else { 'alvo' }
        $limHtml = "<line x1=""$x0"" y1=""$yl"" x2=""$x1"" y2=""$yl"" stroke=""#BC352A"" stroke-width=""1"" stroke-dasharray=""4 3""/>" +
                   "<text x=""$([double]$x1 - 2)"" y=""$([double]$yl - 3)"" font-size=""8"" text-anchor=""end"" fill=""#BC352A"">$rot $('{0:0.#}' -f $Limiar)</text>"
    }

    $seriesL = @($Series | Where-Object { $_ -and $_.Pontos })
    $linhas = foreach ($s in $seriesL) {
        $cor = if ($s.Cor) { [string] $s.Cor } else { '#123FA8' }
        $ptsOrd = @($s.Pontos | Where-Object { $_ } | Sort-Object { [double] $_.T })
        if ($ptsOrd.Count -gt 60) {
            $passoDec = [math]::Ceiling($ptsOrd.Count / 60)
            $ptsOrd = @(for ($k = 0; $k -lt $ptsOrd.Count; $k += $passoDec) { $ptsOrd[$k] }) + @($ptsOrd[-1])
        }
        $trechoAtual = New-Object System.Collections.Generic.List[string]
        $trechos = New-Object System.Collections.Generic.List[string]
        foreach ($p in $ptsOrd) {
            if (-not $p -or $null -eq $p.V -or $null -eq $p.T) {
                if ($trechoAtual.Count -gt 1) { $trechos.Add(($trechoAtual -join ' ')) }
                $trechoAtual = New-Object System.Collections.Generic.List[string]
                continue
            }
            $trechoAtual.Add(('{0},{1}' -f (& $escX $p.T), (& $escY $p.V)))
        }
        if ($trechoAtual.Count -gt 1) { $trechos.Add(($trechoAtual -join ' ')) }
        foreach ($pts in $trechos) { '<polyline points="' + $pts + '" fill="none" stroke="' + $cor + '" stroke-width="1.7"/>' }
    }

    # --- media + extremos (so' na 1a serie, quando pedido) ---
    $decor = ''
    if (($Media -or $MarcarExtremos) -and $seriesL.Count) {
        $vsP = @($seriesL[0].Pontos | Where-Object { $_ -and $null -ne $_.V -and $null -ne $_.T } | Sort-Object { [double] $_.T })
        if ($vsP.Count -ge 3) {
            $cor0 = if ($seriesL[0].Cor) { [string] $seriesL[0].Cor } else { '#123FA8' }
            if ($Media) {
                $md = ($vsP | ForEach-Object { [double] $_.V } | Measure-Object -Average).Average
                $ym = & $escY $md
                $decor += "<line x1=""$x0"" y1=""$ym"" x2=""$x1"" y2=""$ym"" stroke=""$cor0"" stroke-width=""1"" stroke-dasharray=""2 3"" opacity=""0.7""/>" +
                          "<text x=""$([double]$x0 + 3)"" y=""$([double]$ym - 3)"" font-size=""8"" fill=""$cor0"">media $('{0:0.#}' -f $md)</text>"
            }
            if ($MarcarExtremos) {
                $pMax = $vsP | Sort-Object { [double] $_.V } -Descending | Select-Object -First 1
                $pMin = $vsP | Sort-Object { [double] $_.V } | Select-Object -First 1
                foreach ($pr in @(@{ p = $pMax; t = 'pico' }, @{ p = $pMin; t = 'min' })) {
                    $cx = & $escX $pr.p.T; $cy = & $escY $pr.p.V
                    $decor += "<circle cx=""$cx"" cy=""$cy"" r=""2.4"" fill=""$cor0""/>" +
                              "<text x=""$([double]$cx + 4)"" y=""$([double]$cy - 3)"" font-size=""8"" fill=""#333"">$($pr.t) $('{0:0.#}' -f [double] $pr.p.V)</text>"
                }
            }
        }
    }

    $legenda = ($Series | Where-Object { $_ -and $_.Nome } | ForEach-Object {
        '<span style="color:' + [string] $_.Cor + '">&#9632;</span> ' + (ConvertTo-HtmlSafe ([string] $_.Nome))
    }) -join '&nbsp;&nbsp;'
    $tit     = if ($Titulo) { '<div class="graftit">' + (ConvertTo-HtmlSafe $Titulo) + '</div>' } else { '' }
    $legHtml = if ($legenda) { '<div class="graflegenda">' + $legenda + '</div>' } else { '' }
    $laudoHtml = if ($Laudo) { '<div class="graflaudo">' + (ConvertTo-HtmlSafe $Laudo) + '</div>' } else { '' }
    @"
<div class="grafico">
  $tit
  <svg width="$Largura" height="$Altura" viewBox="0 0 $Largura $Altura" xmlns="http://www.w3.org/2000/svg">
    $($gradeY -join "`n    ")
    $($ticksX -join "`n    ")
    <line x1="$x0" y1="$y0" x2="$x0" y2="$y1" stroke="#C6CCD8" stroke-width="1"/>
    <line x1="$x0" y1="$y1" x2="$x1" y2="$y1" stroke="#C6CCD8" stroke-width="1"/>
    $rotEixoY
    $limHtml
    $($linhas -join "`n    ")
    $decor
  </svg>
  $legHtml
  $laudoHtml
</div>
"@
}

# ------------------------------------------------------------- helpers do relatorio

# Tabela "Metrica | Valor | Faixa | Classificacao [ | Motivo do ajuste ]".
function Get-TabelaAvaliacaoHtml {
    param($Linhas, [switch] $ComMotivo, [string] $Modo = 'completo')
    $ls = @($Linhas | Where-Object { $_ })
    if (-not $ls.Count) { return '' }

    if ($Modo -eq 'medicao') {
        $body = foreach ($a in $ls) {
            $val = ConvertTo-HtmlSafe (Format-ValorMetrica $a.valor $a.unidade)
            "      <tr><td>$(ConvertTo-HtmlSafe ([string] $a.rotulo))</td><td class=""mono"">$val</td></tr>"
        }
        return "  <table>`n    <thead><tr><th>M&eacute;trica</th><th>Valor medido</th></tr></thead>`n    <tbody>`n$($body -join "`n")`n    </tbody>`n  </table>"
    }
    if ($Modo -eq 'referencia') {
        $body = foreach ($a in $ls) {
            $val   = ConvertTo-HtmlSafe (Format-ValorMetrica $a.valor $a.unidade)
            $faixa = ConvertTo-HtmlSafe (Get-FaixaEmPalavras $a.direcao $a.limiar_viavel $a.limiar_ressalva $a.unidade)
            "      <tr><td>$(ConvertTo-HtmlSafe ([string] $a.rotulo))</td><td class=""mono"">$val</td><td class=""mono small"">$faixa</td></tr>"
        }
        return "  <table>`n    <thead><tr><th>M&eacute;trica</th><th>Valor medido</th><th>Faixa de refer&ecirc;ncia</th></tr></thead>`n    <tbody>`n$($body -join "`n")`n    </tbody>`n  </table>"
    }

    $head = if ($ComMotivo) {
        '<tr><th>M&eacute;trica</th><th>Valor medido</th><th>Faixa aceit&aacute;vel</th><th>Classifica&ccedil;&atilde;o</th><th>Motivo do ajuste</th></tr>'
    } else {
        '<tr><th>M&eacute;trica</th><th>Valor medido</th><th>Faixa aceit&aacute;vel</th><th>Classifica&ccedil;&atilde;o</th></tr>'
    }
    $body = foreach ($a in $ls) {
        $val   = ConvertTo-HtmlSafe (Format-ValorMetrica $a.valor $a.unidade)
        $faixa = ConvertTo-HtmlSafe (Get-FaixaEmPalavras $a.direcao $a.limiar_viavel $a.limiar_ressalva $a.unidade)
        $cor   = Get-CorVeredito $a.classe_final
        $cls   = ConvertTo-HtmlSafe (Get-RotuloVeredito $a.classe_final)
        $mot   = if ($a.ajustada -and $a.justificativa) { ConvertTo-HtmlSafe ([string] $a.justificativa) } else { '&mdash;' }
        if ($ComMotivo) {
            "      <tr><td>$(ConvertTo-HtmlSafe ([string] $a.rotulo))</td><td class=""mono"">$val</td><td class=""mono small"">$faixa</td><td style=""color:$cor;font-weight:600"">$cls</td><td class=""small"">$mot</td></tr>"
        } else {
            "      <tr><td>$(ConvertTo-HtmlSafe ([string] $a.rotulo))</td><td class=""mono"">$val</td><td class=""mono small"">$faixa</td><td style=""color:$cor;font-weight:600"">$cls</td></tr>"
        }
    }
    "  <table>`n    <thead>$head</thead>`n    <tbody>`n$($body -join "`n")`n    </tbody>`n  </table>"
}

# Tabela simples "Metrica | Valor medido" a partir dos numeros crus de uma medicao
# (fase com a VPN dos meios que NAO sao o recomendado).
function Get-TabelaVpnNumerosHtml {
    param($M)
    $rows = @()
    if ($null -ne $M.latencia_ms -and "$($M.latencia_ms)" -ne '')          { $rows += "      <tr><td>Lat&ecirc;ncia</td><td class=""mono"">$($M.latencia_ms) ms</td></tr>" }
    if ($null -ne $M.jitter_ms -and "$($M.jitter_ms)" -ne '')              { $rows += "      <tr><td>Jitter</td><td class=""mono"">$($M.jitter_ms) ms</td></tr>" }
    if ($null -ne $M.perda_percentual -and "$($M.perda_percentual)" -ne '') { $rows += "      <tr><td>Perda de pacotes</td><td class=""mono"">$($M.perda_percentual) %</td></tr>" }
    if ($null -ne $M.vpn_download_mbps -and "$($M.vpn_download_mbps)" -ne '') { $rows += "      <tr><td>Download (VPN)</td><td class=""mono"">$($M.vpn_download_mbps) Mbps</td></tr>" }
    if ($null -ne $M.vpn_upload_mbps -and "$($M.vpn_upload_mbps)" -ne '')   { $rows += "      <tr><td>Upload (VPN)</td><td class=""mono"">$($M.vpn_upload_mbps) Mbps</td></tr>" }
    if (-not $rows.Count) { return '' }
    "  <table>`n    <thead><tr><th>M&eacute;trica</th><th>Valor medido</th></tr></thead>`n    <tbody>`n$($rows -join "`n")`n    </tbody>`n  </table>"
}

# Item 2 do pedido do usuario: barras "sem VPN vs com VPN" pro mesmo meio --
# um mini-grafico por metrica (download/upload/latencia), so' as que tiverem
# pelo menos um dos dois lados medido.
function Get-GraficoSemComVpnHtml {
    param($M)
    $grupos = @(
        @{ Titulo = 'Download (Mbps)'; Unidade = 'Mbps'; Sem = (Get-Prop $M 'rede_local_download'); Com = (Get-Prop $M 'vpn_download_mbps') }
        @{ Titulo = 'Upload (Mbps)';   Unidade = 'Mbps'; Sem = (Get-Prop $M 'rede_local_upload_mbps'); Com = (Get-Prop $M 'vpn_upload_mbps') }
        @{ Titulo = 'Lat' + [char]0x00EA + 'ncia (ms)'; Unidade = 'ms'; Sem = (Get-Prop $M 'download_lat_ms'); Com = (Get-Prop $M 'latencia_ms') }
    )
    $blocos = foreach ($g in $grupos) {
        if ($null -eq $g.Sem -and $null -eq $g.Com) { continue }
        $barras = @(
            [pscustomobject]@{ Rotulo = 'Sem VPN'; Valor = $g.Sem; Cor = '#5C6472' }
            [pscustomobject]@{ Rotulo = 'Com VPN'; Valor = $g.Com; Cor = '#123FA8' }
        )
        Get-GraficoBarrasHtml -Barras $barras -Titulo $g.Titulo -Unidade $g.Unidade -Largura 230 -AlturaBarra 14 -EspacoBarra 6
    }
    $blocos = @($blocos | Where-Object { $_ })
    if (-not $blocos.Count) { return '' }
    '<div class="graflinha">' + ($blocos -join "`n") + '</div>'
}

# Curva de banda Download + Upload em DOIS graficos lado a lado (cada um com seu
# eixo 0..t em segundos), com linha do alvo (limiar), media, min/pico e a
# frase-laudo. $Pontos: [{T; Mbps; Fase='download'|'upload'}].
function Get-CurvaDuploHtml {
    param($Pontos, $Avaliacao, [string[]] $ChavesDl, [string[]] $ChavesUp,
          [string] $Contexto = '', [int] $Largura = 400, [int] $Altura = 190)
    $pts = @($Pontos | Where-Object { $_ })
    if (-not $pts.Count) { return '' }
    $mk = { param($F) @($pts | Where-Object { $_.Fase -eq $F } | ForEach-Object { [pscustomobject]@{ T = [double] $_.T; V = $_.Mbps } }) }
    $ctx = if ($Contexto) { " ($Contexto)" } else { '' }
    $g = @()
    foreach ($par in @(
            @{ nome = 'Download'; cor = '#123FA8'; serie = @(& $mk 'download'); chaves = $ChavesDl },
            @{ nome = 'Upload';   cor = '#1B7F3B'; serie = @(& $mk 'upload');   chaves = $ChavesUp })) {
        if (-not @($par.serie).Count) { continue }
        $lim = Get-LimiarMetrica $Avaliacao $par.chaves
        $lv  = if ($lim) { [double] $lim.limiar } else { -1 }
        $g += Get-GraficoLinhaHtml -Series @([pscustomobject]@{ Nome = $par.nome; Cor = $par.cor; Pontos = @($par.serie) }) `
            -Titulo ("$($par.nome) ao longo do teste$ctx") -EixoY 'Mbps' -EixoXUnidade 's' `
            -Largura $Largura -Altura $Altura -Limiar $lv -DirecaoLimiar 'max' -Media -MarcarExtremos `
            -Laudo (Get-LaudoCurva -Pontos @($par.serie) -Unidade 'Mbps' -Limiar $lv -Direcao 'max' -Metrica 'banda')
    }
    $g = @($g | Where-Object { $_ })
    if (-not $g.Count) { return '' }
    '<div class="grafpar">' + ($g -join "`n") + '</div>'
}

# Item 5: curva de velocidade do speedtest (Fase 1, sem VPN).
function Get-GraficoCurvaVelocidadeHtml {
    param($M, [int] $Largura = 400, [int] $Altura = 190)
    Get-CurvaDuploHtml -Pontos @(Get-Prop $M 'rede_local_serie_velocidade') `
        -Avaliacao @(Get-Prop $M 'rede_local_avaliacao') -ChavesDl @('rl_download') -ChavesUp @('rl_upload') `
        -Contexto 'sem VPN' -Largura $Largura -Altura $Altura
}

# Item 6a: curva de banda do iperf3 (Fase 2, com VPN).
function Get-GraficoCurvaBandaVpnHtml {
    param($M, $Avaliacao = @(), [int] $Largura = 400, [int] $Altura = 190)
    Get-CurvaDuploHtml -Pontos @(Get-Prop $M 'vpn_serie_banda') `
        -Avaliacao $Avaliacao -ChavesDl @('download') -ChavesUp @('upload') `
        -Contexto 'com a VPN' -Largura $Largura -Altura $Altura
}

# Item 6b: latencia por amostra do ping (Fase 2, com VPN) -- uma amostra sem
# resposta vira um buraco na linha (ver Test-Latencia/AmostrasMs).
function Get-GraficoLatenciaAmostraHtml {
    param($M, $Avaliacao = @(), [int] $Largura = 780, [int] $Altura = 190)
    $amostras = @(Get-Prop $M 'vpn_serie_latencia')
    if (-not $amostras.Count) { return '' }
    $pontos = for ($i = 0; $i -lt $amostras.Count; $i++) {
        [pscustomobject]@{ T = $i + 1; V = $amostras[$i] }
    }
    $lim = Get-LimiarMetrica $Avaliacao @('latencia')
    $lv  = if ($lim) { [double] $lim.limiar } else { -1 }
    $series = @([pscustomobject]@{ Nome = 'Lat' + [char]0x00EA + 'ncia'; Cor = '#B77F00'; Pontos = @($pontos) })
    $titulo = 'Lat' + [char]0x00EA + 'ncia por amostra do ping (falha = buraco na linha)'
    Get-GraficoLinhaHtml -Series $series -Titulo $titulo -EixoY 'ms' -EixoXUnidade 'amostra' `
        -Largura $Largura -Altura $Altura -Limiar $lv -DirecaoLimiar 'min' -Media `
        -Laudo (Get-LaudoCurva -Pontos $pontos -Unidade 'ms' -Limiar $lv -Direcao 'min' -Metrica 'latencia')
}

# Item 7: comparacao entre as tentativas do "Refazer" (so' aparece quando o
# tecnico refez a fase pelo menos uma vez -- ver New-MedicaoAtual/
# fase1_tentativas_detalhe/fase2_tentativas_detalhe).
function Get-GraficoTentativasHtml {
    param($M)
    $blocos = @()

    $f1 = @(Get-Prop $M 'rede_local_tentativas_detalhe')
    if ($f1.Count -gt 1) {
        $dlAtual = Get-Prop $M 'rede_local_download'
        $mediaDl = if ($null -ne $dlAtual) { [double] $dlAtual } else { $null }
        $barrasDl = @()
        for ($i = 0; $i -lt $f1.Count; $i++) { $barrasDl += [pscustomobject]@{ Rotulo = "Tentativa $($i+1)"; Valor = $f1[$i].download_mbps; Cor = '#8891A0' } }
        $barrasDl += [pscustomobject]@{ Rotulo = 'M' + [char]0x00E9 + 'dia'; Valor = $mediaDl; Cor = '#123FA8' }
        $blocos += Get-GraficoBarrasHtml -Barras $barrasDl -Titulo 'Rede local -- download por tentativa (Mbps)' -Unidade 'Mbps' -Largura 260 -AlturaBarra 14 -EspacoBarra 6
    }

    $f2 = @(Get-Prop $M 'vpn_tentativas_detalhe')
    if ($f2.Count -gt 1) {
        $dlAtual2 = Get-Prop $M 'vpn_download_mbps'
        $mediaDl2 = if ($null -ne $dlAtual2) { [double] $dlAtual2 } else { $null }
        $barrasDl2 = @()
        for ($i = 0; $i -lt $f2.Count; $i++) { $barrasDl2 += [pscustomobject]@{ Rotulo = "Tentativa $($i+1)"; Valor = $f2[$i].download_mbps; Cor = '#8891A0' } }
        $barrasDl2 += [pscustomobject]@{ Rotulo = 'M' + [char]0x00E9 + 'dia'; Valor = $mediaDl2; Cor = '#123FA8' }
        $blocos += Get-GraficoBarrasHtml -Barras $barrasDl2 -Titulo 'Com VPN -- download por tentativa (Mbps)' -Unidade 'Mbps' -Largura 260 -AlturaBarra 14 -EspacoBarra 6
    }

    $blocos = @($blocos | Where-Object { $_ })
    if (-not $blocos.Count) { return '' }
    '<div class="ptit" style="margin-top:8px">Tentativas do "Refazer"</div><div class="graflinha">' + ($blocos -join "`n") + '</div>'
}

# Enderecamento da placa usada neste meio (IP / mascara / gateway / DNS / origem),
# congelado no snapshot da Fase 1 -- mostrado logo abaixo do titulo do meio.
# '' se nao houver IP (meio "nao se aplica" ou resultado antigo sem os campos).
function Get-EnderecamentoMeioHtml {
    param($M)
    $p  = $M.PSObject.Properties
    $ip = if ($p['rede_local_ip']) { [string] $M.rede_local_ip } else { '' }
    if (-not $ip) { return '' }
    $itens = @('<span><b>IP:</b> ' + (ConvertTo-HtmlSafe $ip) + '</span>')
    if ($p['rede_local_mascara'] -and [string] $M.rede_local_mascara) {
        $itens += '<span><b>M&aacute;scara:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_mascara)) + '</span>' }
    if ($p['rede_local_gateway'] -and [string] $M.rede_local_gateway) {
        $itens += '<span><b>Gateway:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_gateway)) + '</span>' }
    $dns = if ($p['rede_local_dns']) { @($M.rede_local_dns) | Where-Object { $_ } } else { @() }
    if ($dns.Count) {
        $itens += '<span><b>DNS:</b> ' + (ConvertTo-HtmlSafe ($dns -join ', ')) + '</span>' }
    if ($p['rede_local_ip_origem'] -and [string] $M.rede_local_ip_origem) {
        $itens += '<span><b>Origem do IP:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_ip_origem)) + '</span>' }
    '  <div class="endr">' + ($itens -join '') + '</div>'
}

# Bloco de um meio na secao 4 (Rede local sem VPN + Com a VPN, lado a lado).
function Get-MeioBlocoHtml {
    param($R, $M, [bool] $Recomendado, [string] $Modo = 'completo')
    $tit = ConvertTo-HtmlSafe ([string] $M.rotulo)
    if (-not $tit) { $tit = ConvertTo-HtmlSafe ([string] $M.meio) }

    if ($M.nao_aplicavel) {
        $rot = if ($Modo -eq 'completo') { 'N&Atilde;O APLIC&Aacute;VEL' } else { 'N&Atilde;O SE APLICA' }
        $mot = if ($M.motivo_nao_aplicavel) { ' &mdash; ' + (ConvertTo-HtmlSafe ([string] $M.motivo_nao_aplicavel)) } else { '' }
        return "  <div class=""meio na""><b>$tit</b> &mdash; $rot$mot</div>"
    }

    if ($Modo -ne 'completo') {
        $badge = ''
    } else {
        $cor  = Get-CorVeredito $M.veredito
        $ver  = ConvertTo-HtmlSafe (Get-RotuloVeredito $M.veredito)
        $badge = "<span class=""badge"" style=""color:$cor;border-color:$cor"">$ver</span>"
    }
    $flag = if ($Recomendado) { ' <span class="tag">meio recomendado</span>' } else { '' }

    # Propriedades do meio/placa, mostradas AO LADO DO TITULO (congeladas no
    # momento da checagem -- ver New-ResultadoJson). A "Velocidade da placa"
    # vem do adaptador (Get-NetAdapter.Speed), NAO do teste de velocidade:
    #   LAN            -> Velocidade da placa de rede
    #   Wi-Fi do local -> Provedor . SSID . Banda . Nivel do sinal . Velocidade da placa Wi-Fi
    #   Celular        -> Operadora . Banda . Nivel do sinal . Velocidade da placa Wi-Fi
    $meio    = [string] $M.meio
    $velLink = if ($M.PSObject.Properties['rede_local_velocidade_link_mbps']) { $M.rede_local_velocidade_link_mbps } else { $null }
    $sinalPct = if ($M.PSObject.Properties['rede_local_wifi_sinal_pct']) { $M.rede_local_wifi_sinal_pct } else { $null }
    $props = @()
    if ($meio -eq 'lan') {
        if ($velLink) { $props += '<b>Velocidade da placa de rede:</b> ' + $velLink + ' Mbps' }
    } elseif ($meio -eq 'wifi_local') {
        if ($M.rede_local_wifi_ssid)  { $props += '<b>Rede (SSID):</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_wifi_ssid)) }
        if ($M.rede_local_wifi_banda) { $props += '<b>Banda:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_wifi_banda)) }
        if ($null -ne $sinalPct -and "$sinalPct" -ne '') { $props += '<b>N&iacute;vel do sinal:</b> ' + $sinalPct + ' %' }
        if ($velLink) { $props += '<b>Velocidade da placa Wi-Fi:</b> ' + $velLink + ' Mbps' }
    } elseif ($meio -eq 'celular') {
        if ($M.operadora)             { $props += '<b>Operadora:</b> ' + (ConvertTo-HtmlSafe ([string] $M.operadora)) }
        if ($M.rede_local_wifi_banda) { $props += '<b>Banda:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_wifi_banda)) }
        if ($null -ne $sinalPct -and "$sinalPct" -ne '') { $props += '<b>N&iacute;vel do sinal:</b> ' + $sinalPct + ' %' }
        if ($velLink) { $props += '<b>Velocidade da placa Wi-Fi:</b> ' + $velLink + ' Mbps' }
    }
    $titPropsHtml = if ($props.Count) { '<span class="meiotit-props">' + ($props -join ' &middot; ') + '</span>' } else { '' }

    # Enderecamento da placa (logo abaixo do titulo do meio).
    $endrHtml = Get-EnderecamentoMeioHtml -M $M

    # Provedor + servidor do teste de velocidade -- ao lado da secao "SEM VPN".
    $rlMetaItens = @()
    if ($M.rede_local_provedor) { $rlMetaItens += '<b>Provedor:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_provedor)) }
    $rlServidor = if ($M.PSObject.Properties['rede_local_servidor']) { [string] $M.rede_local_servidor } else { '' }
    if ($rlServidor) { $rlMetaItens += '<b>Servidor:</b> ' + (ConvertTo-HtmlSafe $rlServidor) }
    $rlMetaHtml = if ($rlMetaItens.Count) { '<div class="rlmeta">' + ($rlMetaItens -join ' &middot; ') + '</div>' } else { '' }

    $diagBox = ''
    if ($M.rede_local_diagnostico -and (@('handshake', 'bloqueio') -contains [string] $M.rede_local_falha_tipo)) {
        $rot = if ([string] $M.rede_local_falha_tipo -eq 'handshake') { 'Rede local fraca / inst&aacute;vel' } else { 'Teste de velocidade bloqueado no local' }
        $diagBox = '<div class="warn"><b>' + $rot + ':</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_diagnostico)) + '</div>'
    }
    $f1 = Get-TabelaAvaliacaoHtml -Linhas $M.rede_local_avaliacao -Modo $Modo
    if (-not $f1) { $f1 = '<div class="small">O teste de velocidade n&atilde;o mediu neste meio.</div>' }
    $avalVpn = if ($Recomendado) { @($R.avaliacao) } else { @() }
    $grafVelocidade = Get-GraficoCurvaVelocidadeHtml -M $M

    if ($M.vpn_conectou) {
        $f2 = if ($Recomendado) { Get-TabelaAvaliacaoHtml -Linhas $R.avaliacao -ComMotivo -Modo $Modo } else { Get-TabelaVpnNumerosHtml $M }
        if (-not $f2) { $f2 = '<div class="small">Sem m&eacute;tricas registradas para a fase com a VPN.</div>' }
        $grafBanda    = Get-GraficoCurvaBandaVpnHtml -M $M -Avaliacao $avalVpn
        $grafLatencia = Get-GraficoLatenciaAmostraHtml -M $M -Avaliacao $avalVpn
    } else {
        $mv = if ($M.vpn_motivo) { ' Motivo: ' + (ConvertTo-HtmlSafe ([string] $M.vpn_motivo)) } else { '' }
        $f2 = '<div class="warn"><b>N&atilde;o foi poss&iacute;vel conectar a VPN da Justi&ccedil;a Eleitoral neste meio.</b>' + $mv + '</div>'
        $grafBanda = ''; $grafLatencia = ''
    }
    $subSem = if ($Modo -eq 'completo') { 'Sem VPN conectada &mdash; teste de velocidade' } else { 'Sem VPN &mdash; rede local' }
    $subCom = if ($Modo -eq 'completo') { 'Com VPN conectada &mdash; diagn&oacute;stico pela VPN da Justi&ccedil;a Eleitoral' } else { 'Com VPN &mdash; pela VPN da Justi&ccedil;a Eleitoral' }

    # itens 2 (sem/com VPN) e 7 (tentativas do "Refazer") -- so' aparecem se
    # houver algo pra mostrar (as proprias funcoes devolvem '' senao).
    $grafSemCom     = Get-GraficoSemComVpnHtml -M $M
    $grafTentativas = Get-GraficoTentativasHtml -M $M

    # As curvas ao longo do tempo saem das colunas e vao pra uma faixa de largura
    # total, centralizada e maior (mais facil bater o olho e ver gargalo/queda).
    $zonaGraf = @($grafVelocidade, $grafBanda, $grafLatencia | Where-Object { $_ })
    $zonaGrafHtml = if ($zonaGraf.Count) {
        '<div class="grafzona"><div class="graftit">Curvas ao longo do teste</div>' + ($zonaGraf -join "`n") + '</div>'
    } else { '' }

    @"
  <div class="meio">
    <div class="meiotit"><span>$tit</span>$badge$flag$titPropsHtml</div>
    $endrHtml
    $grafSemCom
    <div class="cols">
      <div>
        <div class="subt">$subSem</div>
        $rlMetaHtml
        $diagBox
        $f1
      </div>
      <div>
        <div class="subt">$subCom</div>
        $f2
      </div>
    </div>
    $zonaGrafHtml
    $grafTentativas
  </div>
"@
}

# Classificacao do local (analogo ao "Classificacao do imovel" da SEMAP).
# Frase pro relatorio sobre o cabo de rede (so' quando a conexao escolhida
# e' a LAN e o tecnico respondeu). '' = nao informado -> a linha nao aparece.
function Get-CaboLanTextoRelatorio {
    param($R)
    $c = if ($R.PSObject.Properties['cabo_lan']) { $R.cabo_lan } else { $null }
    if (-not $c) { return '' }
    $nec = if ($c.PSObject.Properties['necessario']) { $c.necessario } else { $null }
    if ($null -eq $nec) { return '' }
    if (-not $nec) { return 'N&atilde;o &eacute; preciso passar cabo de rede at&eacute; o ponto.' }
    $m = if ($c.PSObject.Properties['metros']) { $c.metros } else { $null }
    if ($null -ne $m -and [double] $m -gt 0) {
        return ('&Eacute; preciso passar cabo de rede de aprox. {0:0.#} m at&eacute; o ponto.' -f [double] $m)
    }
    return '&Eacute; preciso passar cabo de rede (metragem n&atilde;o informada).'
}

function Get-ClassificacaoLocalTexto {
    param([string] $VeredictoFinal)
    switch ($VeredictoFinal) {
        'viavel'              { 'Adequado para a Junta Eleitoral Especial' }
        'ressalva'            { 'Adequado com ressalvas' }
        'viavel_com_ressalva' { 'Adequado com ressalvas' }
        'inviavel'            { 'Inadequado no momento do diagn' + [char]0x00F3 + 'stico' }
        default               { [string] $VeredictoFinal }
    }
}

# Observacoes finais (prosa gerada pelo veredito), como no painel da SEMAP.
function Get-ObservacoesFinaisDiag {
    param($R)
    $rec = if ($R.PSObject.Properties['conexao_recomendada']) { $R.conexao_recomendada } else { $null }
    $meioTxt = if ($rec -and $rec.rotulo) { [string] $rec.rotulo } else { 'nenhum meio' }
    switch ([string] $R.classificacao.final) {
        'viavel' {
            "O local apresenta meio de conex$([char]0x00E3)o ($meioTxt) que atende aos requisitos m$([char]0x00ED)nimos de " +
            "conectividade para a instala$([char]0x00E7)$([char]0x00E3)o da Junta Eleitoral Especial. Recomenda-se confirmar as " +
            "condi$([char]0x00E7)$([char]0x00F5)es (energia, ponto de rede e VPN) no dia da montagem."
        }
        'inviavel' {
            $porVpn = if ($rec -and $rec.provisoria) { ", pois nenhum meio p$([char]0x00F4)de ser validado pela VPN da Justi$([char]0x00E7)a Eleitoral" } else { '' }
            "No momento do diagn$([char]0x00F3)stico, o local n$([char]0x00E3)o apresenta meio de conex$([char]0x00E3)o que atenda aos " +
            "requisitos m$([char]0x00ED)nimos para a Junta Eleitoral Especial$porVpn. $([char]0x00C9) necess$([char]0x00E1)rio tratar as pend$([char]0x00EA)ncias " +
            "apontadas nos condicionantes ou avaliar um local alternativo."
        }
        default {
            "O local pode ser utilizado pela Junta Eleitoral Especial com ressalvas: o meio recomendado ($meioTxt) " +
            "atende parcialmente aos requisitos. As pend$([char]0x00EA)ncias apontadas nos condicionantes devem ser " +
            "tratadas antes da instala$([char]0x00E7)$([char]0x00E3)o."
        }
    }
}

# Condicionantes / pendencias (analogo a "Principais condicionantes" da SEMAP).
function Get-CondicionantesDiag {
    param($R)
    $itens = @()

    $vpnObj = if ($R.PSObject.Properties['vpn']) { $R.vpn } else { $null }
    if ($vpnObj -and $vpnObj.impossivel) {
        $m = if ($vpnObj.motivo) { ' (' + [string] $vpnObj.motivo + ')' } else { '' }
        $itens += 'N' + [char]0x00E3 + 'o foi poss' + [char]0x00ED + 'vel conectar a VPN da Justi' + [char]0x00E7 + 'a Eleitoral' + $m
    }

    foreach ($a in @($R.avaliacao)) {
        if (@('ressalva', 'inviavel', 'viavel_com_ressalva') -contains [string] $a.classe_final) {
            $itens += ('{0}: {1} ({2})' -f $a.rotulo, (Format-ValorMetrica $a.valor $a.unidade), (Get-RotuloVeredito $a.classe_final))
        }
    }

    $rl = if ($R.PSObject.Properties['rede_local']) { $R.rede_local } else { $null }
    if ($rl -and $rl.PSObject.Properties['speedtest_diagnostico'] -and $rl.speedtest_diagnostico -and
        (@('handshake', 'bloqueio') -contains [string] $rl.speedtest_falha_tipo)) {
        $itens += [string] $rl.speedtest_diagnostico
    }

    foreach ($m in @($R.medicoes)) {
        if ($m -and $m.nao_aplicavel) {
            $mot = if ($m.motivo_nao_aplicavel) { ': ' + [string] $m.motivo_nao_aplicavel } else { '' }
            $itens += ('{0} n{1}o se aplica{2}' -f $m.rotulo, [char]0x00E3, $mot)
        }
    }
    @($itens)
}

# Item 1: barras comparando os meios testados (LAN x Wi-Fi x Celular) por
# metrica -- usado tanto no Painel de Medicoes quanto no de Viabilidade
# (mesmos campos, ja no JSON de cada medicao). $Meds: so' os "aplicaveis".
function Get-GraficoComparacaoMeiosHtml {
    param($Meds)
    $aplic = @($Meds | Where-Object { $_ -and -not $_.nao_aplicavel })
    if ($aplic.Count -lt 2) { return '' }   # com 1 meio so, comparar nao ajuda
    $grupos = @(
        @{ Titulo = 'Download s/ VPN (Mbps)'; Unidade = 'Mbps'; Campo = 'rede_local_download' }
        @{ Titulo = 'Upload s/ VPN (Mbps)';   Unidade = 'Mbps'; Campo = 'rede_local_upload_mbps' }
        @{ Titulo = 'Download c/ VPN (Mbps)'; Unidade = 'Mbps'; Campo = 'vpn_download_mbps' }
        @{ Titulo = 'Lat' + [char]0x00EA + 'ncia c/ VPN (ms)'; Unidade = 'ms'; Campo = 'latencia_ms' }
    )
    $blocos = foreach ($g in $grupos) {
        $barras = @($aplic | ForEach-Object {
            [pscustomobject]@{ Rotulo = [string] $_.rotulo; Valor = (Get-Prop $_ $g.Campo); Cor = '#123FA8' }
        })
        if (-not @($barras | Where-Object { $null -ne $_.Valor }).Count) { continue }
        Get-GraficoBarrasHtml -Barras $barras -Titulo $g.Titulo -Unidade $g.Unidade -Largura 340 -AlturaBarra 15 -EspacoBarra 7
    }
    $blocos = @($blocos | Where-Object { $_ })
    if (-not $blocos.Count) { return '' }
    # faixa de largura total, centralizada (sai da coluna estreita do painel)
    '<div class="grafcomp"><div class="ptit">Compara' + [char]0x00E7 + [char]0x00E3 + 'o entre os meios</div>' +
    '<div class="grafcompwrap">' + ($blocos -join "`n") + '</div></div>'
}

# Secao 3 - Painel de Medicoes (modo 'medicao' / 'referencia': sem juizo de viabilidade).
function Get-PainelMedicoesHtml {
    param($R)
    $loc = $R.local
    $rec = if ($R.PSObject.Properties['conexao_recomendada']) { $R.conexao_recomendada } else { $null }
    $meds = @(@(if ($R.PSObject.Properties['medicoes']) { $R.medicoes }) | Where-Object { $_ })
    $quando = try { [datetime] $R.coletado_em } catch { Get-Date }
    $tipoLocal = if ($loc.tipo -eq 'principal') { 'Local principal' } else { 'Local de conting' + [char]0x00EA + 'ncia' }

    $idRows = @(
        '<tr><td class="k">Data do diagn&oacute;stico</td><td>{0}</td></tr>' -f $quando.ToString('dd/MM/yyyy HH:mm')
        '<tr><td class="k">Zona Eleitoral</td><td>ZE {0}</td></tr>' -f $loc.zona_eleitoral
        '<tr><td class="k">Munic&iacute;pio</td><td>{0} (sede: {1})</td></tr>' -f (ConvertTo-HtmlSafe $loc.municipio_termo), (ConvertTo-HtmlSafe $loc.municipio_sede)
        '<tr><td class="k">Local</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.nome)
        '<tr><td class="k">Tipo</td><td>{0}</td></tr>' -f $tipoLocal
        '<tr><td class="k">Endere&ccedil;o</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.endereco)
        '<tr><td class="k">Internet do local</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.tipo_internet)
        '<tr><td class="k">T&eacute;cnico</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe ([string] $R.tecnico.nome))
    )

    $aplic = @($meds | Where-Object { -not $_.nao_aplicavel })
    $na    = @($meds | Where-Object { $_.nao_aplicavel })

    $sugTxt = if ($rec -and $rec.meio -ne 'nenhuma' -and $rec.rotulo) {
        $dl = if ($null -ne (Get-Prop $rec 'download_mbps')) { (' &mdash; maior download {0:N1} Mbps{1}' -f [double] $rec.download_mbps, $(if ($rec.base -eq 'vpn') { ' pela VPN' } else { ' na rede local' })) } else { '' }
        (ConvertTo-HtmlSafe ([string] $rec.rotulo)) + $dl
    } else { '&mdash;' }

    $resumoRows = @(
        '<tr><td class="k">Meios medidos</td><td>{0}</td></tr>' -f $aplic.Count
        '<tr><td class="k">Meios n&atilde;o aplic&aacute;veis</td><td>{0}</td></tr>' -f $na.Count
        '<tr><td class="k">Sugest&atilde;o de conex&atilde;o</td><td>{0}</td></tr>' -f $sugTxt
    )
    $caboTxt = Get-CaboLanTextoRelatorio $R
    if ($caboTxt) { $resumoRows += '<tr><td class="k">Cabo de rede (LAN)</td><td>{0}</td></tr>' -f $caboTxt }

    $rank = @{ 'lan' = 0; 'wifi' = 1; 'celular' = 2 }
    $medRows = foreach ($m in ($meds | Sort-Object { $x = $rank[[string] $_.meio]; if ($null -eq $x) { 9 } else { $x } })) {
        if ($m.nao_aplicavel) {
            $mot = if ($m.motivo_nao_aplicavel) { ' &mdash; ' + (ConvertTo-HtmlSafe ([string] $m.motivo_nao_aplicavel)) } else { '' }
            "      <tr><td>$(ConvertTo-HtmlSafe ([string] $m.rotulo))</td><td colspan=""5"" class=""small"">n&atilde;o se aplica$mot</td></tr>"
            continue
        }
        $vpnTxt = if ($m.vpn_conectou) { 'Sim' } else { 'N&atilde;o' }
        $rl  = if ($null -ne $m.rede_local_download) { '{0:N1} Mbps' -f [double] $m.rede_local_download } elseif ($m.rede_local_ok) { 'ok' } else { 'n&atilde;o rodou' }
        $ul  = if ($null -ne $m.rede_local_upload_mbps) { '{0:N1} Mbps' -f [double] $m.rede_local_upload_mbps } elseif ($m.rede_local_ok) { 'ok' } else { 'n&atilde;o rodou' }
        $lt  = if ($null -ne $m.latencia_ms) { '{0} ms' -f $m.latencia_ms } else { '&mdash;' }
        $pd  = if ($null -ne $m.perda_percentual) { '{0} %' -f $m.perda_percentual } else { '&mdash;' }
        "      <tr><td>$(ConvertTo-HtmlSafe ([string] $m.rotulo))</td><td class=""mono"">$vpnTxt</td><td class=""mono"">$rl</td><td class=""mono"">$ul</td><td class=""mono"">$lt</td><td class=""mono"">$pd</td></tr>"
    }

    # observacoes: a anotacao livre do tecnico (se houver) + pendencias de fato
    # (VPN impossivel, meios NA)
    $obs = @()
    $obsTec = if ($R.PSObject.Properties['observacoes_tecnico']) { [string] $R.observacoes_tecnico } else { '' }
    if ($obsTec.Trim()) { $obs += 'T' + [char]0x00E9 + 'cnico: ' + $obsTec.Trim() }
    $vpnObj = if ($R.PSObject.Properties['vpn']) { $R.vpn } else { $null }
    if ($vpnObj -and $vpnObj.impossivel) {
        $mm = if ($vpnObj.motivo) { ' (' + [string] $vpnObj.motivo + ')' } else { '' }
        $obs += 'N' + [char]0x00E3 + 'o foi poss' + [char]0x00ED + 'vel conectar a VPN da Justi' + [char]0x00E7 + 'a Eleitoral' + $mm
    }
    foreach ($m in $na) {
        $mot = if ($m.motivo_nao_aplicavel) { ': ' + [string] $m.motivo_nao_aplicavel } else { '' }
        $obs += ('{0} n{1}o se aplica{2}' -f $m.rotulo, [char]0x00E3, $mot)
    }
    $obsHtml = if ($obs.Count) { '<ul>' + ((@($obs) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe $_) + '</li>' }) -join '') + '</ul>' } else { 'Sem observa&ccedil;&otilde;es.' }
    $grafComparacao = Get-GraficoComparacaoMeiosHtml -Meds $meds

    @"
  <div class="bar">Painel de Medi&ccedil;&otilde;es</div>
  <div class="pnl">
    <div class="pcols">
      <div>
        <div class="ptit">Identifica&ccedil;&atilde;o</div>
        <table class="kv"><tbody>
$($idRows -join "`n")
        </tbody></table>
      </div>
      <div>
        <div class="ptit">Resumo</div>
        <table class="kv"><tbody>
$($resumoRows -join "`n")
        </tbody></table>
        <div class="ptit" style="margin-top:12px">Medi&ccedil;&otilde;es por meio</div>
        <table>
          <thead><tr><th>Meio</th><th>VPN</th><th>Download s/ VPN</th><th>Upload s/ VPN</th><th>Lat&ecirc;ncia VPN</th><th>Perda VPN</th></tr></thead>
          <tbody>
$($medRows -join "`n")
          </tbody>
        </table>
      </div>
    </div>
    $grafComparacao
    <div class="ptit" style="margin-top:4px">Observa&ccedil;&otilde;es</div>
    $obsHtml
  </div>
"@
}

# Secao 3 - Painel de Viabilidade de Conectividade.
function Get-PainelHtml {
    param($R)
    $loc = $R.local
    $cl  = $R.classificacao
    $rec = if ($R.PSObject.Properties['conexao_recomendada']) { $R.conexao_recomendada } else { $null }
    $meds = @(@(if ($R.PSObject.Properties['medicoes']) { $R.medicoes }) | Where-Object { $_ })
    $quando = try { [datetime] $R.coletado_em } catch { Get-Date }
    $tipoLocal = if ($loc.tipo -eq 'principal') { 'Local principal' } else { 'Local de conting' + [char]0x00EA + 'ncia' }

    $idRows = @(
        '<tr><td class="k">Data do diagn&oacute;stico</td><td>{0}</td></tr>' -f $quando.ToString('dd/MM/yyyy HH:mm')
        '<tr><td class="k">Zona Eleitoral</td><td>ZE {0}</td></tr>' -f $loc.zona_eleitoral
        '<tr><td class="k">Munic&iacute;pio</td><td>{0} (sede: {1})</td></tr>' -f (ConvertTo-HtmlSafe $loc.municipio_termo), (ConvertTo-HtmlSafe $loc.municipio_sede)
        '<tr><td class="k">Local</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.nome)
        '<tr><td class="k">Tipo</td><td>{0}</td></tr>' -f $tipoLocal
        '<tr><td class="k">Endere&ccedil;o</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.endereco)
        '<tr><td class="k">Internet do local</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $loc.tipo_internet)
        '<tr><td class="k">T&eacute;cnico</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe ([string] $R.tecnico.nome))
    )

    $aplic = @($meds | Where-Object { -not $_.nao_aplicavel })
    $na    = @($meds | Where-Object { $_.nao_aplicavel })
    $nViavel   = @($aplic | Where-Object { [string] $_.veredito -eq 'viavel' }).Count
    $nRessalva = @($aplic | Where-Object { [string] $_.veredito -match 'ressalva' }).Count
    $nInviavel = @($aplic | Where-Object { [string] $_.veredito -eq 'inviavel' }).Count
    $nVpn      = @($aplic | Where-Object { $_.vpn_conectou }).Count
    $kpis = @(
        @{ n = $aplic.Count; l = 'Meios testados' }
        @{ n = $nViavel;     l = 'Vi&aacute;veis' }
        @{ n = $nRessalva;   l = 'Com ressalva' }
        @{ n = $nInviavel;   l = 'Invi&aacute;veis' }
        @{ n = $na.Count;    l = 'N&atilde;o aplic&aacute;veis' }
        @{ n = ('{0}/{1}' -f $nVpn, $aplic.Count); l = 'Conectou &agrave; VPN' }
    )
    $kpiHtml = ($kpis | ForEach-Object { '<div class="kpi"><div class="n">{0}</div><div class="l">{1}</div></div>' -f $_.n, $_.l }) -join ''

    $rank = @{ 'lan' = 0; 'wifi' = 1; 'celular' = 2 }
    $sitRows = foreach ($m in ($meds | Sort-Object { $r = $rank[[string] $_.meio]; if ($null -eq $r) { 9 } else { $r } })) {
        $isNa = [bool] $m.nao_aplicavel
        $rlTxt = if ($isNa) { '&mdash;' }
                 elseif ($m.rede_local_ok) { if ($null -ne $m.rede_local_download) { '{0:N1} Mbps' -f [double] $m.rede_local_download } else { 'ok' } }
                 else { 'n&atilde;o rodou' }
        $vpnTxt = if ($isNa) { '&mdash;' } elseif ($m.vpn_conectou) { 'conectou' } else { 'n&atilde;o' }
        $dlTxt  = if (-not $isNa -and $null -ne $m.vpn_download_mbps) { '{0:N1} Mbps' -f [double] $m.vpn_download_mbps } else { '&mdash;' }
        $ltTxt  = if (-not $isNa -and $null -ne $m.latencia_ms) { '{0} ms' -f $m.latencia_ms } else { '&mdash;' }
        $verTxt = if ($isNa) {
            'n&atilde;o aplic&aacute;vel' + $(if ($m.motivo_nao_aplicavel) { ' &mdash; ' + (ConvertTo-HtmlSafe ([string] $m.motivo_nao_aplicavel)) } else { '' })
        } else {
            '<span style="color:{0};font-weight:700">{1}</span>' -f (Get-CorVeredito $m.veredito), (ConvertTo-HtmlSafe (Get-RotuloVeredito $m.veredito))
        }
        $cls = @()
        if ($rec -and -not $rec.provisoria -and ([string] $m.rotulo -eq [string] $rec.rotulo) -and -not $isNa) { $cls += 'rec' }
        if ([string] $m.veredito -eq 'inviavel' -and -not $isNa) { $cls += 'bad' }
        $c = if ($cls.Count) { ' class="' + ($cls -join ' ') + '"' } else { '' }
        "      <tr$c><td>$(ConvertTo-HtmlSafe ([string] $m.rotulo))</td><td class=""mono"">$rlTxt</td><td>$vpnTxt</td><td class=""mono"">$dlTxt</td><td class=""mono"">$ltTxt</td><td>$verTxt</td></tr>"
    }

    $corF = Get-CorVeredito $cl.final
    $rotF = ConvertTo-HtmlSafe (Get-RotuloVeredito $cl.final)
    $recTxt = if ($rec -and $rec.rotulo) {
        (ConvertTo-HtmlSafe ([string] $rec.rotulo)) +
        $(if ($rec.provisoria) { ' <span class="small">(recomenda&ccedil;&atilde;o provis&oacute;ria &mdash; nenhum meio fechou a VPN da Justi&ccedil;a Eleitoral)</span>' } else { '' })
    } else { 'nenhuma' }
    $motRec = if ($rec -and $rec.motivo) { ConvertTo-HtmlSafe ([string] $rec.motivo) } else { '&mdash;' }
    $aju = if ($cl.ajustada -and $cl.justificativa) { ConvertTo-HtmlSafe ([string] $cl.justificativa) } else { '' }
    $cond = Get-CondicionantesDiag $R
    $condHtml = if (@($cond).Count) {
        '<ul>' + ((@($cond) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe $_) + '</li>' }) -join '') + '</ul>'
    } else { 'Nenhuma pend&ecirc;ncia registrada.' }
    $obs = ConvertTo-HtmlSafe (Get-ObservacoesFinaisDiag $R)

    $concRows = @(
        '<tr><td class="k">Recomenda&ccedil;&atilde;o final</td><td><b style="color:{0};font-size:13px">{1}</b></td></tr>' -f $corF, $rotF
        '<tr><td class="k">Classifica&ccedil;&atilde;o do local</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe (Get-ClassificacaoLocalTexto $cl.final))
        '<tr><td class="k">Conex&atilde;o recomendada</td><td>{0}</td></tr>' -f $recTxt
        '<tr><td class="k">Motivo da recomenda&ccedil;&atilde;o</td><td>{0}</td></tr>' -f $motRec
    )
    $caboTxt = Get-CaboLanTextoRelatorio $R
    if ($caboTxt) { $concRows += '<tr><td class="k">Cabo de rede (LAN)</td><td>{0}</td></tr>' -f $caboTxt }
    if ($aju) { $concRows += '<tr><td class="k">Ajuste da recomenda&ccedil;&atilde;o</td><td>{0}</td></tr>' -f $aju }
    $obsTec = if ($R.PSObject.Properties['observacoes_tecnico']) { [string] $R.observacoes_tecnico } else { '' }
    if ($obsTec.Trim()) {
        $concRows += '<tr><td class="k">Observa&ccedil;&otilde;es do t&eacute;cnico</td><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe ($obsTec.Trim()))
    }
    $concRows += '<tr><td class="k">Condicionantes / pend&ecirc;ncias</td><td>{0}</td></tr>' -f $condHtml
    $concRows += '<tr><td class="k">Observa&ccedil;&otilde;es finais</td><td>{0}</td></tr>' -f $obs
    $grafComparacao = Get-GraficoComparacaoMeiosHtml -Meds $meds

    @"
  <div class="bar">Painel de Viabilidade de Conectividade</div>
  <div class="pnl">
    <div class="pcols">
      <div>
        <div class="ptit">Identifica&ccedil;&atilde;o</div>
        <table class="kv"><tbody>
$($idRows -join "`n")
        </tbody></table>
      </div>
      <div>
        <div class="ptit">Indicadores</div>
        <div class="kpis">$kpiHtml</div>
        <div class="ptit" style="margin-top:12px">Situa&ccedil;&atilde;o por meio</div>
        <table>
          <thead><tr><th>Meio</th><th>Download</th><th>VPN</th><th>Download com VPN</th><th>Lat&ecirc;ncia com VPN</th><th>Veredito</th></tr></thead>
          <tbody>
$($sitRows -join "`n")
          </tbody>
        </table>
      </div>
    </div>
    $grafComparacao
    <div class="ptit" style="margin-top:4px">Conclus&atilde;o do diagn&oacute;stico</div>
    <table class="kv"><tbody>
$($concRows -join "`n")
    </tbody></table>
  </div>
"@
}

# Monta o HTML do relatorio a partir do objeto do New-ResultadoJson.
function New-RelatorioHtml {
    param([Parameter(Mandatory)] $Resultado)

    $r   = $Resultado
    $loc = $r.local
    $amb = $r.ambiente
    $modoAv = if ($r.PSObject.Properties['modo_avaliacao'] -and $r.modo_avaliacao) { [string] $r.modo_avaliacao } else { 'medicao' }

    $quando   = try { [datetime] $r.coletado_em } catch { Get-Date }
    $geradoEm = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')

    $brasao    = Get-BrasaoDataUri
    $imgBrasao = if ($brasao) { '<img class="brasao" src="{0}" alt="">' -f $brasao } else { '' }

    # -------- Secao 3: painel (Viabilidade no modo completo; Medicoes nos demais)
    $painel = if ($modoAv -eq 'completo') { Get-PainelHtml $r } else { Get-PainelMedicoesHtml $r }

    # -------- Secao 4: testes por meio (LAN / Wi-Fi do local / Celular)
    $meds = @(@(if ($r.PSObject.Properties['medicoes']) { $r.medicoes }) | Where-Object { $_ })
    $rec  = if ($r.PSObject.Properties['conexao_recomendada']) { $r.conexao_recomendada } else { $null }
    $rank = @{ 'lan' = 0; 'wifi' = 1; 'celular' = 2 }
    $secMeios = ''
    if ($meds.Count) {
        $blocos = foreach ($m in ($meds | Sort-Object { $x = $rank[[string] $_.meio]; if ($null -eq $x) { 9 } else { $x } })) {
            $ehRec = [bool] ($modoAv -eq 'completo' -and $rec -and ([string] $m.rotulo -eq [string] $rec.rotulo))
            Get-MeioBlocoHtml -R $r -M $m -Recomendado $ehRec -Modo $modoAv
        }
        $tituloSec = if ($modoAv -eq 'completo') { 'Testes de comunica&ccedil;&atilde;o por meio' } else { 'Medi&ccedil;&otilde;es por meio' }
        $secMeios = "  <div class=""bar"">$tituloSec</div>`n" + ($blocos -join "`n")
    }

    # -------- Secao 5: dados da vistoria do GEL (sem as fotos)
    $blocoGel = ''
    $vg = if ($r.PSObject.Properties['vistoria_gel']) { $r.vistoria_gel } else { $null }
    if ($vg) {
        $li = {
            param([string] $rotulo, $valor)
            $v = ("$valor").Trim()
            if (-not $v) { return $null }
            '<div><b>{0}:</b> {1}</div>' -f $rotulo, (ConvertTo-HtmlSafe $v)
        }
        $mkSecao = {
            param([string] $titulo, [string[]] $linhas)
            $ok = @($linhas | Where-Object { $_ })
            if (-not $ok.Count) { return '' }
            ('  <div class="subt">{0}</div>' -f $titulo) + "`n  <div class=""grid2"">`n    " + ($ok -join "`n    ") + "`n  </div>"
        }
        $secoes = @()
        $vgTL = if ($vg.PSObject.Properties['tipo_local']) { $vg.tipo_local } else { $null }
        $vgIN = if ($vg.PSObject.Properties['infraestrutura']) { $vg.infraestrutura } else { $null }
        $vgEL = if ($vg.PSObject.Properties['eletrica']) { $vg.eletrica } else { $null }

        $coord = @()
        $imgMapa = ''
        if ($null -ne $vg.latitude -and $null -ne $vg.longitude) {
            $latS  = ("$($vg.latitude)")  -replace ',', '.'
            $longS = ("$($vg.longitude)") -replace ',', '.'
            $precS = (("$($vg.precisao_m)") -replace ',', '.').Trim()
            $prec  = if ($precS -and $precS -ne '0') { (' &middot; precis&atilde;o ~{0} m' -f $precS) } else { '' }
            $coord += '<div style="grid-column:1/3"><b>Coordenadas:</b> {0}, {1}{2}</div>' -f $latS, $longS, $prec
            $lnk = if ($vg.mapa_link) { [string] $vg.mapa_link } else { 'https://www.google.com/maps?q={0},{1}' -f $latS, $longS }
            $coord += '<div style="grid-column:1/3"><b>Mapa:</b> <a href="{0}">{0}</a></div>' -f (ConvertTo-HtmlSafe $lnk)
            $chave = Get-ChaveMapsStatic
            if ($chave) {
                $du = Get-MapaEstaticoDataUri -Lat $vg.latitude -Long $vg.longitude -Chave $chave
                if ($du) { $imgMapa = '<div style="margin:6px 0 12px"><img src="{0}" alt="mapa" style="max-width:560px;border:1px solid #d6dae2;border-radius:4px"></div>' -f $du }
            }
        }
        $secoes += (& $mkSecao 'Coordenadas' $coord)
        $secoes += (& $mkSecao 'Tipo do local' @(
            (& $li 'Esfera administrativa' ($(if ($vgTL) { $vgTL.esfera_administrativa } else { '' })))
            (& $li 'Localiza&ccedil;&atilde;o' ($(if ($vgTL) { $vgTL.localizacao } else { '' })))
            (& $li 'Tipo de local' ($(if ($vgTL) { $vgTL.tipo } else { '' })))
        ))
        $secoes += (& $mkSecao 'Infraestrutura' @(
            (& $li 'Salas necess&aacute;rias' ($(if ($vgIN) { $vgIN.salas_necessarias } else { '' })))
            (& $li 'Abastecimento de &aacute;gua' ($(if ($vgIN) { $vgIN.agua } else { '' })))
            (& $li 'Climatiza&ccedil;&atilde;o / ventila&ccedil;&atilde;o' ($(if ($vgIN) { $vgIN.climatizacao } else { '' })))
            (& $li 'Ilumina&ccedil;&atilde;o' ($(if ($vgIN) { $vgIN.iluminacao } else { '' })))
            (& $li '&Aacute;gua pot&aacute;vel' ($(if ($vgIN) { $vgIN.agua_potavel } else { '' })))
            (& $li 'Pr&eacute;dio em reforma' ($(if ($vgIN) { $vgIN.predio_reforma } else { '' })))
        ))
        $secoes += (& $mkSecao 'Instala&ccedil;&otilde;es el&eacute;tricas' @(
            (& $li 'Quadro de energia' ($(if ($vgEL) { $vgEL.quadro_energia } else { '' })))
            (& $li 'Energia el&eacute;trica' ($(if ($vgEL) { $vgEL.energia_eletrica } else { $vg.energia_eletrica })))
            (& $li 'Tomadas funcionando' ($(if ($vgEL) { $vgEL.tomadas } else { $vg.eletrica_tomadas })))
            (& $li 'Tens&atilde;o da rede' ($(if ($vgEL) { $vgEL.tensao } else { $vg.eletrica_tensao })))
            (& $li 'Necessita extens&atilde;o el&eacute;trica' ($(if ($vgEL) { $vgEL.extensao } else { $vg.eletrica_extensao })))
        ))
        $secoes += (& $mkSecao 'Suporte ao link local' @(
            (& $li 'Empresa / t&eacute;cnico' $vg.suporte_nome)
            (& $li 'Telefone' $vg.suporte_telefone)
        ))
        $secoes = @($secoes | Where-Object { $_ })
        if ($secoes.Count) {
            $blocoGel = "  <div class=""bar"">Dados da vistoria (importado do GEL)</div>`n  <div class=""gel"">`n$imgMapa`n" + ($secoes -join "`n") + "`n  </div>`n"
        }
    }

    # -------- Secao 6: registro fotografico (fotos anexadas ao Local, 3 por linha)
    $secFotos = ''
    $lid = if ($r.PSObject.Properties['local'] -and $r.local) { [string] $r.local.id } else { '' }
    if ($lid) {
        $fotos = @(Get-FotosGel -LocalId $lid)
        if ($fotos.Count) {
            $cells = @(); $acum = 0; $usadas = 0
            foreach ($f in $fotos) {
                $du = Get-FotoGelDataUri -Caminho $f
                if (-not $du) { continue }
                if ($acum + $du.Length -gt 14MB) { break }
                $acum += $du.Length; $usadas++
                $cells += ('<figure><img src="{0}" alt=""><figcaption>Foto {1}</figcaption></figure>' -f $du, $usadas)
            }
            if ($cells.Count) {
                $nota = if ($usadas -lt $fotos.Count) { ' &mdash; as demais foram omitidas por limite de tamanho' } else { '' }
                $secFotos = "  <div class=""bar"">Registro fotogr&aacute;fico ($usadas de $($fotos.Count) fotos)$nota</div>`n" +
                            "  <div class=""fotos"">`n    " + ($cells -join "`n    ") + "`n  </div>`n"
            }
        }
    }

    $rodapeCtx = @()
    if ($amb -and $amb.host)    { $rodapeCtx += 'Computador: ' + (ConvertTo-HtmlSafe ([string] $amb.host)) }
    if ($amb -and $amb.usuario) { $rodapeCtx += 'Usu&aacute;rio: ' + (ConvertTo-HtmlSafe ([string] $amb.usuario)) }
    $rodapeCtxTxt = if ($rodapeCtx.Count) { ' &middot; ' + ($rodapeCtx -join ' &middot; ') } else { '' }

    @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Relat&oacute;rio de Diagn&oacute;stico de Conectividade</title>
<style>
  @page { size: A4 landscape; margin: 12mm 14mm 14mm; }
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', Arial, sans-serif; color: #1f2430; margin: 0; font-size: 11px; }
  a { color: #1a3a8f; word-break: break-all; }

  .cab { display: flex; justify-content: space-between; align-items: flex-start; }
  .cab .id { display: flex; align-items: flex-start; }
  .cab .brasao { height: 66px; margin-right: 14px; }
  .cab h1 { font-size: 15px; margin: 0 0 2px; }
  .cab .org { color: #444; font-size: 10.5px; line-height: 1.5; }
  .cab .data { text-align: right; color: #444; font-size: 10.5px; white-space: nowrap; }
  hr { border: none; border-top: 3px solid #1a3a8f; margin: 9px 0 14px; }

  h1.tit { font-size: 17px; margin: 0 0 2px; }
  p.sub  { font-size: 12px; color: #333; margin: 0 0 12px; }

  .bar { background: #1F4E79; color: #fff; font-weight: 700; text-transform: uppercase;
         letter-spacing: .06em; font-size: 11px; padding: 6px 12px; margin: 16px 0 8px;
         page-break-after: avoid; break-after: avoid; }
  .ptit, .subt { font-weight: 700; color: #1F4E79; font-size: 11px; text-transform: uppercase;
                 letter-spacing: .04em; margin: 8px 0 5px;
                 page-break-after: avoid; break-after: avoid; }
  .subt { color: #2E5A8A; }

  table { border-collapse: collapse; width: 100%; margin: 4px 0 12px;
          page-break-inside: avoid; break-inside: avoid; }
  th, td { border: 1px solid #BFC9DA; padding: 5px 8px; text-align: left; vertical-align: top; }
  th { background: #D9E2F3; font-size: 10px; color: #22324a; text-transform: uppercase; letter-spacing: .03em; }
  tbody tr:nth-child(even) td { background: #F4F7FB; }
  table.kv td.k { background: #E7EDF6; font-weight: 600; width: 190px; color: #33465f; }
  table.kv tbody tr:nth-child(even) td { background: #fff; }
  table.kv td.k { background: #E7EDF6 !important; }
  .mono { font-family: 'Consolas', 'Courier New', monospace; }
  .small { font-size: 10px; color: #333; }
  tr.rec td { background: #EAF3FF !important; }
  tr.bad td { background: #FCEDEC !important; }

  .pnl { border: 1px solid #BFC9DA; border-top: none; padding: 10px 12px 4px; }
  .pcols { display: grid; grid-template-columns: 40% 60%; gap: 0 20px; }
  .kpis { display: grid; grid-template-columns: repeat(6, 1fr); gap: 5px; }
  .kpi { min-width: 0; border: 1px solid #BFC9DA; text-align: center; padding: 6px 3px; background: #F4F7FB; }
  .kpi .n { font-size: 17px; font-weight: 700; color: #1F4E79; }
  .kpi .l { font-size: 8px; color: #555; text-transform: uppercase; letter-spacing: .02em; margin-top: 2px; line-height: 1.25; word-wrap: break-word; }
  .pnl ul { margin: 2px 0 2px 16px; padding: 0; }
  .pnl li { margin: 1px 0; }

  .meio { border: 1px solid #BFC9DA; margin: 0 0 12px; page-break-inside: auto; break-inside: auto; }
  .meio.na { padding: 8px 12px; background: #F4F7FB; color: #555;
             page-break-inside: avoid; break-inside: avoid; }
  .meiotit { background: #E7EDF6; padding: 6px 12px; font-weight: 700; font-size: 12px;
             display: flex; align-items: baseline; flex-wrap: wrap; gap: 3px 10px;
             page-break-after: avoid; break-after: avoid; }
  .meiotit-props { font-weight: 400; font-size: 10px; color: #333; }
  .endr { background: #F4F7FB; border-bottom: 1px solid #DFE6F0; padding: 5px 12px;
          font-size: 10px; color: #333; display: flex; flex-wrap: wrap; gap: 2px 18px;
          page-break-after: avoid; break-after: avoid; }
  .endr b { color: #1F3A63; }
  .rlmeta { font-size: 10px; color: #333; margin: 0 0 5px; }
  .rlmeta b { color: #1F3A63; }
  .badge { border: 1px solid; border-radius: 3px; padding: 1px 7px; font-size: 10px; font-weight: 700; }
  .tag { background: #1F4E79; color: #fff; border-radius: 3px; padding: 1px 7px; font-size: 9px;
         font-weight: 700; text-transform: uppercase; letter-spacing: .04em; }
  .meio .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 0 18px; padding: 8px 12px 2px; }
  .warn { background: #FFF8E1; border-left: 3px solid #E0A800; padding: 6px 10px; margin: 4px 0 8px; font-size: 10.5px; }

  .graflinha { display: flex; flex-wrap: wrap; gap: 10px 18px; margin: 4px 0; }
  .grafico { page-break-inside: avoid; }
  .graftit { font-size: 9.5px; font-weight: 700; color: #5C6472; text-transform: uppercase;
             letter-spacing: .03em; margin: 0 0 3px; }
  .graflegenda { font-size: 9px; color: #5C6472; margin-top: 2px; }
  .graflaudo { font-size: 9.5px; color: #333; margin-top: 3px; max-width: 400px; line-height: 1.35; }
  .grafzona { margin: 10px 0 2px; padding: 8px 12px; background: #FAFBFD;
              border: 1px solid #E7EDF6; border-radius: 4px;
              page-break-inside: auto; break-inside: auto; }
  .grafzona > .graftit { margin-bottom: 6px; page-break-after: avoid; break-after: avoid; }
  .grafpar { display: flex; flex-wrap: wrap; gap: 12px 26px; justify-content: center;
             page-break-inside: avoid; break-inside: avoid; }
  /* "Comparacao entre os meios": faixa de largura total, centralizada */
  .grafcomp { margin: 14px 0 6px; page-break-inside: auto; break-inside: auto; }
  .grafcompwrap { display: flex; flex-wrap: wrap; gap: 14px 36px; justify-content: space-around; }

  .gel { border: 1px solid #BFC9DA; border-top: none; padding: 10px 12px 4px; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 2px 24px; margin: 2px 0 10px; }
  .grid2 div { font-size: 11px; }
  .grid2 b { color: #555; font-weight: 600; }

  .fotos { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
  .fotos figure { margin: 0; page-break-inside: avoid; }
  .fotos img { width: 100%; border: 1px solid #d6dae2; border-radius: 4px; display: block; }
  .fotos figcaption { font-size: 9px; color: #666; margin-top: 2px; }

  .rodape { margin-top: 18px; border-top: 1px solid #d6dae2; padding-top: 7px; color: #777; font-size: 9.5px; }
</style>
</head>
<body>
  <div class="cab">
    <div class="id">
      $imgBrasao
      <div>
        <h1>Justi&ccedil;a Eleitoral</h1>
        <div class="org">Tribunal Regional Eleitoral do Maranh&atilde;o<br>SEASU-COINF-STIC<br>
          <b>DICON</b> &mdash; Diagn&oacute;stico de Conectividade &middot; Juntas Especiais 2026</div>
      </div>
    </div>
    <div class="data">$($quando.ToString('dd/MM/yyyy'))<br>$($quando.ToString('HH:mm:ss'))</div>
  </div>
  <hr>

  <h1 class="tit">Relat&oacute;rio de Diagn&oacute;stico de Conectividade</h1>
  <p class="sub">ZE $($loc.zona_eleitoral) &mdash; $(ConvertTo-HtmlSafe $loc.municipio_termo) (sede: $(ConvertTo-HtmlSafe $loc.municipio_sede))</p>

$painel
$secMeios
$blocoGel
$secFotos
  <div class="rodape">Gerado pela ferramenta DICON &mdash; TRE-MA em $geradoEm. Vers&atilde;o $($r.versao_ferramenta).$rodapeCtxTxt</div>
</body>
</html>
"@
}

# Gera o PDF (ou HTML, se nao houver navegador). Devolve o caminho do arquivo.
function Export-RelatorioPdf {
    param(
        [Parameter(Mandatory)] $Resultado,
        [string] $Caminho
    )

    if ([string]::IsNullOrWhiteSpace($Caminho)) {
        $dir = Join-Path $Global:RaizApp 'relatorios'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $id = ([string] $Resultado.local.id) -replace '[^\w\-]', '_'
        if (-not $id) { $id = 'local' }
        $Caminho = Join-Path $dir ('{0}_{1}.pdf' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $id)
    }

    $html     = New-RelatorioHtml -Resultado $Resultado
    $htmlPath = [IO.Path]::ChangeExtension($Caminho, '.html')
    [IO.File]::WriteAllText($htmlPath, $html, [Text.UTF8Encoding]::new($false))

    $navegador = Get-CaminhoNavegadorPdf
    if (-not $navegador) {
        Write-Log "Navegador para PDF nao encontrado; relatorio salvo em HTML: $htmlPath" -Nivel Aviso
        return $htmlPath
    }

    $uri     = ([Uri] $htmlPath).AbsoluteUri
    $userDir = Join-Path ([IO.Path]::GetTempPath()) 'dicon-pdf-profile'
    $argv = @(
        '--headless=new'
        '--disable-gpu'
        '--no-first-run'
        '--no-pdf-header-footer'
        '--disable-logging'
        '--log-level=3'
        '--disable-breakpad'
        ('--user-data-dir="{0}"' -f $userDir)
        ('--print-to-pdf="{0}"' -f $Caminho)
        ('"{0}"' -f $uri)
    )
    Invoke-ProcessoComSaida -Caminho $navegador -Argumentos $argv -TimeoutS 45 | Out-Null

    if (Test-Path $Caminho) {
        Remove-Item $htmlPath -Force -ErrorAction SilentlyContinue
        Write-Log "Relatorio PDF gerado: $Caminho" -Nivel Ok
        return $Caminho
    }

    Write-Log "Falha ao converter para PDF; relatorio salvo em HTML: $htmlPath" -Nivel Aviso
    return $htmlPath
}
