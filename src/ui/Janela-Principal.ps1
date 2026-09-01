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
$Global:FaseLocalPayload   = $null   # {Lan;Wireless;Internet;Quando} da fase 1 (sem VPN)
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
if (-not (Get-Variable -Name WifiConectarSimulado -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:WifiConectarSimulado = $null  # testes: resultado fixo p/ Connect-RedeWireless
}
if (-not (Get-Variable -Name VpnSimulada -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:VpnSimulada = $null           # testes: $true/$false forca o estado da VPN
}

$Global:Views = @('viewLogin', 'viewHome', 'viewGuia', 'viewDiag', 'viewAdmin')

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

    # diagnostico
    $window.FindName('btnRodar').Add_Click({ Invoke-ExecucaoNaJanela })
    $window.FindName('btnAbrirFortiClient').Add_Click({ Invoke-AbrirFortiClient })
    $window.FindName('btnReverificarVpn').Add_Click({ Invoke-ReverificarVpn })
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
    $window.FindName('btnConectarWifi').Add_Click({ Invoke-ConectarWifi })
    $window.FindName('chkTetheringCelular').Add_Click({ Update-TetheringCelular })
    $window.FindName('btnExportarPdf').Add_Click({ Invoke-ExportarRelatorio })
    $window.FindName('btnTransmitirResultado').Add_Click({ Invoke-TransmitirResultado })
    $window.FindName('btnDiagVoltar').Add_Click({ Show-View 'viewHome' })
    $window.FindName('btnSalvarResultado').Add_Click({ Invoke-SalvarResultado })
    $window.FindName('cboDecisaoFinal').Add_SelectionChanged({
            if (-not $Global:AtualizandoDecisao) { $Global:DecisaoFinalTocada = $true }
            Update-VisibilidadeJustDecisao
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

    # rail de navegacao (RadioButtons) - handlers ignoram mudanca programatica
    $window.FindName('navGuia').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-GuiaBordo } })
    $window.FindName('navDiag').Add_Checked({ if (-not $Global:NavegandoPrograma) { Open-DiagnosticoLimpo } })
    $window.FindName('navAdmin').Add_Checked({ if (-not $Global:NavegandoPrograma) { Show-Admin } })
    $window.FindName('navAtualizar').Add_Checked({ if (-not $Global:NavegandoPrograma) { Invoke-AtualizarDados } })

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
    (New-JanelaPrincipal).ShowDialog() | Out-Null
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
    $map = @{ viewGuia = 'navGuia'; viewDiag = 'navDiag'; viewAdmin = 'navAdmin' }
    $Global:NavegandoPrograma = $true
    foreach ($nn in 'navGuia', 'navDiag', 'navAdmin', 'navAtualizar') {
        $rb = $w.FindName($nn)
        if ($rb) { $rb.IsChecked = ($map[$Nome] -eq $nn) }
    }
    $Global:NavegandoPrograma = $false
}

# ------------------------------------------------------------- LOGIN

function Initialize-Login {
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $tec = @(Get-Tecnicos)
    $w.FindName('cboTecnico').ItemsSource = $tec
    $w.FindName('lblPin').Visibility = 'Collapsed'
    $w.FindName('txtPin').Visibility = 'Collapsed'
    $w.FindName('txtLoginMsg').Text = if ($tec.Count) {
        ''
    } else {
        "Nenhum tecnico no cache. Clique em 'Baixar lista' (precisa de internet)."
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
    $w = $Global:JanelaPrincipal
    $w.FindName('txtLoginMsg').Text = 'Baixando dados...'
    try {
        $r = Sync-TudoOnline
        Initialize-Login
        $w.FindName('txtLoginMsg').Text = ("Baixado: {0} tecnicos, {1} juntas, {2} roteiros." -f $r.tecnicos, $r.juntas, $r.roteiros)
    } catch {
        $w.FindName('txtLoginMsg').Text = "Falha ao baixar: $_"
    }
}

function Enter-Sessao {
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

    $sessao = Set-Sessao -TecnicoNome $nome -Papel $papel
    Enter-Home -Sessao $sessao
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

    $rot = $null
    try { $rot = Get-RoteiroDoTecnico -Nome $Sessao.tecnico_nome } catch { Write-Log "Roteiro nao carregado: $_" -Nivel Aviso }
    $Global:RoteiroAtual = $rot
    Update-SeletorJuntas

    $w.FindName('txtHomeRoteiro').Text = if ($rot) {
        '{0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias' -f $rot.rotulo, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias
    } else {
        'Roteiro nao encontrado no cache. Use "Atualizar dados".'
    }

    if ($rot) {
        $prog = Get-ProgressoRoteiro -Roteiro $rot -TecnicoNome $Sessao.tecnico_nome
        $w.FindName('txtTileDias').Text   = [string] $rot.dias
        $w.FindName('txtTileLocais').Text = [string] $prog.Total
        $w.FindName('txtTileKm').Text     = [string] $rot.total_km

        $w.FindName('txtProgressoRoteiro').Text = '{0} de {1} locais testados' -f $prog.Testados, $prog.Total
        $pb = $w.FindName('prgProgressoRoteiro')
        $pb.Maximum = [math]::Max($prog.Total, 1)
        $pb.Value   = $prog.Testados
        $w.FindName('painelProgressoRoteiro').Visibility = 'Visible'
    } else {
        foreach ($t in 'txtTileDias', 'txtTileLocais', 'txtTileKm') { $w.FindName($t).Text = '--' }
        $w.FindName('painelProgressoRoteiro').Visibility = 'Collapsed'
    }

    Update-AvisoPendentes
    $w.FindName('painelLogHome').Visibility = if ($Global:LogHome.Count) { 'Visible' } else { 'Collapsed' }
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
        'btnReenviarPendentes', 'btnTrocarUsuario', 'navGuia', 'navDiag', 'navAdmin', 'navAtualizar') {
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
        $st = $Global:HomeTrabalhoState
        if ($null -eq $st -or -not $st.Handle.IsCompleted) { return }
        $st.Timer.Stop()
        $Global:HomeTrabalhoState = $null

        $res = $null; $erro = $null
        try {
            $r = $st.PS.EndInvoke($st.Handle) | Select-Object -First 1
            $res = $r.Resultado; $erro = $r.Erro
        } catch { $erro = "$_" } finally { $st.PS.Dispose(); $st.RS.Dispose() }

        if ($erro) { Write-Log "Falha: $erro" -Nivel Erro }
        try { & $st.AoConcluir $res $erro } catch { Write-Log "Pos-processamento falhou: $_" -Nivel Erro }
        Set-HomeOcupado $false
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
        if ($Global:SessaoAtual) { Enter-Home -Sessao $Global:SessaoAtual }
    }
}

# ------------------------------------------------------------- GUIA DE BORDO

function Show-GuiaBordo {
    $w = $Global:JanelaPrincipal
    $rot = $Global:RoteiroAtual

    if (-not $rot) {
        $w.FindName('txtGuiaTitulo').Text = 'Roteiro nao disponivel'
        $w.FindName('txtGuiaSub').Text    = 'Use "Atualizar dados" com internet.'
        $w.FindName('lstTrechos').ItemsSource     = @()
        $w.FindName('lstGuiaJuntas').ItemsSource  = @()
        $w.FindName('txtGuiaSemJunta').Text       = ''
        Show-View 'viewGuia'
        return
    }

    $w.FindName('txtGuiaTitulo').Text = $rot.rotulo
    $w.FindName('txtGuiaSub').Text = ('Tecnico: {0}    |    Etapa {1}    |    {2} a {3}    |    {4} dias    |    {5} km ({6})' -f `
            $rot.tecnico, $rot.etapa, $rot.ida, $rot.retorno, $rot.dias, $rot.total_km, $rot.total_tempo)
    $w.FindName('lstTrechos').ItemsSource    = @($rot.trechos)

    # marca cada local com o status do ultimo diagnostico feito pelo tecnico
    $feitos = Get-DiagnosticosRealizados -TecnicoNome $Global:SessaoAtual.tecnico_nome
    $cinza  = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#7D8698'))
    $cinza.Freeze()
    foreach ($grupo in @($rot.juntas)) {
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
            }
            $loc | Add-Member -NotePropertyName TesteStatus -NotePropertyValue $txt -Force
            $loc | Add-Member -NotePropertyName TesteCor    -NotePropertyValue $cor -Force
            $loc | Add-Member -NotePropertyName BotaoRodar  -NotePropertyValue $bot -Force
        }
    }
    $w.FindName('lstGuiaJuntas').ItemsSource = @($rot.juntas)

    $sem = @($rot.cidades_sem_junta)
    $w.FindName('txtGuiaSemJunta').Text = if ($sem.Count) {
        'Cidades de passagem sem Junta: ' + ($sem -join ', ')
    } else { '' }

    Show-View 'viewGuia'
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
        6 { Update-DecisaoRecalculada }
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
            if (-not $p -or $null -eq $p.Internet) {
                Write-Log 'Rode a checagem da internet do local antes de avancar.' -Nivel Aviso
                return
            }
            if ([bool] $w.FindName('chkTetheringCelular').IsChecked -and
                -not ([string] $w.FindName('cboOperadora').Text).Trim()) {
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
                Show-WizardPasso 5
                return
            }
            if (-not $Global:DiagPayload) {
                Write-Log 'Rode o diagnostico antes de avancar.' -Nivel Aviso
                return
            }
            Show-WizardPasso 5
        }
        5 {
            $falta = Get-JustificativasFaltando -MetricasApenas
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 6
        }
        6 {
            $falta = Get-JustificativasFaltando
            if ($falta.Count) { Write-Log ('Justificativa obrigatoria em: {0}' -f ($falta -join ', ')) -Nivel Erro; return }
            Show-WizardPasso 7
        }
    }
}

# Lista de itens sem justificativa obrigatoria (metricas ajustadas + decisao).
function Get-JustificativasFaltando {
    param([switch] $MetricasApenas)
    $w = $Global:JanelaPrincipal
    $falta = @()
    foreach ($r in @($Global:AvaliacaoRows)) {
        if (($r.ClasseFinal -ne $r.ClasseAutomatica) -and [string]::IsNullOrWhiteSpace($r.Justificativa)) {
            $falta += $r.Rotulo
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
        $ck = $w.FindName('chkTetheringCelular'); if ($ck) { $ck.IsChecked = $false }
        $op = $w.FindName('cboOperadora');        if ($op) { $op.Text = '' }
    }
    if (-not $sel) {
        $card.Visibility = 'Collapsed'
        if ($Global:WizardStep -eq 2) {
            $w.FindName('btnWizProximo').Visibility   = 'Visible'
            $w.FindName('btnRefazerTeste').Visibility = 'Collapsed'
        }
        return
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
        } catch { $erro = "$_" } finally { $st.PS.Dispose(); $st.RS.Dispose() }

        try { & $st.AoConcluir $res $erro } catch { Write-Log "Pos-processamento de rede falhou: $_" -Nivel Erro }
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
    foreach ($n in 'btnRodarFaseLocal', 'btnConectarWifi', 'btnWizProximo', 'btnWizVoltar') {
        $c = $w.FindName($n); if ($c) { $c.IsEnabled = -not $Ocupado }
    }
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

    # "Conectar a uma rede Wi-Fi" so aparece se o computador tem placa wireless.
    $temWifi = if ($p) { [bool] $p.Wireless.presente } else { Test-TemPlacaWireless }
    $cardWifi = $w.FindName('cardConectarWifi')
    if ($cardWifi) { $cardWifi.Visibility = if ($temWifi) { 'Visible' } else { 'Collapsed' } }

    if (-not $p) {
        if ($card) { $card.Visibility = 'Collapsed' }
        $w.FindName('cardInternetLocal').Visibility = 'Collapsed'
        $w.FindName('txtLocDica').Visibility = 'Collapsed'
        $w.FindName('btnRodarFaseLocal').IsEnabled = $false
        $w.FindName('chkTetheringCelular').IsEnabled = $false
        return
    }

    $lan = $p.Lan; $wf = $p.Wireless; $it = $p.Internet
    $hostNb = if ($p.PSObject.Properties['Host']) { [string] $p.Host } else { '' }
    Set-LinhaDetalhe $w.FindName('txtLocHost') 'Computador' $hostNb

    $lanUp = [bool] $lan.conectado
    $tl = $w.FindName('txtLocLan'); $dl = $w.FindName('dotLan')
    if ($lanUp) {
        $tl.Text = 'Cabo de rede (LAN): conectado' + $(if ($lan.nome) { " - $($lan.nome)" } else { '' })
        $tl.Foreground = $verde ; $dl.Fill = $verde
    } elseif ($lan.presente) {
        $tl.Text = 'Cabo de rede (LAN): sem conexao (cabo fora / sem IP)'
        $tl.Foreground = $vermelho ; $dl.Fill = $vermelho
    } else {
        $tl.Text = 'Cabo de rede (LAN): nenhuma placa cabeada neste computador'
        $tl.Foreground = $cinza ; $dl.Fill = $cinza
    }

    Set-LinhaDetalhe $w.FindName('txtLocIp')      'IP na rede local' ([string] $lan.ipv4)
    Set-LinhaDetalhe $w.FindName('txtLocGateway') 'Gateway'          ([string] $lan.gateway)
    Set-LinhaDetalhe $w.FindName('txtLocMascara') 'Mascara'          ([string] $lan.mascara)
    Set-LinhaDetalhe $w.FindName('txtLocDns')     'DNS'              ((@($lan.dns)) -join ', ')
    Set-LinhaDetalhe $w.FindName('txtLocMac')     'MAC'              ([string] $lan.mac)
    Set-LinhaDetalhe $w.FindName('txtLocVel')     'Enlace'          $(if ($lan.velocidade_mbps) { "$($lan.velocidade_mbps) Mbps" } else { '' })

    $wifiUp = [bool] $wf.conectado
    $tw = $w.FindName('txtLocWifi'); $dw = $w.FindName('dotWifi')
    if ($wifiUp) {
        $tw.Text = 'Wi-Fi: conectado a "{0}" ({1}%)' -f $wf.ssid, $wf.sinal_pct
        $tw.Foreground = $verde ; $dw.Fill = $verde
    } elseif ($wf.presente) {
        $n = (@($wf.redes_disponiveis)).Count
        $tw.Text = 'Wi-Fi: placa presente, nao conectada' + $(if ($n) { " - $n rede(s) por perto" } else { '' })
        $tw.Foreground = if ($lanUp) { $cinza } else { $vermelho }
        $dw.Fill       = if ($lanUp) { $cinza } else { $vermelho }
    } else {
        $tw.Text = 'Wi-Fi: sem placa wireless neste computador'
        $tw.Foreground = $cinza ; $dw.Fill = $cinza
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

    $cbo = $w.FindName('cboWifiSsid')
    if ($cbo) {
        $atual = [string] $cbo.Text
        $cbo.ItemsSource = @($wf.redes_disponiveis)
        # nao pre-seleciona a rede em que ja estamos (a lista tambem ja a exclui);
        # so restaura o que o tecnico tinha digitado.
        if ($atual -and $atual -ne $wf.ssid) { $cbo.Text = $atual } else { $cbo.Text = '' }
    }

    # quando ja estamos num Wi-Fi, o card serve para TROCAR de rede.
    $lblWifi = $w.FindName('txtConectarWifiDica')
    if ($lblWifi) {
        $lblWifi.Text = if ($wifiUp) {
            'Ja conectado a "{0}". Use abaixo so para trocar para outra rede. A senha fica gravada no perfil de Wi-Fi do Windows.' -f $wf.ssid
        } else {
            'Use se o local nao tiver cabo. A senha fica gravada no perfil de Wi-Fi do Windows.'
        }
    }

    # --- regras de habilitacao ------------------------------------------
    $conectado = $lanUp -or $wifiUp
    $w.FindName('btnRodarFaseLocal').IsEnabled = $conectado

    # "teste pelo celular" so quando NAO ha cabo de rede E existe placa Wi-Fi
    $podeTether = (-not $lanUp) -and [bool] $wf.presente
    $chk = $w.FindName('chkTetheringCelular')
    $chk.IsEnabled = $podeTether
    if (-not $podeTether -and $chk.IsChecked) { $chk.IsChecked = $false }
    Update-TetheringCelular

    $dica = $w.FindName('txtLocDica')
    if ($conectado) {
        $dica.Visibility = 'Collapsed'
    } elseif ([bool] $wf.presente) {
        $dica.Text = 'Sem cabo de rede. Conecte-se a uma rede Wi-Fi (a do local ou a do seu celular) para liberar a checagem.'
        $dica.Visibility = 'Visible'
    } else {
        $dica.Text = 'Sem cabo de rede e sem placa Wi-Fi neste computador - nao da para rodar a checagem aqui.'
        $dica.Visibility = 'Visible'
    }

    $card.Visibility = 'Visible'
}

# Probe rapido ao ENTRAR no passo 3: so inventaria as placas (sem internet).
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
$Global:VeloTick    = 0      # throttle do velocimetro do passo 3 (speedtest)
$Global:VeloTickVpn = 0      # throttle do velocimetro do passo 4 (iperf3)
$Global:VeloTicks   = @(0, 10, 50, 100, 250, 500, 1000)

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

# Anima uma DependencyProperty ate $Para (ms) com easing suave.
function Set-PropAnimada {
    param($Alvo, $Prop, $Para, [int] $Ms = 150)
    $dur = [Windows.Duration] ([TimeSpan]::FromMilliseconds($Ms))
    $anim = if ($Para -is [Windows.Point]) {
        [Windows.Media.Animation.PointAnimation]::new([Windows.Point] $Para, $dur)
    } else {
        [Windows.Media.Animation.DoubleAnimation]::new([double] $Para, $dur)
    }
    $anim.EasingFunction = [Windows.Media.Animation.CubicEase]::new()
    $Alvo.BeginAnimation($Prop, $anim)
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
    if ($Suf -eq 'Vpn') { $Global:VeloTickVpn = 0 } else { $Global:VeloTick = 0 }
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
        $w.FindName('txtSpeedInfo').Text = ''
    }
    Set-TicksVelocimetro -Suf $Suf
}

function Set-VelocimetroValor {
    param([double] $Valor, [string] $Unidade = 'Mbps', [string] $Fase = '', [double] $Linear = 0, [string] $Suf = '')
    $w = $Global:JanelaPrincipal
    if (-not $w) { return }
    $frac = Get-FracVelo -Valor $Valor -Linear $Linear
    $ang  = -135.0 + 270.0 * $frac
    Set-PropAnimada $w.FindName('rotAgulha' + $Suf) ([Windows.Media.RotateTransform]::AngleProperty) $ang
    $pt = Get-PontoArco -Cx 140 -Cy 140 -R 110 -AngGraus $ang
    $seg = $w.FindName('segVelo' + $Suf)
    $seg.IsLargeArc = ((270.0 * $frac) -gt 180.0)
    Set-PropAnimada $seg ([Windows.Media.ArcSegment]::PointProperty) $pt
    $fmt = if ($Valor -ge 100) { '{0:0}' } elseif ($Valor -ge 10) { '{0:0.0}' } else { '{0:0.00}' }
    $w.FindName('txtVeloNum' + $Suf).Text  = ($fmt -f $Valor)
    $w.FindName('txtVeloUnid' + $Suf).Text = $Unidade
    if ($Fase) { $w.FindName('txtVeloFase' + $Suf).Text = $Fase }
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
            $w.FindName('txtSpeedInfo').Text = ('{0}   -   servidor: {1} ({2})   -   IP {3}' -f `
                    $Evento.isp, $srv.name, $srv.location, $ext)
            $w.FindName('txtVeloFase').Text = 'conectando...'
        }
        'ping' {
            Set-ProgressoSpeed (0.10 * [double] $Evento.ping.progress)
            if ($desenha) { Set-VelocimetroValor -Valor ([double] $Evento.ping.latency) -Unidade 'ms' -Fase 'Ping' -Linear 60 }
        }
        'download' {
            Set-ProgressoSpeed (0.10 + 0.50 * [double] $Evento.download.progress)
            if ($desenha) { Set-VelocimetroValor -Valor (ConvertTo-MbpsGui $Evento.download.bandwidth) -Unidade 'Mbps' -Fase 'Download' }
        }
        'upload' {
            Set-ProgressoSpeed (0.60 + 0.40 * [double] $Evento.upload.progress)
            if ($desenha) { Set-VelocimetroValor -Valor (ConvertTo-MbpsGui $Evento.upload.bandwidth) -Unidade 'Mbps' -Fase 'Upload' }
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

    $w.FindName('txtResIsp').Text = 'Provedor: ' + [string] (& $g 'isp')
    $srv = [string] (& $g 'servidor_nome')
    $loc = [string] (& $g 'servidor_local')
    $w.FindName('txtResServidor').Text = 'Servidor: ' + $srv + $(if ($loc) { " - $loc" } else { '' })
    $w.FindName('txtResIp').Text = 'IP externo: ' + [string] (& $g 'ip_externo')
    $url = [string] (& $g 'resultado_url')
    $tl = $w.FindName('txtResLink')
    $tl.Text = if ($url) { 'Resultado Ookla: ' + $url } else { '' }
    $tl.Visibility = if ($url) { 'Visible' } else { 'Collapsed' }

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
    $conectado = $p -and ([bool] $p.Lan.conectado -or [bool] $p.Wireless.conectado)
    if (-not $conectado) {
        Write-Log 'Conecte o computador a rede do local (cabo ou Wi-Fi) antes de rodar a checagem.' -Nivel Aviso
        return
    }
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
    $Global:FaseLocalPayload = $Payload
    Update-PainelFaseLocal
    Write-Log 'Rede local checada. Conecte a VPN do TRE e clique em Proximo.' -Nivel Ok
}

function Invoke-ConectarWifi {
    $w = $Global:JanelaPrincipal
    $ssid  = ([string] $w.FindName('cboWifiSsid').Text).Trim()
    $senha = $w.FindName('pwdWifiSenha').Password
    $st = $w.FindName('txtWifiStatus')
    $temWifi = if ($Global:FaseLocalPayload) { [bool] $Global:FaseLocalPayload.Wireless.presente } else { Test-TemPlacaWireless }
    if (-not $temWifi)       { $st.Text = 'Este computador nao tem placa de rede Wi-Fi.'; return }
    if (-not $ssid)          { $st.Text = 'Informe o nome (SSID) da rede Wi-Fi.'; return }
    if ($senha.Length -lt 8) { $st.Text = 'A senha do Wi-Fi precisa ter ao menos 8 caracteres.'; return }

    Set-FaseLocalOcupado $true
    $st.Text = "Conectando a '$ssid'..."
    Write-Log "Conectando ao Wi-Fi '$ssid' pela ferramenta..." -Nivel Info

    if ($Global:WifiConectarSimulado) { Complete-ConectarWifi $Global:WifiConectarSimulado $null; return }
    Start-TarefaRede -Script 'Connect-RedeWireless -Ssid $ssid -Senha $senha' `
        -Vars @{ ssid = $ssid; senha = $senha } `
        -AoConcluir { param($res, $erro) Complete-ConectarWifi $res $erro }
}

function Complete-ConectarWifi {
    param($Res, $Erro)
    $w = $Global:JanelaPrincipal
    $st = $w.FindName('txtWifiStatus')
    Set-FaseLocalOcupado $false
    if ($Erro) { $st.Text = "Falha ao conectar: $Erro"; Write-Log "Wi-Fi: $Erro" -Nivel Erro; return }
    if ($Res -and $Res.ok) {
        $st.Text = [string] $Res.mensagem
        Write-Log ("Wi-Fi conectado: {0}" -f $Res.mensagem) -Nivel Ok

        # Registra JA a conexao Wi-Fi no estado (nao espera o re-probe async):
        # a checagem local nao pode ficar travada se o inventario falhar. Parte
        # do payload anterior (LAN, redes vistas) e so vira o Wi-Fi p/ conectado.
        $ant     = $Global:FaseLocalPayload
        $lanBase = if ($ant -and $ant.PSObject.Properties['Lan']) { $ant.Lan } else { $null }
        $wfBase  = if ($ant -and $ant.PSObject.Properties['Wireless']) { $ant.Wireless } else { $null }
        $Global:FaseLocalPayload = [pscustomobject]@{
            Host     = $env:COMPUTERNAME
            Lan      = $lanBase
            Wireless = [pscustomobject]@{
                presente          = $true
                conectado         = $true
                ssid              = [string] $Res.ssid
                sinal_pct         = $Res.sinal_pct
                nome              = if ($wfBase -and $wfBase.PSObject.Properties['nome']) { $wfBase.nome } else { $null }
                redes_disponiveis = if ($wfBase -and $wfBase.PSObject.Properties['redes_disponiveis']) { $wfBase.redes_disponiveis } else { @() }
            }
            Internet = $null
            Quando   = (Get-Date).ToString('o')
            Parcial  = $true
        }
        Update-PainelFaseLocal

        # Re-inventaria as placas FORA deste tick: chamar Start-TarefaRede aqui
        # dentro (aninhado no tick de Connect-RedeWireless) deixava dois
        # DispatcherTimer polindo o mesmo slot -> EndInvoke apos Dispose
        # ("o fluxo nao era legivel"). BeginInvoke deixa o tick atual terminar.
        if ($w) {
            $w.Dispatcher.BeginInvoke(
                [Windows.Threading.DispatcherPriority]::Background,
                [action] { Invoke-ProbeRedeLocal }) | Out-Null
        } else {
            Invoke-ProbeRedeLocal
        }
    } else {
        $st.Text = if ($Res) { [string] $Res.mensagem } else { 'Nao foi possivel conectar.' }
        Write-Log ("Wi-Fi nao conectou: {0}" -f $st.Text) -Nivel Aviso
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

# Zera o passo 3 (rede local) ao abrir o assistente limpo / pelo guia.
function Reset-PainelFaseLocal {
    $Global:FaseLocalPayload = $null
    Reset-Velocimetro
    $w = $Global:JanelaPrincipal
    if ($w) {
        $w.FindName('txtWifiStatus').Text     = ''
        $w.FindName('cboWifiSsid').Text        = ''
        $w.FindName('pwdWifiSenha').Password   = ''
        $w.FindName('chkTetheringCelular').IsChecked = $false
        $w.FindName('cboOperadora').Text       = ''
        $w.FindName('cboOperadora').IsEnabled  = $false
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
}

# Preenche o passo 7 (conclusao).
function Update-ResumoFim {
    $w = $Global:JanelaPrincipal
    $p = $Global:DiagPayload
    if (-not $p) { return }
    $dec = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $w.FindName('txtFimLocal').Text = 'ZE {0} - {1} / {2} ({3})' -f `
        $p.Local.zona_eleitoral, $p.Local.municipio_termo, $p.Local.nome, $p.Local.tipo
    $ver = $w.FindName('txtFimVeredito')
    $ver.Text       = Get-PalavraVeredito $dec
    $ver.Foreground = Get-PincelVeredito $dec
    $w.FindName('btnSalvarResultado').IsEnabled     = $true
    $w.FindName('btnExportarPdf').IsEnabled         = $true
    $w.FindName('btnTransmitirResultado').IsEnabled = $Global:FeitoSalvar
    Update-ChecklistFim
}

function Invoke-TransmitirResultado {
    $w = $Global:JanelaPrincipal
    if (-not $Global:UltimoResultadoSalvo -or -not (Test-Path $Global:UltimoResultadoSalvo)) {
        Write-Log 'Salve o resultado antes de transmitir.' -Nivel Aviso
        $st = $w.FindName('txtFimStatus'); if ($st) { $st.Text = 'Salve o resultado antes de transmitir.' }
        return
    }
    $btn = $w.FindName('btnTransmitirResultado'); $btn.IsEnabled = $false
    $st  = $w.FindName('txtFimStatus'); $st.Text = 'Transmitindo...'
    try {
        $cfg = $null
        try { $cfg = Get-Config 'envio' } catch { }
        $ok = Send-Resultado -Caminho $Global:UltimoResultadoSalvo -Endpoint $cfg.endpoint_apps_script `
            -Retentativas ($cfg.retentativas) -IntervaloS ($cfg.intervalo_retentativa_s)
        if ($ok) {
            $Global:FeitoTransmitir = $true
            $st.Text = 'Resultado transmitido ao painel.'
        } else {
            $st.Text = 'Nao foi possivel transmitir agora. O resultado fica pendente e vai no proximo "Atualizar dados".'
            $btn.IsEnabled = $true
        }
    } catch {
        Write-Log "Falha ao transmitir: $_" -Nivel Erro
        $st.Text = "Falha ao transmitir: $_"
        $btn.IsEnabled = $true
    }
    Update-ChecklistFim
    Update-AvisoPendentes
}

function Invoke-ExportarRelatorio {
    $w = $Global:JanelaPrincipal
    if (-not $Global:DiagPayload -or -not $Global:AvaliacaoRows) {
        Write-Log 'Rode o diagnostico antes de exportar o relatorio.' -Nivel Aviso
        return
    }
    $btn = $w.FindName('btnExportarPdf'); $btn.IsEnabled = $false
    $st  = $w.FindName('txtFimStatus');  $st.Text = 'Gerando relatorio...'
    try {
        $avaliacoes = @()
        foreach ($r in @($Global:AvaliacaoRows)) {
            $avaliacoes += @{ metrica = $r.Metrica; classe_final = $r.ClasseFinal; justificativa = [string] $r.Justificativa }
        }
        $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
        $justDec  = [string] $w.FindName('txtJustDecisao').Text
        $p = $Global:DiagPayload
        $res = New-ResultadoJson -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome) -FaseLocal $Global:FaseLocalPayload `
            -Tethering ([bool] $w.FindName('chkTetheringCelular').IsChecked) `
            -Operadora (([string] $w.FindName('cboOperadora').Text).Trim()) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim())
        $out = Export-RelatorioPdf -Resultado $res
        $Global:FeitoExportar = $true
        $st.Text = "Relatorio salvo: $out"
        if (-not $Global:ModoTeste) { try { Start-Process -FilePath $out } catch { } }
    } catch {
        $st.Text = "Falha ao exportar: $_"
        Write-Log "Falha ao exportar relatorio: $_" -Nivel Erro
    } finally {
        $btn.IsEnabled = $true
    }
    Update-ChecklistFim
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
    $w.FindName('btnWizProximo').IsEnabled = ($null -ne $Global:DiagPayload) -or $impossivelOk
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
    param($Payload)
    $w = $Global:JanelaPrincipal
    $Global:DiagPayload        = $Payload
    $Global:DecisaoFinalTocada = $false

    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($d in @($Payload.Decisao.Detalhes)) {
        $row = New-AvaliacaoRow -Detalhe $d
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
    $decFinal = [string] $w.FindName('cboDecisaoFinal').SelectedItem
    $justDec  = [string] $w.FindName('txtJustDecisao').Text

    $w.FindName('btnSalvarResultado').IsEnabled = $false
    try {
        $p = $Global:DiagPayload
        $caminho = Save-Diagnostico -Ambiente $p.Ambiente -Metricas $p.Metricas -Decisao $p.Decisao -Local $p.Local `
            -Avaliacoes $avaliacoes `
            -ClassificacaoFinal @{ final = $decFinal; justificativa = $justDec } `
            -TecnicoNome ($Global:SessaoAtual.tecnico_nome) `
            -FaseLocal $Global:FaseLocalPayload `
            -Tethering ([bool] $w.FindName('chkTetheringCelular').IsChecked) `
            -Operadora (([string] $w.FindName('cboOperadora').Text).Trim()) `
            -VpnImpossivel ([bool] $w.FindName('chkVpnImpossivel').IsChecked) `
            -VpnMotivo (([string] $w.FindName('txtVpnMotivo').Text).Trim())
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
            $st.PS.Dispose()
            $st.RS.Dispose()
        }

        try {
            Complete-Diagnostico -Payload $payload -Erro $erro
        } catch {
            Write-Log "Falha ao montar o painel apos o diagnostico: $_" -Nivel Erro
        }
    })
    $timer.Start()
}
