# Relatorio de diagnostico em PDF. Monta um HTML no padrao dos relatorios do
# TRE-MA (cabecalho JE, tabela, rodape) e converte com o Microsoft Edge em
# modo headless (--print-to-pdf). Sem Edge, salva o proprio HTML.

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

# Monta o HTML do relatorio a partir do objeto do New-ResultadoJson.
function New-RelatorioHtml {
    param([Parameter(Mandatory)] $Resultado)

    $r   = $Resultado
    $loc = $r.local
    $amb = $r.ambiente
    $cl  = $r.classificacao

    $quando = try { [datetime] $r.coletado_em } catch { Get-Date }
    $tipoLocal = if ($loc.tipo -eq 'principal') { 'Local Principal' } else { 'Local de Conting' + [char]0x00EA + 'ncia' }
    $vpn = if ($amb.vpn_ativa -eq $true) { 'ativa' } elseif ($amb.vpn_ativa -eq $false) { 'n' + [char]0x00E3 + 'o detectada' } else { 'n/d' }

    $linhas = foreach ($a in @($r.avaliacao)) {
        $regra = if ($a.direcao -eq 'max') {
            'vi' + [char]0x00E1 + 'vel &le; {0}{2} / ressalva &le; {1}{2}' -f $a.limiar_viavel, $a.limiar_ressalva, $a.unidade
        } else {
            'vi' + [char]0x00E1 + 'vel &ge; {0}{2} / ressalva &ge; {1}{2}' -f $a.limiar_viavel, $a.limiar_ressalva, $a.unidade
        }
        $badge = '<span style="color:{0};font-weight:600">{1}</span>' -f (Get-CorVeredito $a.classe_final), (ConvertTo-HtmlSafe (Get-RotuloVeredito $a.classe_final))
        $just  = if ($a.ajustada) { ConvertTo-HtmlSafe ([string] $a.justificativa) } else { '&mdash;' }
        @"
      <tr>
        <td>$(ConvertTo-HtmlSafe $a.rotulo)</td>
        <td class="mono">$(ConvertTo-HtmlSafe (Format-ValorMetrica $a.valor $a.unidade))</td>
        <td class="mono small">$regra</td>
        <td>$badge</td>
        <td class="small">$just</td>
      </tr>
"@
    }

    $corFinal = Get-CorVeredito $cl.final
    $rotFinal = ConvertTo-HtmlSafe (Get-RotuloVeredito $cl.final)
    $justFinal = if ($cl.ajustada -and $cl.justificativa) {
        '<p class="small"><b>Ajuste da decis' + [char]0x00E3 + 'o:</b> ' + (ConvertTo-HtmlSafe ([string] $cl.justificativa)) + '</p>'
    } else { '' }

    $vpnBanner = ''
    $vpnObj = if ($r.PSObject.Properties['vpn']) { $r.vpn } else { $null }
    if ($vpnObj -and $vpnObj.impossivel) {
        $vpnBanner = '<p style="border:1px solid #BC352A;color:#BC352A;padding:6px 12px;border-radius:4px;font-weight:700">' +
            'N&atilde;o foi poss&iacute;vel conectar a VPN da Justi&ccedil;a Eleitoral neste local &mdash; a bateria com VPN n&atilde;o foi medida.' +
            $(if ($vpnObj.motivo) { '<br><span style="font-weight:400">Motivo: ' + (ConvertTo-HtmlSafe ([string] $vpnObj.motivo)) + '</span>' } else { '' }) +
            '</p>'
    }

    $tecnico  = ConvertTo-HtmlSafe ([string] $r.tecnico.nome)
    $geradoEm = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')

    $desat = @(if ($r.PSObject.Properties['metricas_desativadas']) { $r.metricas_desativadas })
    $linhaDesat = if ($desat.Count) {
        '<p class="small"><b>M&eacute;tricas n&atilde;o avaliadas (desativadas na configura&ccedil;&atilde;o):</b> {0}</p>' -f `
            (ConvertTo-HtmlSafe (($desat | ForEach-Object { Get-RotuloMetrica $_ }) -join ', '))
    } else { '' }

    $brasao    = Get-BrasaoDataUri
    $imgBrasao = if ($brasao) { '<img class="brasao" src="{0}" alt="">' -f $brasao } else { '' }

    # Bloco "Local avaliado" (so mostra o que existir nos dados).
    $uc   = ConvertTo-HtmlSafe (Get-CampoLocal $loc 'unidade_consumidora')
    $resp = Get-CampoLocal $loc 'responsavel'
    $func = Get-CampoLocal $loc 'funcao'
    if ($func) { $resp = '{0} ({1})' -f $resp, $func }
    $resp = ConvertTo-HtmlSafe $resp
    $tel  = ConvertTo-HtmlSafe (Get-CampoLocal $loc 'telefone')

    $campos = @(
        '<div><b>Tipo:</b> {0}</div>' -f $tipoLocal
        '<div><b>Junta / ZE:</b> {0}</div>' -f $loc.zona_eleitoral
        '<div style="grid-column:1/3"><b>Local:</b> {0}</div>' -f (ConvertTo-HtmlSafe $loc.nome)
        '<div style="grid-column:1/3"><b>Endere&ccedil;o:</b> {0}</div>' -f (ConvertTo-HtmlSafe $loc.endereco)
    )
    if ($uc)   { $campos += '<div><b>Unidade consumidora:</b> {0}</div>' -f $uc }
    if ($tel)  { $campos += '<div><b>Telefone / WhatsApp:</b> {0}</div>' -f $tel }
    if ($resp) { $campos += '<div style="grid-column:1/3"><b>Respons&aacute;vel:</b> {0}</div>' -f $resp }
    $campos += '<div style="grid-column:1/3"><b>Tipo de internet:</b> {0}</div>' -f (ConvertTo-HtmlSafe $loc.tipo_internet)
    $blocoLocal = $campos -join "`n    "

    # Bloco "Rede local (antes da VPN)" - so aparece se a fase 1 foi coletada.
    $rl = if ($r.PSObject.Properties['rede_local']) { $r.rede_local } else { $null }
    $blocoRedeLocal = ''
    if ($rl) {
        $lanS = if ($rl.lan_conectada) { 'conectada' } else { 'sem cabo / desconectada' }
        $wifiS = if ($rl.wireless_conectado) {
            'conectada a &quot;{0}&quot; ({1}%)' -f (ConvertTo-HtmlSafe ([string] $rl.wireless_ssid)), $rl.wireless_sinal_pct
        } elseif ($rl.wireless_presente) { 'placa presente, n&atilde;o conectada' } else { 'sem placa Wi-Fi' }

        $tether = ($rl.PSObject.Properties['tethering_celular']) -and $rl.tethering_celular

        $ce = @()
        if ($rl.PSObject.Properties['host'] -and $rl.host) {
            $ce += '<div><b>Computador:</b> {0}</div>' -f (ConvertTo-HtmlSafe ([string] $rl.host))
        }
        if ($tether) {
            $op = if ($rl.PSObject.Properties['operadora'] -and $rl.operadora) {
                ' &mdash; operadora <b>{0}</b>' -f (ConvertTo-HtmlSafe ([string] $rl.operadora))
            } else { '' }
            $ce += '<div style="grid-column:1/3"><b>Conex&atilde;o:</b> roteamento (tethering) do celular do t&eacute;cnico{0}</div>' -f $op
        }
        $ce += '<div><b>Placa de rede (LAN):</b> {0}</div>' -f $lanS
        if ($rl.ip_local)        { $ce += '<div><b>IP na rede local:</b> {0}</div>' -f (ConvertTo-HtmlSafe ([string] $rl.ip_local)) }
        if ($rl.mascara)         { $ce += '<div><b>M&aacute;scara:</b> {0}</div>' -f (ConvertTo-HtmlSafe ([string] $rl.mascara)) }
        if ($rl.gateway)         { $ce += '<div><b>Gateway:</b> {0}</div>' -f (ConvertTo-HtmlSafe ([string] $rl.gateway)) }
        if (@($rl.dns).Count)    { $ce += '<div><b>DNS:</b> {0}</div>' -f (ConvertTo-HtmlSafe ((@($rl.dns)) -join ', ')) }
        if ($rl.mac)             { $ce += '<div><b>MAC:</b> {0}</div>' -f (ConvertTo-HtmlSafe ([string] $rl.mac)) }
        if ($rl.velocidade_mbps) { $ce += '<div><b>Enlace:</b> {0} Mbps</div>' -f $rl.velocidade_mbps }
        $ce += '<div style="grid-column:1/3"><b>Wi-Fi:</b> {0}</div>' -f $wifiS

        $pAlvo = if ($rl.PSObject.Properties['internet_ping_alvo']) { [string] $rl.internet_ping_alvo } else { '' }
        $dUrl  = if ($rl.PSObject.Properties['internet_download_url']) { [string] $rl.internet_download_url } else { '' }
        $dBy   = if ($rl.PSObject.Properties['internet_download_bytes']) { $rl.internet_download_bytes } else { $null }

        $intp = @()
        if ($null -ne $rl.internet_ping_ms) {
            $intp += ('ping p&uacute;blico{0} {1} ms' -f $(if ($pAlvo) { ' a ' + (ConvertTo-HtmlSafe $pAlvo) } else { '' }), $rl.internet_ping_ms)
        }
        if ($null -ne $rl.internet_perda_pct)     { $intp += ('perda {0}%' -f $rl.internet_perda_pct) }
        if ($null -ne $rl.internet_dns_ms)        { $intp += ('DNS {0} ms' -f $rl.internet_dns_ms) }
        if ($null -ne $rl.internet_download_mbps) {
            $tam = if ($dBy) { ' de {0} MB' -f ([math]::Round([double] $dBy / 1MB, 1)) } else { '' }
            $intp += ('download ~{0} Mbps{1}' -f $rl.internet_download_mbps, $tam)
        }
        if ($intp.Count) { $ce += '<div style="grid-column:1/3"><b>Internet local (sem VPN):</b> {0}</div>' -f ($intp -join ' &middot; ') }
        if ($dUrl) { $ce += '<div style="grid-column:1/3"><b>Alvo do download:</b> {0}</div>' -f (ConvertTo-HtmlSafe $dUrl) }
        if ($rl.PSObject.Properties['internet_tracert_saltos'] -and [int] $rl.internet_tracert_saltos -gt 0) {
            $trH = if ($rl.PSObject.Properties['internet_tracert_host']) { [string] $rl.internet_tracert_host } else { '' }
            $ce += '<div style="grid-column:1/3"><b>Rota (tracert):</b> {0} salto(s){1}</div>' -f `
                $rl.internet_tracert_saltos, $(if ($trH) { ' at&eacute; ' + (ConvertTo-HtmlSafe $trH) } else { '' })
        }

        $blocoRedeLocal = "  <h2>Rede local (antes da VPN do TRE)</h2>`n  <div class=""grid2"">`n    " + ($ce -join "`n    ") + "`n  </div>`n"
    }

    @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Relat&oacute;rio de Diagn&oacute;stico de Conectividade</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', Arial, sans-serif; color: #1f2430; margin: 32px 36px; font-size: 12px; }
  .cab { display: flex; justify-content: space-between; align-items: flex-start; }
  .cab .id { display: flex; align-items: flex-start; }
  .cab .brasao { height: 74px; margin-right: 14px; }
  .cab h1 { font-size: 15px; margin: 0 0 2px; }
  .cab .org { color: #444; font-size: 11px; line-height: 1.5; }
  .cab .data { text-align: right; color: #444; font-size: 11px; white-space: nowrap; }
  hr { border: none; border-top: 3px solid #1a3a8f; margin: 10px 0 18px; }
  h2 { font-size: 14px; margin: 20px 0 8px; }
  .resumo { font-size: 12px; margin: 0 0 6px; }
  .final { display: inline-block; margin: 4px 0 14px; padding: 6px 14px; border-radius: 4px;
           border: 1px solid $corFinal; color: $corFinal; font-weight: 700; font-size: 14px; }
  table { border-collapse: collapse; width: 100%; margin: 6px 0 14px; }
  th, td { border: 1px solid #d6dae2; padding: 6px 9px; text-align: left; vertical-align: top; }
  th { background: #f2f4f8; font-size: 11px; color: #333; }
  .mono { font-family: 'Consolas', 'Courier New', monospace; }
  .small { font-size: 11px; color: #333; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 2px 24px; margin: 4px 0 10px; }
  .grid2 div { font-size: 12px; }
  .grid2 b { color: #555; font-weight: 600; }
  .rodape { margin-top: 22px; border-top: 1px solid #d6dae2; padding-top: 8px; color: #777; font-size: 10px; }
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

  <h2>Relat&oacute;rio de Diagn&oacute;stico de Conectividade</h2>
  <p class="resumo">ZE $($loc.zona_eleitoral) &mdash; $(ConvertTo-HtmlSafe $loc.municipio_termo) (sede: $(ConvertTo-HtmlSafe $loc.municipio_sede))</p>
  <div class="final">Decis&atilde;o final: $rotFinal</div>
  $justFinal
  $vpnBanner

  <h2>Local avaliado</h2>
  <div class="grid2">
    $blocoLocal
  </div>

$blocoRedeLocal
  <h2>M&eacute;tricas medidas</h2>
  <table>
    <thead>
      <tr><th>M&eacute;trica</th><th>Valor medido</th><th>Faixa aceit&aacute;vel</th><th>Classifica&ccedil;&atilde;o</th><th>Motivo do ajuste</th></tr>
    </thead>
    <tbody>
$($linhas -join "`n")
    </tbody>
  </table>
  $linhaDesat

  <h2>Contexto da medi&ccedil;&atilde;o</h2>
  <div class="grid2">
    <div><b>T&eacute;cnico:</b> $tecnico</div>
    <div><b>Coletado em:</b> $($quando.ToString('dd/MM/yyyy HH:mm:ss'))</div>
    <div><b>Computador:</b> $(ConvertTo-HtmlSafe $amb.host)</div>
    <div><b>Usu&aacute;rio:</b> $(ConvertTo-HtmlSafe $amb.usuario)</div>
    <div><b>VPN da JE:</b> $vpn</div>
    <div><b>Interface:</b> $(ConvertTo-HtmlSafe $amb.interface_principal)</div>
  </div>

  <div class="rodape">Gerado pela ferramenta DICON &mdash; TRE-MA em $geradoEm. Vers&atilde;o $($r.versao_ferramenta).</div>
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
