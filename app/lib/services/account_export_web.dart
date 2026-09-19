import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'account_export.dart';

Future<String?> saveAccountExport(String json) async {
  final blob = web.Blob(
    [json.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = accountExportFileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return 'Downloaded $accountExportFileName';
}
