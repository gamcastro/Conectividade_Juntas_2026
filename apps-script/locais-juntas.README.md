# Aba `Locais` (dados estruturados dos locais das Juntas)

Fonte: *LOCAIS PARA INSTALAÇÃO DAS JUNTAS ESPECIAIS — Oficial*. Traz a
**Unidade Consumidora**, que não existe nos blocos de texto da aba `Página1`.

## Como carregar

1. Abra a planilha **Informações Juntas Especiais**
   (`11MqlYAJfJBZ5ywkEe5AaYopNmM4UVToYPXADwPO72Us`).
2. Crie uma aba nova chamada exatamente **`Locais`**.
3. `Arquivo → Importar → Fazer upload` → `locais-juntas.tsv`
   (separador: tabulação; "Substituir a planilha atual" na aba `Locais`).
   Ou abra o `.tsv`, copie tudo e cole em `A1` da aba `Locais`.
4. **Revise contra o PDF oficial** — este `.tsv` foi transcrito do PDF e pode
   ter erros (números de UC, telefones, endereços).

## Colunas (cabeçalho na linha 1, ordem livre)

`zona` · `tipo` · `municipio` · `local` · `endereco` · `unidade_consumidora` ·
`responsavel` · `telefone` · `internet`

- `zona`: só o número (ex.: `24`, `107`).
- `tipo`: `principal` ou `contingencia`.
- `municipio`: precisa casar com a coluna **Termo** da aba `Página1`
  (sem `/MA`, `- MA`, `(MA)`). É o que liga a linha ao local certo.

## O que o Web App faz

`listarJuntas()` monta os locais da aba `Página1` (como antes) e **enriquece**
cada um com a linha correspondente de `Locais` (casando `zona` + `tipo` +
`municipio`): preenche `unidade_consumidora` e completa `responsavel` /
`telefone` / `local` / `endereco` / `internet` que estiverem em branco.
Sem a aba `Locais`, tudo continua funcionando pelo texto da `Página1`.

Depois de carregar/editar a aba: no app, **Atualizar dados**.
