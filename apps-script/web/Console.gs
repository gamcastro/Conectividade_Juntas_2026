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
function carregarPainel() {
  var acesso = verificarAcesso();
  if (!acesso.papel) return { acesso: acesso, sem_acesso: true };

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
    acesso: acesso,
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
