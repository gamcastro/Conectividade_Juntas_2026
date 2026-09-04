#Requires -Version 5.1
<#
.SYNOPSIS
    Teste de integracao HEADLESS: login -> home -> guia de bordo -> diagnostico,
    com fixtures locais, sem exibir janela. Valida navegacao + fluxo assincrono.
#>
[CmdletBinding()]
param(
    [int] $TimeoutS = 120
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    & $exe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -TimeoutS $TimeoutS
    exit $LASTEXITCODE
}

$Global:RaizApp    = Split-Path $PSScriptRoot -Parent
$Global:ArquivoLog = $null
$Global:ModoTeste  = $true   # nao abrir o PDF/pasta no final do export
$Global:VpnSimulada = $true  # passo 4: VPN "conectada" (troque p/ testar o gate)
# passo 4: nao roda o iperf3 real (o binario agora vai no repo); erro sintetico
$Global:BandaVpnSimulada = [pscustomobject]@{
    iperf_ok = $false; iperf_erro = 'ambiente de teste: iperf3 nao executado'
    servidor = 'teste:5201'; DownloadMbps = $null; UploadMbps = $null
    retrans_down = $null; retrans_up = $null
}

# fase 1 (rede local) simulada: nao mexe na placa de rede real da maquina de teste
$Global:FaseLocalSimulada = [pscustomobject]@{
    Host = 'NB-TESTE-01'
    Lan = [pscustomobject]@{
        presente = $true; nome = 'Ethernet'; descricao = 'Realtek PCIe GbE Family Controller'
        status = 'Up'; conectado = $true
        ipv4 = '192.168.15.42'; prefixo = 24; mascara = '255.255.255.0'; gateway = '192.168.15.1'
        dns = @('192.168.15.1', '8.8.8.8'); ip_origem = 'DHCP'; mac = 'AA-BB-CC-DD-EE-FF'; velocidade_mbps = 1000
    }
    Wireless = [pscustomobject]@{
        presente = $true; nome = 'Wi-Fi'; status = 'Disconnected'; conectado = $false
        ssid = 'JE-CAMPO'; sinal_pct = 78; banda_ghz = '5 GHz'; redes_disponiveis = @('JE-CAMPO', 'VIVO-2G')
        ipv4 = '192.168.15.42'; prefixo = 24; mascara = '255.255.255.0'; gateway = '192.168.15.1'
        dns = @('192.168.15.1'); ip_origem = 'DHCP'; mac = '11-22-33-44-55-66'; velocidade_mbps = 300
    }
    Internet = [pscustomobject]@{
        speedtest_ok = $true; speedtest_erro = ''
        isp = 'BARREIRAS NET'; ip_externo = '187.62.154.178'
        servidor_nome = 'Suprinet Fibra'; servidor_local = 'Corrente'; servidor_id = 12345; servidor_host = 'st.suprinet.net:8080'
        ping_ms = 20.1; jitter_ms = 0.8; perda_pct = 0.0
        download_mbps = 855.63; upload_mbps = 295.27; download_lat_ms = 27; upload_lat_ms = 20
        resultado_url = 'https://www.speedtest.net/result/c/abc-123'; resultado_id = 'abc-123'
        quando = (Get-Date).ToString('o')
    }
    Quando = (Get-Date).ToString('o')
}

Import-Module (Join-Path $Global:RaizApp 'src\Conectividade.psd1') -Force
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Invoke-Pump {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        [action] { $frame.Continue = $false }) | Out-Null
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---- fixtures numa pasta temporaria: nao toca no data/ real -------------
$dataDir = Join-Path ([IO.Path]::GetTempPath()) ('dicon-teste-data-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$Global:PastaDadosOverride = $dataDir

$agora = (Get-Date).ToString('o')
@{ atualizado_em = $agora; juntas = @(
        @{ id = 'ZE99-TESTE-PRINCIPAL'; zona_eleitoral = 99; municipio_sede = 'TESTE'; municipio_termo = 'Teste'
            tipo = 'principal'; nome = 'LOCAL PRINCIPAL DE TESTE'; endereco = 'Rua Teste, 1'; tipo_internet = 'Fibra optica'
            unidade_consumidora = '10163145'; responsavel = 'Fulano de Tal'; funcao = 'Servidor'; telefone = '(99) 90000-0000'; texto_completo = '' }
        @{ id = 'ZE99-TESTE-CONTINGENCIA'; zona_eleitoral = 99; municipio_sede = 'TESTE'; municipio_termo = 'Teste'
            tipo = 'contingencia'; nome = 'LOCAL DE CONTINGENCIA DE TESTE'; endereco = 'Rua Teste, 2'; tipo_internet = 'Banda larga'; texto_completo = '' }
        @{ id = 'ZE88-FORA-PRINCIPAL'; zona_eleitoral = 88; municipio_sede = 'FORA'; municipio_termo = 'Fora da Rota'
            tipo = 'principal'; nome = 'LOCAL FORA DA ROTA'; endereco = 'Rua Fora, 1'; tipo_internet = 'Radio'; texto_completo = '' }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'juntas.json') -Encoding UTF8

@{ atualizado_em = $agora; tecnicos = @(
        @{ nome = 'TECNICO HEADLESS'; roteiro_numero = 99; roteiro_nome = 'Teste'; ida = '01/01/2026'; retorno = '02/01/2026'; dias = 2 }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'tecnicos.json') -Encoding UTF8

@{ atualizado_em = $agora; roteiros = @(
        @{ numero = 99; nome = 'Teste'; rotulo = 'Roteiro 99 - Teste'; tecnico = 'TECNICO HEADLESS'; etapa = 1
            ida = '01/01/2026'; retorno = '02/01/2026'; dias = 2; total_km = 10; total_tempo = '1h'; total_locais = 1
            cidades = @('Teste'); cidades_sem_junta = @()
            trechos = @(@{ origem = 'A'; destino = 'Teste'; distancia_km = 10; tempo = '1h'; atividade_dias = 0.5 })
            juntas_ids = @('ZE99-TESTE-PRINCIPAL', 'ZE99-TESTE-CONTINGENCIA') }
    ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dataDir 'roteiros.json') -Encoding UTF8

$pendDir = Join-Path $Global:RaizApp 'resultados\pendentes'
$pendAntes = @(Get-ChildItem $pendDir -Filter *.json -EA SilentlyContinue | Select-Object -ExpandProperty FullName)

$falhas = 0
try {
    $w = New-JanelaPrincipal
    Write-Host "[1] Janela construida"
    if ($w.FindName('viewLogin').Visibility -ne 'Visible') { Write-Host "    FALHA: nao abriu no login"; $falhas++ }
    else { Write-Host "[1] Abriu na tela de login" }

    # 1b. selo de ambiente: existe e segue o canal (config\canal). Sem o arquivo
    # (repo/testes) o canal e 'main' -> selos ocultos.
    $canalT = Get-CanalInstalacao
    $bl = $w.FindName('badgeHomologLogin'); $br = $w.FindName('badgeHomologRail')
    if (-not $bl -or -not $br) { Write-Host "    FALHA: selos de homologacao ausentes no XAML"; $falhas++ }
    else {
        $espera = if ($canalT -eq 'homologacao') { 'Visible' } else { 'Collapsed' }
        if ("$($bl.Visibility)" -eq $espera -and "$($br.Visibility)" -eq $espera) {
            Write-Host "[1b] selo de ambiente coerente com o canal '$canalT' ($espera)"
        } else { Write-Host "    FALHA: selo de ambiente (canal=$canalT login=$($bl.Visibility) rail=$($br.Visibility))"; $falhas++ }
    }

    # 2. login
    $cbo = $w.FindName('cboTecnico')
    if ($cbo.Items.Count -lt 1) { Write-Host "[2] FALHA: cboTecnico vazio"; $falhas++ }
    $cbo.SelectedIndex = 0
    Enter-Sessao
    if ($w.FindName('viewHome').Visibility -ne 'Visible') { Write-Host "[2] FALHA: nao foi para a home"; $falhas++ }
    else { Write-Host "[2] Login OK -> home ($($w.FindName('txtSaudacao').Text))" }

    # 2c-versao. aviso de versao nova no rodape do rail
    Update-AvisoVersao '99.99.99'
    if ("$($w.FindName('btnAtualizarApp').Visibility)" -eq 'Visible' -and "$($w.FindName('btnAtualizarApp').Content)" -match '99\.99\.99') {
        Write-Host "[2c] versao nova -> botao 'Atualizar' aparece no rail"
    } else { Write-Host "    FALHA: aviso de versao nova"; $falhas++ }
    Update-AvisoVersao $Global:VersaoApp
    if ("$($w.FindName('btnAtualizarApp').Visibility)" -eq 'Collapsed') { Write-Host "[2c] mesma versao -> botao oculto" }
    else { Write-Host "    FALHA: botao 'Atualizar' nao sumiu com a mesma versao"; $falhas++ }

    # 2d. menu lateral recolhe/expande
    $lRail0 = $w.FindName('railNav').Width
    Invoke-ToggleRail
    $lRail1 = $w.FindName('railNav').Width
    if ($lRail1 -lt $lRail0 -and "$($w.FindName('lblNavGuia').Visibility)" -eq 'Collapsed') {
        Write-Host "[2d] menu recolheu ($lRail0 -> $lRail1, rotulos ocultos)"
    } else { Write-Host "    FALHA: menu nao recolheu (w $lRail0 -> $lRail1)"; $falhas++ }
    Invoke-ToggleRail
    if ($w.FindName('railNav').Width -eq $lRail0 -and "$($w.FindName('lblNavGuia').Visibility)" -eq 'Visible') {
        Write-Host "[2d] menu expandiu de volta"
    } else { Write-Host "    FALHA: menu nao expandiu"; $falhas++ }

    # 2b. seletor de Juntas filtra pela rota do tecnico (cache tem 2, rota tem 1)
    $nJrota = @($w.FindName('cboJunta').ItemsSource).Count
    if ($nJrota -eq 1) { Write-Host "[2b] seletor filtra pela rota: $nJrota Junta (de 2 no cache)" }
    else { Write-Host "    FALHA: seletor mostrou $nJrota Junta(s) (esperado 1 da rota)"; $falhas++ }

    # 2c. 'incluir Juntas fora da rota' (admin) volta a mostrar todas
    $Global:MostrarTodasJuntas = $true;  Update-SeletorJuntas
    $nJtodas = @($w.FindName('cboJunta').ItemsSource).Count
    $Global:MostrarTodasJuntas = $false; Update-SeletorJuntas
    if ($nJtodas -eq 2) { Write-Host "[2c] incluir fora da rota: $nJtodas Juntas" }
    else { Write-Host "    FALHA: incluir fora da rota = $nJtodas (esperado 2)"; $falhas++ }

    # 3. guia de bordo
    Show-GuiaBordo
    if ($w.FindName('viewGuia').Visibility -ne 'Visible') { Write-Host "[3] FALHA: nao abriu o guia"; $falhas++ }
    $nJuntas  = @($w.FindName('lstGuiaJuntas').ItemsSource).Count
    Write-Host "[3] Guia: $nJuntas grupo(s) de Junta"
    if ($nJuntas -lt 1) { Write-Host "    FALHA: guia sem conteudo"; $falhas++ }

    # 3b. tela de Locais: lista + busca + filtros por ZE/municipio
    Show-Locais
    if ($w.FindName('viewLocais').Visibility -eq 'Visible' -and @($w.FindName('dgLocais').ItemsSource).Count -ge 1) {
        $nTot = @($w.FindName('dgLocais').ItemsSource).Count
        Write-Host "[3b] Locais: tela abriu com $nTot local(is)"
    } else { Write-Host "[3b] FALHA: tela de Locais vazia (vis=$($w.FindName('viewLocais').Visibility))"; $falhas++ }
    $nTodos = @($w.FindName('dgLocais').ItemsSource).Count
    $w.FindName('txtBuscaLocais').Text = 'zzz-nao-existe'
    Invoke-Pump
    if (@($w.FindName('dgLocais').ItemsSource).Count -eq 0) { Write-Host "[3b] busca sem resultado filtra a grade" }
    else { Write-Host "    FALHA: busca nao filtrou"; $falhas++ }
    $w.FindName('txtBuscaLocais').Text = ''
    Invoke-Pump
    if (@($w.FindName('dgLocais').ItemsSource).Count -eq $nTodos) { Write-Host "[3b] limpar a busca restaura a lista" }
    else { Write-Host "    FALHA: limpar a busca nao restaurou ($(@($w.FindName('dgLocais').ItemsSource).Count) x $nTodos)"; $falhas++ }
    if (@($w.FindName('cboFiltroZE').ItemsSource).Count -ge 2 -and @($w.FindName('cboFiltroMun').ItemsSource).Count -ge 2) {
        Write-Host "[3b] combos ZE/municipio populados"
    } else { Write-Host "    FALHA: combos de filtro vazios"; $falhas++ }
    # a grade precisa selecionar a LINHA inteira (SelectedItem != null ao clicar);
    # com SelectionUnit=Cell do estilo GridMetricas, clicar nao abria nada.
    $dg = $w.FindName('dgLocais')
    if ("$($dg.SelectionUnit)" -eq 'FullRow') { Write-Host "[3b] grade seleciona a linha inteira (FullRow)" }
    else { Write-Host "    FALHA: dgLocais SelectionUnit='$($dg.SelectionUnit)' (esperado FullRow)"; $falhas++ }
    $dg.SelectedItem = @($dg.ItemsSource)[0]   # o que um clique de mouse faz
    Invoke-Pump
    if ("$($w.FindName('viewLocalDetalhe').Visibility)" -eq 'Visible' -and "$($w.FindName('txtLDPNome').Text)") {
        Write-Host "[3b] clicar num local abre a ficha completa ($($w.FindName('txtLDPNome').Text))"
    } else { Write-Host "    FALHA: ficha completa do local nao abriu (vis=$($w.FindName('viewLocalDetalhe').Visibility))"; $falhas++ }

    # 3c. tela de detalhe: indicadores de status + card do GEL (movido do passo 2)
    $dotsLd = @('dotLdTestado','dotLdSalvo','dotLdTransmitido','dotLdExportado','dotLdGel') |
        ForEach-Object { $w.FindName($_) }
    if (@($dotsLd | Where-Object { $_ }).Count -eq 5 -and @($dotsLd | Where-Object { $_.Fill }).Count -eq 5) {
        Write-Host "[3c] 5 indicadores de status pintados na ficha do local"
    } else { Write-Host "    FALHA: indicadores de status ausentes/sem cor na ficha do local"; $falhas++ }
    if ("$($w.FindName('cardGel').Visibility)" -eq 'Visible') {
        Write-Host "[3c] card do formulario GEL vive na ficha do local"
    } else { Write-Host "    FALHA: cardGel nao visivel na ficha do local (vis=$($w.FindName('cardGel').Visibility))"; $falhas++ }
    $anc = $w.FindName('cardGel'); $souDetalhe = $false
    while ($anc) {
        if ($anc -eq $w.FindName('viewLocalDetalhe')) { $souDetalhe = $true; break }
        $anc = [Windows.LogicalTreeHelper]::GetParent($anc)
    }
    if ($souDetalhe) {
        Write-Host "[3c] card do GEL vive dentro de viewLocalDetalhe (saiu do passo 2)"
    } else { Write-Host "    FALHA: cardGel nao esta sob viewLocalDetalhe"; $falhas++ }

    # 3d. persistencia do anexo GEL por local (data/vistoria-gel/<id>.json)
    $gelId = 'ZE99-TESTE-PRINCIPAL'
    Remove-VistoriaGel -LocalId $gelId
    Save-VistoriaGel -LocalId $gelId -Dados ([pscustomobject]@{
        lat = -2.5; long = -43.25; precisao_m = 6.5
        suporte_nome = 'ACME'; suporte_telefone = '99 99999-9999'
        eletrica_tensao = '220V'; eletrica_tomadas = '4'; eletrica_extensao = 'nao'
    }) | Out-Null
    $gelBack = Get-VistoriaGel -LocalId $gelId
    if ($gelBack -and [double] $gelBack.lat -eq -2.5 -and "$($gelBack.suporte_nome)" -eq 'ACME') {
        Write-Host "[3d] Save-VistoriaGel / Get-VistoriaGel round-trip OK"
    } else { Write-Host "    FALHA: round-trip do anexo GEL"; $falhas++ }
    if ((Get-StatusLocal -LocalId $gelId).gel) {
        Write-Host "[3d] Get-StatusLocal reflete o anexo GEL"
    } else { Write-Host "    FALHA: Get-StatusLocal nao viu o anexo GEL"; $falhas++ }
    Remove-VistoriaGel -LocalId $gelId
    if (-not (Get-StatusLocal -LocalId $gelId).gel) {
        Write-Host "[3d] Remove-VistoriaGel limpa o anexo"
    } else { Write-Host "    FALHA: Remove-VistoriaGel nao apagou o anexo"; $falhas++ }

    Invoke-VoltarAosLocais
    Invoke-Pump
    if ("$($w.FindName('viewLocais').Visibility)" -eq 'Visible' -and $w.FindName('dgLocais').SelectedIndex -lt 0) {
        Write-Host "[3b] 'voltar aos locais' retorna para a lista e limpa a selecao"
    } else { Write-Host "    FALHA: nao voltou para a lista de locais"; $falhas++ }
    Show-View 'viewHome'

    # 4. assistente pelo atalho do guia: abre no passo 1, Junta/Local pre-selecionados
    # (blocos [4]..[5f] cobrem o modo 'completo' - viabilidade; o modo 'medicao'
    #  e coberto no bloco [m] mais abaixo)
    $Global:ModoAvaliacaoOverride = 'completo'
    Start-DiagnosticoDoGuia -LocalId 'ZE99-TESTE-PRINCIPAL'
    Invoke-Pump
    if ($w.FindName('viewDiag').Visibility -ne 'Visible' -or $Global:WizardStep -ne 1) {
        Write-Host "[4] FALHA: nao abriu o assistente no passo 1 (step=$($Global:WizardStep))"; $falhas++
    }
    $selL = $w.FindName('cboLocal').SelectedItem
    if (-not $selL) { Write-Host "[4] FALHA: local nao pre-selecionado"; $falhas++ }
    else { Write-Host "[4] Assistente passo 1, local pre-selecionado: $($selL.Rotulo)" }

    # 4a-2. rail travado enquanto o assistente esta aberto (nao pode navegar pra
    # fora sem querer e perder o fio do diagnostico)
    $railPreso = -not $w.FindName('navLocais').IsEnabled -and -not $w.FindName('navDiag').IsEnabled -and
                 -not $w.FindName('navAjuda').IsEnabled -and -not $w.FindName('btnTrocarUsuario').IsEnabled
    if ($railPreso -and $Global:RailTravadoDiag) { Write-Host "[4a] rail travado ao entrar no assistente" }
    else { Write-Host "    FALHA: rail nao travou ao abrir o assistente (RailTravadoDiag=$Global:RailTravadoDiag)"; $falhas++ }

    # 4b. passo 1 -> 2: cartao de detalhe do local aparece com os campos extras
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 2) { Write-Host "[4b] FALHA: nao foi para o passo 2"; $falhas++ }
    if ($w.FindName('cardDetalheLocal').Visibility -ne 'Visible') { Write-Host "[4b] FALHA: cartao de detalhe nao apareceu"; $falhas++ }
    else { Write-Host "[4b] Passo 2: detalhe = '$($w.FindName('txtDetNome').Text)'" }
    $uc  = $w.FindName('txtDetUC')
    $rsp = $w.FindName('txtDetResponsavel')
    if ($uc.Visibility -eq 'Visible' -and "$($uc.Text)" -match '10163145' -and $rsp.Visibility -eq 'Visible' -and "$($rsp.Text)" -match 'Servidor') {
        Write-Host "[4b] campos extras: '$($uc.Text)' / '$($rsp.Text)'"
    } else { Write-Host "    FALHA: cartao sem UC/responsavel (uc='$($uc.Text)' resp='$($rsp.Text)')"; $falhas++ }

    # 4c. passo 2 -> 3 (meios de conexao): probe ao entrar mostra as placas
    Invoke-WizardProximo
    Invoke-Pump
    if ($Global:WizardStep -ne 3) { Write-Host "[4c] FALHA: nao foi para o passo 3 (meios)"; $falhas++ }
    $hostTxt = "$($w.FindName('txtLocHost').Text)"
    if ($w.FindName('cardFaseLocal').Visibility -eq 'Visible' -and $hostTxt -match 'NB-TESTE-01' -and
        $w.FindName('btnCheckLan').IsEnabled -and -not $w.FindName('btnCheckWifi').IsEnabled) {
        Write-Host "[4c] probe ao entrar: placas mostradas ($hostTxt); LAN conectada libera o botao, Wi-Fi nao"
    } else { Write-Host "    FALHA: probe do passo 3 (card=$($w.FindName('cardFaseLocal').Visibility) lan.en=$($w.FindName('btnCheckLan').IsEnabled) wifi.en=$($w.FindName('btnCheckWifi').IsEnabled) host='$hostTxt')"; $falhas++ }

    # 4c-0a. spinner "verificando as placas" enquanto o probe roda (payload nulo)
    $flOrig = $Global:FaseLocalPayload
    $Global:FaseLocalPayload = $null ; Update-PainelMeios
    $spinOn = ("$($w.FindName('ringMeios').Visibility)" -eq 'Visible' -and $w.FindName('ringMeios').IsActive)
    $Global:FaseLocalPayload = $flOrig ; Update-PainelMeios
    $spinOff = ("$($w.FindName('ringMeios').Visibility)" -eq 'Collapsed')
    if ($spinOn -and $spinOff) { Write-Host "[4c] spinner 'verificando placas' liga sem payload e desliga com payload" }
    else { Write-Host "    FALHA: spinner do probe (on=$spinOn off=$spinOff)"; $falhas++ }

    # 4c-0b. botao "reler placas" reinventaria sem sair do passo 3
    Invoke-RelerPlacas
    Invoke-Pump
    if ($Global:WizardStep -eq 3 -and $w.FindName('cardFaseLocal').Visibility -eq 'Visible') {
        Write-Host "[4c] 'reler placas' reinventaria e mantem o passo 3"
    } else { Write-Host "    FALHA: 'reler placas' (step=$($Global:WizardStep))"; $falhas++ }

    # 4c-0c. selo "rede da Justica Eleitoral" quando o IP da LAN e 10.11.* / 10.198.*
    if (-not $w.FindName('ringRelerLan') -or -not $w.FindName('ringRelerWifi') -or -not $w.FindName('btnRelerLan')) {
        Write-Host "    FALHA: controles de releitura por card ausentes no XAML"; $falhas++
    }
    $ipLanOrig = $Global:FaseLocalPayload.Lan.ipv4
    $Global:FaseLocalPayload.Lan.ipv4 = '10.11.5.20' ; Update-PainelMeios
    $jeOn = "$($w.FindName('cardLocJE').Visibility)" -eq 'Visible'
    $Global:FaseLocalPayload.Lan.ipv4 = '192.168.1.10' ; Update-PainelMeios
    $jeOff = "$($w.FindName('cardLocJE').Visibility)" -eq 'Collapsed'
    if ($jeOn -and $jeOff) { Write-Host "[4c] selo 'rede da JE' aparece com IP 10.11.* e some fora dela" }
    else { Write-Host "    FALHA: selo rede JE (on=$jeOn off=$jeOff)"; $falhas++ }

    # 4c-0d. reler SO o Wi-Fi (por card) preserva os dados ja coletados da LAN
    $Global:FaseLocalPayload.Lan.ipv4 = '10.11.5.20' ; $Global:FaseLocalPayload.Lan.conectado = $true
    $wifiConectadoAntes = $Global:FaseLocalSimulada.Wireless.conectado
    $Global:FaseLocalSimulada.Wireless.conectado = $true
    Invoke-RelerAdaptador 'wifi'
    Invoke-Pump
    if ($Global:FaseLocalPayload.Lan.ipv4 -eq '10.11.5.20' -and [bool] $Global:FaseLocalPayload.Wireless.conectado) {
        Write-Host "[4c] reler so o Wi-Fi por card: LAN mantem o IP coletado, Wi-Fi atualiza"
    } else { Write-Host "    FALHA: reler Wi-Fi mexeu na LAN (lan.ip='$($Global:FaseLocalPayload.Lan.ipv4)' wifi.on=$($Global:FaseLocalPayload.Wireless.conectado))"; $falhas++ }
    $Global:FaseLocalSimulada.Wireless.conectado = $wifiConectadoAntes
    $Global:FaseLocalPayload.Lan.ipv4 = $ipLanOrig
    Update-PainelMeios

    # 4c-1. passo 3 bloqueia "Proximo" sem nenhum meio testado
    Invoke-WizardProximo
    if ($Global:WizardStep -eq 3) { Write-Host "[4c] passo 3 bloqueia 'Proximo' sem meio testado" }
    else { Write-Host "    FALHA: avancou sem testar meio (step=$($Global:WizardStep))"; $falhas++ }

    # 4c-2. ordem fixa LAN -> Wi-Fi -> Celular + isolamento de rede + "Proximo"
    $Global:FaseLocalPayload.Lan.conectado = $true
    $Global:FaseLocalPayload.Wireless.conectado = $true       # cabo E Wi-Fi ligados
    $w.FindName('cboOperadoraCel').Text = 'Vivo'
    Update-PainelMeios
    # a vez e da LAN, mas o Wi-Fi esta conectado -> botao travado + aviso na tela
    $lanTravadaPorWifi = -not $w.FindName('btnCheckLan').IsEnabled
    $avisoIsolamento   = "$($w.FindName('cardMeioAviso').Visibility)" -eq 'Visible'
    $wifi0 = -not $w.FindName('btnCheckWifi').IsEnabled       # 2o da ordem: travado
    $cel0  = -not $w.FindName('btnCheckCelular').IsEnabled    # 3o da ordem: travado
    $prox0 = "$($w.FindName('btnWizProximo').Visibility)" -eq 'Collapsed'
    # LAN "nao se aplica" -> a vez passa ao Wi-Fi; com o cabo fora o botao libera
    $w.FindName('chkNaLan').IsChecked = $true ; Update-NaoAplicavelMeio
    $w.FindName('txtNaJustif').Text = 'sem ponto de rede' ; Invoke-NaRegistrar ; Invoke-Pump
    $Global:FaseLocalPayload.Lan.conectado = $false          # cabo retirado p/ a etapa Wi-Fi
    Update-PainelMeios
    $wifi1 = $w.FindName('btnCheckWifi').IsEnabled
    $cel1  = -not $w.FindName('btnCheckCelular').IsEnabled    # Celular (3o) ainda travado
    # Wi-Fi e Celular tambem NA -> todos resolvidos -> "Proximo" aparece
    $w.FindName('chkNaWifi').IsChecked = $true ; Update-NaoAplicavelMeio
    $w.FindName('txtNaJustif').Text = 'x' ; Invoke-NaRegistrar ; Invoke-Pump
    $w.FindName('chkNaCelular').IsChecked = $true ; Update-NaoAplicavelMeio
    $w.FindName('txtNaJustif').Text = 'x' ; Invoke-NaRegistrar ; Invoke-Pump
    $proxAll = "$($w.FindName('btnWizProximo').Visibility)" -eq 'Visible'
    if ($lanTravadaPorWifi -and $avisoIsolamento -and $wifi0 -and $cel0 -and $prox0 -and $wifi1 -and $cel1 -and $proxAll) {
        Write-Host "[4c] ordem LAN->Wi-Fi->Celular + isolamento de rede + 'Proximo' so com tudo resolvido"
    } else { Write-Host "    FALHA: ordem/isolamento/Proximo (lanTrava=$lanTravadaPorWifi aviso=$avisoIsolamento w0=$wifi0 c0=$cel0 p0=$prox0 w1=$wifi1 c1=$cel1 pAll=$proxAll)"; $falhas++ }
    # restaura: nenhum meio NA (nem no hashtable nem em Medicoes), sem selecao
    foreach ($mk in 'lan', 'wifi_local', 'celular') { $Global:MeiosNaoAplicaveis.Remove($mk) }
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { $_ -and -not $_.nao_aplicavel })
    $Global:NaMeioPendente = ''
    $w.FindName('chkNaLan').IsChecked = $false ; $w.FindName('chkNaWifi').IsChecked = $false ; $w.FindName('chkNaCelular').IsChecked = $false
    $w.FindName('cardNaJustif').Visibility = 'Collapsed'
    $Global:FaseLocalPayload.Lan.conectado = $true
    $Global:MeioSelecionado = ''
    Update-PainelMeios

    # 4c-3. meio ja testado preserva os dados da placa do momento do teste (um
    # probe geral depois nao apaga; so refazer a checagem renova).
    $snapFake = [pscustomobject]@{ conectado = $true; presente = $true; nome = 'LAN'; ipv4 = '10.55.0.9'
        gateway = '10.55.0.1'; mascara = '255.255.255.0'; dns = @('10.55.0.1'); mac = 'AA-BB-CC-DD-EE-FF'
        ip_origem = 'DHCP'; velocidade_mbps = 1000 }
    $Global:Medicoes = @(@($Global:Medicoes) + [pscustomobject]@{ meio = 'lan'; operadora = ''
        rotulo = 'Rede cabeada (LAN)'; nao_aplicavel = $false; snapshot_adaptador = $snapFake
        veredito = 'viavel'; quando = (Get-Date).ToString('o') })
    $ipLanReal = $Global:FaseLocalPayload.Lan.ipv4
    $Global:FaseLocalPayload.Lan.ipv4 = '192.168.99.99'   # "probe geral" mexeu na placa
    Update-PainelMeios ; Invoke-Pump
    if ("$($w.FindName('txtLocIp').Text)" -match '10\.55\.0\.9' -and "$($w.FindName('txtLocGateway').Text)" -match '10\.55\.0\.1') {
        Write-Host "[4c] meio ja testado preserva IP/gateway do teste (probe geral nao apaga)"
    } else { Write-Host "    FALHA: card LAN nao preservou o snapshot (ip='$($w.FindName('txtLocIp').Text)')"; $falhas++ }
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { -not ($_.PSObject.Properties['snapshot_adaptador'] -and $_.snapshot_adaptador -eq $snapFake) })
    $Global:FaseLocalPayload.Lan.ipv4 = $ipLanReal
    Update-PainelMeios

    # 4d. checagem de um meio (celular) pelo overlay: Fase 1 + Fase 2 (VPN).
    # A ordem e rigida: LAN e Wi-Fi precisam estar resolvidos p/ a vez chegar ao Celular.
    $Global:VpnSimulada = $true
    $Global:FaseLocalPayload.Lan.conectado = $false          # cabo fora (etapa Wi-Fi/Celular)
    $Global:FaseLocalPayload.Wireless.conectado = $true       # placa Wi-Fi conectada
    $w.FindName('cboOperadoraCel').Text = 'Vivo'
    $Global:MeioSelecionado = '' ; Update-PainelMeios
    if (-not $w.FindName('btnCheckWifi').IsEnabled -and -not $w.FindName('btnCheckCelular').IsEnabled) {
        Write-Host "[4d] so a vez (LAN) e clicavel -> Wi-Fi e Celular travados"
    } else { Write-Host "    FALHA: card fora da vez habilitado (wifi.en=$($w.FindName('btnCheckWifi').IsEnabled) cel.en=$($w.FindName('btnCheckCelular').IsEnabled))"; $falhas++ }
    Select-MeioParaChecar 'celular'   # fora da ordem -> ignorado
    if ($Global:MeioSelecionado -ne 'celular') {
        Write-Host "[4d] clicar num card fora da ordem e ignorado (a vez ainda e da LAN)"
    } else { Write-Host "    FALHA: selecao pulou a ordem (sel='$($Global:MeioSelecionado)')"; $falhas++ }
    # LAN e Wi-Fi "nao se aplica" -> a vez passa ao Celular
    foreach ($nap in @(@('chkNaLan', 'sem ponto de rede cabeada'), @('chkNaWifi', 'sem Wi-Fi proprio no local'))) {
        $w.FindName($nap[0]).IsChecked = $true ; Update-NaoAplicavelMeio
        $w.FindName('txtNaJustif').Text = $nap[1] ; Invoke-NaRegistrar ; Invoke-Pump
    }
    Update-PainelMeios
    if ($Global:MeioSelecionado -eq 'celular' -and $w.FindName('btnCheckCelular').IsEnabled -and
        -not $w.FindName('btnCheckLan').IsEnabled -and -not $w.FindName('btnCheckWifi').IsEnabled) {
        Write-Host "[4d] a vez passa ao Celular: selecionado e 'Rodar checagem' liberado"
    } else { Write-Host "    FALHA: a vez nao chegou ao Celular (sel='$($Global:MeioSelecionado)' cel.en=$($w.FindName('btnCheckCelular').IsEnabled))"; $falhas++ }
    Invoke-CheckMeio 'celular'
    Invoke-Pump
    if ("$($w.FindName('overlayCheck').Visibility)" -eq 'Visible' -and $Global:CheckMeioAtivo -and
        "$($w.FindName('btnChkIniciar').Visibility)" -eq 'Visible' -and $Global:ChkFase -eq 'f1-pronto') {
        Write-Host "[4d] 'Rodar checagem' abre o overlay (aguardando 'Iniciar', nao roda sozinho)"
    } else { Write-Host "    FALHA: overlay nao abriu certo (vis=$($w.FindName('overlayCheck').Visibility) fase='$($Global:ChkFase)' btn=$($w.FindName('btnChkIniciar').Visibility))"; $falhas++ }
    Invoke-ChkAvancar   # Iniciar -> Fase 1
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump ; Start-Sleep -Milliseconds 120
        if ($Global:ChkFase -eq 'f2-pronto' -and $null -eq $Global:TarefaRedeState) { break }
    }
    if ($Global:ChkFase -eq 'f2-pronto' -and "$($w.FindName('btnChkIniciar').Content)" -match 'VPN') {
        Write-Host "[4d] Fase 1 concluida -> botao vira 'Testar a VPN'"
    } else { Write-Host "    FALHA: Fase 1 nao concluiu (fase='$($Global:ChkFase)' btn='$($w.FindName('btnChkIniciar').Content)')"; $falhas++ }
    Invoke-ChkAvancar   # "Testar a VPN" -> so VERIFICA (nao roda)
    Invoke-Pump
    $vpnTxt = "$($w.FindName('txtDiagVpn').Text)"
    if ($Global:ChkFase -eq 'f2-vpn-ok' -and $vpnTxt -match 'conectada' -and $vpnTxt -match '10\.11\.' -and
        "$($w.FindName('btnChkIniciar').Content)" -match 'Iniciar diagn') {
        Write-Host "[4d] 'Verificar' -> pausa: VPN conectada + IP mostrado; botao vira 'Iniciar diagnostico'"
    } else { Write-Host "    FALHA: pausa da VPN (fase='$($Global:ChkFase)' btn='$($w.FindName('btnChkIniciar').Content)' txt='$vpnTxt')"; $falhas++ }
    Invoke-ChkAvancar   # "Iniciar diagnostico com a VPN" -> agora sim roda a Fase 2
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump ; Start-Sleep -Milliseconds 120
        if ("$($w.FindName('btnChkFechar').Content)" -eq 'Concluir' -and $null -eq $Global:DiagRunState) { break }
    }
    Invoke-Pump
    $medCel = @($Global:Medicoes | Where-Object { $_.meio -eq 'celular' -and -not $_.nao_aplicavel } | Select-Object -First 1)
    if ($medCel -and "$($w.FindName('btnChkFechar').Content)" -eq 'Concluir') {
        Write-Host "[4d] checagem do meio concluida -> medicao 'celular' registrada (veredito $($medCel.veredito))"
    } else { Write-Host "    FALHA: checagem do meio nao concluiu (btn='$($w.FindName('btnChkFechar').Content)' med=$([bool]$medCel))"; $falhas++ }
    Close-OverlayCheck
    Invoke-Pump
    if ("$($w.FindName('overlayCheck').Visibility)" -eq 'Collapsed' -and -not $Global:CheckMeioAtivo) {
        Write-Host "[4d] 'Concluir' fecha o overlay"
    } else { Write-Host "    FALHA: overlay nao fechou"; $falhas++ }
    if ("$($w.FindName('badgeCelular').Text)" -match 'TESTADO') { Write-Host "[4d] card Celular marca 'TESTADO' ($($w.FindName('badgeCelular').Text))" }
    else { Write-Host "    FALHA: badge Celular nao virou TESTADO ('$($w.FindName('badgeCelular').Text)')"; $falhas++ }

    # 4e. banner de recomendacao aparece com >= 1 meio testado
    if ("$($w.FindName('cardRecMeios').Visibility)" -eq 'Visible' -and "$($w.FindName('txtRecMeios').Text)" -match 'usar') {
        Write-Host "[4e] banner de recomendacao: '$($w.FindName('txtRecMeios').Text)'"
    } else { Write-Host "    FALHA: banner de recomendacao (vis=$($w.FindName('cardRecMeios').Visibility) txt='$($w.FindName('txtRecMeios').Text)')"; $falhas++ }

    # 4f. "nao se aplica" -> abre o card de justificativa; "Registrar" desabilita o card do meio
    #    (a LAN esta NA desde o 4d; primeiro desmarca, depois refaz o ciclo)
    $w.FindName('chkNaLan').IsChecked = $false ; Update-NaoAplicavelMeio ; Invoke-Pump
    if (-not $Global:MeiosNaoAplicaveis.ContainsKey('lan')) { Write-Host "[4f] desmarcar o checkbox remove o 'nao aplicavel'" }
    else { Write-Host "    FALHA: desmarcar nao removeu o NA"; $falhas++ }
    $w.FindName('chkNaLan').IsChecked = $true
    Update-NaoAplicavelMeio
    Invoke-Pump
    if ("$($w.FindName('cardNaJustif').Visibility)" -eq 'Visible' -and $Global:NaMeioPendente -eq 'lan') {
        Write-Host "[4f] marcar 'nao se aplica' abre o card de justificativa"
    } else { Write-Host "    FALHA: card de justificativa nao abriu (vis=$($w.FindName('cardNaJustif').Visibility) pend='$($Global:NaMeioPendente)')"; $falhas++ }
    Invoke-NaRegistrar   # sem texto -> nao registra
    if (-not $Global:MeiosNaoAplicaveis.ContainsKey('lan')) { Write-Host "[4f] 'Registrar' sem justificativa nao grava" }
    else { Write-Host "    FALHA: registrou sem justificativa"; $falhas++ }
    $w.FindName('txtNaJustif').Text = 'sem ponto de rede na sala'
    Invoke-NaRegistrar
    Invoke-Pump
    if ($Global:MeiosNaoAplicaveis.ContainsKey('lan') -and -not $w.FindName('btnCheckLan').IsEnabled -and
        "$($w.FindName('cardNaJustif').Visibility)" -eq 'Collapsed' -and
        "$($w.FindName('txtNaMotivoCardLan').Visibility)" -eq 'Visible' -and
        "$($w.FindName('txtNaMotivoCardLan').Text)" -match 'sem ponto de rede') {
        Write-Host "[4f] 'Registrar' fecha o card e o motivo aparece no card LAN (inviavel)"
    } else { Write-Host "    FALHA: registrar NA (chave=$($Global:MeiosNaoAplicaveis.ContainsKey('lan')) card=$($w.FindName('cardNaJustif').Visibility) motivo='$($w.FindName('txtNaMotivoCardLan').Text)')"; $falhas++ }

    # 4g. Fase 2 sem VPN: a saida "nao consegui conectar a VPN" + motivo registra o meio; depois limpa
    #    (LAN NA + Celular testado -> a vez agora e do Wi-Fi, apos desmarca-lo)
    $Global:VpnSimulada = $false
    $w.FindName('chkNaWifi').IsChecked = $false ; Update-NaoAplicavelMeio ; Invoke-Pump
    Select-MeioParaChecar 'wifi'   # a vez e do Wi-Fi (rede atual = Wi-Fi do local)
    if ($Global:MeioSelecionado -ne 'wifi') { Write-Host "    FALHA: a vez nao chegou ao Wi-Fi (sel='$($Global:MeioSelecionado)')"; $falhas++ }
    Invoke-CheckMeio 'wifi'
    Invoke-Pump
    Invoke-ChkAvancar   # Iniciar -> Fase 1
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump ; Start-Sleep -Milliseconds 120
        if ($Global:ChkFase -eq 'f2-pronto' -and $null -eq $Global:TarefaRedeState) { break }
    }
    Invoke-ChkAvancar   # Testar a VPN -> gate (VPN off)
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump ; Start-Sleep -Milliseconds 120
        if ("$($w.FindName('panelChkVpnGate').Visibility)" -eq 'Visible' -and $null -eq $Global:TarefaRedeState) { break }
    }
    if ("$($w.FindName('panelChkVpnGate').Visibility)" -eq 'Visible' -and "$($w.FindName('btnChkVpnImpossivel').Visibility)" -eq 'Visible') {
        Write-Host "[4g] Fase 2 sem VPN: aparece o gate + 'registrar sem a VPN'"
    } else { Write-Host "    FALHA: gate de VPN nao apareceu (gate=$($w.FindName('panelChkVpnGate').Visibility))"; $falhas++ }
    $w.FindName('chkVpnImpossivel').IsChecked = $true ; Update-VpnImpossivel
    $w.FindName('txtVpnMotivo').Text = 'FortiClient corrompido; sem internet no local para reinstalar.'
    Invoke-CheckVpnImpossivel
    Invoke-Pump
    $medWifi = @($Global:Medicoes | Where-Object { $_.meio -eq 'wifi_local' -and -not $_.nao_aplicavel } | Select-Object -First 1)
    if ($medWifi -and $medWifi.vpn_conectou -eq $false -and $medWifi.veredito -eq 'inviavel') {
        Write-Host "[4g] meio Wi-Fi registrado sem a VPN -> inviavel"
    } else { Write-Host "    FALHA: medicao Wi-Fi sem VPN (med=$([bool]$medWifi) vpn=$($medWifi.vpn_conectou) ver=$($medWifi.veredito))"; $falhas++ }
    Close-OverlayCheck
    $w.FindName('chkVpnImpossivel').IsChecked = $false ; Update-VpnImpossivel
    $Global:VpnSimulada = $true
    # volta ao meio unico (celular) p/ o restante do teste seguir igual: solta os NA
    # de LAN/Wi-Fi (marcados no 4d/4f) e descarta as medicoes que nao sao do celular
    $Global:MeiosNaoAplicaveis.Remove('lan')
    $Global:MeiosNaoAplicaveis.Remove('wifi_local')
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { $_.meio -eq 'celular' -and -not $_.nao_aplicavel })
    $Global:MeioSelecionado = ''
    Show-MedicaoNoPasso5 -Par ([pscustomobject]@{ idx = 0; med = @($Global:Medicoes)[0] })
    Invoke-Pump

    # 4h. passo 3 -> 4 (resultado por metrica)
    Invoke-WizardProximo
    Invoke-Pump
    if ($Global:WizardStep -ne 4) { Write-Host "    FALHA: nao foi para o passo 4 (resultado) (step=$($Global:WizardStep))"; $falhas++ }
    else { Write-Host "[4h] passo 3 -> 4 (resultado por metrica)" }
    $nVpn = @($w.FindName('dgAvaliacaoVpn').ItemsSource).Count
    $nRl  = @($w.FindName('dgAvaliacaoRl').ItemsSource).Count
    $nLinhas = @($Global:AvaliacaoRows).Count
    $decIni  = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    Write-Host "[5] passo 4: $nVpn linha(s) VPN + $nRl rede local = $nLinhas, decisao '$decIni'"
    # 6 linhas da Fase 2 (VPN) + 4 da Fase 1 (rede local, Speedtest ok no fixture;
    # perda_percentual desativada no SEM VPN -- v0.6.79, sonda de perda nao
    # suportada pelos servidores Ookla da regiao)
    if ($nVpn -ne 6 -or $nRl -ne 4 -or $nLinhas -ne 10) { Write-Host "    FALHA: cards do passo 4 (vpn=$nVpn rede_local=$nRl total=$nLinhas)"; $falhas++ }
    $rlRows = @($Global:AvaliacaoRows | Where-Object { $_.Fase -eq 'Rede local' })
    $rlDown = $rlRows | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    if ($rlRows.Count -eq 4 -and $rlDown -and "$($rlDown.ValorTexto)" -match '855') {
        Write-Host "[5] card da rede local (Fase 1): $($rlRows.Count) linhas, Download=$($rlDown.ValorTexto)"
    } else { Write-Host "    FALHA: linhas da rede local no passo 4 (n=$($rlRows.Count) down='$($rlDown.ValorTexto)')"; $falhas++ }
    if ("$($w.FindName('cardAvaliacaoRl').Visibility)" -eq 'Visible' -and "$($w.FindName('txtRedeLocalNota').Visibility)" -eq 'Visible') {
        Write-Host "[5] card + nota da rede local visiveis no passo 4"
    } else { Write-Host "    FALHA: card/nota da rede local (card=$($w.FindName('cardAvaliacaoRl').Visibility) nota=$($w.FindName('txtRedeLocalNota').Visibility))"; $falhas++ }
    if ($decIni -notin @('viavel', 'viavel_com_ressalva', 'inviavel')) { Write-Host "    FALHA: decisao nao classificou"; $falhas++ }

    # 5b. override de metrica + passo 4 -> 5 bloqueia sem justificativa
    $linha = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    $linha.ClasseFinal = 'viavel'
    Invoke-Pump
    Invoke-WizardProximo
    $ultimoLog = @($Global:LogEntries)[-1].Texto
    if ($Global:WizardStep -eq 4 -and $ultimoLog -match 'Justificativa obrigatoria') {
        Write-Host "[5b] passo 4 bloqueia override sem justificativa"
    } else { Write-Host "    FALHA: passo 4 avancou sem justificativa (step=$($Global:WizardStep))"; $falhas++ }

    # 5b-2. multi-meio: seletor de medicoes no passo 4 (resultado) (2+ meios testados)
    $medBase = @($Global:Medicoes)[-1]
    $medLan = [pscustomobject]@{
        meio = 'lan'; operadora = ''; rotulo = 'Rede cabeada (LAN)'
        nao_aplicavel = $false; motivo_na = ''
        fase_local = $medBase.fase_local; rede_local_ok = $true; rede_local_download = 120
        vpn_conectou = $true; vpn_motivo = ''; vpn_download = 40
        metricas = $medBase.metricas; fase2_ok = $true
        decisao = $medBase.decisao; iperf = $medBase.iperf; ambiente = $medBase.ambiente
        avaliacoes = @(); veredito = [string] $medBase.decisao.Classificacao; quando = (Get-Date).ToString('o')
    }
    $Global:Medicoes = @(@($Global:Medicoes) + $medLan)
    Show-WizardPasso 4
    Invoke-Pump
    $boxVis = "$($w.FindName('tabsMedicoes').Visibility)"
    $nOpc = @($w.FindName('tabsMedicoes').Items).Count
    if ($boxVis -eq 'Visible' -and $nOpc -eq 2) { Write-Host "[5b] multi-meio: abas de medicoes visiveis com $nOpc abas" }
    else { Write-Host "    FALHA: abas de medicoes do passo 4 (vis=$boxVis abas=$nOpc)"; $falhas++ }
    $idxAntes  = $Global:MedicaoPasso5Idx
    $selInicial = $w.FindName('tabsMedicoes').SelectedIndex
    $novoSel   = if ($selInicial -eq 0) { 1 } else { 0 }
    $w.FindName('tabsMedicoes').SelectedIndex = $novoSel
    Invoke-Pump
    if ($Global:MedicaoPasso5Idx -ne $idxAntes -and @($Global:AvaliacaoRows).Count -eq 10) {
        Write-Host "[5b] troca de medicao re-renderiza o grid (idx $idxAntes -> $($Global:MedicaoPasso5Idx))"
    } else { Write-Host "    FALHA: troca de medicao no passo 4 (idx=$($Global:MedicaoPasso5Idx) linhas=$(@($Global:AvaliacaoRows).Count))"; $falhas++ }
    $lnLan = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Latencia' } | Select-Object -First 1
    $lnLan.ClasseFinal = 'inviavel'; $lnLan.Justificativa = 'teste multi-meio'
    Invoke-Pump
    $outroSel = if ($novoSel -eq 0) { 1 } else { 0 }
    $w.FindName('tabsMedicoes').SelectedIndex = $outroSel ; Invoke-Pump
    $w.FindName('tabsMedicoes').SelectedIndex = $novoSel ; Invoke-Pump
    $lnLan2 = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Latencia' } | Select-Object -First 1
    if ("$($lnLan2.ClasseFinal)" -eq 'inviavel' -and "$($lnLan2.Justificativa)" -eq 'teste multi-meio') {
        Write-Host "[5b] ajuste por medicao persiste ao alternar no seletor"
    } else { Write-Host "    FALHA: ajuste da medicao nao persistiu (cf='$($lnLan2.ClasseFinal)' just='$($lnLan2.Justificativa)')"; $falhas++ }
    # limpa: volta ao meio unico e re-renderiza para o resto do teste seguir igual
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { $_.meio -ne 'lan' })
    $Global:MedicaoPasso5Idx = -1
    Show-MedicaoNoPasso5 -Par ([pscustomobject]@{ idx = 0; med = @($Global:Medicoes)[-1] })
    Invoke-Pump
    $linha = @($Global:AvaliacaoRows) | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    $linha.ClasseFinal = 'viavel'
    Invoke-Pump

    # 5c. com justificativa -> passo 4 -> 5
    $linha.Justificativa = 'Refiz o teste pelo celular e deu 25 Mbps.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 5) { Write-Host "    FALHA: nao foi para o passo 5 (decisao)"; $falhas++ }

    # 5c-2. passo 5: seletor da conexao recomendada + tabela de medicoes
    $optsRec = @($w.FindName('cboConexaoRec').ItemsSource)
    $selRec  = [string] $w.FindName('cboConexaoRec').SelectedItem
    if ($optsRec.Count -ge 1 -and $selRec) { Write-Host "[5c] passo 5: recomendacao pre-selecionada = '$selRec' ($($optsRec.Count) opcao/oes)" }
    else { Write-Host "    FALHA: combo da conexao recomendada vazio (opts=$($optsRec.Count) sel='$selRec')"; $falhas++ }
    $nMed = @($w.FindName('dgMedicoes').ItemsSource).Count
    if ($nMed -ge 1) { Write-Host "[5c] passo 5: tabela de medicoes com $nMed linha(s)" }
    else { Write-Host "    FALHA: tabela de medicoes vazia"; $falhas++ }

    # 5c-3. passo 5 -> 6 bloqueia sem o motivo da recomendacao
    $w.FindName('txtMotivoRec').Text = ''
    Invoke-Pump
    Invoke-WizardProximo
    $ultimoLog = @($Global:LogEntries)[-1].Texto
    if ($Global:WizardStep -eq 5 -and $ultimoLog -match 'motivo da recomendacao') {
        Write-Host "[5c] passo 5 bloqueia sem o motivo da recomendacao"
    } else { Write-Host "    FALHA: passo 5 avancou sem o motivo (step=$($Global:WizardStep))"; $falhas++ }

    # 5c-4. com o motivo -> passo 6 (conclusao)
    $w.FindName('txtMotivoRec').Text = 'Cabo nao alcanca a sala; melhor download foi pelo celular Vivo.'
    Invoke-Pump
    Invoke-WizardProximo
    if ($Global:WizardStep -ne 6) { Write-Host "    FALHA: nao foi para o passo 6 com o motivo"; $falhas++ }
    else { Write-Host "[5c] passos 5->6->7 (com justificativa + motivo da recomendacao)" }

    # 5d. passo 6: salva o resultado -> checklist "Salvar" fica verde, "Transmitir" habilita
    $antesJson = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter *.json -EA SilentlyContinue).Count
    Invoke-SalvarResultado
    $novos = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter *.json -EA SilentlyContinue)
    if ($novos.Count -le $antesJson) { Write-Host "    FALHA: nao gravou o JSON"; $falhas++ }
    else {
        $doc = Get-Content ($novos | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $linhaAlt = $doc.avaliacao | Where-Object { $_.ajustada } | Select-Object -First 1
        $okDoc = ($doc.tecnico.nome) -and ($doc.classificacao.final) -and $linhaAlt -and $linhaAlt.justificativa
        Write-Host "[5d] salvo: tecnico='$($doc.tecnico.nome)' final='$($doc.classificacao.final)' ajustada='$($linhaAlt.metrica)'->'$($linhaAlt.classe_final)'"
        if (-not $okDoc) { Write-Host "    FALHA: JSON incompleto"; $falhas++ }
        $rl = $doc.rede_local
        if ($rl -and $rl.ip_local -eq '192.168.15.42' -and $rl.gateway -eq '192.168.15.1' -and $rl.host -eq 'NB-TESTE-01' -and
            @($rl.wireless_redes).Count -ge 1 -and $rl.speedtest_ok -eq $true -and $rl.internet_provedor -eq 'BARREIRAS NET' -and
            [double] $rl.internet_download_mbps -gt 800 -and "$($rl.internet_resultado_url)" -match 'speedtest') {
            Write-Host "[5d] JSON traz rede_local: host=$($rl.host) ip=$($rl.ip_local) provedor=$($rl.internet_provedor) down=$($rl.internet_download_mbps) up=$($rl.internet_upload_mbps)"
        } else { Write-Host "    FALHA: JSON sem bloco rede_local completo (host='$($rl.host)' provedor='$($rl.internet_provedor)' down='$($rl.internet_download_mbps)')"; $falhas++ }
        if ($rl.tethering_celular -eq $true -and $rl.operadora -eq 'Vivo') {
            Write-Host "[5d] rede_local traz o tethering: operadora=$($rl.operadora)"
        } else { Write-Host "    FALHA: rede_local sem tethering/operadora (t=$($rl.tethering_celular) op='$($rl.operadora)')"; $falhas++ }
        if ($doc.vpn -and $doc.vpn.impossivel -eq $false) { Write-Host "[5d] JSON traz bloco vpn (impossivel=false neste teste)" }
        else { Write-Host "    FALHA: JSON sem bloco vpn"; $falhas++ }
        $rec = $doc.conexao_recomendada
        if ($rec -and $rec.rotulo -and $rec.veredito -and $rec.motivo -match 'celular' -and @($doc.medicoes).Count -ge 1) {
            Write-Host "[5d] JSON traz conexao_recomendada='$($rec.rotulo)' veredito='$($rec.veredito)' base='$($rec.base)' + $(@($doc.medicoes).Count) medicao(oes)"
        } else { Write-Host "    FALHA: JSON sem conexao_recomendada/medicoes (rotulo='$($rec.rotulo)' motivo='$($rec.motivo)' meds=$(@($doc.medicoes).Count))"; $falhas++ }
        if ("$($doc.classificacao.final)" -eq "$($rec.veredito)") { Write-Host "[5d] decisao final do local = veredito do meio recomendado ('$($doc.classificacao.final)')" }
        else { Write-Host "    FALHA: classificacao.final ('$($doc.classificacao.final)') != veredito recomendado ('$($rec.veredito)')"; $falhas++ }
        $htmlRel = New-RelatorioHtml -Resultado $doc
        if ($htmlRel -match 'Painel de Viabilidade de Conectividade' -and $htmlRel -match 'Situa&ccedil;&atilde;o por meio' -and
            $htmlRel -match 'Testes de comunica&ccedil;&atilde;o por meio' -and $htmlRel -match 'A4 landscape' -and
            $htmlRel -match 'Conex&atilde;o recomendada' -and $htmlRel -match 'Conclus&atilde;o do diagn&oacute;stico') {
            Write-Host "[5d] relatorio HTML: painel de viabilidade (paisagem) + testes por meio + conclusao"
        } else { Write-Host "    FALHA: relatorio HTML sem o painel/estrutura nova"; $falhas++ }
    }
    $vok = [char]0x2713
    if ($Global:FeitoSalvar -and "$($w.FindName('chkFimSalvar').Text)" -eq $vok -and $w.FindName('btnTransmitirResultado').IsEnabled -and "$($w.FindName('chkFimTransmitir').Text)" -ne $vok) {
        Write-Host "[5d] checklist: Salvar=OK, Transmitir habilitado e pendente"
    } else { Write-Host "    FALHA: checklist do passo 6 (salvar=$($Global:FeitoSalvar) transmitir.en=$($w.FindName('btnTransmitirResultado').IsEnabled))"; $falhas++ }
    if (-not $w.FindName('btnFinalizarDiag').IsEnabled) { Write-Host "[5d] 'Finalizar' ainda travado (falta exportar o PDF)" }
    else { Write-Host "    FALHA: 'Finalizar' liberou so com Salvar (sem Exportar)"; $falhas++ }

    # 5d-2. exporta o relatorio pelo botao -> checklist "Exportar" fica verde
    Invoke-ExportarRelatorio
    if ($Global:FeitoExportar -and "$($w.FindName('chkFimExportar').Text)" -eq $vok -and "$($w.FindName('txtFimStatus').Text)" -match 'Relatorio salvo') {
        Write-Host "[5d] relatorio exportado ($($w.FindName('txtFimStatus').Text))"
    } else { Write-Host "    FALHA: export nao marcou o checklist (exportar=$($Global:FeitoExportar))"; $falhas++ }

    # 5d-3. "Finalizar" so habilita apos Salvar + Exportar (Transmitir pode ficar pendente)
    if ($w.FindName('btnFinalizarDiag').IsEnabled) { Write-Host "[5d] botao 'Finalizar' habilitado (salvo + exportado)" }
    else { Write-Host "    FALHA: 'Finalizar' desabilitado com resultado salvo + exportado"; $falhas++ }
    Invoke-FinalizarDiagnostico
    if ("$($w.FindName('viewHome').Visibility)" -eq 'Visible') { Write-Host "[5d] 'Finalizar' -> volta para a tela inicial" }
    else { Write-Host "    FALHA: 'Finalizar' nao voltou para a home (viewHome=$($w.FindName('viewHome').Visibility))"; $falhas++ }
    # 5d-4. 'Finalizar' tambem destrava o rail (saiu do assistente)
    if ($w.FindName('navLocais').IsEnabled -and $w.FindName('btnTrocarUsuario').IsEnabled -and -not $Global:RailTravadoDiag) {
        Write-Host "[5d] rail destravado depois de 'Finalizar'"
    } else { Write-Host "    FALHA: rail continuou travado apos 'Finalizar' (RailTravadoDiag=$Global:RailTravadoDiag)"; $falhas++ }
    Show-WizardPasso 6   # volta ao passo 6 (conclusao) para os proximos testes seguirem

    # 5e. acompanhamento: guia marca o local como testado; home mostra progresso
    Show-GuiaBordo
    $grpT = @($w.FindName('lstGuiaJuntas').ItemsSource)[0]
    $locT = @($grpT.locais) | Where-Object { $_.id -eq 'ZE99-TESTE-PRINCIPAL' } | Select-Object -First 1
    if ($locT -and "$($locT.TesteStatus)" -match 'Testado' -and "$($locT.BotaoRodar)" -match 'Refazer' -and $locT.Testado -eq $true) {
        Write-Host "[5e] guia marca o local como testado: '$($locT.TesteStatus)'"
    } else {
        Write-Host "    FALHA: guia nao marcou o local como testado (status='$($locT.TesteStatus)' Testado=$($locT.Testado))"; $falhas++
    }
    # so o Principal foi testado (Contingencia ainda nao) -> cartao da ZE ainda nao fica verde
    if ($grpT.TodasTestadas -eq $false) { Write-Host "[5e] cartao da ZE ainda nao 'concluida' (falta a contingencia)" }
    else { Write-Host "    FALHA: TodasTestadas deveria ser false (so o principal foi testado)"; $falhas++ }
    $prog = Get-ProgressoRoteiro -Roteiro $Global:RoteiroAtual -TecnicoNome 'TECNICO HEADLESS'
    if ($prog.Testados -eq 1 -and $prog.Total -eq 2) { Write-Host "[5e] progresso do roteiro: $($prog.Testados)/$($prog.Total)" }
    else { Write-Host "    FALHA: progresso $($prog.Testados)/$($prog.Total) (esperado 1/2)"; $falhas++ }

    # 5f. "abrir relatorio completo" na tela do Local: anexa GEL + foto DEPOIS do
    # teste e regenera o PDF a partir do resultado salvo (via Invoke-AbrirRelatorioLocal)
    $Global:LocalDetalheAtual = [pscustomobject]@{ id = 'ZE99-TESTE-PRINCIPAL'; nome = 'LOCAL PRINCIPAL DE TESTE' }
    Save-VistoriaGel -LocalId 'ZE99-TESTE-PRINCIPAL' -Dados ([pscustomobject]@{
        lat = -2.5; long = -43.25; precisao_m = 5; esfera_administrativa = 'Estadual'
        suporte_nome = 'ACME'; eletrica_tensao = '220 volts'; eletrica_tomadas = '4'
    }) | Out-Null
    Add-Type -AssemblyName PresentationCore
    $pngF = Join-Path $env:TEMP ('ld-{0}.png' -f (Get-Random))
    $wbF = New-Object Windows.Media.Imaging.WriteableBitmap 20, 20, 96, 96, ([Windows.Media.PixelFormats]::Bgr32), $null
    $encF = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encF.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($wbF))
    $fsF = [IO.File]::Create($pngF); try { $encF.Save($fsF) } finally { $fsF.Dispose() }
    Add-FotoGel -LocalId 'ZE99-TESTE-PRINCIPAL' -Caminho $pngF | Out-Null
    Remove-Item $pngF -Force -ErrorAction SilentlyContinue

    Update-StatusLocalDetalhe
    $btnRel = $w.FindName('btnLdRelatorio')
    if ($btnRel -and $btnRel.IsEnabled) { Write-Host "[5f] 'Abrir relatorio' habilitado (local ja testado)" }
    else { Write-Host "    FALHA: botao 'Abrir relatorio' deveria estar habilitado"; $falhas++ }
    Invoke-AbrirRelatorioLocal
    Invoke-Pump
    $relTxt = [string] $w.FindName('txtLdRelatStatus').Text
    if ($relTxt -match 'Relatorio:' -and (Test-Path ($relTxt -replace '^Relatorio:\s*', ''))) {
        Write-Host "[5f] relatorio do local gerado a partir do resultado salvo ($(Split-Path ($relTxt -replace '^Relatorio:\s*','') -Leaf))"
    } else { Write-Host "    FALHA: 'Abrir relatorio do local' (status='$relTxt')"; $falhas++ }
    Remove-VistoriaGel -LocalId 'ZE99-TESTE-PRINCIPAL'
    $Global:LocalDetalheAtual = $null

    # m. modo de avaliacao 'medicao' (padrao de fabrica): assistente de 5 passos,
    #    sem veredito/faixa/classificacao; relatorio = "Painel de Medicoes".
    $Global:ModoAvaliacaoOverride = 'medicao'
    Set-ModoAssistente
    $passo5 = ($Global:WizardNPassos -eq 5) -and ($Global:WizardPassos -notcontains 'stepDecisao')
    if ($passo5) { Write-Host "[m] modo medicao: assistente de 5 passos (pula a decisao)" }
    else { Write-Host "    FALHA: assistente deveria ter 5 passos (n=$($Global:WizardNPassos) passos=$($Global:WizardPassos -join ','))"; $falhas++ }

    Open-DiagnosticoLimpo
    $cboJm = $w.FindName('cboJunta'); if ($cboJm.Items.Count) { $cboJm.SelectedIndex = 0 }
    $cboLm = $w.FindName('cboLocal'); if ($cboLm.Items.Count) { $cboLm.SelectedIndex = 0 }
    Show-WizardPasso ($Global:WizardPassos.IndexOf('stepResultado') + 1)
    $met = [pscustomobject]@{ LatenciaMediaMs = 12; JitterMs = 1; PerdaPercentual = 0; BandaDownloadMbps = 90; BandaUploadMbps = 30; CarregamentoWebS = 3 }
    $dec = Invoke-MotorDecisao -Metricas $met -Limiares (Get-PerfilLimiares -Meio lan -Cenario com_vpn)
    $Global:Medicoes = @([pscustomobject]@{
            meio = 'lan'; operadora = ''; rotulo = 'Rede cabeada (LAN)'; nao_aplicavel = $false
            fase_local = $Global:FaseLocalPayload; rede_local_ok = $true; rede_local_download = 850
            vpn_conectou = $true; vpn_motivo = ''; vpn_download = 90; metricas = $met; fase2_ok = $true
            decisao = $dec; avaliacoes = @(); veredito = 'medido'; quando = (Get-Date).ToString('o') })
    Show-PainelResultado -Payload ([pscustomobject]@{ Ambiente = (Get-EstadoAmbiente); Metricas = $met; Decisao = $dec; Local = $cboLm.SelectedItem.Dados })
    Invoke-Pump
    $colClasse = "$($w.FindName('colVpnClasse').Visibility)"
    $colFaixaM = "$($w.FindName('colVpnFaixa').Visibility)"
    $ver0 = "$($w.FindName('dgAvaliacaoVpn').Items[0].ClasseFinal)"
    if ($colClasse -eq 'Collapsed' -and $colFaixaM -eq 'Collapsed' -and $ver0 -eq '') {
        Write-Host "[m] passo 4: sem colunas de faixa/classificacao, sem veredito na linha"
    } else { Write-Host "    FALHA: passo 4 (colClasse=$colClasse colFaixa=$colFaixaM ver='$ver0')"; $falhas++ }
    # avanca do stepResultado -> deve cair no stepFim (nao stepDecisao)
    Invoke-WizardProximo
    if ($Global:WizardPassos[$Global:WizardStep - 1] -eq 'stepFim') { Write-Host "[m] passo 4 -> conclusao (pula a decisao)" }
    else { Write-Host "    FALHA: nao pulou a decisao (step=$($Global:WizardStep) painel=$($Global:WizardPassos[$Global:WizardStep-1]))"; $falhas++ }

    # modo 'referencia': aparece a faixa, mas nao a classificacao
    $Global:ModoAvaliacaoOverride = 'referencia'
    Show-PainelResultado -Payload ([pscustomobject]@{ Ambiente = (Get-EstadoAmbiente); Metricas = $met; Decisao = $dec; Local = $cboLm.SelectedItem.Dados })
    Invoke-Pump
    if ("$($w.FindName('colVpnFaixa').Visibility)" -eq 'Visible' -and "$($w.FindName('colVpnClasse').Visibility)" -eq 'Collapsed') {
        Write-Host "[m] modo referencia: faixa visivel, classificacao oculta"
    } else { Write-Host "    FALHA: modo referencia (faixa=$($w.FindName('colVpnFaixa').Visibility) classe=$($w.FindName('colVpnClasse').Visibility))"; $falhas++ }

    # JSON + relatorio no modo medicao
    $Global:ModoAvaliacaoOverride = 'medicao'
    $recM = Get-ConexaoRecomendada @($Global:Medicoes) -Modo medicao
    $docM = New-ResultadoJson -Ambiente (Get-EstadoAmbiente) -Metricas $met -Decisao $dec `
        -Local $cboLm.SelectedItem.Dados -TecnicoNome 'TESTE' -FaseLocal $Global:FaseLocalPayload `
        -Medicoes $Global:Medicoes -ConexaoRecomendada $recM
    $htmlM = New-RelatorioHtml -Resultado $docM
    if ($docM.modo_avaliacao -eq 'medicao' -and $htmlM -match 'Painel de Medi' -and $htmlM -notmatch 'Painel de Viabilidade') {
        Write-Host "[m] JSON traz modo_avaliacao='medicao'; relatorio = Painel de Medicoes (sem Painel de Viabilidade)"
    } else { Write-Host "    FALHA: json/relatorio modo medicao (modo=$($docM.modo_avaliacao))"; $falhas++ }

    $Global:ModoAvaliacaoOverride = 'completo'   # [6]..[9] cobrem o modo completo
    Reset-Medicoes
    Clear-PainelResultado

    # 6. menu Inicio -> assistente abre limpo no passo 1
    Open-DiagnosticoLimpo
    $selLimpo    = $w.FindName('cboLocal').SelectedItem
    $painelLimpo = (@($w.FindName('dgAvaliacaoVpn').Items).Count -eq 0) -and (@($w.FindName('dgAvaliacaoRl').Items).Count -eq 0) -and ($null -eq $Global:DiagPayload)
    $faseLimpa   = ($null -eq $Global:FaseLocalPayload) -and ($w.FindName('cardFaseLocal').Visibility -ne 'Visible')
    if ($selLimpo -or $Global:LogEntries.Count -ne 0 -or -not $painelLimpo -or -not $faseLimpa -or $Global:WizardStep -ne 1) {
        Write-Host "[6] FALHA: nao abriu limpo (sel=$([bool]$selLimpo) log=$($Global:LogEntries.Count) painelVpn=$(@($w.FindName('dgAvaliacaoVpn').Items).Count) payload=$($null -ne $Global:DiagPayload) fase=$($null -ne $Global:FaseLocalPayload) step=$($Global:WizardStep))"
        $falhas++
    } else { Write-Host "[6] Assistente pelo menu abre limpo no passo 1 (rede local zerada)" }

    # 6b. passo 2 com local JA testado: some "Proximo", aparece "Refazer o teste"
    Show-WizardPasso 2
    $cboJ6 = $w.FindName('cboJunta'); if ($cboJ6.Items.Count) { $cboJ6.SelectedIndex = 0 }
    $cboL6 = $w.FindName('cboLocal')
    $liP = @($cboL6.Items) | Where-Object { $_.Dados.id -eq 'ZE99-TESTE-PRINCIPAL' } | Select-Object -First 1
    $liC = @($cboL6.Items) | Where-Object { $_.Dados.id -eq 'ZE99-TESTE-CONTINGENCIA' } | Select-Object -First 1
    $cboL6.SelectedItem = $liC; Invoke-Pump          # nao testado
    $cboL6.SelectedItem = $liP; Invoke-Pump          # testado no passo 5d
    $refV  = "$($w.FindName('btnRefazerTeste').Visibility)"
    $proxV = "$($w.FindName('btnWizProximo').Visibility)"
    if ($refV -eq 'Visible' -and $proxV -ne 'Visible') { Write-Host "[6b] local testado: 'Refazer o teste' no card, sem 'Proximo'" }
    else { Write-Host "    FALHA: nav passo 2 p/ testado (refazer=$refV proximo=$proxV)"; $falhas++ }
    $cboL6.SelectedItem = $liC; Invoke-Pump          # volta para nao testado
    if ("$($w.FindName('btnWizProximo').Visibility)" -eq 'Visible' -and "$($w.FindName('btnRefazerTeste').Visibility)" -ne 'Visible') { Write-Host "[6b] local nao testado: 'Proximo' de volta" }
    else { Write-Host "    FALHA: nav nao voltou p/ nao testado"; $falhas++ }
    $cboL6.SelectedItem = $liP; Invoke-Pump
    Invoke-WizardProximo                              # o handler de 'Refazer o teste'
    if ($Global:WizardStep -eq 3) { Write-Host "[6b] 'Refazer o teste' -> passo 3 (rede local)" }
    else { Write-Host "    FALHA: refazer nao foi ao passo 3 (step=$($Global:WizardStep))"; $falhas++ }

    # 7. trocar usuario
    Invoke-TrocarUsuario
    if ($w.FindName('viewLogin').Visibility -ne 'Visible') { Write-Host "[7] FALHA: 'trocar usuario' nao voltou ao login"; $falhas++ }
    else { Write-Host "[7] Trocar usuario -> login OK" }

    # 8. admin: tela de limiares (sem POST real)
    Set-Sessao -TecnicoNome $Global:AdminNome -Papel 'admin' | Out-Null
    Enter-Home -Sessao (Get-Sessao)
    if ($w.FindName('btnMenuAdmin').Visibility -ne 'Visible') { Write-Host "[8] FALHA: botao Administracao nao aparece para admin"; $falhas++ }
    if ($w.FindName('chkTodasJuntas').Visibility -ne 'Collapsed') { Write-Host "    FALHA: checkbox 'incluir Juntas fora da rota' deveria estar oculto"; $falhas++ }
    else { Write-Host "[8] checkbox 'incluir Juntas fora da rota' oculto (desativado por ora)" }
    Show-Admin
    $nLan = $w.FindName('dgLimLan').Items.Count
    $nWifi = $w.FindName('dgLimWifi').Items.Count
    $nCel = $w.FindName('dgLimCel').Items.Count
    Write-Host "[8] Admin: 3 abas de limiar (LAN=$nLan / Wi-Fi=$nWifi / Celular=$nCel linhas)"
    if ($nLan -ne 6 -or $nWifi -ne 6 -or $nCel -ne 6) { Write-Host "    FALHA: cada aba deveria ter 6 metricas"; $falhas++ }
    if ($Global:LimiarRowsLan[0].SemVpnAtivo -ne $true -or $Global:LimiarRowsLan[0].ComVpnAtivo -ne $true) {
        Write-Host "    FALHA: limiar LAN sem 'Na bateria' marcado por padrao"; $falhas++
    } else { Write-Host "[8] limiar vem com 'Na bateria' (SEM e COM VPN) marcado" }
    # carregamento web (linha 6) so existe COM VPN
    $rWeb = $Global:LimiarRowsLan[5]
    if ("$($rWeb.Metrica)" -eq 'carregamento_web_s' -and -not $rWeb.SemVpnVisivel -and $rWeb.SemVpnAtivo -eq $false) {
        Write-Host "[8] carregamento web fica so na coluna COM VPN"
    } else { Write-Host "    FALHA: carregamento web deveria ser so COM VPN (vis=$($rWeb.SemVpnVisivel) at=$($rWeb.SemVpnAtivo))"; $falhas++ }
    # LAN: SEM VPN != COM VPN (custo da VPN)
    if ("$($Global:LimiarRowsLan[0].SemVpnIdeal)" -ne "$($Global:LimiarRowsLan[0].ComVpnIdeal)") {
        Write-Host "[8] LAN: COM VPN diferente do SEM VPN (lat ideal $($Global:LimiarRowsLan[0].SemVpnIdeal) -> $($Global:LimiarRowsLan[0].ComVpnIdeal))"
    } else { Write-Host "    FALHA: LAN COM VPN igual ao SEM VPN"; $falhas++ }
    # Wi-Fi herda da LAN + folga: read-only + folga visivel + valor = LAN + folga
    $wLat = $Global:LimiarRowsWifi[0]
    if ($wLat.FolgaVisivel -and -not $wLat.CamposEditaveis -and "$($wLat.Folga)" -ne '' -and
        [double]("$($wLat.SemVpnIdeal)" -replace ',', '.') -eq ([double]("$($Global:LimiarRowsLan[0].SemVpnIdeal)" -replace ',', '.') + [double]("$($wLat.Folga)" -replace ',', '.'))) {
        Write-Host "[8] Wi-Fi do local herda da LAN + folga (lat $($Global:LimiarRowsLan[0].SemVpnIdeal) + $($wLat.Folga) = $($wLat.SemVpnIdeal), so leitura)"
    } else { Write-Host "    FALHA: Wi-Fi nao herdou da LAN + folga (folgaVis=$($wLat.FolgaVisivel) edit=$($wLat.CamposEditaveis) folga=$($wLat.Folga) ideal=$($wLat.SemVpnIdeal))"; $falhas++ }
    # Celular tem perfil proprio (SMP != SCM)
    if ("$($Global:LimiarRowsCel[0].SemVpnLimite)" -ne "$($Global:LimiarRowsLan[0].SemVpnLimite)") {
        Write-Host "[8] Celular tem perfil proprio (lat limite $($Global:LimiarRowsCel[0].SemVpnLimite) vs LAN $($Global:LimiarRowsLan[0].SemVpnLimite))"
    } else { Write-Host "    FALHA: Celular igual a LAN"; $falhas++ }
    # "Recalcular COM VPN" a partir do orcamento
    $latComAntes = "$($Global:LimiarRowsLan[0].ComVpnIdeal)"
    $w.FindName('txtOrcLat').Text = '25'
    Invoke-AplicarOrcamento
    if ("$($Global:LimiarRowsLan[0].ComVpnIdeal)" -eq '45') {
        Write-Host "[8] 'Recalcular COM VPN': lat SEM VPN 20 + orcamento 25 = 45"
    } else { Write-Host "    FALHA: recalcular COM VPN (antes=$latComAntes depois=$($Global:LimiarRowsLan[0].ComVpnIdeal))"; $falhas++ }
    Show-Admin   # recarrega os valores do exemplo (desfaz o recalculo em memoria)
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarLimiares
    if ($w.FindName('lblAdminMsg').Text -notmatch 'PIN') { Write-Host "    FALHA: salvou limiares sem PIN"; $falhas++ }
    else { Write-Host "[8] salvar limiares sem PIN bloqueado" }

    # 8-2. Get-PerfilLimiares resolve os 6 perfis (meio x cenario)
    $pLanSem = Get-PerfilLimiares -Meio lan -Cenario sem_vpn
    $pLanCom = Get-PerfilLimiares -Meio lan -Cenario com_vpn
    $pWifiSem = Get-PerfilLimiares -Meio wifi_local -Cenario sem_vpn
    $pCelCom = Get-PerfilLimiares -Meio celular -Cenario com_vpn
    if ($pLanSem.latencia_ms.ressalva_ate -eq 80 -and $pLanCom.latencia_ms.ressalva_ate -eq 110 -and
        $pWifiSem.latencia_ms.viavel_ate -eq ($pLanSem.latencia_ms.viavel_ate + 10) -and
        $pCelCom.latencia_ms.ressalva_ate -eq 130 -and
        $pLanSem.carregamento_web_s.ativo -eq $false -and $pLanCom.carregamento_web_s.ativo -eq $true) {
        Write-Host "[8] Get-PerfilLimiares: LAN sem/com VPN + Wi-Fi=LAN+folga + Celular proprio + web so COM VPN"
    } else { Write-Host "    FALHA: Get-PerfilLimiares (lanSem=$($pLanSem.latencia_ms.ressalva_ate) lanCom=$($pLanCom.latencia_ms.ressalva_ate) wifi=$($pWifiSem.latencia_ms.viavel_ate) celCom=$($pCelCom.latencia_ms.ressalva_ate))"; $falhas++ }

    # 8-3. cache no formato ANTIGO (Web App v1) NAO rebaixa os pisos nested do pacote
    $flatV1 = [pscustomobject]@{
        latencia_ms         = [pscustomobject]@{ viavel_ate = 60; ressalva_ate = 120; ativo = $true }
        jitter_ms           = [pscustomobject]@{ viavel_ate = 10; ressalva_ate = 30;  ativo = $true }
        perda_percentual    = [pscustomobject]@{ viavel_ate = 1;  ressalva_ate = 5;   ativo = $true }
        banda_download_mbps = [pscustomobject]@{ viavel_min = 20; ressalva_min = 8;   ativo = $true }
        banda_upload_mbps   = [pscustomobject]@{ viavel_min = 10; ressalva_min = 4;   ativo = $true }
        carregamento_web_s  = [pscustomobject]@{ viavel_ate = 5;  ressalva_ate = 12;  ativo = $true }
    }
    Write-CacheJson -Nome 'limiares.json' -Campo 'limiares' -Itens $flatV1 -Origem 'teste v1 antigo'
    $pLanSem2 = Get-PerfilLimiares -Meio lan -Cenario sem_vpn
    if ((Test-LimiaresNested (Get-LimiaresConfig)) -and $pLanSem2.latencia_ms.viavel_ate -eq 20 -and $pLanSem2.latencia_ms.ressalva_ate -eq 80) {
        Write-Host "[8] cache no formato antigo e ignorado - vale o config nested (LAN sem VPN lat 20/80, nao 60/120)"
    } else { Write-Host "    FALHA: cache antigo rebaixou os limiares (lat $($pLanSem2.latencia_ms.viavel_ate)/$($pLanSem2.latencia_ms.ressalva_ate))"; $falhas++ }
    Remove-Item (Join-Path $Global:RaizApp 'data\limiares.json') -Force -ErrorAction SilentlyContinue

    # 8b. ambiente iperf3: campos carregam da config e "Salvar ambiente" exige PIN
    $srvCfg = "$($w.FindName('txtIperfServidorCfg').Text)"
    if ($srvCfg -and "$($w.FindName('txtIperfPortaCfg').Text)" -match '\d') {
        Write-Host "[8b] admin carrega servidor iperf3: $srvCfg`:$($w.FindName('txtIperfPortaCfg').Text)"
    } else { Write-Host "    FALHA: campos do servidor iperf3 nao carregaram (srv='$srvCfg')"; $falhas++ }
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarAmbiente
    if ("$($w.FindName('lblAmbienteMsg').Text)" -match 'PIN') { Write-Host "[8b] salvar ambiente sem PIN bloqueado" }
    else { Write-Host "    FALHA: salvou ambiente sem PIN ('$($w.FindName('lblAmbienteMsg').Text)')"; $falhas++ }

    # 9. metrica desativada sai da bateria (motor)
    $limTest = [pscustomobject]@{
        latencia_ms         = [pscustomobject]@{ viavel_ate = 60; ressalva_ate = 120; ativo = $true }
        jitter_ms           = [pscustomobject]@{ viavel_ate = 10; ressalva_ate = 30;  ativo = $true }
        perda_percentual    = [pscustomobject]@{ viavel_ate = 1;  ressalva_ate = 5;   ativo = $true }
        banda_download_mbps = [pscustomobject]@{ viavel_min = 20; ressalva_min = 8;   ativo = $true }
        banda_upload_mbps   = [pscustomobject]@{ viavel_min = 10; ressalva_min = 4;   ativo = $true }
        carregamento_web_s  = [pscustomobject]@{ viavel_ate = 5;  ressalva_ate = 12;  ativo = $false }
    }
    $met = [pscustomobject]@{ LatenciaMediaMs = 10; JitterMs = 1; PerdaPercentual = 0; BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = $null }
    $dec = Invoke-MotorDecisao -Metricas $met -Limiares $limTest
    if (@($dec.Detalhes).Count -eq 5 -and (@($dec.MetricasDesativadas) -contains 'carregamento_web_s') -and $dec.Classificacao -eq 'viavel') {
        Write-Host "[9] metrica desativada fora da bateria (5 detalhes, decisao=viavel)"
    } else {
        Write-Host "    FALHA: motor c/ metrica desativada (detalhes=$(@($dec.Detalhes).Count) desat=$($dec.MetricasDesativadas -join ',') dec=$($dec.Classificacao))"; $falhas++
    }

    # 10. classificacao da falha do Speedtest (handshake da Ookla = dado do laudo)
    $fHand = Resolve-FalhaSpeedtest -Mensagem '[error] Configuration - Timeout was reached (TimeoutException)' -Tentativas 3 -SsidWifi 'Mobili-TREMA05' -SinalPct 66
    if ($fHand.tipo -eq 'handshake' -and $fHand.laudo -match 'link|Wi-Fi fraco' -and $fHand.laudo -match 'Mobili-TREMA05') {
        Write-Host "[10] 'Configuration - Timeout' -> tipo 'handshake' + frase de laudo (link fraco)"
    } else { Write-Host "    FALHA: classificacao handshake (tipo='$($fHand.tipo)' laudo='$($fHand.laudo)')"; $falhas++ }
    $fBlock = Resolve-FalhaSpeedtest -Mensagem 'Cannot resolve www.speedtest.net'
    $fUnk   = Resolve-FalhaSpeedtest -Mensagem 'algo esquisito aconteceu'
    if ($fBlock.tipo -eq 'bloqueio' -and $fUnk.tipo -eq 'desconhecido' -and -not $fUnk.laudo) {
        Write-Host "[10] falha de DNS -> 'bloqueio'; mensagem generica -> 'desconhecido' sem laudo"
    } else { Write-Host "    FALHA: classificacao bloqueio/desconhecido (b='$($fBlock.tipo)' u='$($fUnk.tipo)')"; $falhas++ }

    # 10b. fallback de servidor: parser da lista "speedtest --servers" (tabela + jsonl)
    $tabela = "  ID  Name                     Location          Country`n" +
        "====================================================================`n" +
        " 63579  PROFISSIONAL TELECOM     Mirassol d'Oeste  Brazil`n" +
        " 14924  DATALIG TELECOM          Sao Luis          Brazil`n" +
        " 72111  Mundonet Banda Larga     Sao Luis          Brazil`n"
    $ids1 = ConvertFrom-ListaServidoresSpeedtest -Texto $tabela
    $ids2 = ConvertFrom-ListaServidoresSpeedtest -Texto '{"type":"servers","servers":[{"id":111,"name":"A"},{"id":222},{"id":111}]}'
    if ("$($ids1 -join ',')" -eq '63579,14924,72111' -and "$($ids2 -join ',')" -eq '111,222') {
        Write-Host "[10] ConvertFrom-ListaServidoresSpeedtest le a tabela e o jsonl de servidores"
    } else { Write-Host "    FALHA: parser da lista de servidores (tabela='$($ids1 -join ',')' jsonl='$($ids2 -join ',')')"; $falhas++ }

    # 11. anexo do GEL: extrator + links de mapa + bloco no JSON/relatorio.
    # Layout REAL do PDF do GEL: a resposta vem ANTES do marcador " R. :" e o
    # rotulo "Coordenadas:" vem DEPOIS do valor. Acentos como o PDF entrega
    # (inclusive "eletrica" com acento precomposto).
    $fixGel = 'Sistema de Georreferenciamento Eleitoral Zona: 32 Tipo de local: Predio Externo ' +
        'HUMBERTO DE CAMPOS Municipio: Local: C. E. MANOEL DIAS DE SOUSA ' +
        '-2.4997476' + [char]0x00BA + ',-43.25344546' + [char]0x00BA + '. Precis' + [char]0x00E3 + 'o 6.558 Coordenadas: ' +
        'Selecione a esfera administrativa do local vistoriado Estadual R. : ' +
        'Localizacao Urbano R. : Tipo de local Escola R. : Observacoes: R. : ' +
        'Infraestrutura Quantidade de salas necessarias para funcionar como secao eleitoral? 1 R. : ' +
        'Ha abastecimento de agua? Sim R. : A climatizacao ou ventilacao e feita por: Ar condicionado R. : ' +
        'Ha ilumina' + [char]0x00E7 + [char]0x00E3 + 'o? Sim R. : ' +
        'Ha agua potavel disponivel para mesarias(os) e eleitoras(es)? Sim R. : ' +
        'O predio esta em reforma? Nao R. : ' +
        'Qual a configuracao de rede? DHCP R. : ' +
        'Qual o nome do tecnico ou empresa responsavel pelo suporte ao link local? suporte Tec 98 30421747 R. : ' +
        'Qual o telefone do tecnico ou empresa responsavel pelo suporte ao link local? OLNY TELECON R. : ' +
        'Instalacoes eletricas Localizacao do Quadro de Energia: Externo R. : Ha energia el' + [char]0x00E9 + 'trica? Sim R. : ' +
        'Ha quantas tomadas funcionando? 6 R. : Qual a tens' + [char]0x00E3 + 'o da rede el' + [char]0x00E9 + 'trica? 220 volts R. : ' +
        'Ha necessidade de extens' + [char]0x00E3 + 'o el' + [char]0x00E9 + 'trica? Sim R. : ' +
        'Qual o numero da unidade consumidora (UC) ou numero do poste ou numero do medidor? 3064-001367-9 R. :'
    $pg = ConvertFrom-VistoriaGel -Texto $fixGel
    if ([math]::Abs($pg.lat - (-2.4997476)) -lt 1e-6 -and [math]::Abs($pg.long - (-43.25344546)) -lt 1e-6 -and
        [math]::Abs([double] $pg.precisao_m - 6.558) -lt 1e-3 -and
        $pg.eletrica_tensao -match '220' -and $pg.eletrica_tomadas -eq '6' -and $pg.eletrica_extensao -match 'Sim' -and
        $pg.suporte_nome -match 'suporte Tec' -and $pg.suporte_telefone -match 'OLNY') {
        Write-Host "[11] ConvertFrom-VistoriaGel extrai coordenadas + eletrica + suporte do texto do GEL"
    } else { Write-Host "    FALHA: extrator do GEL (lat=$($pg.lat) long=$($pg.long) prec=$($pg.precisao_m) tensao='$($pg.eletrica_tensao)' tomadas='$($pg.eletrica_tomadas)' ext='$($pg.eletrica_extensao)' sup='$($pg.suporte_nome)'/'$($pg.suporte_telefone)')"; $falhas++ }
    if ($pg.esfera_administrativa -eq 'Estadual' -and $pg.localizacao -eq 'Urbano' -and $pg.tipo_local -eq 'Escola' -and
        $pg.salas_necessarias -eq '1' -and $pg.agua -eq 'Sim' -and $pg.climatizacao -match 'Ar cond' -and
        $pg.iluminacao -eq 'Sim' -and $pg.agua_potavel -eq 'Sim' -and $pg.predio_reforma -eq 'Nao' -and
        $pg.quadro_energia -eq 'Externo' -and $pg.energia_eletrica -eq 'Sim') {
        Write-Host "[11] ConvertFrom-VistoriaGel extrai tipo do local + infraestrutura + quadro de energia"
    } else { Write-Host "    FALHA: novas secoes do GEL (esfera='$($pg.esfera_administrativa)' loc='$($pg.localizacao)' tipo='$($pg.tipo_local)' salas='$($pg.salas_necessarias)' agua='$($pg.agua)' clima='$($pg.climatizacao)' ilum='$($pg.iluminacao)' potavel='$($pg.agua_potavel)' reforma='$($pg.predio_reforma)' quadro='$($pg.quadro_energia)' energia='$($pg.energia_eletrica)')"; $falhas++ }

    $lnkG = Get-LinkGoogleMaps -Lat -2.5 -Long -43.25
    $urlM = Get-UrlMapaEstatico -Lat -2.5 -Long -43.25 -Chave 'FAKE123'
    if ($lnkG -eq 'https://www.google.com/maps?q=-2.5,-43.25' -and $urlM -match 'staticmap' -and $urlM -match 'key=FAKE123' -and $urlM -match '-2.5,-43.25') {
        Write-Host "[11] links de mapa: Get-LinkGoogleMaps + Get-UrlMapaEstatico OK"
    } else { Write-Host "    FALHA: links de mapa (lnk='$lnkG' url='$urlM')"; $falhas++ }
    if ((Get-UrlMapaEstatico -Lat -2.5 -Long -43.25 -Chave '') -eq '') { Write-Host "[11] sem chave -> Get-UrlMapaEstatico vazio" }
    else { Write-Host "    FALHA: Get-UrlMapaEstatico deveria voltar vazio sem chave"; $falhas++ }

    # fotos do GEL: gera um PNG minimo, anexa via Add-FotoGel, confere round-trip
    Add-Type -AssemblyName PresentationCore
    $pngT = Join-Path $env:TEMP ('gelfoto-{0}.png' -f (Get-Random))
    $wbT = New-Object Windows.Media.Imaging.WriteableBitmap 24, 24, 96, 96, ([Windows.Media.PixelFormats]::Bgr32), $null
    $encT = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encT.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($wbT))
    $fspT = [IO.File]::Create($pngT); try { $encT.Save($fspT) } finally { $fspT.Dispose() }
    Add-FotoGel -LocalId 'X' -Caminho $pngT | Out-Null
    Add-FotoGel -LocalId 'X' -Caminho $pngT | Out-Null
    Remove-Item $pngT -Force -ErrorAction SilentlyContinue
    $fx = @(Get-FotosGel -LocalId 'X')
    if ($fx.Count -eq 2 -and (Split-Path $fx[0] -Leaf) -eq 'foto-01.jpg' -and (Split-Path $fx[1] -Leaf) -eq 'foto-02.jpg') {
        Write-Host "[11] Add-FotoGel/Get-FotosGel: 2 fotos numeradas (reduzidas p/ jpg)"
    } else { Write-Host "    FALHA: fotos do GEL ($($fx.Count): $(($fx | ForEach-Object { Split-Path $_ -Leaf }) -join ','))"; $falhas++ }
    Remove-FotoGel -LocalId 'X' -Nome 'foto-01.jpg'
    if (@(Get-FotosGel -LocalId 'X').Count -eq 1) { Write-Host "[11] Remove-FotoGel tira so a selecionada" }
    else { Write-Host "    FALHA: Remove-FotoGel"; $falhas++ }

    $g = [pscustomobject]@{
        lat = -2.4997476; long = -43.25344546; precisao_m = 6.558
        esfera_administrativa = 'Estadual'; localizacao = 'Urbano'; tipo_local = 'Escola'
        salas_necessarias = '1'; agua = 'Sim'; climatizacao = 'Ar condicionado'
        iluminacao = 'Sim'; agua_potavel = 'Sim'; predio_reforma = 'Nao'
        quadro_energia = 'Externo'; energia_eletrica = 'Sim'
        suporte_nome = 'OLNY TELECON'; suporte_telefone = '(98) 3042-1747'
        eletrica_tensao = '220 volts'; eletrica_tomadas = '6'; eletrica_extensao = 'Sim'
        mapa_link = (Get-LinkGoogleMaps -Lat -2.4997476 -Long -43.25344546)
    }
    $jsonGel = New-ResultadoJson -Local ([pscustomobject]@{ id = 'X'; nome = 'L'; zona_eleitoral = 24; municipio_sede = 'S'; municipio_termo = 'T'; tipo = 'contingencia'; endereco = 'R' }) `
        -TecnicoNome 'T' -Decisao ([pscustomobject]@{ Classificacao = 'inviavel'; Detalhes = @() }) -Metricas ([pscustomobject]@{}) -VistoriaGel $g
    $htmlGel = New-RelatorioHtml -Resultado $jsonGel
    if ($jsonGel.vistoria_gel -and [double] $jsonGel.vistoria_gel.latitude -eq -2.4997476 -and
        $jsonGel.vistoria_gel.suporte_nome -eq 'OLNY TELECON' -and $jsonGel.vistoria_gel.eletrica_tomadas -eq '6' -and
        $jsonGel.vistoria_gel.tipo_local.esfera_administrativa -eq 'Estadual' -and
        $jsonGel.vistoria_gel.infraestrutura.iluminacao -eq 'Sim' -and
        $jsonGel.vistoria_gel.eletrica.quadro_energia -eq 'Externo' -and $jsonGel.vistoria_gel.fotos -eq 1 -and
        $htmlGel -match 'Dados da vistoria \(importado do GEL\)' -and $htmlGel -match '-2.4997476' -and $htmlGel -match 'google.com/maps' -and
        $htmlGel -match 'Tipo do local' -and $htmlGel -match 'Infraestrutura' -and $htmlGel -match 'Quadro de energia' -and
        $htmlGel -match 'Registro fotogr&aacute;fico' -and $htmlGel -match '<img src="data:image/jpeg;base64,') {
        Write-Host "[11] JSON traz 'vistoria_gel' em secoes + contagem de fotos; relatorio agrupa secoes + embute as fotos"
    } else { Write-Host "    FALHA: JSON/relatorio do GEL (vg=$([bool]$jsonGel.vistoria_gel) fotos=$($jsonGel.vistoria_gel.fotos) html_infra=$($htmlGel -match 'Infraestrutura') html_foto=$($htmlGel -match 'Fotos da vistoria'))"; $falhas++ }
    Remove-VistoriaGel -LocalId 'X'

    # arquivo que nao e PDF -> erro (nao trava a GUI)
    try { Read-TextoPdf -Caminho $PSCommandPath; Write-Host "    FALHA: Read-TextoPdf devia falhar com nao-PDF"; $falhas++ }
    catch { Write-Host "[11] Read-TextoPdf com arquivo nao-PDF -> erro claro" }

    # round-trip real: se as DLLs do PdfPig estao no repo, constroi um PDF com o
    # proprio PdfPig, le de volta e confirma que ConvertFrom-VistoriaGel extrai.
    if (Get-CaminhoPdfLib) {
        try {
            Register-ResolucaoPdfLib -Pasta (Join-Path $Global:RaizApp 'lib\pdfpig')
            $pdfOut = Join-Path $env:TEMP ('dicon-teste-{0}.pdf' -f (Get-Random))
            $bld = New-Object UglyToad.PdfPig.Writer.PdfDocumentBuilder
            $pgB = $bld.AddPage([UglyToad.PdfPig.Content.PageSize]::A4)
            $fnt = $bld.AddTrueTypeFont([IO.File]::ReadAllBytes("$env:WINDIR\Fonts\arial.ttf"))
            [void] $pgB.AddText('Coordenadas: -2.4997476o,-43.25344546o. Precisao 6.558', 11,
                (New-Object UglyToad.PdfPig.Core.PdfPoint(50, 700)), $fnt)
            [IO.File]::WriteAllBytes($pdfOut, $bld.Build())
            $lido = Read-TextoPdf -Caminho $pdfOut
            Remove-Item $pdfOut -Force -ErrorAction SilentlyContinue
            $vgL = ConvertFrom-VistoriaGel -Texto $lido
            if ([math]::Abs($vgL.lat - (-2.4997476)) -lt 1e-6 -and [math]::Abs($vgL.long - (-43.25344546)) -lt 1e-6) {
                Write-Host "[11] PdfPig no repo: build -> Read-TextoPdf -> extrai coordenadas OK"
            } else { Write-Host "    FALHA: round-trip PdfPig (lat=$($vgL.lat) long=$($vgL.long))"; $falhas++ }
        } catch { Write-Host "    FALHA: PdfPig nao carregou sob o PS 5.1 -> $_"; $falhas++ }
    } else {
        Write-Host "[11] PdfPig ausente de lib\pdfpig\ - round-trip pulado (anexo do GEL avisa e degrada)"
    }
}
finally {
    $Global:PastaDadosOverride = $null
    $Global:FaseLocalSimulada  = $null
    $Global:VpnSimulada        = $null
    $Global:ModoAvaliacaoOverride = $null
    Remove-Item $dataDir -Recurse -Force -EA SilentlyContinue
    # remove os JSON de resultado criados por este teste
    Get-ChildItem $pendDir -Filter *.json -EA SilentlyContinue |
        Where-Object { $_.FullName -notin $pendAntes } |
        Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem (Join-Path $Global:RaizApp 'relatorios') -Filter '*.*' -EA SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force -EA SilentlyContinue
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: OK"; exit 0 }
else { Write-Host "RESULTADO: $falhas FALHA(S)"; exit 1 }
