#Requires -Version 5.1
<#
  Spike de viabilidade: MahApps.Metro num WPF hospedado em PowerShell.
  Carrega as DLLs de lib/mahapps, garante um Application, monta um MetroWindow
  minimo com o tema Dark e bombeia o Dispatcher (headless). Sai 0 se der certo.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    & $exe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$raiz = Split-Path $PSScriptRoot -Parent
$lib  = Join-Path $raiz 'lib\mahapps'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($d in 'ControlzEx.dll', 'Microsoft.Xaml.Behaviors.dll', 'MahApps.Metro.dll') {
    Add-Type -Path (Join-Path $lib $d)
    Write-Host "carregou $d"
}

if (-not [System.Windows.Application]::Current) {
    $app = New-Object System.Windows.Application
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    Write-Host "Application criado"
} else {
    Write-Host "Application ja existia"
}

$xaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Spike" Width="600" Height="400">
    <StackPanel Margin="24">
        <TextBlock Text="MahApps.Metro carregou" FontSize="20"/>
        <Button Content="Botao" Margin="0,12,0,0" Width="120" HorizontalAlignment="Left"/>
        <Controls:ToggleSwitch Header="Toggle" Margin="0,12,0,0"/>
        <Controls:NumericUpDown Value="60" Minimum="0" Maximum="500" Margin="0,12,0,0" Width="140" HorizontalAlignment="Left"/>
        <ProgressBar IsIndeterminate="True" Height="6" Margin="0,16,0,0"/>
    </StackPanel>
</Controls:MetroWindow>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
Write-Host "MetroWindow parseou: $($win.GetType().FullName)"

foreach ($u in @(
        'pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml'
        'pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml'
        'pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Blue.xaml'
    )) {
    $rd = New-Object System.Windows.ResourceDictionary
    $rd.Source = [Uri]$u
    $win.Resources.MergedDictionaries.Add($rd)
    Write-Host "merge OK: $u  ($($rd.Count) chaves)"
}

# aplica os templates: força a construção do visual sem exibir
$win.Measure([Windows.Size]::new(600, 400))
$win.Arrange([Windows.Rect]::new(0, 0, 600, 400))
$win.UpdateLayout()

$frame = [Windows.Threading.DispatcherFrame]::new()
[Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
    [Windows.Threading.DispatcherPriority]::Background, [action] { $frame.Continue = $false }) | Out-Null
[Windows.Threading.Dispatcher]::PushFrame($frame)

$btn = $null
$win.Dispatcher.Invoke([action] {
        $script:btn = $win.FindName('x') # so pra exercitar FindName; ignore
    })

Write-Host ""
Write-Host "SPIKE OK - MahApps.Metro funciona neste host."
exit 0
