import 'dart:typed_data';
import '../domain/models.dart';
import 'guided_capture_pending_types.dart';

// Includes photos saved by older app versions, whose limit was 10 MB.
const maxSavedCaptureBytes = 10 * 1024 * 1024;

/// The native/web host binds the estimate and account guard once, outside JS.
abstract class GuidedCaptureApi {
  Uri get pageUri;
  Future<Json> state();
  Future<({Uint8List bytes, String mimeType})> readPhoto(String photoId);
  Future<Json> checkFrame({
    required Uint8List bytes,
    required String mimeType,
    required String captureKey,
    required String bodyStyle,
  });
  Future<Json> save(GuidedCapturePending photo);
  Future<Json> recognize(String photoId);
  Future<Json> confirm(Json body);
  Future<Json> help(String captureKey, String question);
}
