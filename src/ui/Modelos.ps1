# Tipos usados pela UI WPF.

if (-not ('Conectividade.LogEntry' -as [type])) {
    Add-Type -Language CSharp @'
namespace Conectividade
{
    public class LogEntry
    {
        public string Hora  { get; set; }
        public string Texto { get; set; }
        public string Cor   { get; set; }
    }
}
'@
}

# A faixa de severidade e o chip "Sugerida" no painel de resultados sao
# coloridos direto no XAML: a faixa via {Binding CorFinal} (hex na AvaliacaoRow)
# e o chip via Style.Triggers por texto (ChipVeredito, em Tema.xaml).

# Linha editavel do painel de resultados. INotifyPropertyChanged e obrigatorio
# para o binding two-way do DataGrid e para o recalculo ao vivo da decisao.
if (-not ('Conectividade.AvaliacaoRow' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;
namespace Conectividade
{
    public class AvaliacaoRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n)
        {
            var h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(n));
        }

        public string Metrica    { get; set; }
        public string Fase       { get; set; }   // "Rede local" (sem VPN) | "Com a VPN"
        public string Rotulo     { get; set; }
        public string ValorTexto { get; set; }
        public string Regra      { get; set; }

        private string _classeAutomatica;
        public string ClasseAutomatica
        {
            get { return _classeAutomatica; }
            set { _classeAutomatica = value; Raise("ClasseAutomatica"); Raise("CorAutomatica"); Raise("Ajustada"); }
        }

        private string _classeFinal;
        public string ClasseFinal
        {
            get { return _classeFinal; }
            set { if (_classeFinal != value) { _classeFinal = value; Raise("ClasseFinal"); Raise("Ajustada"); Raise("CorFinal"); } }
        }

        private string _justificativa = "";
        public string Justificativa
        {
            get { return _justificativa; }
            set { _justificativa = value; Raise("Justificativa"); }
        }

        public bool Ajustada { get { return _classeFinal != _classeAutomatica; } }

        public string CorAutomatica
        {
            get
            {
                if (_classeAutomatica == "viavel")   return "LightGreen";
                if (_classeAutomatica == "ressalva") return "Yellow";
                return "OrangeRed";
            }
        }

        // Cor da faixa de severidade no painel (tons escuros da identidade DICON).
        public string CorFinal
        {
            get
            {
                if (_classeFinal == "viavel")   return "#4FC177";
                if (_classeFinal == "ressalva") return "#E8B93E";
                return "#E8695C";
            }
        }
    }
}
'@
}

# Linha da tela de Administracao no formato NESTED (v0.6.67+): uma linha por
# metrica, com colunas SEM VPN / COM VPN (e Folga so na aba Wi-Fi do local).
if (-not ('Conectividade.PerfilLimiarRow' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;
namespace Conectividade
{
    public class PerfilLimiarRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string n)
        {
            var h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(n));
        }

        public string Metrica      { get; set; }
        public string Rotulo       { get; set; }
        public string Direcao      { get; set; }   // "max" | "min"
        public string Unidade      { get; set; }

        // flags de apresentacao (nao mudam em runtime)
        public bool SemVpnVisivel  { get; set; }   // a metrica existe no cenario SEM VPN?
        public bool CamposEditaveis { get; set; }  // LAN/Celular = true; Wi-Fi = false (computado)
        public bool FolgaVisivel   { get; set; }   // aba Wi-Fi do local

        private string _semIdeal;
        public string SemVpnIdeal   { get { return _semIdeal; }  set { _semIdeal = value;  Raise("SemVpnIdeal"); } }
        private string _semLimite;
        public string SemVpnLimite  { get { return _semLimite; } set { _semLimite = value; Raise("SemVpnLimite"); } }
        private string _comIdeal;
        public string ComVpnIdeal   { get { return _comIdeal; }  set { _comIdeal = value;  Raise("ComVpnIdeal"); } }
        private string _comLimite;
        public string ComVpnLimite  { get { return _comLimite; } set { _comLimite = value; Raise("ComVpnLimite"); } }
        private string _folga;
        public string Folga         { get { return _folga; }     set { _folga = value;     Raise("Folga"); } }

        private bool _semAtivo = true;
        public bool SemVpnAtivo { get { return _semAtivo; } set { _semAtivo = value; Raise("SemVpnAtivo"); } }
        private bool _comAtivo = true;
        public bool ComVpnAtivo { get { return _comAtivo; } set { _comAtivo = value; Raise("ComVpnAtivo"); } }
    }
}
'@
}

function New-LogEntry {
    param(
        [string] $Hora,
        [string] $Texto,
        [string] $Cor = 'SkyBlue'
    )
    $e = [Conectividade.LogEntry]::new()
    $e.Hora  = $Hora
    $e.Texto = $Texto
    $e.Cor   = $Cor
    return $e
}

function New-AvaliacaoRow {
    param($Detalhe, [string] $Fase = '')
    $d = $Detalhe

    $valorTxt = if ($null -eq $d.valor) { 'sem medida' }
               else { (('{0} {1}' -f $d.valor, $d.unidade)).Trim() }

    $regra = if ($d.direcao -eq 'max') {
        'viavel <= {0}{2}  /  ressalva <= {1}{2}' -f $d.limiar_viavel, $d.limiar_ressalva, $d.unidade
    } else {
        'viavel >= {0}{2}  /  ressalva >= {1}{2}' -f $d.limiar_viavel, $d.limiar_ressalva, $d.unidade
    }

    $r = [Conectividade.AvaliacaoRow]::new()
    $r.Metrica          = [string] $d.metrica
    $r.Fase             = $Fase
    $r.Rotulo           = [string] $d.rotulo
    $r.ValorTexto       = $valorTxt
    $r.Regra            = $regra
    $r.ClasseAutomatica = [string] $d.classe
    $r.ClasseFinal      = [string] $d.classe
    return $r
}

$Global:MetricasInfo = @(
    @{ metrica = 'latencia_ms';         rotulo = 'Latencia';          unidade = 'ms';   direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'jitter_ms';           rotulo = 'Jitter';            unidade = 'ms';   direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'perda_percentual';    rotulo = 'Perda de pacotes';  unidade = '%';    direcao = 'max'; cenarios = @('sem_vpn', 'com_vpn') }
    @{ metrica = 'banda_download_mbps'; rotulo = 'Download';          unidade = 'Mbps'; direcao = 'min'; cenarios = @('sem_vpn', 'com_vpn'); pct = 'banda_download_pct' }
    @{ metrica = 'banda_upload_mbps';   rotulo = 'Upload';            unidade = 'Mbps'; direcao = 'min'; cenarios = @('sem_vpn', 'com_vpn'); pct = 'banda_upload_pct' }
    @{ metrica = 'carregamento_web_s';  rotulo = 'Carregamento web';  unidade = 's';    direcao = 'max'; cenarios = @('com_vpn') }
)

function Get-RotuloMetrica {
    param([string] $Metrica)
    $i = $Global:MetricasInfo | Where-Object { $_.metrica -eq $Metrica } | Select-Object -First 1
    if ($i) { $i.rotulo } else { [string] $Metrica }
}

# Extrai "ideal" / "limite" de um bloco de metrica resolvido (shape plano).
function Get-ParIdealLimite {
    param($Bloco, [string] $Direcao)
    if ($null -eq $Bloco) { return @('', '') }
    if ($Direcao -eq 'min') {
        return @([string] $Bloco.viavel_min, [string] $Bloco.ressalva_min)
    }
    return @([string] $Bloco.viavel_ate, [string] $Bloco.ressalva_ate)
}

# Linha da tela de Administracao (formato nested). $PerfilSem / $PerfilCom sao os
# perfis PLANOS resolvidos (Get-PerfilLimiares) do meio para cada cenario.
# $Folga (opcional) = bloco perfis.wifi_local.folga -> mostra a coluna Folga e
# deixa Ideal/Limite read-only (valores computados).
function New-PerfilLimiarRow {
    param($Info, $PerfilSem, $PerfilCom, $Folga)

    $r = [Conectividade.PerfilLimiarRow]::new()
    $r.Metrica        = $Info.metrica
    $r.Rotulo         = $Info.rotulo
    $r.Unidade        = $Info.unidade
    $r.Direcao        = $Info.direcao
    $r.SemVpnVisivel  = ($Info.cenarios -contains 'sem_vpn')
    $r.FolgaVisivel   = [bool] $Folga
    $r.CamposEditaveis = (-not [bool] $Folga)

    $ps = if ($PerfilSem) { $PerfilSem.($Info.metrica) } else { $null }
    $pc = if ($PerfilCom) { $PerfilCom.($Info.metrica) } else { $null }
    $parS = Get-ParIdealLimite $ps $Info.direcao
    $parC = Get-ParIdealLimite $pc $Info.direcao
    $r.SemVpnIdeal  = if ($r.SemVpnVisivel) { $parS[0] } else { '' }
    $r.SemVpnLimite = if ($r.SemVpnVisivel) { $parS[1] } else { '' }
    $r.ComVpnIdeal  = $parC[0]
    $r.ComVpnLimite = $parC[1]
    $r.SemVpnAtivo  = if ($ps) { [bool] (& { $p = $ps.PSObject.Properties['ativo']; if ($p) { $p.Value } else { $true } }) } else { $false }
    $r.ComVpnAtivo  = if ($pc) { [bool] (& { $p = $pc.PSObject.Properties['ativo']; if ($p) { $p.Value } else { $true } }) } else { $true }

    if ($Folga) {
        $chave = if ($Info.direcao -eq 'min' -and $Info.pct) { $Info.pct } else { $Info.metrica }
        $pf = $Folga.PSObject.Properties[$chave]
        $r.Folga = if ($pf -and $null -ne $pf.Value) { [string] $pf.Value } else { '0' }
    }
    return $r
}
