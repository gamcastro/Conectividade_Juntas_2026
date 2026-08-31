# Marca DICON

Guia completo (conceito, assinaturas, aplicações, usos indevidos):
**[Identidade DICON](https://claude.ai/code/artifact/4543b902-d51c-4c93-a029-3856c77c88c2)**

## Arquivos

| Arquivo | Uso |
|---|---|
| `dicon-simbolo.svg` | Símbolo principal — azul-je + estrelas de veredito. Fundo claro. |
| `dicon-simbolo-mono.svg` | Uma tinta (`#14181F`). Impressão, carimbo, fax. |
| `dicon-simbolo-reverso.svg` | Fundo escuro (azul-profundo / foto). Traço claro + estrelas. |
| `dicon-icone.svg` | Ícone do app — quadrado arredondado, fundo azul-je, símbolo reverso. |
| `dicon-favicon.svg` | Versão simplificada (2 arcos, sem estrelas) para tamanhos ≤ 32 px. |
| `dicon.ico` | Ícone multi-tamanho (256/64/48/32/16) para o executável / janela. |
| `icones/dicon-{16..256}.png` | PNGs rasterizados do ícone. |
| `paleta.md` | Tokens de cor (claro / escuro), com regras de uso. |
| `dicon-cores.ps1` | Mesmos tokens para dot-source em PowerShell (`$DiconCor`). |
| `institucional/eleicoes-2026.png` | Selo oficial **Eleições 2026** (850×567, fundo claro) — para a co-assinatura na tela de abertura. |

> `assets/logo-eleicoes-2026.png` (raiz de `assets/`) é o mesmo arquivo, mantido
> ali porque a GUI atual o referencia. Ao aplicar a identidade, migrar a
> referência para `assets/marca/institucional/`.

## Regenerar os PNGs / .ico

```powershell
.\tools\Gerar-Icones.ps1
```

Rasteriza a partir da geometria (não depende de renderer de SVG). Edite o
`tools/Gerar-Icones.ps1` se mudar a marca.

## Logotipo

O logotipo "DICON" é **Archivo ExtraBold**, caixa alta, tracking −2%. Para
distribuição, converter o texto em curvas (outline). O símbolo acima é geometria
pura e não precisa de fonte.

## Importante

- As estrelas usam **exatamente** as cores de veredito (viável / ressalva /
  inviável). Nunca trocar.
- Não redesenhar, distorcer, emoldurar, aplicar sombra/gradiente, nem alterar a
  espessura do traço — ver "Usos indevidos" no guia.
- Não substitui o Manual de Identidade do TRE-MA / gov.br. As co-assinaturas com
  o TRE-MA e o selo Eleições 2026 usam os arquivos oficiais.
