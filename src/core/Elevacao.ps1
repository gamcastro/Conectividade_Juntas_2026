# Verificacao e auto-elevacao UAC. Este arquivo tambem e carregado avulso pelo
# Iniciar-Diagnostico.ps1 (antes do modulo), entao nao deve depender de nada.

function Test-Administrador {
    $id        = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-AutoElevacao {
    param(
        [string]   $Script,
        [string[]] $Argumentos = @()
    )
    $exe   = (Get-Process -Id $PID).Path
    $lista = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script)) + $Argumentos
    Start-Process -FilePath $exe -ArgumentList $lista -Verb RunAs
}
