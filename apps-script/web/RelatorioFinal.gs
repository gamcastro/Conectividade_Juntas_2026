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
 * Visual espelhado do relatorio do DICON Desktop (src/saida/Export-RelatorioPdf.ps1):
 * cabecalho JE + brasao, regua navy, faixas navy #1F4E79, th #D9E2F3, bordas
 * #BFC9DA, celulas-chave #E7EDF6. Layout so' com tabelas aninhadas -- o
 * renderizador HTML->PDF do Utilities nao faz flexbox/grid.
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
  } else if (aba.getLastColumn() < cabecalho.length) {
    aba.getRange(1, 1, 1, cabecalho.length).setValues([cabecalho]);  // estende cabecalho antigo
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

// Uma tabela "Testados / Total / %" por agrupamento, no estilo do relatorio Desktop.
function _webTabelaCobertura(titulo, universo, testados, mapfn) {
  var ag = {};
  universo.forEach(function (u) {
    var k = String(mapfn(u) || '(sem)');
    if (!ag[k]) { ag[k] = { f: 0, t: 0 }; }
    ag[k].t++;
    if (testados[u.local_id]) { ag[k].f++; }
  });
  var linhas = Object.keys(ag).sort().map(function (k, i) {
    var o = ag[k], p = o.t ? Math.round(o.f * 100 / o.t) : 0;
    return '<tr' + (i % 2 ? ' class="alt"' : '') + '><td>' + _webEsc(k) +
      '</td><td class="n">' + o.f + '</td><td class="n">' + o.t +
      '</td><td class="n">' + p + '%</td></tr>';
  }).join('');
  return '<div class="subt">' + _webEsc(titulo) + '</div>' +
    '<table class="cob"><thead><tr><th>' + _webEsc(titulo.replace(/^Cobertura por\s+/i, '')) +
    '</th><th class="n">Testados</th><th class="n">Total</th><th class="n">%</th></tr></thead>' +
    '<tbody>' + linhas + '</tbody></table>';
}

function gerarRelatorioFinal(modo) {
  var acesso = _webExigirAcesso('leitura');
  modo = modo || 'medicao';
  var tz = Session.getScriptTimeZone();

  var universo = _webUniverso();
  var testados = _webTestadosCompleto();
  var gelWeb   = _webGelWeb();
  var total  = universo.length;
  var feitos = universo.filter(function (u) { return testados[u.local_id]; }).length;
  var pct    = total ? Math.round(feitos * 100 / total) : 0;
  var quando = Utilities.formatDate(new Date(), tz, "dd/MM/yyyy 'as' HH:mm");
  var dataCurta = Utilities.formatDate(new Date(), tz, 'dd/MM/yyyy');
  var final_ = (pct >= 100);

  var linhasLocais = universo.map(function (u, i) {
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
    if (!gel && gelWeb[u.local_id] && gelWeb[u.local_id].secoes) { gel = 'sim (web)'; }
    var qd = _webParseData(t ? t.recebido_em : '');
    var status = t
      ? '<span class="ok">testado' + (qd ? ' ' + Utilities.formatDate(qd, tz, 'dd/MM') : '') + '</span>'
      : '<span class="no">nao testado</span>';
    var cls = [];
    if (!t) { cls.push('pend'); }
    if (i % 2) { cls.push('alt'); }
    return '<tr' + (cls.length ? ' class="' + cls.join(' ') + '"' : '') + '>' +
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

  var brasao = (typeof WEB_BRASAO !== 'undefined' && WEB_BRASAO)
    ? '<img class="brasao" src="' + WEB_BRASAO + '">' : '';

  var css =
    "body{font-family:Arial,Helvetica,sans-serif;font-size:9px;color:#1f2430;margin:22px 26px}" +
    ".cab{width:100%;border-collapse:collapse;margin-bottom:2px}" +
    ".cab td{border:0;padding:0;vertical-align:middle}" +
    ".cab .bcell{width:60px}" +
    ".cab .brasao{width:52px;height:auto}" +
    ".cab .org{color:#444;font-size:8.5px;line-height:1.4}" +
    ".cab .org b{color:#1f2430;font-size:9.5px}" +
    ".cab .dt{text-align:right;color:#555;font-size:8.5px;white-space:nowrap}" +
    ".rule{border:0;border-top:3px solid #1a3a8f;margin:7px 0 10px}" +
    "h1.tit{font-size:14px;margin:0 0 2px;color:#1f2430}" +
    "p.sub{font-size:10px;margin:0;color:#333}" +
    ".bar{background:#1F4E79;color:#fff;font-weight:bold;text-transform:uppercase;" +
      "letter-spacing:.06em;font-size:9.5px;padding:5px 10px;margin:14px 0 6px}" +
    ".subt{font-weight:bold;color:#2E5A8A;text-transform:uppercase;font-size:8.5px;" +
      "letter-spacing:.03em;margin:9px 0 2px}" +
    "table{border-collapse:collapse;width:100%;margin-top:3px}" +
    "th,td{border:1px solid #BFC9DA;padding:4px 7px;text-align:left;vertical-align:top}" +
    "th{background:#D9E2F3;font-size:8px;color:#22324a;text-transform:uppercase;letter-spacing:.03em}" +
    "td.n,th.n{text-align:right}" +
    "table.kv td.k{background:#E7EDF6;font-weight:bold;width:150px;color:#33465f}" +
    "table.cob{width:auto;min-width:280px}" +
    "tr.alt td{background:#F4F7FB}" +
    "tr.pend td{color:#8891a0}" +
    ".ok{color:#1b7f3b;font-weight:bold}.no{color:#8891a0}" +
    ".warn{color:#a3320f;font-weight:bold}" +
    ".big{font-size:9.5px;margin:2px 0}" +
    ".grid2{width:100%;border-collapse:collapse;margin-top:3px}" +
    ".grid2>tbody>tr>td{border:0;padding:0;vertical-align:top}" +
    ".grid2 .gap{width:16px;border:0;padding:0}" +
    ".foot{margin-top:12px;color:#5c6472;font-size:8px}";

  var kvIdent =
    '<table class="kv"><tbody>' +
    '<tr><td class="k">Gerado em</td><td>' + _webEsc(quando) + '</td></tr>' +
    '<tr><td class="k">Gerado por</td><td>' + _webEsc(acesso.email) + '</td></tr>' +
    '<tr><td class="k">Modo</td><td>' + _webEsc(modo) + ' &middot; medicoes e sugestao de conexao</td></tr>' +
    '<tr><td class="k">Ambiente</td><td>HOMOLOGACAO</td></tr>' +
    '</tbody></table>';

  var kvResumo =
    '<table class="kv"><tbody>' +
    '<tr><td class="k">Locais no plano</td><td class="n">' + total + '</td></tr>' +
    '<tr><td class="k">Locais testados</td><td class="n">' + feitos + '</td></tr>' +
    '<tr><td class="k">Cobertura</td><td class="n">' + pct + '%</td></tr>' +
    '<tr><td class="k">Pendentes</td><td class="n">' + (total - feitos) + '</td></tr>' +
    '</tbody></table>';

  var cob = _webTabelaCobertura('Cobertura por roteiro', universo, testados, function (u) { return u.roteiro_rotulo; });
  var cobTec = _webTabelaCobertura('Cobertura por tecnico previsto', universo, testados, function (u) { return u.tecnico_previsto; });
  var cobZe = _webTabelaCobertura('Cobertura por ZE', universo, testados, function (u) { return 'ZE ' + u.zona; });
  var cobMun = _webTabelaCobertura('Cobertura por municipio', universo, testados, function (u) { return u.municipio; });

  var html =
    '<html><head><meta charset="utf-8"><style>' + css + '</style></head><body>' +

    '<table class="cab"><tbody><tr>' +
    '<td class="bcell">' + brasao + '</td>' +
    '<td class="org"><b>JUSTICA ELEITORAL</b><br>' +
      'Tribunal Regional Eleitoral do Maranhao<br>' +
      'SEASU / COINF / STIC &mdash; DICON &middot; Diagnostico de Conectividade</td>' +
    '<td class="dt">' + _webEsc(dataCurta) + '</td>' +
    '</tr></tbody></table>' +
    '<hr class="rule">' +

    '<h1 class="tit">Relatorio ' + (final_ ? 'final' : 'parcial') + ' de diagnostico de conectividade</h1>' +
    '<p class="sub">Juntas Eleitorais Especiais 2026 &mdash; TRE-MA</p>' +

    '<div class="bar">Painel de cobertura &mdash; Juntas Eleitorais Especiais 2026</div>' +
    '<table class="grid2"><tbody><tr>' +
    '<td>' + kvIdent + '</td><td class="gap"></td><td>' + kvResumo + '</td>' +
    '</tr></tbody></table>' +
    '<div class="big"><b>Cobertura: ' + feitos + ' de ' + total + ' locais testados (' + pct + '%).</b></div>' +
    (final_ ? '' : '<div class="big warn">RELATORIO PARCIAL &mdash; faltam ' + (total - feitos) + ' locais.</div>') +

    '<div class="bar">Cobertura por agrupamento</div>' +
    '<table class="grid2"><tbody><tr>' +
    '<td>' + cob + '</td><td class="gap"></td><td>' + cobTec + '</td>' +
    '</tr><tr>' +
    '<td>' + cobZe + '</td><td class="gap"></td><td>' + cobMun + '</td>' +
    '</tr></tbody></table>' +

    '<div class="bar">Locais</div>' +
    '<table><thead><tr>' +
    '<th>Local</th><th class="n">ZE</th><th>Municipio</th><th>Tipo</th><th class="n">Rot.</th><th>Status</th>' +
    '<th>Conexao sugerida</th><th class="n">Down Mbps</th><th class="n">Lat ms</th>' +
    '<th>Cabo de rede</th><th>Observacoes do tecnico</th><th class="n">GEL</th>' +
    '</tr></thead><tbody>' + linhasLocais + '</tbody></table>' +

    '<div class="foot">Eleicoes 2026 &mdash; Juntas Eleitorais Especiais. ' +
    'Modo ' + _webEsc(modo) + ': medicoes e sugestao de conexao, sem juizo de viabilidade. ' +
    'Documento gerado pela console DICON Web (homologacao).</div>' +
    '</body></html>';

  var nomeArq = 'DICON - Relatorio ' + (final_ ? 'final' : 'parcial ' + pct + 'pct') + ' - ' +
                Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HHmm') + '.pdf';
  var pdf = Utilities.newBlob(html, 'text/html', nomeArq).getAs('application/pdf');

  // arquiva no Shared Drive (DICON/relatorios-finais/) -- best-effort: se o
  // token de servico ainda nao tiver escopo de Drive, segue so' com o download.
  var arq = { id: '', url: '' };
  try {
    var tokenD = _tokenServico();
    var pastaRF = _driveGarantirPasta(tokenD, 'relatorios-finais', WEB_DRIVE_ROOT);
    var fRF = _driveUpload(tokenD, pastaRF, nomeArq, 'application/pdf', pdf.getBytes());
    arq = { id: fRF.id, url: fRF.webViewLink || '' };
  } catch (e) { /* sem Drive: so' download */ }

  try {
    _webAbaSimples('RelatoriosFinais', ['gerado_em', 'por', 'modo', 'cobertura_pct', 'feitos', 'total', 'pdf_url', 'pdf_id'])
      .appendRow([_webAgora(), acesso.email, modo, pct, feitos, total, arq.url, arq.id]);
  } catch (e) { /* historico e' secundario */ }

  return {
    ok: true, cobertura_pct: pct, feitos: feitos, total: total, parcial: !final_,
    filename: nomeArq, pdf_b64: Utilities.base64Encode(pdf.getBytes()),
    arquivo_url: arq.url
  };
}

function listarRelatoriosFinais() {
  var acesso = verificarAcesso();
  if (!acesso.papel) { return { acesso: acesso, sem_acesso: true }; }
  var ss = SpreadsheetApp.openById(_idResultados());
  var hist = _webLerAba(ss, 'RelatoriosFinais').reverse().map(function (r) {
    return {
      gerado_em: _webHora(r['gerado_em']), por: r['por'], modo: r['modo'],
      cobertura_pct: r['cobertura_pct'], feitos: r['feitos'], total: r['total'],
      pdf_url: r['pdf_url'] || ''
    };
  });
  return { acesso: acesso, historico: hist };
}
