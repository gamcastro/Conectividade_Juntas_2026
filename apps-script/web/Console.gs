/**
 * DICON Web -- console de coordenacao (ambiente de homologacao).
 * Ver docs/dicon-web-plano.md. FASE 0: Painel + Vistorias, so' leitura.
 *
 * Servido pelo Web App do mesmo projeto Apps Script (Codigo.gs > doGet, ?app=web).
 * Executa COMO O USUARIO que acessa (appsscript.json > webapp.executeAs =
 * USER_ACCESSING) -- por isso os membros da allowlist precisam de LEITOR nas
 * planilhas de referencia (Resultados de homolog, Juntas, Roteiros). Sem token
 * de servico nesta fase.
 *
 * Acesso: aba "Acesso" na planilha de Resultados (email | papel | ativo | obs).
 * Criada automaticamente no 1o uso, semeando o admin bootstrap.
 */

var WEB_ABA_ACESSO     = 'Acesso';
var WEB_BOOTSTRAP_ADMIN = 'george.castro@tre-ma.jus.br';

// Pasta raiz no Shared Drive onde a console arquiva os PDFs (relatorios/ e
// relatorios-finais/). Producao e homologacao usam pastas SEPARADAS: a Script
// Property DICON_DRIVE_ROOT (setada so' no projeto de producao) vence; sem ela,
// cai na pasta atual -- que em homolog foi renomeada para "DICON-HOMOLOG" (o
// Drive referencia por ID, nao por nome, entao renomear nao quebra nada).
function _webDriveRoot() {
  try {
    var p = PropertiesService.getScriptProperties().getProperty('DICON_DRIVE_ROOT');
    if (p && String(p).trim()) return String(p).trim();
  } catch (e) { /* usa o default */ }
  return '1ZaV3-VYAgwXJ6knuODCK6lw9FCPDjZJf';
}

// 'homologacao' | 'producao' -- o Index.html (mesmo arquivo nos dois projetos)
// usa isso pro selo e o rodape. Automatico pela planilha de Resultados; a
// Script Property DICON_AMBIENTE forca, se preciso.
var WEB_SHEET_HOMOLOG = '1aihOABaGSnHNIP5BHisR-iI1-OpQWHALLt5jvsUzpWE';
function _webAmbiente() {
  try {
    var p = PropertiesService.getScriptProperties().getProperty('DICON_AMBIENTE');
    if (p && String(p).trim()) return String(p).trim().toLowerCase();
  } catch (e) { /* ok */ }
  try { if (_idResultados() === WEB_SHEET_HOMOLOG) return 'homologacao'; } catch (e) { /* ok */ }
  return 'producao';
}

/* ============================ PAGINA ============================ */

function webConsolePagina(e) {
  var pp = (e && e.parameter) || {};
  var m = (pp.app === 'mobile') || pp.m || pp.mobile;
  return HtmlService.createHtmlOutputFromFile(m ? 'web/Mobile' : 'web/Index')
    .setTitle('DICON Web — Coordenação')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

/* ============================ ACESSO ============================ */

function _webAbaAcesso() {
  var ss = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(WEB_ABA_ACESSO);
  if (!aba) {
    aba = ss.insertSheet(WEB_ABA_ACESSO);
    aba.getRange(1, 1, 1, 4).setValues([['email', 'papel', 'ativo', 'obs']]);
    aba.getRange(2, 1, 1, 4).setValues([[WEB_BOOTSTRAP_ADMIN, 'admin', 'sim', 'bootstrap automatico']]);
    SpreadsheetApp.flush();
  }
  return aba;
}

// { email, papel: 'admin'|'leitura'|null }
function verificarAcesso() {
  var email = '';
  try { email = Session.getActiveUser().getEmail() || ''; } catch (err) { email = ''; }
  email = String(email).toLowerCase().trim();

  var papel = null;
  try {
    var v = _webAbaAcesso().getDataRange().getValues();
    for (var r = 1; r < v.length; r++) {
      if (String(v[r][0] || '').toLowerCase().trim() !== email) continue;
      var ativo = String(v[r][2] || '').toLowerCase().trim();
      if (ativo === 'nao' || ativo === 'não' || ativo === 'false' || ativo === '0' || ativo === '') break;
      papel = String(v[r][1] || 'leitura').toLowerCase().trim() || 'leitura';
      break;
    }
  } catch (err) { /* aba inacessivel: cai no bootstrap abaixo */ }

  if (!papel && email && email === WEB_BOOTSTRAP_ADMIN) papel = 'admin';
  return { email: email, papel: papel };
}

// Lanca 'SEM_ACESSO' se o usuario nao tem o papel minimo. Devolve o acesso.
function _webExigirAcesso(papelMin) {
  var a = verificarAcesso();
  var ordem = { 'leitura': 1, 'admin': 2 };
  var minimo = ordem[papelMin || 'leitura'] || 1;
  if (!a.papel || (ordem[a.papel] || 0) < minimo) throw new Error('SEM_ACESSO');
  return a;
}

/* -------- gestao da allowlist (papel admin) -------- */

function listarAcesso() {
  var acesso = _webExigirAcesso('admin');
  var token = _tokenServico();
  var sheetId = _idResultados();
  _sheetsGarantirAba(token, sheetId, WEB_ABA_ACESSO, ['email', 'papel', 'ativo', 'obs']);
  var v = _sheetsGetValores(token, sheetId, WEB_ABA_ACESSO);
  var linhas = (v || []).slice(1)
    .filter(function (r) { return String(r[0] || '').trim(); })
    .map(function (r) {
      var ativoRaw = String(r[2] || '').toLowerCase().trim();
      return {
        email: String(r[0] || '').trim(),
        papel: (String(r[1] || '').toLowerCase().trim() === 'admin') ? 'admin' : 'leitura',
        ativo: !(ativoRaw === 'nao' || ativoRaw === 'não' || ativoRaw === 'false' || ativoRaw === '0' || ativoRaw === ''),
        obs: String(r[3] || '')
      };
    });
  return { acesso: acesso, linhas: linhas, bootstrap: String(WEB_BOOTSTRAP_ADMIN).toLowerCase() };
}

function salvarAcesso(req) {
  _webExigirAcesso('admin');
  req = req || {};
  var email = String(req.email || '').toLowerCase().trim();
  if (!email || email.indexOf('@') < 1) throw new Error('e-mail invalido');
  var papel = (String(req.papel || '').toLowerCase().trim() === 'admin') ? 'admin' : 'leitura';
  var ativo = (req.ativo === false) ? 'nao' : 'sim';

  var token = _tokenServico();
  var sheetId = _idResultados();
  _sheetsGarantirAba(token, sheetId, WEB_ABA_ACESSO, ['email', 'papel', 'ativo', 'obs']);
  var v = _sheetsGetValores(token, sheetId, WEB_ABA_ACESSO);
  var rowNum = -1, obs = req.obs != null ? String(req.obs) : '';
  for (var r = 1; r < v.length; r++) {
    if (String(v[r][0] || '').toLowerCase().trim() === email) {
      rowNum = r + 1;
      if (req.obs == null) obs = String(v[r][3] || '');
      break;
    }
  }
  var linha = [email, papel, ativo, obs];
  if (rowNum > 0) _sheetsSetValores(token, sheetId, WEB_ABA_ACESSO + '!A' + rowNum + ':D' + rowNum, [linha]);
  else _sheetsAppendLinha(token, sheetId, WEB_ABA_ACESSO, linha);
  return { ok: true };
}

// "desativar" -- marca ativo=nao mantendo papel/obs (nao apaga a linha).
function removerAcesso(email) {
  _webExigirAcesso('admin');
  email = String(email || '').toLowerCase().trim();
  if (!email) throw new Error('e-mail ausente');
  if (email === String(WEB_BOOTSTRAP_ADMIN).toLowerCase()) throw new Error('o administrador inicial nao pode ser desativado');
  var token = _tokenServico();
  var sheetId = _idResultados();
  var v = _sheetsGetValores(token, sheetId, WEB_ABA_ACESSO);
  for (var r = 1; r < v.length; r++) {
    if (String(v[r][0] || '').toLowerCase().trim() === email) {
      _sheetsSetValores(token, sheetId, WEB_ABA_ACESSO + '!A' + (r + 1) + ':D' + (r + 1),
        [[email, String(v[r][1] || 'leitura'), 'nao', String(v[r][3] || '')]]);
      break;
    }
  }
  return { ok: true };
}

/* ======================= UNIVERSO x TESTADOS ======================= */

// Todos os Locais que DEVEM ser testados (uniao dos juntas_ids dos roteiros),
// com os dados do Local e o tecnico/roteiro previsto. Um Local aparece uma vez.
function _webUniverso() {
  var byId = {};
  listarJuntas().forEach(function (j) { byId[j.id] = j; });

  var out = [];
  var visto = {};
  listarRoteiros().forEach(function (r) {
    (r.juntas_ids || []).forEach(function (id) {
      if (visto[id]) return;
      var j = byId[id];
      if (!j) return;
      visto[id] = true;
      out.push({
        local_id: id,
        zona: j.zona_eleitoral,
        municipio: j.municipio_termo,
        sede: j.municipio_sede,
        tipo: j.tipo,
        nome: j.nome,
        endereco: j.endereco,
        roteiro: r.numero,
        roteiro_rotulo: r.rotulo,
        tecnico_previsto: r.tecnico
      });
    });
  });
  return out;
}

// Data (string "dd/MM/yyyy HH:mm:ss" OU objeto Date do getValues()) -> texto
// amigavel "dd/MM/yyyy HH:mm". Reusa _webParseData / _webHora (Console.gs Fase 1).
function _webDataAmigavel(v) {
  var d = _webParseData(v);
  if (!d) return String(v || '');
  return Utilities.formatDate(d, Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm');
}

// Mapa local_id -> ultimo resultado transmitido (linha mais recente da aba
// Resultados; append-only, entao a linha de maior indice vence).
function _webTestados() {
  var out = {};
  var ss = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(ABA_RESULTADOS);
  if (!aba || aba.getLastRow() < 2) return out;

  var v = aba.getDataRange().getValues();
  var ix = {};
  v[0].forEach(function (c, i) { ix[String(c || '').trim()] = i; });
  function cel(row, nome) { var i = ix[nome]; return (i == null) ? '' : row[i]; }

  for (var r = 1; r < v.length; r++) {
    var row = v[r];
    var id = String(cel(row, 'local_id') || '').trim();
    if (!id) continue;
    out[id] = {
      local_id: id,
      recebido_em: _webDataAmigavel(cel(row, 'recebido_em')),
      tecnico: String(cel(row, 'tecnico') || ''),
      conexao_recomendada: String(cel(row, 'conexao_recomendada') || ''),
      operadora_recomendada: String(cel(row, 'operadora_recomendada') || ''),
      download_mbps: cel(row, 'download_mbps'),
      latencia_ms: cel(row, 'latencia_ms'),
      perda: cel(row, 'perda_%'),
      pdf_url: String(cel(row, 'pdf_url') || cel(row, 'pdf_drive_id') || '')
    };
  }
  return out;
}

/* ============================ PAINEL ============================ */

function _webAcc(m, k, ok) {
  k = k || '(sem)';
  if (!m[k]) m[k] = { feitos: 0, total: 0 };
  m[k].total++;
  if (ok) m[k].feitos++;
}
function _webOrdena(m) {
  return Object.keys(m).sort().map(function (k) {
    var o = m[k];
    return { rotulo: k, feitos: o.feitos, total: o.total, pct: o.total ? Math.round(o.feitos * 100 / o.total) : 0 };
  });
}

// Uma chamada so': acesso + resumo + agregados + a lista de vistorias.
// Sem acesso -> devolve { acesso, sem_acesso: true } (o cliente mostra a tela
// "sem permissao" com o e-mail); nao lanca.
//
// O corpo pesado (universo x testados) e' IGUAL pra todos os coordenadores ->
// cache de ~45 s no CacheService (o `acesso`, esse sim por e-mail, vai fresco).
// `forcar` (botao Atualizar) pula o cache.
function carregarPainel(forcar) {
  var acesso = verificarAcesso();
  if (!acesso.papel) return { acesso: acesso, sem_acesso: true };

  var cache = null;
  try { cache = CacheService.getScriptCache(); } catch (e) { cache = null; }
  if (cache && !forcar) {
    var hit = cache.get('painel_v2');
    if (hit) {
      try { var o = JSON.parse(hit); o.acesso = acesso; o.cache = true; return o; } catch (e) { /* recomputa */ }
    }
  }

  var corpo = _carregarPainelCorpo();
  if (cache) {
    try {
      var s = JSON.stringify(corpo);
      if (s.length < 95000) cache.put('painel_v2', s, 45);
    } catch (e) { /* cache e' opcional */ }
  }
  corpo.acesso = acesso;
  corpo.ambiente = _webAmbiente();
  return corpo;
}

function _carregarPainelCorpo() {
  var universo = _webUniverso();
  var testados = _webTestados();

  var linhas = universo.map(function (u) {
    var t = testados[u.local_id];
    return {
      local_id: u.local_id,
      zona: u.zona,
      municipio: u.municipio,
      sede: u.sede,
      tipo: u.tipo,
      nome: u.nome,
      roteiro: u.roteiro,
      roteiro_rotulo: u.roteiro_rotulo,
      tecnico_previsto: u.tecnico_previsto,
      testado: !!t,
      quando: t ? t.recebido_em : '',
      tecnico: t ? t.tecnico : '',
      conexao: t ? (t.conexao_recomendada + (t.operadora_recomendada ? ' (' + t.operadora_recomendada + ')' : '')) : '',
      download_mbps: t ? t.download_mbps : '',
      latencia_ms: t ? t.latencia_ms : '',
      perda: t ? t.perda : '',
      pdf_url: t ? t.pdf_url : ''
    };
  });

  var total = linhas.length;
  var feitos = 0;
  var porRoteiro = {}, porZE = {}, porMun = {}, porTecnico = {};
  linhas.forEach(function (l) {
    if (l.testado) feitos++;
    _webAcc(porRoteiro, l.roteiro_rotulo || ('Roteiro ' + l.roteiro), l.testado);
    _webAcc(porZE, 'ZE ' + l.zona, l.testado);
    _webAcc(porMun, l.municipio, l.testado);
    _webAcc(porTecnico, l.tecnico_previsto, l.testado);
  });

  return {
    resumo: {
      total: total, feitos: feitos, pendentes: total - feitos,
      pct: total ? Math.round(feitos * 100 / total) : 0
    },
    por_roteiro: _webOrdena(porRoteiro),
    por_tecnico: _webOrdena(porTecnico),
    por_ze: _webOrdena(porZE),
    por_municipio: _webOrdena(porMun),
    vistorias: linhas,
    gerado_em: new Date().toISOString()
  };
}

/* ============================ MAPA ============================ */
/* Aba "Mapa" da console. So' leitura, chamada por google.script.run -> redeploy
 * do Web App apenas (nao mexe em Codigo.gs > executar). Duas camadas:
 *
 *  - CHOROPLETH por municipio (malha do IBGE -- web/MalhaMA.gs / carregarMalhaMA):
 *    cada municipio com junta e' pintado pelo andamento dos testes -- verde
 *    (todos os locais testados) / laranja (parcial) / vermelho (nenhum); borda
 *    amarela grossa quando o municipio e' sede de alguma ZE; cinza claro nos
 *    demais. O de-para nome->codigo IBGE e' por nome normalizado (sem acento,
 *    so' letras/numeros); nomes que nao casarem vao em `municipios_sem_codigo`.
 *  - PINOS do GEL: Locais cujo formulario do GEL trouxe latitude/longitude
 *    (1) aba GEL, coluna gel_json; (2) reserva -- bloco vistoria_gel do json
 *    transmitido na aba Resultados. Ficam por cima do choropleth.
 *
 * A chave do Maps JS fica na Script Property GOOGLE_MAPS_JS_KEY (so' o George/GCP
 * configura); sem ela a aba mostra um aviso e a contagem de pendentes. */

// Caixa envolvente do Maranhao (folgada) -- descarta (0,0) e coordenada fora do estado.
var WEB_MA_BBOX = { latMin: -10.6, latMax: -0.5, lonMin: -49.5, lonMax: -41.0 };

function _webNumCoord(v) {
  if (v == null || v === '') return null;
  var n = Number(String(v).replace(',', '.').trim());
  return isFinite(n) ? n : null;
}
function _webCoordNoMA(lat, lon) {
  if (typeof lat !== 'number' || typeof lon !== 'number') return false;
  if (!isFinite(lat) || !isFinite(lon) || (lat === 0 && lon === 0)) return false;
  return lat >= WEB_MA_BBOX.latMin && lat <= WEB_MA_BBOX.latMax &&
         lon >= WEB_MA_BBOX.lonMin && lon <= WEB_MA_BBOX.lonMax;
}

// local_id -> { lat, lon, gel_em, fonte }. Aba GEL primeiro; o que faltar,
// tenta no vistoria_gel do json da aba Resultados.
function _webCoordenadasGel() {
  var out = {};
  var token = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) return out;

  // 1) aba GEL (coluna gel_json = data/vistoria-gel/<id>.json do desktop)
  try {
    var v = _sheetsGetValores(token, sheetId, ABA_GEL);
    if (v && v.length >= 2) {
      var head = v[0].map(function (c) { return String(c || '').trim(); });
      var ix = {}; head.forEach(function (n, i) { ix[n] = i; });
      for (var r = 1; r < v.length; r++) {
        var id = String(v[r][ix['local_id']] || '').trim();
        if (!id) continue;
        var g = null;
        try { g = JSON.parse(String(v[r][ix['gel_json']] || '')); } catch (e) { g = null; }
        if (!g) continue;
        var lat = _webNumCoord(g.lat != null ? g.lat : g.latitude);
        var lon = _webNumCoord(g.long != null ? g.long : g.longitude);
        if (!_webCoordNoMA(lat, lon)) continue;
        out[id] = { lat: lat, lon: lon, gel_em: String(v[r][ix['atualizado_em']] || ''), fonte: 'gel' };
      }
    }
  } catch (e) { /* a aba GEL pode nem existir ainda */ }

  // 2) reserva: vistoria_gel dentro do json da aba Resultados
  try {
    var ss = SpreadsheetApp.openById(sheetId);
    var aba = ss.getSheetByName(ABA_RESULTADOS);
    if (aba && aba.getLastRow() >= 2) {
      var vv = aba.getDataRange().getValues();
      var ixr = {}; vv[0].forEach(function (c, i) { ixr[String(c || '').trim()] = i; });
      var ixId = ixr['local_id'], ixJson = ixr['json'], ixReceb = ixr['recebido_em'];
      for (var k = 1; k < vv.length; k++) {
        var lid = String(vv[k][ixId] || '').trim();
        if (!lid || out[lid]) continue;
        var blob = null;
        try { blob = JSON.parse(String(vv[k][ixJson] || '')); } catch (e) { blob = null; }
        var vg = blob && blob.vistoria_gel;
        if (!vg) continue;
        var la = _webNumCoord(vg.latitude != null ? vg.latitude : vg.lat);
        var lo = _webNumCoord(vg.longitude != null ? vg.longitude : vg.long);
        if (!_webCoordNoMA(la, lo)) continue;
        out[lid] = { lat: la, lon: lo, gel_em: _webDataAmigavel(vv[k][ixReceb]), fonte: 'resultado' };
      }
    }
  } catch (e) { /* ok -- segue so' com o que a aba GEL deu */ }

  return out;
}

// Nome -> chave normalizada (minusculo, sem acento, so' [a-z0-9]) -- casa
// "Pindaré-Mirim" com "pindare mirim", "Zé Doca" com "ze doca", etc.
function _webNormNome(s) {
  s = String(s == null ? '' : s);
  try { s = s.normalize('NFD'); } catch (e) { /* V8 tem normalize */ }
  var out = '';
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c >= 0x300 && c <= 0x36f) continue;              // marca de acento (forma NFD)
    var ch = s.charAt(i).toLowerCase();
    if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) out += ch;
  }
  return out;
}

// { normNome: {cod, nome} } a partir da malha do IBGE (carregarMalhaMA).
// Memoizado na execucao (a malha tem ~135 KB).
var _WEB_MALHA_IDX = null;
function _webMalhaCodPorNome() {
  if (_WEB_MALHA_IDX) return _WEB_MALHA_IDX;
  var idx = {};
  try {
    var fc = JSON.parse(carregarMalhaMA());
    (fc.features || []).forEach(function (f) {
      var p = f.properties || {};
      var k = _webNormNome(p.nome);
      if (k) idx[k] = { cod: String(p.cod || ''), nome: String(p.nome || '') };
    });
  } catch (e) { /* sem malha -> so' pinos, sem choropleth */ }
  _WEB_MALHA_IDX = idx;
  return idx;
}

// Estrutura das Zonas Eleitorais -- aba "Zonas e Termos" da planilha corporativa
// "Zonas Eleitorais" (colunas ZONA | SEDE | TERMO, 1 linha por termo de cada ZE;
// uma sede pode ter varias ZEs). Regra: quando SEDE == TERMO na linha, aquele
// municipio conta so' como SEDE (nao como termo). Lida pelo TOKEN DE SERVICO
// (como o George) -- os coordenadores nao precisam de acesso a essa planilha.
// Sem acesso -> {} e o mapa cai pro modo "so' junta".
//   -> { porCod: {cod:{cod,nome,ze_sede{},ze_termo{},sede_nome}}, sem_codigo:{} }
var WEB_ZE_SHEET = '1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I';
var WEB_ZE_ABA   = 'Zonas e Termos';
function _webEstruturaZE() {
  var idx = _webMalhaCodPorNome();
  var out = { porCod: {}, sem_codigo: {} };
  var tok = _tokenServico(), rows;
  try { rows = _sheetsGetValores(tok, WEB_ZE_SHEET, "'" + WEB_ZE_ABA + "'"); }
  catch (e1) {
    try { rows = _sheetsGetValores(tok, WEB_ZE_SHEET, WEB_ZE_ABA); }
    catch (e2) { return out; }
  }
  if (!rows || !rows.length) return out;

  // acha a linha de cabecalho (ZONA / SEDE / TERMO, em qualquer ordem)
  var hi = -1, cZ = 0, cS = 1, cT = 2;
  for (var r = 0; r < Math.min(rows.length, 12); r++) {
    var norm = (rows[r] || []).map(function (c) { return _webNormNome(c); });
    var iz = norm.indexOf('zona'), is = norm.indexOf('sede'), it = norm.indexOf('termo');
    if (iz >= 0 && is >= 0 && it >= 0) { hi = r; cZ = iz; cS = is; cT = it; break; }
  }
  if (hi < 0) hi = 0;

  function ensure(cod, nome) {
    if (!out.porCod[cod]) out.porCod[cod] = { cod: cod, nome: nome, ze_sede: {}, ze_termo: {}, sede_nome: '' };
    return out.porCod[cod];
  }
  for (var k = hi + 1; k < rows.length; k++) {
    var row = rows[k] || [];
    var ze   = String(row[cZ] == null ? '' : row[cZ]).trim();
    var sede = String(row[cS] || '').trim();
    var termo = String(row[cT] || '').trim();
    if (!ze && !sede && !termo) continue;
    var ms = idx[_webNormNome(sede)];
    var mt = idx[_webNormNome(termo)];
    if (sede && !ms) out.sem_codigo[sede] = true;
    if (termo && !mt) out.sem_codigo[termo] = true;
    if (ms) { var es = ensure(ms.cod, ms.nome); if (ze) es.ze_sede[ze] = true; }
    // termo so' quando for municipio DIFERENTE da sede
    if (mt && (!ms || mt.cod !== ms.cod)) {
      var et = ensure(mt.cod, mt.nome);
      if (ze) et.ze_termo[ze] = true;
      if (sede) et.sede_nome = ms ? ms.nome : sede;   // nome canonico do IBGE quando casou
    }
  }
  return out;
}

// Agrega TODO municipio que aparece na estrutura das ZEs (sede ou termo) ou que
// hospeda junta, com a categoria pro choropleth:
//   sede_junta  = sede de ZE cujo(s) termo(s) -- ou ela mesma -- tem junta especial
//   sede        = sede de ZE sem nenhuma junta na(s) sua(s) ZE(s)
//   termo_junta = termo (nao sede) que hospeda junta especial
//   termo       = termo (nao sede) sem junta
//   outro       = fora da estrutura (nao devia acontecer)
// `locais[]` alimenta a opacidade por andamento e a lista da janelinha: pra sede,
// sao os locais de TODAS as ZEs dela; pra termo, os locais dele. Nomes que nao
// casaram com a malha -> `sem_codigo`.
function _webMunicipiosMapa(universo, testados) {
  var idx = _webMalhaCodPorNome();
  var est = _webEstruturaZE();
  var semCodigo = {};
  Object.keys(est.sem_codigo).forEach(function (n) { semCodigo[n] = true; });

  // cod -> [locais de junta] ;  ze (numero) -> [locais de junta daquela ZE]
  var juntaLocais = {}, juntaNome = {}, juntaPorZE = {};
  Object.keys(universo).forEach(function (id) {
    var u = universo[id];
    var mt = idx[_webNormNome(u.municipio)];
    if (!mt) { if (u.municipio) semCodigo[String(u.municipio)] = true; return; }
    var t = testados[id];
    var loc = {
      local_id: id, nome: u.nome || id, zona: String(u.zona || '').trim(), tipo: u.tipo || '',
      roteiro_rotulo: u.roteiro_rotulo || (u.roteiro ? ('Roteiro ' + u.roteiro) : ''),
      testado: !!t, quando: t ? t.recebido_em : '', tecnico: t ? t.tecnico : ''
    };
    juntaNome[mt.cod] = mt.nome;
    (juntaLocais[mt.cod] = juntaLocais[mt.cod] || []).push(loc);
    if (loc.zona) (juntaPorZE[loc.zona] = juntaPorZE[loc.zona] || []).push(loc);
  });

  var cods = {};
  Object.keys(est.porCod).forEach(function (c) { cods[c] = true; });
  Object.keys(juntaLocais).forEach(function (c) { cods[c] = true; });

  var lista = Object.keys(cods).map(function (cod) {
    var e = est.porCod[cod] || { cod: cod, nome: juntaNome[cod] || cod, ze_sede: {}, ze_termo: {}, sede_nome: '' };
    var zesSede = Object.keys(e.ze_sede);
    var zesTermo = Object.keys(e.ze_termo);
    var ehSede = zesSede.length > 0;
    var ehTermo = zesTermo.length > 0;
    var proprios = juntaLocais[cod] || [];

    var categoria, locais;
    if (ehSede) {
      // locais de todas as ZEs de que este municipio e' sede (+ os proprios), sem repetir
      var vistos = {}, acc = [];
      proprios.concat.apply(proprios, zesSede.map(function (z) { return juntaPorZE[z] || []; }))
        .forEach(function (l) { if (!vistos[l.local_id]) { vistos[l.local_id] = 1; acc.push(l); } });
      locais = acc;
      categoria = acc.length ? 'sede_junta' : 'sede';
    } else if (ehTermo) {
      locais = proprios;
      categoria = proprios.length ? 'termo_junta' : 'termo';
    } else {
      locais = proprios;
      categoria = proprios.length ? 'termo_junta' : 'outro';
    }

    return {
      cod: cod, nome: e.nome || cod, categoria: categoria,
      ze_sede: zesSede.sort(function (a, b) { return (+a) - (+b); }),
      ze_termo: zesTermo.sort(function (a, b) { return (+a) - (+b); }),
      sede_nome: e.sede_nome || '',
      locais: locais
    };
  });
  return { municipios: lista, sem_codigo: Object.keys(semCodigo).sort() };
}

// Uma chamada: acesso + choropleth por municipio + pinos do GEL + a chave do
// Maps. Sem acesso -> { acesso, sem_acesso:true }. Corpo pesado em cache de 60 s
// (a chave e o acesso vao frescos). `forcar` pula o cache.
function carregarMapa(forcar) {
  var acesso = verificarAcesso();
  if (!acesso.papel) return { acesso: acesso, sem_acesso: true };

  var mapsKey = '';
  try { mapsKey = PropertiesService.getScriptProperties().getProperty('GOOGLE_MAPS_JS_KEY') || ''; } catch (e) { mapsKey = ''; }

  var cache = null;
  try { cache = CacheService.getScriptCache(); } catch (e) { cache = null; }
  if (cache && !forcar) {
    var hit = cache.get('mapa_v5');
    if (hit) {
      try {
        var o = JSON.parse(hit);
        o.acesso = acesso; o.maps_key = mapsKey; o.cache = true;
        return o;
      } catch (e) { /* recomputa */ }
    }
  }

  var universo = {};
  _webUniverso().forEach(function (u) { universo[u.local_id] = u; });
  var testados = _webTestados();
  var coords = _webCoordenadasGel();
  var mm = _webMunicipiosMapa(universo, testados);

  var pontos = [];
  Object.keys(coords).forEach(function (id) {
    var c = coords[id];
    var u = universo[id] || {};
    var t = testados[id];
    pontos.push({
      local_id: id,
      nome: u.nome || id,
      zona: u.zona || '',
      municipio: u.municipio || '',
      tipo: u.tipo || '',
      roteiro: u.roteiro || '',
      roteiro_rotulo: u.roteiro_rotulo || (u.roteiro ? ('Roteiro ' + u.roteiro) : ''),
      tecnico_previsto: u.tecnico_previsto || '',
      lat: c.lat, lng: c.lon,
      gel_em: c.gel_em || '',
      fonte: c.fonte || '',
      testado: !!t,
      quando: t ? t.recebido_em : '',
      tecnico: t ? t.tecnico : '',
      conexao: t ? (t.conexao_recomendada + (t.operadora_recomendada ? ' (' + t.operadora_recomendada + ')' : '')) : '',
      download_mbps: t ? t.download_mbps : '',
      latencia_ms: t ? t.latencia_ms : '',
      pdf_url: t ? t.pdf_url : ''
    });
  });
  pontos.sort(function (a, b) { return (a.municipio < b.municipio) ? -1 : (a.municipio > b.municipio) ? 1 : 0; });

  var corpo = {
    pontos: pontos,
    municipios: mm.municipios,
    municipios_sem_codigo: mm.sem_codigo,
    total_universo: Object.keys(universo).length,
    com_coord: pontos.length,
    gerado_em: new Date().toISOString()
  };
  if (cache) {
    try { var s = JSON.stringify(corpo); if (s.length < 95000) cache.put('mapa_v5', s, 60); } catch (e) { /* cache e' opcional */ }
  }
  corpo.acesso = acesso;
  corpo.ambiente = _webAmbiente();
  corpo.maps_key = mapsKey;
  return corpo;
}

/* ==================== FASE 1: CHECK-IN AO VIVO ==================== */
/* Escrita: webCheckin / webRegistrarEvento -- chamadas pela Execution API
 * (Codigo.gs > executar), gravadas com o TOKEN DE SERVICO (o tecnico nao e'
 * editor da planilha). Leitura: carregarAoVivo -- chamada pela console
 * (google.script.run), como o usuario logado (leitor). */

var WEB_HEAD_PRESENCA = ['tecnico', 'email', 'ultimo_checkin', 'versao_dicon', 'roteiro', 'maquina', 'atividade_atual', 'local_atual', 'municipio_atual', 'zona_atual'];
var WEB_HEAD_EVENTOS  = ['id_evento', 'hora_cliente', 'hora_servidor', 'tecnico', 'tipo', 'local_id', 'zona', 'municipio', 'tipo_local', 'roteiro', 'detalhe'];

function _webAgora() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm:ss');
}

// Cria a aba (com cabecalho) se nao existir. Via token de servico -> o dono da
// planilha e' quem cria, entao funciona mesmo com o tecnico chamando.
function _sheetsGarantirAba(token, sheetId, nome, cabecalho) {
  try {
    _sheetsGetValores(token, sheetId, nome + '!1:1');
    return;
  } catch (e) {
    var url = 'https://sheets.googleapis.com/v4/spreadsheets/' + sheetId + ':batchUpdate';
    var resp = UrlFetchApp.fetch(url, {
      method: 'post', muteHttpExceptions: true, contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + token },
      payload: JSON.stringify({ requests: [{ addSheet: { properties: { title: nome } } }] })
    });
    if (resp.getResponseCode() >= 300 && String(resp.getContentText()).indexOf('already exists') < 0) {
      throw new Error('Sheets addSheet ' + nome + ': ' + resp.getContentText());
    }
    _sheetsSetValores(token, sheetId, nome + '!A1', [cabecalho]);
  }
}

// upsert de 1 linha na aba Presenca, casando por email (ou nome).
function _webPresencaUpsert(token, sheetId, campos) {
  _sheetsGarantirAba(token, sheetId, 'Presenca', WEB_HEAD_PRESENCA);
  var v = _sheetsGetValores(token, sheetId, 'Presenca');
  var head = (v[0] || WEB_HEAD_PRESENCA).map(function (c) { return String(c || '').trim(); });
  // aba antiga com menos colunas -> estende o cabecalho (municipio_atual/zona_atual)
  if (head.length < WEB_HEAD_PRESENCA.length) {
    _sheetsSetValores(token, sheetId, 'Presenca!A1', [WEB_HEAD_PRESENCA]);
    head = WEB_HEAD_PRESENCA.slice();
  }
  var ix = {}; head.forEach(function (n, i) { ix[n] = i; });

  var alvoEmail = String(campos.email || '').toLowerCase().trim();
  var alvoNome  = String(campos.tecnico || '').toLowerCase().trim();
  var rowNum = -1;
  for (var r = 1; r < v.length; r++) {
    var e = String(v[r][ix['email']] || '').toLowerCase().trim();
    var n = String(v[r][ix['tecnico']] || '').toLowerCase().trim();
    if ((alvoEmail && e === alvoEmail) || (!alvoEmail && alvoNome && n === alvoNome)) { rowNum = r + 1; break; }
  }

  var atual = (rowNum > 0) ? v[rowNum - 1] : [];
  // merge padrao: so' sobrescreve com valor "cheio" (heartbeat nao apaga identidade)
  function val(nome, novo) {
    if (novo !== undefined && novo !== null && novo !== '') return novo;
    var i = ix[nome];
    return (i != null && atual[i] != null) ? atual[i] : '';
  }
  // estado do diagnostico em andamento: uma string vazia EXPLICITA limpa
  // (fim do diagnostico); undefined = nao mexe (evento que nao e' de estado).
  function estado(nome) {
    var novo = campos[nome];
    if (novo === undefined) { var i = ix[nome]; return (i != null && atual[i] != null) ? atual[i] : ''; }
    return (novo == null) ? '' : String(novo);
  }
  var linha = [
    val('tecnico', campos.tecnico), val('email', campos.email), _webAgora(),
    val('versao_dicon', campos.versao_dicon), val('roteiro', campos.roteiro),
    val('maquina', campos.maquina), val('atividade_atual', campos.atividade_atual),
    val('local_atual', campos.local_atual),
    estado('municipio_atual'), estado('zona_atual')
  ];
  var colFim = _colA1(WEB_HEAD_PRESENCA.length);   // 'J'
  if (rowNum > 0) _sheetsSetValores(token, sheetId, 'Presenca!A' + rowNum + ':' + colFim + rowNum, [linha]);
  else _sheetsAppendLinha(token, sheetId, 'Presenca', linha);
}

// acao 'checkin' -- heartbeat. req: {tecnico, email, versao_dicon, roteiro, maquina}
function webCheckin(req) {
  req = req || {};
  var token = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) return { status: 'ignorado', motivo: 'PLANILHA_RESULTADOS_ID nao configurado' };
  _webPresencaUpsert(token, sheetId, {
    tecnico: req.tecnico, email: req.email, versao_dicon: req.versao_dicon,
    roteiro: req.roteiro, maquina: req.maquina
  });
  return { status: 'ok', hora: _webAgora() };
}

// acao 'evento'. req: {id_evento, hora_cliente, tecnico, email, tipo, local_id,
// zona, municipio, tipo_local, roteiro, detalhe, versao_dicon, maquina}
function webRegistrarEvento(req) {
  req = req || {};
  var token = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) return { status: 'ignorado', motivo: 'PLANILHA_RESULTADOS_ID nao configurado' };

  _sheetsGarantirAba(token, sheetId, 'Eventos', WEB_HEAD_EVENTOS);

  if (req.id_evento) {
    var ids = _sheetsGetValores(token, sheetId, 'Eventos!A2:A');
    for (var i = 0; i < ids.length; i++) {
      if (String(ids[i][0] || '') === String(req.id_evento)) return { status: 'ok', dedupe: true };
    }
  }

  _sheetsAppendLinha(token, sheetId, 'Eventos', [
    req.id_evento || '', req.hora_cliente || '', _webAgora(), req.tecnico || '',
    req.tipo || '', req.local_id || '', req.zona || '', req.municipio || '',
    req.tipo_local || '', req.roteiro || '', req.detalhe || ''
  ]);

  // reflete no card do tecnico
  var atividade = '', local = '', muniAtual, zonaAtual;
  if (req.tipo === 'iniciou_diagnostico') {
    atividade = 'Diagnostico em ' + (req.detalhe || req.local_id || '') + ' desde ' + _webAgora();
    local = req.local_id || '';
    muniAtual = String(req.municipio || '');   // preenche o "onde" do card
    zonaAtual = String(req.zona || '');
  } else if (req.tipo === 'transmitiu' || req.tipo === 'finalizou' || req.tipo === 'abandonou') {
    atividade = (req.tipo === 'finalizou' ? 'Concluiu ' : (req.tipo === 'transmitiu' ? 'Transmitiu ' : 'Saiu de ')) +
                (req.detalhe || req.local_id || '') + ' as ' + _webAgora();
    local = '';
    muniAtual = ''; zonaAtual = '';            // acabou -> limpa o "onde"
  }
  // outros tipos (rodou_checagem, salvou, ...): muniAtual/zonaAtual ficam undefined -> nao mexe
  try {
    _webPresencaUpsert(token, sheetId, {
      tecnico: req.tecnico, email: req.email, versao_dicon: req.versao_dicon,
      roteiro: req.roteiro, maquina: req.maquina,
      atividade_atual: atividade || undefined,
      local_atual: (req.tipo === 'iniciou_diagnostico') ? local : '',
      municipio_atual: muniAtual, zona_atual: zonaAtual
    });
  } catch (e) { /* presenca e' secundaria */ }

  return { status: 'ok' };
}

/* ---- leitura para a console ---- */

function _webLerAba(ss, nome) {
  var aba = ss.getSheetByName(nome);
  if (!aba || aba.getLastRow() < 2) return [];
  var v = aba.getDataRange().getValues();
  var head = v[0].map(function (c) { return String(c || '').trim(); });
  return v.slice(1).map(function (row) {
    var o = {};
    head.forEach(function (h, i) { o[h] = row[i]; });
    return o;
  });
}

function _webParseData(s) {
  if (s instanceof Date) { return isNaN(s.getTime()) ? null : s; }
  s = String(s || '').trim();
  var m = s.match(/^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) { var d = new Date(s); return isNaN(d.getTime()) ? null : d; }
  return new Date(+m[3], +m[2] - 1, +m[1], +m[4], +m[5], +(m[6] || 0));
}

// Data (string "dd/MM/yyyy HH:mm:ss" OU objeto Date do Sheets) -> "dd/MM HH:mm".
function _webHora(v) {
  var d = _webParseData(v);
  if (!d) { return String(v || ''); }
  return Utilities.formatDate(d, Session.getScriptTimeZone(), 'dd/MM HH:mm');
}

// Aba "Ao vivo" da console: presenca (online se <=10 min) + feed de eventos.
function carregarAoVivo() {
  var acesso = verificarAcesso();
  if (!acesso.papel) return { acesso: acesso, sem_acesso: true };

  var ss = SpreadsheetApp.openById(_idResultados());
  var agora = new Date();

  var presencas = _webLerAba(ss, 'Presenca').map(function (p) {
    var visto = _webParseData(p['ultimo_checkin']);
    var min = visto ? Math.round((agora - visto) / 60000) : null;
    return {
      tecnico: p['tecnico'], email: p['email'], roteiro: p['roteiro'],
      versao_dicon: p['versao_dicon'], atividade_atual: String(p['atividade_atual'] || ''),
      local_atual: p['local_atual'],
      municipio_atual: String(p['municipio_atual'] || ''), zona_atual: String(p['zona_atual'] || ''),
      ultimo_checkin: _webHora(p['ultimo_checkin']),
      minutos: min, online: (min != null && min <= 10)
    };
  }).sort(function (a, b) {
    return (a.minutos == null ? 1e9 : a.minutos) - (b.minutos == null ? 1e9 : b.minutos);
  });

  var evs = _webLerAba(ss, 'Eventos');
  var feed = evs.slice(-100).reverse().map(function (e) {
    return {
      hora: _webHora(e['hora_cliente'] || e['hora_servidor']),
      tecnico: e['tecnico'], tipo: e['tipo'], local_id: e['local_id'],
      zona: e['zona'], municipio: e['municipio'], tipo_local: e['tipo_local'],
      roteiro: e['roteiro'], detalhe: e['detalhe']
    };
  });

  return { acesso: acesso, presencas: presencas, eventos: feed, gerado_em: agora.toISOString() };
}
