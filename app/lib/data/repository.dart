import 'dart:typed_data';
import '../domain/models.dart';
import '../services/guided_capture_api.dart';
import '../services/receipt_api.dart';

class PlusApiException implements Exception {
  const PlusApiException(this.message, [this.statusCode, this.code]);
  final String message;
  final int? statusCode;
  final String? code;
  @override
  String toString() => message;
}

abstract class PlusRepository {
  bool get isDemo;
  GuidedCaptureApi openGuidedCapture(
    String estimateId, {
    required bool Function() isCurrent,
  }) => throw const PlusApiException(
    'The guided camera is unavailable in this preview.',
  );
  ReceiptApi openReceiptRecord(
    String recordId, {
    required bool Function() isCurrent,
  }) => throw const PlusApiException(
    'Receipt uploads are unavailable in this preview.',
  );
  Future<Json> lookupVehicleValue(
    String vehicleId,
    Json body, {
    required bool Function() isCurrent,
  }) => throw const PlusApiException(
    'Vehicle value estimates are currently unavailable.',
    503,
  );
  Future<Json> listVehicleValuations(String vehicleId) async => {
    'vehicle_id': vehicleId,
    'valuations': <Json>[],
  };
  Future<void> deleteVehicleValuation(String vehicleId, String valuationId) =>
      throw const PlusApiException('Past lookups cannot be removed right now.');
  Future<PlusSnapshot> bootstrap();
  Future<Json> saveProfile(Json body);
  Future<Json> getProfileSettings({bool Function()? isCurrent}) =>
      _settingsUnavailable();
  Future<Json> saveProfileSettings(
    Json body, {
    required bool Function() isCurrent,
  }) => _settingsUnavailable();
  Future<Json> clearProfileSettings(
    int expectedRevision, {
    required bool Function() isCurrent,
  }) => _settingsUnavailable();
  Future<Json> getAppSettings({bool Function()? isCurrent}) =>
      _settingsUnavailable();
  Future<Json> saveAppSettings(
    Json body, {
    required bool Function() isCurrent,
  }) => _settingsUnavailable();
  Future<Json> resetAppSettings(
    int expectedRevision, {
    required bool Function() isCurrent,
  }) => _settingsUnavailable();
  Future<Json> getKnowledgePreferences({bool Function()? isCurrent}) =>
      _settingsUnavailable();
  Future<Json> saveKnowledgePreferencesScoped(
    Json body, {
    required bool Function() isCurrent,
  }) => _settingsUnavailable();
  Future<Json> _settingsUnavailable() => throw const PlusApiException(
    'Settings are unavailable. Please try again later.',
    503,
  );
  Future<Json> saveVehicle(Json body, {String? id});
  Future<void> deleteVehicle(String id);
  Future<VehiclePhoto?> getVehicleImage(String id) async => null;
  Future<Json> uploadVehicleImage(
    String id,
    Uint8List bytes,
    String filename,
  ) => throw const PlusApiException('Vehicle photos are not available yet.');
  Future<void> deleteVehicleImage(String id) =>
      throw const PlusApiException('Vehicle photos are not available yet.');
  Future<Json> createEstimate(Json body);
  Future<Json> uploadPhoto(
    String estimateId,
    Uint8List bytes,
    String filename,
    String label,
  );
  Future<Uint8List> getPhoto(String estimateId, String photoId);
  Future<Json> submitEstimate(String id, Json body, String idempotencyKey);
  Future<Json> updateEstimate(String id, Json body) =>
      throw const PlusApiException(
        'This estimate cannot be changed right now.',
      );
  Future<void> deleteEstimate(String id) => throw const PlusApiException(
    'This estimate cannot be changed right now.',
  );
  Future<void> deletePhoto(String estimateId, String photoId) =>
      throw const PlusApiException('This photo cannot be removed right now.');
  Future<Json> createRequest(Json body, String idempotencyKey);
  Future<Json> cancelRequest(String id);
  Future<Json> addReminder(Json body);
  Future<Json> completeReminder(String id);
  Future<Json> updateReminder(String id, Json body) =>
      throw const PlusApiException('Reminders cannot be changed right now.');
  Future<void> deleteReminder(String id) =>
      throw const PlusApiException('Reminders cannot be changed right now.');
  Future<Json> reopenReminder(String id) =>
      throw const PlusApiException('Reminders cannot be changed right now.');
  Future<AssistantAnswer> askAssistant(Json body);
  Future<List<Json>> listMyShops();
  Future<Json> saveMyShop(Json body, {String? id});
  Future<void> deleteMyShop(String id);
  Future<List<Json>> listShopOutreach();
  Future<Json> getShopOutreach(String id);
  Future<Json> createShopOutreach(Json body, String idempotencyKey);
  Future<Json> authorizeShopOutreach(
    String id,
    Json body,
    String idempotencyKey,
  );
  Future<void> deleteShopOutreach(String id) => throw const PlusApiException(
    'This request cannot be discarded right now.',
  );
  Future<Json> withdrawShopOutreach(String id) => throw const PlusApiException(
    'This request cannot be withdrawn right now.',
  );
  Future<Json> getKnowledge();
  Future<Json> addKnowledgeRecord(Json body, String idempotencyKey);
  Future<void> deleteKnowledgeRecord(String id);
  Future<Json> updateKnowledgeRecord(String id, Json body) =>
      throw const PlusApiException('History cannot be changed right now.');
  Future<Json> saveKnowledgePreferences(Json body);
  Future<Json> discoverProviders(Json query) async => {
    'providers': <Json>[],
    'shop_visit_alternatives': <Json>[],
    'status': 'unavailable',
    'postal_code': query['postal_code'],
    'radius_miles': 30,
    'distance_basis': 'zip_centroid',
    'exhaustive': false,
    'truncated': false,
    'source_attributions': <Json>[],
    'message': 'Nearby listings are unavailable. Try again later.',
  };
  Future<List<Json>> listDiscoveryFavorites(String vehicleId) async => [];
  Future<Json> saveDiscoveryFavorite(String specialty, Json body) =>
      throw const PlusApiException(
        'Dedicated shops are unavailable. Try again later.',
      );
  Future<void> deleteDiscoveryFavorite(String specialty, String vehicleId) =>
      throw const PlusApiException(
        'Dedicated shops are unavailable. Try again later.',
      );
  Future<Json> getCalendarStatus() async => {
    'configured': false,
    'connected': false,
    'status': 'unavailable',
    'generation': 0,
    'selected_calendar_ids': <String>[],
    'time_zone': 'Etc/UTC',
    'sync_confirmed': false,
    'attempt_id': null,
    'sync_issues': <Json>[],
  };
  Future<Json> connectGoogleCalendar() => _calendarUnavailable();
  Future<Json> reconcileGoogleCalendar(String attemptId) =>
      _calendarUnavailable();
  Future<Json> listGoogleCalendars() => _calendarUnavailable();
  Future<Json> saveCalendarPreferences(Json body) => _calendarUnavailable();
  Future<Json> findCalendarAvailability(Json body) => _calendarUnavailable();
  Future<Json> disconnectGoogleCalendar() => _calendarUnavailable();
  Future<Json> retryCalendarSync(Json body) => _calendarUnavailable();
  Future<Json> _calendarUnavailable() =>
      throw const PlusApiException('Google Calendar is unavailable.', 503);
  void invalidateSession() => close();
  void close() {}
}
