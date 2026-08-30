# Referência de limiares

> **Onde ficam:** planilha Google de configuração
> (`1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww`, aba `Limiares`), editável pelo
> **administrador** na tela de Administração do app. O Web App expõe
> `?recurso=limiares`; a ferramenta cacheia em `data/limiares.json`. Se a aba
> ainda não existe, valem os padrões abaixo (`config/limiares.exemplo.json`).
>
> **Salvar** exige o PIN do admin. Pré-requisito único: no editor do Apps Script,
> engrenagem *Configurações do projeto* → *Propriedades do script* → adicionar
> `ADMIN_PIN_SHA256` com o hash impresso por `tools/Definir-PIN-Admin.ps1`.

## Modelo de avaliação

Cada métrica é classificada em `viavel`, `ressalva` ou `inviavel`. A
classificação final do local é o pior caso entre todas:

| Situação das métricas | Classificação final |
|---|---|
| Todas em `viavel` | `viavel` |
| Nenhuma `inviavel`, ao menos uma em `ressalva` | `viavel_com_ressalva` |
| Ao menos uma `inviavel` (ou sem medida) | `inviavel` |

**Ajuste pelo técnico:** no painel de resultados o técnico pode trocar a classe
de qualquer métrica e a decisão final, sempre com justificativa quando muda. O
JSON guarda o valor automático e o final lado a lado (ver `docs/formato-json.md`).

## Métricas e direção

| Métrica | Chave em `limiares.json` | Melhor quando | Campos |
|---|---|---|---|
| Latência média | `latencia_ms` | menor | `viavel_ate`, `ressalva_ate` |
| Jitter | `jitter_ms` | menor | `viavel_ate`, `ressalva_ate` |
| Perda de pacotes | `perda_percentual` | menor | `viavel_ate`, `ressalva_ate` |
| Banda de download | `banda_download_mbps` | maior | `viavel_min`, `ressalva_min` |
| Banda de upload | `banda_upload_mbps` | maior | `viavel_min`, `ressalva_min` |
| Carregamento da totalização | `carregamento_web_s` | menor | `viavel_ate`, `ressalva_ate` |

## Valores provisórios atuais

| Métrica | viável | ressalva até / mínimo |
|---|---|---|
| Latência (ms) | ≤ 60 | ≤ 120 |
| Jitter (ms) | ≤ 10 | ≤ 30 |
| Perda (%) | ≤ 1 | ≤ 5 |
| Download (Mbps) | ≥ 20 | ≥ 8 |
| Upload (Mbps) | ≥ 10 | ≥ 4 |
| Carregamento web (s) | ≤ 5 | ≤ 12 |

## A definir com o time de totalização

- Banda mínima real por posto de trabalho da Junta Especial.
- Latência/perda em que o sistema de totalização começa a apresentar timeout.
- Se o teste de carregamento deve usar uma página específica (login vs. tela de
  digitação) e qual tempo é aceitável.
