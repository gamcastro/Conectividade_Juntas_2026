# Manual do técnico — diagnóstico de conectividade

## Antes de sair para campo (máquina com internet)

1. Copie a pasta inteira do projeto para o notebook de vistoria.
2. Monte `bin/` com os binários portáteis:
   - `bin/iperf3/iperf3.exe` (+ `cygwin1.dll`) — build Windows do iperf3
   - `bin/geckodriver/geckodriver.exe` — versão compatível com o Firefox de produção
   - `bin/chromedriver/chromedriver.exe` — versão compatível com o Chrome instalado
3. Coloque `Selenium.WebDriver.dll` e dependências em `lib/Selenium/`.
4. Copie os arquivos de `config/*.exemplo.json` removendo o sufixo `.exemplo` e
   preencha:
   - `ambiente.json` — IP do servidor iperf3 no CPD, URL do sistema de totalização
   - `envio.json` — endpoint do Apps Script e `modo` (`na-hora` ou `offline-first`)
   - `limiares.json` — se os valores definitivos já tiverem sido homologados

## No local da Junta

1. Conecte a internet local e **suba a VPN** da Justiça Eleitoral.
2. Rode `Iniciar-Diagnostico.ps1` (ou o `.bat`). Aceite o prompt do UAC.
3. Informe o **código do local** e clique em **Rodar diagnóstico**.
4. Acompanhe o log colorido. Ao final aparece a classificação:
   **viável / viável com ressalva / inviável**.
5. O resultado é gravado em `resultados/pendentes/`. No modo `na-hora` o envio
   ao Painel de Vistoria é automático; no modo `offline-first` rode
   `Send-ResultadosPendentes` quando houver conexão com a internet aberta.

## Solução de problemas

| Sintoma | Causa provável |
|---|---|
| "iperf3.exe não encontrado" | `bin/iperf3/` não foi montado |
| "VPN não detectada" | Cliente VPN desconectado ou nome fora do padrão em `Get-EstadoAmbiente` |
| Janela não abre / erro de STA | Rodar via `Iniciar-Diagnostico.bat` (força `-STA`) |
| Envio sempre falha | `endpoint_apps_script` errado em `config/envio.json` |
