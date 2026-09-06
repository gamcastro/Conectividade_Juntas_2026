/**
 * DICON Web -- relatorio INDIVIDUAL de um Local, gerado pela console.
 *
 * Caso de uso (2026-09-06): o tecnico roda o DICON desktop e transmite o
 * diagnostico, mas NAO tem acesso ao GEL web -> nao consegue anexar o
 * formulario/fotos do GEL no proprio relatorio. O coordenador, que tem acesso,
 * importa o GEL + fotos pela console e aqui **regenera** o PDF individual
 * daquele Local juntando: medicoes do JSON transmitido + as 5 secoes do GEL da
 * console + as fotos do Drive -- no mesmo visual do relatorio do DICON desktop
 * (modo 'medicao'). Salva em DICON/relatorios/<local_id>.pdf (SOBRESCREVE o que
 * o desktop subiu) e atualiza pdf_url na aba Resultados.
 *
 * HTML -> PDF pelo Utilities (sem DocumentApp). Drive via token de servico.
 */

function _relLocDados(localId) {
  var t = null, gw = null, u = null;
  try { t = _webTestadosCompleto()[localId]; } catch (e) { t = null; }
  try { gw = _webGelWeb()[localId]; } catch (e) { gw = null; }
  _webUniverso().forEach(function (x) { if (x.local_id === localId) u = x; });
  return { t: t, gw: gw, u: u };
}

function _relN(v, dig) {
  if (v === '' || v == null || isNaN(v)) return '';
  var n = Math.round(Number(v) * Math.pow(10, dig || 1)) / Math.pow(10, dig || 1);
  return String(n);
}

// { latitude, longitude, precisao_m, tipo_local:{...}, infraestrutura:{...},
//   eletrica:{...}, suporte_nome, suporte_telefone } -> HTML das 5 secoes.
function _relGelHtml(vg) {
  if (!vg) return '';
  function esc(s) { return _webEsc(s); }
  function kv(titulo, pares) {
    var linhas = pares.filter(function (p) { return String(p[1] == null ? '' : p[1]).trim() !== ''; })
      .map(function (p) { return '<tr><td class="k">' + esc(p[0]) + '</td><td>' + esc(p[1]) + '</td></tr>'; });
    if (!linhas.length) return '';
    return '<div class="subt">' + esc(titulo) + '</div><table class="kv"><tbody>' + linhas.join('') + '</tbody></table>';
  }
  var tl = vg.tipo_local || {}, inf = vg.infraestrutura || {}, et = vg.eletrica || {};
  var secs = [];

  var lat = vg.latitude, lng = vg.longitude;
  if (lat != null && lng != null && lat !== '' && lng !== '') {
    var prec = (vg.precisao_m != null && String(vg.precisao_m) !== '' && String(vg.precisao_m) !== '0')
      ? (' · precisão ~' + _relN(vg.precisao_m, 1) + ' m') : '';
    var link = vg.mapa_link || ('https://www.google.com/maps?q=' + lat + ',' + lng);
    secs.push('<div class="subt">Coordenadas</div><table class="kv"><tbody>' +
      '<tr><td class="k">Lat / Long</td><td>' + esc(lat + ', ' + lng + prec) + '</td></tr>' +
      '<tr><td class="k">Mapa</td><td><a href="' + esc(link) + '">' + esc(link) + '</a></td></tr>' +
      '</tbody></table>');
  }
  secs.push(kv('Tipo do local', [
    ['Esfera administrativa', tl.esfera_administrativa],
    ['Localização', tl.localizacao],
    ['Tipo de local', tl.tipo]
  ]));
  secs.push(kv('Infraestrutura', [
    ['Salas necessárias', inf.salas_necessarias],
    ['Abastecimento de água', inf.agua],
    ['Climatização / ventilação', inf.climatizacao],
    ['Iluminação', inf.iluminacao],
    ['Água potável', inf.agua_potavel],
    ['Prédio em reforma', inf.predio_reforma]
  ]));
  secs.push(kv('Instalações elétricas', [
    ['Quadro de energia', et.quadro_energia],
    ['Energia elétrica', et.energia_eletrica != null ? et.energia_eletrica : vg.energia_eletrica],
    ['Tomadas funcionando', et.tomadas != null ? et.tomadas : vg.eletrica_tomadas],
    ['Tensão da rede', et.tensao != null ? et.tensao : vg.eletrica_tensao],
    ['Necessita extensão elétrica', et.extensao != null ? et.extensao : vg.eletrica_extensao]
  ]));
  secs.push(kv('Suporte ao link local', [
    ['Empresa / técnico', vg.suporte_nome],
    ['Telefone', vg.suporte_telefone]
  ]));

  secs = secs.filter(function (s) { return s; });
  return secs.length ? secs.join('') : '';
}

// req: { local_id }  (papel leitura basta -- e' o coordenador enriquecendo)
function gerarRelatorioLocal(req) {
  var acesso = _webExigirAcesso('leitura');
  req = req || {};
  var localId = String(req.local_id || '').trim();
  if (!localId) throw new Error('local_id ausente');

  var tz = Session.getScriptTimeZone();
  var d = _relLocDados(localId);
  if (!d.t || !d.t.doc) return { ok: false, erro: 'SEM_RESULTADO' };  // Local ainda nao transmitido

  var doc = d.t.doc;
  var loc = doc.local || {};
  var meds = (doc.medicoes || []).filter(function (m) { return m; });
  var rec = doc.conexao_recomendada || null;
  var quando = _webParseData(doc.coletado_em || d.t.recebido_em);
  var quandoTxt = quando ? Utilities.formatDate(quando, tz, 'dd/MM/yyyy HH:mm') : '';

  // GEL: prioriza o da console; senao o que veio no JSON do tecnico.
  var vg = (d.gw && d.gw.secoes) ? d.gw.secoes : (doc.vistoria_gel || null);
  var gelOrigem = (d.gw && d.gw.secoes) ? ('console · ' + _webEsc(d.gw.por || '') + (d.gw.quando ? ' · ' + _webEsc(d.gw.quando) : '')) : (doc.vistoria_gel ? 'enviado pelo técnico' : '');

  // ---- fotos do Drive -> data URIs (teto ~9 MB / 12 fotos)
  var fotosHtml = '', nFotos = 0, nUsadas = 0;
  try {
    var token = _tokenServico();
    var lista = listarFotosGel(localId).fotos || [];
    nFotos = lista.length;
    var acum = 0, cells = [];
    for (var i = 0; i < lista.length && cells.length < 12; i++) {
      var du = _driveBaixarDataUri(token, lista[i].id, 'image/jpeg');
      if (!du) continue;
      if (acum + du.length > 9000000) break;
      acum += du.length; nUsadas++;
      cells.push('<td class="foto"><img src="' + du + '"><div class="cap">Foto ' + nUsadas + '</div></td>');
    }
    if (cells.length) {
      var rows = [];
      for (var j = 0; j < cells.length; j += 2) {
        rows.push('<tr>' + cells[j] + (cells[j + 1] || '<td class="foto"></td>') + '</tr>');
      }
      fotosHtml = '<div class="bar">Registro fotográfico (' + nUsadas + ' de ' + nFotos + ' fotos)' +
        (nUsadas < nFotos ? ' — as demais foram omitidas por limite de tamanho' : '') + '</div>' +
        '<table class="fotos"><tbody>' + rows.join('') + '</tbody></table>';
    }
  } catch (e) { /* sem fotos */ }

  // ---- identificacao + resumo
  var tipoLocal = (loc.tipo === 'principal') ? 'Local principal' : 'Local de contingência';
  var idRows =
    '<tr><td class="k">Data do diagnóstico</td><td>' + _webEsc(quandoTxt) + '</td></tr>' +
    '<tr><td class="k">Zona Eleitoral</td><td>ZE ' + _webEsc(loc.zona_eleitoral || (d.u && d.u.zona) || '') + '</td></tr>' +
    '<tr><td class="k">Município</td><td>' + _webEsc((loc.municipio_termo || (d.u && d.u.municipio) || '')) +
      (loc.municipio_sede ? ' (sede: ' + _webEsc(loc.municipio_sede) + ')' : '') + '</td></tr>' +
    '<tr><td class="k">Local</td><td>' + _webEsc(loc.nome || (d.u && d.u.nome) || localId) + '</td></tr>' +
    '<tr><td class="k">Tipo</td><td>' + _webEsc(tipoLocal) + '</td></tr>' +
    '<tr><td class="k">Endereço</td><td>' + _webEsc(loc.endereco || (d.u && d.u.endereco) || '') + '</td></tr>' +
    '<tr><td class="k">Internet do local</td><td>' + _webEsc(loc.tipo_internet || '') + '</td></tr>' +
    '<tr><td class="k">Técnico</td><td>' + _webEsc((doc.tecnico && doc.tecnico.nome) || d.t.tecnico || '') + '</td></tr>';

  var aplic = meds.filter(function (m) { return !m.nao_aplicavel; });
  var na = meds.filter(function (m) { return m.nao_aplicavel; });
  var sug = (rec && rec.rotulo && rec.meio !== 'nenhuma')
    ? (_webEsc(rec.rotulo) + (rec.download_mbps != null ? (' — maior download ' + _relN(rec.download_mbps, 1) + ' Mbps' + (rec.base === 'vpn' ? ' pela VPN' : ' na rede local')) : ''))
    : '—';
  var resumoRows =
    '<tr><td class="k">Meios medidos</td><td class="n">' + aplic.length + '</td></tr>' +
    '<tr><td class="k">Meios não aplicáveis</td><td class="n">' + na.length + '</td></tr>' +
    '<tr><td class="k">Sugestão de conexão</td><td>' + sug + '</td></tr>';
  var cl = doc.cabo_lan;
  if (cl && cl.necessario != null) {
    resumoRows += '<tr><td class="k">Cabo de rede (LAN)</td><td>' +
      (cl.necessario ? ('sim' + (cl.metros ? ' ~' + cl.metros + ' m' : '')) : 'não precisa') + '</td></tr>';
  }

  var rank = { lan: 0, wifi: 1, celular: 2 };
  var medRows = meds.slice().sort(function (a, b) {
    var ra = rank[a.meio], rb = rank[b.meio];
    return (ra == null ? 9 : ra) - (rb == null ? 9 : rb);
  }).map(function (m) {
    if (m.nao_aplicavel) {
      return '<tr><td>' + _webEsc(m.rotulo || m.meio) + '</td><td colspan="6" class="small">não se aplica' +
        (m.motivo_nao_aplicavel ? ' — ' + _webEsc(m.motivo_nao_aplicavel) : '') + '</td></tr>';
    }
    var rl = (m.rede_local_download != null) ? (_relN(m.rede_local_download, 1) + ' Mbps') : (m.rede_local_ok ? 'ok' : 'não rodou');
    var ul = (m.rede_local_upload_mbps != null) ? (_relN(m.rede_local_upload_mbps, 1) + ' Mbps') : (m.rede_local_ok ? 'ok' : 'não rodou');
    var dv = (m.vpn_download_mbps != null) ? (_relN(m.vpn_download_mbps, 1) + ' Mbps') : '—';
    var lt = (m.latencia_ms != null) ? (m.latencia_ms + ' ms') : '—';
    var pd = (m.perda_percentual != null) ? (m.perda_percentual + ' %') : '—';
    return '<tr><td>' + _webEsc(m.rotulo || m.meio) + '</td><td class="n">' + (m.vpn_conectou ? 'Sim' : 'Não') +
      '</td><td class="n">' + rl + '</td><td class="n">' + ul + '</td><td class="n">' + dv +
      '</td><td class="n">' + lt + '</td><td class="n">' + pd + '</td></tr>';
  }).join('');

  var obs = [];
  if (doc.observacoes_tecnico && String(doc.observacoes_tecnico).trim()) obs.push('Técnico: ' + String(doc.observacoes_tecnico).trim());
  if (doc.vpn && doc.vpn.impossivel) obs.push('Não foi possível conectar a VPN da Justiça Eleitoral' + (doc.vpn.motivo ? ' (' + doc.vpn.motivo + ')' : ''));
  na.forEach(function (m) { obs.push((m.rotulo || m.meio) + ' não se aplica' + (m.motivo_nao_aplicavel ? ': ' + m.motivo_nao_aplicavel : '')); });
  var obsHtml = obs.length ? ('<ul>' + obs.map(function (o) { return '<li>' + _webEsc(o) + '</li>'; }).join('') + '</ul>') : 'Sem observações.';

  var gelHtml = _relGelHtml(vg);
  var brasao = (typeof WEB_BRASAO !== 'undefined' && WEB_BRASAO) ? '<img class="brasao" src="' + WEB_BRASAO + '">' : '';
  var dataCurta = Utilities.formatDate(new Date(), tz, 'dd/MM/yyyy');

  var css =
    "body{font-family:Arial,Helvetica,sans-serif;font-size:9px;color:#1f2430;margin:22px 26px}" +
    ".cab{width:100%;border-collapse:collapse;margin-bottom:2px}.cab td{border:0;padding:0;vertical-align:middle}" +
    ".cab .bcell{width:60px}.cab .brasao{width:52px;height:auto}" +
    ".cab .org{color:#444;font-size:8.5px;line-height:1.4}.cab .org b{color:#1f2430;font-size:9.5px}" +
    ".cab .dt{text-align:right;color:#555;font-size:8.5px;white-space:nowrap}" +
    ".rule{border:0;border-top:3px solid #1a3a8f;margin:7px 0 10px}" +
    "h1.tit{font-size:14px;margin:0 0 2px}p.sub{font-size:10px;margin:0 0 2px;color:#333}" +
    ".bar{background:#1F4E79;color:#fff;font-weight:bold;text-transform:uppercase;letter-spacing:.06em;font-size:9.5px;padding:5px 10px;margin:14px 0 6px}" +
    ".subt{font-weight:bold;color:#2E5A8A;text-transform:uppercase;font-size:8.5px;letter-spacing:.03em;margin:9px 0 2px}" +
    "table{border-collapse:collapse;width:100%;margin-top:3px}" +
    "th,td{border:1px solid #BFC9DA;padding:4px 7px;text-align:left;vertical-align:top}" +
    "th{background:#D9E2F3;font-size:8px;color:#22324a;text-transform:uppercase;letter-spacing:.03em}" +
    "td.n,th.n{text-align:right}td.small{color:#8891a0}" +
    "table.kv td.k{background:#E7EDF6;font-weight:bold;width:150px;color:#33465f}" +
    ".grid2{width:100%;border-collapse:collapse;margin-top:3px}.grid2>tbody>tr>td{border:0;padding:0;vertical-align:top}.grid2 .gap{width:16px;border:0;padding:0}" +
    "ul{margin:4px 0 0 16px;padding:0}li{margin:1px 0}" +
    "table.fotos{border-collapse:separate;border-spacing:6px}table.fotos td{border:0;width:50%;vertical-align:top}" +
    "td.foto img{width:100%;border:1px solid #BFC9DA;border-radius:3px}td.foto .cap{font-size:8px;color:#5c6472;margin-top:2px}" +
    ".foot{margin-top:12px;color:#5c6472;font-size:8px}";

  var html =
    '<html><head><meta charset="utf-8"><style>' + css + '</style></head><body>' +
    '<table class="cab"><tbody><tr>' +
    '<td class="bcell">' + brasao + '</td>' +
    '<td class="org"><b>JUSTICA ELEITORAL</b><br>Tribunal Regional Eleitoral do Maranhao<br>' +
      'SEASU / COINF / STIC &mdash; DICON &middot; Diagnostico de Conectividade</td>' +
    '<td class="dt">' + _webEsc(dataCurta) + '</td></tr></tbody></table><hr class="rule">' +

    '<h1 class="tit">Relatório de Diagnóstico de Conectividade</h1>' +
    '<p class="sub">ZE ' + _webEsc(loc.zona_eleitoral || (d.u && d.u.zona) || '') + ' &mdash; ' +
      _webEsc(loc.municipio_termo || (d.u && d.u.municipio) || '') +
      (loc.municipio_sede ? ' (sede: ' + _webEsc(loc.municipio_sede) + ')' : '') + '</p>' +

    '<div class="bar">Painel de Medições &mdash; Junta Eleitoral Especial 2026</div>' +
    '<table class="grid2"><tbody><tr>' +
    '<td><div class="subt">Identificação</div><table class="kv"><tbody>' + idRows + '</tbody></table></td>' +
    '<td class="gap"></td>' +
    '<td><div class="subt">Resumo</div><table class="kv"><tbody>' + resumoRows + '</tbody></table></td>' +
    '</tr></tbody></table>' +
    '<div class="subt" style="margin-top:8px">Medições por meio</div>' +
    '<table><thead><tr><th>Meio</th><th class="n">VPN</th><th class="n">Down s/ VPN</th><th class="n">Up s/ VPN</th>' +
      '<th class="n">Down c/ VPN</th><th class="n">Latência</th><th class="n">Perda</th></tr></thead>' +
      '<tbody>' + (medRows || '<tr><td colspan="7">Sem medições.</td></tr>') + '</tbody></table>' +
    '<div class="subt" style="margin-top:8px">Observações</div>' + obsHtml +

    (gelHtml
      ? ('<div class="bar">Dados da vistoria (importado do GEL)</div>' +
         (gelOrigem ? '<div class="foot" style="margin:0 0 4px">Origem: ' + gelOrigem + '</div>' : '') + gelHtml)
      : '<div class="bar">Dados da vistoria (importado do GEL)</div><div class="foot" style="margin:0">Nenhum formulário do GEL anexado a este Local.</div>') +

    (fotosHtml || '') +

    '<div class="foot">Relatório gerado pela console DICON Web (homologação) em ' +
      _webEsc(Utilities.formatDate(new Date(), tz, "dd/MM/yyyy 'as' HH:mm")) + ' por ' + _webEsc(acesso.email) +
      '. Modo medição &mdash; medições e sugestão de conexão, sem juízo de viabilidade.</div>' +
    '</body></html>';

  var nomeArq = localId.replace(/[^A-Za-z0-9_.-]+/g, '_') + '.pdf';
  var pdf = Utilities.newBlob(html, 'text/html', nomeArq).getAs('application/pdf');

  var url = '';
  try {
    var tk = _tokenServico();
    var pasta = _driveGarantirPasta(tk, 'relatorios', WEB_DRIVE_ROOT);
    var f = _driveUploadOuAtualiza(tk, pasta, nomeArq, 'application/pdf', pdf.getBytes());
    url = f.webViewLink || ('https://drive.google.com/file/d/' + f.id + '/view');
    try { _resultadoSetPdf(tk, _idResultados(), localId, String((doc.tecnico && doc.tecnico.nome) || d.t.tecnico || ''), url); } catch (e) {}
  } catch (e) {
    if (String(e.message || e).indexOf('DRIVE_SEM_ESCOPO') >= 0) {
      return { ok: false, erro: 'DRIVE_SEM_ESCOPO', pdf_b64: Utilities.base64Encode(pdf.getBytes()), filename: nomeArq };
    }
    throw e;
  }

  return {
    ok: true, url: url, filename: nomeArq,
    tem_gel: !!gelHtml, fotos: nUsadas,
    pdf_b64: Utilities.base64Encode(pdf.getBytes())
  };
}
