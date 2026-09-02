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
$Global:WizardStep         = 1       # passo atual do assistente de diagnostico (1..7)
$Global:HomeTrabalhoState  = $null   # runspace do "Atualizar dados"/"Reenviar" async
$Global:TarefaRedeState    = $null   # runspace da fase local / conexao Wi-Fi
$Global:LoginEmAndamento   = $false   # trava reentrancia de Enter-Sessao (duplo-clique em "Entrar")
$Global:FaseLocalPayload   = $null   # {Lan;Wireless;Internet;Quando} da fase 1 (sem VPN)
$Global:FaseLocalTipo      = ''      # placa escolhida no passo 3: '' | 'lan' | 'wifi'

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

$Global:Views = @('viewLogin', 'viewHome', 'viewGuia', 'viewLocais', 'viewLocalDetalhe', 'viewDiag', 'viewAdmin')

$Global:LocaisTecnico            = @()      # locais do roteiro do tecnico (achatados)
$Global:AtualizandoFiltroLocais  = $false   # guarda: preenchimento programatico dos combos
$Global:RailRecolhido            = $false   # menu lateral recolhido (so icones)?
$Global:VersaoNova               = ''       # versao mais recente no canal (se > a atual)

$Global:WizardPassos  = @('stepInfo', 'stepJunta', 'stepLocal', 'stepDiag', 'stepResultado', 'stepDecisao', 'stepFim')
$Global:WizardTitulos = @(
    ('Informa' + [char]0x00E7 + [char]0x00E3 + 'o do teste')
    'Junta Especial'
    'Rede local (sem VPN)'
    ('Diagn' + [char]0x00F3 + 'stico com a VPN')
    ('Resultado por m' + [char]0x00E9 + 'trica')
    ('Decis' + [char]0x00E3 + 'o final')
    ('Conclus' + [char]0x00E3 + 'o')
)

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

    # diagnostico
    $window.FindName('btnRodar').Add_Click({ Invoke-ExecucaoNaJanela })
    $window.FindName('btnAbrirFortiClient').Add_Click({ Invoke-AbrirFortiClient })
    $window.FindName('btnReverificarVpn').Add_Click({ Invoke-ReverificarVpn })
    $window.FindName('btnTestarOutroMeio').Add_Click({ Invoke-TestarOutroMeio })
    $window.FindName('chkVpnImpossivel').Add_Click({ Update-VpnImpossivel })
    $window.FindName('txtVpnMotivo').Add_TextChanged({ Update-Passo4Nav })
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
    $window.FindName('btnRodarFaseLocal').Add_Click({ Invoke-RodarFaseLocal })
    $window.FindName('btnRelerPlacas').Add_Click({ Invoke-RelerPlacas })
    $window.FindName('chkTetheringCelular').Add_Click({ Update-TetheringCelular })
    $window.FindName('rbUsarLan').Add_Checked({ Set-FaseLocalTipo 'lan' })
    $window.FindName('rbUsarWifi').Add_Checked({ Set-FaseLocalTipo 'wifi' })
    $window.FindName('rbUsarCelular').Add_Checked({ Set-FaseLocalTipo 'celular' })
    $window.FindName('cboOperadoraCel').Add_LostFocus({
            $w2 = $Global:JanelaPrincipal
            $w2.FindName('cboOperadora').Text = ([string] $w2.FindName('cboOperadoraCel').Text).Trim()
            Update-PainelFaseLocal
        })
    foreach ($n in 'chkNaLan', 'chkNaWifi', 'chkNaCelular') {
        $window.FindName($n).Add_Click({ Update-NaoAplicavelMeio })
    }
    $window.FindName('txtMotivoNaMeio').Add_LostFocus({ Update-NaoAplicavelMeio })
    $window.FindName('btnExportarPdf').Add_Click({ Invoke-ExportarRelatorio })
    $window.FindName('btnTransmitirResultado').Add_Click({ Invoke-TransmitirResultado })
    $window.FindName('btnDiagVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarResultado').Add_Click({ Invoke-SalvarResultado })
    $window.FindName('btnFinalizarDiag').Add_Click({ Invoke-FinalizarDiagnostico })
    $window.FindName('cboDecisaoFinal').Add_SelectionChanged({
            if (-not $Global:AtualizandoDecisao) { $Global:DecisaoFinalTocada = $true }
            Update-VisibilidadeJustDecisao
        })
    $window.FindName('cboMedicaoPasso5').Add_SelectionChanged({ Invoke-TrocarMedicaoPasso5 })
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
    if ($N -lt 1) { $N = 1 }
    if ($N -gt 7) { $N = 7 }
    $Global:WizardStep = $N

    for ($i = 0; $i -lt 7; $i++) {
        $vis = if ($i -eq ($N - 1)) { 'Visible' } else { 'Collapsed' }
        $w.FindName($Global:WizardPassos[$i]).Visibility = $vis
    }
    $w.FindName('txtWizTitulo').Text = $Global:WizardTitulos[$N - 1]
    $w.FindName('txtWizPasso').Text  = 'Passo {0} de 7' -f $N
    $w.FindName('prgWizard').Value   = $N

    $w.FindName('btnWizVoltar').IsEnabled = ($N -gt 1)
    $w.FindName('btnRefazerTeste').Visibility = 'Collapsed'
    $prox = $w.FindName('btnWizProximo')
    $prox.Visibility = if ($N -lt 7) { 'Visible' } else { 'Collapsed' }
    $prox.Content    = if ($N -eq 6) { 'Concluir' } else { 'Pr' + [char]0x00F3 + 'ximo' }
    $prox.IsEnabled  = $true   # passo 4 recalcula em Update-Passo4Nav

    switch ($N) {
        2 { Update-DetalheLocal }
        3 {
            if (-not $Global:FaseLocalPayload) { Invoke-ProbeRedeLocal }
            Update-PainelFaseLocal
        }
        4 {
            $sel = $w.FindName('cboLocal').SelectedItem
            $w.FindName('txtDiagLocal').Text = if ($sel) { 'Local: ' + $sel.Rotulo } else { 'Volte e selecione o local.' }
            Update-EstadoVpn
        }
        5 { Update-SeletorMedicoes }
        6 { Update-DecisaoRecalculada; Update-Passo6Recomendacao }
        7 { Update-ResumoFim }
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
            $p = $Global:FaseLocalPayload
            # todos os 3 meios marcados "nao aplicavel" -> nada a testar, vai ao resultado
            $todosNA = $Global:MeiosNaoAplicaveis.ContainsKey('lan') -and
                       $Global:MeiosNaoAplicaveis.ContainsKey('wifi_local') -and
                       $Global:MeiosNaoAplicaveis.ContainsKey('celular')
            if ($todosNA -and -not @($Global:Medicoes | Where-Object { -not $_.nao_aplicavel }).Count) {
                Write-Log 'Todos os meios marcados como nao aplicaveis - o local sera registrado como inviavel.' -Nivel Aviso
                Set-DiagnosticoVpnImpossivel -Motivo 'Nenhum meio de conexao se aplica a este local.'
                Show-WizardPasso 5
                return
            }
            if (-not $p -or $null -eq $p.Internet) {
                Write-Log 'Rode a checagem da internet do local (ou marque os meios como nao aplicaveis) antes de avancar.' -Nivel Aviso
                return
            }
            if ($Global:FaseLocalTipo -eq 'celular' -and
                -not ([string] $w.FindName('cboOperadoraCel').Text).Trim()) {
                Write-Log 'Informe a operadora do celular usado no roteamento.' -Nivel Aviso
                return
            }
            Show-WizardPasso 4
        }
        4 {
            if ([bool] $w.FindName('chkVpnImpossivel').IsChecked) {
                $motivo = ([string] $w.FindName('txtVpnMotivo').Text).Trim()
                if (-not $motivo) {
                    Write-Log 'Descreva por que nao foi possivel conectar a VPN da JE.' -Nivel Aviso
                    return
                }
                if (-not $Global:DiagPayload) { Set-DiagnosticoVpnImpossivel -Motivo $motivo }
                Add-MedicaoAtual
                Show-WizardPasso 5
                return
            }
            if (-not $Global:DiagPayload) {
                Write-Log 'Rode o diagnostico antes de avancar.' -Nivel Aviso
                return
            }
            Add-MedicaoAtual
            Show-WizardPasso 5
        }
        5 {
            Save-AjustesPasso5   # guarda a medicao aberta antes de checar
            $falta = Get-JustificativasFaltando -MetricasApenas
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 6
        }
        6 {
            $falta = Get-JustificativasFaltando
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            if (-not (Test-RecomendacaoValida)) { return }
            Show-WizardPasso 7
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
            $falta += 'Decisao final'
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

    # Trocar de Local / voltar ao passo 2 invalida a checagem da rede local:
    # ao reentrar no passo 3 uma nova checagem e feita do zero.
    if ($Global:FaseLocalPayload) {
        $Global:FaseLocalPayload = $null
        $Global:FaseLocalTipo    = ''
        $ck = $w.FindName('chkTetheringCelular'); if ($ck) { $ck.IsChecked = $false }
        $op = $w.FindName('cboOperadora');        if ($op) { $op.Text = '' }
        foreach ($n in 'rbUsarLan', 'rbUsarWifi', 'rbUsarCelular') {
            $c = $w.FindName($n); if ($c) { $c.IsChecked = $false }
        }
    }
    if (-not $sel) {
        $card.Visibility = 'Collapsed'
        if ($Global:WizardStep -eq 2) {
            $w.FindName('btnWizProximo').Visibility   = 'Visible'
            $w.FindName('btnRefazerTeste').Visibility = 'Collapsed'
        }
        return
    }

    # trocou de Local -> as medicoes acumuladas eram do local anterior
    $idSel = [string] $sel.Dados.id
    if ($idSel -and $idSel -ne $Global:LocalMedicoesId) {
        if (@($Global:Medicoes).Count) { Write-Log 'Local trocado - medicoes anteriores descartadas.' -Nivel Aviso }
        Reset-Medicoes
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
    $Global:TarefaRedeState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer; AoConcluir = $AoConcluir; Concluido = $false }

    $timer.Add_Tick({
      # Blindagem total: nada aqui pode escapar para o loop do ShowDialog
      # (senao a janela fecha com "excecao ao chamar ShowDialog").
      try {
        $st = $Global:TarefaRedeState
        # Concluido: se um tick ja enfileirado disparar de novo (o processamento
        # abaixo demora mais que o intervalo do timer), ele nao pode reprocessar
        # o mesmo slot -> senao dava EndInvoke/Dispose em dobro ("o fluxo nao era
        # legivel").
        if ($null -eq $st -or $st.Concluido -or -not $st.Handle.IsCompleted) { return }
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

# Trava os botoes do passo 3 e mostra o anel enquanto a fase local roda.
function Set-FaseLocalOcupado {
    param([bool] $Ocupado)
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $ring = $w.FindName('ringLocal')
    if ($ring) {
        $ring.IsActive   = $Ocupado
        $ring.Visibility = if ($Ocupado) { 'Visible' } else { 'Collapsed' }
    }
    foreach ($n in 'btnRodarFaseLocal', 'btnRelerPlacas',
        'btnWizProximo', 'btnWizVoltar', 'rbUsarLan', 'rbUsarWifi') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
}

# Escolha da placa (radio nos cartoes) -> revalida o passo 3.
function Set-FaseLocalTipo {
    param([string] $Tipo)
    $Global:FaseLocalTipo = $Tipo
    $w = $Global:JanelaPrincipal
    if ($w) {
        # o "meio celular" e a antiga marca de tethering: mantem o estado legado
        # coerente para todo o codigo a jusante (JSON, relatorio...).
        $ck = $w.FindName('chkTetheringCelular')
        if ($ck) { $ck.IsChecked = ($Tipo -eq 'celular') }
        if ($Tipo -eq 'celular') {
            $w.FindName('cboOperadora').Text = ([string] $w.FindName('cboOperadoraCel').Text).Trim()
        }
    }
    Update-PainelFaseLocal
}

# chkNaLan/Wifi/Celular + o campo de motivo: marca/desmarca meios "nao aplicaveis".
function Update-NaoAplicavelMeio {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $map = @{ chkNaLan = 'lan'; chkNaWifi = 'wifi_local'; chkNaCelular = 'celular' }
    $motivo = ([string] $w.FindName('txtMotivoNaMeio').Text).Trim()
    $algumMarcado = $false
    foreach ($ctl in $map.Keys) {
        $meio = $map[$ctl]
        $marcado = [bool] $w.FindName($ctl).IsChecked
        if ($marcado) {
            $algumMarcado = $true
            if ($motivo) { Set-MeioNaoAplicavel -Meio $meio -Motivo $motivo }
        } elseif ($Global:MeiosNaoAplicaveis.ContainsKey($meio)) {
            $Global:MeiosNaoAplicaveis.Remove($meio)
            $Global:Medicoes = @($Global:Medicoes | Where-Object { -not ($_.meio -eq $meio -and $_.nao_aplicavel) })
        }
    }
    $vis = if ($algumMarcado) { 'Visible' } else { 'Collapsed' }
    $w.FindName('txtMotivoNaMeio').Visibility = $vis
    $w.FindName('txtMotivoNaDica').Visibility = $vis
    if (-not $algumMarcado) { $w.FindName('txtMotivoNaMeio').Text = '' }
    Update-PainelFaseLocal
}

# Preenche o cartao da placa de rede + regras de habilitacao do passo 3.
# $Global:FaseLocalPayload pode estar so com as placas (probe, Internet=$null)
# ou completo (apos "Rodar checagem local", com Internet).
function Update-PainelFaseLocal {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $card = $w.FindName('cardFaseLocal')
    $p = $Global:FaseLocalPayload

    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $cinza    = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
    $cinza.Freeze()

    $cardWifi = $w.FindName('cardWifiBandeja')

    if (-not $p) {
        if ($card) { $card.Visibility = 'Collapsed' }
        $w.FindName('cardInternetLocal').Visibility = 'Collapsed'
        if ($cardWifi) { $cardWifi.Visibility = 'Collapsed' }
        $w.FindName('txtLocDica').Visibility = 'Collapsed'
        $w.FindName('txtLocEscolha').Text = 'Verificando as placas de rede deste computador...'
        $w.FindName('btnRodarFaseLocal').IsEnabled = $false
        $w.FindName('chkTetheringCelular').IsEnabled = $false
        return
    }
    $w.FindName('txtLocEscolha').Text = 'Escolha o meio de conexao a testar nesta rodada. Voce pode testar mais de um meio no mesmo local; marque os que nao se aplicam.'

    $lan = $p.Lan; $wf = $p.Wireless; $it = $p.Internet
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
    # sem Wi-Fi associado -> nao mostra IP/gateway/mascara/MAC/origem (evita dado velho)
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

    # card do speedtest: as linhas ja foram transmitidas ao vivo pelo runspace;
    # aqui so garantimos o resultado final (ou o erro) a partir do payload.
    $ci = $w.FindName('cardInternetLocal')
    if ($it) {
        $ci.Visibility = 'Visible'
        $preenche = { param($n) if ($it.PSObject.Properties[$n]) { $it.($n) } }
        if ($it.speedtest_ok) {
            Update-SpeedtestPainel -It $it
        } else {
            $w.FindName('painelSpeedResultado').Visibility = 'Collapsed'
            $te = $w.FindName('txtSpeedErro')
            $te.Text = [string] (& $preenche 'speedtest_erro')
            $te.Visibility = if ($te.Text) { 'Visible' } else { 'Collapsed' }
        }
    } else {
        $ci.Visibility = 'Collapsed'
    }

    # cartao "celular": conexao Wi-Fi (o roteamento usa a mesma placa)
    $tcel = $w.FindName('txtLocCel')
    if ($tcel) {
        $tcel.Text = if ($wifiUp) { 'Conectado a "{0}" ({1}%)' -f $wf.ssid, $wf.sinal_pct }
                     elseif ($wf.presente) { 'Placa Wi-Fi ativa, nao conectada. Conecte a rede do celular.' }
                     else { 'Sem placa Wi-Fi neste computador.' }
        $tcel.Foreground = if ($wifiUp) { $verde } else { $cinza }
    }

    # --- badges de estado dos 3 meios (a partir das medicoes) -------------
    $estadoMeio = {
        param($meio)
        if ($Global:MeiosNaoAplicaveis.ContainsKey($meio)) { return @{ txt = 'NAO APLICAVEL'; cor = $cinza } }
        $m = @($Global:Medicoes | Where-Object { $_.meio -eq $meio -and -not $_.nao_aplicavel } | Select-Object -Last 1)
        if ($m) {
            return @{ txt = 'TESTADO: ' + (Get-PalavraVeredito $m.veredito).ToUpper(); cor = (Get-PincelVeredito $m.veredito) }
        }
        @{ txt = 'NAO TESTADO'; cor = $cinza }
    }
    foreach ($par in @(@('badgeLan', 'lan'), @('badgeWifi', 'wifi_local'), @('badgeCelular', 'celular'))) {
        $b = $w.FindName($par[0])
        if ($b) { $e = & $estadoMeio $par[1]; $b.Text = $e.txt; $b.Foreground = $e.cor }
    }
    # sincroniza os checkboxes "nao aplicavel" com o estado
    foreach ($par in @(@('chkNaLan', 'lan'), @('chkNaWifi', 'wifi_local'), @('chkNaCelular', 'celular'))) {
        $c = $w.FindName($par[0])
        if ($c) { $c.IsChecked = $Global:MeiosNaoAplicaveis.ContainsKey($par[1]) }
    }

    # --- escolha do meio (radio) + regras de habilitacao -----------------
    $tipo = [string] $Global:FaseLocalTipo
    $rbL = $w.FindName('rbUsarLan'); $rbW = $w.FindName('rbUsarWifi'); $rbC = $w.FindName('rbUsarCelular')
    $naLan = $Global:MeiosNaoAplicaveis.ContainsKey('lan')
    $naWf  = $Global:MeiosNaoAplicaveis.ContainsKey('wifi_local')
    $naCel = $Global:MeiosNaoAplicaveis.ContainsKey('celular')

    if ($rbL) { $rbL.IsEnabled = [bool] $lan.conectado -and -not $naLan }
    if ($rbW) { $rbW.IsEnabled = [bool] $wf.presente   -and -not $naWf  }
    if ($rbC) { $rbC.IsEnabled = [bool] $wf.presente   -and -not $naCel }

    if ($tipo -eq 'lan'     -and $rbL -and -not $rbL.IsEnabled) { $tipo = ''; $rbL.IsChecked = $false }
    if ($tipo -eq 'wifi'    -and $rbW -and -not $rbW.IsEnabled) { $tipo = ''; $rbW.IsChecked = $false }
    if ($tipo -eq 'celular' -and $rbC -and -not $rbC.IsEnabled) { $tipo = ''; $rbC.IsChecked = $false }
    $Global:FaseLocalTipo = $tipo

    # realce + esmaecimento do cartao (borda accent no escolhido; opaco no NA)
    $accent = $w.TryFindResource('Dicon.Accent')
    $hair   = $w.TryFindResource('Dicon.Hair')
    foreach ($par in @(@('cardLan', 'lan', $naLan), @('cardWifiPlaca', 'wifi', $naWf), @('cardCelular', 'celular', $naCel))) {
        $cd = $w.FindName($par[0])
        if (-not $cd) { continue }
        $sel = ($tipo -eq $par[1])
        $cd.BorderBrush     = if ($sel) { $accent } else { $hair }
        $cd.BorderThickness = [Windows.Thickness]::new($(if ($sel) { 2 } else { 1 }))
        $cd.Opacity         = if ($par[2]) { 0.5 } else { 1.0 }
    }

    # card informativo "conecte pelo Windows": so aparece se ha placa Wi-Fi
    if ($cardWifi) {
        $cardWifi.Visibility = if ($wf.presente) { 'Visible' } else { 'Collapsed' }
    }

    # botao "Rodar checagem local": meio escolhido E aquela via conectada
    $operCel  = ([string] $w.FindName('cboOperadoraCel').Text).Trim()
    $prontoLan  = ($tipo -eq 'lan')     -and $lanUp
    $prontoWifi = ($tipo -eq 'wifi')    -and $wifiUp
    $prontoCel  = ($tipo -eq 'celular') -and $wifiUp -and $operCel
    $w.FindName('btnRodarFaseLocal').IsEnabled = $prontoLan -or $prontoWifi -or $prontoCel

    $dica = $w.FindName('txtLocDica')
    $msg =
        if ($prontoLan -or $prontoWifi -or $prontoCel) { '' }
        elseif (-not $tipo) { 'Escolha um meio de conexao nos cartoes acima (ou marque os que nao se aplicam a este local).' }
        elseif ($tipo -eq 'wifi'    -and -not $wifiUp) { 'Conecte-se a rede Wi-Fi do local no card abaixo para liberar a checagem.' }
        elseif ($tipo -eq 'celular' -and -not $wifiUp) { 'Conecte-se a rede roteada do celular no card abaixo para liberar a checagem.' }
        elseif ($tipo -eq 'celular' -and -not $operCel) { 'Informe a operadora do celular no cartao do meio Celular.' }
        elseif ($tipo -eq 'lan'     -and -not $lanUp)  { 'A rede cabeada nao esta conectada. Ligue o cabo ou escolha outro meio.' }
        else { '' }
    $dica.Text = $msg
    $dica.Visibility = if ($msg) { 'Visible' } else { 'Collapsed' }

    $card.Visibility = 'Visible'
}

# Probe rapido ao ENTRAR no passo 3: so inventaria as placas (sem internet).
# Botao de recarregar (canto da tela do passo 3): reinventaria as placas -
# pega cabo plugado/desplugado e mudanca de Wi-Fi sem sair do passo.
function Invoke-RelerPlacas {
    if ($Global:TarefaRedeState) {
        Write-Log 'Aguarde a checagem em andamento terminar.' -Nivel Aviso
        return
    }
    $p = $Global:FaseLocalPayload
    if ($p -and $p.PSObject.Properties['Internet'] -and $p.Internet) {
        Write-Log 'Relendo as placas - o teste de velocidade anterior sera descartado; rode a checagem de novo.' -Nivel Aviso
    } else {
        Write-Log 'Relendo o status das placas de rede...' -Nivel Info
    }
    Invoke-ProbeRedeLocal
}

function Invoke-ProbeRedeLocal {
    if ($Global:FaseLocalSimulada) {
        $s = $Global:FaseLocalSimulada
        $Global:FaseLocalPayload = [pscustomobject]@{ Host = $s.Host; Lan = $s.Lan; Wireless = $s.Wireless; Internet = $null; Quando = $s.Quando }
        Update-PainelFaseLocal
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
    Update-PainelFaseLocal
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

# Botao "Rodar checagem local": teste de velocidade Ookla (speedtest.exe).
function Invoke-RodarFaseLocal {
    $p = $Global:FaseLocalPayload
    $tipo = [string] $Global:FaseLocalTipo
    $ok = ($tipo -eq 'lan'     -and $p -and [bool] $p.Lan.conectado) -or `
          ($tipo -eq 'wifi'    -and $p -and [bool] $p.Wireless.conectado) -or `
          ($tipo -eq 'celular' -and $p -and [bool] $p.Wireless.conectado)
    if (-not $ok) {
        Write-Log 'Escolha o meio (LAN, Wi-Fi do local ou celular) e conecte-o antes de rodar a checagem.' -Nivel Aviso
        return
    }
    Write-Log ("Checagem local pelo meio: {0}" -f (Get-RotuloMeio (Get-MeioDoPasso3).meio (Get-MeioDoPasso3).operadora)) -Nivel Info
    Reset-Velocimetro
    $w = $Global:JanelaPrincipal
    if ($w) {
        $w.FindName('cardInternetLocal').Visibility = 'Visible'
        $w.FindName('txtVeloFase').Text = 'iniciando...'
    }

    if ($Global:FaseLocalSimulada) { Complete-FaseLocal $Global:FaseLocalSimulada $null; return }
    Set-FaseLocalOcupado $true
    Write-Log 'Rodando o Speedtest (Ookla), sem a VPN do TRE...' -Nivel Destaque
    Start-TarefaRede -Script 'Invoke-FaseLocal' -AoConcluir { param($res, $erro) Complete-FaseLocal $res $erro }
}

function Complete-FaseLocal {
    param($Payload, $Erro)
    Set-FaseLocalOcupado $false
    if ($Erro) { Write-Log "Checagem da rede local falhou: $Erro" -Nivel Erro; return }
    if ($Payload -and $Global:FaseLocalTipo) {
        $Payload | Add-Member -NotePropertyName TipoUsado -NotePropertyValue ([string] $Global:FaseLocalTipo) -Force
    }
    $Global:FaseLocalPayload = $Payload
    Update-PainelFaseLocal

    $it = if ($Payload) { $Payload.Internet } else { $null }
    if ($it -and $it.speedtest_ok) {
        Write-Log 'Rede local checada. Conecte a VPN do TRE e clique em Proximo.' -Nivel Ok
    } elseif ($it -and $it.speedtest_erro) {
        Write-Log ("Speedtest nao concluiu: {0}" -f $it.speedtest_erro) -Nivel Erro
        Write-Log 'Voce ainda pode avancar - a falha vai no relatorio.' -Nivel Aviso
    } else {
        Write-Log 'Checagem da rede local sem resultado de velocidade.' -Nivel Aviso
    }
}

# "Testei pelo roteamento do celular" -> libera/limpa o campo Operadora.
function Update-TetheringCelular {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $on = [bool] $w.FindName('chkTetheringCelular').IsChecked
    $cbo = $w.FindName('cboOperadora')
    $cbo.IsEnabled = $on
    if (-not $on) { $cbo.Text = '' }
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

# Zera o passo 3 (rede local) ao abrir o assistente limpo / pelo guia.
function Reset-PainelFaseLocal {
    $Global:FaseLocalPayload = $null
    $Global:FaseLocalTipo    = ''
    Reset-Velocimetro
    $w = $Global:JanelaPrincipal
    if ($w) {
        $w.FindName('chkTetheringCelular').IsChecked = $false
        $w.FindName('cboOperadora').Text       = ''
        $w.FindName('cboOperadora').IsEnabled  = $false
        $w.FindName('cboOperadoraCel').Text    = ''
        foreach ($n in 'rbUsarLan', 'rbUsarWifi', 'rbUsarCelular', 'chkNaLan', 'chkNaWifi', 'chkNaCelular') {
            $c = $w.FindName($n); if ($c) { $c.IsChecked = $false }
        }
        $w.FindName('txtMotivoNaMeio').Text = ''
        $w.FindName('txtMotivoNaMeio').Visibility = 'Collapsed'
        $w.FindName('txtMotivoNaDica').Visibility = 'Collapsed'
    }
    Update-PainelFaseLocal
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
            -Tethering ([bool] $w.FindName('chkTetheringCelular').IsChecked) `
            -Operadora (([string] $w.FindName('cboOperadora').Text).Trim()) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim()) `
            -Medicoes $Global:Medicoes -ConexaoRecomendada $rec `
            -MotivoRecomendacao ([string] $Global:MotivoRecomendacao)
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

    try {
        $arq = Save-ConfigAmbiente -Servidor $srv -Porta $porta -Duracao $dur
        $msg.Foreground = [Windows.Media.Brushes]::LightGreen
        $msg.Text = "Servidor iperf3 salvo neste computador ($srv`:$porta)."
        Write-Log "Ambiente iperf3 salvo pelo admin: $srv`:$porta / ${dur}s -> $arq" -Nivel Ok
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

# Passo 4: estado da VPN da JE. Sem VPN -> "Rodar diagnostico" desabilitado e
# aparecem "Abrir o FortiClient" + "Verificar novamente".
function Update-EstadoVpn {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $sel = $w.FindName('cboLocal').SelectedItem
    $vpn = Test-VpnAtiva

    $verde    = Get-PincelVeredito 'viavel'
    $vermelho = Get-PincelVeredito 'inviavel'
    $tv = $w.FindName('txtDiagVpn'); $dv = $w.FindName('dotVpn')
    if ($vpn) {
        $tv.Text = 'VPN da Justica Eleitoral conectada.'
        $tv.Foreground = $verde ; $dv.Fill = $verde
    } else {
        $tv.Text = 'VPN da Justica Eleitoral NAO detectada - conecte pelo FortiClient antes de rodar o diagnostico.'
        $tv.Foreground = $vermelho ; $dv.Fill = $vermelho
    }
    $impossivel = [bool] $w.FindName('chkVpnImpossivel').IsChecked
    $w.FindName('btnRodar').IsEnabled = [bool] $sel -and $vpn -and (-not $impossivel)
    $vis = if ($vpn -or $impossivel) { 'Collapsed' } else { 'Visible' }
    $w.FindName('btnAbrirFortiClient').Visibility = $vis
    $w.FindName('btnReverificarVpn').Visibility   = $vis
    Update-Passo4Nav
}

# "Proximo" no passo 4 so habilita se o diagnostico rodou OU se o tecnico
# marcou "nao consegui conectar a VPN" e descreveu o motivo.
function Update-Passo4Nav {
    $w = $Global:JanelaPrincipal
    if (-not $w -or $Global:WizardStep -ne 4) { return }
    $impossivelOk = [bool] $w.FindName('chkVpnImpossivel').IsChecked -and
        (-not [string]::IsNullOrWhiteSpace([string] $w.FindName('txtVpnMotivo').Text))
    $pronto = ($null -ne $Global:DiagPayload) -or $impossivelOk
    $w.FindName('btnWizProximo').IsEnabled = $pronto

    # "testar outro meio": aparece quando a bateria deste meio ja concluiu.
    $card = $w.FindName('cardOutroMeio')
    if ($card) {
        $card.Visibility = if ($pronto) { 'Visible' } else { 'Collapsed' }
        if ($pronto) {
            $feitas = @($Global:Medicoes | Where-Object { -not $_.nao_aplicavel } |
                ForEach-Object { '{0} ({1})' -f $_.rotulo, (Get-PalavraVeredito $_.veredito) })
            $na = @($Global:Medicoes | Where-Object { $_.nao_aplicavel } | ForEach-Object { '{0} (nao aplicavel)' -f $_.rotulo })
            $tudo = @($feitas + $na)
            $w.FindName('txtMedicoesFeitas').Text = if ($tudo.Count) {
                'Ja medidos neste local: ' + ($tudo -join '  ·  ') + '.  Este meio ainda nao foi registrado.'
            } else {
                'Este e o primeiro meio testado neste local.'
            }
        }
    }
}

# "Testar outro meio neste local": guarda a medicao atual e volta ao passo 3.
function Invoke-TestarOutroMeio {
    Add-MedicaoAtual
    Reset-RodadaMeio
    Show-WizardPasso 3
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
    Update-EstadoVpn   # recomputa "Rodar diagnostico" / botoes do FortiClient + Update-Passo4Nav
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

function Invoke-ReverificarVpn { Update-EstadoVpn }

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

function Invoke-ExecucaoNaJanela {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }

    $selLocal = $w.FindName('cboLocal').SelectedItem
    if (-not $selLocal) {
        Write-Log 'Selecione a Junta Especial e o local antes de rodar o diagnostico.' -Nivel Aviso
        return
    }
    if (-not (Test-VpnAtiva)) {
        Write-Log 'VPN da Justica Eleitoral nao conectada. Abra o FortiClient e conecte antes de rodar.' -Nivel Erro
        Update-EstadoVpn
        return
    }

    $w.FindName('btnRodar').IsEnabled = $false
    Set-ProgressoDiag $true
    $Global:LogEntries.Clear()
    Clear-PainelResultado
    Reset-Velocimetro -Suf 'Vpn'
    $w.FindName('cardIperfVpn').Visibility = 'Visible'
    $w.FindName('txtVeloFaseVpn').Text = 'iniciando...'

    Start-DiagnosticoAssincrono -Local $selLocal.Dados
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

    $bm = $w.FindName('boxMedicaoPasso5'); if ($bm) { $bm.Visibility = 'Collapsed' }
    $w.FindName('dgAvaliacao').ItemsSource = @()
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
    $w.FindName('cardIperfVpn').Visibility = 'Collapsed'
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
    $w = $Global:JanelaPrincipal

    Set-ProgressoDiag $false
    $w.FindName('btnRodar').IsEnabled = $true

    if ($Erro) {
        Write-Log "Diagnostico falhou: $Erro" -Nivel Erro
        return
    }
    Show-PainelResultado -Payload $Payload
    if ($Payload.PSObject.Properties['Iperf'] -and $Payload.Iperf) { Update-IperfPainel -Iperf $Payload.Iperf }
    Update-Passo4Nav
    # nao avanca sozinho: o tecnico confere o log e clica em "Proximo".
    Write-Log 'Diagnostico concluido. Revise e clique em "Proximo".' -Nivel Ok
}

function Show-PainelResultado {
    param($Payload, [hashtable] $Overrides)
    $w = $Global:JanelaPrincipal
    $Global:DiagPayload        = $Payload
    $Global:DecisaoFinalTocada = $false

    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($d in @($Payload.Decisao.Detalhes)) {
        $row = New-AvaliacaoRow -Detalhe $d
        if ($Overrides -and $Overrides.ContainsKey([string] $d.metrica)) {
            $o = $Overrides[[string] $d.metrica]
            if ($o.classe_final) { $row.ClasseFinal = [string] $o.classe_final }
            $row.Justificativa = [string] $o.justificativa
        }
        $rows.Add($row)
        $row.add_PropertyChanged({
                param($s, $e)
                if ($e.PropertyName -eq 'ClasseFinal') { Update-DecisaoRecalculada }
            })
    }
    $Global:AvaliacaoRows = $rows
    $w.FindName('dgAvaliacao').ItemsSource = $rows

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

# Passo 5: monta o seletor de medicoes (so aparece com 2+ meios testados) e
# abre a medicao correspondente ao meio que acabou de rodar.
function Update-SeletorMedicoes {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $box = $w.FindName('boxMedicaoPasso5')
    $cbo = $w.FindName('cboMedicaoPasso5')

    $pares = @()
    for ($i = 0; $i -lt @($Global:Medicoes).Count; $i++) {
        $m = $Global:Medicoes[$i]
        if ($m -and -not $m.nao_aplicavel -and $m.decisao) {
            $pares += [pscustomobject]@{ idx = $i; med = $m }
        }
    }
    $Global:MedicoesPasso5 = $pares

    if ($pares.Count -eq 0) {
        if ($box) { $box.Visibility = 'Collapsed' }
        $Global:MedicaoPasso5Idx = -1
        return
    }
    if ($pares.Count -eq 1) {
        if ($box) { $box.Visibility = 'Collapsed' }
        $Global:MedicaoPasso5Idx = $pares[0].idx
        return
    }

    if ($box) { $box.Visibility = 'Visible' }
    # abre na ultima medicao registrada, ou na que ja estava aberta
    $sel = $pares.Count - 1
    if ($Global:MedicaoPasso5Idx -ge 0) {
        for ($k = 0; $k -lt $pares.Count; $k++) {
            if ($pares[$k].idx -eq $Global:MedicaoPasso5Idx) { $sel = $k }
        }
    }
    $Global:AtualizandoMedicaoP5 = $true
    $cbo.ItemsSource   = @($pares | ForEach-Object { '{0}  -  {1}' -f $_.med.rotulo, (Get-PalavraVeredito $_.med.veredito) })
    $cbo.SelectedIndex = $sel
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
        Ambiente = $m.ambiente
        Metricas = $m.metricas
        Decisao  = $m.decisao
        Local    = $localRef
        Iperf    = $m.iperf
    }
    $ovr = @{}
    foreach ($a in @($m.avaliacoes)) { if ($a -and $a.metrica) { $ovr[[string] $a.metrica] = $a } }
    Show-PainelResultado -Payload $payload -Overrides $ovr
}

# Handler do combo de medicoes do passo 5: salva a aberta e mostra a escolhida.
function Invoke-TrocarMedicaoPasso5 {
    if ($Global:AtualizandoMedicaoP5) { return }
    $w = $Global:JanelaPrincipal
    $i = $w.FindName('cboMedicaoPasso5').SelectedIndex
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
            -Tethering ([bool] $w.FindName('chkTetheringCelular').IsChecked) `
            -Operadora (([string] $w.FindName('cboOperadora').Text).Trim()) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim()) `
            -Medicoes $Global:Medicoes -ConexaoRecomendada $rec `
            -MotivoRecomendacao ([string] $Global:MotivoRecomendacao)
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
    param($Local)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('RaizApp',         $Global:RaizApp)
    $rs.SessionStateProxy.SetVariable('LogEntries',      $Global:LogEntries)
    $rs.SessionStateProxy.SetVariable('JanelaPrincipal', $Global:JanelaPrincipal)
    $rs.SessionStateProxy.SetVariable('ArquivoLog',      $Global:ArquivoLog)

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
    $Global:DiagRunState = @{ PS = $ps; RS = $rs; Handle = $handle; Timer = $timer }

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
            Complete-Diagnostico -Payload $payload -Erro $erro
        } catch {
            Write-Log "Falha ao montar o painel apos o diagnostico: $_" -Nivel Erro
        }
      } catch {
        try { Write-Log "Diagnostico: falha inesperada ($_)." -Nivel Erro } catch { }
      }
    })
    $timer.Start()
}
