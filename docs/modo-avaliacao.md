# Modo de avaliação

O DICON pode emitir um **juízo de viabilidade** (viável / ressalva / inviável, com
recomendação de meio e "Painel de Viabilidade") ou apenas **informar as métricas
medidas**. Isso é um flag global — `modo_avaliacao` no doc de limiares
(`config/limiares.json` / `.exemplo.json`, ao lado de `perfis` / `orcamento_vpn`),
editável por **radio no topo da tela de Administração** (mesmo PIN dos limiares).

## Os 3 modos

| Modo | Assistente | Passo 4 (por métrica) | Recomendação de meio | Relatório PDF |
|---|---|---|---|---|
| **`medicao`** (padrão) | 5 passos (pula a decisão) | só `Métrica \| Valor medido`, sem faixa/classificação/veredito | sugestão informativa: meio de **maior download** (VPN se houver, senão rede local), sem rótulo | **Painel de Medições** (identificação + resumo + tabela de valores por meio) |
| **`referencia`** | 5 passos | `Métrica \| Valor \| Faixa de referência` (só leitura); nada é reprovado | idem `medicao` | Painel de Medições + a faixa nas tabelas por meio |
| **`completo`** | 6 passos (com "Recomendação final") | tudo: `Faixa` + `Sugerida` + `Classificação` (editável) + `Motivo do ajuste`; pior caso; override do veredito | motor completo (`Get-ConexaoRecomendada`): candidato = fechou rede local + VPN + Fase 2; desempate por download VPN; provisória se ninguém fechou a VPN | **Painel de Viabilidade** (KPIs viáveis/inviáveis, Situação por meio com veredito, Conclusão do diagnóstico) |

Em `medicao` a tela de Administração esconde as abas de limiares e o orçamento da
VPN (não há o que classificar); em `referencia`/`completo` elas ficam visíveis (a
faixa vem dos perfis de limiares).

## Onde fica no código

- `src/core/Limiares.ps1`: `Get-ModoAvaliacao` (default `medicao`; hook de teste
  `$Global:ModoAvaliacaoOverride`), `Test-ModoCompleto`, `Test-ModoComFaixa`.
- `src/decisao/Invoke-MotorDecisao.ps1`: `Get-ConexaoRecomendada -Modo`.
- `src/ui/Janela-Principal.ps1`: `Set-ModoAssistente` (5↔6 passos, chamado ao
  abrir o assistente); wizard navega por **nome de painel**; `New-MedicaoAtual`
  grava `veredito='medido'` fora do `completo`; `Show-PainelResultado` liga/desliga
  as colunas (`colVpn*`/`colRl*`); `Update-DecisaoRecalculada` sai cedo;
  `Update-BannerRecomendacao` / `Update-ResumoFim` viram sugestão informativa;
  Administração: `rbModoMedicao`/`rbModoReferencia`/`rbModoCompleto` +
  `Update-VisibilidadeLimiaresAdmin`; `Invoke-SalvarLimiares` grava `modo_avaliacao`.
- `src/saida/New-ResultadoJson.ps1`: campo top-level `modo_avaliacao`;
  `conexao_recomendada` carrega `informativo`/`download_mbps`.
- `src/saida/Export-RelatorioPdf.ps1`: `Get-PainelMedicoesHtml` (novo),
  `Get-MeioBlocoHtml -Modo`, `Get-TabelaAvaliacaoHtml -Modo`.
- Testes: `tools/Testar-Fluxo.ps1` bloco `[m]`; `tools/Testar-Recomendacao.ps1`
  cenários 7-8.

## Padrão de fábrica

`config/limiares.exemplo.json` vem com `"modo_avaliacao": "medicao"`. A migração
do formato antigo (`ConvertTo-PerfisLimiares`) também assume `medicao`. Para voltar
ao comportamento clássico (viabilidade), o admin marca **"Viabilidade completa"**
e salva.
