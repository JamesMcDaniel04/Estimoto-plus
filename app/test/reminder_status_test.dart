import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/services/reminder_status.dart';

ServiceReminder reminder(String id, {String? date, int? mileage}) =>
    ServiceReminder.fromJson({
      'id': id,
      'title': id,
      'due_date': date,
      'due_mileage': mileage,
    });

void main() {
  final now = DateTime(2026, 9, 19, 23, 59);

  test('urgency uses local calendar days and either due threshold', () {
    final cases = [
      (
        reminder('past date', date: '2026-09-18', mileage: 15000),
        ReminderUrgency.overdue,
      ),
      (
        reminder('past mileage', date: '2026-09-20', mileage: 9999),
        ReminderUrgency.overdue,
      ),
      (reminder('today', date: '2026-09-19'), ReminderUrgency.dueNow),
      (reminder('equal mileage', mileage: 10000), ReminderUrgency.dueNow),
      (
        reminder('tomorrow', date: '2026-09-20', mileage: 11000),
        ReminderUrgency.upcoming,
      ),
      (
        reminder('overdue beats today', date: '2026-09-19', mileage: 9000),
        ReminderUrgency.overdue,
      ),
    ];
    for (final (row, expected) in cases) {
      expect(
        ReminderStatus.forReminder(row, now: now, mileage: 10000).urgency,
        expected,
        reason: row.title,
      );
    }
  });

  test('remaining time does not depend on time of day or DST duration', () {
    final row = reminder('tomorrow', date: '2026-11-02');
    final result = ReminderStatus.forReminder(
      row,
      now: DateTime(2026, 11, 1, 23, 59),
      mileage: 0,
    );
    expect(result.daysRemaining, 1);
    expect(result.detail, 'In 1 day');
    expect(
      ReminderStatus.forReminder(
        reminder('today', date: '2026-11-01'),
        now: DateTime(2026, 11, 1, 0, 1),
        mileage: 0,
      ).detail,
      'Due today',
    );
  });

  test('details explain both mileage and calendar thresholds', () {
    final result = ReminderStatus.forReminder(
      reminder('both', date: '2026-09-17', mileage: 11250),
      now: now,
      mileage: 10000,
    );
    expect(result.detail, '2 days overdue · In 1,250 miles');
    expect(
      ReminderStatus.forReminder(
        reminder('one', mileage: 9999),
        now: now,
        mileage: 10000,
      ).detail,
      '1 mile overdue',
    );
    expect(
      ReminderStatus.forReminder(
        reminder('zero', mileage: 10000),
        now: now,
        mileage: 10000,
      ).detail,
      'Due at current mileage',
    );
  });

  test(
    'priority sorting is stable by due day then mileage and preserves input',
    () {
      final rows = [
        reminder('future miles', mileage: 10100),
        reminder('today miles', mileage: 10000),
        reminder('old miles', mileage: 9999),
        reminder('future date', date: '2026-09-21'),
        reminder('today date', date: '2026-09-19'),
        reminder('old date', date: '2026-09-17'),
        reminder('older date', date: '2026-09-16'),
        reminder('another old miles', mileage: 9000),
      ];
      final ordered = sortReminders(rows, now: now, mileage: 10000);
      expect(ordered.map((row) => row.id), [
        'older date',
        'old date',
        'another old miles',
        'old miles',
        'today date',
        'today miles',
        'future date',
        'future miles',
      ]);
      expect(rows.first.id, 'future miles');
    },
  );

  test('invalid absent dates fall back to mileage without crashing', () {
    final result = ReminderStatus.forReminder(
      reminder('mileage', date: 'bad-date', mileage: 10050),
      now: now,
      mileage: 10000,
    );
    expect(result.daysRemaining, isNull);
    expect(result.detail, 'In 50 miles');
    expect(result.urgency, ReminderUrgency.upcoming);
  });
}
