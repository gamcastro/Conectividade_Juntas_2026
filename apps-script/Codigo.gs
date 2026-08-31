/**
 * Web App de apoio ao modulo de Conectividade das Juntas Especiais 2026 (TRE-MA).
 *
 *   GET  ?recurso=juntas    -> locais (principal + contingencia) por Junta,
 *                              da planilha "Informacoes Juntas Especiais".
 *   GET  ?recurso=tecnicos  -> tecnicos e o roteiro de cada um (aba Resumo da
 *                              planilha "Roteiros - Teste de Juntas Especiais").
 *   GET  ?recurso=roteiros  -> por roteiro: etapa, datas, trechos de viagem,
 *                              cidades e ids das Juntas resolvidas.
 *   GET  ?recurso=limiares  -> limiares de decisao (aba Limiares da planilha de
 *                              config); devolve os padroes se a aba nao existir.
 *   POST {acao:'limiares.salvar', pin, limiares} -> grava os limiares (so o
 *                              admin: PIN conferido contra a Script Property).
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

var PLANILHA_ROTEIROS_URL  = 'https://docs.google.com/spreadsheets/d/1EQ32sRXiB4b9aXLc52CkONsL6AOUnIxERw4gKlj7ESo/edit';
var ABA_RESUMO             = 'Resumo';
var ABA_RESUMO_CIDADES     = 'Cópia de Resumo';
var ABA_ETAPAS             = 'Etapas';

var PLANILHA_CONFIG_URL    = 'https://docs.google.com/spreadsheets/d/1wAZTeRsbDcFL4lyLF0J9pOmtR-cGElSh93HSpMKTCww/edit';
var ABA_LIMIARES           = 'Limiares';

var PLANILHA_RESULTADOS_ID = '1FnuGm-4sZHXamsK6WtHBKOIUlIsFobhrq6rhpBTrswk';  // vazio = POST de resultado desativado
var ABA_RESULTADOS         = 'Resultados';

// Direcao de cada metrica: 'max' = menor e melhor; 'min' = maior e melhor.
var MAP_DIRECAO = {
  latencia_ms: 'max', jitter_ms: 'max', perda_percentual: 'max',
  banda_download_mbps: 'min', banda_upload_mbps: 'min', carregamento_web_s: 'max'
};

// Fallback / bootstrap (espelha config/limiares.exemplo.json).
var LIMIARES_PADRAO = {
  latencia_ms:         { viavel_ate: 60,  ressalva_ate: 120 },
  jitter_ms:           { viavel_ate: 10,  ressalva_ate: 30 },
  perda_percentual:    { viavel_ate: 1,   ressalva_ate: 5 },
  banda_download_mbps: { viavel_min: 20,  ressalva_min: 8 },
  banda_upload_mbps:   { viavel_min: 10,  ressalva_min: 4 },
  carregamento_web_s:  { viavel_ate: 5,   ressalva_ate: 12 }
};


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
    if (!PLANILHA_RESULTADOS_ID) {
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
  return saida;
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
    aba.appendRow(['metrica', 'direcao', 'limiar_viavel', 'limiar_ressalva']);
  }
  return aba;
}

// Devolve { atualizado_em, origem, limiares:{ metrica:{viavel_ate|min, ressalva_ate|min} } }
function lerLimiares() {
  var aba = _abaLimiares(false);
  var limiares = {};
  var origem = 'padrao';

  if (aba && aba.getLastRow() > 1) {
    var linhas = aba.getDataRange().getValues();
    for (var r = 1; r < linhas.length; r++) {
      var metrica = String(linhas[r][0]).trim();
      if (!MAP_DIRECAO[metrica]) continue;
      var dir = MAP_DIRECAO[metrica];
      var sv = (dir === 'max') ? 'viavel_ate' : 'viavel_min';
      var sr = (dir === 'max') ? 'ressalva_ate' : 'ressalva_min';
      var o = {};
      o[sv] = Number(linhas[r][2]);
      o[sr] = Number(linhas[r][3]);
      limiares[metrica] = o;
    }
    origem = 'planilha';
  }

  // completa com os padroes o que faltar
  for (var m in LIMIARES_PADRAO) {
    if (!limiares[m]) limiares[m] = LIMIARES_PADRAO[m];
  }

  return { atualizado_em: new Date().toISOString(), origem: origem, limiares: limiares };
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
  var linhas = [];
  for (var m in MAP_DIRECAO) {
    var dir = MAP_DIRECAO[m];
    var sv = (dir === 'max') ? 'viavel_ate' : 'viavel_min';
    var sr = (dir === 'max') ? 'ressalva_ate' : 'ressalva_min';
    var o = lim[m];
    if (!o) return { status: 'erro', erro: 'faltou a metrica ' + m };
    var v = Number(o[sv]);
    var rr = Number(o[sr]);
    if (!(v > 0) || !(rr > 0)) return { status: 'erro', erro: 'valores invalidos em ' + m };
    linhas.push([m, dir, v, rr]);
  }

  var aba = _abaLimiares(true);
  aba.getRange(2, 1, Math.max(aba.getLastRow() - 1, 1), 4).clearContent();
  aba.getRange(2, 1, linhas.length, 4).setValues(linhas);

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


/* ============================ RESULTADOS (POST) ============================ */

function gravarResultado(dados) {
  var ss  = SpreadsheetApp.openById(PLANILHA_RESULTADOS_ID);
  var aba = ss.getSheetByName(ABA_RESULTADOS) || ss.insertSheet(ABA_RESULTADOS);

  if (aba.getLastRow() === 0) {
    aba.appendRow(['recebido_em', 'tecnico', 'local_id', 'zona', 'municipio_termo', 'tipo',
      'classificacao_final', 'classificacao_automatica', 'ajustada',
      'latencia_ms', 'jitter_ms', 'perda_%', 'download_mbps', 'upload_mbps', 'carregamento_s', 'json']);
  }

  var m = dados.metricas || {};
  var l = dados.local || {};
  var c = dados.classificacao || {};
  // compat: versao antiga mandava classificacao como string
  var cFinal = (typeof c === 'string') ? c : (c.final || '');
  var cAuto  = (typeof c === 'string') ? c : (c.automatica || '');
  var cAdj   = (typeof c === 'object') ? !!c.ajustada : false;
  aba.appendRow([
    new Date(), (dados.tecnico || {}).nome || '', l.id || '', l.zona_eleitoral || '',
    l.municipio_termo || '', l.tipo || '',
    cFinal, cAuto, cAdj,
    m.latencia_ms, m.jitter_ms, m.perda_percentual,
    m.banda_download_mbps, m.banda_upload_mbps, m.carregamento_web_s,
    JSON.stringify(dados)
  ]);
}


function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
