import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/services/guided_capture_pending.dart';

void main() {
  test(
    'saved image header rejection cancels the unconsumed response body',
    () async {
      for (final status in [401, 302, 200, -1]) {
        var cancelled = false, current = true;
        final stream = StreamController<List<int>>(
          onCancel: () async {
            cancelled = true;
          },
        );
        final repository = ApiPlusRepository(
          baseUrl: 'https://plus.example.test',
          token: () async => 'owner',
          client: MockClient.streaming((request, body) async {
            if (status == -1) current = false;
            return http.StreamedResponse(
              stream.stream,
              status == -1 ? 200 : status,
              headers: {
                'content-type': status == 200 ? 'image/svg+xml' : 'image/png',
              },
            );
          }),
        );
        final api = repository.openGuidedCapture(
          'estimate-1',
          isCurrent: () => current,
        );
        await expectLater(
          api.readPhoto('photo-1'),
          throwsA(isA<PlusApiException>()),
        );
        expect(
          cancelled,
          isTrue,
          reason: 'Response $status must cancel its body',
        );
        unawaited(stream.close());
      }
    },
  );
  testWidgets(
    'saved image total deadline cancels a continuously progressing body',
    (tester) async {
      var cancelled = false;
      Timer? ticks;
      final stream = StreamController<List<int>>(
        onCancel: () async {
          cancelled = true;
          ticks?.cancel();
        },
      );
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'owner',
        client: MockClient.streaming((request, body) async {
          ticks = Timer.periodic(
            const Duration(seconds: 2),
            (_) => stream.add([1]),
          );
          return http.StreamedResponse(
            stream.stream,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => true,
      );
      Object? failure;
      var complete = false;
      final pending = api
          .readPhoto('photo-1')
          .then<void>(
            (_) {
              complete = true;
            },
            onError: (Object error) {
              failure = error;
              complete = true;
            },
          );
      await tester.pump();
      for (var tick = 0; tick < 8; tick++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(complete, isTrue);
      expect(
        failure,
        isA<PlusApiException>().having(
          (error) => error.statusCode,
          'status',
          408,
        ),
      );
      expect(cancelled, isTrue);
      ticks?.cancel();
      unawaited(stream.close());
      await pending;
    },
  );
  test(
    'saved image transport binds private path and never exposes auth to the page',
    () async {
      final requests = <http.Request>[];
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'private-token',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response.bytes(
            image,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => true,
      );
      final dynamic result = await api.readPhoto('photo-1');
      expect(result.bytes, image);
      expect(result.mimeType, 'image/png');
      expect(
        requests.single.url.toString(),
        'https://plus.example.test/v1/estimates/estimate-1/photos/photo-1',
      );
      expect(requests.single.headers['Authorization'], 'Bearer private-token');
      expect(requests.single.followRedirects, isFalse);
    },
  );
  test(
    'saved image read checks account after resolving auth before sending',
    () async {
      var current = true, sends = 0;
      final token = Completer<String?>();
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () => token.future,
        client: MockClient((r) async {
          sends++;
          return http.Response('', 200);
        }),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => current,
      );
      final Future<dynamic> pending = api.readPhoto('photo-1');
      current = false;
      token.complete('different-owner');
      await expectLater(pending, throwsA(isA<PlusApiException>()));
      expect(sends, 0);
    },
  );
  test(
    'saved image read rejects unsafe content, redirects and oversized responses',
    () async {
      var response = http.Response(
        '<svg/>',
        200,
        headers: {'content-type': 'image/svg+xml'},
      );
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'owner',
        client: MockClient((r) async => response),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => true,
      );
      for (final next in [
        response,
        http.Response('', 302, headers: {'location': 'https://evil.test'}),
        http.Response.bytes(
          Uint8List(10 * 1024 * 1024 + 1),
          200,
          headers: {'content-type': 'image/png'},
        ),
      ]) {
        response = next;
        await expectLater(
          api.readPhoto('photo-1'),
          throwsA(isA<PlusApiException>()),
        );
      }
    },
  );
  test(
    'capture transport binds path and auth outside the page and preserves exact multipart operation',
    () async {
      final requests = <http.Request>[];
      final dynamic repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'private-token',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 200);
        }),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => true,
      );
      expect(api.pageUri.toString(), 'https://plus.example.test/capture/');
      await api.state();
      final pending = GuidedCapturePending(
        ownerId: 'customer-1',
        estimateId: 'estimate-1',
        operationId: '11111111-1111-4111-8111-111111111111',
        captureKey: 'vin',
        bodyStyle: 'suv',
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await api.save(pending);
      await api.recognize('photo-1');
      await api.confirm({
        'photo_id': 'photo-1',
        'photo_sha256': 'a' * 64,
        'expected_vin': '',
        'vin': '1HGBH41JXMN109186',
      });
      expect(requests.map((r) => r.url.path), [
        '/v1/estimates/estimate-1/capture',
        '/v1/estimates/estimate-1/capture/photos',
        '/v1/estimates/estimate-1/capture/vin/recognize',
        '/v1/estimates/estimate-1/capture/vin/confirm',
      ]);
      for (final request in requests) {
        expect(request.headers['Authorization'], 'Bearer private-token');
        expect(request.url.hasQuery, isFalse);
        expect(request.followRedirects, isFalse);
      }
      expect(requests[1].body, contains(pending.operationId));
      expect(requests[1].body, contains('name="photo"'));
      expect(requests[1].body, contains('image/png'));
      expect(jsonDecode(requests[2].body), {'photo_id': 'photo-1'});
      expect(jsonDecode(requests[3].body)['photo_sha256'], 'a' * 64);
    },
  );
  test(
    'capture account or page invalidation while auth resolves prevents network I/O',
    () async {
      var current = true, sends = 0;
      final token = Completer<String?>();
      final dynamic repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () => token.future,
        client: MockClient((r) async {
          sends++;
          return http.Response('{}', 200);
        }),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => current,
      );
      final Future<dynamic> request = api.state();
      current = false;
      token.complete('new-account-token');
      await expectLater(request, throwsA(isA<PlusApiException>()));
      expect(sends, 0);
    },
  );
  test(
    'capture errors preserve status and allow only safe known recovery text',
    () async {
      var response = http.Response('{"detail":"secret provider headers"}', 503);
      final dynamic repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'owner',
        client: MockClient((r) async => response),
      );
      final dynamic api = repository.openGuidedCapture(
        'estimate-1',
        isCurrent: () => true,
      );
      await expectLater(
        api.state(),
        throwsA(
          isA<PlusApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
      response = http.Response(
        '{"detail":"This capture expired. Take the photo again."}',
        422,
      );
      await expectLater(
        api.state(),
        throwsA(
          isA<PlusApiException>()
              .having((e) => e.statusCode, 'status', 422)
              .having(
                (e) => e.message,
                'message',
                'This capture expired. Take the photo again.',
              ),
        ),
      );
    },
  );
}
