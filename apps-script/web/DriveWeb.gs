/**
 * DICON Web -- Drive via API REST: arquiva os PDFs no Shared Drive da
 * coordenacao.
 *
 * Usa o TOKEN DE SERVICO (do George) + UrlFetchApp contra a API do Drive -- NAO
 * DriveApp. Assim o manifest do projeto continua so' com os escopos que a
 * Execution API do DICON de campo exige (spreadsheets + external_request); o
 * escopo de Drive (drive.file) vive so' no refresh token de servico
 * (tools/Conectar-DriveServico.ps1 -> setupServiceAuth).
 *
 * webUploadPdfRelatorio: acao 'pdf.relatorio' -- o DICON desktop sobe o PDF
 * individual de cada Local (com ou sem GEL) pra DICON/relatorios/ e a console
 * grava pdf_url na aba Resultados. gerarRelatorioFinal (RelatorioFinal.gs) usa
 * _driveGarantirPasta/_driveUpload pra arquivar o consolidado.
 *
 * Sem escopo de Drive no token -> 'DRIVE_SEM_ESCOPO' e nada quebra.
 */

var DRIVE_API   = 'https://www.googleapis.com/drive/v3';
var DRIVE_UPLOAD = 'https://www.googleapis.com/upload/drive/v3/files';
var DRIVE_COMUM = 'supportsAllDrives=true&includeItemsFromAllDrives=true';

function _driveFetch(url, opt) {
  opt = opt || {};
  var resp = UrlFetchApp.fetch(url, opt);
  var cod = resp.getResponseCode();
  var txt = resp.getContentText();
  if (cod === 403 && /insufficient|scope|permission/i.test(txt)) {
    throw new Error('DRIVE_SEM_ESCOPO');
  }
  if (cod >= 300) throw new Error('Drive API ' + cod + ': ' + txt);
  return txt ? JSON.parse(txt) : {};
}

function _driveHeaders(token) { return { Authorization: 'Bearer ' + token }; }

// procura um filho (pasta ou arquivo) pelo nome dentro de paiId. null se nao acha.
function _driveAcharFilho(token, nome, paiId, soPasta) {
  var q = "name = '" + String(nome).replace(/'/g, "\\'") + "' and '" + paiId +
          "' in parents and trashed = false" +
          (soPasta ? " and mimeType = 'application/vnd.google-apps.folder'" : '');
  var url = DRIVE_API + '/files?q=' + encodeURIComponent(q) +
            '&fields=files(id,name)&corpora=allDrives&' + DRIVE_COMUM;
  var j = _driveFetch(url, { method: 'get', muteHttpExceptions: true, headers: _driveHeaders(token) });
  var f = (j.files || [])[0];
  return f ? f.id : null;
}

function _driveCriarPasta(token, nome, paiId) {
  var j = _driveFetch(DRIVE_API + '/files?fields=id&' + DRIVE_COMUM, {
    method: 'post', muteHttpExceptions: true, contentType: 'application/json',
    headers: _driveHeaders(token),
    payload: JSON.stringify({ name: String(nome), mimeType: 'application/vnd.google-apps.folder', parents: [paiId] })
  });
  return j.id;
}

function _driveGarantirPasta(token, nome, paiId) {
  return _driveAcharFilho(token, nome, paiId, true) || _driveCriarPasta(token, nome, paiId);
}

function _driveUpload(token, paiId, nome, mimeType, bytes) {
  var boundary = 'dicon' + Date.now() + Math.floor(Math.random() * 1e6);
  var meta = { name: nome, parents: [paiId] };
  var pre = '--' + boundary + '\r\n' +
    'Content-Type: application/json; charset=UTF-8\r\n\r\n' + JSON.stringify(meta) + '\r\n' +
    '--' + boundary + '\r\n' + 'Content-Type: ' + mimeType + '\r\n\r\n';
  var pos = '\r\n--' + boundary + '--';
  var corpo = Utilities.newBlob(pre).getBytes().concat(bytes).concat(Utilities.newBlob(pos).getBytes());
  var j = _driveFetch(DRIVE_UPLOAD + '?uploadType=multipart&fields=id,name,webViewLink,thumbnailLink&' + DRIVE_COMUM, {
    method: 'post', muteHttpExceptions: true,
    contentType: 'multipart/related; boundary=' + boundary,
    headers: _driveHeaders(token),
    payload: corpo
  });
  return j;
}

function _driveUploadMedia(token, fileId, mimeType, bytes) {
  return _driveFetch(DRIVE_UPLOAD + '/' + fileId + '?uploadType=media&fields=id,webViewLink&' + DRIVE_COMUM, {
    method: 'patch', muteHttpExceptions: true, contentType: mimeType,
    headers: _driveHeaders(token), payload: bytes
  });
}

// cria o arquivo, ou SOBRESCREVE se ja existe um com esse nome na pasta.
function _driveUploadOuAtualiza(token, paiId, nome, mimeType, bytes) {
  var id = _driveAcharFilho(token, nome, paiId, false);
  if (id) return _driveUploadMedia(token, id, mimeType, bytes);
  return _driveUpload(token, paiId, nome, mimeType, bytes);
}

function _colA1(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}

// grava pdf_url na linha mais recente do Local (casando o tecnico quando dado)
// na aba Resultados. Cria a coluna pdf_url se ela nao existir.
function _resultadoSetPdf(token, sheetId, localId, tecnico, url) {
  var v = _sheetsGetValores(token, sheetId, ABA_RESULTADOS);
  if (!v || v.length < 2) return;
  var head = v[0].map(function (c) { return String(c || '').trim(); });
  var ix = {}; head.forEach(function (n, i) { ix[n] = i; });
  if (ix['local_id'] == null) return;

  if (ix['pdf_url'] == null) {
    var nova = head.length + 1;
    _sheetsSetValores(token, sheetId, ABA_RESULTADOS + '!' + _colA1(nova) + '1', [['pdf_url']]);
    ix['pdf_url'] = nova - 1;
  }

  var alvoTec = String(tecnico || '').toLowerCase().trim();
  for (var r = v.length - 1; r >= 1; r--) {   // mais recente primeiro
    if (String(v[r][ix['local_id']] || '').trim() !== localId) continue;
    if (alvoTec && ix['tecnico'] != null && String(v[r][ix['tecnico']] || '').toLowerCase().trim() !== alvoTec) continue;
    _sheetsSetValores(token, sheetId, ABA_RESULTADOS + '!' + _colA1(ix['pdf_url'] + 1) + (r + 1), [[url]]);
    return;
  }
}

// acao 'pdf.relatorio' (Codigo.gs > executar). Chamada pelo DICON desktop.
// req: { local_id, tecnico, nome, b64 }
function webUploadPdfRelatorio(req) {
  req = req || {};
  var localId = String(req.local_id || '').trim();
  if (!localId) return { status: 'ignorado', motivo: 'local_id ausente' };
  if (!req.b64)  return { status: 'ignorado', motivo: 'pdf vazio' };

  var token = _tokenServico();
  var sheetId = _idResultados();
  var nome = String(req.nome || '').trim() || (localId.replace(/[^A-Za-z0-9_.-]+/g, '_') + '.pdf');

  var f;
  try {
    var pasta = _driveGarantirPasta(token, 'relatorios', _webDriveRoot());
    f = _driveUploadOuAtualiza(token, pasta, nome, 'application/pdf', Utilities.base64Decode(req.b64));
  } catch (e) {
    if (String(e.message || e).indexOf('DRIVE_SEM_ESCOPO') >= 0) return { status: 'ignorado', motivo: 'DRIVE_SEM_ESCOPO' };
    throw e;
  }

  var url = f.webViewLink || ('https://drive.google.com/file/d/' + f.id + '/view');
  try { _resultadoSetPdf(token, sheetId, localId, String(req.tecnico || ''), url); } catch (e) { /* link e' secundario */ }
  return { status: 'ok', url: url, id: f.id };
}
