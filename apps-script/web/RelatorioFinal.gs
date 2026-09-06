/**
 * DICON Web -- Fase 3: relatorio final consolidado (docs/dicon-web-plano.md).
 *
 * gerarRelatorioFinal: monta um Google Doc -> PDF, salva os dois em
 * relatorios-finais/ da pasta do Shared Drive (WEB_DRIVE_ROOT, em Console.gs),
 * registra em RelatoriosFinais e devolve os links. Funciona a qualquer
 * cobertura (parcial ou 100%). Roda COMO O USUARIO -> o coordenador precisa de
 * editor na pasta do Drive. Modo 'medicao': medicoes + sugestao de conexao,
 * sem KPIs de viabilidade.
 */

function _webSubpasta(nome) {
  var raiz = DriveApp.getFolderById(WEB_DRIVE_ROOT);
  var it = raiz.getFoldersByName(nome);
  return it.hasNext() ? it.next() : raiz.createFolder(nome);
}

function _webAbaSimples(nome, cabecalho) {
  var ss = SpreadsheetApp.openById(_idResultados());
  var aba = ss.getSheetByName(nome);
  if (!aba) {
    aba = ss.insertSheet(nome);
    aba.getRange(1, 1, 1, cabecalho.length).setValues([cabecalho]);
  }
  return aba;
}

// Testados COM o json completo parseado (mais pesado -- so' o relatorio final usa).
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

function gerarRelatorioFinal(modo) {
  var acesso = _webExigirAcesso('leitura');
  modo = modo || 'medicao';
  var tz = Session.getScriptTimeZone();

  var universo = _webUniverso();
  var testados = _webTestadosCompleto();
  var total  = universo.length;
  var feitos = universo.filter(function (u) { return testados[u.local_id]; }).length;
  var pct    = total ? Math.round(feitos * 100 / total) : 0;

  var nome = 'DICON - Relatorio ' + (pct >= 100 ? 'final' : 'parcial ' + pct + 'pct') + ' - ' +
             Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HHmm');

  var doc = DocumentApp.create(nome);
  var b = doc.getBody();

  b.appendParagraph('JUSTICA ELEITORAL / TRE-MA / SEASU-COINF-STIC / DICON')
    .setHeading(DocumentApp.ParagraphHeading.SUBTITLE);
  b.appendParagraph('Relatorio ' + (pct >= 100 ? 'final' : 'parcial') + ' de diagnostico de conectividade')
    .setHeading(DocumentApp.ParagraphHeading.TITLE);
  b.appendParagraph('Gerado em ' + Utilities.formatDate(new Date(), tz, "dd/MM/yyyy 'as' HH:mm") +
                    ' por ' + acesso.email + ' - modo: ' + modo);
  var pCob = b.appendParagraph('Cobertura: ' + feitos + ' de ' + total + ' locais testados (' + pct + '%).');
  if (pct < 100) {
    pCob.setBold(true);
    b.appendParagraph('RELATORIO PARCIAL - faltam ' + (total - feitos) + ' locais.').setBold(true);
  }

  function bloco(titulo, mapfn) {
    b.appendParagraph(titulo).setHeading(DocumentApp.ParagraphHeading.HEADING2);
    var ag = {};
    universo.forEach(function (u) {
      var k = String(mapfn(u) || '(sem)');
      if (!ag[k]) { ag[k] = { f: 0, t: 0 }; }
      ag[k].t++;
      if (testados[u.local_id]) { ag[k].f++; }
    });
    var linhas = [['', 'Testados', 'Total', '%']];
    Object.keys(ag).sort().forEach(function (k) {
      var o = ag[k];
      linhas.push([k, String(o.f), String(o.t), (o.t ? Math.round(o.f * 100 / o.t) : 0) + '%']);
    });
    b.appendTable(linhas);
  }
  bloco('Cobertura por roteiro',          function (u) { return u.roteiro_rotulo; });
  bloco('Cobertura por tecnico previsto', function (u) { return u.tecnico_previsto; });
  bloco('Cobertura por ZE',               function (u) { return 'ZE ' + u.zona; });
  bloco('Cobertura por municipio',        function (u) { return u.municipio; });

  b.appendParagraph('Locais').setHeading(DocumentApp.ParagraphHeading.HEADING2);
  var linhas = [['Local', 'ZE', 'Municipio', 'Tipo', 'Rot.', 'Status', 'Conexao sugerida',
                 'Down Mbps', 'Lat ms', 'Cabo de rede', 'Observacoes do tecnico', 'GEL', 'PDF']];
  universo.forEach(function (u) {
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
    linhas.push([
      String(u.nome || u.local_id), String(u.zona), String(u.municipio), String(u.tipo), String(u.roteiro),
      (t ? ('testado ' + (qd ? Utilities.formatDate(qd, tz, 'dd/MM') : '')) : 'nao testado'),
      String(t ? t.conexao : ''),
      String(t && t.download !== '' && t.download != null ? t.download : ''),
      String(t && t.latencia !== '' && t.latencia != null ? t.latencia : ''),
      cabo, obs, gel, String(t && t.pdf_url ? t.pdf_url : '')
    ]);
  });
  b.appendTable(linhas);

  b.appendParagraph('Eleicoes 2026 - Juntas Eleitorais Especiais. Modo ' + modo +
                    ' - medicoes e sugestao de conexao, sem juizo de viabilidade.').setItalic(true);

  doc.saveAndClose();

  var pasta  = _webSubpasta('relatorios-finais');
  var arqDoc = DriveApp.getFileById(doc.getId());
  try { arqDoc.moveTo(pasta); } catch (e) { pasta.addFile(arqDoc); }
  var pdf = pasta.createFile(arqDoc.getBlob().getAs('application/pdf').setName(nome + '.pdf'));

  try {
    _webAbaSimples('RelatoriosFinais', ['gerado_em', 'por', 'modo', 'cobertura_pct', 'doc_url', 'pdf_url'])
      .appendRow([_webAgora(), acesso.email, modo, pct, arqDoc.getUrl(), pdf.getUrl()]);
  } catch (e) { /* historico e' secundario */ }

  return {
    ok: true, cobertura_pct: pct, feitos: feitos, total: total,
    parcial: (pct < 100), doc_url: arqDoc.getUrl(), pdf_url: pdf.getUrl()
  };
}

function listarRelatoriosFinais() {
  var acesso = verificarAcesso();
  if (!acesso.papel) { return { acesso: acesso, sem_acesso: true }; }
  var ss = SpreadsheetApp.openById(_idResultados());
  var hist = _webLerAba(ss, 'RelatoriosFinais').reverse().map(function (r) {
    return {
      gerado_em: _webHora(r['gerado_em']), por: r['por'], modo: r['modo'],
      cobertura_pct: r['cobertura_pct'], doc_url: r['doc_url'], pdf_url: r['pdf_url']
    };
  });
  return { acesso: acesso, historico: hist };
}
