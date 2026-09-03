/**
 * Web App de apoio ao modulo de Conectividade das Juntas Especiais 2026 (TRE-MA).
 *
 *   GET  ?recurso=juntas    -> locais (principal + contingencia) por Junta,
 *                              da planilha "Informacoes Juntas Especiais".
 *   GET  ?recurso=tecnicos  -> tecnicos e o roteiro de cada um (aba Resumo da
 *                              planilha "Roteiros - Teste de Juntas Especiais").
 *   GET  ?recurso=roteiros  -> por roteiro: etapa, datas, trechos de viagem,
 *                              cidades e ids das Juntas resolvidas.
 *   GET  ?recurso=limiares  -> limiares de decisao (aba Limiares, celula A2 = JSON
 *                              NESTED por meio x cenario, v0.6.67+); devolve os
 *                              padroes se a aba nao existir. Retrocompat: se a A2
 *                              estiver vazia mas houver linhas no formato antigo
 *                              (uma por metrica), converte para perfis.lan.
 *   POST {acao:'limiares.salvar', pin, limiares} -> grava o JSON NESTED na
 *                              celula A2 (so o admin: PIN conferido contra a
 *                              Script Property). ** Exige redeploy manual (clasp)
 *                              apos esta mudanca de formato. **
 *   POST {acao:'resultado', ...} -> grava um resultado (so se PLANILHA_RESULTADOS_ID).
 *
 * Implantacao: Implantar > Nova implantacao > "App da Web", Executar como Eu,
 * Acesso "Qualquer pessoa". Copie a URL .../exec para config/juntas.json.
 *
 * Seguranca: o acesso anonimo expoe apenas dados publicos de localizacao e
 * logistica. Nao inclua informacao sensivel nas planilhas de origem.
 */

var PLANILHA_JUNTAS_URL    = 'https://docs.google.com/spreadsheets/d/11MqlYAJfJBZ5ywkEe5AaYopNmM4UVToYPXADwPO72Us/edit';
var ABA_JUNTAS             = 'Página1';
// Aba estruturada opcional, importada da lista oficial de locais. Colunas
// (cabecalho, qualquer ordem): zona, tipo, municipio, local, endereco,
// unidade_consumidora, responsavel, telefone, internet. Se existir, esses
// campos sobrescrevem (unidade_consumidora) ou completam os do bloco de texto.
var ABA_LOCAIS             = 'Locais';

var PLANILHA_ROTEIROS_URL  = 'https://docs.google.com/spreadsheets/d/1EQ32sRXiB4b9aXLc52CkONsL6AOUnIxERw4gKlj7ESo/edit';
var ABA_RESUMO             = 'Resumo';
var ABA_RESUMO_CIDADES     = 'Cópia de Resumo';
var ABA_ETAPAS             = 'Etapas';

var PLANILHA_CONFIG_URL    = 'https://docs.google.com/spreadsheets/d/1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww/edit';
var ABA_LIMIARES           = 'Limiares';

// ID da planilha de Resultados. Prioriza a Script Property PLANILHA_RESULTADOS_ID
// (um projeto por ambiente: producao x homologacao, sem tocar no codigo); se
// ausente, usa o padrao abaixo. Vazio -> POST de resultado desativado.
var PLANILHA_RESULTADOS_ID_PADRAO = '1FnuGm-4sZHXamsK6WtHBKOIUlIsFobhrq6rhpBTrswk';
var ABA_RESULTADOS               = 'Resultados';

function _idResultados() {
  var p = PropertiesService.getScriptProperties().getProperty('PLANILHA_RESULTADOS_ID');
  return (p && p.trim()) || PLANILHA_RESULTADOS_ID_PADRAO;
}

// Direcao de cada metrica: 'max' = menor e melhor; 'min' = maior e melhor.
var MAP_DIRECAO = {
  latencia_ms: 'max', jitter_ms: 'max', perda_percentual: 'max',
  banda_download_mbps: 'min', banda_upload_mbps: 'min', carregamento_web_s: 'max'
};

// Fallback / bootstrap (espelha config/limiares.exemplo.json - formato NESTED).
var LIMIARES_PADRAO = {
  orcamento_vpn: {
    latencia_ms: 30, jitter_ms: 10, perda_percentual: 1,
    banda_download_pct: -30, banda_upload_pct: -30
  },
  perfis: {
    lan: {
      sem_vpn: {
        latencia_ms:         { viavel_ate: 20,  ressalva_ate: 80, ativo: true },
        jitter_ms:           { viavel_ate: 10,  ressalva_ate: 40, ativo: true },
        perda_percentual:    { viavel_ate: 0.5, ressalva_ate: 2,  ativo: true },
        banda_download_mbps: { viavel_min: 25,  ressalva_min: 5,  ativo: true },
        banda_upload_mbps:   { viavel_min: 5,   ressalva_min: 1,  ativo: true }
      },
      com_vpn: {
        latencia_ms:         { viavel_ate: 50,  ressalva_ate: 110, ativo: true },
        jitter_ms:           { viavel_ate: 20,  ressalva_ate: 50,  ativo: true },
        perda_percentual:    { viavel_ate: 1.5, ressalva_ate: 3,   ativo: true },
        banda_download_mbps: { viavel_min: 18,  ressalva_min: 4,   ativo: true },
        banda_upload_mbps:   { viavel_min: 3.5, ressalva_min: 1,   ativo: true },
        carregamento_web_s:  { viavel_ate: 4,   ressalva_ate: 12,  ativo: true }
      }
    },
    celular: {
      sem_vpn: {
        latencia_ms:         { viavel_ate: 40, ressalva_ate: 100, ativo: true },
        jitter_ms:           { viavel_ate: 10, ressalva_ate: 25,  ativo: true },
        perda_percentual:    { viavel_ate: 1,  ressalva_ate: 2,   ativo: true },
        banda_download_mbps: { viavel_min: 15, ressalva_min: 7,   ativo: true },
        banda_upload_mbps:   { viavel_min: 5,  ressalva_min: 1.5, ativo: true }
      },
      com_vpn: {
        latencia_ms:         { viavel_ate: 60,  ressalva_ate: 130, ativo: true },
        jitter_ms:           { viavel_ate: 15,  ressalva_ate: 35,  ativo: true },
        perda_percentual:    { viavel_ate: 1.5, ressalva_ate: 4,   ativo: true },
        banda_download_mbps: { viavel_min: 10,  ressalva_min: 5,   ativo: true },
        banda_upload_mbps:   { viavel_min: 4,   ressalva_min: 1.5, ativo: true },
        carregamento_web_s:  { viavel_ate: 6,   ressalva_ate: 18,  ativo: true }
      }
    },
    wifi_local: {
      folga: {
        latencia_ms: 10, jitter_ms: 5, perda_percentual: 1,
        banda_download_pct: -20, banda_upload_pct: -20, carregamento_web_s: 3
      },
      ativos: {
        sem_vpn: { latencia_ms: true, jitter_ms: true, perda_percentual: true, banda_download_mbps: true, banda_upload_mbps: true },
        com_vpn: { latencia_ms: true, jitter_ms: true, perda_percentual: true, banda_download_mbps: true, banda_upload_mbps: true, carregamento_web_s: true }
      }
    }
  }
};

// Converte o formato antigo (uma linha por metrica) para o NESTED novo, usando
// as linhas como perfis.lan e semeando o resto com os padroes.
function _migrarLimiaresAntigos(linhas) {
  var lan = { sem_vpn: {}, com_vpn: {} };
  for (var r = 1; r < linhas.length; r++) {
    var metrica = String(linhas[r][0]).trim();
    if (!MAP_DIRECAO[metrica]) continue;
    var dir = MAP_DIRECAO[metrica];
    var o = {};
    o[(dir === 'max') ? 'viavel_ate' : 'viavel_min'] = Number(linhas[r][2]);
    o[(dir === 'max') ? 'ressalva_ate' : 'ressalva_min'] = Number(linhas[r][3]);
    var a = String(linhas[r][4] == null ? '' : linhas[r][4]).trim().toLowerCase();
    o.ativo = !(a === 'false' || a === 'nao' || a === 'não' || a === '0' || a === 'n');
    lan.com_vpn[metrica] = o;
    if (metrica !== 'carregamento_web_s') lan.sem_vpn[metrica] = o;
  }
  var doc = JSON.parse(JSON.stringify(LIMIARES_PADRAO));
  doc.perfis.lan = lan;
  doc.perfis.celular = JSON.parse(JSON.stringify(lan));
  doc._comentario = 'migrado do formato antigo (uma linha por metrica)';
  return doc;
}


function doGet(e) {
  var recurso = (e && e.parameter && e.parameter.recurso) || 'juntas';
  try {
    if (recurso === 'juntas') {
      return _json({ atualizado_em: new Date().toISOString(), juntas: listarJuntas() });
    }
    if (recurso === 'tecnicos') {
      return _json({ atualizado_em: new Date().toISOString(), tecnicos: listarTecnicos() });
    }
    if (recurso === 'roteiros') {
      return _json({ atualizado_em: new Date().toISOString(), roteiros: listarRoteiros() });
    }
    if (recurso === 'limiares') {
      return _json(lerLimiares());
    }
    return _json({ erro: 'recurso desconhecido: ' + recurso });
  } catch (err) {
    return _json({ erro: String(err) });
  }
}


function doPost(e) {
  try {
    var body = JSON.parse(e.postData.contents);
    var acao = body.acao || 'resultado';

    if (acao === 'limiares.salvar') {
      return _json(salvarLimiares(body));
    }

    // acao 'resultado'
    if (!_idResultados()) {
      return _json({ status: 'ignorado', motivo: 'PLANILHA_RESULTADOS_ID nao configurado' });
    }
    gravarResultado(body);
    return _json({ status: 'ok', recebido_em: new Date().toISOString() });
  } catch (err) {
    return _json({ status: 'erro', erro: String(err) });
  }
}


/* ============================ JUNTAS ============================ */

/** Le a planilha e devolve uma entrada por local (principal e contingencia). */
function listarJuntas() {
  var aba = SpreadsheetApp.openByUrl(PLANILHA_JUNTAS_URL).getSheetByName(ABA_JUNTAS);
  if (!aba) throw new Error('Aba nao encontrada: ' + ABA_JUNTAS);

  var linhas = aba.getDataRange().getValues();

  var iCab = -1;
  for (var i = 0; i < linhas.length; i++) {
    if (String(linhas[i][0]).trim().toLowerCase() === 'zona eleitoral') { iCab = i; break; }
  }
  if (iCab < 0) throw new Error('Cabecalho "Zona Eleitoral" nao localizado.');

  var saida = [];
  for (var r = iCab + 1; r < linhas.length; r++) {
    var zona  = String(linhas[r][0]).trim();
    var sede  = String(linhas[r][1]).trim();
    var termo = String(linhas[r][2]).trim();
    var blocoPrincipal    = String(linhas[r][3] || '').trim();
    var blocoContingencia = String(linhas[r][4] || '').trim();

    if (!zona) continue;   // separadores / continuacoes de celula

    if (blocoPrincipal)    saida.push(montarLocal(zona, sede, termo, 'principal', blocoPrincipal));
    if (blocoContingencia) saida.push(montarLocal(zona, sede, termo, 'contingencia', blocoContingencia));
  }

  // Enriquece com a aba estruturada (unidade_consumidora e o que faltar).
  var extras = lerLocaisEstruturados();
  for (var s = 0; s < saida.length; s++) {
    var loc = saida[s];
    var ex = extras[String(loc.zona_eleitoral).replace(/\D/g, '') + '|' + loc.tipo + '|' + chaveMunicipio(loc.municipio_termo)];
    if (!ex) continue;
    if (ex.unidade_consumidora) loc.unidade_consumidora = ex.unidade_consumidora;
    if (ex.responsavel && !loc.responsavel)     loc.responsavel   = ex.responsavel;
    if (ex.telefone && !loc.telefone)           loc.telefone      = ex.telefone;
    if (ex.nome && !loc.nome)                   loc.nome          = ex.nome;
    if (ex.endereco && !loc.endereco)           loc.endereco      = ex.endereco;
    if (ex.tipo_internet && !loc.tipo_internet) loc.tipo_internet = ex.tipo_internet;
  }
  return saida;
}

// Chave de municipio para casar a aba estruturada com o "Termo" da Pagina1.
function chaveMunicipio(s) {
  var t = String(s || '').replace(/[\/\-\(]\s*MA\s*\)?\s*$/i, '').replace(/\bMA\b\s*$/i, '');
  return normalizeMunicipio(t);
}

function _normTipoLocal(v) {
  var t = String(v || '').trim().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  return (t.indexOf('conting') >= 0) ? 'contingencia' : 'principal';
}

// Le a aba ABA_LOCAIS (se existir) -> mapa "zona|tipo|chaveMunicipio" -> campos.
function lerLocaisEstruturados() {
  var map = {};
  try {
    var aba = SpreadsheetApp.openByUrl(PLANILHA_JUNTAS_URL).getSheetByName(ABA_LOCAIS);
    if (!aba || aba.getLastRow() < 2) return map;
    var dados = aba.getDataRange().getValues();

    var hRow = -1, col = {};
    for (var i = 0; i < dados.length && hRow < 0; i++) {
      var lc = dados[i].map(function (c) { return String(c).trim().toLowerCase(); });
      if (lc.indexOf('zona') >= 0 && lc.indexOf('tipo') >= 0) {
        hRow = i;
        for (var k = 0; k < lc.length; k++) if (lc[k]) col[lc[k]] = k;
      }
    }
    if (hRow < 0) return map;

    for (var r = hRow + 1; r < dados.length; r++) {
      var row = dados[r];
      var zona = String(row[col['zona']] || '').replace(/\D/g, '');
      if (!zona) continue;
      var tipo = _normTipoLocal(row[col['tipo']]);
      var mun  = (col['municipio'] != null) ? row[col['municipio']] : '';
      var o = {};
      if (col['local']               != null) o.nome                = String(row[col['local']] || '').trim();
      if (col['endereco']            != null) o.endereco            = String(row[col['endereco']] || '').trim();
      if (col['unidade_consumidora'] != null) o.unidade_consumidora = String(row[col['unidade_consumidora']] || '').trim();
      if (col['responsavel']         != null) o.responsavel         = String(row[col['responsavel']] || '').trim();
      if (col['telefone']            != null) o.telefone            = String(row[col['telefone']] || '').trim();
      if (col['internet']            != null) o.tipo_internet       = String(row[col['internet']] || '').trim();
      map[zona + '|' + tipo + '|' + chaveMunicipio(mun)] = o;
    }
  } catch (e) { /* aba ausente ou sem permissao: ignora */ }
  return map;
}


function montarLocal(zona, sede, termo, tipo, bloco) {
  var linhas = bloco.split(/\r?\n/)
    .map(function (s) { return s.trim(); })
    .filter(function (s) { return s.length > 0; });

  var nome = linhas.length ? linhas[0].replace(/^Local\s*:\s*/i, '').trim() : '';

  // Extrai o primeiro valor de "<Rotulo>: <valor>" no bloco (case-insensitive).
  function campo(rotulo) {
    var re = new RegExp('^' + rotulo + '\\s*:\\s*(.+)$', 'i');
    for (var i = 0; i < linhas.length; i++) {
      var m = linhas[i].match(re);
      if (m) return m[1].trim();
    }
    return '';
  }

  return {
    id: 'ZE' + zona + '-' + slug(termo) + '-' + tipo.toUpperCase(),
    zona_eleitoral: Number(zona) || zona,
    municipio_sede: sede,
    municipio_termo: termo,
    tipo: tipo,
    nome: nome,
    endereco: campo('Endere[çc]o'),
    unidade_consumidora: campo('Unidade Consumidora') || campo('UC'),
    responsavel: campo('Respons[áa]vel'),
    funcao: campo('Fun[çc][ãa]o'),
    telefone: campo('Telefone(?:\\s*/\\s*WhatsApp)?') || campo('WhatsApp'),
    tipo_internet: campo('Tipo de Internet') || campo('Internet'),
    texto_completo: bloco
  };
}


/* ============================ TECNICOS ============================ */

function listarTecnicos() {
  var linhas = _valores(PLANILHA_ROTEIROS_URL, ABA_RESUMO);
  var cab = _acharCelula(linhas, 'roteiro');
  if (!cab) throw new Error('Cabecalho "ROTEIRO" nao localizado na aba ' + ABA_RESUMO);
  var c = cab.c;   // coluna base (a planilha tem coluna A vazia)

  var out = [];
  for (var r = cab.r + 1; r < linhas.length; r++) {
    var rot = _parseRoteiro(linhas[r][c]);
    if (!rot) continue;
    var nome = String(linhas[r][c + 3] || '').trim();
    if (!nome) continue;
    out.push({
      nome: nome,
      roteiro_numero: rot.numero,
      roteiro_nome: rot.nome,
      ida: _fmtData(linhas[r][c + 1]),
      retorno: _fmtData(linhas[r][c + 2]),
      dias: Number(linhas[r][c + 4]) || linhas[r][c + 4]
    });
  }
  return out;
}


/* ============================ ROTEIROS ============================ */

function listarRoteiros() {
  var juntas = listarJuntas();
  var tecnicos = listarTecnicos();
  var cidadesPorRoteiro = _lerCidadesPorRoteiro();
  var etapaPorRoteiro   = _lerEtapaPorRoteiro();

  var out = [];
  for (var t = 0; t < tecnicos.length; t++) {
    var tc = tecnicos[t];
    var n = tc.roteiro_numero;
    var cidades = cidadesPorRoteiro[n] || [];
    var trechosInfo = _lerTrechos(n);

    var juntasIds = [];
    var semJunta = [];
    for (var c = 0; c < cidades.length; c++) {
      var alvo = normalizeMunicipio(cidades[c]);
      var achou = false;
      for (var j = 0; j < juntas.length; j++) {
        if (normalizeMunicipio(juntas[j].municipio_termo) === alvo) {
          juntasIds.push(juntas[j].id);
          achou = true;
        }
      }
      if (!achou) semJunta.push(cidades[c]);
    }

    out.push({
      numero: n,
      nome: tc.roteiro_nome,
      rotulo: 'Roteiro ' + n + ' - ' + tc.roteiro_nome,
      tecnico: tc.nome,
      etapa: etapaPorRoteiro[n] || null,
      ida: tc.ida,
      retorno: tc.retorno,
      dias: tc.dias,
      total_km: trechosInfo.total_km,
      total_tempo: trechosInfo.total_tempo,
      total_locais: trechosInfo.total_locais,
      cidades: cidades,
      trechos: trechosInfo.trechos,
      juntas_ids: juntasIds,
      cidades_sem_junta: semJunta
    });
  }
  return out;
}


function _lerCidadesPorRoteiro() {
  var linhas = _valores(PLANILHA_ROTEIROS_URL, ABA_RESUMO_CIDADES);
  var cab = _acharCelula(linhas, 'roteiro');
  var map = {};
  if (!cab) return map;
  var c = cab.c;
  for (var r = cab.r + 1; r < linhas.length; r++) {
    var rot = _parseRoteiro(linhas[r][c]);
    if (!rot) continue;
    var blob = String(linhas[r][c + 4] || '');
    map[rot.numero] = blob.split(/\r?\n/)
      .map(function (s) { return s.trim(); })
      .filter(function (s) { return s.length > 0; });
  }
  return map;
}


function _lerEtapaPorRoteiro() {
  var linhas = _valores(PLANILHA_ROTEIROS_URL, ABA_ETAPAS);
  var cab = _acharCelula(linhas, 'etapa');
  var map = {};
  if (!cab) return map;
  var c = cab.c;
  var etapaAtual = null;
  for (var r = cab.r + 1; r < linhas.length; r++) {
    var a = String(linhas[r][c]).trim();
    if (/^per[íi]odo total/i.test(a)) break;
    if (a) etapaAtual = Number(a) || a;
    var rot = _parseRoteiro(linhas[r][c + 1]);
    if (rot) map[rot.numero] = etapaAtual;
  }
  return map;
}


function _lerTrechos(numero) {
  var vazio = { trechos: [], total_km: null, total_tempo: null, total_locais: null };
  var ss = SpreadsheetApp.openByUrl(PLANILHA_ROTEIROS_URL);
  var aba = ss.getSheetByName('Roteiro ' + numero);
  if (!aba) return vazio;

  var linhas = aba.getDataRange().getValues();
  var iCab = -1, c = 0;
  for (var i = 0; i < linhas.length && iCab < 0; i++) {
    for (var k = 0; k < linhas[i].length; k++) {
      if (/^munic[íi]pio\s+origem/i.test(String(linhas[i][k]).trim())) { iCab = i; c = k; break; }
    }
  }
  if (iCab < 0) return vazio;

  var trechos = [];
  var total_km = null, total_tempo = null, total_locais = null;
  for (var r = iCab + 1; r < linhas.length; r++) {
    var a = String(linhas[r][c]).trim();
    if (/^total de locais/i.test(a)) { total_locais = Number(linhas[r][c + 1]) || linhas[r][c + 1]; continue; }
    if (/^total\b/i.test(a)) {
      // linha "Total" tem o rotulo mesclado; km fica na coluna de Distancia.
      var row = linhas[r];
      for (var q = c + 1; q < row.length; q++) {
        if (typeof row[q] === 'number') { total_km = row[q]; total_tempo = String(row[q + 1] || '').trim(); break; }
      }
      continue;
    }
    if (/^(quantidade de dias|n[ºo]\.? de t[ée]cnico|data)/i.test(a)) continue;
    if (!a || !String(linhas[r][c + 1] || '').trim()) continue;
    trechos.push({
      origem: a,
      destino: String(linhas[r][c + 1]).trim(),
      distancia_km: Number(linhas[r][c + 2]) || linhas[r][c + 2],
      tempo: String(linhas[r][c + 3] || '').trim(),
      atividade_dias: linhas[r][c + 4] === '' || linhas[r][c + 4] == null ? 0 : (Number(linhas[r][c + 4]) || linhas[r][c + 4])
    });
  }
  return { trechos: trechos, total_km: total_km, total_tempo: total_tempo, total_locais: total_locais };
}


/* ============================ HELPERS ============================ */

function normalizeMunicipio(s) {
  var t = String(s || '').trim()
    .replace(/\bGov\.\s*/i, 'Governador ')
    .replace(/\bSen\.\s*/i, 'Senador ')
    .replace(/\bdo MA\b/gi, 'do Maranhão');
  t = t.normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase().replace(/\s+/g, ' ').trim();
  var alias = { 'GOVERNADOR EDSON LOBAO': 'GOVERNADOR EDISON LOBAO' };
  return alias[t] || t;
}

function slug(s) {
  return String(s).normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

function _valores(url, aba) {
  var s = SpreadsheetApp.openByUrl(url).getSheetByName(aba);
  if (!s) throw new Error('Aba nao encontrada: ' + aba);
  return s.getDataRange().getValues();
}

/** Acha a primeira celula (qualquer coluna) cujo texto == textoLower. */
function _acharCelula(linhas, textoLower) {
  for (var i = 0; i < linhas.length; i++) {
    for (var k = 0; k < linhas[i].length; k++) {
      if (String(linhas[i][k]).trim().toLowerCase() === textoLower) return { r: i, c: k };
    }
  }
  return null;
}

function _parseRoteiro(v) {
  var m = String(v || '').trim().match(/^(\d+)\s*[-–]\s*(.+)$/);
  if (!m) return null;
  return { numero: Number(m[1]), nome: m[2].trim() };
}

function _fmtData(v) {
  if (v instanceof Date) {
    return Utilities.formatDate(v, Session.getScriptTimeZone(), 'dd/MM/yyyy');
  }
  return String(v || '').trim();
}


/* ============================ LIMIARES ============================ */

function _abaLimiares(criar) {
  var ss = SpreadsheetApp.openByUrl(PLANILHA_CONFIG_URL);
  var aba = ss.getSheetByName(ABA_LIMIARES);
  if (!aba && criar) {
    aba = ss.insertSheet(ABA_LIMIARES);
    aba.getRange(1, 1).setValue('limiares_json (editado pelo DICON - nao editar aqui a mao)');
  }
  return aba;
}

// Devolve { atualizado_em, origem, limiares:<doc NESTED> }.
// Fonte: celula A2 da aba Limiares (JSON). Retrocompat: linhas do formato antigo.
function lerLimiares() {
  var aba = _abaLimiares(false);
  var origem = 'padrao';
  var doc = LIMIARES_PADRAO;

  if (aba && aba.getLastRow() >= 2) {
    var bruto = String(aba.getRange(2, 1).getValue() || '').trim();
    if (bruto && bruto.charAt(0) === '{') {
      try { doc = JSON.parse(bruto); origem = 'planilha'; }
      catch (e) { doc = LIMIARES_PADRAO; origem = 'padrao (A2 invalida: ' + e + ')'; }
    } else {
      // sem JSON na A2: talvez ainda esteja o formato antigo (uma linha/metrica)
      var linhas = aba.getDataRange().getValues();
      var temAntigo = false;
      for (var r = 1; r < linhas.length; r++) {
        if (MAP_DIRECAO[String(linhas[r][0]).trim()]) { temAntigo = true; break; }
      }
      if (temAntigo) { doc = _migrarLimiaresAntigos(linhas); origem = 'planilha (migrado do formato antigo)'; }
    }
  }

  return { atualizado_em: new Date().toISOString(), origem: origem, limiares: doc };
}

function salvarLimiares(body) {
  var esperado = PropertiesService.getScriptProperties().getProperty('ADMIN_PIN_SHA256');
  if (!esperado) {
    return { status: 'erro', erro: 'ADMIN_PIN_SHA256 nao configurado (rode setupAdminPin no editor).' };
  }
  if (!body.pin || sha256Hex(String(body.pin)) !== String(esperado).toLowerCase()) {
    return { status: 'negado' };
  }

  var lim = body.limiares || {};
  if (!lim.perfis || !lim.perfis.lan || !lim.perfis.celular || !lim.perfis.wifi_local) {
    return { status: 'erro', erro: 'limiares fora do formato nested (esperado perfis.lan / .celular / .wifi_local)' };
  }

  var aba = _abaLimiares(true);
  // limpa qualquer resquicio do formato antigo e grava o JSON na A2
  if (aba.getLastRow() > 1) {
    aba.getRange(2, 1, aba.getLastRow() - 1, Math.max(aba.getLastColumn(), 5)).clearContent();
  }
  aba.getRange(2, 1).setValue(JSON.stringify(lim, null, 2));

  return { status: 'ok', salvo_em: new Date().toISOString() };
}

function sha256Hex(s) {
  var b = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, s, Utilities.Charset.UTF_8);
  return b.map(function (x) { return ('0' + (x & 0xff).toString(16)).slice(-2); }).join('');
}

// Alternativa por codigo. Preferir: engrenagem "Configuracoes do projeto" >
// "Propriedades do script" > ADMIN_PIN_SHA256 = <hash de config/admin.json>.
function setupAdminPin(hashHex) {
  if (!hashHex) throw new Error('passe o hash: setupAdminPin("<pin_sha256>")');
  PropertiesService.getScriptProperties().setProperty('ADMIN_PIN_SHA256', String(hashHex).toLowerCase());
  return 'ADMIN_PIN_SHA256 gravado.';
}

// Define a planilha de Resultados deste projeto Apps Script. Rode 1x no editor:
//   producao:     setupResultados('1FnuGm-4sZHXamsK6WtHBKOIUlIsFobhrq6rhpBTrswk')
//   homologacao:  setupResultados('1aihOABaGSnHNIP5BHisR-iI1-OpQWHALLt5jvsUzpWE')
function setupResultados(sheetId) {
  if (!sheetId) throw new Error('passe o id: setupResultados("<sheet_id>")');
  PropertiesService.getScriptProperties().setProperty('PLANILHA_RESULTADOS_ID', String(sheetId).trim());
  return 'PLANILHA_RESULTADOS_ID = ' + String(sheetId).trim();
}


/* ============================ RESULTADOS (POST) ============================ */

function gravarResultado(dados) {
  var ss  = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(ABA_RESULTADOS) || ss.insertSheet(ABA_RESULTADOS);

  var COLS = ['recebido_em', 'tecnico', 'local_id', 'zona', 'municipio_termo', 'tipo',
    'classificacao_final', 'classificacao_automatica', 'ajustada',
    'conexao_recomendada', 'operadora_recomendada', 'veredito_recomendado',
    'recomendacao_provisoria', 'motivo_recomendacao',
    'latencia_ms', 'jitter_ms', 'perda_%', 'download_mbps', 'upload_mbps', 'carregamento_s', 'json'];

  if (aba.getLastRow() === 0) {
    aba.appendRow(COLS);
  } else {
    // migracao: planilha de versao anterior nao tem as colunas multi-meio.
    var head = aba.getRange(1, 1, 1, aba.getLastColumn()).getValues()[0];
    if (head.indexOf('conexao_recomendada') === -1) {
      var novas = ['conexao_recomendada', 'operadora_recomendada', 'veredito_recomendado',
        'recomendacao_provisoria', 'motivo_recomendacao'];
      var jsonIdx = head.indexOf('json');
      var at = (jsonIdx === -1) ? head.length + 1 : jsonIdx + 1;  // antes da coluna 'json'
      aba.insertColumnsBefore(at, novas.length);
      aba.getRange(1, at, 1, novas.length).setValues([novas]);
    }
  }

  var m = dados.metricas || {};
  var l = dados.local || {};
  var c = dados.classificacao || {};
  var r = dados.conexao_recomendada || {};
  // compat: versao antiga mandava classificacao como string
  var cFinal = (typeof c === 'string') ? c : (c.final || '');
  var cAuto  = (typeof c === 'string') ? c : (c.automatica || '');
  var cAdj   = (typeof c === 'object') ? !!c.ajustada : false;

  var valores = {
    'recebido_em': new Date(),
    'tecnico': (dados.tecnico || {}).nome || '',
    'local_id': l.id || '',
    'zona': l.zona_eleitoral || '',
    'municipio_termo': l.municipio_termo || '',
    'tipo': l.tipo || '',
    'classificacao_final': cFinal,
    'classificacao_automatica': cAuto,
    'ajustada': cAdj,
    'conexao_recomendada': r.rotulo || r.meio || '',
    'operadora_recomendada': r.operadora || '',
    'veredito_recomendado': r.veredito || '',
    'recomendacao_provisoria': !!r.provisoria,
    'motivo_recomendacao': r.motivo || '',
    'latencia_ms': m.latencia_ms,
    'jitter_ms': m.jitter_ms,
    'perda_%': m.perda_percentual,
    'download_mbps': m.banda_download_mbps,
    'upload_mbps': m.banda_upload_mbps,
    'carregamento_s': m.carregamento_web_s,
    'json': JSON.stringify(dados)
  };

  // grava por nome de coluna, tolerando ordem/idade diferentes da planilha.
  var head2 = aba.getRange(1, 1, 1, aba.getLastColumn()).getValues()[0];
  var linha = head2.map(function (nome) {
    return Object.prototype.hasOwnProperty.call(valores, nome) ? valores[nome] : '';
  });
  aba.appendRow(linha);
}


function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
