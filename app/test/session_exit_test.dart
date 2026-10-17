import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/app.dart';
import 'package:estimoto_plus/data/customer_auth.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/demo_seed.dart';
import 'package:estimoto_plus/data/pending_request_store.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/main.dart';

class _DelayedAuth extends CustomerAuth {
  @override
  String? userId = 'customer-a';
  final changes = StreamController<String?>.broadcast();
  final exits = <Completer<void>>[];
  @override
  Stream<String?> get identities => changes.stream;
  @override
  Future<String?> accessToken() async => userId;
  @override
  Future<void> signOut() {
    final exit = Completer<void>();
    exits.add(exit);
    return exit.future;
  }

  void switchTo(String id) {
    userId = id;
    changes.add(id);
  }
}

class _Repository extends DemoPlusRepository {
  _Repository(this.owner);
  final String owner;
  @override
  bool get isDemo => false;
  @override
  Future<PlusSnapshot> bootstrap() async {
    final seed = demoSeed();
    return PlusSnapshot.fromJson({
      ...seed,
      'profile': {...seed['profile'] as Json, 'id': owner, 'name': owner},
      'capabilities': {...seed['capabilities'] as Json, 'demo': false},
    });
  }
}

Future<_DelayedAuth> _mount(WidgetTester tester) async {
  final auth = _DelayedAuth();
  addTearDown(auth.changes.close);
  await tester.pumpWidget(
    PlusLauncher(
      auth: auth,
      pendingStore: MemoryPendingRequestStore(),
      repositoryFactory: (_) => _Repository(auth.userId!),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

EstimotoPlusApp _app(WidgetTester tester) =>
    tester.widget<EstimotoPlusApp>(find.byType(EstimotoPlusApp));

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      'late sign-out ${fail ? 'failure' : 'success'} cannot affect the replacement account',
      (tester) async {
        final auth = await _mount(tester);
        _app(tester).onExit!();
        expect(auth.exits, hasLength(1));
        auth.switchTo('customer-b');
        await tester.pumpAndSettle();
        final replacement = _app(tester).controller;
        expect(replacement.snapshot!.profile.id, 'customer-b');
        if (fail) {
          auth.exits.single.completeError(Exception('A sign-out failed'));
        } else {
          auth.exits.single.complete();
        }
        await tester.pumpAndSettle();
        expect(find.byType(EstimotoPlusApp), findsOneWidget);
        expect(_app(tester).controller, same(replacement));
        expect(replacement.snapshot!.profile.id, 'customer-b');
        expect(replacement.error, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a captured old exit callback cannot sign out the new account', (
    tester,
  ) async {
    final auth = await _mount(tester);
    final oldExit = _app(tester).onExit!;
    auth.switchTo('customer-b');
    await tester.pumpAndSettle();
    oldExit();
    await tester.pump();
    expect(auth.exits, isEmpty);
    expect(_app(tester).controller.snapshot!.profile.id, 'customer-b');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'duplicate exit is suppressed and a failed current exit can retry',
    (tester) async {
      final auth = await _mount(tester);
      final current = _app(tester).controller;
      final exit = _app(tester).onExit!;
      exit();
      exit();
      expect(auth.exits, hasLength(1));
      auth.exits.first.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(_app(tester).controller, same(current));
      expect(current.error, contains('Your sign-in could not refresh'));
      exit();
      expect(auth.exits, hasLength(2));
      auth.exits.last.complete();
      await tester.pumpAndSettle();
      expect(find.byType(EstimotoPlusApp), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old exit completion does not unlock the new account pending exit',
    (tester) async {
      final auth = await _mount(tester);
      _app(tester).onExit!();
      auth.switchTo('customer-b');
      await tester.pumpAndSettle();
      final replacement = _app(tester).controller;
      final newExit = _app(tester).onExit!;
      newExit();
      expect(auth.exits, hasLength(2));
      auth.exits.first.complete();
      await tester.pumpAndSettle();
      newExit();
      expect(auth.exits, hasLength(2));
      expect(_app(tester).controller, same(replacement));
      auth.exits.last.complete();
      await tester.pumpAndSettle();
      expect(find.byType(EstimotoPlusApp), findsNothing);
    },
  );
}
