import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/garage_forms.dart';
import 'package:estimoto_plus/screens/history_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class Repo extends DemoPlusRepository {
  final vehicleWrite = Completer<Json>();
  final answer = Completer<AssistantAnswer>();
  int vehicleWrites = 0, deletes = 0, reminderDeletes = 0;
  bool malformedPrivacy = false;
  @override
  Future<Json> saveVehicle(Json body, {String? id}) {
    vehicleWrites++;
    return vehicleWrite.future;
  }

  @override
  Future<void> deleteReminder(String id) async {
    reminderDeletes++;
  }

  @override
  Future<void> deleteVehicle(String id) async {
    deletes++;
  }

  @override
  Future<AssistantAnswer> askAssistant(Json body) => answer.future;
  @override
  Future<Json> getKnowledge() async => malformedPrivacy
      ? {'records': [], 'preferences': {}}
      : super.getKnowledge();
  @override
  Future<Json> saveKnowledgePreferences(Json body) async => {};
}

Future<PlusController> controller(Repo repo) async {
  final c = PlusController(repo);
  await c.refresh();
  addTearDown(c.dispose);
  return c;
}

Future<void> mount(WidgetTester t, Widget child) async {
  await t.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      home: Scaffold(body: child),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> vehicleForm(WidgetTester t, PlusController c) async {
  await mount(
    t,
    Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            editVehicle(context, c, vehicle: c.snapshot!.vehicles.first),
        child: const Text('Edit'),
      ),
    ),
  );
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'reminder delete confirmation is deduplicated and cannot act after sign-out',
    (t) async {
      final r = Repo();
      final c = await controller(r);
      final reminder = c.snapshot!.reminders.first;
      await mount(
        t,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => addReminder(context, c, reminder: reminder),
            child: const Text('Edit reminder'),
          ),
        ),
      );
      await t.tap(find.text('Edit reminder'));
      await t.pumpAndSettle();
      final button = t
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Delete reminder'),
          )
          .onPressed!;
      button();
      button();
      await t.pumpAndSettle();
      expect(find.text('Delete this reminder?'), findsOneWidget);
      c.invalidateSession();
      await t.pump();
      await t.tap(find.widgetWithText(TextButton, 'Delete'));
      await t.pumpAndSettle();
      expect(r.reminderDeletes, 0);
      expect(t.takeException(), isNull);
    },
  );

  test('clearing a conversation suppresses an outstanding reply', () async {
    final r = Repo();
    final c = await controller(r);
    final ask = c.ask('Help with tires');
    c.clearConversation();
    r.answer.complete(
      AssistantAnswer.fromJson({'reply': 'Old private answer'}),
    );
    await ask;
    expect(c.messages, isEmpty);
  });
  test('vehicle save cannot run after session invalidation', () async {
    final r = Repo();
    final c = await controller(r);
    c.invalidateSession();
    final future = c.saveVehicle({'make': 'Ford'});
    final check = expectLater(future, throwsA(isA<PlusApiException>()));
    r.vehicleWrite.complete({'id': 'late'});
    await check;
    expect(r.vehicleWrites, 0);
  });
  test(
    'late vehicle save cannot restore selected vehicle after sign-out',
    () async {
      final r = Repo();
      final c = await controller(r);
      final future = c.saveVehicle({'make': 'Ford'});
      c.invalidateSession();
      final check = expectLater(future, throwsA(isA<PlusApiException>()));
      r.vehicleWrite.complete({'id': 'late'});
      await check;
      expect(c.selectedVehicleId, isNull);
    },
  );
  testWidgets('vehicle form rejects duplicate saved callbacks', (t) async {
    final r = Repo();
    final c = await controller(r);
    await vehicleForm(t, c);
    final button = find.widgetWithText(FilledButton, 'Save vehicle');
    final callback = t.widget<FilledButton>(button).onPressed!;
    callback();
    callback();
    await t.pump();
    expect(r.vehicleWrites, 1);
    r.vehicleWrite.complete({'id': c.selectedVehicleId});
    await t.pumpAndSettle();
  });
  testWidgets(
    'vehicle removal requires confirmation and rejects an ended session',
    (t) async {
      final r = Repo();
      final c = await controller(r);
      await vehicleForm(t, c);
      await t.ensureVisible(find.text('Remove from garage'));
      await t.tap(find.text('Remove from garage'));
      await t.pumpAndSettle();
      expect(r.deletes, 0);
      expect(find.text('Remove this vehicle?'), findsOneWidget);
      c.invalidateSession();
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Remove vehicle'));
      await t.pumpAndSettle();
      expect(r.deletes, 0);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('unknown history privacy choice never appears as consent off', (
    t,
  ) async {
    final r = Repo()..malformedPrivacy = true;
    final c = await controller(r);
    await mount(t, HistoryScreen(controller: c));
    expect(find.byKey(const Key('insights-consent')), findsNothing);
    expect(
      find.text('Refresh to load your saved insights-sharing choice.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'malformed history consent save retains retry rather than claiming success',
    (t) async {
      final r = Repo();
      final c = await controller(r);
      await mount(t, HistoryScreen(controller: c));
      final change = t
          .widget<SwitchListTile>(find.byKey(const Key('insights-consent')))
          .onChanged!;
      change(true);
      await t.pumpAndSettle();
      expect(find.text('Retry preference change'), findsOneWidget);
      expect(find.textContaining('has not been confirmed'), findsOneWidget);
    },
  );
}
