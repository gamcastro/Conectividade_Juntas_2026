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
        ssid = ''; sinal_pct = $null; redes_disponiveis = @('JE-CAMPO', 'VIVO-2G')
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
    Invoke-VoltarAosLocais
    Invoke-Pump
    if ("$($w.FindName('viewLocais').Visibility)" -eq 'Visible' -and $w.FindName('dgLocais').SelectedIndex -lt 0) {
        Write-Host "[3b] 'voltar aos locais' retorna para a lista e limpa a selecao"
    } else { Write-Host "    FALHA: nao voltou para a lista de locais"; $falhas++ }
    Show-View 'viewHome'

    # 4. assistente pelo atalho do guia: abre no passo 1, Junta/Local pre-selecionados
    Start-DiagnosticoDoGuia -LocalId 'ZE99-TESTE-PRINCIPAL'
    Invoke-Pump
    if ($w.FindName('viewDiag').Visibility -ne 'Visible' -or $Global:WizardStep -ne 1) {
        Write-Host "[4] FALHA: nao abriu o assistente no passo 1 (step=$($Global:WizardStep))"; $falhas++
    }
    $selL = $w.FindName('cboLocal').SelectedItem
    if (-not $selL) { Write-Host "[4] FALHA: local nao pre-selecionado"; $falhas++ }
    else { Write-Host "[4] Assistente passo 1, local pre-selecionado: $($selL.Rotulo)" }

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

    # 4d. checagem de um meio (celular) pelo overlay: Fase 1 (Ookla) + Fase 2 (VPN)
    $Global:VpnSimulada = $true
    $Global:FaseLocalPayload.Wireless.conectado = $true      # rede Wi-Fi conectada
    $w.FindName('cboOperadoraCel').Text = 'Vivo'
    $Global:MeioSelecionado = '' ; Update-PainelMeios
    if (-not $w.FindName('btnCheckWifi').IsEnabled -and -not $w.FindName('btnCheckCelular').IsEnabled) {
        Write-Host "[4d] sem card selecionado -> nenhum 'Rodar checagem' habilitado"
    } else { Write-Host "    FALHA: botao habilitado sem selecao (wifi.en=$($w.FindName('btnCheckWifi').IsEnabled) cel.en=$($w.FindName('btnCheckCelular').IsEnabled))"; $falhas++ }
    Select-MeioParaChecar 'wifi'
    if ($w.FindName('btnCheckWifi').IsEnabled -and -not $w.FindName('btnCheckCelular').IsEnabled -and
        $Global:MeioSelecionado -eq 'wifi') {
        Write-Host "[4d] clicar no card WI-FI seleciona-o e libera so o seu botao"
    } else { Write-Host "    FALHA: selecao do card Wi-Fi (wifi.en=$($w.FindName('btnCheckWifi').IsEnabled) cel.en=$($w.FindName('btnCheckCelular').IsEnabled))"; $falhas++ }
    Select-MeioParaChecar 'celular'
    if ($w.FindName('btnCheckCelular').IsEnabled -and -not $w.FindName('btnCheckWifi').IsEnabled -and
        "$($w.FindName('txtWifiSelDica').Visibility)" -eq 'Visible') {
        Write-Host "[4d] clicar no card CELULAR troca a selecao -> Celular libera, Wi-Fi trava"
    } else { Write-Host "    FALHA: troca de selecao p/ Celular (cel.en=$($w.FindName('btnCheckCelular').IsEnabled) wifi.en=$($w.FindName('btnCheckWifi').IsEnabled))"; $falhas++ }
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
    $w.FindName('chkNaLan').IsChecked = $false ; Update-NaoAplicavelMeio ; Invoke-Pump
    if (-not $Global:MeiosNaoAplicaveis.ContainsKey('lan')) { Write-Host "[4f] desmarcar o checkbox remove o 'nao aplicavel'" }
    else { Write-Host "    FALHA: desmarcar nao removeu o NA"; $falhas++ }

    # 4g. Fase 2 sem VPN: a saida "nao consegui conectar a VPN" + motivo registra o meio; depois limpa
    $Global:VpnSimulada = $false
    Select-MeioParaChecar 'wifi'   # rede atual = Wi-Fi do local
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
    $Global:Medicoes = @(@($Global:Medicoes) | Where-Object { $_.meio -ne 'wifi_local' })   # volta ao meio unico (celular)
    $idxCel = [array]::IndexOf(@($Global:Medicoes), (@($Global:Medicoes | Where-Object { $_.meio -eq 'celular' })[0]))
    Show-MedicaoNoPasso5 -Par ([pscustomobject]@{ idx = $idxCel; med = @($Global:Medicoes | Where-Object { $_.meio -eq 'celular' })[0] })
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
    # 6 linhas da Fase 2 (VPN) + 5 da Fase 1 (rede local, Speedtest ok no fixture)
    if ($nVpn -ne 6 -or $nRl -ne 5 -or $nLinhas -ne 11) { Write-Host "    FALHA: cards do passo 4 (vpn=$nVpn rede_local=$nRl total=$nLinhas)"; $falhas++ }
    $rlRows = @($Global:AvaliacaoRows | Where-Object { $_.Fase -eq 'Rede local' })
    $rlDown = $rlRows | Where-Object { $_.Rotulo -eq 'Download' } | Select-Object -First 1
    if ($rlRows.Count -eq 5 -and $rlDown -and "$($rlDown.ValorTexto)" -match '855') {
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
    if ($Global:MedicaoPasso5Idx -ne $idxAntes -and @($Global:AvaliacaoRows).Count -eq 11) {
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
        if ($htmlRel -match 'Conex&atilde;o recomendada para este local' -and $htmlRel -match 'Meios de conex&atilde;o testados') {
            Write-Host "[5d] relatorio HTML traz o bloco de conexao recomendada + tabela de meios"
        } else { Write-Host "    FALHA: relatorio HTML sem os blocos multi-meio"; $falhas++ }
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
    $nLim = $w.FindName('dgLimiares').Items.Count
    Write-Host "[8] Admin: $nLim linha(s) de limiar"
    if ($nLim -ne 6) { Write-Host "    FALHA: deveria ter 6 metricas"; $falhas++ }
    if ($Global:LimiarRows[0].Ativo -ne $true) { Write-Host "    FALHA: limiar sem 'Na bateria' marcado por padrao"; $falhas++ }
    else { Write-Host "[8] limiar vem com 'Na bateria' marcado" }
    $w.FindName('txtPinAdmin').Password = ''
    Invoke-SalvarLimiares
    if ($w.FindName('lblAdminMsg').Text -notmatch 'PIN') { Write-Host "    FALHA: salvou limiares sem PIN"; $falhas++ }
    else { Write-Host "[8] salvar limiares sem PIN bloqueado" }

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

    # 11. anexo do GEL: extrator + links de mapa + bloco no JSON/relatorio
    $fixGel = 'Sistema de Georreferenciamento Eleitoral Zona: 24 Municipio: HUMBERTO DE CAMPOS ' +
        'Local: C. E. MANOEL DIAS DE SOUSA Coordenadas: -2.4997476' + [char]0x00BA + ',-43.25344546' + [char]0x00BA + '. Precisao 6.558 ' +
        'Localizacao do Quadro de Energia: R. : Externo Ha energia eletrica? R. : Sim ' +
        'Ha quantas tomadas funcionando? R. : 6 Qual a tensao da rede eletrica? R. : 220 volts ' +
        'Ha necessidade de extensao eletrica? R. : Sim Qual o numero da unidade consumidora (UC)? R. : 3064-001367-9 ' +
        'Qual o nome do tecnico ou empresa responsavel pelo suporte ao link local? R. : suporte Tec 98 30421747 ' +
        'Qual o telefone do tecnico ou empresa responsavel pelo suporte ao link local? R. : OLNY TELECON ' +
        'Qual o tempo de resposta do ping exaustivo utilizando o comando ping <endereco> -t? R. :'
    $pg = ConvertFrom-VistoriaGel -Texto $fixGel
    if ([math]::Abs($pg.lat - (-2.4997476)) -lt 1e-6 -and [math]::Abs($pg.long - (-43.25344546)) -lt 1e-6 -and
        [math]::Abs([double] $pg.precisao_m - 6.558) -lt 1e-3 -and
        $pg.eletrica_tensao -match '220' -and $pg.eletrica_tomadas -eq '6' -and $pg.eletrica_extensao -match 'Sim' -and
        $pg.suporte_nome -match 'suporte Tec' -and $pg.suporte_telefone -match 'OLNY') {
        Write-Host "[11] ConvertFrom-VistoriaGel extrai coordenadas + eletrica + suporte do texto do GEL"
    } else { Write-Host "    FALHA: extrator do GEL (lat=$($pg.lat) long=$($pg.long) prec=$($pg.precisao_m) tensao='$($pg.eletrica_tensao)' tomadas='$($pg.eletrica_tomadas)' ext='$($pg.eletrica_extensao)' sup='$($pg.suporte_nome)'/'$($pg.suporte_telefone)')"; $falhas++ }

    $lnkG = Get-LinkGoogleMaps -Lat -2.5 -Long -43.25
    $urlM = Get-UrlMapaEstatico -Lat -2.5 -Long -43.25 -Chave 'FAKE123'
    if ($lnkG -eq 'https://www.google.com/maps?q=-2.5,-43.25' -and $urlM -match 'staticmap' -and $urlM -match 'key=FAKE123' -and $urlM -match '-2.5,-43.25') {
        Write-Host "[11] links de mapa: Get-LinkGoogleMaps + Get-UrlMapaEstatico OK"
    } else { Write-Host "    FALHA: links de mapa (lnk='$lnkG' url='$urlM')"; $falhas++ }
    if ((Get-UrlMapaEstatico -Lat -2.5 -Long -43.25 -Chave '') -eq '') { Write-Host "[11] sem chave -> Get-UrlMapaEstatico vazio" }
    else { Write-Host "    FALHA: Get-UrlMapaEstatico deveria voltar vazio sem chave"; $falhas++ }

    $g = [pscustomobject]@{
        lat = -2.4997476; long = -43.25344546; precisao_m = 6.558
        suporte_nome = 'OLNY TELECON'; suporte_telefone = '(98) 3042-1747'
        eletrica_tensao = '220 volts'; eletrica_tomadas = '6'; eletrica_extensao = 'Sim'
        mapa_link = (Get-LinkGoogleMaps -Lat -2.4997476 -Long -43.25344546)
    }
    $jsonGel = New-ResultadoJson -Local ([pscustomobject]@{ id = 'X'; nome = 'L'; zona_eleitoral = 24; municipio_sede = 'S'; municipio_termo = 'T'; tipo = 'contingencia'; endereco = 'R' }) `
        -TecnicoNome 'T' -Decisao ([pscustomobject]@{ Classificacao = 'inviavel'; Detalhes = @() }) -Metricas ([pscustomobject]@{}) -VistoriaGel $g
    $htmlGel = New-RelatorioHtml -Resultado $jsonGel
    if ($jsonGel.vistoria_gel -and [double] $jsonGel.vistoria_gel.latitude -eq -2.4997476 -and
        $jsonGel.vistoria_gel.suporte_nome -eq 'OLNY TELECON' -and $jsonGel.vistoria_gel.eletrica_tomadas -eq '6' -and
        $htmlGel -match 'Vistoria GEL' -and $htmlGel -match '-2.4997476' -and $htmlGel -match 'google.com/maps') {
        Write-Host "[11] JSON traz 'vistoria_gel' e o relatorio traz a secao do GEL + link do mapa"
    } else { Write-Host "    FALHA: JSON/relatorio do GEL (vg=$([bool]$jsonGel.vistoria_gel) html_sec=$($htmlGel -match 'Vistoria GEL'))"; $falhas++ }

    try { Read-TextoPdf -Caminho $PSCommandPath; Write-Host "    FALHA: Read-TextoPdf devia falhar sem a lib / com nao-PDF"; $falhas++ }
    catch { Write-Host "[11] Read-TextoPdf sem a biblioteca do PdfPig -> erro claro ($($_.Exception.Message.Substring(0,[Math]::Min(40,$_.Exception.Message.Length)))...)" }
}
finally {
    $Global:PastaDadosOverride = $null
    $Global:FaseLocalSimulada  = $null
    $Global:VpnSimulada        = $null
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
