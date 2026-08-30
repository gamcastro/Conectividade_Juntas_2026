# Contrato do JSON de resultado

Gerado por `New-ResultadoJson`, salvo em `resultados/pendentes/` pelo botão
**Salvar resultado** e enviado via `Invoke-RestMethod` (POST, `application/json`)
ao endpoint do Apps Script.

Cada métrica tem uma **classe automática** (do motor) e uma **classe final** (o
que o técnico deixou). Quando `classe_final != classe_automatica`, a
`justificativa` é obrigatória. A `classificacao.final` também pode ser
sobrescrita pelo técnico (com `classificacao.justificativa`).

## Exemplo

```json
{
  "versao_ferramenta": "0.1.0",
  "coletado_em": "2026-08-30T14:22:05.1234567-03:00",
  "tecnico": { "nome": "Arnóbio Mata de Araújo Júnior" },
  "local": {
    "id": "ZE6-SENADOR_ALEXANDRE_COSTA-PRINCIPAL",
    "zona_eleitoral": 6,
    "municipio_sede": "CAXIAS",
    "municipio_termo": "Senador Alexandre Costa",
    "tipo": "principal",
    "nome": "CÂMARA MUNICIPAL",
    "endereco": "Rua Cônego Aderson, nº 09, Centro",
    "tipo_internet": "Fibra óptica"
  },
  "ambiente": {
    "host": "NOTE-VISTORIA-07",
    "usuario": "tecnico.sti",
    "so": "Microsoft Windows 11 Pro",
    "vpn_ativa": true,
    "interface_principal": "Wi-Fi",
    "coletado_em": "2026-08-30T14:22:00.0000000-03:00"
  },
  "metricas": {
    "latencia_ms": 48.3,
    "jitter_ms": 6.1,
    "perda_percentual": 0.0,
    "banda_download_mbps": 34.7,
    "banda_upload_mbps": 12.2,
    "carregamento_web_s": 4.8
  },
  "avaliacao": [
    {
      "metrica": "latencia_ms", "rotulo": "Latencia", "valor": 48.3,
      "unidade": "ms", "direcao": "max",
      "limiar_viavel": 60, "limiar_ressalva": 120,
      "classe_automatica": "viavel", "classe_final": "viavel",
      "ajustada": false, "justificativa": ""
    }
  ],
  "classificacao": {
    "automatica": "viavel",
    "recalculada": "viavel",
    "final": "viavel",
    "ajustada": false,
    "justificativa": ""
  },
  "envio": { "status": "pendente", "tentativas": 0, "enviado_em": null }
}
```

## Campos

| Campo | Tipo | Observação |
|---|---|---|
| `versao_ferramenta` | string | `$Global:VersaoApp` |
| `coletado_em` | string ISO 8601 | com offset de fuso |
| `tecnico.nome` | string | técnico logado (`$Global:SessaoAtual`); "" no modo `-SemUI` |
| `local.id` | string | `ZE<zona>-<TERMO>-<PRINCIPAL\|CONTINGENCIA>`; vira nome do arquivo |
| `local.*` | string/número | da planilha *Informações Juntas Especiais* |
| `ambiente.*` | objeto | saída de `Get-EstadoAmbiente` |
| `metricas.*` | número \| null | valor medido; `null` = não coletada |
| `avaliacao[]` | array | uma entrada por métrica |
| `avaliacao[].classe_automatica` | string | `viavel` \| `ressalva` \| `inviavel` (do motor) |
| `avaliacao[].classe_final` | string | idem; o que o técnico deixou |
| `avaliacao[].ajustada` | bool | `classe_final != classe_automatica` |
| `avaliacao[].justificativa` | string | obrigatória quando `ajustada` |
| `classificacao.automatica` | string | `viavel` \| `viavel_com_ressalva` \| `inviavel` (motor) |
| `classificacao.recalculada` | string | pior caso das `classe_final` das métricas |
| `classificacao.final` | string | decisão do técnico (= recalculada se não mexeu) |
| `classificacao.ajustada` | bool | `final != recalculada` |
| `classificacao.justificativa` | string | obrigatória quando `classificacao.ajustada` |
| `envio.status` | string | `pendente` \| `enviado` |

## A confirmar com o Apps Script

- Nome exato do parâmetro/rota esperado no `doPost(e)`.
- Se o corpo vai como JSON puro (atual) ou `form-urlencoded` com um campo
  `payload`.
- Formato da resposta de sucesso (para gravar `enviado_em` e mudar `status`).
