import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/garage_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _DelayedRepository extends DemoPlusRepository {
  final completion = Completer<void>();
  int completionCalls = 0;

  @override
  Future<Json> completeReminder(String id) async {
    completionCalls++;
    await completion.future;
    return super.completeReminder(id);
  }
}

Future<PlusController> _controller(DemoPlusRepository repository) async {
  for (final reminder in (await repository.bootstrap()).reminders) {
    await repository.deleteReminder(reminder.id);
  }
  final controller = PlusController(repository);
  await controller.refresh();
  return controller;
}

Future<Json> _reminder(
  PlusController controller,
  String title, {
  String? vehicleId,
  int? dueMileage,
}) => controller.repository.addReminder({
  'vehicle_id': vehicleId ?? controller.selectedVehicle!.id,
  'title': title,
  'due_mileage': dueMileage ?? controller.selectedVehicle!.mileage,
});

Future<void> _mount(
  WidgetTester tester,
  PlusController controller, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await controller.refresh();
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => GarageScreen(controller: controller),
        ),
      ),
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
    'completed reminder remains editable and reopenable after undo expires',
    (tester) async {
      final controller = await _controller(DemoPlusRepository());
      final row = await _reminder(controller, 'Rotate tires');
      await _mount(tester, controller);
      await _tap(tester, find.byTooltip('Mark reminder complete'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      await _tap(tester, find.text('Completed reminders (1)'));
      await _tap(tester, find.text('Rotate tires'));
      expect(find.text('Edit reminder'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Reopen reminder'));
      expect(controller.snapshot!.reminders.single.id, row['id']);
      expect(controller.snapshot!.reminders.single.completed, isFalse);
      expect(find.byTooltip('Mark reminder complete'), findsOneWidget);
    },
  );

  testWidgets(
    'completed reminders can be deleted and stay scoped to the selected vehicle',
    (tester) async {
      final controller = await _controller(DemoPlusRepository());
      final mine = await _reminder(controller, 'My completed service');
      final other = await _reminder(
        controller,
        'Other car service',
        vehicleId: controller.snapshot!.vehicles.last.id,
      );
      await controller.repository.completeReminder(mine['id'] as String);
      await controller.repository.completeReminder(other['id'] as String);
      await _mount(tester, controller);
      await _tap(tester, find.text('Completed reminders (1)'));
      expect(find.text('Other car service'), findsNothing);
      await _tap(tester, find.text('My completed service'));
      await _tap(tester, find.text('Delete reminder'));
      await _tap(tester, find.widgetWithText(TextButton, 'Delete'));
      expect(find.text('My completed service'), findsNothing);
      expect(controller.snapshot!.reminders.single.title, 'Other car service');
      controller.selectVehicle(controller.snapshot!.vehicles.last.id);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Completed reminders (1)'));
      expect(find.text('Other car service'), findsOneWidget);
    },
  );

  testWidgets(
    'garage prioritizes overdue mileage and shows remaining distance',
    (tester) async {
      final controller = await _controller(DemoPlusRepository());
      final mileage = controller.selectedVehicle!.mileage;
      await _reminder(controller, 'Later service', dueMileage: mileage + 1000);
      await _reminder(controller, 'Due service', dueMileage: mileage);
      await _reminder(controller, 'Overdue service', dueMileage: mileage - 500);
      await _mount(tester, controller);
      expect(
        tester.getTopLeft(find.text('Overdue service')).dy,
        lessThan(tester.getTopLeft(find.text('Due service')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Due service')).dy,
        lessThan(tester.getTopLeft(find.text('Later service')).dy),
      );
      expect(find.textContaining('500 miles overdue'), findsOneWidget);
      expect(find.textContaining('Due at current mileage'), findsOneWidget);
      expect(find.textContaining('In 1,000 miles'), findsOneWidget);
    },
  );

  testWidgets('reminders remain usable at 320 pixels with enlarged text', (
    tester,
  ) async {
    final controller = await _controller(DemoPlusRepository());
    await _reminder(controller, 'Check tires before a long road trip');
    await _mount(tester, controller, width: 320, scale: 2);
    await _tap(tester, find.byTooltip('Mark reminder complete'));
    await _tap(tester, find.text('Completed reminders (1)'));
    await _tap(tester, find.byTooltip('Reopen reminder'));
    expect(tester.takeException(), isNull);
    expect(controller.snapshot!.reminders.single.completed, isFalse);
  });

  testWidgets('repeated completion taps cannot start duplicate mutations', (
    tester,
  ) async {
    final repository = _DelayedRepository();
    final controller = await _controller(repository);
    await _reminder(controller, 'One service');
    await _mount(tester, controller);
    final button = find.byTooltip('Mark reminder complete');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(repository.completionCalls, 1);
    repository.completion.complete();
    await tester.pumpAndSettle();
    expect(controller.snapshot!.reminders.single.completed, isTrue);
  });

  testWidgets(
    'completion response cannot refresh an invalidated customer session',
    (tester) async {
      final repository = _DelayedRepository();
      final controller = await _controller(repository);
      await _reminder(controller, 'Private service');
      await _mount(tester, controller);
      await tester.ensureVisible(find.byTooltip('Mark reminder complete'));
      await tester.tap(find.byTooltip('Mark reminder complete'));
      controller.invalidateSession();
      repository.completion.complete();
      await tester.pumpAndSettle();
      expect(controller.snapshot!.reminders.single.completed, isFalse);
      expect(find.text('Reminder completed'), findsNothing);
    },
  );
}
