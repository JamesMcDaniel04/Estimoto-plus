/// Hands a finished account export to the customer on the current platform.
///
/// Web downloads a JSON file from the browser. Native builds write the file
/// to the app's Documents folder (visible under Files on iOS) and report the
/// path; callers also offer the clipboard so Android customers can move the
/// data without a share sheet.
library;

export 'account_export_unsupported.dart'
    if (dart.library.js_interop) 'account_export_web.dart'
    if (dart.library.io) 'account_export_native.dart';

const accountExportFileName = 'estimoto-plus-export.json';
