# Papeis: operador (todos) e admin (so George Andre Melo Castro, com PIN).
# Hash SHA-256 do PIN em config/admin.json (fora do git):
#   { "pin_sha256": "<hex minusculo>" }
# Gerar com tools/Definir-PIN-Admin.ps1.

# Montado por codigo para nao depender do encoding do arquivo (o "e" e acentuado).
$Global:AdminNome = 'George Andr' + [char]0x00E9 + ' Melo Castro'

function Get-HashPin {
    param([string] $Pin)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Pin)
    $sha   = [Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Test-PinAdmin {
    param([string] $Pin)
    if ([string]::IsNullOrWhiteSpace($Pin)) { return $false }

    $arq = Join-Path $Global:RaizApp 'config\admin.json'
    if (-not (Test-Path $arq)) {
        Write-Log "config/admin.json ausente - perfil admin indisponivel. Use tools/Definir-PIN-Admin.ps1." -Nivel Aviso
        return $false
    }
    try {
        $cfg = Get-Content -Path $arq -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "config/admin.json invalido: $_" -Nivel Erro
        return $false
    }
    if (-not $cfg.pin_sha256) { return $false }
    return ((Get-HashPin $Pin).ToLower() -eq ([string]$cfg.pin_sha256).ToLower())
}

function Test-NomeAdmin {
    param([string] $Nome)
    return ([string]$Nome).Trim() -eq $Global:AdminNome
}

# Papel do tecnico: 'admin' so se for o nome do admin E o PIN conferir.
function Get-PapelTecnico {
    param(
        [string] $Nome,
        [string] $Pin
    )
    if ((Test-NomeAdmin $Nome) -and (Test-PinAdmin $Pin)) { return 'admin' }
    return 'operador'
}
