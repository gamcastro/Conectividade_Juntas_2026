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
            set { if (_classeFinal != value) { _classeFinal = value; Raise("ClasseFinal"); Raise("Ajustada"); } }
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
    }
}
'@
}

# Linha editavel da tela de Administracao (limiares).
if (-not ('Conectividade.LimiarRow' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;
namespace Conectividade
{
    public class LimiarRow : INotifyPropertyChanged
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
        public string DirecaoTexto { get; set; }
        public string Unidade      { get; set; }

        private string _viavel;
        public string LimiarViavel   { get { return _viavel; }   set { _viavel = value;   Raise("LimiarViavel"); } }

        private string _ressalva;
        public string LimiarRessalva { get { return _ressalva; } set { _ressalva = value; Raise("LimiarRessalva"); } }
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
    param($Detalhe)
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
    $r.Rotulo           = [string] $d.rotulo
    $r.ValorTexto       = $valorTxt
    $r.Regra            = $regra
    $r.ClasseAutomatica = [string] $d.classe
    $r.ClasseFinal      = [string] $d.classe
    return $r
}

$Global:MetricasInfo = @(
    @{ metrica = 'latencia_ms';         rotulo = 'Latencia';          unidade = 'ms';   direcao = 'max' }
    @{ metrica = 'jitter_ms';           rotulo = 'Jitter';            unidade = 'ms';   direcao = 'max' }
    @{ metrica = 'perda_percentual';    rotulo = 'Perda de pacotes';  unidade = '%';    direcao = 'max' }
    @{ metrica = 'banda_download_mbps'; rotulo = 'Download';          unidade = 'Mbps'; direcao = 'min' }
    @{ metrica = 'banda_upload_mbps';   rotulo = 'Upload';            unidade = 'Mbps'; direcao = 'min' }
    @{ metrica = 'carregamento_web_s';  rotulo = 'Carregamento web';  unidade = 's';    direcao = 'max' }
)

function New-LimiarRow {
    param($Info, $Limiar)
    $sv = if ($Info.direcao -eq 'max') { 'viavel_ate' } else { 'viavel_min' }
    $sr = if ($Info.direcao -eq 'max') { 'ressalva_ate' } else { 'ressalva_min' }

    $r = [Conectividade.LimiarRow]::new()
    $r.Metrica       = $Info.metrica
    $r.Rotulo        = $Info.rotulo
    $r.Unidade       = $Info.unidade
    $r.Direcao       = $Info.direcao
    $r.DirecaoTexto  = if ($Info.direcao -eq 'max') { 'menor e melhor' } else { 'maior e melhor' }
    $r.LimiarViavel   = [string] $Limiar.$sv
    $r.LimiarRessalva = [string] $Limiar.$sr
    return $r
}
