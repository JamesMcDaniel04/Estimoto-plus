import 'dart:async';
import 'package:estimoto_plus/services/receipt_pending_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/navigation/route_observer.dart';
import 'package:estimoto_plus/screens/my_shops_screen.dart';
import 'package:estimoto_plus/screens/shop_outreach_screen.dart';
import 'package:estimoto_plus/screens/history_screen.dart';
import 'package:estimoto_plus/services/customer_workspace.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _Repository extends DemoPlusRepository {
  _Repository({this.phoneOnly = false, this.failFirst = false});
  final bool phoneOnly, failFirst;
  final keys = <String>[];
  final bodies = <Json>[];
  Completer<Json>? detail;
  late Json draft = {
    'id': 'draft-1',
    'shop_name': 'Trusted Neighborhood Maintenance Shop',
    'recipient_email': phoneOnly ? '' : 'reviewed-shop@example.test',
    'recipient_phone': '+13035550123',
    'subject': 'Your exact subject',
    'message': 'Please check the brakes. Do not replace parts without asking.',
    'shared_contact': {
      'name': 'Original Customer',
      'email': 'original@example.test',
      'phone': '+13035550001',
    },
    'vehicle_summary': '2022 Audi Q5',
    'proposed_slots': [
      offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
    ],
    'review_hash': List.filled(64, 'a').join(),
    'status': 'draft',
    'delivery_status': 'draft',
  };
  @override
  Future<Json> getShopOutreach(String id) async =>
      detail == null ? Map.of(draft) : detail!.future;
  @override
  Future<Json> withdrawShopOutreach(String id) async {
    draft = {...draft, 'status': 'withdrawn'};
    return Map.of(draft);
  }

  @override
  Future<Json> authorizeShopOutreach(String id, Json body, String key) async {
    keys.add(key);
    bodies.add(Map.of(body));
    if (failFirst && keys.length == 1) {
      throw const PlusApiException(
        'Connection lost. Recover your saved authorization.',
      );
    }
    draft = {
      ...draft,
      'status': phoneOnly ? 'call_required' : 'queued',
      'delivery_status': phoneOnly ? 'not_sent' : 'queued',
      'call_link': phoneOnly ? 'tel:+13035550123' : null,
    };
    return Map.of(draft);
  }
}

Future<PlusController> _controller([DemoPlusRepository? repository]) async {
  final controller = PlusController(repository ?? DemoPlusRepository());
  await controller.refresh();
  return controller;
}

Future<void> _mount(
  WidgetTester tester,
  Widget screen, {
  double scale = 1.8,
}) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'actual demo phone-only authorization exposes reviewed call link',
    (tester) async {
      final launches = <String>[];
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
        call,
      ) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcher,
          null,
        ),
      );
      final repository = DemoPlusRepository();
      final controller = await _controller(repository);
      final shop = await repository.saveMyShop({
        'name': 'Sample phone shop',
        'phone': '(303) 555-0123',
      });
      final draft = await repository.createShopOutreach({
        'shop_id': shop['id'],
        'service_summary': 'Inspect brakes',
        'proposed_slots': [
          offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
        ],
      }, 'demo-phone-draft');
      await _mount(
        tester,
        ShopOutreachReview(controller: controller, draftId: draft['id']),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Continue to call'),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, find.byKey(const Key('outreach-consent')));
      await _tap(tester, find.widgetWithText(FilledButton, 'Continue to call'));
      expect(find.text('Call Sample phone shop'), findsOneWidget);
      expect(find.text('Call the shop • not sent'), findsOneWidget);
      final saved = await repository.getShopOutreach(draft['id']);
      expect(saved['call_link'], 'tel:3035550123');
      expect(saved['delivery_status'], 'local_preview');
      expect(launches, isEmpty);
      await _tap(tester, find.text('Call Sample phone shop'));
      expect(launches, ['tel:3035550123']);
      expect(find.text('Shop confirmed'), findsNothing);
      expect(find.text('Waiting for shop response'), findsNothing);
      controller.dispose();
    },
  );

  testWidgets(
    'immutable outreach review requires explicit consent at 320px large text',
    (tester) async {
      final repository = _Repository(), controller = await _controller();
      final liveController = await _controller(repository);
      await repository.saveProfile({
        'name': 'Changed after draft',
      });
      await liveController.refresh();
      await _mount(
        tester,
        ShopOutreachReview(controller: liveController, draftId: 'draft-1'),
      );
      expect(find.text('reviewed-shop@example.test'), findsOneWidget);
      expect(find.textContaining('Original Customer'), findsOneWidget);
      expect(find.textContaining('Changed after draft'), findsNothing);
      expect(find.textContaining('Do not replace parts'), findsOneWidget);
      expect(find.textContaining('UTC'), findsWidgets);
      final button = find.widgetWithText(
        FilledButton,
        'Authorize and send request',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(repository.keys, isEmpty);
      await _tap(tester, find.byKey(const Key('outreach-consent')));
      await _tap(tester, button);
      expect(repository.bodies.single, {
        'share_contact': true,
        'review_hash': List.filled(64, 'a').join(),
      });
      expect(find.text('Queued for delivery'), findsOneWidget);
      expect(find.text('Shop confirmed'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'interrupted authorization recovers with original key without another send consent',
    (tester) async {
      final repository = _Repository(failFirst: true),
          controller = await _controller();
      final owner = await _controller(repository);
      await _mount(
        tester,
        ShopOutreachReview(controller: owner, draftId: 'draft-1'),
        scale: 1,
      );
      await _tap(tester, find.byKey(const Key('outreach-consent')));
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Authorize and send request'),
      );
      expect(find.textContaining('Connection lost'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _mount(
        tester,
        ShopOutreachReview(controller: owner, draftId: 'draft-1'),
        scale: 1,
      );
      expect(find.byKey(const Key('outreach-consent')), findsNothing);
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Recover authorized request'),
      );
      expect(repository.keys, hasLength(2));
      expect(repository.keys[0], repository.keys[1]);
      expect(find.text('Queued for delivery'), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'phone-only authorization offers a call and never claims a message or booking',
    (tester) async {
      final repository = _Repository(phoneOnly: true),
          controller = await _controller();
      final owner = await _controller(repository);
      await _mount(
        tester,
        ShopOutreachReview(controller: owner, draftId: 'draft-1'),
      );
      expect(find.text('Authorize and send request'), findsNothing);
      await _tap(tester, find.byKey(const Key('outreach-consent')));
      await _tap(tester, find.widgetWithText(FilledButton, 'Continue to call'));
      expect(find.text('Call the shop • not sent'), findsOneWidget);
      expect(
        find.text('Call Trusted Neighborhood Maintenance Shop'),
        findsOneWidget,
      );
      expect(find.text('Waiting for shop response'), findsNothing);
      expect(find.text('Shop confirmed'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'late response after account invalidation cannot reveal private draft',
    (tester) async {
      final repository = _Repository()..detail = Completer<Json>();
      final controller = await _controller(repository);
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ShopOutreachReview(controller: controller, draftId: 'draft-1'),
        ),
      );
      await tester.pump();
      controller.invalidateSession();
      repository.detail!.complete(repository.draft);
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: ShopOutreachReview(controller: controller, draftId: 'draft-1'),
        ),
      );
      await tester.pump();
      expect(find.text('reviewed-shop@example.test'), findsNothing);
      expect(find.textContaining('Original Customer'), findsNothing);
      expect(repository.keys, isEmpty);
    },
  );

  testWidgets('stale preferred times cannot authorize a new email request', (
    tester,
  ) async {
    final repository = _Repository();
    repository.draft['proposed_slots'] = [
      offsetTimestamp(DateTime.now().subtract(const Duration(days: 1))),
    ];
    final controller = await _controller(repository);
    await _mount(
      tester,
      ShopOutreachReview(controller: controller, draftId: 'draft-1'),
    );
    expect(
      find.textContaining('These preferred times are too near'),
      findsOneWidget,
    );
    expect(find.text('Authorize and send request'), findsNothing);
    expect(repository.keys, isEmpty);
  });

  testWidgets(
    'reusing a route with another controller hides the previous customer',
    (tester) async {
      final first = await _controller(_Repository());
      final second = await _controller();
      await tester.pumpWidget(
        MaterialApp(
          home: ShopOutreachReview(controller: first, draftId: 'draft-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('reviewed-shop@example.test'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: ShopOutreachReview(controller: second, draftId: 'draft-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('reviewed-shop@example.test'), findsNothing);
      expect(find.text('Sign in to view your saved details.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shop save/edit and history routes fit narrow large-text screens',
    (tester) async {
      final controller = await _controller();
      await _mount(tester, MyShopsScreen(controller: controller));
      await _tap(tester, find.text('Add a shop'));
      await tester.enterText(
        find.byKey(const Key('shop-name')),
        'Neighborhood Garage',
      );
      await tester.enterText(
        find.byKey(const Key('shop-email')),
        'shop@example.test',
      );
      await _tap(tester, find.widgetWithText(FilledButton, 'Save shop'));
      expect(find.text('Neighborhood Garage'), findsOneWidget);
      expect(await controller.repository.listMyShops(), hasLength(1));
      await _tap(tester, find.byTooltip('Manage Neighborhood Garage'));
      await _tap(tester, find.text('Edit shop'));
      await tester.enterText(
        find.byKey(const Key('shop-name')),
        'Updated Garage',
      );
      await _tap(tester, find.widgetWithText(FilledButton, 'Save shop'));
      expect(find.text('Updated Garage'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history saves optional parts details while insights are off and revocable',
    (tester) async {
      final controller = await _controller();
      await _mount(tester, HistoryScreen(controller: controller));
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('insights-consent')))
            .value,
        isFalse,
      );
      await _tap(tester, find.text('Add service history').last);
      await tester.enterText(find.byKey(const Key('history-mileage')), '31000');
      await tester.enterText(
        find.byKey(const Key('history-shop_name')),
        'Neighborhood Garage',
      );
      await tester.enterText(
        find.byKey(const Key('history-parts_source')),
        'Local parts store',
      );
      await tester.enterText(
        find.byKey(const Key('history-parts_description')),
        'Cabin filter',
      );
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Save history entry'),
      );
      final history = await controller.repository.getKnowledge();
      expect(history['records'], hasLength(1));
      expect(
        (history['records'] as List).single['parts_source'],
        'Local parts store',
      );
      expect(history['preferences'], {'share_aggregate_insights': false});
      expect(find.text('Choose PDF'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('insights-consent')));
      expect((await controller.repository.getKnowledge())['preferences'], {
        'share_aggregate_insights': true,
      });
      await _tap(tester, find.byKey(const Key('insights-consent')));
      expect((await controller.repository.getKnowledge())['preferences'], {
        'share_aggregate_insights': false,
      });
      expect(find.text('Cabin filter'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved draft composer restores exact details before review without sending',
    (tester) async {
      final controller = await _controller();
      final workspace = CustomerWorkspace.forController(controller);
      final shop = await controller.repository.saveMyShop({
        'name': 'Saved shop',
        'email': 'shop@example.test',
        'phone': '',
        'address': '',
      });
      final body = <String, dynamic>{
        'shop_id': shop['id'],
        'vehicle_id': 'demo-audi',
        'service_summary': 'Exact saved service',
        'customer_message': 'Keep original note',
        'proposed_slots': ['2026-10-14T09:30:00-06:00'],
      };
      await workspace.store.write(
        '${workspace.customerId}/outreach-draft',
        PendingWorkspaceWrite(body: body, key: 'saved-key'),
      );
      await _mount(
        tester,
        ShopOutreachComposer(
          controller: controller,
          shops: [shop],
          initialSummary: 'Do not overwrite',
        ),
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('outreach-summary')))
            .enabled,
        isFalse,
      );
      expect(find.text('Exact saved service'), findsOneWidget);
      expect(find.textContaining('Do not overwrite'), findsNothing);
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Recover saved review'),
      );
      expect(
        (await controller.repository.listShopOutreach()).single['status'],
        'draft',
      );
      expect(await workspace.pending('outreach-draft'), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a draft scheduling request can be discarded from my shops', (
    tester,
  ) async {
    final controller = await _controller();
    final shop = await controller.repository.saveMyShop({
      'name': 'Shop',
      'email': 's@example.test',
      'phone': '',
    });
    await controller.repository.createShopOutreach({
      'shop_id': shop['id'],
      'vehicle_id': controller.snapshot!.vehicles.first.id,
      'service_summary': 'Brakes',
      'proposed_slots': [
        offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
      ],
    }, 'draft-key');
    await _mount(tester, MyShopsScreen(controller: controller));
    expect(find.text('Draft • not sent'), findsOneWidget);
    await _tap(tester, find.byTooltip('Request options').first);
    await _tap(tester, find.text('Discard request'));
    expect(find.text('Discard this request?'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, 'Discard'));
    expect(find.text('Draft • not sent'), findsNothing);
    expect(await controller.repository.listShopOutreach(), isEmpty);
  });

  testWidgets('a sent request can be withdrawn from its review screen', (
    tester,
  ) async {
    final repository = _Repository();
    final controller = await _controller(repository);
    repository.draft = {
      ...repository.draft,
      'status': 'waiting_for_reply',
      'delivery_status': 'provider_accepted',
    };
    await _mount(
      tester,
      ShopOutreachReview(controller: controller, draftId: 'draft-1'),
    );
    await _tap(tester, find.text('Withdraw request'));
    expect(find.text('Withdraw this request?'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, 'Withdraw'));
    expect(find.text('Withdrawn'), findsOneWidget);
    expect(find.text('Withdraw request'), findsNothing);
  });

  testWidgets('an interrupted device draft can be discarded', (tester) async {
    final controller = await _controller();
    final workspace = CustomerWorkspace.forController(controller);
    final shop = await controller.repository.saveMyShop({
      'name': 'Test shop',
      'email': 'shop@example.test',
    });
    final body = <String, dynamic>{
      'shop_id': shop['id'],
      'service_summary': 'Oil',
      'proposed_slots': [
        offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
      ],
    };
    await controller.repository.createShopOutreach(body, 'k');
    await workspace.store.write(
      workspace.scopeFor('outreach-draft'),
      PendingWorkspaceWrite(body: body, key: 'k'),
    );
    await _mount(tester, MyShopsScreen(controller: controller));
    expect(find.text('Recover scheduling draft'), findsOneWidget);
    await _tap(tester, find.text('Discard draft'));
    expect(find.text('Discard the saved draft?'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, 'Discard'));
    expect(find.text('Recover scheduling draft'), findsNothing);
    expect(await workspace.pending('outreach-draft'), isNull);
    expect(await controller.repository.listShopOutreach(), isEmpty);
  });

  testWidgets('a history record can be edited and keeps its receipts', (
    tester,
  ) async {
    final controller = await _controller();
    final record = await controller.repository.addKnowledgeRecord({
      'vehicle_id': controller.snapshot!.vehicles.first.id,
      'service_type': 'maintenance',
      'service_date': '2026-09-01',
      'shop_name': 'Old Shop',
      'cost_cents': 1000,
    }, 'h-edit');
    await controller.repository
        .openReceiptRecord(record['id'] as String, isCurrent: () => true)
        .upload(
          ReceiptPending(
            ownerId: controller.snapshot!.profile.id,
            recordId: record['id'] as String,
            operationId: '11111111-1111-4111-8111-111111111111',
            filename: 'work.pdf',
            mimeType: 'application/pdf',
            bytes: Uint8List.fromList('%PDF-1.4'.codeUnits),
          ),
        );
    await _mount(tester, HistoryScreen(controller: controller));
    await _tap(tester, find.byTooltip('Edit history entry').first);
    expect(find.text('Edit service history'), findsOneWidget);
    expect(find.textContaining('1 receipt stays attached'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Shop or DIY (optional)'),
      'New Shop',
    );
    await _tap(tester, find.text('Save changes'));
    expect(find.text('New Shop'), findsOneWidget);
    expect(find.text('Old Shop'), findsNothing);
    final saved = (await controller.repository.getKnowledge())['records'].first;
    expect(saved['shop_name'], 'New Shop');
    expect(saved['cost_cents'], 1000);
  });

  testWidgets('my shops reloads when a route above it pops', (tester) async {
    final controller = await _controller();
    final shop = await controller.repository.saveMyShop({
      'name': 'Shop',
      'email': 's@example.test',
      'phone': '',
    });
    final draft = await controller.repository.createShopOutreach({
      'shop_id': shop['id'],
      'vehicle_id': controller.snapshot!.vehicles.first.id,
      'service_summary': 'Brakes',
      'proposed_slots': [
        offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
      ],
    }, 'draft-reload');
    late BuildContext screenContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: plusTheme(),
        navigatorObservers: [plusRouteObserver],
        home: Builder(
          builder: (context) {
            screenContext = context;
            return MyShopsScreen(controller: controller);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Draft • not sent'), findsOneWidget);
    final popped = Navigator.of(
      screenContext,
    ).push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    await controller.repository.deleteShopOutreach(draft['id'] as String);
    Navigator.of(screenContext).pop();
    await popped;
    await tester.pumpAndSettle();
    expect(find.text('Draft • not sent'), findsNothing);
  });
}
