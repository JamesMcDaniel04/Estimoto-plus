import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/app.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/local_store.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/data/snapshot_cache.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/activity_screen.dart';
import 'package:estimoto_plus/screens/settings_screen.dart';
import 'package:estimoto_plus/services/error_reporting.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';
import 'package:estimoto_plus/widgets/getting_started.dart';

/// Live-shaped repository that can be switched offline.
class _FlakyRepository extends DemoPlusRepository {
  bool offline = false;
  bool emailUpdates = true;
  @override
  bool get isDemo => false;
  @override
  Future<PlusSnapshot> bootstrap() async {
    if (offline) {
      throw const PlusApiException(
        'Could not connect. Check your connection and try again.',
      );
    }
    final snapshot = await super.bootstrap();
    return PlusSnapshot.fromJson({
      ...snapshot.raw,
      'profile': {...snapshot.profile.json, 'email_updates': emailUpdates},
      'capabilities': {'demo': false},
    });
  }

  @override
  Future<Json> setEmailUpdates(bool enabled) async {
    emailUpdates = enabled;
    return {'email_updates': enabled};
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the activity bell shows unread notices and opening clears them',
    (tester) async {
      _phone(tester);
      final controller = PlusController(DemoPlusRepository());
      await controller.refresh();
      expect(controller.unreadNotifications, 1);
      await tester.pumpWidget(EstimotoPlusApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Activity, 1 new'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
      await _tap(tester, find.byTooltip('Activity, 1 new'));
      expect(find.byType(ActivityScreen), findsOneWidget);
      expect(find.text('Demo Dent Care accepted your request'), findsOneWidget);
      expect(
        find.text('Oil change is due for the sample truck'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.circle), findsOneWidget);
      expect(controller.unreadNotifications, 0);
      // A request notice jumps to Repairs.
      await _tap(tester, find.text('Demo Dent Care accepted your request'));
      expect(find.byType(ActivityScreen), findsNothing);
      expect(controller.tab, 3);
      expect(find.byTooltip('Activity'), findsOneWidget);
    },
  );

  testWidgets('settings toggles email updates and shows the calendar state', (
    tester,
  ) async {
    _phone(tester);
    final repository = _FlakyRepository();
    final controller = PlusController(repository);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: plusTheme(),
        home: SettingsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Email me about updates',
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await _tap(tester, toggle);
    expect(repository.emailUpdates, isFalse);
    expect(find.text('Email updates off'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.textContaining('Google Calendar ·'), findsOneWidget);
    expect(find.textContaining('Coming soon'), findsOneWidget);
    expect(find.text('Not configured'), findsNothing);
  });

  testWidgets(
    'getting started lists the remaining steps and can be dismissed',
    (tester) async {
      _phone(tester);
      final store = MemoryLocalStore();
      final controller = PlusController(
        DemoPlusRepository(),
        localStore: store,
      );
      await controller.refresh();
      // The demo garage already has vehicles and estimates; blank the profile
      // so one step remains.
      await controller.repository.saveProfile({'name': '', 'postal_code': ''});
      await controller.refresh();
      var profileTaps = 0;
      Widget card() => MaterialApp(
        theme: plusTheme(),
        home: Scaffold(
          body: GettingStartedCard(
            controller: controller,
            onAddVehicle: () {},
            onEditProfile: () => profileTaps++,
            onStartEstimate: () {},
          ),
        ),
      );
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(find.text('Getting started · 2 of 3'), findsOneWidget);
      await _tap(tester, find.text('Complete your profile'));
      expect(profileTaps, 1);
      await _tap(tester, find.byTooltip('Hide getting started'));
      expect(find.text('Getting started · 2 of 3'), findsNothing);
      expect(
        await store.read(
          controller.snapshot!.profile.id,
          GettingStartedCard.storeName,
        ),
        'true',
      );
      // Remounting respects the stored dismissal.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(find.textContaining('Getting started'), findsNothing);
    },
  );

  test(
    'offline refresh restores the last saved snapshot, never after sign-out',
    () async {
      final repository = _FlakyRepository();
      final cache = MemorySnapshotCache();
      final controller = PlusController(
        repository,
        snapshotCache: cache,
        cacheOwnerId: 'customer-1',
      );
      await controller.refresh();
      expect(controller.isOffline, isFalse);
      expect(await cache.read('customer-1'), isNotNull);

      final fresh = PlusController(
        repository,
        snapshotCache: cache,
        cacheOwnerId: 'customer-1',
      );
      repository.offline = true;
      await fresh.refresh();
      expect(fresh.snapshot, isNotNull);
      expect(fresh.isOffline, isTrue);
      expect(fresh.snapshot!.vehicles, isNotEmpty);
      expect(fresh.error, contains('Could not connect'));

      // Once the server answers again the offline state clears.
      repository.offline = false;
      await fresh.refresh();
      expect(fresh.isOffline, isFalse);

      // Another owner never sees this cache, and clearing removes it.
      final other = PlusController(
        repository,
        snapshotCache: cache,
        cacheOwnerId: 'customer-2',
      );
      repository.offline = true;
      await other.refresh();
      expect(other.snapshot, isNull);
      await fresh.clearDeviceData();
      expect(await cache.read('customer-1'), isNull);
    },
  );

  test(
    'error reporter posts anonymous, deduplicated, capped reports',
    () async {
      final posts = <Map<String, dynamic>>[];
      final reporter = ClientErrorReporter(
        apiOrigin: Uri.parse('https://plus.example.com'),
        platform: 'ios',
        appVersion: '0.1.0',
        buildNumber: '16',
        maxReports: 2,
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://plus.example.com/v1/client-errors',
          );
          expect(request.headers.containsKey('Authorization'), isFalse);
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"accepted":true}', 202);
        }),
      );
      final stack = StackTrace.fromString('#0 a\n#1 b\n#2 c\n');
      expect(await reporter.report(StateError('boom'), stack), isTrue);
      expect(await reporter.report(StateError('boom'), stack), isFalse);
      expect(await reporter.report(ArgumentError('other'), stack), isTrue);
      expect(await reporter.report(FormatException('third'), stack), isFalse);
      expect(posts, hasLength(2));
      expect(posts.first['kind'], 'StateError');
      expect(posts.first['message'], 'Bad state: boom');
      expect(posts.first['platform'], 'ios');
      expect(posts.first.keys, isNot(contains('customer_id')));
    },
  );

  test('relative time wording', () {
    final now = DateTime.utc(2026, 9, 19, 12);
    String at(Duration ago) =>
        relativeTime(now.subtract(ago).toIso8601String(), now: now);
    expect(at(Duration.zero), 'Just now');
    expect(at(const Duration(minutes: 5)), '5 min ago');
    expect(at(const Duration(hours: 3)), '3 h ago');
    expect(at(const Duration(days: 2)), '2 d ago');
    expect(at(const Duration(days: 30)), isNot(contains('ago')));
  });
}
