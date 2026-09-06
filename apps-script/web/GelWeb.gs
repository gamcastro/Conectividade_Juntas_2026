/**
 * DICON Web -- SYNC do formulario do GEL + fotos da vistoria (Escopo 2 da tela
 * Coordenacao do DICON desktop).
 *
 * Problema: o formulario do GEL (data/vistoria-gel/<id>.json) e as fotos ficavam
 * SO' no computador onde foram anexados. Um 2o coordenador -- ou o tecnico de
 * campo -- regenerava o relatorio daquele local SEM a secao GEL/fotos e, com
 * pdf_web ligado, ainda sobrescrevia no Drive a versao boa.
 *
 * Aqui o GEL e as fotos passam pelo backend:
 *   - o JSON do formulario vai numa aba 'GEL' da planilha de Resultados (1 linha
 *     por local, upsert por local_id);
 *   - as fotos vao pro Drive da coordenacao em  <raiz>/vistoria-gel/<local_id>/.
 *
 * Tudo pelo TOKEN DE SERVICO + UrlFetchApp (nunca DriveApp) -- mesma restricao de
 * escopo do resto do web/ (ver cabecalho de DriveWeb.gs). Sem escopo de Drive no
 * token -> 'DRIVE_SEM_ESCOPO' e o JSON ainda e' gravado na planilha.
 *
 * Acoes em Codigo.gs > executar:
 *   'gel.enviar' { local_id, enviado_por, gel_json, remover?, fotos:[{nome,b64}] }
 *   'gel.obter'  { local_id } -> { gel_json, fotos:[{nome,b64}], atualizado_em, enviado_por }
 */

var ABA_GEL       = 'GEL';
var WEB_HEAD_GEL  = ['local_id', 'atualizado_em', 'enviado_por', 'fotos', 'gel_json'];
var GEL_PASTA_RAIZ = 'vistoria-gel';
var GEL_FOTO_MAX_B64   = 12 * 1024 * 1024;   // ~9 MB por foto ja e' muito
var GEL_TOTAL_MAX_B64  = 45 * 1024 * 1024;   // teto de resposta do gel.obter

// Pasta <raiz>/vistoria-gel/<local_id>/ no Drive da coordenacao. Cria o caminho.
function _gelPastaLocal(token, localId) {
  var raiz  = _driveGarantirPasta(token, GEL_PASTA_RAIZ, _webDriveRoot());
  var idSan = String(localId).replace(/[^A-Za-z0-9_.-]+/g, '_');
  return _driveGarantirPasta(token, idSan, raiz);
}

// linha (1-based) do local na aba GEL, ou -1. head = cabecalho ja lido.
function _gelAcharLinha(valores, ixLocal, localId) {
  for (var r = 1; r < valores.length; r++) {
    if (String(valores[r][ixLocal] || '').trim() === String(localId).trim()) return r + 1;
  }
  return -1;
}

// acao 'gel.enviar' (Codigo.gs > executar). Chamada pelo DICON desktop ao
// Registrar o GEL / adicionar / remover fotos, e por Invoke-GelRemover.
function webGelEnviar(req) {
  req = req || {};
  var localId = String(req.local_id || '').trim();
  if (!localId) return { status: 'ignorado', motivo: 'local_id ausente' };

  var token   = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) return { status: 'ignorado', motivo: 'PLANILHA_RESULTADOS_ID nao configurado' };

  _sheetsGarantirAba(token, sheetId, ABA_GEL, WEB_HEAD_GEL);
  var v    = _sheetsGetValores(token, sheetId, ABA_GEL);
  var head = (v[0] || WEB_HEAD_GEL).map(function (c) { return String(c || '').trim(); });
  var ix   = {}; head.forEach(function (n, i) { ix[n] = i; });
  var rowNum = _gelAcharLinha(v, ix['local_id'], localId);

  // --- REMOVER: limpa a linha + apaga as fotos da pasta -----------------------
  if (req.remover) {
    if (rowNum > 0) {
      _sheetsSetValores(token, sheetId, ABA_GEL + '!A' + rowNum + ':E' + rowNum,
        [[localId, _webAgora(), String(req.enviado_por || ''), 0, '']]);
    }
    try {
      var pastaR = _gelPastaLocal(token, localId);
      _driveListarFilhos(token, pastaR).forEach(function (f) { _driveApagar(token, f.id); });
    } catch (e) {
      if (String(e.message || e).indexOf('DRIVE_SEM_ESCOPO') < 0) throw e;
    }
    return { status: 'ok', removido: true };
  }

  // --- ENVIAR: upsert do JSON + fotos ---------------------------------------
  var gelJson = String(req.gel_json || '');
  var fotos   = req.fotos || [];
  var nomes   = {};

  var linha = [localId, _webAgora(), String(req.enviado_por || ''), fotos.length, gelJson];
  if (rowNum > 0) _sheetsSetValores(token, sheetId, ABA_GEL + '!A' + rowNum + ':E' + rowNum, [linha]);
  else            _sheetsAppendLinha(token, sheetId, ABA_GEL, linha);

  var fotosOk = 0, driveErro = '';
  try {
    var pasta = _gelPastaLocal(token, localId);
    for (var i = 0; i < fotos.length; i++) {
      var nome = String(fotos[i].nome || ('foto-' + (i + 1) + '.jpg')).replace(/[^A-Za-z0-9_.-]+/g, '_');
      nomes[nome] = true;
      if (!fotos[i].b64) continue;
      _driveUploadOuAtualiza(token, pasta, nome, 'image/jpeg', Utilities.base64Decode(fotos[i].b64));
      fotosOk++;
    }
    // apaga do Drive o que nao veio nesta remessa (foto removida no desktop)
    _driveListarFilhos(token, pasta).forEach(function (f) {
      if (!nomes[f.name]) { try { _driveApagar(token, f.id); } catch (e) { /* ok */ } }
    });
  } catch (e) {
    driveErro = String(e.message || e);
    if (driveErro.indexOf('DRIVE_SEM_ESCOPO') >= 0) {
      return { status: 'ok', gel_gravado: true, fotos: 0, motivo_fotos: 'DRIVE_SEM_ESCOPO' };
    }
    throw e;
  }

  return { status: 'ok', gel_gravado: true, fotos: fotosOk };
}

// acao 'gel.obter' (Codigo.gs > executar). O DICON desktop chama ao "Baixar
// resultado transmitido" (Coordenacao) e no Sync-Resultados do "Atualizar dados".
function webGelObter(req) {
  req = req || {};
  var localId = String(req.local_id || '').trim();
  if (!localId) return { erro: 'local_id obrigatorio' };

  var token   = _tokenServico();
  var sheetId = _idResultados();
  if (!sheetId) return { erro: 'PLANILHA_RESULTADOS_ID nao configurado' };

  var out = { local_id: localId, gel_json: '', atualizado_em: '', enviado_por: '', fotos: [] };

  // 1) JSON do formulario, da aba GEL
  try {
    var v = _sheetsGetValores(token, sheetId, ABA_GEL);
    if (v && v.length >= 2) {
      var head = v[0].map(function (c) { return String(c || '').trim(); });
      var ix = {}; head.forEach(function (n, i) { ix[n] = i; });
      var rowNum = _gelAcharLinha(v, ix['local_id'], localId);
      if (rowNum > 0) {
        var row = v[rowNum - 1];
        out.gel_json      = String(row[ix['gel_json']] || '');
        out.atualizado_em = String(row[ix['atualizado_em']] || '');
        out.enviado_por   = String(row[ix['enviado_por']] || '');
      }
    }
  } catch (e) { /* aba pode nem existir ainda */ }

  // 2) fotos, do Drive
  try {
    var raiz  = _driveAcharFilho(token, GEL_PASTA_RAIZ, _webDriveRoot(), true);
    if (raiz) {
      var idSan = localId.replace(/[^A-Za-z0-9_.-]+/g, '_');
      var pasta = _driveAcharFilho(token, idSan, raiz, true);
      if (pasta) {
        var total = 0;
        var arquivos = _driveListarFilhos(token, pasta).filter(function (f) {
          return f.mimeType && f.mimeType.indexOf('image/') === 0;
        }).sort(function (a, b) { return a.name < b.name ? -1 : 1; });
        for (var i = 0; i < arquivos.length; i++) {
          var b64 = _driveBaixarBytesB64(token, arquivos[i].id);
          if (b64.length > GEL_FOTO_MAX_B64) continue;
          total += b64.length;
          if (total > GEL_TOTAL_MAX_B64) { out.fotos_truncado = true; break; }
          out.fotos.push({ nome: arquivos[i].name, b64: b64 });
        }
      }
    }
  } catch (e) {
    out.fotos_erro = String(e.message || e);
  }

  return out;
}
