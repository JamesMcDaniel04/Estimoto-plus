import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/services/guided_capture_api.dart';
import 'package:estimoto_plus/services/guided_capture_pending.dart';
import 'package:estimoto_plus/services/guided_capture_session.dart';
import 'package:estimoto_plus/state/plus_controller.dart';

class CaptureApiFake extends GuidedCaptureApi {
  final calls = <String>[];
  final saves = <GuidedCapturePending>[];
  Completer<Json>? saving;
  Completer<Json>? readingState;
  PlusApiException? saveError;
  bool superseded = false;
  List<Json>? photos;
  Uint8List readBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  String readMime = 'image/png';
  Completer<({Uint8List bytes, String mimeType})>? reading;
  @override
  Future<({Uint8List bytes, String mimeType})> readPhoto(String photoId) async {
    calls.add('read:$photoId');
    return reading?.future ?? (bytes: readBytes, mimeType: readMime);
  }

  @override
  Uri get pageUri => Uri.parse('https://plus.example.test/capture/');
  @override
  Future<Json> state() async {
    calls.add('state');
    if (readingState != null) return readingState!.future;
    return {
      'photos':
          photos ??
          (saves.isEmpty
              ? []
              : [
                  {
                    'id': 'photo-1',
                    'label': saves.last.captureKey,
                    'sha256': superseded ? 'b' * 64 : saves.last.sha256,
                  },
                ]),
    };
  }

  @override
  Future<Json> save(GuidedCapturePending photo) async {
    calls.add('save');
    saves.add(photo);
    if (saveError != null) throw saveError!;
    if (saving != null) return saving!.future;
    return {
      'id': 'photo-1',
      'label': photo.captureKey,
      'sha256': photo.sha256,
      'quality': 'not_checked',
    };
  }

  @override
  Future<Json> checkFrame({
    required Uint8List bytes,
    required String mimeType,
    required String captureKey,
    required String bodyStyle,
  }) async {
    calls.add('check');
    return {'ready': true, 'available': true, 'instruction': 'Ready'};
  }

  @override
  Future<Json> recognize(String photoId) async {
    calls.add('recognize');
    return {
      'suggested_vin': '1HGBH41JXMN109186',
      'requires_confirmation': true,
    };
  }

  @override
  Future<Json> confirm(Json body) async {
    calls.add('confirm');
    return {'confirmed': true};
  }

  @override
  Future<Json> help(String captureKey, String question) async {
    calls.add('help');
    return {'reply': 'Capture guidance'};
  }
}

class CaptureRepositoryFake extends DemoPlusRepository {
  final api = CaptureApiFake();
  @override
  GuidedCaptureApi openGuidedCapture(
    String estimateId, {
    required bool Function() isCurrent,
  }) => api;
}

Future<GuidedCaptureSession> session(
  CaptureRepositoryFake repo,
  GuidedCapturePendingStore store,
) async {
  final c = PlusController(repo);
  await c.refresh();
  final estimate = await repo.createEstimate({
    'vehicle_id': c.selectedVehicle!.id,
    'discipline': 'pdr',
    'description': 'Door dent',
  });
  await c.refresh();
  return GuidedCaptureSession(
    controller: c,
    estimateId: textOf(estimate, 'id'),
    store: store,
  )..activate();
}

String rpc(String id, String method, [Json params = const {}]) => jsonEncode({
  'channel': captureChannel,
  'id': id,
  'method': method,
  'params': params,
});
Json photoBody([String operation = '11111111-1111-4111-8111-111111111111']) => {
  'operation_id': operation,
  'capture_key': 'vin',
  'body_style': 'suv',
  'photo': {
    'base64': base64Encode([1, 2, 3]),
    'mime_type': 'image/png',
  },
};

void main() {
  testWidgets(
    'review state deadline releases the image slot for another capture',
    (tester) async {
      final repo = CaptureRepositoryFake();
      final hash = sha256.convert(repo.api.readBytes).toString();
      final s = await session(repo, MemoryGuidedCapturePendingStore());
      repo.api.readingState = Completer();
      Json? response;
      final request = s
          .receive(
            rpc('slow-state', 'readSavedPhoto', {
              'photo_id': 'photo-1',
              'photo_sha256': hash,
            }),
          )
          .then((value) {
            response = value;
          });
      await tester.pump(const Duration(seconds: 5));
      expect(response?['error']['status'], 408);
      final next = await s.receive(
        rpc('check-after-timeout', 'checkFrame', {
          'capture_key': 'vin',
          'body_style': 'suv',
          'photo': {'base64': 'AQID', 'mime_type': 'image/png'},
        }),
      );
      expect(next?['result']['ready'], isTrue);
      repo.api.readingState!.complete({'photos': []});
      await request;
    },
  );
  test('saved photo review returns only verified active image bytes', () async {
    final repo = CaptureRepositoryFake();
    final hash = sha256.convert(repo.api.readBytes).toString();
    repo.api.photos = [
      {'id': 'photo-1', 'label': 'vin', 'sha256': hash},
    ];
    final s = await session(repo, MemoryGuidedCapturePendingStore());
    final response = await s.receive(
      rpc('review', 'readSavedPhoto', {
        'photo_id': 'photo-1',
        'photo_sha256': hash,
      }),
    );
    expect(response?['result'], {
      'id': 'photo-1',
      'sha256': hash,
      'mime_type': 'image/png',
      'base64': base64Encode(repo.api.readBytes),
    });
  });
  test(
    'review rejects caller identity, stale hash and unknown photo before reading',
    () async {
      final repo = CaptureRepositoryFake();
      final hash = sha256.convert(repo.api.readBytes).toString();
      repo.api.photos = [
        {'id': 'photo-1', 'label': 'vin', 'sha256': hash},
      ];
      final s = await session(repo, MemoryGuidedCapturePendingStore());
      for (final params in [
        {'photo_id': 'photo-1', 'photo_sha256': hash, 'estimate_id': 'other'},
        {'photo_id': 'foreign', 'photo_sha256': hash},
        {'photo_id': 'photo-1', 'photo_sha256': 'a' * 64},
      ]) {
        final response = await s.receive(
          rpc('review-${params.hashCode}', 'readSavedPhoto', params),
        );
        expect(response?['error'], isNotNull);
      }
      expect(repo.api.calls.where((call) => call.startsWith('read:')), isEmpty);
    },
  );
  test('review withholds mismatched bytes and unsafe image formats', () async {
    final repo = CaptureRepositoryFake();
    final hash = sha256.convert(repo.api.readBytes).toString();
    repo.api.photos = [
      {'id': 'photo-1', 'label': 'vin', 'sha256': hash},
    ];
    final s = await session(repo, MemoryGuidedCapturePendingStore());
    repo.api.readBytes = Uint8List.fromList([1, 2, 3]);
    final changed = await s.receive(
      rpc('changed', 'readSavedPhoto', {
        'photo_id': 'photo-1',
        'photo_sha256': hash,
      }),
    );
    expect(changed?['error'], isNotNull);
    repo.api.photos![0]['sha256'] = sha256
        .convert(repo.api.readBytes)
        .toString();
    final unsafe = await s.receive(
      rpc('unsafe', 'readSavedPhoto', {
        'photo_id': 'photo-1',
        'photo_sha256': repo.api.photos![0]['sha256'],
      }),
    );
    expect(unsafe?['error'], isNotNull);
  });
  test(
    'review drops late bytes when paused and when photo is replaced during read',
    () async {
      for (final pause in [true, false]) {
        final repo = CaptureRepositoryFake();
        final hash = sha256.convert(repo.api.readBytes).toString();
        repo.api.photos = [
          {'id': 'photo-1', 'label': 'vin', 'sha256': hash},
        ];
        repo.api.reading = Completer();
        final s = await session(repo, MemoryGuidedCapturePendingStore());
        final request = s.receive(
          rpc('late', 'readSavedPhoto', {
            'photo_id': 'photo-1',
            'photo_sha256': hash,
          }),
        );
        await Future<void>.delayed(Duration.zero);
        if (pause) {
          s.pause();
        } else {
          repo.api.photos![0]['sha256'] = 'b' * 64;
        }
        repo.api.reading!.complete((
          bytes: repo.api.readBytes,
          mimeType: repo.api.readMime,
        ));
        final response = await request;
        if (pause) {
          expect(response, isNull);
        } else {
          expect(response?['error']['status'], 409);
        }
      }
    },
  );
  test(
    'external gallery handoff waits for foreground and fails closed after disposal',
    () async {
      final s = await session(
        CaptureRepositoryFake(),
        MemoryGuidedCapturePendingStore(),
      );
      s.foreground = false;
      s.pause();
      var completed = false;
      final resumed = s.waitForForeground().then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      s.foreground = true;
      s.activate();
      expect(await resumed, isTrue);
      s.foreground = false;
      s.pause();
      final cancelled = s.waitForForeground();
      s.dispose();
      expect(await cancelled, isFalse);
    },
  );
  test(
    'only the exact first-party page, bounded message shape and known actions are accepted',
    () async {
      final expected = Uri.parse('https://plus.example.test/capture/');
      for (final bad in [
        'about:blank',
        'https://evil.test/capture/',
        'https://plus.example.test/',
        'https://plus.example.test/capture/?token=secret',
        'https://user@plus.example.test/capture/',
        'https://plus.example.test/capture/#other',
      ]) {
        expect(trustedCapturePage(expected, bad), isFalse, reason: bad);
      }
      expect(trustedCapturePage(expected, expected.toString()), isTrue);
      expect(boundedCaptureMessage('[' * 100 + ']' * 100), isFalse);
      final repo = CaptureRepositoryFake();
      final s = await session(repo, MemoryGuidedCapturePendingStore());
      expect(await s.receive('x' * (maxCaptureMessageLength + 1)), isNull);
      expect(await s.receive('{"channel":"foreign"}'), isNull);
      expect(
        (await s.receive(
          rpc('unknown', 'fetch', {'url': 'https://evil.test'}),
        ))?['error']['status'],
        422,
      );
      expect(
        (await s.receive(
          rpc('identity', 'captureState', {'estimate_id': 'someone-else'}),
        ))?['error']['status'],
        422,
      );
      expect(repo.api.calls, isEmpty);
      expect(
        (await s.receive(rpc('one', 'captureState')))?['result'],
        isNotNull,
      );
      expect(await s.receive(rpc('one', 'captureState')), isNull);
      expect(repo.api.calls, ['state']);
    },
  );
  test(
    'only bounded canonical image data and discipline capture keys reach the API',
    () async {
      final repo = CaptureRepositoryFake();
      final s = await session(repo, MemoryGuidedCapturePendingStore());
      for (final body in [
        {...photoBody(), 'capture_key': 'panel_front_bumper'},
        {...photoBody(), 'body_style': 'unknown'},
        {
          ...photoBody(),
          'photo': {'base64': 'data:image/png,AAAA', 'mime_type': 'image/png'},
        },
        {
          ...photoBody(),
          'photo': {'base64': 'AAAA', 'mime_type': 'text/html'},
        },
        {...photoBody(), 'operation_id': '../other'},
      ]) {
        final response = await s.receive(
          rpc('bad-${body.hashCode}', 'saveCapture', body),
        );
        expect(response?['error']['status'], 422);
      }
      expect(repo.api.calls, isEmpty);
    },
  );
  test(
    'timeout retains exact durable bytes and operation; an acknowledged retry clears only that operation',
    () async {
      final repo = CaptureRepositoryFake()
        ..api.saveError = const PlusApiException('Timed out', 408);
      final store = MemoryGuidedCapturePendingStore();
      final s = await session(repo, store);
      final first = await s.receive(rpc('first', 'saveCapture', photoBody()));
      expect(first?['error']['status'], 408);
      final pending = (await store.read(s.ownerId))!;
      expect(pending.bytes, [1, 2, 3]);
      repo.api.saveError = null;
      final second = await s.receive(rpc('retry', 'saveCapture', photoBody()));
      expect(second?['result']['sha256'], pending.sha256);
      expect(repo.api.saves[0].samePayload(repo.api.saves[1]), isTrue);
      expect(await store.read(s.ownerId), isNull);
    },
  );
  test(
    'a changed operation cannot overwrite uncertain capture bytes',
    () async {
      final repo = CaptureRepositoryFake()
        ..api.saveError = const PlusApiException('Busy', 503);
      final store = MemoryGuidedCapturePendingStore();
      final s = await session(repo, store);
      await s.receive(rpc('first', 'saveCapture', photoBody()));
      final response = await s.receive(
        rpc(
          'new',
          'saveCapture',
          photoBody('22222222-2222-4222-8222-222222222222'),
        ),
      );
      expect(response?['error']['status'], 409);
      expect(repo.api.saves, hasLength(1));
      expect(
        (await store.read(s.ownerId))?.operationId,
        photoBody()['operation_id'],
      );
    },
  );
  test(
    'definitive retake and superseded receipts allow new capture without claiming the old image is active',
    () async {
      final repo = CaptureRepositoryFake()
        ..api.saveError = const PlusApiException('Retake', 422);
      final store = MemoryGuidedCapturePendingStore();
      final s = await session(repo, store);
      expect(
        (await s.receive(
          rpc('retake', 'saveCapture', photoBody()),
        ))?['error']['status'],
        422,
      );
      expect(await store.read(s.ownerId), isNull);
      repo.api.saveError = null;
      repo.api.superseded = true;
      final result = await s.receive(
        rpc('superseded', 'saveCapture', photoBody()),
      );
      expect(result?['error']['code'], 'capture_superseded');
      expect(result?['result'], isNull);
      expect(await store.read(s.ownerId), isNull);
    },
  );
  test(
    'pause resume or account change during a save drops old replies and retains recovery',
    () async {
      final repo = CaptureRepositoryFake()..api.saving = Completer<Json>();
      final store = MemoryGuidedCapturePendingStore();
      final s = await session(repo, store);
      final response = s.receive(rpc('saving', 'saveCapture', photoBody()));
      await Future<void>.delayed(Duration.zero);
      final saved = repo.api.saves.single;
      s.pause();
      s.activate();
      repo.api.saving!.complete({
        'id': 'photo-1',
        'label': saved.captureKey,
        'sha256': saved.sha256,
      });
      expect(await response, isNull);
      expect(await store.read(s.ownerId), isNotNull);
      s.controller.invalidateSession();
      expect(await s.receive(rpc('after-switch', 'captureState')), isNull);
      expect(repo.api.calls, ['save']);
    },
  );
  test(
    'OCR suggestion does not confirm VIN and close never submits the estimate',
    () async {
      final repo = CaptureRepositoryFake();
      final s = await session(repo, MemoryGuidedCapturePendingStore());
      await s.receive(rpc('ocr', 'recognizeVin', {'photo_id': 'photo-1'}));
      expect(repo.api.calls, ['recognize']);
      final invalid = await s.receive(
        rpc('confirm-bad', 'confirmVin', {
          'photo_id': 'photo-1',
          'expected_vin': '',
          'vin': '1HGBH41JXMN109186',
        }),
      );
      expect(invalid?['error']['status'], 422);
      await s.receive(
        rpc('confirm', 'confirmVin', {
          'photo_id': 'photo-1',
          'photo_sha256': 'a' * 64,
          'expected_vin': '',
          'vin': '1HGBH41JXMN109186',
        }),
      );
      await s.receive(rpc('close', 'close'));
      expect(s.closeRequested, isTrue);
      expect(repo.api.calls, ['recognize', 'confirm']);
      expect(
        s.controller.snapshot!.estimates
            .firstWhere((e) => e.id == s.estimateId)
            .status,
        'draft',
      );
    },
  );
}
