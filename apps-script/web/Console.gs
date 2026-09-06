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
// Pasta raiz "DICON" no Shared Drive da coordenacao. AINDA NAO USADA: escrever
// no Drive daqui exigiria o escopo 'drive' no manifest, e a Execution API que o
// DICON de campo usa exige que o token do DICON tenha TODOS os escopos do
// script (o do DICON so' tem 'spreadsheets'). Fica para a Fase 4, quando o
// token de servico tiver 'drive'. Por ora, o relatorio final e' baixado pelo
// navegador (ver web/RelatorioFinal.gs).
var WEB_DRIVE_ROOT = '1ZaV3-VYAgwXJ6knuODCK6lw9FCPDjZJf';

/* ============================ PAGINA ============================ */

function webConsolePagina(e) {
  return HtmlService.createHtmlOutputFromFile('web/Index')
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
      recebido_em: String(cel(row, 'recebido_em') || ''),
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
  return corpo;
}

function _carregarPainelCorpo() {
  var universo = _webUniverso();
  var testados = _webTestados();
  var gelWeb   = _webGelWeb();

  var linhas = universo.map(function (u) {
    var t = testados[u.local_id];
    var gw = gelWeb[u.local_id];
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
      pdf_url: t ? t.pdf_url : '',
      gel_web: !!(gw && gw.secoes),
      gel_web_quando: gw ? gw.quando : ''
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

/* ==================== FASE 1: CHECK-IN AO VIVO ==================== */
/* Escrita: webCheckin / webRegistrarEvento -- chamadas pela Execution API
 * (Codigo.gs > executar), gravadas com o TOKEN DE SERVICO (o tecnico nao e'
 * editor da planilha). Leitura: carregarAoVivo -- chamada pela console
 * (google.script.run), como o usuario logado (leitor). */

var WEB_HEAD_PRESENCA = ['tecnico', 'email', 'ultimo_checkin', 'versao_dicon', 'roteiro', 'maquina', 'atividade_atual', 'local_atual'];
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
  function val(nome, novo) {
    if (novo !== undefined && novo !== null && novo !== '') return novo;
    var i = ix[nome];
    return (i != null && atual[i] != null) ? atual[i] : '';
  }
  var linha = [
    val('tecnico', campos.tecnico), val('email', campos.email), _webAgora(),
    val('versao_dicon', campos.versao_dicon), val('roteiro', campos.roteiro),
    val('maquina', campos.maquina), val('atividade_atual', campos.atividade_atual),
    val('local_atual', campos.local_atual)
  ];
  if (rowNum > 0) _sheetsSetValores(token, sheetId, 'Presenca!A' + rowNum + ':H' + rowNum, [linha]);
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
  var atividade = '', local = '';
  if (req.tipo === 'iniciou_diagnostico') {
    atividade = 'Diagnostico em ' + (req.detalhe || req.local_id || '') + ' desde ' + _webAgora();
    local = req.local_id || '';
  } else if (req.tipo === 'transmitiu' || req.tipo === 'finalizou' || req.tipo === 'abandonou') {
    atividade = (req.tipo === 'finalizou' ? 'Concluiu ' : (req.tipo === 'transmitiu' ? 'Transmitiu ' : 'Saiu de ')) +
                (req.detalhe || req.local_id || '') + ' as ' + _webAgora();
    local = '';
  }
  try {
    _webPresencaUpsert(token, sheetId, {
      tecnico: req.tecnico, email: req.email, versao_dicon: req.versao_dicon,
      roteiro: req.roteiro, maquina: req.maquina,
      atividade_atual: atividade || undefined, local_atual: (req.tipo === 'iniciou_diagnostico') ? local : ''
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
      local_atual: p['local_atual'], ultimo_checkin: _webHora(p['ultimo_checkin']),
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
