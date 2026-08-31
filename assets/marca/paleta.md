# Paleta DICON

Guia completo (com aplicações e regras de uso): [Identidade DICON](https://claude.ai/code/artifact/4543b902-d51c-4c93-a029-3856c77c88c2).

## Azuis — estrutura

| Token | Claro | Escuro | Uso |
|---|---|---|---|
| `azul-je` | `#123FA8` | `#6E9BFF` | Primária: marca, botões, links, estado ativo |
| `azul-profundo` | `#0A1E4D` | `#0A1428` | Fundos institucionais, barra de título, splash |
| `azul-ambiente` | `#E7ECF8` | `#16223C` | Realce sutil, faixas, seleção — só como fundo |

## Veredito — semântico (não é acento decorativo)

| Estado | Claro | Escuro |
|---|---|---|
| `viavel` | `#1B7F3B` | `#4FC177` |
| `ressalva` | `#B77F00` | `#E8B93E` |
| `inviavel` | `#BC352A` | `#E8695C` |

## Neutros — azul-enviesados

| Token | Claro | Escuro | Uso |
|---|---|---|---|
| `grafite` | `#14181F` | `#E6EAF2` | Texto principal (claro) / fundo do app (escuro) |
| `aco` | `#5C6472` | `#7D8698` | Texto secundário, legendas, ícones inativos |
| `papel` | `#F4F5F8` | `#0F1319` | Fundo (documentos / app) |
| `linha` | `#C9CFDB` | `#262D39` | Bordas, divisórias, grades |

## Herança — só fio decorativo

| Token | Hex | Uso |
|---|---|---|
| `amarelo` | `#F2C200` | Filete de 3 px em rodapé de documento. Nunca em UI. |
| `verde` | `#009C3B` | Filete par ao amarelo. Não confundir com `viavel`. |

## Estrelas da marca

As três estrelas do símbolo usam **exatamente** as cores de veredito
(`viavel` / `ressalva` / `inviavel`) na versão principal, e a lightened
(`#7FE0A0` / `#F2D272` / `#F2A79C`) no ícone do app. Nunca usar outra cor.
