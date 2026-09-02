# Verificacao e auto-elevacao UAC. Este arquivo tambem e carregado avulso pelo
# Iniciar-Diagnostico.ps1 (antes do modulo), entao nao deve depender de nada.

function Test-Administrador {
    $id        = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A maquina permite elevacao interativa? (Falso quando o UAC esta desligado ou a
# politica "negar automaticamente pedidos de elevacao" esta ligada - comum em
# notebook de campo. Nesses casos tentar elevar so gera loop de janela.)
function Test-PodeElevar {
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $p = Get-ItemProperty -Path $k -ErrorAction Stop
        if ($p.PSObject.Properties['EnableLUA'] -and [int] $p.EnableLUA -eq 0) { return $false }
        if ($p.PSObject.Properties['ConsentPromptBehaviorUser'] -and [int] $p.ConsentPromptBehaviorUser -eq 0) { return $false }
        return $true
    } catch { return $true }
}

# Relanca o script elevado. Devolve $true se o Start-Process nao falhou (a
# instancia elevada assume), $false se a maquina recusou (o chamador deve
# seguir SEM admin, nunca tentar de novo).
function Invoke-AutoElevacao {
    param(
        [string]   $Script,
        [string[]] $Argumentos = @()
    )
    $exe   = (Get-Process -Id $PID).Path
    $lista = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script)) + $Argumentos
    try {
        Start-Process -FilePath $exe -ArgumentList $lista -Verb RunAs -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
