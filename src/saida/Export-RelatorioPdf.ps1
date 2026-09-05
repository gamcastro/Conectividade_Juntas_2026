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
        $meioY  = [math]::Round($y + $AlturaBarra * 0.72, 1)
        if ($null -eq $b.Valor -or "$($b.Valor)" -eq '') {
            @"
<text x="0" y="$meioY" font-size="9" fill="#8891A0">$rotulo</text>
<text x="$margemRotulo" y="$meioY" font-size="9" fill="#8891A0" font-style="italic">sem medida</text>
"@
        } else {
            $cor = if ($b.PSObject.Properties['Cor'] -and $b.Cor) { [string] $b.Cor } else { '#123FA8' }
            $w = [math]::Round(($areaBarra * ([math]::Min(1.0, [double] $b.Valor / $max))), 1)
            if ($w -lt 1) { $w = 1 }
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
        [int] $Largura = 300,
        [int] $Altura = 110
    )
    $comPonto = @($Series | Where-Object { $_ -and $_.Pontos } | ForEach-Object { $_.Pontos } | Where-Object { $_ -and $null -ne $_.V -and $null -ne $_.T })
    if (-not $comPonto.Count) { return '' }

    $margemEsq = 34; $margemDir = 8; $margemTopo = 10; $margemBaixo = 20
    $areaW = [math]::Max(20, $Largura - $margemEsq - $margemDir)
    $areaH = [math]::Max(20, $Altura - $margemTopo - $margemBaixo)
    $tMin = ($comPonto | ForEach-Object { [double] $_.T } | Measure-Object -Minimum).Minimum
    $tMax = ($comPonto | ForEach-Object { [double] $_.T } | Measure-Object -Maximum).Maximum
    if ($tMax -le $tMin) { $tMax = $tMin + 1 }
    $vMax = ($comPonto | ForEach-Object { [double] $_.V } | Measure-Object -Maximum).Maximum
    if ($vMax -le 0) { $vMax = 1 }
    $escX = { param($t) [math]::Round($margemEsq + ((([double] $t - $tMin) / ($tMax - $tMin)) * $areaW), 1) }
    $escY = { param($v) [math]::Round($margemTopo + $areaH - (([double] $v / $vMax) * $areaH), 1) }

    $linhas = foreach ($s in @($Series | Where-Object { $_ -and $_.Pontos })) {
        $cor = if ($s.Cor) { [string] $s.Cor } else { '#123FA8' }
        $trechoAtual = New-Object System.Collections.Generic.List[string]
        $trechos = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($s.Pontos)) {
            if (-not $p -or $null -eq $p.V -or $null -eq $p.T) {
                if ($trechoAtual.Count -gt 1) { $trechos.Add(($trechoAtual -join ' ')) }
                $trechoAtual = New-Object System.Collections.Generic.List[string]
                continue
            }
            $trechoAtual.Add(('{0},{1}' -f (& $escX $p.T), (& $escY $p.V)))
        }
        if ($trechoAtual.Count -gt 1) { $trechos.Add(($trechoAtual -join ' ')) }
        foreach ($pts in $trechos) { '<polyline points="' + $pts + '" fill="none" stroke="' + $cor + '" stroke-width="1.6"/>' }
    }

    # eixo Y: so' o valor maximo, pra nao poluir (grafico pequeno)
    $eixoYHtml = "<text x=""2"" y=""$($margemTopo + 4)"" font-size=""8"" fill=""#8891A0"">$('{0:N0}' -f $vMax) $(ConvertTo-HtmlSafe $EixoY)</text>" +
                 "<text x=""2"" y=""$($margemTopo + $areaH)"" font-size=""8"" fill=""#8891A0"">0</text>"
    $legenda = ($Series | Where-Object { $_ -and $_.Nome } | ForEach-Object {
        '<span style="color:' + [string] $_.Cor + '">&#9632;</span> ' + (ConvertTo-HtmlSafe ([string] $_.Nome))
    }) -join '&nbsp;&nbsp;'
    $tit = if ($Titulo) { '<div class="graftit">' + (ConvertTo-HtmlSafe $Titulo) + '</div>' } else { '' }
    $legHtml = if ($legenda) { '<div class="graflegenda">' + $legenda + '</div>' } else { '' }
    @"
<div class="grafico">
  $tit
  <svg width="$Largura" height="$Altura" viewBox="0 0 $Largura $Altura" xmlns="http://www.w3.org/2000/svg">
    <line x1="$margemEsq" y1="$margemTopo" x2="$margemEsq" y2="$($margemTopo + $areaH)" stroke="#D6DBE6" stroke-width="1"/>
    <line x1="$margemEsq" y1="$($margemTopo + $areaH)" x2="$($margemEsq + $areaW)" y2="$($margemTopo + $areaH)" stroke="#D6DBE6" stroke-width="1"/>
    $eixoYHtml
    $($linhas -join "`n")
  </svg>
  $legHtml
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

# Item 5: curva de velocidade do speedtest (Fase 1, sem VPN) -- 2 series
# (Download/Upload), eixo X = % daquela fase (ver ConvertTo-SerieVelocidadeSpeedtest).
function Get-GraficoCurvaVelocidadeHtml {
    param($M)
    $pontos = @(Get-Prop $M 'rede_local_serie_velocidade')
    if (-not $pontos.Count) { return '' }
    $mk = { param($Fase) @($pontos | Where-Object { $_.Fase -eq $Fase } | ForEach-Object { [pscustomobject]@{ T = $_.T; V = $_.Mbps } }) }
    $series = @(
        [pscustomobject]@{ Nome = 'Download'; Cor = '#123FA8'; Pontos = @(& $mk 'download') }
        [pscustomobject]@{ Nome = 'Upload';   Cor = '#1B7F3B'; Pontos = @(& $mk 'upload') }
    )
    Get-GraficoLinhaHtml -Series $series -Titulo ('Velocidade ao longo do teste (% da fase)') -EixoY 'Mbps' -Largura 300 -Altura 100
}

# Item 6a: curva de banda do iperf3 (Fase 2, com VPN) -- download e upload em
# sequencia na mesma linha do tempo (ver Test-BandaVpn/SerieBanda).
function Get-GraficoCurvaBandaVpnHtml {
    param($M)
    $pontos = @(Get-Prop $M 'vpn_serie_banda')
    if (-not $pontos.Count) { return '' }
    $mk = { param($Fase) @($pontos | Where-Object { $_.Fase -eq $Fase } | ForEach-Object { [pscustomobject]@{ T = $_.T; V = $_.Mbps } }) }
    $series = @(
        [pscustomobject]@{ Nome = 'Download'; Cor = '#123FA8'; Pontos = @(& $mk 'download') }
        [pscustomobject]@{ Nome = 'Upload';   Cor = '#1B7F3B'; Pontos = @(& $mk 'upload') }
    )
    Get-GraficoLinhaHtml -Series $series -Titulo 'Banda pela VPN ao longo do teste (s)' -EixoY 'Mbps' -Largura 300 -Altura 100
}

# Item 6b: latencia por amostra do ping (Fase 2, com VPN) -- uma amostra sem
# resposta vira um buraco na linha (ver Test-Latencia/AmostrasMs).
function Get-GraficoLatenciaAmostraHtml {
    param($M)
    $amostras = @(Get-Prop $M 'vpn_serie_latencia')
    if (-not $amostras.Count) { return '' }
    $pontos = for ($i = 0; $i -lt $amostras.Count; $i++) {
        [pscustomobject]@{ T = $i + 1; V = $amostras[$i] }
    }
    $series = @([pscustomobject]@{ Nome = 'Lat' + [char]0x00EA + 'ncia'; Cor = '#B77F00'; Pontos = @($pontos) })
    $titulo = 'Lat' + [char]0x00EA + 'ncia por amostra do ping (falha = buraco na linha)'
    Get-GraficoLinhaHtml -Series $series -Titulo $titulo -EixoY 'ms' -Largura 300 -Altura 100
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

    $prov = if ($M.rede_local_provedor) { '<div class="small"><b>Provedor:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_provedor)) + '</div>' } else { '' }

    # Dados da placa usada no teste (congelados no momento da checagem, ver
    # New-ResultadoJson): velocidade do link em LAN/Wi-Fi do local; banda,
    # sinal e SSID so' em Wi-Fi do local (no roteamento de celular nao
    # informamos isso, a rede de interesse ali e' a do celular, nao a placa).
    $infoPlaca = @()
    if ($M.PSObject.Properties['rede_local_velocidade_link_mbps'] -and $M.rede_local_velocidade_link_mbps) {
        $infoPlaca += '<b>Velocidade do link:</b> ' + $M.rede_local_velocidade_link_mbps + ' Mbps'
    }
    if ([string] $M.meio -eq 'wifi_local') {
        if ($M.PSObject.Properties['rede_local_wifi_ssid'] -and $M.rede_local_wifi_ssid) {
            $infoPlaca += '<b>Rede (SSID):</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_wifi_ssid))
        }
        if ($M.PSObject.Properties['rede_local_wifi_banda'] -and $M.rede_local_wifi_banda) {
            $infoPlaca += '<b>Banda:</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_wifi_banda))
        }
        if ($M.PSObject.Properties['rede_local_wifi_sinal_pct'] -and $null -ne $M.rede_local_wifi_sinal_pct -and "$($M.rede_local_wifi_sinal_pct)" -ne '') {
            $infoPlaca += '<b>N&iacute;vel do sinal:</b> ' + $M.rede_local_wifi_sinal_pct + ' %'
        }
    }
    $infoPlacaHtml = if ($infoPlaca.Count) { '<div class="small">' + ($infoPlaca -join ' &middot; ') + '</div>' } else { '' }

    $diagBox = ''
    if ($M.rede_local_diagnostico -and (@('handshake', 'bloqueio') -contains [string] $M.rede_local_falha_tipo)) {
        $rot = if ([string] $M.rede_local_falha_tipo -eq 'handshake') { 'Rede local fraca / inst&aacute;vel' } else { 'Teste de velocidade bloqueado no local' }
        $diagBox = '<div class="warn"><b>' + $rot + ':</b> ' + (ConvertTo-HtmlSafe ([string] $M.rede_local_diagnostico)) + '</div>'
    }
    $f1 = Get-TabelaAvaliacaoHtml -Linhas $M.rede_local_avaliacao -Modo $Modo
    if (-not $f1) { $f1 = '<div class="small">O teste de velocidade n&atilde;o mediu neste meio.</div>' }
    $grafVelocidade = Get-GraficoCurvaVelocidadeHtml -M $M

    if ($M.vpn_conectou) {
        $f2 = if ($Recomendado) { Get-TabelaAvaliacaoHtml -Linhas $R.avaliacao -ComMotivo -Modo $Modo } else { Get-TabelaVpnNumerosHtml $M }
        if (-not $f2) { $f2 = '<div class="small">Sem m&eacute;tricas registradas para a fase com a VPN.</div>' }
        $grafBanda    = Get-GraficoCurvaBandaVpnHtml -M $M
        $grafLatencia = Get-GraficoLatenciaAmostraHtml -M $M
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

    @"
  <div class="meio">
    <div class="meiotit"><span>$tit</span>$badge$flag</div>
    $grafSemCom
    <div class="cols">
      <div>
        <div class="subt">$subSem</div>
        $prov
        $infoPlacaHtml
        $diagBox
        $f1
        $grafVelocidade
      </div>
      <div>
        <div class="subt">$subCom</div>
        $f2
        $grafBanda
        $grafLatencia
      </div>
    </div>
    $grafTentativas
  </div>
"@
}

# Classificacao do local (analogo ao "Classificacao do imovel" da SEMAP).
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
        Get-GraficoBarrasHtml -Barras $barras -Titulo $g.Titulo -Unidade $g.Unidade -Largura 260 -AlturaBarra 14 -EspacoBarra 6
    }
    $blocos = @($blocos | Where-Object { $_ })
    if (-not $blocos.Count) { return '' }
    '<div class="ptit" style="margin-top:12px">Compara' + [char]0x00E7 + [char]0x00E3 + 'o entre os meios</div><div class="graflinha">' + ($blocos -join "`n") + '</div>'
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

    # observacoes: so pendencias de fato (VPN impossivel, meios NA)
    $obs = @()
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
  <div class="bar">Painel de Medi&ccedil;&otilde;es &mdash; Junta Eleitoral Especial 2026</div>
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
        $grafComparacao
      </div>
    </div>
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
    if ($aju) { $concRows += '<tr><td class="k">Ajuste da recomenda&ccedil;&atilde;o</td><td>{0}</td></tr>' -f $aju }
    $concRows += '<tr><td class="k">Condicionantes / pend&ecirc;ncias</td><td>{0}</td></tr>' -f $condHtml
    $concRows += '<tr><td class="k">Observa&ccedil;&otilde;es finais</td><td>{0}</td></tr>' -f $obs
    $grafComparacao = Get-GraficoComparacaoMeiosHtml -Meds $meds

    @"
  <div class="bar">Painel de Viabilidade de Conectividade &mdash; Junta Eleitoral Especial 2026</div>
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
        $grafComparacao
      </div>
    </div>
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
         letter-spacing: .06em; font-size: 11px; padding: 6px 12px; margin: 16px 0 8px; }
  .ptit, .subt { font-weight: 700; color: #1F4E79; font-size: 11px; text-transform: uppercase;
                 letter-spacing: .04em; margin: 8px 0 5px; }
  .subt { color: #2E5A8A; }

  table { border-collapse: collapse; width: 100%; margin: 4px 0 12px; }
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

  .meio { border: 1px solid #BFC9DA; margin: 0 0 12px; page-break-inside: avoid; }
  .meio.na { padding: 8px 12px; background: #F4F7FB; color: #555; }
  .meiotit { background: #E7EDF6; padding: 6px 12px; font-weight: 700; font-size: 12px;
             display: flex; align-items: center; gap: 10px; }
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
