import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/state/plus_controller.dart';

ApiPlusRepository api(
  http.Client client, {
  Future<String?> Function()? token,
}) => ApiPlusRepository(
  baseUrl: 'https://example.test',
  client: client,
  token: token ?? () async => 'token',
);

class StreamClient extends http.BaseClient {
  StreamClient(this.respond);
  final Future<http.StreamedResponse> Function() respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => respond();
}

void main() {
  final streaming =
      <String, (int, Future<dynamic> Function(ApiPlusRepository))>{
        'JSON': (20, (r) => r.getKnowledge()),
        'estimate photo': (20, (r) => r.getPhoto('estimate', 'photo')),
        'vehicle photo': (25, (r) => r.getVehicleImage('car')),
        'capture': (
          45,
          (r) => r.openGuidedCapture('estimate', isCurrent: () => true).state(),
        ),
        'receipt': (
          60,
          (r) => r
              .openReceiptRecord('record', isCurrent: () => true)
              .read('receipt'),
        ),
      };
  for (final entry in streaming.entries) {
    testWidgets('${entry.key} deadline cancels a continuously trickling body', (
      tester,
    ) async {
      var cancelled = false, done = false;
      Object? failure;
      final body = StreamController<List<int>>(
        onCancel: () async {
          cancelled = true;
        },
      );
      final repository = api(
        StreamClient(
          () async => http.StreamedResponse(
            body.stream,
            200,
            headers: {
              'content-type': 'image/webp',
              'x-vehicle-image-source': 'upload',
            },
          ),
        ),
      );
      final pending = entry.value
          .$2(repository)
          .then<void>(
            (_) {
              done = true;
            },
            onError: (Object e) {
              failure = e;
              done = true;
            },
          );
      await tester.pump();
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => body.add([32]),
      );
      for (var tick = 0; tick <= entry.value.$1; tick++) {
        await tester.pump(const Duration(seconds: 1));
      }
      try {
        expect(done, isTrue);
        expect(failure, isA<PlusApiException>());
        expect(cancelled, isTrue);
      } finally {
        timer.cancel();
        unawaited(body.close());
        await pending;
        repository.close();
      }
    });
  }
  testWidgets('headers arriving after timeout have their body cancelled', (
    tester,
  ) async {
    final headers = Completer<http.StreamedResponse>();
    var cancelled = false;
    final body = StreamController<List<int>>(
      onCancel: () async {
        cancelled = true;
      },
    );
    final repository = api(StreamClient(() => headers.future));
    final pending = repository.getKnowledge();
    final check = expectLater(pending, throwsA(isA<PlusApiException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await check;
    headers.complete(http.StreamedResponse(body.stream, 200));
    await tester.pump();
    expect(cancelled, isTrue);
    unawaited(body.close());
    repository.close();
  });
  for (final vehicle in [true, false]) {
    test(
      '${vehicle ? 'vehicle' : 'estimate'} upload freezes bytes while authentication is pending',
      () async {
        final token = Completer<String?>();
        String? sent;
        final repository = api(
          MockClient((r) async {
            sent = utf8.decode(r.bodyBytes, allowMalformed: true);
            return http.Response('{}', 200);
          }),
          token: () => token.future,
        );
        final bytes = Uint8List.fromList([65, 66, 67]);
        final pending = vehicle
            ? repository.uploadVehicleImage('car', bytes, 'photo.jpg')
            : repository.uploadPhoto('estimate', bytes, 'photo.jpg', 'front');
        bytes.setAll(0, [88, 89, 90]);
        token.complete('token');
        await pending;
        expect(sent, contains('ABC'));
        expect(sent, isNot(contains('XYZ')));
        repository.close();
      },
    );
  }
  final operations = <String, Future<dynamic> Function(ApiPlusRepository)>{
    'garage': (r) => r.saveVehicle({'make': 'Ford'}),
    'reminders': (r) => r.addReminder({'title': 'Oil'}),
    'estimates': (r) => r.createEstimate({'description': 'Dent'}),
    'requests': (r) => r.createRequest({'description': 'Help'}, 'key'),
    'history': (r) => r.addKnowledgeRecord({'notes': 'Private'}, 'key'),
    'shops': (r) => r.saveMyShop({'name': 'Shop'}),
    'discovery': (r) => r.discoverProviders({'postal_code': '80202'}),
    'assistant': (r) => r.askAssistant({'message': 'Help'}),
    'calendar': (r) => r.getCalendarStatus(),
    'vehicle photo': (r) =>
        r.uploadVehicleImage('car', Uint8List.fromList([1]), 'a.jpg'),
    'estimate photo': (r) =>
        r.uploadPhoto('estimate', Uint8List.fromList([1]), 'a.jpg', 'front'),
  };
  for (final entry in operations.entries) {
    test(
      '${entry.key} cannot send after account invalidation during token lookup',
      () async {
        final token = Completer<String?>();
        var sends = 0;
        final repository = api(
          MockClient((_) async {
            sends++;
            return http.Response('{}', 200);
          }),
          token: () => token.future,
        );
        final controller = PlusController(repository);
        final pending = entry.value(repository);
        final check = expectLater(pending, throwsA(isA<PlusApiException>()));
        controller.invalidateSession();
        token.complete('token');
        await check;
        expect(sends, 0);
        controller.dispose();
      },
    );
  }
  test(
    'request payload is frozen before token resolution, including nested data',
    () async {
      final token = Completer<String?>();
      String? sent;
      final repository = api(
        MockClient((r) async {
          sent = r.body;
          return http.Response('{}', 200);
        }),
        token: () => token.future,
      );
      final body = <String, dynamic>{
        'description': 'Reviewed',
        'slots': [
          {'start': 'original'},
        ],
      };
      final pending = repository.createRequest(body, 'same-key');
      body['description'] = 'Changed';
      (body['slots'] as List).first['start'] = 'changed';
      token.complete('token');
      await pending;
      expect(jsonDecode(sent!), {
        'description': 'Reviewed',
        'slots': [
          {'start': 'original'},
        ],
      });
      repository.close();
    },
  );
  test('late JSON response after repository shutdown is rejected', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final repository = api(
      MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    final pending = repository.getKnowledge();
    await started.future;
    repository.close();
    final check = expectLater(pending, throwsA(isA<PlusApiException>()));
    response.complete(http.Response('{"records":[]}', 200));
    await check;
  });
  test('oversized JSON response is rejected before decoding', () async {
    final repository = api(
      MockClient(
        (_) async =>
            http.Response(jsonEncode({'value': 'x' * (16 * 1024 * 1024)}), 200),
      ),
    );
    await expectLater(
      repository.getKnowledge(),
      throwsA(isA<PlusApiException>()),
    );
    repository.close();
  });
  testWidgets('token timeout cannot dispatch a mutation later', (tester) async {
    final token = Completer<String?>();
    var sends = 0;
    final repository = api(
      MockClient((_) async {
        sends++;
        return http.Response('{}', 200);
      }),
      token: () => token.future,
    );
    final pending = repository.addReminder({'title': 'Oil'});
    final check = expectLater(pending, throwsA(isA<PlusApiException>()));
    await tester.pump(const Duration(seconds: 21));
    await check;
    token.complete('token');
    await tester.pump();
    expect(sends, 0);
    repository.close();
  });
}
