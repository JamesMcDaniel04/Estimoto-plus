import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'account_export.dart';

Future<String?> saveAccountExport(String json) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$accountExportFileName');
    await file.writeAsString(json, flush: true);
    return Platform.isIOS
        ? 'Saved to Files › On My iPhone › Estimoto + › $accountExportFileName'
        : 'Saved to the app documents folder as $accountExportFileName';
  } catch (_) {
    return null;
  }
}
