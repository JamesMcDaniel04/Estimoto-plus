import '../domain/models.dart';

enum ReminderUrgency { overdue, dueNow, upcoming }

/// A reminder is due when either its date or its mileage is reached.
/// Calendar arithmetic uses date components so DST and the current hour cannot
/// turn a reminder due today into an overdue one.
class ReminderStatus {
  ReminderStatus.forReminder(
    ServiceReminder reminder, {
    required DateTime now,
    required int mileage,
  }) {
    final localNow = now.toLocal();
    final due = DateTime.tryParse(reminder.dueDate);
    daysRemaining = due == null
        ? null
        : DateTime.utc(due.year, due.month, due.day)
              .difference(
                DateTime.utc(localNow.year, localNow.month, localNow.day),
              )
              .inDays;
    milesRemaining = reminder.dueMileage == null
        ? null
        : reminder.dueMileage! - mileage;
  }

  late final int? daysRemaining;
  late final int? milesRemaining;

  ReminderUrgency get urgency {
    if ((daysRemaining != null && daysRemaining! < 0) ||
        (milesRemaining != null && milesRemaining! < 0)) {
      return ReminderUrgency.overdue;
    }
    if (daysRemaining == 0 || milesRemaining == 0) {
      return ReminderUrgency.dueNow;
    }
    return ReminderUrgency.upcoming;
  }

  String get label => switch (urgency) {
    ReminderUrgency.overdue => 'Overdue',
    ReminderUrgency.dueNow => 'Due now',
    ReminderUrgency.upcoming => 'Upcoming',
  };

  String get detail => [
    if (daysRemaining != null)
      daysRemaining == 0 ? 'Due today' : _distance(daysRemaining!, 'day'),
    if (milesRemaining != null)
      milesRemaining == 0
          ? 'Due at current mileage'
          : _distance(milesRemaining!, 'mile'),
  ].join(' · ');

  static String _distance(int difference, String unit) {
    final amount = difference.abs();
    final formatted = amount.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final distance = '$formatted $unit${amount == 1 ? '' : 's'}';
    return difference < 0 ? '$distance overdue' : 'In $distance';
  }
}

/// Urgency first, then earliest calendar date, then lowest target mileage.
/// Date-based and mileage-only reminders cannot be compared by units; within
/// an urgency group, dated reminders precede mileage-only reminders.
List<ServiceReminder> sortReminders(
  Iterable<ServiceReminder> reminders, {
  required DateTime now,
  required int mileage,
}) {
  final rows = reminders.toList();
  final statuses = {
    for (final row in rows)
      row.id: ReminderStatus.forReminder(row, now: now, mileage: mileage),
  };
  int optional(int? a, int? b) => a == null
      ? b == null
            ? 0
            : 1
      : b == null
      ? -1
      : a.compareTo(b);
  rows.sort((a, b) {
    final first = statuses[a.id]!, second = statuses[b.id]!;
    for (final comparison in [
      first.urgency.index.compareTo(second.urgency.index),
      optional(first.daysRemaining, second.daysRemaining),
      optional(first.milesRemaining, second.milesRemaining),
      a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      a.id.compareTo(b.id),
    ]) {
      if (comparison != 0) return comparison;
    }
    return 0;
  });
  return rows;
}
