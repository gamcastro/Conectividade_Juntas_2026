# Web App do Apps Script

`Codigo.gs` serve, para a ferramenta de campo:

| Rota (GET) | Conteúdo |
|---|---|
| `?recurso=juntas` | locais (principal + contingência) por Junta — planilha *Informações Juntas Especiais* |
| `?recurso=tecnicos` | técnicos e o roteiro de cada um — aba *Resumo* da planilha *Roteiros - Teste de Juntas Especiais* |
| `?recurso=roteiros` | por roteiro: etapa, datas, trechos de viagem, cidades e `juntas_ids` resolvidos |
| `?recurso=limiares` | limiares de decisão — aba *Limiares* da planilha de config; padrões se a aba não existir |

`POST {acao:'limiares.salvar', pin, limiares}` grava os limiares (PIN do admin
conferido contra a Script Property `ADMIN_PIN_SHA256` — ver `CLASP.md`).

Constantes no topo: `PLANILHA_JUNTAS_URL`, `PLANILHA_ROTEIROS_URL` (ambas já
preenchidas, via `openByUrl`).

## Implantar

> Já implantado via `clasp` — ver `CLASP.md` para redeploy. Os passos abaixo são
> para uma implantação nova do zero.

1. https://script.google.com → **Novo projeto**.
2. Cole o conteúdo de `Codigo.gs` no editor.
3. Confira as constantes no topo (`PLANILHA_JUNTAS_URL`, `PLANILHA_ROTEIROS_URL`,
   `PLANILHA_RESULTADOS_ID` vazio = `POST` desativado).
4. **Implantar → Nova implantação → Tipo: App da Web**
   - Executar como: **Eu**
   - Quem tem acesso: **Qualquer pessoa**
5. Autorize os escopos (leitura de planilhas).
6. Copie a **URL do app da Web** (`.../exec`) e cole em:
   - `config/juntas.json` → `endpoint`

## Testar

- No navegador: `https://.../exec?recurso=juntas` deve devolver JSON com
  `{ "atualizado_em": ..., "juntas": [ ... ] }`.
- Cada Junta vira duas entradas: `tipo: "principal"` (coluna D) e
  `tipo: "contingencia"` (coluna E).

## Observações

- Linhas da planilha sem *Zona Eleitoral* são ignoradas (separadores /
  continuações de célula). O total ignorado aparece em **Execuções → Logs**.
- Só nome, endereço e tipo de internet são extraídos das células D/E; o texto
  completo vai em `texto_completo`.
- Acesso anônimo expõe apenas dados públicos de localização — não inclua
  informação sensível na planilha de origem.
