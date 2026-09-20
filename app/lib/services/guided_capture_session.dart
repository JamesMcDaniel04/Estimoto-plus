import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../data/repository.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import 'estimate_capture_steps.dart';
import 'guided_capture_api.dart';
import 'guided_capture_pending.dart';

const captureChannel = 'estimoto-plus-capture';
const maxCaptureMessageLength = 4 * ((maxGuidedCaptureBytes + 2) ~/ 3) + 2048;
const captureBodyStyles = {
  'sedan',
  'coupe',
  'hatchback',
  'wagon',
  'suv',
  'pickup',
  'van',
  'convertible',
};

bool trustedCapturePage(Uri expected, String raw) {
  final actual = Uri.tryParse(raw);
  return actual != null &&
      const ['https', 'http'].contains(actual.scheme) &&
      actual.hasAuthority &&
      actual.origin == expected.origin &&
      actual.path == '/capture/' &&
      !actual.hasQuery &&
      !actual.hasFragment &&
      actual.userInfo.isEmpty;
}

bool boundedCaptureMessage(String raw) {
  if (raw.length > maxCaptureMessageLength) return false;
  var quoted = false, escaped = false, depth = 0, punctuation = 0;
  for (final unit in raw.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (unit == 92) {
        escaped = true;
      } else if (unit == 34) {
        quoted = false;
      }
    } else if (unit == 34) {
      quoted = true;
    } else if (unit == 123 || unit == 91) {
      if (++depth > 8 || ++punctuation > 128) return false;
    } else if (unit == 125 || unit == 93) {
      depth--;
    } else if (unit == 44 || unit == 58) {
      if (++punctuation > 128) return false;
    }
  }
  return !quoted && depth == 0;
}

/// A page can choose a documented capture operation, never an account or URL.
class GuidedCaptureSession {
  GuidedCaptureSession({
    required this.controller,
    required this.estimateId,
    required this.store,
  }) : ownerId = controller.snapshot!.profile.id,
       discipline =
           controller.snapshot!.estimates
               .where((e) => e.id == estimateId)
               .firstOrNull
               ?.discipline ??
           '';
  final PlusController controller;
  final String ownerId, estimateId, discipline;
  final GuidedCapturePendingStore store;
  int epoch = 0, _inFlight = 0, _images = 0;
  bool enabled = false, disposed = false, closeRequested = false;
  bool foreground = true, selectingPhoto = false;
  void Function()? stopMedia;
  Future<void> _persisting = Future.value();
  Completer<bool>? _resumed;
  Future<bool> waitForForeground() {
    if (!current) return Future.value(false);
    if (foreground) return Future.value(true);
    return (_resumed ??= Completer<bool>()).future;
  }

  final _seen = <String>{};
  bool Function()? documentIsCurrent;
  bool get current =>
      !disposed &&
      controller.isCurrentCustomer(ownerId) &&
      controller.snapshot!.estimates.any((e) => e.id == estimateId);
  bool valid(int run) =>
      current && enabled && run == epoch && (documentIsCurrent?.call() ?? true);
  void activate({
    bool newDocument = false,
    bool Function()? documentIsCurrent,
  }) {
    epoch++;
    if (newDocument) {
      this.documentIsCurrent = documentIsCurrent;
      _seen.clear();
    }
    enabled = current && foreground;
    closeRequested = false;
    if (enabled) {
      _resumed?.complete(true);
      _resumed = null;
    }
  }

  void pause() {
    stopMedia?.call();
    epoch++;
    enabled = false;
  }

  void dispose() {
    pause();
    disposed = true;
    _resumed?.complete(false);
    _resumed = null;
  }

  void check(int run) {
    if (!valid(run)) {
      throw const PlusApiException(
        'Capture is paused. Reopen the guide to continue.',
        401,
      );
    }
  }

  GuidedCaptureApi api(int run) => controller.repository.openGuidedCapture(
    estimateId,
    isCurrent: () => valid(run),
  );
  Uri get pageUri => controller.repository
      .openGuidedCapture(estimateId, isCurrent: () => current)
      .pageUri;

  bool allowedKey(String key) =>
      const {
        'odometer',
        'vin',
        'engine_bay',
        'interior',
        'tire_tread',
        'front',
        'driver',
        'rear',
        'passenger',
        'corner_fl',
        'corner_fr',
        'corner_rl',
        'corner_rr',
        'roof',
      }.contains(key) ||
      (key.startsWith('panel_') &&
          (discipline == 'pdr' ? pdrDamagePanels : collisionDamagePanels)
              .contains(key.substring(6))) ||
      (discipline == 'pdr' &&
          ((key.startsWith('hail_close_') &&
                  pdrDamagePanels.contains(key.substring(11))) ||
              (key.startsWith('hail_raking_') &&
                  pdrDamagePanels.contains(key.substring(12)))));
  void keys(Json value, Set<String> expected) {
    if (value.length != expected.length ||
        !value.keys.every(expected.contains)) {
      throw const PlusApiException('Invalid capture request.', 422);
    }
  }

  String string(Json value, String name, int max, {bool empty = false}) {
    final result = value[name];
    if (result is! String ||
        result.length > max ||
        (!empty && result.trim().isEmpty)) {
      throw const PlusApiException('Invalid capture request.', 422);
    }
    return result;
  }

  ({Uint8List bytes, String mime, String key, String body}) frame(Json params) {
    final key = string(params, 'capture_key', 100),
        body = string(params, 'body_style', 30);
    if (!allowedKey(key) || !captureBodyStyles.contains(body)) {
      throw const PlusApiException(
        'Choose a supported capture step and vehicle body.',
        422,
      );
    }
    if (params['photo'] is! Map) {
      throw const PlusApiException('A photo is required.', 422);
    }
    final photo = Map<String, dynamic>.from(params['photo'] as Map);
    keys(photo, {'base64', 'mime_type'});
    final mime = string(photo, 'mime_type', 20),
        data = string(photo, 'base64', 4 * ((maxGuidedCaptureBytes + 2) ~/ 3));
    if (!const {'image/jpeg', 'image/png', 'image/webp'}.contains(mime) ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(data)) {
      throw const PlusApiException(
        'Choose a JPEG, PNG or WebP photo under 8 MB.',
        422,
      );
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      throw const PlusApiException(
        'The photo could not be read. Choose it again.',
        422,
      );
    }
    if (bytes.isEmpty || bytes.length > maxGuidedCaptureBytes) {
      throw const PlusApiException('Choose a photo under 8 MB.', 422);
    }
    return (bytes: bytes, mime: mime, key: key, body: body);
  }

  Future<GuidedCapturePending?> pending() async {
    if (!current) return null;
    final run = epoch;
    await _persisting.catchError((_) {});
    if (!current || run != epoch) return null;
    final value = await store.read(ownerId);
    return current && run == epoch ? value : null;
  }

  Future<void> discard(GuidedCapturePending value) async {
    final run = epoch;
    if (!current || value.ownerId != ownerId) return;
    await store.clear(ownerId, value.operationId);
    if (!current || run != epoch) return;
  }

  Future<void> discardCorrupt() async {
    if (!current) return;
    await store.discardCorrupt(ownerId);
  }

  Future<Json> save(GuidedCapturePending photo, int run) async {
    check(run);
    if (photo.ownerId != ownerId || photo.estimateId != estimateId) {
      throw const PlusApiException(
        'Open the original estimate to recover this photo.',
        409,
      );
    }
    _persisting = store.write(photo);
    await _persisting;
    check(run);
    try {
      final result = await api(run).save(photo);
      check(run);
      if (result['sha256'] != photo.sha256 ||
          result['label'] != photo.captureKey ||
          result['id'] is! String) {
        throw const PlusApiException(
          'The save receipt could not be verified. Keep this photo and retry.',
          502,
        );
      }
      final latest = await api(run).state();
      check(run);
      final active = rowsOf(latest, 'photos').any(
        (p) =>
            p['id'] == result['id'] &&
            p['sha256'] == photo.sha256 &&
            p['label'] == photo.captureKey,
      );
      await store.clear(ownerId, photo.operationId);
      check(run);
      if (!active) {
        throw const PlusApiException(
          'A newer photo is already saved for this step. Refresh the guide before taking another.',
          409,
          'capture_superseded',
        );
      }
      return result;
    } on PlusApiException catch (error) {
      if (error.statusCode == 422 && valid(run)) {
        await store.clear(ownerId, photo.operationId);
      }
      rethrow;
    }
  }

  Future<Json> readSavedPhoto(Json params, int run) async {
    keys(params, {'photo_id', 'photo_sha256'});
    final id = string(params, 'photo_id', 36);
    final hash = string(params, 'photo_sha256', 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const PlusApiException('Choose a saved photo to review.', 422);
    }
    var reviewing = true;
    final reviewApi = controller.repository.openGuidedCapture(
      estimateId,
      isCurrent: () => reviewing && valid(run),
    );
    Future<void> checkPhoto() async {
      final latest = await reviewApi.state().timeout(
        const Duration(seconds: 4),
      );
      check(run);
      if (!rowsOf(
        latest,
        'photos',
      ).any((photo) => photo['id'] == id && photo['sha256'] == hash)) {
        throw const PlusApiException(
          'This photo changed. Refresh the guide to review the saved photo.',
          409,
        );
      }
    }

    try {
      // At most 4 + 15 + 4 seconds; the page waits 25 seconds. The private reader
      // cancels its HTTP body at its deadline, and this scope rejects late state.
      await checkPhoto();
      final photo = await reviewApi
          .readPhoto(id)
          .timeout(const Duration(seconds: 15));
      check(run);
      final bytes = photo.bytes;
      bool starts(List<int> signature, [int offset = 0]) =>
          bytes.length >= offset + signature.length &&
          signature.indexed.every(
            (entry) => bytes[offset + entry.$1] == entry.$2,
          );
      final validImage = switch (photo.mimeType) {
        'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
        'image/jpeg' => starts([255, 216, 255]),
        'image/webp' => starts([82, 73, 70, 70]) && starts([87, 69, 66, 80], 8),
        _ => false,
      };
      if (bytes.isEmpty || bytes.length > maxSavedCaptureBytes || !validImage) {
        throw const PlusApiException(
          'This saved image cannot be displayed.',
          422,
        );
      }
      if (sha256.convert(bytes).toString() != hash) {
        throw const PlusApiException(
          'This photo changed. Refresh the guide to review the saved photo.',
          409,
        );
      }
      await checkPhoto();
      return {
        'id': id,
        'sha256': hash,
        'mime_type': photo.mimeType,
        'base64': base64Encode(bytes),
      };
    } on TimeoutException {
      throw const PlusApiException('Photo loading timed out. Try again.', 408);
    } finally {
      reviewing = false;
    }
  }

  /// Called only after the platform has validated the exact page/window origin.
  Future<Json?> receive(String raw) async {
    if (!valid(epoch) || !boundedCaptureMessage(raw)) return null;
    Json request;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      request = Map<String, dynamic>.from(value);
    } catch (_) {
      return null;
    }
    if (request['channel'] != captureChannel) return null;
    if (request['type'] == 'ready') return null;
    final id = request['id'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id) ||
        _seen.contains(id)) {
      return null;
    }
    final run = epoch;
    Json failure(PlusApiException error) => {
      'channel': captureChannel,
      'id': id,
      'error': {
        'status': error.statusCode ?? 500,
        'message': error.message,
        if (error.code == 'capture_superseded') 'code': error.code,
      },
    };
    if (_seen.length >= 4096 || _inFlight >= 3) {
      return failure(
        const PlusApiException('Capture is busy. Retry shortly.', 429),
      );
    }
    _seen.add(id);
    _inFlight++;
    var imageCall = false;
    try {
      keys(request, {'channel', 'id', 'method', 'params'});
      final method = string(request, 'method', 30);
      if (request['params'] is! Map) {
        throw const PlusApiException('Invalid capture request.', 422);
      }
      final params = Map<String, dynamic>.from(request['params'] as Map);
      if (method == 'checkFrame' ||
          method == 'saveCapture' ||
          method == 'readSavedPhoto') {
        if (_images != 0) {
          throw const PlusApiException(
            'A photo is being checked or saved. Retry shortly.',
            429,
          );
        }
        _images++;
        imageCall = true;
      }
      final Json result;
      switch (method) {
        case 'captureState':
          keys(params, {});
          result = await api(run).state();
        case 'readSavedPhoto':
          result = await readSavedPhoto(params, run);
        case 'checkFrame':
          keys(params, {'capture_key', 'body_style', 'photo'});
          final value = frame(params);
          result = await api(run).checkFrame(
            bytes: value.bytes,
            mimeType: value.mime,
            captureKey: value.key,
            bodyStyle: value.body,
          );
        case 'saveCapture':
          keys(params, {'capture_key', 'body_style', 'photo', 'operation_id'});
          final value = frame(params);
          final operation = string(params, 'operation_id', 36);
          validateGuidedCaptureOperation(operation);
          result = await save(
            GuidedCapturePending(
              ownerId: ownerId,
              estimateId: estimateId,
              operationId: operation,
              captureKey: value.key,
              bodyStyle: value.body,
              mimeType: value.mime,
              bytes: value.bytes,
            ),
            run,
          );
        case 'recognizeVin':
          keys(params, {'photo_id'});
          result = await api(run).recognize(string(params, 'photo_id', 36));
        case 'confirmVin':
          keys(params, {'photo_id', 'photo_sha256', 'expected_vin', 'vin'});
          string(params, 'photo_id', 36);
          string(params, 'expected_vin', 32, empty: true);
          if (!RegExp(
                r'^[a-f0-9]{64}$',
              ).hasMatch(string(params, 'photo_sha256', 64)) ||
              !RegExp(
                r'^[A-HJ-NPR-Z0-9]{17}$',
              ).hasMatch(string(params, 'vin', 17))) {
            throw const PlusApiException(
              'Review the 17 VIN characters on the label before confirming.',
              422,
            );
          }
          result = await api(run).confirm(params);
        case 'askCaptureHelp':
          keys(params, {'capture_key', 'question'});
          final key = string(params, 'capture_key', 100);
          if (!allowedKey(key)) {
            throw const PlusApiException('Choose a capture step first.', 422);
          }
          result = await api(run).help(key, string(params, 'question', 500));
        case 'close':
          keys(params, {});
          closeRequested = true;
          result = {};
        default:
          throw const PlusApiException(
            'This capture action is unavailable.',
            422,
          );
      }
      if (!valid(run)) return null;
      return {'channel': captureChannel, 'id': id, 'result': result};
    } on PlusApiException catch (error) {
      return valid(run) ? failure(error) : null;
    } on GuidedCapturePendingException catch (error) {
      return valid(run)
          ? failure(
              PlusApiException(
                error.toString(),
                error.failure == GuidedCapturePendingFailure.invalid
                    ? 422
                    : error.failure == GuidedCapturePendingFailure.conflict
                    ? 409
                    : 503,
              ),
            )
          : null;
    } catch (_) {
      return valid(run)
          ? failure(
              const PlusApiException(
                'Capture could not finish. Keep the same photo and retry.',
                500,
              ),
            )
          : null;
    } finally {
      _inFlight--;
      if (imageCall) _images--;
    }
  }
}
