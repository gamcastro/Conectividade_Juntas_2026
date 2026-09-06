/**
 * DICON Web -- Fase 3: relatorio final consolidado (docs/dicon-web-plano.md).
 *
 * gerarRelatorioFinal: monta um HTML -> converte pra PDF com Utilities (NAO usa
 * DocumentApp/DriveApp -- esses exigiriam os escopos 'documents'/'drive' no
 * manifest, e a Execution API que o DICON de campo usa exige que o token do
 * DICON tenha TODOS os escopos do script -- o token do DICON so' tem
 * 'spreadsheets'). O PDF volta em base64 para o navegador baixar. O
 * arquivamento no Shared Drive fica para quando o token de servico tiver
 * escopo 'drive' (Fase 4).
 *
 * Modo 'medicao': medicoes + sugestao de conexao, sem KPIs de viabilidade.
 * Funciona a qualquer cobertura (parcial < 100% ou final).
 */

function _webAbaSimples(nome, cabecalho) {
  var ss = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(nome);
  if (!aba) {
    aba = ss.insertSheet(nome);
    aba.getRange(1, 1, 1, cabecalho.length).setValues([cabecalho]);
  }
  return aba;
}

// Testados COM o json completo parseado (cabo_lan / observacoes / vistoria_gel).
function _webTestadosCompleto() {
  var out = {};
  var ss = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(ABA_RESULTADOS);
  if (!aba || aba.getLastRow() < 2) return out;
  var v = aba.getDataRange().getValues();
  var ix = {};
  v[0].forEach(function (c, i) { ix[String(c || '').trim()] = i; });
  function cel(row, n) { var i = ix[n]; return (i == null) ? '' : row[i]; }
  for (var r = 1; r < v.length; r++) {
    var row = v[r];
    var id = String(cel(row, 'local_id') || '').trim();
    if (!id) { continue; }
    var doc = null;
    try { doc = JSON.parse(String(cel(row, 'json') || '')); } catch (e) { doc = null; }
    var oper = String(cel(row, 'operadora_recomendada') || '');
    out[id] = {
      local_id: id,
      recebido_em: cel(row, 'recebido_em'),
      tecnico: String(cel(row, 'tecnico') || ''),
      conexao: String(cel(row, 'conexao_recomendada') || '') + (oper ? ' (' + oper + ')' : ''),
      download: cel(row, 'download_mbps'),
      latencia: cel(row, 'latencia_ms'),
      perda: cel(row, 'perda_%'),
      pdf_url: String(cel(row, 'pdf_url') || cel(row, 'pdf_drive_id') || ''),
      doc: doc
    };
  }
  return out;
}

function _webEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>]/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
  });
}

function _webTabelaCobertura(titulo, universo, testados, mapfn) {
  var ag = {};
  universo.forEach(function (u) {
    var k = String(mapfn(u) || '(sem)');
    if (!ag[k]) { ag[k] = { f: 0, t: 0 }; }
    ag[k].t++;
    if (testados[u.local_id]) { ag[k].f++; }
  });
  var linhas = Object.keys(ag).sort().map(function (k) {
    var o = ag[k], p = o.t ? Math.round(o.f * 100 / o.t) : 0;
    return '<tr><td>' + _webEsc(k) + '</td><td class="n">' + o.f + '</td><td class="n">' + o.t +
      '</td><td class="n">' + p + '%</td></tr>';
  }).join('');
  return '<h2>' + _webEsc(titulo) + '</h2><table class="cob"><thead><tr><th></th><th>Testados</th>' +
    '<th>Total</th><th>%</th></tr></thead><tbody>' + linhas + '</tbody></table>';
}

function gerarRelatorioFinal(modo) {
  var acesso = _webExigirAcesso('leitura');
  modo = modo || 'medicao';
  var tz = Session.getScriptTimeZone();

  var universo = _webUniverso();
  var testados = _webTestadosCompleto();
  var total  = universo.length;
  var feitos = universo.filter(function (u) { return testados[u.local_id]; }).length;
  var pct    = total ? Math.round(feitos * 100 / total) : 0;
  var quando = Utilities.formatDate(new Date(), tz, "dd/MM/yyyy 'as' HH:mm");

  var linhasLocais = universo.map(function (u) {
    var t = testados[u.local_id];
    var cabo = '', obs = '', gel = '';
    if (t && t.doc) {
      var cl = t.doc.cabo_lan;
      if (cl && cl.necessario != null) {
        cabo = cl.necessario ? ('sim' + (cl.metros ? ' ~' + cl.metros + ' m' : '')) : 'nao precisa';
      }
      obs = String(t.doc.observacoes_tecnico || '');
      var vg = t.doc.vistoria_gel;
      gel = (vg && (vg.tipo_local || vg.infraestrutura || vg.eletrica || (vg.fotos && vg.fotos > 0))) ? 'sim' : '';
    }
    var qd = _webParseData(t ? t.recebido_em : '');
    var status = t
      ? '<span class="ok">testado ' + (qd ? Utilities.formatDate(qd, tz, 'dd/MM') : '') + '</span>'
      : '<span class="no">nao testado</span>';
    return '<tr class="' + (t ? '' : 'pend') + '">' +
      '<td>' + _webEsc(u.nome || u.local_id) + '</td>' +
      '<td class="n">' + _webEsc(u.zona) + '</td>' +
      '<td>' + _webEsc(u.municipio) + '</td>' +
      '<td>' + _webEsc(u.tipo) + '</td>' +
      '<td class="n">' + _webEsc(u.roteiro) + '</td>' +
      '<td>' + status + '</td>' +
      '<td>' + _webEsc(t ? t.conexao : '') + '</td>' +
      '<td class="n">' + _webEsc(t && t.download !== '' && t.download != null ? t.download : '') + '</td>' +
      '<td class="n">' + _webEsc(t && t.latencia !== '' && t.latencia != null ? t.latencia : '') + '</td>' +
      '<td>' + _webEsc(cabo) + '</td>' +
      '<td>' + _webEsc(obs) + '</td>' +
      '<td class="n">' + _webEsc(gel) + '</td>' +
      '</tr>';
  }).join('');

  var html =
    '<html><head><meta charset="utf-8"><style>' +
    'body{font-family:Arial,Helvetica,sans-serif;font-size:9px;color:#14181f;margin:24px}' +
    'h1{font-size:15px;margin:0 0 2px}h2{font-size:11px;margin:14px 0 4px;color:#0a1e4d}' +
    '.sub{font-size:8px;color:#5c6472;letter-spacing:.06em}' +
    '.meta{font-size:8.5px;color:#5c6472;margin:6px 0}' +
    '.big{font-size:8.5px;margin:2px 0}.warn{color:#a3320f;font-weight:bold}' +
    'table{border-collapse:collapse;width:100%;margin-top:3px}' +
    'th,td{border:1px solid #cfd6e0;padding:3px 5px;text-align:left;vertical-align:top}' +
    'th{background:#eef1f6;font-size:8px}td.n,th.n{text-align:right}' +
    'table.cob{width:auto;min-width:260px}' +
    'tr.pend td{color:#8891a0}.ok{color:#1b7f3b}.no{color:#8891a0}' +
    '</style></head><body>' +
    '<div class="sub">JUSTICA ELEITORAL / TRE-MA / SEASU-COINF-STIC / DICON</div>' +
    '<h1>Relatorio ' + (pct >= 100 ? 'final' : 'parcial') + ' de diagnostico de conectividade</h1>' +
    '<div class="meta">Gerado em ' + _webEsc(quando) + ' por ' + _webEsc(acesso.email) +
      ' &middot; modo: ' + _webEsc(modo) + '</div>' +
    '<div class="big"><b>Cobertura: ' + feitos + ' de ' + total + ' locais testados (' + pct + '%).</b></div>' +
    (pct < 100 ? '<div class="big warn">RELATORIO PARCIAL - faltam ' + (total - feitos) + ' locais.</div>' : '') +
    _webTabelaCobertura('Cobertura por roteiro', universo, testados, function (u) { return u.roteiro_rotulo; }) +
    _webTabelaCobertura('Cobertura por tecnico previsto', universo, testados, function (u) { return u.tecnico_previsto; }) +
    _webTabelaCobertura('Cobertura por ZE', universo, testados, function (u) { return 'ZE ' + u.zona; }) +
    _webTabelaCobertura('Cobertura por municipio', universo, testados, function (u) { return u.municipio; }) +
    '<h2>Locais</h2><table><thead><tr>' +
    '<th>Local</th><th>ZE</th><th>Municipio</th><th>Tipo</th><th>Rot.</th><th>Status</th>' +
    '<th>Conexao sugerida</th><th class="n">Down Mbps</th><th class="n">Lat ms</th>' +
    '<th>Cabo de rede</th><th>Observacoes do tecnico</th><th class="n">GEL</th>' +
    '</tr></thead><tbody>' + linhasLocais + '</tbody></table>' +
    '<div class="meta" style="margin-top:12px">Eleicoes 2026 - Juntas Eleitorais Especiais. ' +
    'Modo ' + _webEsc(modo) + ' - medicoes e sugestao de conexao, sem juizo de viabilidade.</div>' +
    '</body></html>';

  var nomeArq = 'DICON - Relatorio ' + (pct >= 100 ? 'final' : 'parcial ' + pct + 'pct') + ' - ' +
                Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HHmm') + '.pdf';
  var pdf = Utilities.newBlob(html, 'text/html', nomeArq).getAs('application/pdf');

  try {
    _webAbaSimples('RelatoriosFinais', ['gerado_em', 'por', 'modo', 'cobertura_pct', 'feitos', 'total'])
      .appendRow([_webAgora(), acesso.email, modo, pct, feitos, total]);
  } catch (e) { /* historico e' secundario */ }

  return {
    ok: true, cobertura_pct: pct, feitos: feitos, total: total, parcial: (pct < 100),
    filename: nomeArq, pdf_b64: Utilities.base64Encode(pdf.getBytes())
  };
}

function listarRelatoriosFinais() {
  var acesso = verificarAcesso();
  if (!acesso.papel) { return { acesso: acesso, sem_acesso: true }; }
  var ss = SpreadsheetApp.openById(_idResultados());
  var hist = _webLerAba(ss, 'RelatoriosFinais').reverse().map(function (r) {
    return {
      gerado_em: _webHora(r['gerado_em']), por: r['por'], modo: r['modo'],
      cobertura_pct: r['cobertura_pct'], feitos: r['feitos'], total: r['total']
    };
  });
  return { acesso: acesso, historico: hist };
}
