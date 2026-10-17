// Run through scripts/smoke_api.py --flutter-client against its isolated API.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/repository.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> expectConflict(Future<dynamic> pending, String code) async {
  try {
    await pending;
    throw StateError('A stale settings change was accepted.');
  } on PlusApiException catch (error) {
    check(
      error.statusCode == 409 && error.code == code,
      'The settings conflict lost its recovery code.',
    );
  }
}

Future<void> main() async {
  final origin = Platform.environment['PLUS_SMOKE_API'];
  if (origin == null || Uri.parse(origin).host != '127.0.0.1') {
    throw StateError('The isolated loopback smoke server is required.');
  }
  final session = await http.post(Uri.parse('$origin/v1/dev/session'));
  check(session.statusCode == 200, 'Local demo session failed.');
  final token = (jsonDecode(session.body) as Map)['access_token'] as String;
  final api = ApiPlusRepository(baseUrl: origin, token: () async => token);
  try {
    final initial = await api.bootstrap();
    check(initial.capabilities.demo, 'Expected explicitly isolated API demo.');
    final vehicle = await api.saveVehicle({
      'year': 2024,
      'make': 'Toyota',
      'model': 'Camry',
      'nickname': 'Flutter socket car',
      'vin': '',
      'mileage': 8200,
      'insurer': '',
      'policy_number': '',
    });
    final vehicleId = vehicle['id'] as String;
    final updated = await api.saveVehicle({'mileage': 8300}, id: vehicleId);
    check(updated['mileage'] == 8300, 'Vehicle edit did not persist.');
    final originalProfile = await api.getProfileSettings(isCurrent: () => true);
    final profile = await api.saveProfileSettings({
      'expected_revision': originalProfile['revision'],
      'name': 'Flutter Socket Driver',
      'phone': '+1 (303) 555-0100',
      'postal_code': '80202-1234',
      'contact_preference': 'phone',
    }, isCurrent: () => true);
    final partialProfile = await api.saveProfileSettings({
      'expected_revision': profile['revision'],
      'name': 'Flutter Socket Driver Updated',
    }, isCurrent: () => true);
    check(
      partialProfile['phone'] == profile['phone'] &&
          partialProfile['postal_code'] == '80202' &&
          partialProfile['contact_preference'] == 'phone',
      'Partial profile save erased omitted contact details.',
    );
    final defaults = await api.getAppSettings(isCurrent: () => true);
    check(
      defaults['customized'] == false &&
          defaults['home_tab'] == 'garage' &&
          defaults['default_vehicle_id'] == null,
      'The new demo account did not return default app preferences.',
    );
    final settingsBody = <String, dynamic>{
      'expected_revision': defaults['revision'],
      'default_vehicle_id': vehicleId,
      'default_estimate_discipline': 'collision',
      'home_tab': 'find_help',
    };
    final savedSettings = await api.saveAppSettings(
      settingsBody,
      isCurrent: () => true,
    );
    final settingsState = await api.bootstrap();
    check(
      settingsState.settings.defaultVehicleId == vehicleId &&
          settingsState.settings.homeTab == 'find_help' &&
          settingsState.settings.defaultEstimateDiscipline == 'collision',
      'Saved app preferences were missing from bootstrap.',
    );
    await expectConflict(
      api.saveAppSettings(settingsBody, isCurrent: () => true),
      'settings_conflict',
    );
    final resetSettings = await api.resetAppSettings(
      savedSettings['revision'] as int,
      isCurrent: () => true,
    );
    check(
      resetSettings['revision'] == (savedSettings['revision'] as int) + 1 &&
          resetSettings['customized'] == false &&
          resetSettings['default_vehicle_id'] == null &&
          resetSettings['default_estimate_discipline'] == 'pdr' &&
          resetSettings['home_tab'] == 'garage',
      'App preferences reset did not preserve a revision tombstone.',
    );
    await expectConflict(
      api.resetAppSettings(
        savedSettings['revision'] as int,
        isCurrent: () => true,
      ),
      'settings_conflict',
    );
    final privacy = await api.getKnowledgePreferences(isCurrent: () => true);
    check(
      privacy['share_aggregate_insights'] == false,
      'Aggregate sharing was enabled without consent.',
    );
    final shared = await api.saveKnowledgePreferencesScoped({
      'share_aggregate_insights': true,
    }, isCurrent: () => true);
    check(
      shared['share_aggregate_insights'] == true &&
          shared['policy_version'] == privacy['policy_version'] &&
          (await api
                  .getKnowledge())['preferences']['share_aggregate_insights'] ==
              true,
      'Privacy settings and service history do not share the same preference.',
    );
    await api.saveKnowledgePreferencesScoped({
      'share_aggregate_insights': false,
    }, isCurrent: () => true);
    check(
      (await api.getKnowledgePreferences())['share_aggregate_insights'] ==
          false,
      'Privacy consent could not be withdrawn.',
    );
    final draft = await api.createEstimate({
      'vehicle_id': vehicleId,
      'discipline': 'collision',
      'description': 'Socket test bumper damage.',
      'claim_number': '',
      'date_of_loss': null,
    });
    check(
      draft['amount_cents'] == null && draft['status'] == 'draft',
      'Draft invented a quote.',
    );
    final answer = await api.askAssistant({
      'message': 'Find dent repair',
      'vehicle_id': vehicleId,
      'postal_code': '80202',
      'mobile_only': false,
    });
    check(
      answer.providers.isNotEmpty,
      'Assistant did not return the seeded provider.',
    );
    final body = <String, dynamic>{
      'vehicle_id': vehicleId,
      'provider_id': answer.providers.first.id,
      'specialty': 'pdr',
      'description': 'Repair my door dent.',
      'preferred_time': 'Next week',
      'share_contact': true,
    };
    final key = 'flutter-socket-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await api.createRequest({
        ...body,
        'provider_id': 'missing-provider',
      }, '$key-rejected');
      throw StateError('Unknown provider accepted a request.');
    } on PlusApiException catch (error) {
      check(
        error.statusCode == 409 && error.code == 'request_not_created',
        'Definitive rejection lost its recovery code.',
      );
    }
    final request = await api.createRequest(body, key);
    final replay = await api.createRequest(body, key);
    check(request['id'] == replay['id'], 'Request replay created a duplicate.');
    check(
      request['status'] == 'requested' &&
          request['delivery_status'] == 'local_preview',
      'Demo request claimed a real delivery or booking.',
    );
    await api.cancelRequest(request['id'] as String);
    final reminder = await api.addReminder({
      'vehicle_id': vehicleId,
      'title': 'Check tire pressure',
      'due_date': null,
      'due_mileage': 10000,
    });
    await api.completeReminder(reminder['id'] as String);
    final finalState = await api.bootstrap();
    check(
      finalState.vehicle(vehicleId)?.mileage == 8300,
      'Bootstrap lost garage data.',
    );
    check(
      finalState.requests.firstWhere((r) => r.id == request['id']).status ==
          'cancelled',
      'Bootstrap lost cancellation.',
    );
    check(
      finalState.reminders.firstWhere((r) => r.id == reminder['id']).completed,
      'Bootstrap lost reminder completion.',
    );
    try {
      await api.submitEstimate(draft['id'] as String, {
        'provider_id': answer.providers.first.id,
        'share_contact': true,
      }, 'estimate:${draft['id']}');
      throw StateError('Unconnected estimator accepted submission.');
    } on PlusApiException catch (error) {
      check(
        error.statusCode == 503,
        'Unexpected unavailable estimator response.',
      );
    }
    final clearedProfile = await api.clearProfileSettings(
      partialProfile['revision'] as int,
      isCurrent: () => true,
    );
    check(
      clearedProfile['id'] == originalProfile['id'] &&
          clearedProfile['email'] == originalProfile['email'] &&
          clearedProfile['name'] == '' &&
          clearedProfile['phone'] == '' &&
          clearedProfile['postal_code'] == '' &&
          clearedProfile['contact_preference'] == 'email',
      'Clearing contact details altered account identity or retained contact data.',
    );
    await expectConflict(
      api.saveProfileSettings({
        'expected_revision': partialProfile['revision'],
        'name': 'Stale profile',
      }, isCurrent: () => true),
      'profile_conflict',
    );
    final clearedState = await api.bootstrap();
    check(
      clearedState.profile.id == originalProfile['id'] &&
          clearedState.profile.name.isEmpty &&
          clearedState.profile.revision == clearedProfile['revision'] &&
          clearedState.vehicle(vehicleId) != null &&
          clearedState.settings.revision == resetSettings['revision'],
      'Profile clearing lost garage data or did not persist cleared details.',
    );
    stdout.writeln(
      'Flutter HTTP client: settings/profile/privacy CRUD, stale-edit conflicts, garage, draft, matching, consented request replay/cancel and reminder persistence passed.',
    );
  } finally {
    api.close();
  }
}
