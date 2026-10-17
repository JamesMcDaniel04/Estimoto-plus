import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/widgets/shop_profile.dart';
import 'package:estimoto_plus/app.dart';
import 'package:estimoto_plus/data/customer_auth.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/demo_seed.dart';
import 'package:estimoto_plus/data/pending_request_store.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/main.dart';
import 'package:estimoto_plus/state/plus_controller.dart';

class DelayedRepository extends DemoPlusRepository {
  final pending = <Completer<PlusSnapshot>>[];
  @override
  Future<PlusSnapshot> bootstrap() {
    final response = Completer<PlusSnapshot>();
    pending.add(response);
    return response.future;
  }
}

class LostResponseRepository extends DemoPlusRepository {
  int calls = 0;
  @override
  Future<Json> createRequest(Json body, String key) async {
    final result = await super.createRequest(body, key);
    if (++calls == 1) throw const PlusApiException('The response was lost.');
    return result;
  }
}

class RejectedProviderRepository extends DemoPlusRepository {
  @override
  Future<Json> createRequest(Json body, String key) async {
    if (body['provider_id'] == (await bootstrap()).providers.first.id) {
      throw const PlusApiException(
        'Provider rejected this request.',
        409,
        'request_not_created',
      );
    }
    return super.createRequest(body, key);
  }
}

class FakeAuth extends CustomerAuth {
  FakeAuth(this.userId);
  @override
  String? userId;
  final changes = StreamController<String?>.broadcast();
  @override
  Stream<String?> get identities => changes.stream;
  @override
  Future<String?> accessToken() async => userId;
  @override
  Future<void> signOut() async {
    userId = null;
    changes.add(null);
  }

  void switchTo(String id) {
    userId = id;
    changes.add(id);
  }
}

class IdentityRepository extends DemoPlusRepository {
  IdentityRepository(this.identity, this.token);
  final String identity;
  final Future<String?> Function() token;
  bool closed = false;
  @override
  bool get isDemo => false;
  @override
  Future<PlusSnapshot> bootstrap() async {
    final seed = demoSeed();
    return PlusSnapshot.fromJson({
      ...seed,
      'profile': {...seed['profile'] as Json, 'id': identity, 'name': identity},
    });
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('a late old refresh cannot overwrite the newer snapshot', () async {
    final repo = DelayedRepository();
    final controller = PlusController(repo);
    final old = controller.refresh();
    final recent = controller.refresh();
    repo.pending[1].complete(
      PlusSnapshot.fromJson({
        'profile': {'id': 'a', 'name': 'New'},
      }),
    );
    await recent;
    repo.pending[0].complete(
      PlusSnapshot.fromJson({
        'profile': {'id': 'a', 'name': 'Old'},
      }),
    );
    await old;
    expect(controller.snapshot!.profile.name, 'New');
    expect(controller.loading, isFalse);
    controller.dispose();
  });
  test(
    'uncertain request survives recreation and blocks an edited replacement',
    () async {
      final repo = LostResponseRepository();
      final store = MemoryPendingRequestStore();
      final first = PlusController(repo, pendingStore: store);
      await first.refresh();
      final provider = first.snapshot!.providers.first;
      final body = <String, dynamic>{
        'vehicle_id': first.selectedVehicle!.id,
        'provider_id': provider.id,
        'specialty': 'pdr',
        'description': 'Dent on the door.',
        'preferred_time': '',
        'share_contact': true,
      };
      await expectLater(
        first.sendRequest(body, provider),
        throwsA(isA<PlusApiException>()),
      );
      first.dispose();
      final reopened = PlusController(repo, pendingStore: store);
      await reopened.refresh();
      expect(reopened.pendingRequest, isNotNull);
      await expectLater(
        reopened.sendRequest({
          ...body,
          'description': 'Different work',
        }, provider),
        throwsA(isA<PlusApiException>()),
      );
      expect((await repo.bootstrap()).requests, hasLength(1));
      final receipt = await reopened.sendRequest(body, provider);
      expect(receipt['id'], (await repo.bootstrap()).requests.single.id);
      expect(reopened.pendingRequest, isNull);
      expect(await store.read(reopened.snapshot!.profile.id), isNull);
      expect(await store.read('different-account'), isNull);
      reopened.dispose();
    },
  );
  test(
    'definitive provider rejection permits choosing another provider after reopening',
    () async {
      final repo = RejectedProviderRepository();
      final store = MemoryPendingRequestStore();
      final controller = PlusController(repo, pendingStore: store);
      await controller.refresh();
      final providers = controller.snapshot!.providers;
      final body = <String, dynamic>{
        'vehicle_id': controller.selectedVehicle!.id,
        'provider_id': providers.first.id,
        'specialty': 'pdr',
        'description': 'Door damage.',
        'share_contact': true,
      };
      await expectLater(
        controller.sendRequest(body, providers.first),
        throwsA(isA<PlusApiException>()),
      );
      expect(controller.pendingRequest, isNull);
      controller.dispose();
      final reopened = PlusController(repo, pendingStore: store);
      await reopened.refresh();
      expect(reopened.pendingRequest, isNull);
      final replacement = await reopened.sendRequest({
        ...body,
        'provider_id': providers[1].id,
        'specialty': 'collision',
      }, providers[1]);
      expect(replacement['status'], 'requested');
      expect((await repo.bootstrap()).requests, hasLength(1));
      reopened.dispose();
    },
  );

  testWidgets('dismissing and reopening restores an uncertain request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = LostResponseRepository();
    final controller = PlusController(repo);
    await controller.refresh();
    await tester.pumpWidget(EstimotoPlusApp(controller: controller));
    await tester.tap(find.byKey(const Key('nav-find-help')));
    await tester.pumpAndSettle();
    Future<void> open() async {
      final shopCard = find.byKey(
        ValueKey('shop-card-${controller.snapshot!.providers.first.id}'),
      );
      await tester.ensureVisible(shopCard);
      await tester.tap(shopCard);
      await tester.pumpAndSettle();
      final action = find.descendant(
        of: find.byType(ShopProfile),
        matching: find.text('Request help'),
      );
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    Future<void> send() async {
      final consent = find.byKey(const Key('share-contact'));
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      final action = find.byKey(const Key('send-request'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    await open();
    await tester.enterText(
      find.byKey(const Key('request-description')),
      'A dent on the door needs repair.',
    );
    await send();
    expect((await repo.bootstrap()).requests, hasLength(1));
    Navigator.of(tester.element(find.text('Review your request'))).pop();
    await tester.pumpAndSettle();
    await open();
    expect(
      find.textContaining('A previous send has an uncertain outcome'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('request-description')))
          .enabled,
      isFalse,
    );
    await send();
    expect((await repo.bootstrap()).requests, hasLength(1));
    expect(controller.tab, 3);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'auth errors are handled and account switch replaces customer state',
    (tester) async {
      final auth = FakeAuth('CustomerA');
      addTearDown(auth.changes.close);
      final repositories = <IdentityRepository>[];
      await tester.pumpWidget(
        PlusLauncher(
          auth: auth,
          pendingStore: MemoryPendingRequestStore(),
          repositoryFactory: (token) {
            final repo = IdentityRepository(auth.userId!, token);
            repositories.add(repo);
            return repo;
          },
        ),
      );
      await tester.pumpAndSettle();
      final old = tester
          .widget<EstimotoPlusApp>(find.byType(EstimotoPlusApp))
          .controller;
      expect(old.snapshot!.profile.name, 'CustomerA');
      old.messages.add(ChatEntry.user('Private A conversation'));
      auth.changes.addError(
        Exception('sensitive upstream error'),
        StackTrace.current,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your sign-in could not refresh'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      auth.switchTo('CustomerA');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EstimotoPlusApp>(find.byType(EstimotoPlusApp)).controller,
        same(old),
      );
      auth.switchTo('CustomerB');
      await tester.pumpAndSettle();
      final current = tester
          .widget<EstimotoPlusApp>(find.byType(EstimotoPlusApp))
          .controller;
      expect(current, isNot(same(old)));
      expect(current.snapshot!.profile.name, 'CustomerB');
      expect(current.messages, isEmpty);
      expect(repositories.first.closed, isTrue);
      await expectLater(
        repositories.first.token(),
        throwsA(isA<PlusApiException>()),
      );
      expect(await repositories.last.token(), 'CustomerB');
      expect(find.textContaining('Private A'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
