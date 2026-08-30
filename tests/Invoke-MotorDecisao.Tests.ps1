# Pester (v5). Executar da raiz do projeto:  Invoke-Pester .\tests

BeforeAll {
    $raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path $raiz 'src\decisao\Invoke-MotorDecisao.ps1')
    $script:Limiares = Get-Content (Join-Path $raiz 'config\limiares.exemplo.json') -Raw | ConvertFrom-Json
}

Describe 'Invoke-MotorDecisao' {

    It 'classifica como viavel quando todas as metricas estao na faixa ideal' {
        $m = [pscustomobject]@{
            LatenciaMediaMs = 20; JitterMs = 3; PerdaPercentual = 0
            BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = 2
        }
        (Invoke-MotorDecisao -Metricas $m -Limiares $Limiares).Classificacao | Should -Be 'viavel'
    }

    It 'cai para viavel_com_ressalva quando uma metrica esta na faixa de ressalva' {
        $m = [pscustomobject]@{
            LatenciaMediaMs = 90; JitterMs = 3; PerdaPercentual = 0
            BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = 2
        }
        (Invoke-MotorDecisao -Metricas $m -Limiares $Limiares).Classificacao | Should -Be 'viavel_com_ressalva'
    }

    It 'classifica como inviavel quando uma metrica estoura a faixa de ressalva' {
        $m = [pscustomobject]@{
            LatenciaMediaMs = 20; JitterMs = 3; PerdaPercentual = 40
            BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = 2
        }
        (Invoke-MotorDecisao -Metricas $m -Limiares $Limiares).Classificacao | Should -Be 'inviavel'
    }

    It 'trata metrica ausente (null) como inviavel' {
        $m = [pscustomobject]@{
            LatenciaMediaMs = $null; JitterMs = 3; PerdaPercentual = 0
            BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = 2
        }
        (Invoke-MotorDecisao -Metricas $m -Limiares $Limiares).Classificacao | Should -Be 'inviavel'
    }

    It 'devolve uma avaliacao por metrica' {
        $m = [pscustomobject]@{
            LatenciaMediaMs = 20; JitterMs = 3; PerdaPercentual = 0
            BandaDownloadMbps = 50; BandaUploadMbps = 20; CarregamentoWebS = 2
        }
        (Invoke-MotorDecisao -Metricas $m -Limiares $Limiares).Detalhes.Count | Should -Be 6
    }
}
