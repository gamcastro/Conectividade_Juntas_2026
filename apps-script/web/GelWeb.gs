/**
 * DICON Web -- Fase 2: importacao do formulario do GEL pela console.
 *
 * A extracao do PDF do GEL roda NO NAVEGADOR (pdf.js) -- nada de PDF chega ao
 * servidor. Aqui fica so' a gravacao das secoes conferidas na aba "GEL" da
 * planilha de Resultados, com o TOKEN DE SERVICO (o coordenador tem so' leitor
 * na planilha) -- mesmo padrao de webCheckin / webRegistrarEvento.
 *
 * Chamadas por google.script.run (console) -- NAO por 'executar' -- entao so' a
 * implantacao Web App precisa de redeploy, nao a da Execution API do DICON.
 *
 * Fotos da vistoria: NAO nesta fase. Dependem do escopo 'drive' no token de
 * servico (decisao 2026-09-06: o token de servico ganha 'drive'; ver o plano).
 */

var WEB_HEAD_GEL = ['local_id', 'secoes_json', 'n_fotos', 'por', 'quando', 'pdf_gel_id', 'pasta_drive_id'];

// Normaliza o formulario conferido no MESMO shape do bloco vistoria_gel do DICON
// desktop (New-BlocoVistoriaGel em src/core/VistoriaGel.ps1) -- assim o dado da
// web fica identico ao do desktop e o relatorio final le os dois do mesmo jeito.
function _gelNormaliza(s) {
  s = s || {};
  function g(k) { return String(s[k] == null ? '' : s[k]).trim(); }
  function num(k) {
    var v = s[k];
    if (v === '' || v == null) return null;
    v = parseFloat(String(v).replace(',', '.'));
    return isNaN(v) ? null : v;
  }
  var lat = num('latitude'), lng = num('longitude');
  return {
    latitude: lat, longitude: lng, precisao_m: num('precisao_m'),
    mapa_link: (lat != null && lng != null) ? ('https://www.google.com/maps?q=' + lat + ',' + lng) : '',
    tipo_local: {
      esfera_administrativa: g('esfera_administrativa'),
      localizacao: g('localizacao'),
      tipo: g('tipo_local')
    },
    infraestrutura: {
      salas_necessarias: g('salas_necessarias'), agua: g('agua'),
      climatizacao: g('climatizacao'), iluminacao: g('iluminacao'),
      agua_potavel: g('agua_potavel'), predio_reforma: g('predio_reforma')
    },
    eletrica: {
      quadro_energia: g('quadro_energia'), energia_eletrica: g('energia_eletrica'),
      tomadas: g('eletrica_tomadas'), tensao: g('eletrica_tensao'), extensao: g('eletrica_extensao')
    },
    suporte_nome: g('suporte_nome'), suporte_telefone: g('suporte_telefone'),
    fotos: 0,
    // compat: campos planos que o desktop tambem grava
    eletrica_tensao: g('eletrica_tensao'), eletrica_tomadas: g('eletrica_tomadas'),
    eletrica_extensao: g('eletrica_extensao'),
    origem: 'web'
  };
}

// local_id -> { secoes(obj|null), por, quando, n_fotos } lido da aba GEL.
// Best-effort: se a aba nao existe ou o token de servico nao esta configurado,
// devolve {} (sem GEL web).
function _webGelWeb() {
  var out = {};
  try {
    var token = _tokenServico();
    var sheetId = _idResultados();
    if (!sheetId) return out;
    var v = _sheetsGetValores(token, sheetId, 'GEL');
    if (!v || v.length < 2) return out;
    var ix = {}; (v[0] || []).forEach(function (c, i) { ix[String(c || '').trim()] = i; });
    for (var r = 1; r < v.length; r++) {
      var row = v[r];
      var id = String(row[ix['local_id']] || '').trim();
      if (!id) continue;
      var sec = null;
      try { sec = JSON.parse(String(row[ix['secoes_json']] || '')); } catch (e) { sec = null; }
      out[id] = {
        secoes: sec,
        por: String(row[ix['por']] || ''),
        quando: String(row[ix['quando']] || ''),
        n_fotos: Number(row[ix['n_fotos']] || 0) || 0
      };
    }
  } catch (e) { /* sem GEL web */ }
  return out;
}

// Tela GEL da console: identidade do Local + GEL ja existente (da web ou do
// resultado transmitido) para pre-preencher / conferir o formulario.
function carregarGelLocal(localId) {
  var acesso = _webExigirAcesso('leitura');
  localId = String(localId || '').trim();

  var u = null;
  _webUniverso().forEach(function (x) { if (x.local_id === localId) u = x; });

  var web = _webGelWeb()[localId] || null;

  var doResultado = null;
  try {
    var t = _webTestadosCompleto()[localId];
    if (t && t.doc && t.doc.vistoria_gel) doResultado = t.doc.vistoria_gel;
  } catch (e) { /* ok */ }

  return { acesso: acesso, local: u, gel_web: web, gel_resultado: doResultado };
}

// Grava/atualiza a linha do Local na aba GEL. req: { local_id, secoes }
function salvarGelWeb(req) {
  var acesso = _webExigirAcesso('leitura');
  req = req || {};
  var localId = String(req.local_id || '').trim();
  if (!localId) throw new Error('local_id ausente');

  var token = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) throw new Error('PLANILHA_RESULTADOS_ID nao configurado');

  _sheetsGarantirAba(token, sheetId, 'GEL', WEB_HEAD_GEL);
  var v = _sheetsGetValores(token, sheetId, 'GEL');
  var head = (v[0] || WEB_HEAD_GEL).map(function (c) { return String(c || '').trim(); });
  var ix = {}; head.forEach(function (n, i) { ix[n] = i; });

  var rowNum = -1, existente = null;
  for (var r = 1; r < v.length; r++) {
    if (String((v[r][ix['local_id']]) || '').trim() === localId) { rowNum = r + 1; existente = v[r]; break; }
  }
  var nFotos = (existente && existente[ix['n_fotos']] !== '' && existente[ix['n_fotos']] != null)
    ? existente[ix['n_fotos']] : 0;

  var secoes = _gelNormaliza(req.secoes);
  secoes.fotos = Number(nFotos) || 0;

  var linha = [
    localId, JSON.stringify(secoes), nFotos, acesso.email, _webAgora(),
    (existente ? (existente[ix['pdf_gel_id']] || '') : ''),
    (existente ? (existente[ix['pasta_drive_id']] || '') : '')
  ];
  if (rowNum > 0) _sheetsSetValores(token, sheetId, 'GEL!A' + rowNum + ':G' + rowNum, [linha]);
  else _sheetsAppendLinha(token, sheetId, 'GEL', linha);

  return { ok: true, quando: _webAgora(), por: acesso.email };
}
