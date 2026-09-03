# Code-behind da janela WPF (shell com navegacao por Visibility).
# Regras de escopo ja validadas: handlers chamam FUNCOES NOMEADAS; estado em
# $Global:*; nada de .GetNewClosure() dentro do .psm1; controles resolvidos via
# $Global:JanelaPrincipal.FindName.

$Global:DiagRunState      = $null
$Global:JuntasCache       = @()
$Global:SessaoAtual       = $null
$Global:RoteiroAtual      = $null
$Global:DiagPayload       = $null   # {Ambiente;Metricas;Decisao;Local} da ultima bateria
$Global:AvaliacaoRows     = $null   # ObservableCollection[AvaliacaoRow] do painel
$Global:DecisaoRecalculada = $null
$Global:DecisaoFinalTocada = $false # tecnico mexeu no combo da decisao final?
$Global:AtualizandoDecisao = $false # guarda para nao confundir set programatico com clique
$Global:LimiarRows         = $null   # ObservableCollection[LimiarRow] da tela de admin
$Global:NavegandoPrograma  = $false  # guarda: Show-View mexendo no rail sem disparar handler
$Global:TemaCarregado      = $false  # MahApps + Application ja inicializados neste processo?
$Global:MostrarTodasJuntas = $false  # admin: incluir Juntas fora da rota no seletor
$Global:WizardStep         = 1       # passo atual do assistente de diagnostico (1..6)
$Global:HomeTrabalhoState  = $null   # runspace do "Atualizar dados"/"Reenviar" async
$Global:TarefaRedeState    = $null   # runspace da fase local / conexao Wi-Fi
$Global:LoginEmAndamento   = $false   # trava reentrancia de Enter-Sessao (duplo-clique em "Entrar")
$Global:FaseLocalPayload   = $null   # {Lan;Wireless;Internet;Quando} da fase 1 (sem VPN)
$Global:RelerAdaptadorTipo = ''      # placa sendo relida no passo 3: '' | 'lan' | 'wifi'
$Global:FaseLocalTipo      = ''      # meio da checagem em curso: '' | 'lan' | 'wifi' | 'celular'
$Global:MeioSelecionado    = ''      # card do passo 3 selecionado p/ testar: '' | 'lan' | 'wifi' | 'celular'
$Global:CheckMeioAtivo     = $false  # overlay de checagem de um meio esta aberto/rodando
$Global:ChkFase            = ''      # estado do overlay: ''|f1-pronto|f1-rodando|f2-pronto|f2-rodando|fim
$Global:NaMeioPendente     = ''      # meio com "nao se aplica" marcado, aguardando a justificativa

# --- multi-meio: o local pode ter varias medicoes, uma por meio de conexao ---
$Global:Medicoes           = @()     # medicoes ja concluidas/marcadas neste local
$Global:MeioAtual          = ''      # meio em teste nesta rodada: 'lan' | 'wifi_local' | 'celular'
$Global:OperadoraAtual     = ''      # operadora (so quando MeioAtual = 'celular')
$Global:MeiosNaoAplicaveis = @{}     # meio -> motivo ("cabo nao alcanca a sala", etc.)
$Global:RecomendacaoLocal  = $null   # {meio;operadora;rotulo;veredito;provisoria;base}
$Global:LocalMedicoesId    = ''      # id do local a que as medicoes atuais pertencem
$Global:MotivoRecomendacao = ''      # justificativa da conexao recomendada (passo 6)
$Global:AtualizandoRecomendacao = $false  # guarda: set programatico do combo de recomendacao
$Global:MedicoesPasso5     = @()     # [{idx;med}] das medicoes testaveis no seletor do passo 5
$Global:MedicaoPasso5Idx   = -1      # indice em $Global:Medicoes da medicao aberta no passo 5 (-1 = ultima)
$Global:AtualizandoMedicaoP5 = $false # guarda: set programatico do combo de medicoes do passo 5
$Global:VistoriaGel        = $null   # anexo do GEL do local aberto no assistente (carregado do disco)
$Global:LocalDetalheAtual  = $null   # objeto do local aberto na tela viewLocalDetalhe

$Global:FeitoSalvar        = $false  # checklist do passo 7
$Global:FeitoTransmitir    = $false
$Global:FeitoExportar      = $false
$Global:UltimoResultadoSalvo = $null # caminho do JSON gravado no passo 7

# Ganchos de teste: preservam o valor definido ANTES de Import-Module -Force.
if (-not (Get-Variable -Name ModoTeste -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:ModoTeste = $false            # testes: nao abrir arquivos externos
}
if (-not (Get-Variable -Name FaseLocalSimulada -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:FaseLocalSimulada = $null     # testes: payload fixo p/ a fase local
}
if (-not (Get-Variable -Name VpnSimulada -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:VpnSimulada = $null           # testes: $true/$false forca o estado da VPN
}
if (-not (Get-Variable -Name BandaVpnSimulada -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:BandaVpnSimulada = $null      # testes: resultado fixo p/ Test-BandaVpn (nao roda iperf3)
}

$Global:Views = @('viewLogin', 'viewHome', 'viewGuia', 'viewLocais', 'viewLocalDetalhe', 'viewDiag', 'viewAdmin')

$Global:LocaisTecnico            = @()      # locais do roteiro do tecnico (achatados)
$Global:AtualizandoFiltroLocais  = $false   # guarda: preenchimento programatico dos combos
$Global:RailRecolhido            = $false   # menu lateral recolhido (so icones)?
$Global:VersaoNova               = ''       # versao mais recente no canal (se > a atual)

$Global:WizardPassos  = @('stepInfo', 'stepJunta', 'stepLocal', 'stepResultado', 'stepDecisao', 'stepFim')
$Global:WizardTitulos = @(
    ('Informa' + [char]0x00E7 + [char]0x00E3 + 'o do teste')
    'Junta Especial'
    'Meios de conex' + [char]0x00E3 + 'o'
    ('Resultado por m' + [char]0x00E9 + 'trica')
    ('Recomenda' + [char]0x00E7 + [char]0x00E3 + 'o final')
    ('Conclus' + [char]0x00E3 + 'o')
)
$Global:WizardNPassos = $Global:WizardPassos.Count

function Import-Xaml {
    param([string] $Caminho)
    [xml] $xml = Get-Content -Path $Caminho -Raw -Encoding UTF8
    return [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
}

# Carrega MahApps.Metro (lib/mahapps) e garante um System.Windows.Application,
# exigido para resolver os URIs pack://application dos dicionarios do tema.
# Idempotente: roda uma vez por processo.
function Initialize-Tema {
    if ($Global:TemaCarregado) { return }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml

    $lib = Join-Path $Global:RaizApp 'lib\mahapps'
    foreach ($d in 'ControlzEx.dll', 'Microsoft.Xaml.Behaviors.dll', 'MahApps.Metro.dll') {
        $dll = Join-Path $lib $d
        if (-not (Test-Path $dll)) { throw "Dependencia do tema nao encontrada: $dll" }
        Add-Type -Path $dll
    }

    if (-not [System.Windows.Application]::Current) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $Global:TemaCarregado = $true
}

function New-LogoBitmap {
    $p = Join-Path $Global:RaizApp 'assets\logo-eleicoes-2026.png'
    if (-not (Test-Path $p)) { return $null }
    try {
        $bmp = [Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource   = [Uri]::new($p)
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch {
        Write-Log "Falha ao carregar o logo: $_" -Nivel Aviso
        return $null
    }
}

function Get-PincelClassificacao {
    param([string] $Classificacao)
    switch ($Classificacao) {
        'viavel'              { [Windows.Media.Brushes]::LightGreen }
        'viavel_com_ressalva' { [Windows.Media.Brushes]::Yellow }
        default               { [Windows.Media.Brushes]::OrangeRed }
    }
}

# Pincel nos tons da identidade DICON para a barra de decisao final.
function Get-PincelVeredito {
    param([string] $Classificacao)
    $hex = switch ($Classificacao) {
        'viavel'              { '#4FC177' }
        'viavel_com_ressalva' { '#E8B93E' }
        'inviavel'            { '#E8695C' }
        default               { '#7D8698' }
    }
    $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze()
    return $b
}

function Get-PalavraVeredito {
    param([string] $Classificacao)
    switch ($Classificacao) {
        'viavel'              { 'VIAVEL' }
        'viavel_com_ressalva' { 'VIAVEL C/ RESSALVA' }
        'inviavel'            { 'INVIAVEL' }
        default               { '--' }
    }
}

# Rotulo legivel do veredito para textos corridos (ex.: "Viavel com Ressalva").
function Get-RotuloVeredito {
    param([string] $Classificacao)
    $a = [char]0x00E1  # a acentuado
    switch ($Classificacao) {
        'viavel'              { 'Vi{0}vel' -f $a }
        'ressalva'            { 'Ressalva' }
        'viavel_com_ressalva' { 'Vi{0}vel com Ressalva' -f $a }
        'inviavel'            { 'Invi{0}vel' -f $a }
        default               { if ($Classificacao) { [string] $Classificacao } else { '--' } }
    }
}

# Atualiza a faixa + palavra da barra de decisao final.
function Set-BarraDecisao {
    param([string] $Classificacao)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $pincel = Get-PincelVeredito $Classificacao
    $pal = $w.FindName('txtDecisaoPalavra')
    if ($pal) { $pal.Text = Get-PalavraVeredito $Classificacao; $pal.Foreground = $pincel }
    $stripe = $w.FindName('barraDecisaoStripe')
    if ($stripe) { $stripe.Background = $pincel }
}

# Liga/desliga o indicador de progresso (anel + barra) da tela de diagnostico.
function Set-ProgressoDiag {
    param([bool] $Ativo)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $ring = $w.FindName('ringDiag')
    if ($ring) {
        $ring.IsActive   = $Ativo
        $ring.Visibility = if ($Ativo) { 'Visible' } else { 'Collapsed' }
    }
    $bar = $w.FindName('prgProgresso')
    if ($bar) { $bar.IsIndeterminate = $Ativo }
}

# ------------------------------------------------------------- SHELL / NAV

function New-JanelaPrincipal {
    Initialize-Tema

    $window = Import-Xaml (Join-Path $PSScriptRoot 'MainWindow.xaml')

    # --- Fontes da identidade: Archivo empacotada (titulos) + Segoe UI (texto) ---
    $fontDir = (Join-Path $Global:RaizApp 'assets\marca\tema\fonts') + '\'
    try {
        $baseUri = [Uri]('file:///' + ($fontDir -replace '\\', '/'))
        $window.Resources['Dicon.Display'] = [Windows.Media.FontFamily]::new($baseUri, './#Archivo')
    } catch {
        $window.Resources['Dicon.Display'] = [Windows.Media.FontFamily]::new('Segoe UI')
    }
    $window.Resources['Dicon.Body'] = [Windows.Media.FontFamily]::new('Segoe UI')

    # --- Dicionarios: MahApps (Dark.Blue) primeiro, tema DICON por ultimo ---
    foreach ($u in @(
            'pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml'
            'pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml'
            'pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Blue.xaml'
        )) {
        $rd = [System.Windows.ResourceDictionary]::new()
        $rd.Source = [Uri] $u
        $window.Resources.MergedDictionaries.Add($rd)
    }
    $window.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $PSScriptRoot 'Tema.xaml')))

    # --- Icone da janela ---
    $ico = Join-Path $Global:RaizApp 'assets\marca\dicon.ico'
    if (Test-Path $ico) {
        try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico)) } catch { }
    }

    $Global:JanelaPrincipal = $window
    $Global:LogEntries.Clear()   # cada abertura da janela comeca com o log limpo
    $Global:LogHome.Clear()
    $window.FindName('lstLog').ItemsSource     = $Global:LogEntries
    $window.FindName('lstLogHome').ItemsSource = $Global:LogHome

    Reset-Velocimetro
    Reset-Velocimetro -Suf 'Vpn'

    $logo = New-LogoBitmap
    if ($logo) {
        foreach ($n in 'imgLogoLogin', 'imgLogoHome') {
            $ctrl = $window.FindName($n)
            if ($ctrl) { $ctrl.Source = $logo }
        }
    }

    $ver = if (Get-Variable -Name VersaoApp -Scope Global -ErrorAction SilentlyContinue) { $Global:VersaoApp } else { '' }
    if ($ver) {
        foreach ($n in 'txtRailVersao', 'txtLoginVersao') {
            $ctrl = $window.FindName($n)
            if ($ctrl) { $ctrl.Text = "DICON v$ver" }
        }
    }

    # Marca de ambiente: em 'homologacao' mostra os selos (login + rail) e poe o
    # sufixo no titulo da janela, pra ninguem confundir com o DICON de producao.
    $Global:CanalApp = try { Get-CanalInstalacao } catch { 'main' }
    if ($Global:CanalApp -eq 'homologacao') {
        foreach ($n in 'badgeHomologLogin', 'badgeHomologRail') {
            $b = $window.FindName($n); if ($b) { $b.Visibility = 'Visible' }
        }
        try { $window.Title = "$($window.Title)  -  HOMOLOGACAO" } catch { }
        $lv = $window.FindName('txtLoginVersao')
        if ($lv) { $lv.Text = "DICON v$ver - homologacao" }
    }

    # diagnostico - overlay de checagem de meio
    $window.FindName('btnCheckLan').Add_Click({ Invoke-CheckMeio 'lan' })
    $window.FindName('btnCheckWifi').Add_Click({ Invoke-CheckMeio 'wifi' })
    $window.FindName('btnCheckCelular').Add_Click({ Invoke-CheckMeio 'celular' })
    $window.FindName('btnChkIniciar').Add_Click({ Invoke-ChkAvancar })
    $window.FindName('btnChkFechar').Add_Click({ Close-OverlayCheck })
    $window.FindName('btnChkVpnImpossivel').Add_Click({ Invoke-CheckVpnImpossivel })
    $window.FindName('btnAbrirFortiClient').Add_Click({ Invoke-AbrirFortiClient })
    $window.FindName('btnReverificarVpn').Add_Click({ Invoke-ReverificarVpn })
    $window.FindName('chkVpnImpossivel').Add_Click({ Update-VpnImpossivel })
    $window.FindName('btnAtualizar').Add_Click({ Invoke-AtualizarListaJuntas })
    $window.FindName('cboJunta').Add_SelectionChanged({ Update-ComboLocais })
    $window.FindName('cboLocal').Add_SelectionChanged({ Update-DetalheLocal })
    $window.FindName('chkTodasJuntas').Add_Click({
            $Global:MostrarTodasJuntas = [bool] $Global:JanelaPrincipal.FindName('chkTodasJuntas').IsChecked
            Update-SeletorJuntas
        })
    $window.FindName('btnWizVoltar').Add_Click({ Invoke-WizardVoltar })
    $window.FindName('btnWizProximo').Add_Click({ Invoke-WizardProximo })
    $window.FindName('btnRefazerTeste').Add_Click({ Invoke-WizardProximo })
    $window.FindName('btnAnexarGel').Add_Click({ Invoke-AnexarGel })
    $window.FindName('btnGelRegistrar').Add_Click({ Invoke-GelRegistrar })
    $window.FindName('btnGelCancelar').Add_Click({ Invoke-GelCancelar })
    $window.FindName('btnGelRemover').Add_Click({ Invoke-GelRemover })
    $window.FindName('btnGelAddFotos').Add_Click({ Invoke-GelAddFotos })
    $window.FindName('btnGelFotoRemover').Add_Click({ Invoke-GelFotoRemover })
    $window.FindName('btnRelerPlacas').Add_Click({ Invoke-RelerPlacas })
    $window.FindName('btnRelerLan').Add_Click({ Invoke-RelerAdaptador 'lan' })
    $window.FindName('btnRelerWifi').Add_Click({ Invoke-RelerAdaptador 'wifi' })
    $window.FindName('btnRelerCel').Add_Click({ Invoke-RelerAdaptador 'wifi' })
    $window.FindName('cboOperadoraCel').Add_LostFocus({ Update-PainelMeios })
    $window.FindName('cardLan').Add_MouseLeftButtonUp({ Select-MeioParaChecar 'lan' })
    $window.FindName('cardWifiPlaca').Add_MouseLeftButtonUp({ Select-MeioParaChecar 'wifi' })
    $window.FindName('cardCelular').Add_MouseLeftButtonUp({ Select-MeioParaChecar 'celular' })
    foreach ($n in 'chkNaLan', 'chkNaWifi', 'chkNaCelular') {
        $window.FindName($n).Add_Click({ Update-NaoAplicavelMeio })
    }
    $window.FindName('btnNaRegistrar').Add_Click({ Invoke-NaRegistrar })
    $window.FindName('btnNaCancelar').Add_Click({ Invoke-NaCancelar })
    $window.FindName('btnExportarPdf').Add_Click({ Invoke-ExportarRelatorio })
    $window.FindName('btnTransmitirResultado').Add_Click({ Invoke-TransmitirResultado })
    $window.FindName('btnDiagVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarResultado').Add_Click({ Invoke-SalvarResultado })
    $window.FindName('btnFinalizarDiag').Add_Click({ Invoke-FinalizarDiagnostico })
    $window.FindName('cboDecisaoFinal').Add_SelectionChanged({
            if (-not $Global:AtualizandoDecisao) { $Global:DecisaoFinalTocada = $true }
            Update-VisibilidadeJustDecisao
        })
    $window.FindName('tabsMedicoes').Add_SelectionChanged({ Invoke-TrocarMedicaoPasso5 })
    $window.FindName('cboConexaoRec').Add_SelectionChanged({
            if (-not $Global:AtualizandoRecomendacao) { Update-ContextoRecomendacao }
        })
    $window.FindName('txtMotivoRec').Add_TextChanged({
            $Global:MotivoRecomendacao = [string] $Global:JanelaPrincipal.FindName('txtMotivoRec').Text
        })

    # login
    $window.FindName('cboTecnico').Add_SelectionChanged({ Update-VisibilidadePin })
    $window.FindName('btnEntrar').Add_Click({ Enter-Sessao })
    $window.FindName('btnBaixarLista').Add_Click({ Invoke-BaixarListaLogin })

    # home
    $window.FindName('btnMenuGuia').Add_Click({ Show-GuiaBordo })
    $window.FindName('btnMenuDiag').Add_Click({ Open-DiagnosticoLimpo })
    $window.FindName('btnMenuAdmin').Add_Click({ Show-Admin })
    $window.FindName('btnMenuAtualizar').Add_Click({ Invoke-AtualizarDados })
    $window.FindName('btnReenviarPendentes').Add_Click({ Invoke-ReenvioPendentes })
    $window.FindName('btnTrocarUsuario').Add_Click({ Invoke-TrocarUsuario })

    $window.FindName('btnRailToggle').Add_Click({ Invoke-ToggleRail })
    $window.FindName('btnAtualizarApp').Add_Click({ Invoke-AtualizarApp })

    # rail de navegacao (RadioButtons) - handlers ignoram mudanca programatica
    $window.FindName('navGuia').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-GuiaBordo } })
    $window.FindName('navLocais').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-Locais } })
    $window.FindName('navDiag').Add_Checked({ if (-not $Global:NavegandoPrograma) { Open-DiagnosticoLimpo } })
    $window.FindName('navAdmin').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-Admin } })
    $window.FindName('navAtualizar').Add_Checked({ if (-not $Global:NavegandoPrograma) { Invoke-AtualizarDados } })

    # locais de vistoria
    $window.FindName('btnLocaisVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnLocalDetalheVoltar').Add_Click({ Invoke-VoltarAosLocais })
    $window.FindName('txtBuscaLocais').Add_TextChanged({ Update-LocaisFiltrados })
    $window.FindName('cboFiltroZE').Add_SelectionChanged({ if (-not $Global:AtualizandoFiltroLocais) { Update-LocaisFiltrados } })
    $window.FindName('cboFiltroMun').Add_SelectionChanged({ if (-not $Global:AtualizandoFiltroLocais) { Update-LocaisFiltrados } })
    $window.FindName('dgLocais').Add_SelectionChanged({ Invoke-AbrirLocalDetalhe })

    # guia / admin
    $window.FindName('btnGuiaVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnAdminVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarLimiares').Add_Click({ Invoke-SalvarLimiares })
    $window.FindName('btnRecarregarLimiares').Add_Click({ Invoke-RecarregarLimiares })
    $window.FindName('btnSalvarAmbiente').Add_Click({ Invoke-SalvarAmbiente })
    $window.FindName('lstGuiaJuntas').AddHandler(
        [Windows.Controls.Button]::ClickEvent,
        [Windows.RoutedEventHandler] {
            param($s, $e)
            $tag = $e.OriginalSource.Tag
            if ($tag -and $tag.id) { Start-DiagnosticoDoGuia -LocalId $tag.id }
        })

    Initialize-SeletorJuntas

    # Sempre comeca no login (sem pre-selecao). A sessao gravada nao faz auto-login.
    Initialize-Login
    Show-View 'viewLogin'
    return $window
}

function Show-JanelaPrincipal {
    $janela = New-JanelaPrincipal
    # Rede de seguranca: um erro solto numa callback (timer, dispatcher) nao
    # pode fechar a janela inteira - loga e segue. Erro de layout/template
    # repete a cada frame de render; aqui a gente NAO deixa o log virar um
    # dilúvio (so a 1a ocorrencia de cada mensagem, e no maximo poucas por vez).
    $Global:UiErroUltimo = ''
    $Global:UiErroCount  = 0
    $janela.Dispatcher.add_UnhandledException({
        param($fonte, $ev)
        $ev.Handled = $true
        $msg = "$($ev.Exception.Message)"
        if ($msg -eq $Global:UiErroUltimo) {
            $Global:UiErroCount++
            if ($Global:UiErroCount -eq 3) {
                try { Write-Log 'Erro na interface se repetindo - parando de registrar (veja o log em disco).' -Nivel Erro } catch { }
            }
            return
        }
        $Global:UiErroUltimo = $msg
        $Global:UiErroCount  = 0
        try {
            $ex   = $ev.Exception
            $tipo = try { $ex.GetType().FullName } catch { '?' }
            $onde = ''
            try {
                if ($ex.TargetSite) { $onde = " em {0}.{1}" -f $ex.TargetSite.DeclaringType.Name, $ex.TargetSite.Name }
                elseif ($ex.StackTrace) { $onde = ' | ' + (($ex.StackTrace -split "`n")[0].Trim()) }
            } catch { }
            Write-Log ("Erro nao tratado na interface [{0}]: {1}{2}" -f $tipo, $msg, $onde) -Nivel Erro
            $inner = $ex.InnerException
            $guard = 0
            while ($inner -and $guard -lt 3) {
                Write-Log ("  causado por [{0}]: {1}" -f $inner.GetType().Name, $inner.Message) -Nivel Erro
                $inner = $inner.InnerException; $guard++
            }
        } catch { }
    })
    $janela.ShowDialog() | Out-Null
}

function Show-View {
    param([string] $Nome)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    foreach ($v in $Global:Views) {
        $w.FindName($v).Visibility = if ($v -eq $Nome) { 'Visible' } else { 'Collapsed' }
    }
    $w.FindName('railNav').Visibility = if ($Nome -eq 'viewLogin') { 'Collapsed' } else { 'Visible' }

    # sincroniza o item ativo do rail sem disparar os handlers de navegacao
    $map = @{ viewGuia = 'navGuia'; viewLocais = 'navLocais'; viewLocalDetalhe = 'navLocais'; viewDiag = 'navDiag'; viewAdmin = 'navAdmin' }
    $Global:NavegandoPrograma = $true
    foreach ($nn in 'navGuia', 'navLocais', 'navDiag', 'navAdmin', 'navAtualizar') {
        $rb = $w.FindName($nn)
        if ($rb) { $rb.IsChecked = ($map[$Nome] -eq $nn) }
    }
    $Global:NavegandoPrograma = $false
}

# Recolhe (so icones, ~56px) ou expande (214px) o menu lateral.
function Set-RailRecolhido {
    param([bool] $On)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $w.FindName('railNav').Width = if ($On) { 56 } else { 214 }
    $vis = if ($On) { 'Collapsed' } else { 'Visible' }
    foreach ($n in 'railCabTexto', 'lblNavSecao', 'railRodape',
        'lblNavGuia', 'lblNavLocais', 'lblNavDiag', 'lblNavAdmin', 'lblNavAtualizar') {
        $c = $w.FindName($n); if ($c) { $c.Visibility = $vis }
    }
    $t = $w.FindName('txtRailToggle')
    if ($t) { $t.Text = if ($On) { [char]0x00BB } else { [char]0x00AB } }
}

function Invoke-ToggleRail {
    $Global:RailRecolhido = -not $Global:RailRecolhido
    Set-RailRecolhido $Global:RailRecolhido
}

# ---------------------------------------------------------- ATUALIZACAO DA FERRAMENTA

# Checa (async, best-effort) se ha versao nova no canal desta instalacao.
function Test-AtualizacaoApp {
    if ($Global:ModoTeste -or $Global:TarefaRedeState) { return }
    Start-TarefaRede -Script 'Get-VersaoRemota' -AoConcluir {
        param($res, $erro)
        if (-not $erro -and $res) { Update-AvisoVersao ([string] $res) }
    }
}

# Mostra/oculta o botao "Atualizar" no rodape do rail conforme a versao remota.
function Update-AvisoVersao {
    param([string] $Remota)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $b = $w.FindName('btnAtualizarApp')
    if (-not $b) { return }
    $temNova = $false
    try { $temNova = [version] $Remota -gt [version] $Global:VersaoApp }
    catch { $temNova = ($Remota -and $Remota -ne $Global:VersaoApp) }
    if ($temNova) {
        $Global:VersaoNova = $Remota
        $b.Content    = ([char]0x2B06) + " Atualizar (v$Remota)"
        $b.Visibility = 'Visible'
        Write-Log ("Versao nova do DICON disponivel: v{0} (voce esta na v{1}). Clique em 'Atualizar' no menu." -f $Remota, $Global:VersaoApp) -Nivel Aviso
    } else {
        $Global:VersaoNova = ''
        $b.Visibility = 'Collapsed'
    }
}

# Fecha o DICON e abre o Atualizar-DICON.ps1 numa janela propria.
function Invoke-AtualizarApp {
    $w = $Global:JanelaPrincipal
    $upd = Join-Path $Global:RaizApp 'setup\Atualizar-DICON.ps1'
    if (-not (Test-Path $upd)) { Write-Log 'setup\Atualizar-DICON.ps1 nao encontrado nesta instalacao.' -Nivel Erro; return }
    $alvo = if ($Global:VersaoNova) { " para a v$($Global:VersaoNova)" } else { '' }
    $msg  = "Atualizar o DICON$alvo?`n`nA ferramenta vai fechar e o atualizador abre numa janela. " +
            "Quando terminar, reabra o DICON pelo atalho da area de trabalho."
    $r = [System.Windows.MessageBox]::Show($w, $msg, 'Atualizar DICON',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $upd, '-Force')
        $w.Close()
    } catch {
        Write-Log "Nao consegui abrir o atualizador: $_" -Nivel Erro
    }
}

# ------------------------------------------------------------- LOGIN

function Initialize-Login {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $tec = @(Get-Tecnicos)
    $w.FindName('cboTecnico').ItemsSource = $tec
    $w.FindName('lblPin').Visibility = 'Collapsed'
    $w.FindName('txtPin').Visibility = 'Collapsed'

    # sem listas locais: trava a selecao/entrada e orienta a baixar
    $temLista = [bool] $tec.Count
    $w.FindName('cboTecnico').IsEnabled = $temLista
    $w.FindName('btnEntrar').IsEnabled  = $temLista
    if ($temLista) {
        $w.FindName('txtLoginMsg').Text = ''
    } else {
        $w.FindName('txtLoginMsg').Text = "Este computador ainda nao tem as listas (tecnicos, Juntas, roteiros). " +
            "Conecte a internet e clique em 'Baixar lista' para carrega-las."
    }
}

# Liga/desliga o spinner + trava os controles do login durante o "Baixar lista".
function Set-LoginBaixando {
    param([bool] $On)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $ring = $w.FindName('ringLogin')
    if ($ring) {
        $ring.IsActive   = $On
        $ring.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    }
    $w.FindName('btnBaixarLista').IsEnabled = -not $On
    $w.FindName('btnEntrar').IsEnabled      = -not $On
    $w.FindName('cboTecnico').IsEnabled     = -not $On
    if ($On) {
        $w.FindName('txtLoginMsg').Text = 'Baixando as listas (Juntas, tecnicos, roteiros, limiares)... acompanhe no log abaixo.'
    }
}

function Update-VisibilidadePin {
    $w = $Global:JanelaPrincipal
    $t = $w.FindName('cboTecnico').SelectedItem
    $ehAdmin = $t -and (Test-NomeAdmin $t.nome)
    $vis = if ($ehAdmin) { 'Visible' } else { 'Collapsed' }
    $w.FindName('lblPin').Visibility = $vis
    $w.FindName('txtPin').Visibility = $vis
}

function Invoke-BaixarListaLogin {
    if ($Global:TarefaRedeState) { return }   # ja tem uma tarefa de rede rodando
    Set-LoginBaixando $true
    Start-TarefaRede -Script 'Sync-TudoOnline' -AoConcluir {
        param($res, $erro)
        Set-LoginBaixando $false
        Initialize-Login
        $w = $Global:JanelaPrincipal
        if ($erro) {
            $w.FindName('txtLoginMsg').Text = "Falha ao baixar: $erro"
        } elseif ($res) {
            $w.FindName('txtLoginMsg').Text = ("Baixado: {0} tecnicos, {1} juntas, {2} roteiros." -f $res.tecnicos, $res.juntas, $res.roteiros)
        }
    }
}

function Enter-Sessao {
    if ($Global:LoginEmAndamento) { return }   # ignora duplo-clique em "Entrar"
    $Global:LoginEmAndamento = $true
    try { Enter-SessaoInterno } finally { $Global:LoginEmAndamento = $false }
}

function Enter-SessaoInterno {
    $w = $Global:JanelaPrincipal
    $t = $w.FindName('cboTecnico').SelectedItem
    if (-not $t) { $w.FindName('txtLoginMsg').Text = 'Selecione seu nome.'; return }

    $nome  = $t.nome
    $papel = 'operador'
    if (Test-NomeAdmin $nome) {
        $pin = $w.FindName('txtPin').Password
        if (-not [string]::IsNullOrWhiteSpace($pin)) {
            if (Test-PinAdmin $pin) { $papel = 'admin' }
            else { $w.FindName('txtLoginMsg').Text = 'PIN incorreto.'; return }
        }
    }

    $sessao = $null
    try { $sessao = Set-Sessao -TecnicoNome $nome -Papel $papel }
    catch {
        Write-Log "Falha ao gravar a sessao: $_" -Nivel Aviso
        $sessao = [pscustomobject]@{ tecnico_nome = $nome; papel = $papel; ultimo_login = (Get-Date).ToString('o') }
    }
    # Entrar SEMPRE leva para a tela inicial - um erro num painel de la nao pode
    # prender o tecnico no login.
    try { Enter-Home -Sessao $sessao }
    catch {
        Write-Log "Falha ao montar a tela inicial: $_" -Nivel Erro
        $Global:SessaoAtual = $sessao
        try { Show-View 'viewHome' } catch { }
    }
}

function Invoke-TrocarUsuario {
    Clear-Sessao
    $Global:SessaoAtual  = $null
    $Global:RoteiroAtual = $null
    $Global:JanelaPrincipal.FindName('txtPin').Password = ''
    Initialize-Login
    Show-View 'viewLogin'
}

# ------------------------------------------------------------- HOME

function Enter-Home {
    param($Sessao)
    $w = $Global:JanelaPrincipal
    $Global:SessaoAtual = $Sessao

    $primeiro = ($Sessao.tecnico_nome -split '\s+')[0]
    $sfx = if ($Sessao.papel -eq 'admin') { '  (administrador)' } else { '' }
    $w.FindName('txtSaudacao').Text     = "Ola, $primeiro$sfx"
    $w.FindName('txtRailTecnico').Text  = $Sessao.tecnico_nome
    $w.FindName('txtHomeTecnico').Text  = "Ola, $primeiro"

    $visAdmin = if ($Sessao.papel -eq 'admin') { 'Visible' } else { 'Collapsed' }
    $w.FindName('btnMenuAdmin').Visibility = $visAdmin
    $w.FindName('navAdmin').Visibility     = $visAdmin

    # seletor de Juntas: sempre so da rota (checkbox "incluir fora da rota"
    # desativado por ora; para reativar, use  $chkTodas.Visibility = $visAdmin)
    $Global:MostrarTodasJuntas = $false
    $chkTodas = $w.FindName('chkTodasJuntas')
    $chkTodas.IsChecked  = $false
    $chkTodas.Visibility = 'Collapsed'

    # Tudo daqui pra baixo e "melhor esforco": nada pode impedir o login de
    # concluir (Show-View 'viewHome' no fim SEMPRE roda).
    $rot = $null
    try { $rot = Get-RoteiroDoTecnico -Nome $Sessao.tecnico_nome } catch { Write-Log "Roteiro nao carregado: $_" -Nivel Aviso }
    $Global:RoteiroAtual = $rot
    try { Update-SeletorJuntas } catch { Write-Log "Seletor de Juntas falhou: $_" -Nivel Aviso }

    try {
        $w.FindName('txtHomeRoteiro').Text = if ($rot) {
            '{0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias' -f $rot.rotulo, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias
        } else {
            'Roteiro nao encontrado no cache. Use "Atualizar dados".'
        }

        if ($rot) {
            $prog = $null
            try { $prog = Get-ProgressoRoteiro -Roteiro $rot -TecnicoNome $Sessao.tecnico_nome } catch { Write-Log "Progresso do roteiro falhou: $_" -Nivel Aviso }
            $w.FindName('txtTileDias').Text   = [string] $rot.dias
            $w.FindName('txtTileLocais').Text = if ($prog) { [string] $prog.Total } else { '--' }
            $w.FindName('txtTileKm').Text     = [string] $rot.total_km

            if ($prog) {
                $w.FindName('txtProgressoRoteiro').Text = '{0} de {1} locais testados' -f $prog.Testados, $prog.Total
                $pb = $w.FindName('prgProgressoRoteiro')
                $pb.Maximum = [math]::Max($prog.Total, 1)
                $pb.Value   = $prog.Testados
                $w.FindName('painelProgressoRoteiro').Visibility = 'Visible'
            } else {
                $w.FindName('painelProgressoRoteiro').Visibility = 'Collapsed'
            }
        } else {
            foreach ($t in 'txtTileDias', 'txtTileLocais', 'txtTileKm') { $w.FindName($t).Text = '--' }
            $w.FindName('painelProgressoRoteiro').Visibility = 'Collapsed'
        }
    } catch { Write-Log "Painel do roteiro falhou: $_" -Nivel Aviso }

    try { Update-AvisoPendentes } catch { Write-Log "Aviso de pendentes falhou: $_" -Nivel Aviso }
    try { $w.FindName('painelLogHome').Visibility = if ($Global:LogHome.Count) { 'Visible' } else { 'Collapsed' } } catch { }
    try { Test-AtualizacaoApp } catch { }   # checa versao nova (best-effort, silencioso)
    Show-View 'viewHome'
}

# Trava/destrava a tela inicial e mostra o spinner enquanto um trabalho roda.
function Set-HomeOcupado {
    param([bool] $Ocupado, [string] $Rotulo = 'Processando...')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $w.FindName('painelAtualizando').Visibility = if ($Ocupado) { 'Visible' } else { 'Collapsed' }
    $ring = $w.FindName('ringHome'); if ($ring) { $ring.IsActive = $Ocupado }
    if ($Ocupado) { $w.FindName('txtAtualizandoMsg').Text = $Rotulo }
    foreach ($n in 'btnMenuGuia', 'btnMenuDiag', 'btnMenuAdmin', 'btnMenuAtualizar',
        'btnReenviarPendentes', 'btnTrocarUsuario', 'navGuia', 'navLocais', 'navDiag', 'navAdmin', 'navAtualizar') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
}

# Roda -Trabalho num runspace (janela responde + spinner) e chama -AoConcluir
# na thread de UI com ($resultado, $erro). O Write-Log do runspace ja marshalla
# para o Dispatcher, entao o feed "ATIVIDADE" atualiza ao vivo.
function Start-TrabalhoHome {
    param(
        [Parameter(Mandatory)] [scriptblock] $Trabalho,
        [scriptblock] $AoConcluir = {},
        [string] $Rotulo = 'Processando...'
    )
    if ($Global:HomeTrabalhoState) { return }   # ja tem um rodando

    if (-not $Global:JanelaPrincipal) {          # sem janela: roda sincrono
        try { $r = & $Trabalho; & $AoConcluir $r $null } catch { & $AoConcluir $null "$_" }
        return
    }

    Set-HomeOcupado $true $Rotulo

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    foreach ($v in 'RaizApp', 'LogEntries', 'LogHome', 'LogHomeMax', 'JanelaPrincipal', 'ArquivoLog', 'PastaDadosOverride') {
        $rs.SessionStateProxy.SetVariable($v, (Get-Variable -Name $v -Scope Global -ValueOnly -ErrorAction SilentlyContinue))
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void] $ps.AddScript({
        param($sbTexto)
        Import-Module (Join-Path $RaizApp 'src\Conectividade.psd1') -Force
        try { [pscustomobject]@{ Resultado = (& ([scriptblock]::Create($sbTexto))); Erro = $null } }
        catch { [pscustomobject]@{ Resultado = $null; Erro = "$_" } }
    }).AddArgument($Trabalho.ToString())

    $handle = $ps.BeginInvoke()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $Global:HomeTrabalhoState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer; AoConcluir = $AoConcluir }

    $timer.Add_Tick({
      try {
        $st = $Global:HomeTrabalhoState
        if ($null -eq $st -or -not $st.Handle.IsCompleted) { return }
        $st.Timer.Stop()
        $Global:HomeTrabalhoState = $null

        $res = $null; $erro = $null
        try {
            $r = $st.PS.EndInvoke($st.Handle) | Select-Object -First 1
            $res = $r.Resultado; $erro = $r.Erro
        } catch { $erro = "$_" } finally { try { $st.PS.Dispose(); $st.RS.Dispose() } catch { } }

        if ($erro) { Write-Log "Falha: $erro" -Nivel Erro }
        try { & $st.AoConcluir $res $erro } catch { Write-Log "Pos-processamento falhou: $_" -Nivel Erro }
        Set-HomeOcupado $false
      } catch {
        try { Write-Log "Tarefa de fundo: falha inesperada ($_)." -Nivel Erro } catch { }
        try { Set-HomeOcupado $false } catch { }
      }
    })
    $timer.Start()
}

function Invoke-AtualizarDados {
    Start-TrabalhoHome -Rotulo 'Atualizando dados...' -Trabalho {
        $r = Sync-TudoOnline
        Write-Log ("Dados atualizados: {0} juntas, {1} tecnicos, {2} roteiros." -f $r.juntas, $r.tecnicos, $r.roteiros) -Nivel Ok
        $cfg = $null
        try { $cfg = Get-Config 'envio' } catch { }
        if (-not $cfg -or $cfg.reenvio_ao_atualizar -ne $false) {
            Send-ResultadosPendentes -Endpoint $cfg.endpoint_apps_script | Out-Null
        }
        $r
    } -AoConcluir {
        param($res, $erro)
        Initialize-SeletorJuntas
        if ($Global:SessaoAtual) { Enter-Home -Sessao $Global:SessaoAtual }   # Enter-Home ja checa versao nova
    }
}

# ------------------------------------------------------------- GUIA DE BORDO

function Show-GuiaBordo {
    $w = $Global:JanelaPrincipal
    $rot = $Global:RoteiroAtual

    if (-not $rot) {
        $w.FindName('txtGuiaTitulo').Text = 'Roteiro nao disponivel'
        $w.FindName('txtGuiaSub').Text    = 'Use "Atualizar dados" com internet.'
        $w.FindName('lstGuiaJuntas').ItemsSource  = @()
        $w.FindName('txtGuiaSemJunta').Text       = ''
        Show-View 'viewGuia'
        return
    }

    $w.FindName('txtGuiaTitulo').Text = $rot.rotulo
    $w.FindName('txtGuiaSub').Text = ('Tecnico: {0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias    |    {5} km ({6})' -f `
            $rot.tecnico, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias, $rot.total_km, $rot.total_tempo)

    # marca cada local com o status do ultimo diagnostico feito pelo tecnico;
    # o cartao do local fica verde quando testado, e o cartao da ZE fica verde
    # quando TODOS os locais dela (principal + contingencia) ja foram testados.
    $feitos = Get-DiagnosticosRealizados -TecnicoNome $Global:SessaoAtual.tecnico_nome
    $cinza  = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
    $cinza.Freeze()
    foreach ($grupo in @($rot.juntas)) {
        $todasTestadas = $true
        foreach ($loc in @($grupo.locais)) {
            $d = $feitos[[string] $loc.id]
            if ($d) {
                $ver = Get-RotuloVeredito $d.ClassificacaoFinal
                $sfx = if ($d.Enviado) { '' } else { '  (nao enviado)' }
                $txt = 'Testado {0:dd/MM HH:mm}  -  {1}{2}' -f $d.Quando, $ver, $sfx
                $cor = Get-PincelVeredito $d.ClassificacaoFinal
                $bot = 'Refazer teste'
            } else {
                $txt = 'N' + [char]0x00E3 + 'o testado'
                $cor = $cinza
                $bot = 'Rodar diagn' + [char]0x00F3 + 'stico'
                $todasTestadas = $false
            }
            $loc | Add-Member -NotePropertyName TesteStatus -NotePropertyValue $txt -Force
            $loc | Add-Member -NotePropertyName TesteCor    -NotePropertyValue $cor -Force
            $loc | Add-Member -NotePropertyName BotaoRodar  -NotePropertyValue $bot -Force
            $loc | Add-Member -NotePropertyName Testado     -NotePropertyValue ([bool] $d) -Force
        }
        $temLocais = [bool] (@($grupo.locais).Count)
        $grupo | Add-Member -NotePropertyName TodasTestadas -NotePropertyValue ($temLocais -and $todasTestadas) -Force
    }
    $w.FindName('lstGuiaJuntas').ItemsSource = @($rot.juntas)

    $sem = @($rot.cidades_sem_junta)
    $w.FindName('txtGuiaSemJunta').Text = if ($sem.Count) {
        'Cidades de passagem sem Junta: ' + ($sem -join ', ')
    } else { '' }

    Show-View 'viewGuia'
}

# ------------------------------------------------------------- LOCAIS DE VISTORIA

# Locais do roteiro do tecnico logado, achatados numa lista unica (com rotulos
# prontos p/ a grade). Sem roteiro -> lista vazia.
function Get-LocaisDoTecnico {
    $rot = $Global:RoteiroAtual
    if (-not $rot) { return @() }
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($grupo in @($rot.juntas)) {
        foreach ($loc in @($grupo.locais)) {
            if (-not $loc) { continue }
            $rot2 = if ("$($loc.tipo)" -eq 'principal') { 'Principal' } else { 'Conting' + [char]0x00EA + 'ncia' }
            $loc | Add-Member -NotePropertyName TipoRotulo -Force -NotePropertyValue $rot2
            $saida.Add($loc)
        }
    }
    return $saida
}

# Abre a tela de Locais (chamada pelo rail).
function Show-Locais {
    Initialize-Locais
    Show-View 'viewLocais'
}

# Monta a lista + os combos de filtro (ZE / municipio).
function Initialize-Locais {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $Global:LocaisTecnico = @(Get-LocaisDoTecnico)
    $rot = $Global:RoteiroAtual

    $w.FindName('txtLocaisSub').Text = if ($rot) {
        'Roteiro {0} - {1}    |    {2} local(is)    |    clique num local para abrir a ficha completa' -f $rot.numero, $rot.tecnico, @($Global:LocaisTecnico).Count
    } else {
        'Roteiro nao disponivel neste computador. Use "Atualizar dados" com internet.'
    }

    $zes = @($Global:LocaisTecnico | ForEach-Object { [string] $_.zona_eleitoral } |
        Where-Object { $_ } | Select-Object -Unique | Sort-Object { [int] $_ })
    $muns = @($Global:LocaisTecnico | ForEach-Object { [string] $_.municipio_termo } |
        Where-Object { $_ } | Select-Object -Unique | Sort-Object)

    $Global:AtualizandoFiltroLocais = $true
    $cboZE = $w.FindName('cboFiltroZE')
    $cboMun = $w.FindName('cboFiltroMun')
    $cboZE.ItemsSource  = @('Todas as ZE') + @($zes | ForEach-Object { 'ZE ' + $_ })
    $cboMun.ItemsSource = @('Todos os munic' + [char]0x00ED + 'pios') + $muns
    $cboZE.SelectedIndex  = 0
    $cboMun.SelectedIndex = 0
    $w.FindName('txtBuscaLocais').Text = ''
    $Global:AtualizandoFiltroLocais = $false

    Update-LocaisFiltrados
}

# Aplica busca + filtros e atualiza a grade.
function Update-LocaisFiltrados {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $busca = ([string] $w.FindName('txtBuscaLocais').Text).Trim()
    $selZE  = [string] $w.FindName('cboFiltroZE').SelectedItem
    $selMun = [string] $w.FindName('cboFiltroMun').SelectedItem
    $ze  = if ($selZE -and $selZE -like 'ZE *') { $selZE.Substring(3).Trim() } else { '' }
    $mun = if ($selMun -and $selMun -notlike 'Todos os munic*') { $selMun } else { '' }

    $lista = @($Global:LocaisTecnico)
    if ($ze)  { $lista = @($lista | Where-Object { "$($_.zona_eleitoral)" -eq $ze }) }
    if ($mun) { $lista = @($lista | Where-Object { "$($_.municipio_termo)" -eq $mun }) }
    if ($busca) {
        $alvo = $busca.ToLower()
        $lista = @($lista | Where-Object {
            $campos = @(
                [string] $_.nome, [string] $_.endereco, [string] $_.municipio_termo,
                [string] $_.municipio_sede, [string] $_.tipo_internet,
                ('ze ' + [string] $_.zona_eleitoral),
                [string] (Get-CampoLocal $_ 'responsavel'),
                [string] (Get-CampoLocal $_ 'unidade_consumidora'),
                [string] (Get-CampoLocal $_ 'telefone')
            )
            ($campos -join ' ').ToLower().Contains($alvo)
        })
    }

    $Global:AtualizandoFiltroLocais = $true
    $w.FindName('dgLocais').ItemsSource = @($lista)
    $Global:AtualizandoFiltroLocais = $false
    $w.FindName('txtLocaisContagem').Text = '{0} de {1}' -f @($lista).Count, @($Global:LocaisTecnico).Count
}

# Clicar numa linha da grade abre a ficha completa do local (tela dedicada).
function Invoke-AbrirLocalDetalhe {
    if ($Global:AtualizandoFiltroLocais) { return }
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $d = $w.FindName('dgLocais').SelectedItem
    if (-not $d) { return }

    $w.FindName('txtLDPTipo').Text = if ("$($d.tipo)" -eq 'principal') { 'LOCAL PRINCIPAL' } else { 'LOCAL DE CONTINGENCIA' }
    $w.FindName('txtLDPNome').Text = [string] $d.nome
    $w.FindName('txtLDPZE').Text   = Format-RotuloJunta $d.zona_eleitoral $d.municipio_termo $d.municipio_sede

    Set-LinhaDetalhe $w.FindName('txtLDPEndereco') ('Endere' + [char]0x00E7 + 'o') ([string] $d.endereco)
    Set-LinhaDetalhe $w.FindName('txtLDPInternet') 'Tipo de internet' ([string] $d.tipo_internet)
    Set-LinhaDetalhe $w.FindName('txtLDPUC') 'Unidade consumidora' ([string] (Get-CampoLocal $d 'unidade_consumidora'))

    $resp = [string] (Get-CampoLocal $d 'responsavel')
    $func = [string] (Get-CampoLocal $d 'funcao')
    if ($func) { $resp = '{0} ({1})' -f $resp, $func }
    Set-LinhaDetalhe $w.FindName('txtLDPResponsavel') ('Respons' + [char]0x00E1 + 'vel') $resp
    Set-LinhaDetalhe $w.FindName('txtLDPTelefone') 'Telefone/WhatsApp' ([string] (Get-CampoLocal $d 'telefone'))

    $comp = [string] (Get-CampoLocal $d 'texto_completo')
    $tc   = $w.FindName('txtLDPCompleto')
    $card = $w.FindName('cardLDPCompleto')
    if ($comp) { $tc.Text = $comp; $card.Visibility = 'Visible' } else { $card.Visibility = 'Collapsed' }

    $Global:LocalDetalheAtual = $d
    Update-StatusLocalDetalhe
    Update-CardGel
    Update-FotosGel

    Show-View 'viewLocalDetalhe'
}

# "Voltar aos locais": limpa a selecao (para reabrir a mesma linha depois) e
# volta para a lista com os filtros preservados.
function Invoke-VoltarAosLocais {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $Global:AtualizandoFiltroLocais = $true
    $w.FindName('dgLocais').SelectedIndex = -1
    $Global:AtualizandoFiltroLocais = $false
    Show-View 'viewLocais'
}

# ------------------------------------------------------------- ASSISTENTE (WIZARD)

function Show-WizardPasso {
    param([int] $N)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $nMax = $Global:WizardNPassos
    if ($N -lt 1) { $N = 1 }
    if ($N -gt $nMax) { $N = $nMax }
    $Global:WizardStep = $N

    for ($i = 0; $i -lt $nMax; $i++) {
        $vis = if ($i -eq ($N - 1)) { 'Visible' } else { 'Collapsed' }
        $w.FindName($Global:WizardPassos[$i]).Visibility = $vis
    }
    $w.FindName('txtWizTitulo').Text = $Global:WizardTitulos[$N - 1]
    $w.FindName('txtWizPasso').Text  = 'Passo {0} de {1}' -f $N, $nMax
    $w.FindName('prgWizard').Value   = $N

    $w.FindName('btnWizVoltar').IsEnabled = ($N -gt 1)
    $rf = $w.FindName('btnRefazerTeste'); if ($rf) { $rf.Visibility = 'Collapsed' }
    $prox = $w.FindName('btnWizProximo')
    $prox.Visibility = if ($N -lt $nMax) { 'Visible' } else { 'Collapsed' }
    $prox.Content    = if ($N -eq ($nMax - 1)) { 'Concluir' } else { 'Pr' + [char]0x00F3 + 'ximo' }
    $prox.IsEnabled  = $true

    switch ($N) {
        2 { Update-DetalheLocal }
        3 {
            if (-not $Global:FaseLocalPayload) { Invoke-ProbeRedeLocal }
            Update-PainelMeios
        }
        4 { Update-SeletorMedicoes }
        5 { Update-DecisaoRecalculada; Update-Passo6Recomendacao }
        6 { Update-ResumoFim }
    }
}

function Invoke-WizardVoltar {
    if ($Global:WizardStep -gt 1) { Show-WizardPasso ($Global:WizardStep - 1) }
}

function Invoke-WizardProximo {
    $w = $Global:JanelaPrincipal
    switch ($Global:WizardStep) {
        1 { Show-WizardPasso 2 }
        2 {
            if (-not $w.FindName('cboLocal').SelectedItem) {
                Write-Log 'Selecione a Junta Especial e o Local para continuar.' -Nivel Aviso
                return
            }
            Show-WizardPasso 3
        }
        3 {
            if ($Global:CheckMeioAtivo) {
                Write-Log 'Conclua a checagem do meio aberta antes de avancar.' -Nivel Aviso
                return
            }
            $todosNA = $Global:MeiosNaoAplicaveis.ContainsKey('lan') -and
                       $Global:MeiosNaoAplicaveis.ContainsKey('wifi_local') -and
                       $Global:MeiosNaoAplicaveis.ContainsKey('celular')
            $temMedicao = @($Global:Medicoes | Where-Object { $_ -and -not $_.nao_aplicavel }).Count -ge 1
            if (-not $temMedicao -and -not $todosNA) {
                Write-Log 'Rode a checagem em pelo menos um meio (ou marque os que nao se aplicam a este local).' -Nivel Aviso
                return
            }
            if ($todosNA -and -not $temMedicao -and -not $Global:DiagPayload) {
                Write-Log 'Todos os meios marcados como nao aplicaveis - o local sera registrado como inviavel.' -Nivel Aviso
                Set-DiagnosticoVpnImpossivel -Motivo 'Nenhum meio de conexao se aplica a este local.'
            }
            Show-WizardPasso 4
        }
        4 {
            Save-AjustesPasso5   # guarda a medicao aberta antes de checar
            $falta = Get-JustificativasFaltando -MetricasApenas
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 5
        }
        5 {
            $falta = Get-JustificativasFaltando
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            if (-not (Test-RecomendacaoValida)) { return }
            Show-WizardPasso 6
        }
    }
}

# Indice em $Global:Medicoes da medicao aberta no grid do passo 5 (-1 => a ultima).
function Get-IndiceMedicaoAberta {
    $meds = @($Global:Medicoes)
    if (-not $meds.Count) { return -1 }
    if ($Global:MedicaoPasso5Idx -ge 0 -and $Global:MedicaoPasso5Idx -lt $meds.Count) { return $Global:MedicaoPasso5Idx }
    return $meds.Count - 1
}

# Lista de itens sem justificativa obrigatoria (metricas ajustadas + decisao).
# No multi-meio, tambem confere os ajustes ja salvos nas outras medicoes.
function Get-JustificativasFaltando {
    param([switch] $MetricasApenas)
    $w = $Global:JanelaPrincipal
    $falta = @()
    foreach ($r in @($Global:AvaliacaoRows)) {
        if (($r.ClasseFinal -ne $r.ClasseAutomatica) -and [string]::IsNullOrWhiteSpace($r.Justificativa)) {
            $falta += $r.Rotulo
        }
    }
    $idxAberta = Get-IndiceMedicaoAberta
    for ($i = 0; $i -lt @($Global:Medicoes).Count; $i++) {
        if ($i -eq $idxAberta) { continue }   # essa esta no grid, ja conferida acima
        $m = $Global:Medicoes[$i]
        if (-not $m -or $m.nao_aplicavel -or -not $m.decisao) { continue }
        $auto = @{}
        foreach ($d in @($m.decisao.Detalhes)) { $auto[[string] $d.metrica] = [string] $d.classe }
        foreach ($a in @($m.avaliacoes)) {
            $mk = [string] $a.metrica
            if ($auto.ContainsKey($mk) -and ([string] $a.classe_final -ne $auto[$mk]) -and
                [string]::IsNullOrWhiteSpace([string] $a.justificativa)) {
                $falta += ('{0} / {1}' -f $m.rotulo, (Get-RotuloMetrica $mk))
            }
        }
    }
    if (-not $MetricasApenas) {
        $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
        $justDec  = [string] $w.FindName('txtJustDecisao').Text
        if ($decFinal -and $decFinal -ne $Global:DecisaoRecalculada -and [string]::IsNullOrWhiteSpace($justDec)) {
            $falta += 'Recomendacao final'
        }
    }
    return @($falta)
}

# Linha "<Rotulo>: <Valor>" do cartao de detalhe; oculta se o valor for vazio.
function Set-LinhaDetalhe {
    param($Ctrl, [string] $Rotulo, [string] $Valor)
    if (-not $Ctrl) { return }
    if ([string]::IsNullOrWhiteSpace($Valor)) { $Ctrl.Visibility = 'Collapsed'; return }
    $Ctrl.Text       = '{0}: {1}' -f $Rotulo, $Valor
    $Ctrl.Visibility = 'Visible'
}

# Preenche o cartao "Local selecionado" no passo 2.
function Update-DetalheLocal {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $sel  = $w.FindName('cboLocal').SelectedItem
    $card = $w.FindName('cardDetalheLocal')
    if (-not $card) { return }

    # Trocar de Local / voltar ao passo 2 invalida o inventario das placas:
    # ao reentrar no passo 3 um novo probe e feito do zero (as medicoes ja
    # registradas ficam - so somem quando o Local muda, mais abaixo).
    if ($Global:FaseLocalPayload) {
        $Global:FaseLocalPayload = $null
        $Global:FaseLocalTipo    = ''
        $Global:MeioSelecionado  = ''
    }
    if (-not $sel) {
        $card.Visibility = 'Collapsed'
        if ($Global:WizardStep -eq 2) {
            $w.FindName('btnWizProximo').Visibility   = 'Visible'
            $w.FindName('btnRefazerTeste').Visibility = 'Collapsed'
        }
        return
    }

    # trocou de Local -> as medicoes acumuladas eram do local anterior; o anexo
    # GEL do novo Local vem do disco (data/vistoria-gel/<id>.json).
    $idSel = [string] $sel.Dados.id
    if ($idSel -and $idSel -ne $Global:LocalMedicoesId) {
        if (@($Global:Medicoes).Count) { Write-Log 'Local trocado - medicoes anteriores descartadas.' -Nivel Aviso }
        Reset-Medicoes
        $Global:VistoriaGel = Get-VistoriaGel -LocalId $idSel
        $Global:LocalMedicoesId = $idSel
    }

    $d = $sel.Dados
    $w.FindName('txtDetTipo').Text     = if ($d.tipo -eq 'principal') { 'LOCAL PRINCIPAL' } else { 'LOCAL DE CONTINGENCIA' }
    $w.FindName('txtDetNome').Text     = [string] $d.nome
    $w.FindName('txtDetZE').Text       = Format-RotuloJunta $d.zona_eleitoral $d.municipio_termo $d.municipio_sede
    $w.FindName('txtDetEndereco').Text = [string] $d.endereco
    $w.FindName('txtDetInternet').Text = 'Internet: ' + [string] $d.tipo_internet

    $resp = Get-CampoLocal $d 'responsavel'
    $func = Get-CampoLocal $d 'funcao'
    if ($func) { $resp = '{0} ({1})' -f $resp, $func }
    Set-LinhaDetalhe $w.FindName('txtDetUC')          'Unidade consumidora'  (Get-CampoLocal $d 'unidade_consumidora')
    Set-LinhaDetalhe $w.FindName('txtDetResponsavel') 'Responsavel'          $resp
    Set-LinhaDetalhe $w.FindName('txtDetTelefone')    'Telefone/WhatsApp'    (Get-CampoLocal $d 'telefone')

    $feitos = Get-DiagnosticosRealizados -TecnicoNome $Global:SessaoAtual.tecnico_nome
    $t   = $feitos[[string] $d.id]
    $lbl = $w.FindName('txtDetTestado')
    if ($t) {
        $lbl.Text       = 'Ja diagnosticado em {0:dd/MM/yyyy HH:mm} - {1}' -f $t.Quando, (Get-RotuloVeredito $t.ClassificacaoFinal)
        $lbl.Foreground = Get-PincelVeredito $t.ClassificacaoFinal
    } else {
        $cinza = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
        $cinza.Freeze()
        $lbl.Text       = 'Ainda nao diagnosticado neste roteiro.'
        $lbl.Foreground = $cinza
    }
    $card.Visibility = 'Visible'

    # Passo 2: local ja testado (e nao ha diagnostico em andamento) -> some o
    # "Proximo" do rodape e aparece "Refazer o teste" no proprio cartao.
    if ($Global:WizardStep -eq 2) {
        $jaTestado = $t -and (-not $Global:DiagPayload)
        $w.FindName('btnWizProximo').Visibility   = if ($jaTestado) { 'Collapsed' } else { 'Visible' }
        $w.FindName('btnRefazerTeste').Visibility = if ($jaTestado) { 'Visible' } else { 'Collapsed' }
    }
}

# ----------------------------------------------------- ANEXO DO FORMULARIO GEL
# Vive na tela de detalhe do Local (viewLocalDetalhe) - o tecnico/admin anexa a
# qualquer tempo. Persistido em data/vistoria-gel/<localid>.json.

# Pincel verde/vermelho para os "dots" de status.
function Get-PincelStatus {
    param([bool] $Ok)
    $hex = if ($Ok) { '#4FC177' } else { '#E8695C' }
    $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze(); $b
}

# Preenche os 5 indicadores de status na tela de detalhe do Local.
function Update-StatusLocalDetalhe {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $d = $Global:LocalDetalheAtual
    $id = if ($d) { [string] $d.id } else { '' }
    $s = Get-StatusLocal -LocalId $id

    $verdVer = if ($s.veredito) { Get-PincelVeredito $s.veredito } else { Get-PincelStatus $false }
    $dt = $w.FindName('dotLdTestado');     if ($dt) { $dt.Fill = $verdVer }
    $ds = $w.FindName('dotLdSalvo');       if ($ds) { $ds.Fill = Get-PincelStatus $s.salvo }
    $dx = $w.FindName('dotLdTransmitido'); if ($dx) { $dx.Fill = Get-PincelStatus $s.transmitido }
    $de = $w.FindName('dotLdExportado');   if ($de) { $de.Fill = Get-PincelStatus $s.exportado }
    $dg = $w.FindName('dotLdGel');         if ($dg) { $dg.Fill = Get-PincelStatus $s.gel }

    $info = $w.FindName('txtLdStatusInfo')
    if ($info) {
        if ($s.testado) {
            $info.Text = 'Testado em {0:dd/MM/yyyy HH:mm} - {1}{2}' -f `
                $s.quando, (Get-RotuloVeredito $s.veredito), $(if ($s.transmitido) { '' } else { ' (nao transmitido)' })
        } else {
            $info.Text = 'Ainda nao diagnosticado neste roteiro.'
        }
    }
}

# Reflete no card do GEL (tela de detalhe) o que ja esta anexado ao Local.
function Update-CardGel {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $card = $w.FindName('cardGel'); if (-not $card) { return }
    $w.FindName('panelGelConf').Visibility = 'Collapsed'

    $d  = $Global:LocalDetalheAtual
    $g  = if ($d) { Get-VistoriaGel -LocalId ([string] $d.id) } else { $null }
    $res = $w.FindName('txtGelResumo')
    $stx = $w.FindName('txtGelStatus')
    $btnR = $w.FindName('btnGelRemover')
    $btnA = $w.FindName('btnAnexarGel')

    if ($g) {
        $partes = @()
        if ($null -ne $g.lat -and $null -ne $g.long) { $partes += ('coordenadas {0}, {1}' -f $g.lat, $g.long) }
        if ($g.esfera_administrativa -or $g.localizacao -or $g.tipo_local) { $partes += 'tipo do local' }
        if ($g.agua -or $g.iluminacao -or $g.salas_necessarias -or $g.predio_reforma) { $partes += 'infraestrutura' }
        if ($g.eletrica_tensao -or $g.eletrica_tomadas -or $g.eletrica_extensao -or $g.quadro_energia) { $partes += 'dados eletricos' }
        if ($g.suporte_nome -or $g.suporte_telefone) { $partes += 'suporte do link' }
        $nf = @(Get-FotosGel -LocalId ([string] $d.id)).Count
        if ($nf) { $partes += ('{0} foto(s)' -f $nf) }
        $res.Text = 'Formulario GEL anexado: ' + ($partes -join ' - ')
        $res.Visibility = 'Visible'
        $stx.Text = ''
        if ($btnA) { $btnA.Content = 'Substituir formulario GEL (PDF)' }
        if ($btnR) { $btnR.Visibility = 'Visible' }
    } else {
        $res.Visibility = 'Collapsed'
        $stx.Text = ''
        if ($btnA) { $btnA.Content = 'Anexar formulario GEL (PDF)' }
        if ($btnR) { $btnR.Visibility = 'Collapsed' }
    }
}

# Botao "Remover anexo": apaga o GEL do Local (PDF + fotos).
function Invoke-GelRemover {
    $d = $Global:LocalDetalheAtual
    if (-not $d) { return }
    Remove-VistoriaGel -LocalId ([string] $d.id)
    if ([string] $d.id -eq [string] $Global:LocalMedicoesId) { $Global:VistoriaGel = $null }
    Write-Log 'Anexo GEL removido do local.' -Nivel Aviso
    Update-CardGel
    Update-FotosGel
    Update-StatusLocalDetalhe
}

# Lista as fotos ja anexadas ao Local na tela de detalhe.
function Update-FotosGel {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $lst = $w.FindName('lstGelFotos'); if (-not $lst) { return }
    $lst.Items.Clear()
    $d = $Global:LocalDetalheAtual
    $fotos = if ($d) { @(Get-FotosGel -LocalId ([string] $d.id)) } else { @() }
    foreach ($f in $fotos) { [void] $lst.Items.Add((Split-Path $f -Leaf)) }
    $rs = $w.FindName('txtGelFotosResumo')
    if ($rs) { $rs.Text = if ($fotos.Count) { '{0} foto(s) anexada(s)' -f $fotos.Count } else { 'nenhuma foto anexada' } }
}

# Botao "Adicionar fotos": seletor multiplo, reduz e grava cada uma no Local.
function Invoke-GelAddFotos {
    $d = $Global:LocalDetalheAtual
    if (-not $d) { return }
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtGelStatus')
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Imagens (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png'
    $dlg.Title  = 'Selecione as fotos baixadas do GEL web'
    $dlg.Multiselect = $true
    if (-not $dlg.ShowDialog()) { return }

    $ok = 0; $erro = 0
    foreach ($arq in $dlg.FileNames) {
        try { Add-FotoGel -LocalId ([string] $d.id) -Caminho $arq | Out-Null; $ok++ }
        catch { $erro++; Write-Log ("Foto GEL '{0}' nao entrou: {1}" -f (Split-Path $arq -Leaf), $_) -Nivel Aviso }
    }
    if ($st) { $st.Text = "Fotos adicionadas: $ok" + $(if ($erro) { " ($erro falharam)" } else { '' }) }
    Write-Log ("Fotos do GEL: {0} adicionada(s) ao local {1}." -f $ok, $d.nome) -Nivel Ok
    Update-FotosGel
    Update-CardGel
    Update-StatusLocalDetalhe
}

# Botao "Remover selecionada": tira a foto marcada na lista.
function Invoke-GelFotoRemover {
    $d = $Global:LocalDetalheAtual
    if (-not $d) { return }
    $w = $Global:JanelaPrincipal
    $sel = [string] $w.FindName('lstGelFotos').SelectedItem
    if (-not $sel) { Write-Log 'Selecione uma foto na lista para remover.' -Nivel Aviso; return }
    Remove-FotoGel -LocalId ([string] $d.id) -Nome $sel
    Write-Log ("Foto '{0}' removida do local." -f $sel) -Nivel Aviso
    Update-FotosGel
    Update-CardGel
    Update-StatusLocalDetalhe
}

# Botao "Anexar formulario GEL (PDF)": abre o seletor, le o PDF e preenche a
# tela de conferencia.
function Invoke-AnexarGel {
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtGelStatus')
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PDF do GEL (*.pdf)|*.pdf'
    $dlg.Title  = 'Selecione o PDF da vistoria do GEL'
    if (-not $dlg.ShowDialog()) { return }

    $st.Text = 'Lendo o PDF...'
    try {
        $txt = Read-TextoPdf -Caminho $dlg.FileName
    } catch {
        $st.Text = "Nao consegui ler o PDF: $_"
        Write-Log "Anexo GEL - leitura falhou: $_" -Nivel Erro
        return
    }
    $p = ConvertFrom-VistoriaGel -Texto $txt
    if (-not $p.achou_algo) {
        $st.Text = 'PDF lido, mas nao reconheci os campos do GEL. Preencha na mao abaixo se quiser.'
    } else {
        $st.Text = 'Campos extraidos - confira e ajuste.'
    }
    $w.FindName('txtGelLat').Text         = if ($null -ne $p.lat)  { "$($p.lat)"  } else { '' }
    $w.FindName('txtGelLong').Text        = if ($null -ne $p.long) { "$($p.long)" } else { '' }
    $w.FindName('txtGelPrec').Text        = if ($null -ne $p.precisao_m) { "$($p.precisao_m)" } else { '' }
    $w.FindName('txtGelEsfera').Text      = [string] $p.esfera_administrativa
    $w.FindName('txtGelLocalizacao').Text = [string] $p.localizacao
    $w.FindName('txtGelTipoLocal').Text   = [string] $p.tipo_local
    $w.FindName('txtGelSalas').Text       = [string] $p.salas_necessarias
    $w.FindName('txtGelAgua').Text        = [string] $p.agua
    $w.FindName('txtGelClima').Text       = [string] $p.climatizacao
    $w.FindName('txtGelIluminacao').Text  = [string] $p.iluminacao
    $w.FindName('txtGelAguaPot').Text     = [string] $p.agua_potavel
    $w.FindName('txtGelReforma').Text     = [string] $p.predio_reforma
    $w.FindName('txtGelQuadro').Text      = [string] $p.quadro_energia
    $w.FindName('txtGelEnergia').Text     = [string] $p.energia_eletrica
    $w.FindName('txtGelTensao').Text      = [string] $p.eletrica_tensao
    $w.FindName('txtGelTomadas').Text     = [string] $p.eletrica_tomadas
    $w.FindName('txtGelExtensao').Text    = [string] $p.eletrica_extensao
    $w.FindName('txtGelSupNome').Text     = [string] $p.suporte_nome
    $w.FindName('txtGelSupTel').Text      = [string] $p.suporte_telefone
    $w.FindName('panelGelConf').Visibility = 'Visible'
    $w.FindName('txtGelResumo').Visibility = 'Collapsed'
}

function Invoke-GelCancelar {
    $w = $Global:JanelaPrincipal
    $w.FindName('panelGelConf').Visibility = 'Collapsed'
    Update-CardGel
}

# "Registrar": grava o que esta na tela de conferencia no Local (disco).
function Invoke-GelRegistrar {
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtGelStatus')
    $d  = $Global:LocalDetalheAtual
    if (-not $d) { return }

    $latTxt  = (([string] $w.FindName('txtGelLat').Text)  -replace ',', '.').Trim()
    $longTxt = (([string] $w.FindName('txtGelLong').Text) -replace ',', '.').Trim()
    $precTxt = (([string] $w.FindName('txtGelPrec').Text) -replace ',', '.').Trim()

    $lat = $null; $long = $null; $prec = $null
    $la = 0.0; $lo = 0.0; $pr = 0.0
    if ($latTxt -and [double]::TryParse($latTxt, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $la)) { $lat = $la }
    if ($longTxt -and [double]::TryParse($longTxt, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $lo)) { $long = $lo }
    if ($precTxt -and [double]::TryParse($precTxt, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $pr)) { $prec = $pr }

    if (($latTxt -or $longTxt) -and ($null -eq $lat -or $null -eq $long)) {
        $st.Text = 'Latitude/Longitude invalidas (use ponto decimal, ex.: -2.4997476).'
        return
    }

    $tb = { param($n) ([string] $w.FindName($n).Text).Trim() }
    $obj = [pscustomobject]@{
        lat                   = $lat
        long                  = $long
        precisao_m            = $prec
        esfera_administrativa = & $tb 'txtGelEsfera'
        localizacao           = & $tb 'txtGelLocalizacao'
        tipo_local            = & $tb 'txtGelTipoLocal'
        salas_necessarias     = & $tb 'txtGelSalas'
        agua                  = & $tb 'txtGelAgua'
        climatizacao          = & $tb 'txtGelClima'
        iluminacao            = & $tb 'txtGelIluminacao'
        agua_potavel          = & $tb 'txtGelAguaPot'
        predio_reforma        = & $tb 'txtGelReforma'
        quadro_energia        = & $tb 'txtGelQuadro'
        energia_eletrica      = & $tb 'txtGelEnergia'
        eletrica_tensao       = & $tb 'txtGelTensao'
        eletrica_tomadas      = & $tb 'txtGelTomadas'
        eletrica_extensao     = & $tb 'txtGelExtensao'
        suporte_nome          = & $tb 'txtGelSupNome'
        suporte_telefone      = & $tb 'txtGelSupTel'
        mapa_link             = if ($null -ne $lat -and $null -ne $long) { Get-LinkGoogleMaps -Lat $lat -Long $long } else { '' }
        anexado_em            = (Get-Date).ToString('o')
    }
    Save-VistoriaGel -LocalId ([string] $d.id) -Dados $obj | Out-Null
    if ([string] $d.id -eq [string] $Global:LocalMedicoesId) { $Global:VistoriaGel = $obj }
    Write-Log ('Formulario GEL anexado ao local {0}.' -f $d.nome) -Nivel Ok
    Update-CardGel
    Update-StatusLocalDetalhe
}

# ------------------------------------------------------------- PASSO 3: REDE LOCAL

# Roda -Script (texto, avaliado no runspace) fora da thread de UI e chama
# -AoConcluir($resultado, $erro) de volta na UI. -Vars entra no runspace por nome.
# Mesmo padrao de Start-DiagnosticoAssincrono; um slot ($Global:TarefaRedeState).
function Start-TarefaRede {
    param(
        [Parameter(Mandatory)] [string] $Script,
        [Parameter(Mandatory)] [scriptblock] $AoConcluir,
        [hashtable] $Vars = @{}
    )
    if ($Global:TarefaRedeState) { return }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    foreach ($v in 'RaizApp', 'LogEntries', 'LogHome', 'LogHomeMax', 'JanelaPrincipal', 'ArquivoLog', 'PastaDadosOverride') {
        $rs.SessionStateProxy.SetVariable($v, (Get-Variable -Name $v -Scope Global -ValueOnly -ErrorAction SilentlyContinue))
    }
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable([string] $k, $Vars[$k]) }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void] $ps.AddScript({
        param($sbTexto)
        # tudo dentro do try: falha ao importar o modulo tem de voltar como
        # texto de erro, nao derrubar o pipeline (que reaparece como "o fluxo
        # nao era legivel" no EndInvoke).
        try {
            Import-Module (Join-Path $RaizApp 'src\Conectividade.psd1') -Force -ErrorAction Stop
            [pscustomobject]@{ Resultado = (& ([scriptblock]::Create($sbTexto))); Erro = $null }
        } catch {
            [pscustomobject]@{ Resultado = $null; Erro = "$_" }
        }
    }).AddArgument($Script)

    $handle = $ps.BeginInvoke()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $Global:TarefaRedeState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer; AoConcluir = $AoConcluir; Concluido = $false; Inicio = (Get-Date); LimiteS = 150 }

    $timer.Add_Tick({
      # Blindagem total: nada aqui pode escapar para o loop do ShowDialog
      # (senao a janela fecha com "excecao ao chamar ShowDialog").
      try {
        $st = $Global:TarefaRedeState
        if ($null -eq $st -or $st.Concluido) { return }
        # Watchdog: se o runspace travou (ex.: netsh/CIM sem responder), nao
        # deixa o passo 3 "verificando..." pra sempre - aborta e sinaliza erro.
        if (-not $st.Handle.IsCompleted) {
            if (((Get-Date) - $st.Inicio).TotalSeconds -lt $st.LimiteS) { return }
            $st.Concluido = $true
            $st.Timer.Stop()
            $Global:TarefaRedeState = $null
            # nao chamar .Stop()/.EndInvoke() num pipeline travado (pode prender a
            # thread de UI). So dispose - a thread do runspace fica abandonada.
            try { $st.PS.Dispose() } catch { }
            try { $st.RS.Dispose() } catch { }
            try { & $st.AoConcluir $null 'a checagem demorou demais e foi cancelada (verifique o Wi-Fi/servico de rede)' } catch {
                try { Set-FaseLocalOcupado $false } catch { }
            }
            return
        }
        # Concluido: se um tick ja enfileirado disparar de novo (o processamento
        # abaixo demora mais que o intervalo do timer), ele nao pode reprocessar
        # o mesmo slot -> senao dava EndInvoke/Dispose em dobro ("o fluxo nao era
        # legivel").
        $st.Concluido = $true
        $st.Timer.Stop()
        $Global:TarefaRedeState = $null

        $res = $null; $erro = $null
        try {
            $r = $st.PS.EndInvoke($st.Handle) | Select-Object -First 1
            $res = $r.Resultado; $erro = $r.Erro
        } catch { $erro = "$_" } finally { try { $st.PS.Dispose(); $st.RS.Dispose() } catch { } }

        try { & $st.AoConcluir $res $erro } catch {
            Write-Log "Pos-processamento de rede falhou: $_" -Nivel Erro
            try { Set-FaseLocalOcupado $false } catch { }   # nao deixa o passo 3 travado
        }
      } catch {
        try { Write-Log "Tarefa de rede: falha inesperada ($_)." -Nivel Erro } catch { }
        try { Set-FaseLocalOcupado $false } catch { }
      }
    })
    $timer.Start()
}

# Trava a navegacao + o botao de reler placas enquanto o probe/checagem roda.
function Set-FaseLocalOcupado {
    param([bool] $Ocupado)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    foreach ($n in 'btnRelerPlacas', 'btnRelerLan', 'btnRelerWifi', 'btnRelerCel',
        'btnWizProximo', 'btnWizVoltar',
        'btnCheckLan', 'btnCheckWifi', 'btnCheckCelular') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
    $r = $w.FindName('ringMeios')
    if ($r) { $r.IsActive = $Ocupado; $r.Visibility = if ($Ocupado) { 'Visible' } else { 'Collapsed' } }
}

# Nome do checkbox "nao se aplica" de cada meio.
function Get-ChkNaNome {
    param([string] $Meio)
    switch ($Meio) { 'lan' { 'chkNaLan' } 'wifi_local' { 'chkNaWifi' } 'celular' { 'chkNaCelular' } default { '' } }
}

# Abre o card de justificativa "nao se aplica" para um meio.
function Open-CardNaJustif {
    param([string] $Meio)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    # ja havia outro meio pendente sem registrar -> desmarca o checkbox dele
    if ($Global:NaMeioPendente -and $Global:NaMeioPendente -ne $Meio) {
        $c = $w.FindName((Get-ChkNaNome $Global:NaMeioPendente)); if ($c) { $c.IsChecked = $false }
    }
    $Global:NaMeioPendente = $Meio
    $w.FindName('txtNaJustifMeio').Text = 'Meio: ' + (Get-RotuloMeio $Meio '')
    $ja = if ($Global:MeiosNaoAplicaveis.ContainsKey($Meio)) { [string] $Global:MeiosNaoAplicaveis[$Meio] } else { '' }
    $w.FindName('txtNaJustif').Text = $ja
    $w.FindName('cardNaJustif').Visibility = 'Visible'
    try { $w.FindName('txtNaJustif').Focus() } catch { }
}

# Botao "Registrar" do card de justificativa: grava e fecha; o motivo aparece
# no card do meio, em vermelho (inviavel).
function Invoke-NaRegistrar {
    $w = $Global:JanelaPrincipal
    $meio = [string] $Global:NaMeioPendente
    if (-not $meio) { $w.FindName('cardNaJustif').Visibility = 'Collapsed'; return }
    $motivo = ([string] $w.FindName('txtNaJustif').Text).Trim()
    if (-not $motivo) { Write-Log 'Informe a justificativa antes de registrar.' -Nivel Aviso; return }
    Set-MeioNaoAplicavel -Meio $meio -Motivo $motivo
    $Global:NaMeioPendente = ''
    $w.FindName('txtNaJustif').Text = ''
    $w.FindName('cardNaJustif').Visibility = 'Collapsed'
    Write-Log ('Meio {0} marcado como NAO APLICAVEL (inviavel): {1}' -f (Get-RotuloMeio $meio ''), $motivo) -Nivel Aviso
    Update-PainelMeios
}

# Botao "Cancelar" do card de justificativa: fecha e desmarca o checkbox se o
# meio ainda nao estava registrado.
function Invoke-NaCancelar {
    $w = $Global:JanelaPrincipal
    $meio = [string] $Global:NaMeioPendente
    $Global:NaMeioPendente = ''
    $w.FindName('cardNaJustif').Visibility = 'Collapsed'
    $w.FindName('txtNaJustif').Text = ''
    if ($meio -and -not $Global:MeiosNaoAplicaveis.ContainsKey($meio)) {
        $c = $w.FindName((Get-ChkNaNome $meio)); if ($c) { $c.IsChecked = $false }
    }
    Update-PainelMeios
}

# Handler do clique nos checkboxes "nao se aplica": marcou -> abre o card de
# justificativa; desmarcou -> remove o "nao aplicavel".
function Update-NaoAplicavelMeio {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    foreach ($m in @(@('chkNaLan', 'lan'), @('chkNaWifi', 'wifi_local'), @('chkNaCelular', 'celular'))) {
        $chk  = $w.FindName($m[0])
        $meio = $m[1]
        if (-not $chk) { continue }
        $marcado    = [bool] $chk.IsChecked
        $registrado = $Global:MeiosNaoAplicaveis.ContainsKey($meio)
        $pendente   = ($Global:NaMeioPendente -eq $meio)
        if ($marcado -and -not $registrado -and -not $pendente) {
            Open-CardNaJustif -Meio $meio
        } elseif (-not $marcado -and $registrado) {
            $Global:MeiosNaoAplicaveis.Remove($meio)
            $Global:Medicoes = @($Global:Medicoes | Where-Object { -not ($_.meio -eq $meio -and $_.nao_aplicavel) })
        } elseif (-not $marcado -and $pendente) {
            $Global:NaMeioPendente = ''
            $w.FindName('cardNaJustif').Visibility = 'Collapsed'
            $w.FindName('txtNaJustif').Text = ''
        }
    }
    Update-PainelMeios
}

# Passo 3: preenche os 3 cards de meio (inventario das placas + estado da
# checagem) e libera o botao "Rodar checagem" de cada card.
function Update-PainelMeios {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $card = $w.FindName('cardFaseLocal')
    $p = $Global:FaseLocalPayload

    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $cinza    = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
    $cinza.Freeze()
    $hair = $w.TryFindResource('Dicon.Hair')

    $cardWifi = $w.FindName('cardWifiBandeja')

    $rm = $w.FindName('ringMeios')
    if (-not $p) {
        if ($card) { $card.Visibility = 'Collapsed' }
        if ($cardWifi) { $cardWifi.Visibility = 'Collapsed' }
        $w.FindName('cardRecMeios').Visibility = 'Collapsed'
        $w.FindName('txtLocEscolha').Text = 'Verificando as placas de rede deste computador...'
        if ($rm) { $rm.IsActive = $true; $rm.Visibility = 'Visible' }
        foreach ($n in 'btnCheckLan', 'btnCheckWifi', 'btnCheckCelular') {
            $b = $w.FindName($n); if ($b) { $b.IsEnabled = $false }
        }
        return
    }
    if ($rm) { $rm.IsActive = $false; $rm.Visibility = 'Collapsed' }
    $w.FindName('txtLocEscolha').Text = 'Rode a checagem de cada meio que serve a este local. Marque os que nao se aplicam.'

    $lan = $p.Lan; $wf = $p.Wireless
    $hostNb = if ($p.PSObject.Properties['Host']) { [string] $p.Host } else { '' }
    Set-LinhaDetalhe $w.FindName('txtLocHost') 'Computador' $hostNb

    $lanUp = [bool] $lan.conectado
    $tl = $w.FindName('txtLocLan'); $dl = $w.FindName('dotLan')
    if ($lanUp) {
        $tl.Text = 'Conectada' + $(if ($lan.nome) { " - $($lan.nome)" } else { '' })
        $tl.Foreground = $verde ; $dl.Fill = $verde
    } elseif ($lan.presente) {
        $tl.Text = 'Placa ativa, sem conexao (cabo fora / sem IP)'
        $tl.Foreground = $vermelho ; $dl.Fill = $vermelho
    } else {
        $tl.Text = 'Nenhuma placa cabeada neste computador'
        $tl.Foreground = $cinza ; $dl.Fill = $cinza
    }

    Set-LinhaDetalhe $w.FindName('txtLocIp')      'IP na rede local' ([string] $lan.ipv4)
    Set-LinhaDetalhe $w.FindName('txtLocGateway') 'Gateway'          ([string] $lan.gateway)
    Set-LinhaDetalhe $w.FindName('txtLocMascara') 'Mascara'          ([string] $lan.mascara)
    Set-LinhaDetalhe $w.FindName('txtLocDns')     'DNS'              ((@($lan.dns)) -join ', ')
    Set-LinhaDetalhe $w.FindName('txtLocMac')     'MAC'              ([string] $lan.mac)
    Set-LinhaDetalhe $w.FindName('txtLocVel')     'Enlace'          $(if ($lan.velocidade_mbps) { "$($lan.velocidade_mbps) Mbps" } else { '' })
    Set-LinhaDetalhe $w.FindName('txtLocOrigem')  'Obtencao do IP'   ([string] $lan.ip_origem)

    # IP 10.11.* / 10.198.* na placa cabeada = notebook plugado na rede da JE.
    $je = $w.FindName('cardLocJE')
    if ($je) {
        $ehJE = $lanUp -and (Test-RedeJusticaEleitoral ([string] $lan.ipv4))
        $je.Visibility = if ($ehJE) { 'Visible' } else { 'Collapsed' }
    }

    $wifiUp = [bool] $wf.conectado
    $tw = $w.FindName('txtLocWifi'); $dw = $w.FindName('dotWifi')
    if ($wifiUp) {
        $tw.Text = 'Conectada a "{0}" ({1}%)' -f $wf.ssid, $wf.sinal_pct
        $tw.Foreground = $verde ; $dw.Fill = $verde
    } elseif ($wf.presente) {
        $n = (@($wf.redes_disponiveis)).Count
        $tw.Text = 'Placa ativa, nao conectada' + $(if ($n) { " - $n rede(s) por perto" } else { '' })
        $tw.Foreground = if ($lanUp) { $cinza } else { $vermelho }
        $dw.Fill       = if ($lanUp) { $cinza } else { $vermelho }
    } else {
        $tw.Text = 'Sem placa Wi-Fi neste computador'
        $tw.Foreground = $cinza ; $dw.Fill = $cinza
    }
    Set-LinhaDetalhe $w.FindName('txtLocWifiIp')   'IP na rede local' $(if ($wifiUp) { [string] $wf.ipv4 } else { '' })
    Set-LinhaDetalhe $w.FindName('txtLocWifiGw')   'Gateway'          $(if ($wifiUp) { [string] $wf.gateway } else { '' })
    Set-LinhaDetalhe $w.FindName('txtLocWifiMask') 'Mascara'          $(if ($wifiUp) { [string] $wf.mascara } else { '' })
    Set-LinhaDetalhe $w.FindName('txtLocWifiMac')  'MAC'              $(if ($wifiUp) { [string] $wf.mac } else { '' })
    Set-LinhaDetalhe $w.FindName('txtLocWifiOrigem') 'Obtencao do IP' $(if ($wifiUp) { [string] $wf.ip_origem } else { '' })
    $twd = $w.FindName('txtLocWifiDet')
    if ($twd) {
        $twd.Text = if ($wifiUp) {
            $nn = (@($wf.redes_disponiveis)).Count
            if ($nn) { "$nn outra(s) rede(s) por perto" } else { '' }
        } else { '' }
        $twd.Visibility = if ($twd.Text) { 'Visible' } else { 'Collapsed' }
    }

    $tcel = $w.FindName('txtLocCel')
    if ($tcel) {
        $tcel.Text = if ($wifiUp) { 'Conectado a "{0}" ({1}%)' -f $wf.ssid, $wf.sinal_pct }
                     elseif ($wf.presente) { 'Placa Wi-Fi ativa, nao conectada. Conecte a rede do celular.' }
                     else { 'Sem placa Wi-Fi neste computador.' }
        $tcel.Foreground = if ($wifiUp) { $verde } else { $cinza }
    }

    # A placa Wi-Fi so fica numa rede por vez: o tecnico escolhe, clicando no card,
    # se essa rede e o Wi-Fi do local (card WI-FI) ou o roteamento do celular (card
    # CELULAR). O card selecionado ganha borda azul e libera o "Rodar checagem".
    $sel = [string] $Global:MeioSelecionado
    if ($sel) {
        $selNaKey = if ($sel -eq 'wifi') { 'wifi_local' } else { $sel }
        if ($Global:MeiosNaoAplicaveis.ContainsKey($selNaKey) -or $Global:NaMeioPendente -eq $selNaKey) {
            $Global:MeioSelecionado = ''; $sel = ''
        }
    }
    # caso obvio: so a LAN conectada (sem Wi-Fi) -> ja seleciona a LAN. Com Wi-Fi
    # conectado a escolha e do tecnico (Wi-Fi do local x roteamento do celular).
    if (-not $sel -and $lanUp -and -not $wifiUp -and -not $Global:MeiosNaoAplicaveis.ContainsKey('lan')) {
        $Global:MeioSelecionado = 'lan'; $sel = 'lan'
    }
    $tws = $w.FindName('txtWifiSelDica')
    if ($tws) { $tws.Visibility = if ($wifiUp -and $sel -ne 'wifi') { 'Visible' } else { 'Collapsed' } }
    $tcd = $w.FindName('txtCelDica')
    if ($tcd) {
        $tcd.Text = if (-not $wifiUp) {
            'Ligue o roteamento no celular, conecte a rede dele pela bandeja do Windows, clique neste card e informe a operadora.'
        } elseif ($sel -eq 'celular') {
            'Rede "{0}" sera testada como roteamento de celular. Informe a operadora e rode a checagem.' -f $wf.ssid
        } else {
            'Se "{0}" e o roteamento do seu celular, clique neste card para seleciona-lo e informe a operadora.' -f $wf.ssid
        }
    }

    # --- estado (badge + borda) e botao de cada meio ----------------------
    $estadoMeio = {
        param($meio)
        if ($Global:MeiosNaoAplicaveis.ContainsKey($meio)) {
            $ci = Get-PincelVeredito 'inviavel'
            return @{ txt = 'NAO SE APLICA - INVIAVEL'; cor = $ci; borda = $ci }
        }
        $m = @($Global:Medicoes | Where-Object { $_.meio -eq $meio -and -not $_.nao_aplicavel } | Select-Object -Last 1)
        if ($m) {
            $c = Get-PincelVeredito $m.veredito
            return @{ txt = 'TESTADO: ' + (Get-PalavraVeredito $m.veredito).ToUpper(); cor = $c; borda = $c }
        }
        @{ txt = 'NAO TESTADO'; cor = $cinza; borda = $hair }
    }
    $operCel = ([string] $w.FindName('cboOperadoraCel').Text).Trim()
    $livre   = -not $Global:CheckMeioAtivo
    $azulSel = $w.TryFindResource('Dicon.Accent')
    if (-not $azulSel) {
        $azulSel = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'))
        $azulSel.Freeze()
    }

    # (card, badge, meio, botao, selKey, conectado, extraOK)
    # Wi-Fi do local x Celular: a mesma conexao Wi-Fi; o que decide qual meio roda
    # e o card selecionado (borda azul). Celular ainda exige a operadora.
    $defs = @(
        @('cardLan',       'badgeLan',      'lan',        'btnCheckLan',      'lan',      $lanUp,                 $true),
        @('cardWifiPlaca', 'badgeWifi',     'wifi_local', 'btnCheckWifi',     'wifi',     ([bool] $wf.conectado), $true),
        @('cardCelular',   'badgeCelular',  'celular',    'btnCheckCelular',  'celular',  ([bool] $wf.conectado), [bool] $operCel)
    )
    foreach ($d in $defs) {
        $cd    = $w.FindName($d[0])
        $badge = $w.FindName($d[1])
        $meio  = $d[2]
        $btn   = $w.FindName($d[3])
        $selKey    = $d[4]
        $conectado = [bool] $d[5]
        $extraOK   = [bool] $d[6]
        $naMeio = $Global:MeiosNaoAplicaveis.ContainsKey($meio)
        $selecionado = ($sel -eq $selKey) -and -not $naMeio

        $e = & $estadoMeio $meio
        if ($badge) { $badge.Text = $e.txt; $badge.Foreground = $e.cor }
        if ($cd) {
            $cd.BorderBrush     = if ($selecionado) { $azulSel } else { $e.borda }
            $cd.BorderThickness = [Windows.Thickness]::new($(if ($selecionado) { 2.5 } else { 2 }))
            $cd.Opacity         = if ($naMeio) { 0.6 } else { 1.0 }
        }
        if ($btn) {
            $btn.IsEnabled = $selecionado -and $conectado -and $extraOK -and -not $naMeio -and $livre
            $btn.Content   = if (@($Global:Medicoes | Where-Object { $_.meio -eq $meio -and -not $_.nao_aplicavel }).Count) {
                'Refazer checagem'
            } else { 'Rodar checagem' }
        }
    }

    # sincroniza os checkboxes "nao aplicavel" e mostra o motivo registrado no card
    foreach ($par in @(
        @('chkNaLan', 'lan', 'txtNaMotivoCardLan'),
        @('chkNaWifi', 'wifi_local', 'txtNaMotivoCardWifi'),
        @('chkNaCelular', 'celular', 'txtNaMotivoCardCelular'))) {
        $meio = $par[1]
        $na   = $Global:MeiosNaoAplicaveis.ContainsKey($meio)
        $pend = ($Global:NaMeioPendente -eq $meio)
        $c = $w.FindName($par[0])
        if ($c) { $alvo = ($na -or $pend); if ([bool] $c.IsChecked -ne $alvo) { $c.IsChecked = $alvo } }
        $tt = $w.FindName($par[2])
        if ($tt) {
            if ($na) { $tt.Text = 'Nao se aplica: ' + [string] $Global:MeiosNaoAplicaveis[$meio]; $tt.Visibility = 'Visible' }
            else { $tt.Text = ''; $tt.Visibility = 'Collapsed' }
        }
    }

    if ($cardWifi) { $cardWifi.Visibility = if ($wf.presente) { 'Visible' } else { 'Collapsed' } }
    $card.Visibility = 'Visible'
    Update-BannerRecomendacao
}

# Banner "Recomendacao para este local: usar <meio>" no passo 3 (aparece quando
# ha pelo menos um meio testado).
function Update-BannerRecomendacao {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $card = $w.FindName('cardRecMeios')
    if (-not $card) { return }
    $testados = @($Global:Medicoes | Where-Object { $_ -and -not $_.nao_aplicavel -and $_.veredito -ne 'nao_testado' })
    if (-not $testados.Count) { $card.Visibility = 'Collapsed'; return }

    $rec = Get-RecomendacaoLocal
    $card.Visibility = 'Visible'
    if (-not $rec -or $rec.meio -eq 'nenhuma') {
        $w.FindName('txtRecMeios').Text = 'Recomendacao para este local: nenhum meio testado ate agora serve. Continue testando os outros meios.'
    } else {
        $w.FindName('txtRecMeios').Text = 'Recomendacao para este local: usar {0} -- {1}.' -f $rec.rotulo, (Get-RotuloVeredito $rec.veredito)
    }
    $obs = $w.FindName('txtRecMeiosObs')
    if ($rec -and $rec.provisoria) {
        $obs.Text = 'Provisoria: nenhum meio fechou a VPN. Teste os demais meios ou conclua sabendo que o local fica inviavel.'
        $obs.Visibility = 'Visible'
    } else { $obs.Visibility = 'Collapsed' }
}

# Probe rapido ao ENTRAR no passo 3: so inventaria as placas (sem internet).
# Botao de recarregar (canto da tela do passo 3): reinventaria as placas -
# pega cabo plugado/desplugado e mudanca de Wi-Fi sem sair do passo.
function Invoke-RelerPlacas {
    if ($Global:TarefaRedeState -or $Global:CheckMeioAtivo) {
        Write-Log 'Aguarde a checagem em andamento terminar.' -Nivel Aviso
        return
    }
    Write-Log 'Relendo TODAS as placas de rede...' -Nivel Info
    Invoke-ProbeRedeLocal
}

# Spinner + trava so no card da placa que esta sendo relida (nao no probe geral).
function Set-RelerAdaptadorOcupado {
    param([string] $Tipo, [bool] $Ocupado)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $rings = if ($Tipo -eq 'lan') { @('ringRelerLan') } else { @('ringRelerWifi', 'ringRelerCel') }
    foreach ($n in $rings) {
        $r = $w.FindName($n)
        if ($r) { $r.IsActive = $Ocupado; $r.Visibility = if ($Ocupado) { 'Visible' } else { 'Collapsed' } }
    }
    # uma tarefa de rede por vez: trava tudo enquanto roda; ao liberar, o
    # Update-PainelMeios recalcula o estado real dos botoes "Rodar checagem".
    foreach ($n in 'btnRelerPlacas', 'btnRelerLan', 'btnRelerWifi', 'btnRelerCel', 'btnWizProximo', 'btnWizVoltar') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
    if ($Ocupado) {
        foreach ($n in 'btnCheckLan', 'btnCheckWifi', 'btnCheckCelular') {
            $c = $w.FindName($n); if ($c) { $c.IsEnabled = $false }
        }
    }
}

# Botao (do card) para reler SO uma placa - preserva o que ja foi coletado da
# outra. Ex.: ja testei a LAN, tirei o cabo e liguei o Wi-Fi -> releio so o
# Wi-Fi e o card LAN mantem o IP/gateway/... da coleta anterior.
function Invoke-RelerAdaptador {
    param([string] $Tipo)   # 'lan' | 'wifi'
    if ($Global:TarefaRedeState -or $Global:CheckMeioAtivo) {
        Write-Log 'Aguarde a checagem em andamento terminar.' -Nivel Aviso
        return
    }
    if (-not $Global:FaseLocalPayload) { Invoke-ProbeRedeLocal; return }

    if ($Global:FaseLocalSimulada) {
        $s = $Global:FaseLocalSimulada
        if ($Tipo -eq 'lan') { $Global:FaseLocalPayload.Lan = $s.Lan }
        else { $Global:FaseLocalPayload.Wireless = $s.Wireless }
        Update-PainelMeios
        return
    }

    $Global:RelerAdaptadorTipo = $Tipo
    Set-RelerAdaptadorOcupado $Tipo $true
    $rot = if ($Tipo -eq 'lan') { 'cabeada (LAN)' } else { 'Wi-Fi' }
    $script = if ($Tipo -eq 'lan') { 'Get-AdaptadorLan' } else { 'Get-AdaptadorWireless' }
    Write-Log ("Relendo so a placa {0} (o outro card fica como esta)..." -f $rot) -Nivel Info
    Start-TarefaRede -Script $script -AoConcluir { param($res, $erro) Complete-RelerAdaptador $res $erro }
}

function Complete-RelerAdaptador {
    param($Novo, $Erro)
    $tipo = [string] $Global:RelerAdaptadorTipo
    $Global:RelerAdaptadorTipo = ''
    Set-RelerAdaptadorOcupado $tipo $false

    if ($Erro) { Write-Log ("Nao consegui reler a placa: {0}" -f $Erro) -Nivel Aviso; Update-PainelMeios; return }
    if (-not $Novo -or -not $Global:FaseLocalPayload) { Write-Log 'Releitura da placa nao retornou dados.' -Nivel Aviso; Update-PainelMeios; return }

    if ($tipo -eq 'lan') {
        $Global:FaseLocalPayload.Lan = $Novo
        Write-Log ('Placa LAN relida: {0}' -f $(if ($Novo.conectado) { "conectada - IP $($Novo.ipv4)" } else { 'sem conexao' })) -Nivel Info
    } else {
        $Global:FaseLocalPayload.Wireless = $Novo
        Write-Log ('Placa Wi-Fi relida: {0}' -f $(if ($Novo.conectado) { "conectada a `"$($Novo.ssid)`"" } else { 'sem conexao' })) -Nivel Info
    }
    Update-PainelMeios
}

function Invoke-ProbeRedeLocal {
    if ($Global:FaseLocalSimulada) {
        $s = $Global:FaseLocalSimulada
        $Global:FaseLocalPayload = [pscustomobject]@{ Host = $s.Host; Lan = $s.Lan; Wireless = $s.Wireless; Internet = $null; Quando = $s.Quando }
        Update-PainelMeios
        return
    }
    Set-FaseLocalOcupado $true
    Start-TarefaRede -Script 'Invoke-FaseLocal -SemInternet' -AoConcluir { param($res, $erro) Complete-ProbeRedeLocal $res $erro }
}

function Complete-ProbeRedeLocal {
    param($Payload, $Erro)
    Set-FaseLocalOcupado $false

    $ant = $Global:FaseLocalPayload
    $antWifiOk = $ant -and $ant.PSObject.Properties['Parcial'] -and $ant.Parcial -and [bool] $ant.Wireless.conectado

    if ($Erro) {
        # Se o re-probe falhou mas ja havia uma conexao Wi-Fi confirmada
        # (estado parcial), mantem o que temos - a checagem local ainda roda.
        if ($antWifiOk) {
            Write-Log "Nao consegui reinventariar as placas ($Erro). Uso a conexao Wi-Fi ja confirmada." -Nivel Aviso
            return
        }
        Write-Log "Inventario em segundo plano falhou ($Erro). Tentando aqui mesmo..." -Nivel Aviso
        # Ultima tentativa, sincrona na thread de UI (so consultas de placa,
        # rapido): assim o passo 3 nao fica preso sem cartao.
        try {
            $Payload = Invoke-FaseLocal -SemInternet
        } catch {
            Write-Log "Checagem de rede falhou: $_" -Nivel Erro
            return
        }
        if (-not $Payload) { Write-Log 'Checagem de rede falhou: sem retorno.' -Nivel Erro; return }
    }

    # netsh pode ainda nao reportar 'conectado' logo apos o connect: se acabamos
    # de confirmar o Wi-Fi, preserva o flag/ssid no inventario novo.
    if ($antWifiOk -and $Payload -and $Payload.Wireless -and -not [bool] $Payload.Wireless.conectado) {
        $Payload.Wireless.conectado = $true
        if (-not $Payload.Wireless.ssid) { $Payload.Wireless.ssid = $ant.Wireless.ssid }
        if (-not $Payload.Wireless.sinal_pct) { $Payload.Wireless.sinal_pct = $ant.Wireless.sinal_pct }
    }

    $Global:FaseLocalPayload = $Payload
    Update-PainelMeios
}

# Rola cada coluna do teste de internet para o fim quando chega linha nova.
# ------------------------------------------------------- VELOCIMETRO (speedtest)
# Geometria: centro (140,140), raio 110, arco de -135 a +135 graus (270). Escala
# logaritmica ate 1000 Mbps (compressao estilo Ookla).
$Global:VeloMaxMbps = 1000.0
$Global:VeloTick     = 0     # throttle do velocimetro do passo 3 (speedtest)
$Global:VeloTickVpn  = 0     # throttle do velocimetro do passo 4 (iperf3)
$Global:VeloTicks    = @(0, 10, 50, 100, 250, 500, 1000)
$Global:VeloEmaSpeed = 0     # media exponencial p/ suavizar a "rajada" inicial do speedtest

function Get-PontoArco {
    param([double] $Cx, [double] $Cy, [double] $R, [double] $AngGraus)
    $rad = $AngGraus * [Math]::PI / 180.0
    [Windows.Point]::new($Cx + $R * [Math]::Sin($rad), $Cy - $R * [Math]::Cos($rad))
}

function Get-FracVelo {
    param([double] $Valor, [double] $Max = 0, [double] $Linear = 0)
    if ($Linear -gt 0) { return [Math]::Max(0.0, [Math]::Min(1.0, $Valor / $Linear)) }
    if ($Max -le 0) { $Max = $Global:VeloMaxMbps }
    $f = [Math]::Log10(1.0 + [Math]::Max(0.0, $Valor)) / [Math]::Log10(1.0 + $Max)
    [Math]::Max(0.0, [Math]::Min(1.0, $f))
}

# $Suf: '' = velocimetro do passo 3 (speedtest); 'Vpn' = passo 4 (iperf3).
function Set-TicksVelocimetro {
    param([string] $Suf = '')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    for ($i = 0; $i -lt $Global:VeloTicks.Count; $i++) {
        $tb = $w.FindName(('tickVelo{0}{1}' -f $Suf, $i))
        if (-not $tb) { continue }
        $v = [double] $Global:VeloTicks[$i]
        $ang = -135.0 + 270.0 * (Get-FracVelo -Valor $v)
        $pt = Get-PontoArco -Cx 140 -Cy 140 -R 129 -AngGraus $ang
        $tb.Text = '{0:0}' -f $v
        [Windows.Controls.Canvas]::SetLeft($tb, $pt.X - 8)
        [Windows.Controls.Canvas]::SetTop($tb, $pt.Y - 6)
    }
}

function Reset-Velocimetro {
    param([string] $Suf = '')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    if ($Suf -eq 'Vpn') { $Global:VeloTickVpn = 0 } else { $Global:VeloTick = 0; $Global:VeloEmaSpeed = 0 }
    $rot = $w.FindName('rotAgulha' + $Suf)
    $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
    $rot.Angle = -135
    $seg = $w.FindName('segVelo' + $Suf)
    $seg.BeginAnimation([Windows.Media.ArcSegment]::PointProperty, $null)
    $seg.Point = [Windows.Point]::new(62.22, 217.78)
    $seg.IsLargeArc = $false
    $w.FindName('txtVeloNum' + $Suf).Text  = '0'
    $w.FindName('txtVeloUnid' + $Suf).Text = 'Mbps'
    $w.FindName('txtVeloFase' + $Suf).Text = ''
    $w.FindName('prgSpeed' + $Suf).Value   = 0
    if ($Suf -eq 'Vpn') {
        $w.FindName('painelIperfResultado').Visibility = 'Collapsed'
        $w.FindName('txtIperfErro').Visibility = 'Collapsed'
        $w.FindName('txtIperfInfo').Text = ''
    } else {
        $w.FindName('painelSpeedResultado').Visibility = 'Collapsed'
        $w.FindName('txtSpeedErro').Visibility = 'Collapsed'
        foreach ($n in 'runConnProvedor', 'runConnServidor', 'runConnIp') {
            $r = $w.FindName($n); if ($r) { $r.Text = '' }
        }
    }
    Set-TicksVelocimetro -Suf $Suf
}

function Set-VelocimetroValor {
    param([double] $Valor, [string] $Unidade = 'Mbps', [string] $Fase = '', [double] $Linear = 0, [string] $Suf = '')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $frac = Get-FracVelo -Valor $Valor -Linear $Linear
    $ang  = -135.0 + 270.0 * $frac

    # Ponteiro E arco desenhados DIRETO (sem animacao), juntos. Antes o arco
    # usava PointAnimation: ela interpola o extremo em linha reta (sai do
    # circulo) e o IsLargeArc nao acompanha o meio da animacao -> com um evento
    # do speedtest a cada ~100 ms cada frame reiniciava a animacao e o arco
    # ficava "preso" atras do ponteiro. Os eventos ja sao frequentes: encaixar
    # o valor a cada evento da um movimento fluido, no ritmo do Ookla.
    $rot = $w.FindName('rotAgulha' + $Suf)
    if ($rot) {
        $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
        $rot.Angle = $ang
    }
    $seg = $w.FindName('segVelo' + $Suf)
    if ($seg) {
        $seg.BeginAnimation([Windows.Media.ArcSegment]::PointProperty, $null)
        $seg.Point      = Get-PontoArco -Cx 140 -Cy 140 -R 110 -AngGraus $ang
        $seg.IsLargeArc = ((270.0 * $frac) -gt 180.0)
    }
    $fmt = if ($Valor -ge 100) { '{0:0}' } elseif ($Valor -ge 10) { '{0:0.0}' } else { '{0:0.00}' }
    $w.FindName('txtVeloNum' + $Suf).Text  = ($fmt -f $Valor)
    $w.FindName('txtVeloUnid' + $Suf).Text = $Unidade
    if ($Fase) { $w.FindName('txtVeloFase' + $Suf).Text = $Fase }
}

# Velocimetro do speedtest (passo 3) durante download/upload, com anti-"rajada":
# - ignora os primeiros ~6% de cada fase (as 1as amostras do Ookla sao infladas
#   - a media acumulada num intervalo minusculo);
# - depois, media exponencial (EMA) a partir de 0 -> a agulha sobe suave em vez
#   de saltar pro fim e voltar. O valor final (evento 'result') encaixa exato.
function Set-VelocimetroSuave {
    param([double] $Amostra, [double] $Progresso, [string] $Fase)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    if ($Progresso -lt 0.06) {
        $Global:VeloEmaSpeed = 0
        Set-VelocimetroValor -Valor 0 -Unidade 'Mbps' -Fase ($Fase + ' - aquecendo...')
        return
    }
    $Global:VeloEmaSpeed = $Global:VeloEmaSpeed + 0.35 * ($Amostra - $Global:VeloEmaSpeed)
    Set-VelocimetroValor -Valor $Global:VeloEmaSpeed -Unidade 'Mbps' -Fase $Fase
}

function Set-ProgressoSpeed {
    param([double] $Frac, [string] $Suf = '')
    $w = $Global:JanelaPrincipal
    if ($w) { $w.FindName('prgSpeed' + $Suf).Value = [Math]::Max(0.0, [Math]::Min(1.0, $Frac)) }
}

# Recebe um evento JSONL do speedtest.exe (via Write-EventoSpeedtest, na thread de UI).
function Update-Speedtest {
    param($Evento)
    $w = $Global:JanelaPrincipal
    if (-not $w -or -not $Evento) { return }
    $tipo = [string] $Evento.type
    # ponteiro/arco: no maximo ~12x/s durante o dilúvio de eventos de progresso
    $desenha = $true
    if ($tipo -in @('ping', 'download', 'upload')) {
        $agora = [Environment]::TickCount
        if (($agora - [int] $Global:VeloTick) -lt 80) { $desenha = $false }
        else { $Global:VeloTick = $agora }
    }
    switch ($tipo) {
        'testStart' {
            $srv = $Evento.server
            $ext = if ($Evento.PSObject.Properties['interface'] -and $Evento.interface) { [string] $Evento.interface.externalIp } else { '' }
            $loc = [string] $srv.location
            Set-SpeedConn -Provedor ([string] $Evento.isp) `
                          -Servidor ([string] $srv.name + $(if ($loc) { " ($loc)" } else { '' })) `
                          -Ip (Get-IpExibicao $ext)
            $w.FindName('txtVeloFase').Text = 'conectando...'
        }
        'ping' {
            Set-ProgressoSpeed (0.10 * [double] $Evento.ping.progress)
            if ($desenha) { Set-VelocimetroValor -Valor ([double] $Evento.ping.latency) -Unidade 'ms' -Fase 'Ping' -Linear 60 }
        }
        'download' {
            $prog = [double] $Evento.download.progress
            Set-ProgressoSpeed (0.10 + 0.50 * $prog)
            if ($desenha) { Set-VelocimetroSuave (ConvertTo-MbpsGui $Evento.download.bandwidth) $prog 'Download' }
        }
        'upload' {
            $prog = [double] $Evento.upload.progress
            Set-ProgressoSpeed (0.60 + 0.40 * $prog)
            if ($desenha) { Set-VelocimetroSuave (ConvertTo-MbpsGui $Evento.upload.bandwidth) $prog 'Upload' }
        }
        'result' {
            Set-ProgressoSpeed 1.0
            $it = [pscustomobject]@{
                speedtest_ok  = $true
                isp           = [string] $Evento.isp
                ip_externo    = if ($Evento.PSObject.Properties['interface'] -and $Evento.interface) { [string] $Evento.interface.externalIp } else { '' }
                servidor_nome = [string] $Evento.server.name
                servidor_local = [string] $Evento.server.location
                ping_ms       = [math]::Round([double] $Evento.ping.latency, 1)
                jitter_ms     = [math]::Round([double] $Evento.ping.jitter, 1)
                perda_pct     = if ($Evento.PSObject.Properties['packetLoss'] -and $null -ne $Evento.packetLoss) { [math]::Round([double] $Evento.packetLoss, 1) } else { $null }
                download_mbps = (ConvertTo-MbpsGui $Evento.download.bandwidth)
                upload_mbps   = (ConvertTo-MbpsGui $Evento.upload.bandwidth)
                resultado_url = if ($Evento.PSObject.Properties['result'] -and $Evento.result) { [string] $Evento.result.url } else { '' }
            }
            Update-SpeedtestPainel -It $it
        }
        'error' {
            $te = $w.FindName('txtSpeedErro')
            $te.Text = [string] $Evento.message
            $te.Visibility = 'Visible'
        }
    }
}

function ConvertTo-MbpsGui {
    param($BandwidthBytesSeg)
    if ($null -eq $BandwidthBytesSeg) { return 0 }
    [math]::Round(([double] $BandwidthBytesSeg) * 8 / 1e6, 2)
}

# IP a exibir no card do speedtest: prioriza IPv4. O Ookla pode devolver o IPv6
# como "IP externo"; nesse caso mostra o IPv4 local da placa usada.
function Get-IpExibicao {
    param([string] $IpExterno)
    if ($IpExterno -match '^\d{1,3}(\.\d{1,3}){3}$') { return $IpExterno }   # IPv4 publico: usa
    $p = $Global:FaseLocalPayload
    $loc = ''
    if ($p) {
        $t = [string] $Global:FaseLocalTipo
        $loc = if ($t -eq 'lan') { [string] $p.Lan.ipv4 }
               elseif ($t -eq 'wifi') { [string] $p.Wireless.ipv4 }
               elseif ([string] $p.Lan.ipv4) { [string] $p.Lan.ipv4 }
               else { [string] $p.Wireless.ipv4 }
    }
    if ($loc) { return "$loc (local)" }
    if ($IpExterno) { return $IpExterno }
    return ''
}

# Bloco vertical "Provedor / Servidor / IP" no topo do card do speedtest.
function Set-SpeedConn {
    param([string] $Provedor, [string] $Servidor, [string] $Ip)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $par = @{ runConnProvedor = $Provedor; runConnServidor = $Servidor; runConnIp = $Ip }
    foreach ($n in $par.Keys) {
        $r = $w.FindName($n)
        if ($r) { $r.Text = [string] $par[$n] }
    }
}

# Preenche o painel de resultado do speedtest a partir do payload achatado.
function Update-SpeedtestPainel {
    param($It)
    $w = $Global:JanelaPrincipal
    if (-not $w -or -not $It) { return }
    $g = { param($n) if ($It.PSObject.Properties[$n]) { $It.($n) } }
    $fmt = { param($v) if ($null -eq $v -or "$v" -eq '') { '--' } elseif ([double] $v -ge 100) { '{0:0}' -f $v } else { '{0:0.0}' -f $v } }

    $dl = & $g 'download_mbps'; $ul = & $g 'upload_mbps'
    $w.FindName('runResDown').Text   = & $fmt $dl
    $w.FindName('runResUp').Text     = & $fmt $ul
    $w.FindName('runResPing').Text   = & $fmt (& $g 'ping_ms')
    $w.FindName('runResJitter').Text = & $fmt (& $g 'jitter_ms')
    $perda = & $g 'perda_pct'
    $w.FindName('runResPerda').Text  = if ($null -eq $perda) { '--' } else { '{0:0.0}' -f $perda }

    $srv = [string] (& $g 'servidor_nome')
    $loc = [string] (& $g 'servidor_local')
    Set-SpeedConn -Provedor ([string] (& $g 'isp')) `
                  -Servidor ($srv + $(if ($loc) { " ($loc)" } else { '' })) `
                  -Ip (Get-IpExibicao ([string] (& $g 'ip_externo')))

    $w.FindName('txtSpeedErro').Visibility = 'Collapsed'
    $w.FindName('painelSpeedResultado').Visibility = 'Visible'
    # velocimetro final mostra o download
    if ($null -ne $dl) { Set-VelocimetroValor -Valor ([double] $dl) -Unidade 'Mbps' -Fase 'concluido' }
}

# ------------------------------------------------ PASSO 4: VELOCIMETRO iperf3
# Recebe um evento do iperf3 (via Write-EventoIperf, na thread de UI). $Evento
# e um hashtable: fase = download|upload|fim, estado, mbps, t, dur, ...
function Update-IperfGauge {
    param($Evento)
    $w = $Global:JanelaPrincipal
    if (-not $w -or -not $Evento) { return }
    $fase = [string] $Evento.fase

    if ($fase -eq 'fim') {
        Set-ProgressoSpeed -Suf 'Vpn' 1.0
        Update-IperfPainel -Iperf $Evento
        return
    }

    if ($Evento.estado -eq 'inicio') {
        if ($Evento.servidor) { $w.FindName('txtIperfInfo').Text = 'Servidor iperf3: ' + [string] $Evento.servidor }
        if ($Evento.dur) { $Global:IperfDur = [double] $Evento.dur }
        $w.FindName('txtVeloFaseVpn').Text = if ($fase -eq 'upload') { 'Upload...' } else { 'Download...' }
        return
    }

    # andamento
    $base = if ($fase -eq 'upload') { 0.5 } else { 0.0 }
    $dur  = if ($Global:IperfDur -gt 0) { [double] $Global:IperfDur } else { 10.0 }
    Set-ProgressoSpeed -Suf 'Vpn' ($base + 0.5 * ([Math]::Min(1.0, [double] $Evento.t / $dur)))

    $agora = [Environment]::TickCount
    if (($agora - [int] $Global:VeloTickVpn) -ge 80) {
        $Global:VeloTickVpn = $agora
        $rot = if ($fase -eq 'upload') { 'Upload (VPN)' } else { 'Download (VPN)' }
        Set-VelocimetroValor -Suf 'Vpn' -Valor ([double] $Evento.mbps) -Unidade 'Mbps' -Fase $rot
    }
}

# Preenche o painel de resultado da Fase 2. -Iperf: hashtable do evento 'fim'
# OU o $Global:DiagPayload.Iperf; ping/jitter/perda vem de $Global:DiagPayload.Metricas.
function Update-IperfPainel {
    param($Iperf)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $g   = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.($n) } elseif ($o -is [hashtable] -and $o.ContainsKey($n)) { $o[$n] } }
    $fmt = { param($v) if ($null -eq $v -or "$v" -eq '') { '--' } elseif ([double] $v -ge 100) { '{0:0}' -f $v } else { '{0:0.0}' -f $v } }

    $dl = & $g $Iperf 'download';  if ($null -eq $dl) { $dl = & $g $Iperf 'DownloadMbps' }
    $ul = & $g $Iperf 'upload';    if ($null -eq $ul) { $ul = & $g $Iperf 'UploadMbps' }
    $rd = & $g $Iperf 'retrans_down'
    $ru = & $g $Iperf 'retrans_up'
    $erro = [string] (& $g $Iperf 'erro'); if (-not $erro) { $erro = [string] (& $g $Iperf 'iperf_erro') }
    $srv  = [string] (& $g $Iperf 'servidor')

    $w.FindName('runIperfDown').Text = & $fmt $dl
    $w.FindName('runIperfUp').Text   = & $fmt $ul
    $rt = @()
    if ($null -ne $rd) { $rt += "{0} down" -f $rd }
    if ($null -ne $ru) { $rt += "{0} up" -f $ru }
    $w.FindName('runIperfRetrans').Text = if ($rt.Count) { $rt -join ' / ' } else { '--' }
    if ($srv) { $w.FindName('txtIperfServidor').Text = 'Servidor iperf3: ' + $srv }

    # latencia / jitter / perda vem do ping (Test-Latencia), no payload final
    $m = if ($Global:DiagPayload) { $Global:DiagPayload.Metricas } else { $null }
    if ($m) {
        $w.FindName('runIperfPing').Text   = & $fmt $m.LatenciaMediaMs
        $w.FindName('runIperfJitter').Text = & $fmt $m.JitterMs
        $w.FindName('runIperfPerda').Text  = if ($null -eq $m.PerdaPercentual) { '--' } else { '{0:0.0}' -f $m.PerdaPercentual }
    }

    $te = $w.FindName('txtIperfErro')
    if ($erro -and $null -eq $dl -and $null -eq $ul) {
        $te.Text = $erro ; $te.Visibility = 'Visible'
        $w.FindName('painelIperfResultado').Visibility = 'Collapsed'
    } else {
        $te.Visibility = 'Collapsed'
        $w.FindName('painelIperfResultado').Visibility = 'Visible'
        if ($null -ne $dl) { Set-VelocimetroValor -Suf 'Vpn' -Valor ([double] $dl) -Unidade 'Mbps' -Fase 'concluido' }
    }
}

# =============================================================== OVERLAY: CHECAGEM DE UM MEIO
# Cada card do passo 3 tem seu botao "Rodar checagem" -> Invoke-CheckMeio, que
# abre o overlay modal. O tecnico avanca a mao: "Iniciar" roda a Fase 1;
# "Testar a VPN" roda a Fase 2; ao fim, "Concluir" fecha. Fase 3 (Selenium)
# fica "em implementacao". Uma checagem por vez ($Global:CheckMeioAtivo);
# estado da maquina em $Global:ChkFase ('f1-pronto'|'f1-rodando'|'f2-pronto'|
# 'f2-rodando'|'fim').

# Botao "Iniciar"/"Testar a VPN" do overlay: texto + visibilidade por $Global:ChkFase.
function Set-ChkBotao {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $b = $w.FindName('btnChkIniciar')
    if (-not $b) { return }
    switch ($Global:ChkFase) {
        'f1-pronto'  { $b.Content = 'Iniciar checagem da rede local';   $b.Visibility = 'Visible'; $b.IsEnabled = $true }
        'f2-pronto'  { $b.Content = 'Testar a VPN (Fase 2)';            $b.Visibility = 'Visible'; $b.IsEnabled = $true }
        'f2-vpn-ok'  { $b.Content = 'Iniciar diagnostico com a VPN';    $b.Visibility = 'Visible'; $b.IsEnabled = $true }
        default      { $b.Visibility = 'Collapsed' }
    }
    $r = $w.FindName('ringChk')
    if ($r) {
        $rod = $Global:ChkFase -in @('f1-rodando', 'f2-rodando')
        $r.IsActive = $rod ; $r.Visibility = if ($rod) { 'Visible' } else { 'Collapsed' }
    }
}

# Alterna as 3 colunas do corpo entre Fase 1 (Ookla) e Fase 2 (iperf3).
function Set-ChkFaseView {
    param([string] $Fase)   # 'nenhuma' | 'f1' | 'f2'
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $f1 = ($Fase -ne 'f2')
    foreach ($n in 'grpF1Conn', 'canvasVelo', 'prgSpeed') {
        $c = $w.FindName($n); if ($c) { $c.Visibility = if ($f1) { 'Visible' } else { 'Collapsed' } }
    }
    foreach ($n in 'grpF2Conn', 'canvasVeloVpn', 'prgSpeedVpn') {
        $c = $w.FindName($n); if ($c) { $c.Visibility = if ($f1) { 'Collapsed' } else { 'Visible' } }
    }
}

# dot + texto de um passo do stepper do overlay.
function Set-ChkStep {
    param([int] $N, [string] $Estado, [string] $Texto = '')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $dot = $w.FindName("dotChkS$N"); $lbl = $w.FindName("txtChkS$N")
    if (-not $dot) { return }
    $cor = switch ($Estado) {
        'rodando' { '#E8B93E' } 'ok' { '#4FC177' }
        'erro'    { '#E8695C' } 'semvpn' { '#E8695C' }
        default   { '#7D8698' }
    }
    $palavra = switch ($Estado) {
        'rodando' { 'rodando...' } 'ok' { 'ok' } 'erro' { 'erro' }
        'semvpn'  { 'sem VPN' }    default { 'pendente' }
    }
    $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($cor)); $b.Freeze()
    $dot.Fill = $b
    $base = @('1. Rede local (sem VPN)', '2. Diagnostico com a VPN', '3. Sistema de totalizacao (Selenium)')[$N - 1]
    $lbl.Text = if ($Texto) { "$base - $Texto" } else { "$base - $palavra" }
}

function Reset-OverlayCheck {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    Set-ChkStep 1 'pendente'
    Set-ChkStep 2 'pendente'
    Set-ChkStep 3 'pendente' 'em implementacao'
    $w.FindName('panelChkVpnGate').Visibility = 'Collapsed'
    $w.FindName('chkVpnImpossivel').IsChecked = $false
    $w.FindName('txtVpnMotivo').Text = ''
    $w.FindName('txtVpnMotivo').Visibility = 'Collapsed'
    $w.FindName('txtVpnMotivoDica').Visibility = 'Collapsed'
    $w.FindName('btnChkVpnImpossivel').Visibility = 'Collapsed'
    $w.FindName('btnChkFechar').Content = 'Cancelar'
    foreach ($n in 'painelSpeedResultado', 'painelIperfResultado', 'txtSpeedErro', 'txtIperfErro', 'ringDiag') {
        $c = $w.FindName($n); if ($c) { $c.Visibility = 'Collapsed' }
    }
    $rv = $w.FindName('txtChkResultadoVazio'); if ($rv) { $rv.Visibility = 'Visible' }
    foreach ($n in 'txtIperfInfo', 'txtIperfServidor') { $c = $w.FindName($n); if ($c) { $c.Text = '' } }
    Reset-Velocimetro
    Reset-Velocimetro -Suf 'Vpn'
    Set-ChkFaseView 'f1'
    $Global:ChkFase = 'f1-pronto'
    Set-ChkBotao
}

# Passo 3: clicar num card seleciona aquele meio para a checagem (borda azul +
# libera o "Rodar checagem"). So um card fica selecionado por vez.
function Select-MeioParaChecar {
    param([string] $Meio)   # 'lan' | 'wifi' | 'celular'
    if ($Global:CheckMeioAtivo) { return }
    if (-not $Global:FaseLocalPayload) { return }
    $naKey = if ($Meio -eq 'wifi') { 'wifi_local' } else { $Meio }
    if ($Global:MeiosNaoAplicaveis.ContainsKey($naKey) -or $Global:NaMeioPendente -eq $naKey) { return }
    if ($Global:MeioSelecionado -eq $Meio) { return }
    $Global:MeioSelecionado = $Meio
    Update-PainelMeios
}

# Card do meio: "Rodar checagem" -> abre o overlay (nao inicia sozinho).
function Invoke-CheckMeio {
    param([string] $Meio)   # 'lan' | 'wifi' | 'celular'
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    if ($Global:CheckMeioAtivo -or $Global:TarefaRedeState -or $Global:DiagRunState) {
        Write-Log 'Ja ha uma checagem em andamento. Conclua-a antes de comecar outra.' -Nivel Aviso
        return
    }
    if ($Global:MeioSelecionado -ne $Meio) {
        Write-Log 'Clique no card deste meio para seleciona-lo antes de rodar a checagem.' -Nivel Aviso
        return
    }
    $p = $Global:FaseLocalPayload
    $conectado = if ($Meio -eq 'lan') { [bool] ($p -and $p.Lan.conectado) } else { [bool] ($p -and $p.Wireless.conectado) }
    if (-not $conectado) {
        Write-Log 'Conecte este meio e use o botao de reler placas antes de rodar a checagem.' -Nivel Aviso
        return
    }
    if ($Meio -eq 'celular' -and -not ([string] $w.FindName('cboOperadoraCel').Text).Trim()) {
        Write-Log 'Informe a operadora do celular antes de rodar a checagem.' -Nivel Aviso
        return
    }

    $Global:FaseLocalTipo  = $Meio
    $Global:CheckMeioAtivo = $true
    $Global:DiagPayload    = $null
    if ($Global:LogEntries) { $Global:LogEntries.Clear() }

    $mo  = Get-MeioDoPasso3
    $rot = Get-RotuloMeio $mo.meio $mo.operadora
    $w.FindName('txtChkMeioTitulo').Text = ([string] $rot).ToUpper()
    Reset-OverlayCheck
    $w.FindName('overlayCheck').Visibility = 'Visible'
    Update-PainelMeios

    Write-Log ("Checagem do meio: {0} - clique em Iniciar." -f $rot) -Nivel Destaque
}

# Botao "Iniciar" / "Testar a VPN" do overlay.
function Invoke-ChkAvancar {
    switch ($Global:ChkFase) {
        'f1-pronto' { Start-CheckFase1 }
        'f2-pronto' { Start-CheckFase2 }      # so verifica a VPN (nao roda o teste)
        'f2-vpn-ok' { Start-DiagnosticoVpn }  # VPN confirmada -> agora roda a Fase 2
        default     { }
    }
}

function Start-CheckFase1 {
    $w = $Global:JanelaPrincipal
    $Global:ChkFase = 'f1-rodando'
    Set-ChkBotao
    Set-ChkStep 1 'rodando'
    Set-ChkFaseView 'f1'
    $w.FindName('painelSpeedResultado').Visibility = 'Collapsed'
    $w.FindName('txtChkResultadoVazio').Visibility = 'Visible'
    Reset-Velocimetro
    $w.FindName('txtVeloFase').Text = 'iniciando...'
    Write-Log 'Fase 1: teste de velocidade (Ookla), sem a VPN...' -Nivel Info
    if ($Global:FaseLocalSimulada) { Complete-CheckFase1 $Global:FaseLocalSimulada $null; return }
    Set-FaseLocalOcupado $true
    Start-TarefaRede -Script 'Invoke-FaseLocal' -AoConcluir { param($res, $erro) Complete-CheckFase1 $res $erro }
}

function Complete-CheckFase1 {
    param($Payload, $Erro)
    Set-FaseLocalOcupado $false
    $w = $Global:JanelaPrincipal
    if ($Erro) {
        Write-Log "Fase 1 falhou: $Erro" -Nivel Erro
        Set-ChkStep 1 'erro'
    } else {
        if ($Payload -and $Global:FaseLocalTipo) {
            $Payload | Add-Member -NotePropertyName TipoUsado -NotePropertyValue ([string] $Global:FaseLocalTipo) -Force
        }
        $Global:FaseLocalPayload = $Payload
        $it = if ($Payload) { $Payload.Internet } else { $null }
        if ($it -and $it.speedtest_ok) {
            Update-SpeedtestPainel -It $it
            $w.FindName('txtChkResultadoVazio').Visibility = 'Collapsed'
            Write-Log 'Fase 1 concluida.' -Nivel Ok
            Set-ChkStep 1 'ok'
        } else {
            $te = $w.FindName('txtSpeedErro')
            $diag = if ($it -and $it.PSObject.Properties['speedtest_diagnostico']) { [string] $it.speedtest_diagnostico } else { '' }
            $te.Text = if ($diag) { $diag }
                       elseif ($it -and $it.speedtest_erro) { [string] $it.speedtest_erro }
                       else { 'sem resultado de velocidade' }
            $te.Visibility = 'Visible'
            Write-Log ("Fase 1 sem velocidade: {0}" -f $te.Text) -Nivel Aviso
            Set-ChkStep 1 'erro'
        }
    }
    $Global:ChkFase = 'f2-pronto'
    Set-ChkBotao
    Write-Log 'Clique em "Testar a VPN (Fase 2)" quando estiver com a VPN do TRE conectada.' -Nivel Info
}

# Botao "Testar a VPN (Fase 2)": SO verifica a VPN e mostra o estado. Nao dispara
# o diagnostico - o tecnico confere o IP da VPN e clica em "Iniciar diagnostico".
function Start-CheckFase2 {
    $w = $Global:JanelaPrincipal
    Set-ChkStep 2 'rodando' 'verificando a VPN'
    Set-ChkFaseView 'f2'
    # limpa a 3a coluna: some o resultado da Fase 1 e o do iperf de uma rodada anterior
    foreach ($n in 'painelSpeedResultado', 'painelIperfResultado') {
        $c = $w.FindName($n); if ($c) { $c.Visibility = 'Collapsed' }
    }
    $w.FindName('txtChkResultadoVazio').Visibility = 'Visible'
    Update-EstadoVpn
    if (Test-VpnAtiva) {
        $Global:ChkFase = 'f2-vpn-ok'
        $w.FindName('panelChkVpnGate').Visibility = 'Visible'
        Set-ChkStep 2 'rodando' 'VPN conectada - clique em Iniciar'
        Set-ChkBotao
        Write-Log 'VPN da JE conectada. Confira o IP e clique em "Iniciar diagnostico com a VPN".' -Nivel Ok
    } else {
        $Global:ChkFase = 'f2-pronto'
        Set-ChkBotao
        Write-Log 'Fase 2 aguardando a VPN da JE. Abra o FortiClient e conecte, depois "Verificar novamente".' -Nivel Aviso
        $w.FindName('panelChkVpnGate').Visibility = 'Visible'
        $w.FindName('btnChkVpnImpossivel').Visibility = 'Visible'
        Set-ChkStep 2 'rodando' 'aguardando a VPN'
    }
}

# Botao "Iniciar diagnostico com a VPN": agora sim roda a bateria da Fase 2.
function Start-DiagnosticoVpn {
    $w = $Global:JanelaPrincipal
    if (-not (Test-VpnAtiva)) {
        Write-Log 'A VPN caiu. Reconecte pelo FortiClient e clique em "Verificar novamente".' -Nivel Aviso
        Start-CheckFase2
        return
    }
    $Global:ChkFase = 'f2-rodando'
    Set-ChkBotao
    $w.FindName('panelChkVpnGate').Visibility = 'Collapsed'
    Reset-Velocimetro -Suf 'Vpn'
    $w.FindName('txtVeloFaseVpn').Text = 'iniciando...'
    $rd = $w.FindName('ringDiag'); if ($rd) { $rd.IsActive = $true; $rd.Visibility = 'Visible' }
    Write-Log 'Fase 2: diagnostico com a VPN (ping + iperf3)...' -Nivel Info
    Set-ChkStep 2 'rodando'
    Set-ProgressoDiag $true
    $sel  = $w.FindName('cboLocal').SelectedItem
    $selD = if ($sel) { $sel.Dados } else { $null }
    Start-DiagnosticoAssincrono -Local $selD -AoConcluir { param($res, $erro) Complete-CheckFase2 $res $erro }
}

function Complete-CheckFase2 {
    param($Payload, $Erro)
    Set-ProgressoDiag $false
    $w = $Global:JanelaPrincipal
    $rd = $w.FindName('ringDiag'); if ($rd) { $rd.IsActive = $false; $rd.Visibility = 'Collapsed' }
    if ($Erro) {
        Write-Log "Fase 2 falhou: $Erro" -Nivel Erro
        Set-ChkStep 2 'erro'
    } else {
        Show-PainelResultado -Payload $Payload
        if ($Payload -and $Payload.PSObject.Properties['Iperf'] -and $Payload.Iperf) { Update-IperfPainel -Iperf $Payload.Iperf }
        $w.FindName('txtChkResultadoVazio').Visibility = 'Collapsed'
        Write-Log 'Fase 2 concluida.' -Nivel Ok
        $ver = if ($Payload -and $Payload.Decisao) { [string] $Payload.Decisao.Classificacao } else { 'inviavel' }
        Set-ChkStep 2 $(if ($ver -eq 'inviavel') { 'erro' } else { 'ok' })
    }
    Complete-CheckMeio
}

# Botao "Registrar este meio sem a VPN" (no gate da Fase 2).
function Invoke-CheckVpnImpossivel {
    $w = $Global:JanelaPrincipal
    $motivo = ([string] $w.FindName('txtVpnMotivo').Text).Trim()
    if (-not [bool] $w.FindName('chkVpnImpossivel').IsChecked -or -not $motivo) {
        Write-Log 'Marque "nao foi possivel conectar a VPN" e descreva o motivo.' -Nivel Aviso
        return
    }
    Set-DiagnosticoVpnImpossivel -Motivo $motivo
    Write-Log 'Meio registrado sem a VPN (inviavel).' -Nivel Aviso
    Set-ChkStep 2 'semvpn'
    $w.FindName('panelChkVpnGate').Visibility = 'Collapsed'
    Complete-CheckMeio
}

function Complete-CheckMeio {
    $w = $Global:JanelaPrincipal
    $Global:ChkFase = 'fim'
    Set-ChkBotao
    Add-MedicaoAtual
    Write-Log 'Checagem do meio concluida. Clique em "Concluir" para fechar.' -Nivel Ok
    $b = $w.FindName('btnChkFechar'); if ($b) { $b.Content = 'Concluir' }
}

# Botao "Cancelar"/"Concluir" do overlay.
function Close-OverlayCheck {
    if ($Global:TarefaRedeState -or $Global:DiagRunState) {
        Write-Log 'Aguarde a etapa em andamento terminar antes de fechar.' -Nivel Aviso
        return
    }
    $Global:CheckMeioAtivo = $false
    $Global:ChkFase = ''
    $w = $Global:JanelaPrincipal
    if ($w) { $w.FindName('overlayCheck').Visibility = 'Collapsed' }
    Update-PainelMeios
}

# ------------------------------------------------------- MULTI-MEIO (medicoes)

# Meio + operadora escolhidos no passo 3 (radio dos 3 cartoes).
function Get-MeioDoPasso3 {
    $w = $Global:JanelaPrincipal
    switch ($Global:FaseLocalTipo) {
        'lan'     { @{ meio = 'lan';        operadora = '' } }
        'wifi'    { @{ meio = 'wifi_local'; operadora = '' } }
        'celular' { @{ meio = 'celular';    operadora = ([string] $w.FindName('cboOperadoraCel').Text).Trim() } }
        default   { @{ meio = ''; operadora = '' } }
    }
}

# Monta a medicao da rodada atual a partir do estado corrente (Fase 1 + Fase 2).
function New-MedicaoAtual {
    $w  = $Global:JanelaPrincipal
    $fl = $Global:FaseLocalPayload
    $dp = $Global:DiagPayload
    $mo = Get-MeioDoPasso3

    $vpnImpossivel = [bool] $w.FindName('chkVpnImpossivel').IsChecked
    $vpnConectou   = (-not $vpnImpossivel) -and ($null -ne $dp)
    $it = if ($fl) { $fl.Internet } else { $null }

    [pscustomobject]@{
        meio                = $mo.meio
        operadora           = $mo.operadora
        rotulo              = Get-RotuloMeio $mo.meio $mo.operadora
        nao_aplicavel       = $false
        motivo_na           = ''
        fase_local          = $fl
        rede_local_ok       = [bool] (& { if ($it) { $it.speedtest_ok } else { $false } })
        rede_local_download = (& { if ($it -and $it.PSObject.Properties['download_mbps']) { $it.download_mbps } else { $null } })
        vpn_conectou        = $vpnConectou
        vpn_motivo          = if ($vpnImpossivel) { ([string] $w.FindName('txtVpnMotivo').Text).Trim() } else { '' }
        vpn_download        = (& { if ($dp -and $dp.Metricas) { $dp.Metricas.BandaDownloadMbps } else { $null } })
        metricas            = if ($dp) { $dp.Metricas } else { $null }
        fase2_ok            = $vpnConectou
        decisao             = if ($dp) { $dp.Decisao } else { $null }
        iperf               = if ($dp -and $dp.PSObject.Properties['Iperf']) { $dp.Iperf } else { $null }
        ambiente            = if ($dp) { $dp.Ambiente } else { $null }
        avaliacoes          = @()
        veredito            = if ($dp -and $dp.Decisao) { [string] $dp.Decisao.Classificacao } else { 'nao_testado' }
        quando              = (Get-Date).ToString('o')
    }
}

# Guarda a medicao da rodada (substitui a de mesmo meio+operadora se refizer).
function Add-MedicaoAtual {
    $med = New-MedicaoAtual
    if (-not $med.meio) { return }
    $lista = @($Global:Medicoes | Where-Object {
        -not ($_.meio -eq $med.meio -and [string] $_.operadora -eq [string] $med.operadora -and -not $_.nao_aplicavel)
    })
    $Global:Medicoes = @($lista + $med)
    Write-Log ("Medicao registrada: {0} -> {1}" -f $med.rotulo, $med.veredito) -Nivel Info
}

# Persiste os ajustes do grid do passo 5 (classe final + justificativa por
# metrica) na medicao aberta e recalcula o veredito dela (pior caso).
function Save-AjustesPasso5 {
    if (-not $Global:AvaliacaoRows) { return }
    $idx = Get-IndiceMedicaoAberta
    if ($idx -lt 0) { return }
    $med = @($Global:Medicoes)[$idx]
    if (-not $med) { return }
    $aj = @()
    foreach ($r in @($Global:AvaliacaoRows)) {
        $aj += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
    }
    $med.avaliacoes = @($aj)
    if ($Global:DecisaoRecalculada) { $med.veredito = [string] $Global:DecisaoRecalculada }
}

# Recomendacao de conexao para o local (a partir das medicoes registradas).
# Guarda em $Global:RecomendacaoLocal para o JSON/PDF/passo 6.
function Get-RecomendacaoLocal {
    $Global:RecomendacaoLocal = Get-ConexaoRecomendada @($Global:Medicoes)
    return $Global:RecomendacaoLocal
}

# Texto "12,3 Mbps" (ou "-" se nao houver numero).
function Get-TextoMbps {
    param($Valor)
    if ($null -eq $Valor -or "$Valor" -eq '') { return '-' }
    try { return ('{0:N1} Mbps' -f [double] $Valor) } catch { return "$Valor" }
}

# Itens do combo "Conexao recomendada" (passo 6): os meios que passaram nas
# duas checagens (Rede Local + VPN + Fase 2); no fallback, os que ao menos
# rodaram a Rede Local. Sempre com a opcao "Nenhuma" ao final.
function Get-OpcoesRecomendacao {
    $meds = @($Global:Medicoes | Where-Object { $_ -and -not $_.nao_aplicavel -and $_.veredito -ne 'nao_testado' })
    $cand = @($meds | Where-Object { $_.rede_local_ok -and $_.vpn_conectou -and $_.fase2_ok })
    if (-not $cand.Count) { $cand = @($meds | Where-Object { $_.rede_local_ok }) }
    $rotulos = @($cand | ForEach-Object { [string] $_.rotulo } | Select-Object -Unique)
    return @($rotulos + (Get-RotuloMeio 'nenhuma' ''))
}

# Reconstroi o objeto de recomendacao a partir do rotulo escolhido no combo.
function Resolve-RecomendacaoSelecionada {
    param([string] $Rotulo)
    $nenhuma = Get-RotuloMeio 'nenhuma' ''
    if (-not $Rotulo -or $Rotulo -eq $nenhuma) {
        return [pscustomobject]@{
            meio = 'nenhuma'; operadora = ''; rotulo = $nenhuma
            veredito = 'inviavel'; provisoria = $false; base = 'nenhuma'
        }
    }
    $med = @($Global:Medicoes | Where-Object { $_ -and -not $_.nao_aplicavel -and [string] $_.rotulo -eq $Rotulo }) |
        Select-Object -First 1
    if (-not $med) {
        if ($Global:RecomendacaoLocal) { return $Global:RecomendacaoLocal }
        return [pscustomobject]@{ meio = 'nenhuma'; operadora = ''; rotulo = $nenhuma
            veredito = 'inviavel'; provisoria = $false; base = 'nenhuma' }
    }
    $fechouVpn = [bool] $med.vpn_conectou -and [bool] $med.fase2_ok
    [pscustomobject]@{
        meio       = [string] $med.meio
        operadora  = [string] $med.operadora
        rotulo     = [string] $med.rotulo
        veredito   = if ($fechouVpn) { [string] $med.veredito } else { 'inviavel' }
        provisoria = (-not $fechouVpn)
        base       = if ($fechouVpn) { 'vpn' } else { 'rede_local' }
    }
}

# Preenche o passo 6: combo da conexao recomendada (pre-selecao automatica),
# frase de contexto, motivo e a tabela de medicoes.
function Update-Passo6Recomendacao {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    Get-RecomendacaoLocal | Out-Null
    $rec  = $Global:RecomendacaoLocal
    $opts = Get-OpcoesRecomendacao

    $cbo = $w.FindName('cboConexaoRec')
    $Global:AtualizandoRecomendacao = $true
    $cbo.ItemsSource = $opts
    $alvo = if ($rec) { [string] $rec.rotulo } else { '' }
    if ($opts -contains $alvo) { $cbo.SelectedItem = $alvo }
    elseif ($opts.Count)       { $cbo.SelectedItem = $opts[0] }
    $Global:AtualizandoRecomendacao = $false

    $w.FindName('txtMotivoRec').Text = [string] $Global:MotivoRecomendacao

    Update-ContextoRecomendacao
    Update-TabelaMedicoes
}

# Frase abaixo do combo: de onde veio a sugestao e qual o veredito resultante.
function Update-ContextoRecomendacao {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $sel = [string] $w.FindName('cboConexaoRec').SelectedItem
    $obj = Resolve-RecomendacaoSelecionada -Rotulo $sel
    $lbl = $w.FindName('lblRecContexto')
    if (-not $lbl) { return }
    $base = switch ($obj.base) {
        'vpn'        { 'passou na checagem de Rede Local e na VPN' }
        'rede_local' { 'PROVISORIA - nenhum meio fechou a VPN; baseada so no teste de Rede Local (local fica INVIAVEL)' }
        default      { 'nenhum meio de conexao pode ser usado neste local' }
    }
    $lbl.Text = 'Veredito do local por esta conexao: {0}. ({1})' -f (Get-RotuloVeredito $obj.veredito), $base
}

# Tabela read-only das medicoes feitas no local (passo 6).
function Update-TabelaMedicoes {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $linhas = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($m in @($Global:Medicoes)) {
        if (-not $m) { continue }
        $rl = if ($m.nao_aplicavel) { 'n/a' }
              elseif ($m.rede_local_ok) { Get-TextoMbps $m.rede_local_download }
              else { 'nao rodou' }
        $vpn = if ($m.nao_aplicavel) { '-' }
               elseif ($m.vpn_conectou) { 'conectou' }
               else { 'nao' }
        $vpndl = if ($m.nao_aplicavel -or -not $m.vpn_conectou) { '-' } else { Get-TextoMbps $m.vpn_download }
        $ver = if ($m.nao_aplicavel) { 'nao aplicavel - ' + [string] $m.motivo_na } else { Get-RotuloVeredito $m.veredito }
        $linhas.Add([pscustomobject]@{
            Meio = [string] $m.rotulo; RedeLocal = $rl; Vpn = $vpn; VpnDown = $vpndl; Veredito = $ver
        })
    }
    $w.FindName('dgMedicoes').ItemsSource = $linhas
}

# Gate do passo 6 -> 7: exige a escolha da conexao recomendada e o motivo
# (obrigatorio por enquanto). Grava a escolha em $Global:RecomendacaoLocal.
function Test-RecomendacaoValida {
    $w = $Global:JanelaPrincipal
    if (-not @($Global:Medicoes | Where-Object { $_ }).Count) {
        Write-Log 'Rode a bateria em pelo menos um meio (ou marque os meios como nao aplicaveis) antes de concluir.' -Nivel Aviso
        return $false
    }
    $sel = [string] $w.FindName('cboConexaoRec').SelectedItem
    if (-not $sel) {
        Write-Log 'Escolha a conexao recomendada para este local.' -Nivel Erro
        return $false
    }
    $motivo = ([string] $w.FindName('txtMotivoRec').Text).Trim()
    if (-not $motivo) {
        Write-Log 'Informe o motivo da recomendacao (obrigatorio).' -Nivel Erro
        return $false
    }
    $Global:MotivoRecomendacao = $motivo
    $Global:RecomendacaoLocal  = Resolve-RecomendacaoSelecionada -Rotulo $sel
    Write-Log ('Conexao recomendada: {0} -> {1}{2}' -f `
        $Global:RecomendacaoLocal.rotulo, (Get-RotuloVeredito $Global:RecomendacaoLocal.veredito),
        (& { if ($Global:RecomendacaoLocal.provisoria) { ' (provisoria)' } else { '' } })) -Nivel Ok
    return $true
}

# Marca um meio como "nao aplicavel" a este local (com motivo).
function Set-MeioNaoAplicavel {
    param([string] $Meio, [string] $Motivo)
    $Global:MeiosNaoAplicaveis[$Meio] = $Motivo
    $lista = @($Global:Medicoes | Where-Object { $_.meio -ne $Meio })
    $med = [pscustomobject]@{
        meio = $Meio; operadora = ''; rotulo = Get-RotuloMeio $Meio ''
        nao_aplicavel = $true; motivo_na = $Motivo
        fase_local = $null; rede_local_ok = $false; rede_local_download = $null
        vpn_conectou = $false; vpn_motivo = ''; vpn_download = $null; metricas = $null; fase2_ok = $false
        decisao = $null; iperf = $null; ambiente = $null; avaliacoes = @()
        veredito = 'nao_testado'; quando = (Get-Date).ToString('o')
    }
    $Global:Medicoes = @($lista + $med)
}

# Novo local: zera todas as medicoes.
function Reset-Medicoes {
    $Global:Medicoes           = @()
    $Global:MeioAtual          = ''
    $Global:OperadoraAtual     = ''
    $Global:MeiosNaoAplicaveis = @{}
    $Global:RecomendacaoLocal  = $null
    $Global:MotivoRecomendacao = ''
    $Global:MedicoesPasso5     = @()
    $Global:MedicaoPasso5Idx   = -1
}

# Comeca uma nova rodada de medicao (outro meio) sem perder as anteriores.
function Reset-RodadaMeio {
    Clear-PainelResultado
    Reset-PainelFaseLocal
}

# Zera o passo 3 (painel de meios) ao abrir o assistente limpo / pelo guia.
function Reset-PainelFaseLocal {
    $Global:FaseLocalPayload = $null
    $Global:FaseLocalTipo    = ''
    $Global:MeioSelecionado  = ''
    $Global:CheckMeioAtivo   = $false
    Reset-Velocimetro
    Reset-Velocimetro -Suf 'Vpn'
    $w = $Global:JanelaPrincipal
    if ($w) {
        $ov = $w.FindName('overlayCheck'); if ($ov) { $ov.Visibility = 'Collapsed' }
        $w.FindName('cboOperadoraCel').Text = ''
        $Global:NaMeioPendente = ''
        $cj = $w.FindName('cardNaJustif'); if ($cj) { $cj.Visibility = 'Collapsed' }
        $tj = $w.FindName('txtNaJustif');  if ($tj) { $tj.Text = '' }
        foreach ($n in 'chkNaLan', 'chkNaWifi', 'chkNaCelular') {
            $c = $w.FindName($n); if ($c) { $c.IsChecked = $false }
        }
        foreach ($n in 'txtNaMotivoCardLan', 'txtNaMotivoCardWifi', 'txtNaMotivoCardCelular') {
            $t = $w.FindName($n); if ($t) { $t.Text = ''; $t.Visibility = 'Collapsed' }
        }
    }
    Update-PainelMeios
}

# Atualiza os check-marks do passo 7 (verde = feito, vermelho = pendente).
function Update-ChecklistFim {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $itens = @(
        @{ n = 'chkFimSalvar';    ok = $Global:FeitoSalvar }
        @{ n = 'chkFimTransmitir'; ok = $Global:FeitoTransmitir }
        @{ n = 'chkFimExportar';   ok = $Global:FeitoExportar }
    )
    foreach ($it in $itens) {
        $t = $w.FindName($it.n)
        if (-not $t) { continue }
        $t.Text       = if ($it.ok) { [char]0x2713 } else { [char]0x2717 }
        $t.Foreground = if ($it.ok) { $verde } else { $vermelho }
    }

    # "Finalizar": exige Salvar + Exportar (o essencial e o registro em PDF).
    # Transmitir pode ficar pendente - vai sozinho no proximo "Atualizar dados".
    $prontoFim = [bool] $Global:FeitoSalvar -and [bool] $Global:FeitoExportar
    $btnFim = $w.FindName('btnFinalizarDiag')
    if ($btnFim) { $btnFim.IsEnabled = $prontoFim }
    $dica = $w.FindName('txtFimFinalizarDica')
    if ($dica) {
        if ($prontoFim -and -not $Global:FeitoTransmitir) {
            $dica.Text = 'Pode finalizar mesmo assim - a transmissao pendente vai no proximo "Atualizar dados".'
            $dica.Visibility = 'Visible'
        } elseif (-not $prontoFim) {
            $falta = @()
            if (-not $Global:FeitoSalvar)   { $falta += 'salvar o resultado' }
            if (-not $Global:FeitoExportar) { $falta += 'exportar o relatorio (PDF)' }
            $dica.Text = 'Falta ' + ($falta -join ' e ') + ' para liberar o "Finalizar".'
            $dica.Visibility = 'Visible'
        } else {
            $dica.Visibility = 'Collapsed'
        }
    }
}

# Preenche o passo 7 (conclusao).
function Update-ResumoFim {
    $w = $Global:JanelaPrincipal
    $p = $Global:DiagPayload
    if (-not $p) { return }
    $rec = $Global:RecomendacaoLocal
    # a decisao final do local passa a ser o veredito do meio recomendado.
    $dec = if ($rec) { [string] $rec.veredito } else { [string] $w.FindName('cboDecisaoFinal').SelectedItem }
    $txt = 'ZE {0} - {1} / {2} ({3})' -f `
        $p.Local.zona_eleitoral, $p.Local.municipio_termo, $p.Local.nome, $p.Local.tipo
    if ($rec) {
        $txt += "`nConexao recomendada: " + [string] $rec.rotulo
        if ($rec.provisoria) { $txt += '  (provisoria - nenhum meio fechou a VPN)' }
        if ($Global:MotivoRecomendacao) { $txt += "`nMotivo: " + [string] $Global:MotivoRecomendacao }
    }
    $w.FindName('txtFimLocal').Text = $txt
    $ver = $w.FindName('txtFimVeredito')
    $ver.Text       = Get-PalavraVeredito $dec
    $ver.Foreground = Get-PincelVeredito $dec
    $w.FindName('btnSalvarResultado').IsEnabled     = $true
    $w.FindName('btnExportarPdf').IsEnabled         = $true
    $w.FindName('btnTransmitirResultado').IsEnabled = ($Global:FeitoSalvar -and -not $Global:FeitoTransmitir)
    Update-ChecklistFim
}

# Trava os botoes do passo 7 e mostra o anel enquanto transmite (async).
function Set-FimOcupado {
    param([bool] $Ocupado)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $ring = $w.FindName('ringFim')
    if ($ring) { $ring.IsActive = $Ocupado; $ring.Visibility = if ($Ocupado) { 'Visible' } else { 'Collapsed' } }
    foreach ($n in 'btnSalvarResultado', 'btnTransmitirResultado', 'btnExportarPdf', 'btnFinalizarDiag', 'btnWizVoltar') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
}

function Invoke-TransmitirResultado {
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtFimStatus')
    if (-not $Global:UltimoResultadoSalvo -or -not (Test-Path $Global:UltimoResultadoSalvo)) {
        Write-Log 'Salve o resultado antes de transmitir.' -Nivel Aviso
        if ($st) { $st.Text = 'Salve o resultado antes de transmitir.' }
        return
    }
    $cfg = $null
    try { $cfg = Get-Config 'envio' } catch { }

    $st.Text = 'Transmitindo ao painel...'
    Set-FimOcupado $true

    if ($Global:ModoTeste) {   # testes: sincrono, sem runspace
        $ok = $false
        try {
            $ok = Send-Resultado -Caminho $Global:UltimoResultadoSalvo -Endpoint $cfg.endpoint_apps_script `
                -Retentativas ($cfg.retentativas) -IntervaloS ($cfg.intervalo_retentativa_s)
        } catch { Complete-TransmitirResultado $false "$_"; return }
        Complete-TransmitirResultado $ok $null
        return
    }

    Start-TarefaRede `
        -Script 'Send-Resultado -Caminho $Caminho -Endpoint $Endpoint -Retentativas $Ret -IntervaloS $Int' `
        -Vars @{
            Caminho  = $Global:UltimoResultadoSalvo
            Endpoint = $cfg.endpoint_apps_script
            Ret      = $cfg.retentativas
            Int      = $cfg.intervalo_retentativa_s
        } `
        -AoConcluir { param($res, $erro) Complete-TransmitirResultado $res $erro }
}

function Complete-TransmitirResultado {
    param($Ok, $Erro)
    Set-FimOcupado $false
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtFimStatus')
    if ($Erro) {
        Write-Log "Falha ao transmitir: $Erro" -Nivel Erro
        $st.Text = "Falha ao transmitir: $Erro"
    } elseif ($Ok) {
        $Global:FeitoTransmitir = $true
        $st.Text = 'Resultado transmitido ao painel.'
        Write-Log 'Resultado transmitido ao painel.' -Nivel Ok
    } else {
        $st.Text = 'Nao foi possivel transmitir agora. O resultado fica pendente e vai no proximo "Atualizar dados".'
    }
    Update-ResumoFim
    Update-AvisoPendentes
}

# "Finalizar" (passo 7): volta para a tela inicial ja com o progresso do
# roteiro atualizado. O resultado ja esta salvo localmente.
function Invoke-FinalizarDiagnostico {
    if (-not ($Global:FeitoSalvar -and $Global:FeitoExportar)) {
        $w = $Global:JanelaPrincipal
        $st = $w.FindName('txtFimStatus')
        if ($st) { $st.Text = 'Salve o resultado e exporte o relatorio (PDF) antes de finalizar.' }
        return
    }
    if (-not $Global:FeitoTransmitir) {
        Write-Log 'Diagnostico finalizado. A transmissao ficou pendente - vai no proximo "Atualizar dados".' -Nivel Aviso
    } else {
        Write-Log 'Diagnostico finalizado.' -Nivel Ok
    }
    $Global:WizardStep = 1
    Enter-Home -Sessao $Global:SessaoAtual
}

function Invoke-ExportarRelatorio {
    $w = $Global:JanelaPrincipal
    if (-not $Global:DiagPayload -or -not $Global:AvaliacaoRows) {
        Write-Log 'Rode o diagnostico antes de exportar o relatorio.' -Nivel Aviso
        return
    }
    $st = $w.FindName('txtFimStatus'); $st.Text = 'Gerando relatorio (PDF)...'

    # monta o JSON aqui (le controles da UI); a conversao pesada (navegador
    # headless) roda em segundo plano com o mesmo anel do "Transmitir".
    $res = $null
    try {
        $avaliacoes = @()
        foreach ($r in @($Global:AvaliacaoRows)) {
            $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
        }
        $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
        $justDec  = [string] $w.FindName('txtJustDecisao').Text
        $p = $Global:DiagPayload
        $rec = if ($Global:RecomendacaoLocal) { $Global:RecomendacaoLocal } else { Get-RecomendacaoLocal }
        $res = New-ResultadoJson -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome) -FaseLocal $Global:FaseLocalPayload `
            -Tethering ($rec -and $rec.meio -eq 'celular') `
            -Operadora ([string] $(if ($rec) { $rec.operadora } else { '' })) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim()) `
            -Medicoes $Global:Medicoes -ConexaoRecomendada $rec `
            -MotivoRecomendacao ([string] $Global:MotivoRecomendacao) `
            -VistoriaGel $Global:VistoriaGel
    } catch {
        $st.Text = "Falha ao montar o relatorio: $_"
        Write-Log "Falha ao montar o relatorio: $_" -Nivel Erro
        return
    }

    Set-FimOcupado $true

    if ($Global:ModoTeste) {
        try { $out = Export-RelatorioPdf -Resultado $res } catch { Complete-ExportarRelatorio $null "$_"; return }
        Complete-ExportarRelatorio $out $null
        return
    }

    Start-TarefaRede -Script 'Export-RelatorioPdf -Resultado $Res' -Vars @{ Res = $res } `
        -AoConcluir { param($out, $erro) Complete-ExportarRelatorio $out $erro }
}

function Complete-ExportarRelatorio {
    param($Saida, $Erro)
    Set-FimOcupado $false
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtFimStatus')
    if ($Erro) {
        $st.Text = "Falha ao exportar: $Erro"
        Write-Log "Falha ao exportar relatorio: $Erro" -Nivel Erro
    } else {
        $Global:FeitoExportar = $true
        $st.Text = "Relatorio salvo: $Saida"
        Write-Log "Relatorio salvo: $Saida" -Nivel Ok
        if (-not $Global:ModoTeste -and $Saida) { try { Start-Process -FilePath $Saida } catch { } }
    }
    Update-ResumoFim
}

# Abre o assistente de diagnostico do zero (menu Inicio / rail).
function Open-DiagnosticoLimpo {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $Global:LogEntries.Clear()
    $w.FindName('cboJunta').SelectedIndex = -1   # dispara Update-ComboLocais -> limpa cboLocal
    $w.FindName('cboLocal').ItemsSource = @()
    Clear-PainelResultado
    Reset-PainelFaseLocal
    Reset-Medicoes
    Set-ProgressoDiag $false
    Show-WizardPasso 1
    Show-View 'viewDiag'
}

# Abre o assistente pelo atalho do guia de bordo: comeca no passo 1, mas ja
# pre-seleciona a Junta/Local que o tecnico clicou.
function Start-DiagnosticoDoGuia {
    param([string] $LocalId)
    $w = $Global:JanelaPrincipal

    $Global:LogEntries.Clear()
    Clear-PainelResultado
    Reset-PainelFaseLocal
    Reset-Medicoes
    Set-ProgressoDiag $false

    $loc = @($Global:JuntasCache) | Where-Object { $_.id -eq $LocalId } | Select-Object -First 1
    if ($loc) {
        $chave = '{0}|{1}' -f $loc.zona_eleitoral, $loc.municipio_termo
        $cboJunta = $w.FindName('cboJunta')
        $alvo = @($cboJunta.Items) | Where-Object { $_.Chave -eq $chave } | Select-Object -First 1
        if ($alvo) { $cboJunta.SelectedItem = $alvo }   # dispara Update-ComboLocais

        $cboLocal = $w.FindName('cboLocal')
        $li = @($cboLocal.Items) | Where-Object { $_.Dados.id -eq $LocalId } | Select-Object -First 1
        if ($li) { $cboLocal.SelectedItem = $li }
    } else {
        Write-Log "Local '$LocalId' nao esta no cache de juntas. Atualize os dados." -Nivel Aviso
    }

    Show-WizardPasso 1
    Show-View 'viewDiag'
}

# ------------------------------------------------------------- ADMIN (LIMIARES)

function Show-Admin {
    Initialize-Admin
    Show-View 'viewAdmin'
}

function Initialize-Admin {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $lim = Get-LimiaresConfig
    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($info in $Global:MetricasInfo) {
        $rows.Add((New-LimiarRow -Info $info -Limiar $lim.($info.metrica)))
    }
    $Global:LimiarRows = $rows
    $w.FindName('dgLimiares').ItemsSource = $rows
    $w.FindName('txtPinAdmin').Password = ''
    $w.FindName('lblAdminMsg').Text = ''

    # ambiente de teste (iperf3) - config local
    $amb = $null
    try { $amb = Get-Config 'ambiente' } catch { }
    $ip = if ($amb -and $amb.iperf3) { $amb.iperf3 } else { $null }
    $w.FindName('txtIperfServidorCfg').Text = if ($ip) { [string] $ip.servidor } else { '' }
    $w.FindName('txtIperfPortaCfg').Text    = if ($ip -and $ip.porta) { [string] $ip.porta } else { '5201' }
    $w.FindName('txtIperfDuracaoCfg').Text  = if ($ip -and $ip.duracao_s) { [string] $ip.duracao_s } else { '10' }
    $w.FindName('txtMapsKeyCfg').Text = Get-ChaveMapsStatic
    $w.FindName('lblAmbienteMsg').Text = ''
}

function Invoke-SalvarAmbiente {
    $w = $Global:JanelaPrincipal
    $msg = $w.FindName('lblAmbienteMsg')
    $vermelho = [Windows.Media.Brushes]::OrangeRed

    $pin = $w.FindName('txtPinAdmin').Password
    if ([string]::IsNullOrWhiteSpace($pin)) { $msg.Foreground = $vermelho; $msg.Text = 'Digite o PIN do administrador para salvar.'; return }
    if (-not (Test-PinAdmin $pin))          { $msg.Foreground = $vermelho; $msg.Text = 'PIN incorreto.'; return }

    $srv = ([string] $w.FindName('txtIperfServidorCfg').Text).Trim()
    $porta = 0; $dur = 0
    $okP = [int]::TryParse(([string] $w.FindName('txtIperfPortaCfg').Text).Trim(), [ref] $porta)
    $okD = [int]::TryParse(([string] $w.FindName('txtIperfDuracaoCfg').Text).Trim(), [ref] $dur)
    if (-not $srv) { $msg.Foreground = $vermelho; $msg.Text = 'Informe o IP ou host do servidor iperf3.'; return }
    if (-not $okP -or $porta -lt 1 -or $porta -gt 65535) { $msg.Foreground = $vermelho; $msg.Text = 'Porta invalida (1-65535).'; return }
    if (-not $okD -or $dur -lt 3 -or $dur -gt 60) { $msg.Foreground = $vermelho; $msg.Text = 'Duracao invalida (3-60 s).'; return }

    $mapsKey = ([string] $w.FindName('txtMapsKeyCfg').Text).Trim()

    try {
        $arq = Save-ConfigAmbiente -Servidor $srv -Porta $porta -Duracao $dur -MapsKey $mapsKey
        $msg.Foreground = [Windows.Media.Brushes]::LightGreen
        $extra = if ($mapsKey) { ' + chave do Google Maps' } else { '' }
        $msg.Text = "Ambiente salvo neste computador ($srv`:$porta$extra)."
        Write-Log "Ambiente salvo pelo admin: iperf3 $srv`:$porta / ${dur}s ; maps_key=$(if ($mapsKey) { 'definida' } else { 'vazia' }) -> $arq" -Nivel Ok
    } catch {
        $msg.Foreground = $vermelho
        $msg.Text = "Falha ao salvar: $_"
    }
}

function Invoke-SalvarLimiares {
    $w = $Global:JanelaPrincipal
    $msg = $w.FindName('lblAdminMsg')

    $pin = $w.FindName('txtPinAdmin').Password
    if ([string]::IsNullOrWhiteSpace($pin)) {
        $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
        $msg.Text = 'Digite o PIN do administrador para salvar.'
        return
    }

    $limiares = @{}
    foreach ($r in $Global:LimiarRows) {
        $v = 0.0; $rr = 0.0
        $okV = [double]::TryParse(($r.LimiarViavel   -replace ',', '.'), [ref] $v)
        $okR = [double]::TryParse(($r.LimiarRessalva -replace ',', '.'), [ref] $rr)
        if (-not $okV -or -not $okR -or $v -le 0 -or $rr -le 0) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "Valores invalidos em '$($r.Rotulo)'. Use numeros maiores que zero."
            return
        }
        if ($r.Direcao -eq 'max' -and $v -gt $rr) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "'$($r.Rotulo)': o ideal deve ser <= a ressalva."
            return
        }
        if ($r.Direcao -eq 'min' -and $v -lt $rr) {
            $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
            $msg.Text = "'$($r.Rotulo)': o ideal deve ser >= a ressalva."
            return
        }
        if ($r.Direcao -eq 'max') {
            $limiares[$r.Metrica] = @{ viavel_ate = $v; ressalva_ate = $rr; ativo = [bool] $r.Ativo }
        } else {
            $limiares[$r.Metrica] = @{ viavel_min = $v; ressalva_min = $rr; ativo = [bool] $r.Ativo }
        }
    }

    $w.FindName('btnSalvarLimiares').IsEnabled = $false
    $msg.Foreground = [Windows.Media.Brushes]::SkyBlue
    $msg.Text = 'Salvando...'
    try {
        $res = Save-Limiares -Limiares $limiares -Pin $pin
        switch ($res) {
            'ok'     { $msg.Foreground = [Windows.Media.Brushes]::LightGreen; $msg.Text = 'Limiares salvos.'; Write-Log 'Limiares salvos pelo admin.' -Nivel Ok }
            'negado' { $msg.Foreground = [Windows.Media.Brushes]::OrangeRed;  $msg.Text = 'PIN incorreto.' }
            default  { $msg.Foreground = [Windows.Media.Brushes]::OrangeRed;  $msg.Text = ($res -replace '^erro:', 'Falha: ') }
        }
    } finally {
        $w.FindName('btnSalvarLimiares').IsEnabled = $true
    }
}

function Invoke-RecarregarLimiares {
    $w = $Global:JanelaPrincipal
    $msg = $w.FindName('lblAdminMsg')
    $msg.Foreground = [Windows.Media.Brushes]::SkyBlue
    $msg.Text = 'Baixando...'
    try {
        Sync-Limiares | Out-Null
        Initialize-Admin
        $msg.Foreground = [Windows.Media.Brushes]::LightGreen
        $msg.Text = 'Limiares recarregados da planilha.'
    } catch {
        $msg.Foreground = [Windows.Media.Brushes]::OrangeRed
        $msg.Text = "Falha ao baixar: $_"
    }
}

# ------------------------------------------------------------- DIAGNOSTICO (JUNTAS)

function Initialize-SeletorJuntas {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $Global:JuntasCache = @(Get-Juntas)
    $w.FindName('cboLocal').ItemsSource = @()
    Update-SeletorJuntas
}

# Rotulo da Junta no formato "<Municipio termo> - ZE-XXX <Municipio sede>".
function Format-ZonaNum {
    param($Zona)
    $n = 0
    if ([int]::TryParse([string] $Zona, [ref] $n)) { return '{0:D3}' -f $n }
    return [string] $Zona
}
function Format-MunicipioSede {
    param([string] $Sede)
    if ([string]::IsNullOrWhiteSpace($Sede)) { return '' }
    $conect = 'de', 'da', 'do', 'das', 'dos', 'e'
    $ti = (Get-Culture).TextInfo
    (($Sede.ToLower() -split '\s+') | ForEach-Object {
        if ($_ -in $conect) { $_ } else { $ti.ToTitleCase($_) }
    }) -join ' '
}
function Format-RotuloJunta {
    param($Zona, [string] $Termo, [string] $Sede)
    '{0} - ZE-{1} {2}' -f $Termo, (Format-ZonaNum $Zona), (Format-MunicipioSede $Sede)
}

# Popula o combo "Junta Especial": so as Juntas da rota do tecnico logado, a
# menos que o admin tenha marcado "incluir fora da rota" (ou nao haja roteiro).
function Update-SeletorJuntas {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $cboJunta = $w.FindName('cboJunta')
    $locais = @($Global:JuntasCache)
    if (-not $locais.Count) { $cboJunta.ItemsSource = @(); return }

    $rot = $Global:RoteiroAtual
    $chavesRota = @()
    if ($rot) {
        $chavesRota = @($rot.juntas | ForEach-Object { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo })
    }
    $filtrar = ($chavesRota.Count -gt 0) -and (-not $Global:MostrarTodasJuntas)

    $juntas = $locais |
        Group-Object -Property { '{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo } |
        ForEach-Object {
            $p = $_.Group[0]
            [pscustomobject]@{
                Chave  = $_.Name
                Zona   = $p.zona_eleitoral
                Termo  = $p.municipio_termo
                Sede   = $p.municipio_sede
                NaRota = ($_.Name -in $chavesRota)
                Rotulo = Format-RotuloJunta $p.zona_eleitoral $p.municipio_termo $p.municipio_sede
            }
        }

    if ($filtrar) { $juntas = $juntas | Where-Object { $_.NaRota } }
    $juntas = @($juntas | Sort-Object @{ Expression = { -not $_.NaRota } }, Zona, Termo)

    $cboJunta.ItemsSource = $juntas
    # so registra no feed depois do login (a montagem inicial e ruido)
    if ($Global:SessaoAtual) {
        $modo = if ($filtrar) { 'rota do tecnico' } elseif ($chavesRota.Count) { 'todas (admin)' } else { 'todas (sem roteiro)' }
        Write-Log ("Seletor de Juntas: {0} Junta(s) - {1}." -f $juntas.Count, $modo) -Nivel Info
    }
}

function Update-ComboLocais {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $sel      = $w.FindName('cboJunta').SelectedItem
    $cboLocal = $w.FindName('cboLocal')
    if (-not $sel) { $cboLocal.ItemsSource = @(); return }

    $itens = @(
        $Global:JuntasCache |
            Where-Object { ('{0}|{1}' -f $_.zona_eleitoral, $_.municipio_termo) -eq $sel.Chave } |
            Sort-Object { if ($_.tipo -eq 'principal') { 0 } else { 1 } } |
            ForEach-Object {
                $rot = if ($_.tipo -eq 'principal') { 'Principal' } else { 'Contingencia' }
                [pscustomobject]@{ Rotulo = '{0}  -  {1}' -f $rot, $_.nome; Dados = $_ }
            }
    )
    $cboLocal.ItemsSource = $itens
    if ($itens.Count) { $cboLocal.SelectedIndex = 0 }
}

function Invoke-AtualizarListaJuntas {
    $w = $Global:JanelaPrincipal
    $btn = $w.FindName('btnAtualizar')
    $btn.IsEnabled = $false
    try {
        $n = Sync-Juntas
        Write-Log ("Lista atualizada: {0} locais." -f $n) -Nivel Ok
        Initialize-SeletorJuntas
    } catch {
        Write-Log "Falha ao atualizar a lista: $_" -Nivel Erro
    } finally {
        $btn.IsEnabled = $true
    }
}

# Gate da VPN no overlay (Fase 2). Sem VPN -> aparecem "Abrir o FortiClient" +
# "Verificar novamente" e a saida "nao consegui conectar a VPN".
function Update-EstadoVpn {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $d = Get-DetalheVpn
    $vpn = [bool] $d.ativa

    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $tv = $w.FindName('txtDiagVpn'); $dv = $w.FindName('dotVpn')
    if ($tv) {
        if ($vpn) {
            $linhas = @('VPN da Justica Eleitoral conectada.')
            if ($d.ipv4) {
                $marca = if (Test-RedeJusticaEleitoral $d.ipv4) { '  (faixa interna da JE)' } else { '' }
                $linhas += ('IP da VPN: {0}{1}' -f $d.ipv4, $marca)
            }
            if ($d.nome)    { $linhas += ('Interface: {0}' -f $d.nome) }
            if ($d.gateway) { $linhas += ('Gateway: {0}' -f $d.gateway) }
            if (@($d.dns).Count) { $linhas += ('DNS: {0}' -f ((@($d.dns)) -join ', ')) }
            $tv.Text = ($linhas -join "`n")
            $tv.Foreground = $verde ; $dv.Fill = $verde
        } else {
            $tv.Text = 'VPN da Justica Eleitoral NAO detectada - conecte pelo FortiClient e clique em "Verificar novamente".'
            $tv.Foreground = $vermelho ; $dv.Fill = $vermelho
        }
    }
    $bf = $w.FindName('btnAbrirFortiClient'); if ($bf) { $bf.Visibility = if ($vpn) { 'Collapsed' } else { 'Visible' } }
    $bv = $w.FindName('btnReverificarVpn');   if ($bv) { $bv.Visibility = if ($vpn) { 'Collapsed' } else { 'Visible' } }
    # VPN conectada -> some a saida de escape "nao consegui a VPN" (nao faz sentido)
    if ($vpn) {
        $ci = $w.FindName('chkVpnImpossivel'); if ($ci) { $ci.IsChecked = $false }
        foreach ($n in 'chkVpnImpossivel', 'txtVpnMotivo', 'txtVpnMotivoDica', 'btnChkVpnImpossivel') {
            $c = $w.FindName($n); if ($c) { $c.Visibility = 'Collapsed' }
        }
    }
}

# Checkbox "Nao foi possivel conectar a VPN" -> libera/limpa o campo de motivo.
function Update-VpnImpossivel {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $on = [bool] $w.FindName('chkVpnImpossivel').IsChecked
    $vis = if ($on) { 'Visible' } else { 'Collapsed' }
    $w.FindName('txtVpnMotivo').Visibility     = $vis
    $w.FindName('txtVpnMotivoDica').Visibility = $vis
    if (-not $on) { $w.FindName('txtVpnMotivo').Text = '' }
}

# Registra o local como INVIAVEL por VPN indisponivel (sem rodar a bateria).
function Set-DiagnosticoVpnImpossivel {
    param([string] $Motivo)
    $w = $Global:JanelaPrincipal
    $sel = $w.FindName('cboLocal').SelectedItem
    if (-not $sel) { return }
    $met = [pscustomobject]@{
        LatenciaMediaMs = $null; JitterMs = $null; PerdaPercentual = $null
        BandaDownloadMbps = $null; BandaUploadMbps = $null; CarregamentoWebS = $null
    }
    $dec = Invoke-MotorDecisao -Metricas $met -Limiares (Get-LimiaresConfig)
    $amb = Get-EstadoAmbiente
    Show-PainelResultado -Payload ([pscustomobject]@{ Ambiente = $amb; Metricas = $met; Decisao = $dec; Local = $sel.Dados })
    Write-Log ("VPN impossivel de conectar - local registrado como INVIAVEL. Motivo: {0}" -f $Motivo) -Nivel Aviso
}

function Invoke-ReverificarVpn {
    Update-EstadoVpn
    # no overlay: se a VPN subiu agora, mostra a confirmacao (IP da VPN etc.) e
    # troca o botao para "Iniciar diagnostico" - NAO dispara o teste sozinho.
    if ($Global:CheckMeioAtivo -and -not $Global:DiagRunState -and -not $Global:DiagPayload -and (Test-VpnAtiva)) {
        Start-CheckFase2
    }
}

function Invoke-AbrirFortiClient {
    if ($Global:ModoTeste) { Write-Log 'FortiClient (modo teste, nao abre).' -Nivel Info; return }
    $exe = Get-CaminhoFortiClient
    if (-not $exe) {
        Write-Log 'FortiClient nao encontrado neste computador. Abra a VPN manualmente.' -Nivel Erro
        $tv = $Global:JanelaPrincipal.FindName('txtDiagVpn')
        if ($tv) { $tv.Text = 'FortiClient nao encontrado - abra a VPN da JE manualmente e clique em "Verificar novamente".' }
        return
    }
    try {
        Start-ProcessoNaoElevado -Caminho $exe
        Write-Log "Abrindo o FortiClient: $exe" -Nivel Info
    } catch {
        Write-Log "Falha ao abrir o FortiClient: $_" -Nivel Erro
    }
}

# ------------------------------------------------------------- PAINEL DE RESULTADOS

function Clear-PainelResultado {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $Global:DiagPayload        = $null
    $Global:AvaliacaoRows      = $null
    $Global:DecisaoRecalculada = $null
    $Global:DecisaoFinalTocada = $false
    $Global:MedicaoPasso5Idx   = -1

    $tb = $w.FindName('tabsMedicoes')
    if ($tb) { $Global:AtualizandoMedicaoP5 = $true; $tb.Items.Clear(); $tb.Visibility = 'Collapsed'; $Global:AtualizandoMedicaoP5 = $false }
    $cn = $w.FindName('cardNaResumo');  if ($cn) { $cn.Visibility = 'Collapsed' }
    $sm = $w.FindName('txtSemMedicoes'); if ($sm) { $sm.Visibility = 'Collapsed' }
    $w.FindName('dgAvaliacaoVpn').ItemsSource = @()
    $w.FindName('dgAvaliacaoRl').ItemsSource = @()
    $cr = $w.FindName('cardAvaliacaoRl'); if ($cr) { $cr.Visibility = 'Collapsed' }
    $tn = $w.FindName('txtRedeLocalNota'); if ($tn) { $tn.Visibility = 'Collapsed' }
    $Global:AtualizandoDecisao = $true
    $w.FindName('cboDecisaoFinal').SelectedItem = $null
    $Global:AtualizandoDecisao = $false
    $w.FindName('txtJustDecisao').Text  = ''
    $w.FindName('lblDecisaoRecalc').Text = ''
    $w.FindName('btnSalvarResultado').IsEnabled = $false
    $w.FindName('btnExportarPdf').IsEnabled = $false
    $w.FindName('btnTransmitirResultado').IsEnabled = $false
    $w.FindName('txtFimStatus').Text = ''
    $w.FindName('cardDetalheLocal').Visibility = 'Collapsed'
    $w.FindName('chkVpnImpossivel').IsChecked = $false
    $w.FindName('txtVpnMotivo').Text = ''
    $w.FindName('txtVpnMotivo').Visibility = 'Collapsed'
    $w.FindName('txtVpnMotivoDica').Visibility = 'Collapsed'
    Reset-Velocimetro -Suf 'Vpn'
    $Global:FeitoSalvar     = $false
    $Global:FeitoTransmitir = $false
    $Global:FeitoExportar   = $false
    $Global:UltimoResultadoSalvo = $null
    Update-ChecklistFim
    Update-VisibilidadeJustDecisao
}

function Update-VisibilidadeJustDecisao {
    $w = $Global:JanelaPrincipal
    $sel = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $mostra = ($sel -and $Global:DecisaoRecalculada -and $sel -ne $Global:DecisaoRecalculada)
    $vis = if ($mostra) { 'Visible' } else { 'Collapsed' }
    $w.FindName('lblJustDecisao').Visibility = $vis
    $w.FindName('txtJustDecisao').Visibility = $vis
    Set-BarraDecisao $sel
}

function Complete-Diagnostico {
    param($Payload, $Erro)
    Set-ProgressoDiag $false
    if ($Erro) {
        Write-Log "Diagnostico falhou: $Erro" -Nivel Erro
        return
    }
    Show-PainelResultado -Payload $Payload
    if ($Payload.PSObject.Properties['Iperf'] -and $Payload.Iperf) { Update-IperfPainel -Iperf $Payload.Iperf }
    Write-Log 'Diagnostico concluido.' -Nivel Ok
}

# Nota acima do grid do passo 4 sobre a checagem da rede local (Fase 1, sem VPN).
function Set-NotaRedeLocal {
    param($Internet, [bool] $TemLinhas)
    $w = $Global:JanelaPrincipal
    $t = $w.FindName('txtRedeLocalNota')
    if (-not $t) { return }
    if ($TemLinhas) {
        $t.Text = 'As linhas "Rede local" vem do Speedtest da Ookla (sem a VPN) e entram no pior caso junto com as da VPN.'
        $t.Visibility = 'Visible'
    } elseif ($Internet) {
        $diag = if ($Internet.PSObject.Properties['speedtest_diagnostico']) { [string] $Internet.speedtest_diagnostico } else { '' }
        $err  = if ($Internet.PSObject.Properties['speedtest_erro']) { [string] $Internet.speedtest_erro } else { '' }
        $msg  = if ($diag) { $diag } elseif ($err) { $err } else { '' }
        if ($msg) {
            $t.Text = 'Rede local (sem VPN): nao foi medida. ' + $msg
            $t.Visibility = 'Visible'
        } else { $t.Visibility = 'Collapsed' }
    } else {
        $t.Visibility = 'Collapsed'
    }
}

function Show-PainelResultado {
    param($Payload, [hashtable] $Overrides)
    $w = $Global:JanelaPrincipal
    $Global:DiagPayload        = $Payload
    $Global:DecisaoFinalTocada = $false

    $rows    = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $rowsVpn = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $rowsRl  = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $addRow = {
        param($d, $fase, $dest)
        $row = New-AvaliacaoRow -Detalhe $d -Fase $fase
        if ($Overrides -and $Overrides.ContainsKey([string] $d.metrica)) {
            $o = $Overrides[[string] $d.metrica]
            if ($o.classe_final) { $row.ClasseFinal = [string] $o.classe_final }
            $row.Justificativa = [string] $o.justificativa
        }
        $rows.Add($row)
        $dest.Add($row)
        $row.add_PropertyChanged({
                param($s, $e)
                if ($e.PropertyName -eq 'ClasseFinal') { Update-DecisaoRecalculada }
            })
    }
    # linhas da Fase 2 (com a VPN do TRE)
    foreach ($d in @($Payload.Decisao.Detalhes)) { & $addRow $d 'Com a VPN' $rowsVpn }

    # linhas da Fase 1 (rede local, sem VPN) - do Speedtest da Ookla; entram no
    # pior caso junto com as da VPN.
    $rli = if ($Payload.PSObject.Properties['RedeLocalInternet'] -and $Payload.RedeLocalInternet) { $Payload.RedeLocalInternet }
           elseif ($Global:FaseLocalPayload) { $Global:FaseLocalPayload.Internet }
           else { $null }
    $d1 = @(Get-DetalhesRedeLocal -Internet $rli -Limiares (Get-LimiaresConfig))
    foreach ($d in $d1) { & $addRow $d 'Rede local' $rowsRl }

    $Global:AvaliacaoRows = $rows
    $w.FindName('dgAvaliacaoVpn').ItemsSource = $rowsVpn
    $w.FindName('dgAvaliacaoRl').ItemsSource  = $rowsRl

    Set-NotaRedeLocal $rli ($rowsRl.Count -gt 0)
    $dgRl = $w.FindName('dgAvaliacaoRl')
    $dgRl.Visibility = if ($rowsRl.Count) { 'Visible' } else { 'Collapsed' }
    $notaVis = "$($w.FindName('txtRedeLocalNota').Visibility)" -eq 'Visible'
    $w.FindName('cardAvaliacaoRl').Visibility = if ($rowsRl.Count -or $notaVis) { 'Visible' } else { 'Collapsed' }

    $des = @(if ($Payload.Decisao.PSObject.Properties['MetricasDesativadas']) { $Payload.Decisao.MetricasDesativadas })
    $lblDes = $w.FindName('txtMetricasDesativadas')
    if ($des.Count) {
        $lblDes.Text = 'Desativadas pela configuracao (nao avaliadas): ' + (($des | ForEach-Object { Get-RotuloMetrica $_ }) -join ', ')
        $lblDes.Visibility = 'Visible'
    } else {
        $lblDes.Visibility = 'Collapsed'
    }

    $w.FindName('txtJustDecisao').Text = ''
    $w.FindName('btnSalvarResultado').IsEnabled = $true
    Update-DecisaoRecalculada
}

# Passo 4 (resultado): monta uma ABA por meio testado + o resumo dos meios "nao
# aplicaveis", e abre a aba do meio que acabou de rodar.
function Update-SeletorMedicoes {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $tabs = $w.FindName('tabsMedicoes')

    $pares = @()
    for ($i = 0; $i -lt @($Global:Medicoes).Count; $i++) {
        $m = $Global:Medicoes[$i]
        if ($m -and -not $m.nao_aplicavel -and $m.decisao) {
            $pares += [pscustomobject]@{ idx = $i; med = $m }
        }
    }
    $Global:MedicoesPasso5 = $pares

    # resumo dos meios marcados "nao se aplica"
    $na = @($Global:Medicoes | Where-Object { $_ -and $_.nao_aplicavel })
    $cardNa = $w.FindName('cardNaResumo')
    if ($cardNa) {
        if ($na.Count) {
            $w.FindName('txtNaResumo').Text = 'Meios que NAO se aplicam a este local: ' +
                (($na | ForEach-Object { '{0} - {1}' -f $_.rotulo, ([string] $_.motivo_na) }) -join '     |     ')
            $cardNa.Visibility = 'Visible'
        } else { $cardNa.Visibility = 'Collapsed' }
    }

    if ($pares.Count -eq 0) {
        if ($tabs) { $Global:AtualizandoMedicaoP5 = $true; $tabs.Items.Clear(); $tabs.Visibility = 'Collapsed'; $Global:AtualizandoMedicaoP5 = $false }
        $w.FindName('txtSemMedicoes').Visibility = 'Visible'
        $Global:MedicaoPasso5Idx = -1
        return
    }
    $w.FindName('txtSemMedicoes').Visibility = 'Collapsed'

    # abre na ultima medicao registrada, ou na que ja estava aberta
    $sel = $pares.Count - 1
    if ($Global:MedicaoPasso5Idx -ge 0) {
        for ($k = 0; $k -lt $pares.Count; $k++) {
            if ($pares[$k].idx -eq $Global:MedicaoPasso5Idx) { $sel = $k }
        }
    }
    $Global:AtualizandoMedicaoP5 = $true
    $tabs.Items.Clear()
    $pincelMudo = $w.TryFindResource('Dicon.Text3')
    foreach ($p in $pares) {
        $ti = [Windows.Controls.TabItem]::new()
        $sp = [Windows.Controls.StackPanel]::new(); $sp.Orientation = 'Horizontal'
        $dot = [Windows.Shapes.Ellipse]::new()
        $dot.Width = 9; $dot.Height = 9; $dot.VerticalAlignment = 'Center'
        $dot.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        try { $dot.Fill = Get-PincelVeredito $p.med.veredito } catch { }
        $sp.Children.Add($dot) | Out-Null
        $tr = [Windows.Controls.TextBlock]::new()
        $tr.Text = [string] $p.med.rotulo; $tr.VerticalAlignment = 'Center'
        $sp.Children.Add($tr) | Out-Null
        $tv = [Windows.Controls.TextBlock]::new()
        $tv.Text = '  ' + (Get-PalavraVeredito $p.med.veredito)
        $tv.VerticalAlignment = 'Center'; $tv.FontSize = 10
        if ($pincelMudo) { $tv.Foreground = $pincelMudo }
        $sp.Children.Add($tv) | Out-Null
        $ti.Header = $sp
        $tabs.Items.Add($ti) | Out-Null
    }
    $tabs.Visibility = 'Visible'
    $tabs.SelectedIndex = $sel
    $Global:AtualizandoMedicaoP5 = $false

    Show-MedicaoNoPasso5 -Par $pares[$sel]
}

# Renderiza no grid do passo 5 a medicao escolhida (com os ajustes ja salvos).
function Show-MedicaoNoPasso5 {
    param($Par)
    $m = $Par.med
    $Global:MedicaoPasso5Idx = $Par.idx

    $localRef = if ($Global:DiagPayload) { $Global:DiagPayload.Local } else { $null }
    $payload = [pscustomobject]@{
        Ambiente          = $m.ambiente
        Metricas          = $m.metricas
        Decisao           = $m.decisao
        Local             = $localRef
        Iperf             = $m.iperf
        RedeLocalInternet = (Get-Prop $m.fase_local 'Internet')
    }
    $ovr = @{}
    foreach ($a in @($m.avaliacoes)) { if ($a -and $a.metrica) { $ovr[[string] $a.metrica] = $a } }
    Show-PainelResultado -Payload $payload -Overrides $ovr
}

# Handler das abas de medicao do passo 4: salva a aberta e mostra a escolhida.
function Invoke-TrocarMedicaoPasso5 {
    if ($Global:AtualizandoMedicaoP5) { return }
    $w = $Global:JanelaPrincipal
    $i = $w.FindName('tabsMedicoes').SelectedIndex
    $pares = @($Global:MedicoesPasso5)
    if ($i -lt 0 -or $i -ge $pares.Count) { return }
    Save-AjustesPasso5
    Show-MedicaoNoPasso5 -Par $pares[$i]
}

function Update-DecisaoRecalculada {
    $w = $Global:JanelaPrincipal
    if (-not $Global:AvaliacaoRows) { return }

    $classes = @($Global:AvaliacaoRows | ForEach-Object { $_.ClasseFinal })
    $recalc  = Get-ClassificacaoFinal $classes
    $Global:DecisaoRecalculada = $recalc
    $w.FindName('lblDecisaoRecalc').Text = "recalculada: $recalc"

    if (-not $Global:DecisaoFinalTocada) {
        $Global:AtualizandoDecisao = $true
        $w.FindName('cboDecisaoFinal').SelectedItem = $recalc
        $Global:AtualizandoDecisao = $false
    }
    Update-VisibilidadeJustDecisao
}

function Invoke-SalvarResultado {
    $w = $Global:JanelaPrincipal
    if (-not $Global:DiagPayload -or -not $Global:AvaliacaoRows) {
        Write-Log 'Rode o diagnostico antes de salvar.' -Nivel Aviso
        return
    }

    $falta = Get-JustificativasFaltando
    if ($falta.Count) {
        Write-Log ("Justificativa obrigatoria em: {0}" -f ($falta -join ', ')) -Nivel Erro
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Falta justificar: ' + ($falta -join ', ') }
        return
    }

    $avaliacoes = @()
    foreach ($r in $Global:AvaliacaoRows) {
        $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
    }
    # multi-meio: a decisao final do local vem do meio recomendado, salvo se o
    # tecnico tiver sobrescrito o combo da decisao final na mao.
    $decFinal = if ($Global:DecisaoFinalTocada) { [string] $w.FindName('cboDecisaoFinal').SelectedItem } else { '' }
    $justDec  = [string] $w.FindName('txtJustDecisao').Text

    $w.FindName('btnSalvarResultado').IsEnabled = $false
    try {
        $p = $Global:DiagPayload
        $rec = if ($Global:RecomendacaoLocal) { $Global:RecomendacaoLocal } else { Get-RecomendacaoLocal }
        $caminho = Save-Diagnostico -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes `
            -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome) `
            -FaseLocal $Global:FaseLocalPayload `
            -Tethering ($rec -and $rec.meio -eq 'celular') `
            -Operadora ([string] $(if ($rec) { $rec.operadora } else { '' })) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim()) `
            -Medicoes $Global:Medicoes -ConexaoRecomendada $rec `
            -MotivoRecomendacao ([string] $Global:MotivoRecomendacao) `
            -VistoriaGel $Global:VistoriaGel
        Write-Log "Resultado salvo: $caminho" -Nivel Ok
        $Global:FeitoSalvar          = $true
        $Global:UltimoResultadoSalvo = $caminho
        $w.FindName('btnTransmitirResultado').IsEnabled = $true
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Resultado salvo neste computador. Use "Transmitir" para enviar agora.' }
    } catch {
        Write-Log "Falha ao salvar: $_" -Nivel Erro
        $w.FindName('btnSalvarResultado').IsEnabled = $true
    }
    Update-ChecklistFim
    Update-AvisoPendentes
}

# ------------------------------------------------------------- ENVIO PENDENTES

# Mostra/oculta o aviso "N resultado(s) aguardando envio" na tela inicial.
function Update-AvisoPendentes {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $btn = $w.FindName('btnReenviarPendentes')
    if (-not $btn) { return }

    $n = @(Get-ChildItem (Join-Path $Global:RaizApp 'resultados\pendentes') -Filter '*.json' -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) {
        $btn.Content = if ($n -eq 1) {
            '1 resultado aguardando envio  -  Reenviar'
        } else {
            '{0} resultados aguardando envio  -  Reenviar' -f $n
        }
        $btn.Visibility = 'Visible'
    } else {
        $btn.Visibility = 'Collapsed'
    }
}

function Invoke-ReenvioPendentes {
    Start-TrabalhoHome -Rotulo 'Reenviando resultados...' -Trabalho {
        $cfg = $null
        try { $cfg = Get-Config 'envio' } catch { }
        Send-ResultadosPendentes -Endpoint $cfg.endpoint_apps_script | Out-Null
    } -AoConcluir {
        param($res, $erro)
        Update-AvisoPendentes
        $Global:JanelaPrincipal.FindName('painelLogHome').Visibility = if ($Global:LogHome.Count) { 'Visible' } else { 'Collapsed' }
    }
}

function Start-DiagnosticoAssincrono {
    param($Local, [scriptblock] $AoConcluir)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('RaizApp',          $Global:RaizApp)
    $rs.SessionStateProxy.SetVariable('LogEntries',       $Global:LogEntries)
    $rs.SessionStateProxy.SetVariable('JanelaPrincipal',  $Global:JanelaPrincipal)
    $rs.SessionStateProxy.SetVariable('ArquivoLog',       $Global:ArquivoLog)
    $rs.SessionStateProxy.SetVariable('BandaVpnSimulada', $Global:BandaVpnSimulada)  # hook de teste

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void] $ps.AddScript({
        param($local)
        Import-Module (Join-Path $RaizApp 'src\Conectividade.psd1') -Force
        try {
            [pscustomobject]@{ Payload = (Invoke-DiagnosticoCompleto -Local $local); Erro = $null }
        } catch {
            [pscustomobject]@{ Payload = $null; Erro = "$_" }
        }
    }).AddArgument($Local)

    $handle = $ps.BeginInvoke()

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $Global:DiagRunState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer; AoConcluir = $AoConcluir }

    $timer.Add_Tick({
      try {
        $st = $Global:DiagRunState
        if ($null -eq $st -or -not $st.Handle.IsCompleted) { return }

        $st.Timer.Stop()
        $Global:DiagRunState = $null

        $payload = $null
        $erro    = $null
        try {
            $r = $st.PS.EndInvoke($st.Handle) | Select-Object -First 1
            $payload = $r.Payload
            $erro    = $r.Erro
        } catch {
            $erro = "$_"
        } finally {
            try { $st.PS.Dispose(); $st.RS.Dispose() } catch { }
        }

        try {
            if ($st.AoConcluir) { & $st.AoConcluir $payload $erro }
            else { Complete-Diagnostico -Payload $payload -Erro $erro }
        } catch {
            Write-Log "Falha ao montar o painel apos o diagnostico: $_" -Nivel Erro
        }
      } catch {
        try { Write-Log "Diagnostico: falha inesperada ($_)." -Nivel Erro } catch { }
      }
    })
    $timer.Start()
}
