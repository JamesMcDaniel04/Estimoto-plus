import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import 'demo_seed.dart';
import 'repository.dart';
import 'pending_request_store.dart';
import '../services/calendar_time.dart';
import '../services/guided_capture_api.dart';
import '../services/receipt_api.dart';
import '../services/receipt_pending.dart';
import 'package:timezone/timezone.dart' as tz;

/// Isolated, fictional workspace. It never calls an external service.
class DemoPlusRepository extends PlusRepository {
  DemoPlusRepository() : _state = jsonDecode(jsonEncode(demoSeed())) as Json;
  final Json _state;
  final _shops = <Json>[];
  final _outreach = <Json>[];
  final _history = <Json>[];
  final _receiptBytes = <String, Uint8List>{};
  @override
  ReceiptApi openReceiptRecord(
    String recordId, {
    required bool Function() isCurrent,
  }) => _DemoReceiptApi(this, recordId, isCurrent);
  final _vehicleImages = <String, VehiclePhoto>{};

  late final Map<String, List<Json>> _valuations = _seedValuations();

  Map<String, List<Json>> _seedValuations() {
    final vehicle = _rows('vehicles').first;
    Json sample(int daysAgo, int retail, int wholesale, int mileage) => {
      'id': _id(),
      'state': 'CO',
      'condition': 'average',
      'mileage': mileage,
      'created_at': DateTime.now()
          .subtract(Duration(days: daysAgo))
          .toIso8601String(),
      'payload': {
        'buckets': [
          {'kind': 'retail', 'amount_cents': retail},
          {'kind': 'wholesale', 'amount_cents': wholesale},
        ],
      },
    };
    return {
      vehicle['id'] as String: [
        sample(30, 2400000, 2050000, 28100),
        sample(90, 2480000, 2110000, 26900),
      ],
    };
  }

  @override
  Future<Json> listVehicleValuations(String vehicleId) async {
    _find('vehicles', vehicleId);
    return {
      'vehicle_id': vehicleId,
      'valuations': (_valuations[vehicleId] ?? const <Json>[])
          .map(_copy)
          .toList(),
    };
  }

  @override
  Future<void> deleteVehicleValuation(
    String vehicleId,
    String valuationId,
  ) async {
    final rows = _valuations[vehicleId] ?? <Json>[];
    if (!rows.any((r) => r['id'] == valuationId)) {
      throw const PlusApiException('Not found.', 404);
    }
    rows.removeWhere((r) => r['id'] == valuationId);
  }

  @override
  GuidedCaptureApi openGuidedCapture(
    String estimateId, {
    required bool Function() isCurrent,
  }) => throw const PlusApiException(
    'The guided camera is unavailable in this preview.',
    503,
    'guided_capture_unavailable',
  );

  final _dedicated = <String, Json>{};
  @override
  Future<Json> discoverProviders(Json query) async {
    final snapshot = await bootstrap();
    final postal = textOf(query, 'postal_code', snapshot.profile.postalCode);
    final specialty = query['specialty'] as String?;
    final vehicle = query['vehicle_id'] as String?;
    final listings = <Json>[];
    for (final p in snapshot.providers) {
      if (p.json['public_visible'] == false ||
          !p.acceptingRequests ||
          (specialty != null && !p.specialties.contains(specialty))) {
        continue;
      }
      // Fictional demo geography only; no public directory or provider is contacted.
      if (!p.postalCodes.contains(postal) &&
          !p.postalCodes.any(
            (z) => z.length >= 2 && postal.startsWith(z.substring(0, 2)),
          )) {
        continue;
      }
      final modes = [
        if (p.kind == 'shop') 'shop_visit',
        if (p.mobileService && p.postalCodes.contains(postal)) 'mobile',
      ];
      listings.add({
        ...p.json,
        'source': 'estimoto',
        'source_id': p.sourceId,
        'request_modes': modes,
        'distance_miles': 4.5,
        'mobile_status': p.mobileService ? 'listed' : 'not_listed',
        'vehicle_match': {'status': 'not_verified'},
        'specialty_evidence': <Json>[],
        'favorite': _dedicated.values.any(
          (r) =>
              r['vehicle_id'] == vehicle &&
              r['source_id'] == p.sourceId &&
              (specialty == null || r['specialty'] == specialty),
        ),
      });
    }
    final terms = textOf(
      query,
      'q',
    ).toLowerCase().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    listings.removeWhere(
      (row) =>
          (query['make_only'] == true &&
              (row['vehicle_match'] as Map?)?['status'] != 'listed_make') ||
          !terms.every(
            (term) =>
                '${row['name']} ${row['description']} ${(row['specialties'] as List).join(' ')}'
                    .toLowerCase()
                    .contains(term),
          ),
    );
    final mobile = query['mobile_only'] == true;
    final primary = mobile
        ? listings
              .where((r) => (r['request_modes'] as List).contains('mobile'))
              .toList()
        : listings;
    final alternatives = mobile
        ? listings
              .where(
                (r) =>
                    r['kind'] == 'shop' &&
                    !(r['request_modes'] as List).contains('mobile'),
              )
              .toList()
        : <Json>[];
    return {
      'postal_code': postal,
      'radius_miles': 30,
      'distance_basis': 'zip_centroid',
      'status': 'ready',
      'exhaustive': false,
      'truncated': false,
      'checked_at': DateTime.now().toUtc().toIso8601String(),
      'providers': primary.take(100).toList(),
      'shop_visit_alternatives': alternatives
          .take(100 - primary.take(100).length)
          .toList(),
      'source_attributions': <Json>[],
      'message':
          'Sample listings and distances only. No live directory or provider was contacted.',
    };
  }

  @override
  Future<List<Json>> listDiscoveryFavorites(String vehicleId) async =>
      _dedicated.values
          .where((r) => r['vehicle_id'] == vehicleId)
          .map(_copy)
          .toList();
  @override
  Future<Json> saveDiscoveryFavorite(String specialty, Json body) async {
    final row = {...body, 'specialty': specialty};
    _dedicated['${body['vehicle_id']}/$specialty'] = _copy(row);
    return _copy(row);
  }

  @override
  Future<void> deleteDiscoveryFavorite(
    String specialty,
    String vehicleId,
  ) async {
    _dedicated.remove('$vehicleId/$specialty');
  }

  Json _calendar = {
    'configured': false,
    'connected': true,
    'status': 'connected',
    'generation': 1,
    'selected_calendar_ids': ['sample-personal'],
    'time_zone': 'America/Denver',
    'sync_confirmed': false,
    'attempt_id': null,
    'sync_issues': <Json>[],
  };
  @override
  Future<Json> getCalendarStatus() async => _copy(_calendar);
  @override
  Future<Json> connectGoogleCalendar() async => throw const PlusApiException(
    'Sample mode cannot connect Google Calendar.',
  );
  @override
  Future<Json> reconcileGoogleCalendar(String attemptId) async =>
      getCalendarStatus();
  @override
  Future<Json> listGoogleCalendars() async => {
    'calendars': [
      {
        'id': 'sample-personal',
        'summary': 'Sample personal calendar',
        'primary': true,
        'time_zone': _calendar['time_zone'],
        'selected': true,
      },
      {
        'id': 'sample-family',
        'summary': 'Sample family calendar',
        'primary': false,
        'time_zone': _calendar['time_zone'],
        'selected': false,
      },
    ],
  };
  @override
  Future<Json> saveCalendarPreferences(Json body) async {
    if (!validCalendarZone(textOf(body, 'time_zone')) ||
        (body['selected_calendar_ids'] as List? ?? []).isEmpty) {
      throw const PlusApiException(
        'Choose a sample calendar and a valid IANA time zone.',
        422,
      );
    }
    _calendar = {
      ..._calendar,
      ..._copy(body),
      'generation': (_calendar['generation'] as int) + 1,
    };
    return getCalendarStatus();
  }

  @override
  Future<Json> findCalendarAvailability(Json body) async {
    final start = calendarInstant(textOf(body, 'time_min'));
    final end = calendarInstant(textOf(body, 'time_max'));
    final duration = intOf(body, 'duration_minutes');
    final location = calendarLocation(textOf(body, 'time_zone'));
    final first = tz.TZDateTime.from(start, location);
    final slots = <Json>[];
    for (var day = 0; day < 14 && slots.length < 12; day++) {
      final value = tz.TZDateTime(
        location,
        first.year,
        first.month,
        first.day + day,
        intOf(body, 'day_start_hour'),
      );
      if (value.weekday > 5 ||
          value.isBefore(start) ||
          value.add(Duration(minutes: duration)).isAfter(end)) {
        continue;
      }
      slots.add({
        'start': value.toUtc().toIso8601String(),
        'end': value.add(Duration(minutes: duration)).toUtc().toIso8601String(),
      });
    }
    return {
      'slots': slots,
      'checked_at': DateTime.now().toUtc().toIso8601String(),
      'generation': _calendar['generation'],
      'time_zone': _calendar['time_zone'],
      'duration_minutes': duration,
    };
  }

  @override
  Future<Json> disconnectGoogleCalendar() async {
    _calendar = {
      ..._calendar,
      'connected': false,
      'status': 'disconnected',
      'sync_confirmed': false,
      'generation': (_calendar['generation'] as int) + 1,
    };
    return {'disconnected': true};
  }

  @override
  Future<Json> retryCalendarSync(Json body) async => {
    ...body,
    'calendar_sync_status': 'not_enabled',
    'calendar_sync_message':
        'Sample mode does not create Google Calendar events.',
  };

  @override
  Future<VehiclePhoto?> getVehicleImage(String id) async {
    final vehicle = Vehicle.fromJson(_find('vehicles', id));
    final own = _vehicleImages[id];
    if (own != null) return own;
    final asset = switch ('${vehicle.year} ${vehicle.make} ${vehicle.model}') {
      '2021 Toyota Tacoma' => '2021-toyota-tacoma',
      '2022 Audi Q5' => '2022-audi-q5',
      _ => null,
    };
    if (asset == null) return null;
    final data = await rootBundle.load('assets/vehicles/$asset.webp');
    return VehiclePhoto(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      source: 'carsxe',
    );
  }

  @override
  Future<Json> uploadVehicleImage(
    String id,
    Uint8List bytes,
    String filename,
  ) async {
    final vehicle = _find('vehicles', id);
    _vehicleImages[id] = VehiclePhoto(
      Uint8List.fromList(bytes),
      source: 'upload',
    );
    vehicle['image_version'] = _id();
    return {'source': 'upload', 'image_version': vehicle['image_version']};
  }

  @override
  Future<void> deleteVehicleImage(String id) async {
    _find('vehicles', id)['image_version'] = null;
    _vehicleImages.remove(id);
  }

  final _discardedOutreach = <String>{};
  final _workspaceKeys = <String, (String, Json)>{};
  bool _shareInsights = false;
  Json _copy(Json value) => jsonDecode(jsonEncode(value)) as Json;
  Json _workspaceFind(List<Json> rows, String id) =>
      rows.where((r) => r['id'] == id).firstOrNull ??
      (throw const PlusApiException('This item is no longer available.', 404));
  Json _once(String key, Json body, Json Function() create) {
    final previous = _workspaceKeys[key];
    if (previous != null) {
      if (key.startsWith('draft:') &&
          _discardedOutreach.contains(previous.$2['id'])) {
        throw const PlusApiException(
          'This scheduling draft was discarded.',
          410,
        );
      }
      if (previous.$1 != jsonEncode(freezeJson(body))) {
        throw const PlusApiException('The saved request details changed.', 409);
      }
      return _copy(previous.$2);
    }
    final result = create();
    _workspaceKeys[key] = (jsonEncode(freezeJson(body)), result);
    return _copy(result);
  }

  @override
  Future<List<Json>> listMyShops() async => _shops.map(_copy).toList();
  @override
  Future<Json> saveMyShop(Json body, {String? id}) async {
    if (textOf(body, 'name').trim().isEmpty ||
        (textOf(body, 'email').trim().isEmpty &&
            textOf(body, 'phone').trim().isEmpty)) {
      throw const PlusApiException(
        'Add a shop name and an email or phone.',
        422,
      );
    }
    if (body['vehicle_id'] != null) {
      _find('vehicles', body['vehicle_id'] as String);
    }
    final record = id == null
        ? <String, dynamic>{'id': _id()}
        : _workspaceFind(_shops, id);
    record.addAll(_copy(body));
    if (id == null) _shops.add(record);
    return _copy(record);
  }

  @override
  Future<void> deleteMyShop(String id) async {
    _workspaceFind(_shops, id);
    _shops.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<List<Json>> listShopOutreach() async =>
      _outreach.reversed.map(_copy).toList();
  @override
  Future<Json> getShopOutreach(String id) async =>
      _copy(_workspaceFind(_outreach, id));
  @override
  Future<Json> createShopOutreach(
    Json body,
    String idempotencyKey,
  ) async => _once('draft:$idempotencyKey', body, () {
    final shop = _workspaceFind(_shops, body['shop_id'] as String);
    final vehicleId = body['vehicle_id'] ?? shop['vehicle_id'];
    final vehicle = vehicleId == null
        ? ''
        : Vehicle.fromJson(_find('vehicles', vehicleId as String)).title;
    final profile = _state['profile'] as Json;
    final record = <String, dynamic>{
      'id': _id(),
      'shop_id': shop['id'],
      'shop_name': shop['name'],
      'vehicle_id': vehicleId,
      'recipient_email': shop['email'] ?? '',
      'recipient_phone': shop['phone'] ?? '',
      'subject': 'Service availability request from Estimoto +',
      'message':
          'Service request: ${body['service_summary']}\nVehicle: $vehicle\n${body['customer_message'] ?? ''}',
      'shared_contact': {
        'name': profile['name'],
        'email': profile['email'],
        'phone': profile['phone'],
      },
      'vehicle_summary': vehicle,
      'proposed_slots': body['proposed_slots'],
      if (body.containsKey('calendar_check')) ...{
        'calendar_check': false,
        'calendar_sample': true,
        'calendar_time_zone': _calendar['time_zone'],
        'duration_minutes': body['duration_minutes'],
        'calendar_sync_status': 'not_enabled',
      },
      'review_hash': List.filled(64, 'd').join(),
      'status': 'draft',
      'delivery_status': 'draft',
    };
    _outreach.add(record);
    return record;
  });
  bool _demoSent(Json row) =>
      row['delivery_status'] == 'local_preview' && row['status'] == 'draft';

  @override
  Future<void> deleteShopOutreach(String id) async {
    final row = _workspaceFind(_outreach, id);
    const discardable = {'draft', 'call_required', 'delivery_failed'};
    if (_demoSent(row) || !discardable.contains(row['status'])) {
      throw const PlusApiException(
        'This request was already sent and can only be withdrawn.',
        409,
      );
    }
    _discardedOutreach.add(id);
    _outreach.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<Json> withdrawShopOutreach(String id) async {
    final row = _workspaceFind(_outreach, id);
    const withdrawable = {'queued', 'delivery_unknown', 'waiting_for_reply'};
    if (!_demoSent(row) && !withdrawable.contains(row['status'])) {
      throw const PlusApiException(
        'This request can no longer be withdrawn.',
        409,
      );
    }
    row['status'] = 'withdrawn';
    return _copy(row);
  }

  @override
  Future<Json> authorizeShopOutreach(
    String id,
    Json body,
    String idempotencyKey,
  ) async => _once('authorize:$idempotencyKey', body, () {
    final row = _workspaceFind(_outreach, id);
    if (body['share_contact'] != true ||
        body['review_hash'] != row['review_hash']) {
      throw const PlusApiException(
        'Review and authorize these details first.',
        422,
      );
    }
    final phoneOnly = textOf(row, 'recipient_email').trim().isEmpty;
    final phone = textOf(
      row,
      'recipient_phone',
    ).replaceAll(RegExp(r'[^+0-9]'), '');
    row['status'] = phoneOnly ? 'call_required' : 'draft';
    row['call_link'] = phoneOnly && RegExp(r'^\+?\d{7,15}$').hasMatch(phone)
        ? 'tel:$phone'
        : null;
    row['delivery_status'] = 'local_preview';
    return row;
  });
  @override
  Future<Json> lookupVehicleValue(
    String vehicleId,
    Json body, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) {
      throw const PlusApiException('Your account changed.', 401);
    }
    final vehicle = _find('vehicles', vehicleId);
    final result = <String, dynamic>{
      'vehicle_id': vehicleId,
      'status': 'available',
      'sample': true,
      'provider': 'Demo sample',
      'currency': 'USD',
      ...body,
      'buckets': [
        for (final (kind, amount) in [
          ('retail', 2500000),
          ('wholesale', 2100000),
        ])
          {
            'kind': kind,
            'condition': body['condition'],
            'amount_cents': amount,
            'base_cents': amount,
            'mileage_adjustment_cents': 0,
            'equipment_adjustment_cents': 0,
            'regional_adjustment_cents': 0,
            'amount_basis': 'provider_adjusted',
          },
      ],
      'history': {
        'records_count': _history
            .where((r) => r['vehicle_id'] == vehicleId)
            .length,
        'factors': <String>[],
      },
      'message':
          'Fixed fictional amounts show how a valuation appears. No valuation provider was contacted. These amounts do not value this vehicle or change with your selections.',
    };
    (_valuations[vehicleId] ??= <Json>[]).insert(0, {
      'id': _id(),
      'state': body['state'],
      'condition': body['condition'],
      'mileage': vehicle['mileage'] ?? 0,
      'created_at': DateTime.now().toIso8601String(),
      'payload': {'buckets': _copy(result)['buckets']},
    });
    return result;
  }

  @override
  Future<Json> getKnowledge() async => {
    'records': _history.reversed.map(_copy).toList(),
    'preferences': {'share_aggregate_insights': _shareInsights},
  };
  @override
  Future<Json> addKnowledgeRecord(Json body, String idempotencyKey) async =>
      _once('history:$idempotencyKey', body, () {
        _find('vehicles', body['vehicle_id'] as String);
        final record = <String, dynamic>{
          ..._copy(body),
          'id': _id(),
          'source': 'customer_reported',
          'currency': 'USD',
          'receipts': <Json>[],
          'created_at': DateTime.now().toIso8601String(),
        };
        _history.add(record);
        return record;
      });
  @override
  Future<Json> updateKnowledgeRecord(String id, Json body) async {
    final row = _workspaceFind(_history, id);
    row.addAll(_copy(body));
    return _copy(row);
  }

  @override
  Future<void> deleteKnowledgeRecord(String id) async {
    _workspaceFind(_history, id);
    _history.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<Json> saveKnowledgePreferences(Json body) async {
    _shareInsights = body['share_aggregate_insights'] == true;
    return {'share_aggregate_insights': _shareInsights};
  }

  final Map<String, (String, String)> _requestsByKey = {};
  final _photoBytes = <String, Uint8List>{};
  final Random _random = Random.secure();
  @override
  bool get isDemo => true;
  String _id() =>
      'demo-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}';
  List<Json> _rows(String key) => (_state[key] as List).cast<Json>();
  @visibleForTesting
  Json debugEstimateRow(String id) => _find('estimates', id);
  Json _find(String key, String id) =>
      _rows(key).where((row) => row['id'] == id).firstOrNull ??
      (throw const PlusApiException('This item is no longer available.', 404));
  @override
  Future<PlusSnapshot> bootstrap() async =>
      PlusSnapshot.fromJson(jsonDecode(jsonEncode(_state)) as Json);
  @override
  Future<Json> saveProfile(Json body) async {
    (_state['profile'] as Json).addAll(body);
    return _state['profile'] as Json;
  }

  @override
  Future<Json> exportAccount() async => {
    'format': 'estimoto-plus/1',
    'demo': true,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'notes': 'Fictional demo data. Nothing here describes a real customer.',
    ...jsonDecode(jsonEncode(_state)) as Json,
    'service_history': {'records': jsonDecode(jsonEncode(_history))},
    'my_shops': jsonDecode(jsonEncode(_shops)),
    'shop_requests': jsonDecode(jsonEncode(_outreach)),
  };

  @override
  Future<Json> deleteAccount() async => throw const PlusApiException(
    'The demo has no account to delete. Leave the demo to discard its sample data.',
  );

  @override
  Future<Json> saveVehicle(Json body, {String? id}) async {
    if ((body['make'] as String? ?? '').trim().isEmpty ||
        (body['model'] as String? ?? '').trim().isEmpty) {
      throw const PlusApiException('Add your vehicle make and model.');
    }
    final record = id == null
        ? <String, dynamic>{'id': _id()}
        : _find('vehicles', id);
    record.addAll(body);
    if (id == null) _rows('vehicles').add(record);
    return record;
  }

  @override
  Future<void> deleteVehicle(String id) async {
    _find('vehicles', id);
    if ([
      'estimates',
      'repairs',
      'requests',
      'reminders',
    ].any((key) => _rows(key).any((row) => row['vehicle_id'] == id))) {
      throw const PlusApiException(
        'This vehicle has saved history. Keep it in your garage to preserve those records.',
        409,
      );
    }
    _rows('vehicles').removeWhere((row) => row['id'] == id);
  }

  @override
  Future<Json> createEstimate(Json body) async {
    _find('vehicles', body['vehicle_id'] as String);
    final record = <String, dynamic>{
      ...body,
      'id': _id(),
      'status': 'draft',
      'amount_cents': null,
      'provider_name': '',
      'updated_at': DateTime.now().toIso8601String(),
      'photos': <Json>[],
    };
    _rows('estimates').insert(0, record);
    return record;
  }

  @override
  Future<Json> uploadPhoto(
    String estimateId,
    Uint8List bytes,
    String filename,
    String label,
  ) async {
    final estimate = _find('estimates', estimateId);
    if (estimate['status'] != 'draft') {
      throw const PlusApiException('Photos can only be added to a draft.');
    }
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw const PlusApiException('Choose a photo smaller than 10 MB.');
    }
    final photo = <String, dynamic>{'id': _id(), 'label': label};
    _photoBytes['$estimateId/${photo['id']}'] = Uint8List.fromList(bytes);
    (estimate['photos'] as List).add(photo);
    return photo;
  }

  @override
  Future<Uint8List> getPhoto(String estimateId, String photoId) async =>
      _photoBytes['$estimateId/$photoId'] ??
      (throw const PlusApiException('This sample photo is unavailable.', 404));

  @override
  Future<Json> submitEstimate(
    String id,
    Json body,
    String idempotencyKey,
  ) async => throw const PlusApiException(
    'Your demo draft is saved. Live estimating will be available when your shop connects.',
    503,
  );
  @override
  Future<Json> createRequest(Json body, String idempotencyKey) async {
    final fingerprint = jsonEncode(freezeJson(body));
    final existing = _requestsByKey[idempotencyKey];
    if (existing != null) {
      if (existing.$1 != fingerprint) {
        throw const PlusApiException(
          'The request details changed. Review them before sending.',
          409,
        );
      }
      return _find('requests', existing.$2);
    }
    _find('vehicles', body['vehicle_id'] as String);
    final provider = ProviderProfile.fromJson(
      _find('providers', body['provider_id'] as String),
    );
    if (!RegExp(
      r'^\d{5}$',
    ).hasMatch((_state['profile'] as Json)['postal_code'] as String)) {
      throw const PlusApiException(
        'Add your service ZIP code in your profile before sending.',
      );
    }
    if (!provider.matches(
      specialty: body['specialty'] as String,
      postalCode: (_state['profile'] as Json)['postal_code'] as String,
    )) {
      throw const PlusApiException(
        'This provider is not available for that request.',
      );
    }
    if (body['share_contact'] != true) {
      throw const PlusApiException(
        'Choose to share your contact details before sending.',
      );
    }
    final now = DateTime.now().toIso8601String();
    final record = <String, dynamic>{
      ...body,
      if (body.containsKey('calendar_check')) ...{
        'calendar_check': false,
        'calendar_sample': true,
        'calendar_time_zone': _calendar['time_zone'],
        'calendar_sync_status': 'not_enabled',
      },
      'id': _id(),
      'status': 'requested',
      'delivery_status': 'local_preview',
      'created_at': now,
      'updated_at': now,
      'scheduled_at': null,
      'events': <Json>[
        {
          'status': 'requested',
          'message': 'Demo request saved. No provider was contacted.',
          'created_at': now,
        },
      ],
    };
    _rows('requests').add(record);
    _requestsByKey[idempotencyKey] = (fingerprint, record['id'] as String);
    return record;
  }

  @override
  Future<Json> cancelRequest(String id) async {
    final record = _find('requests', id);
    if (!ServiceRequest.fromJson(record).canCancel) {
      throw const PlusApiException(
        'This request can no longer be cancelled here.',
        409,
      );
    }
    record['status'] = 'cancelled';
    record['delivery_status'] = 'cancelled';
    record['updated_at'] = DateTime.now().toIso8601String();
    (record['events'] as List).add({
      'status': 'cancelled',
      'message': 'Request cancelled.',
      'created_at': record['updated_at'],
    });
    return record;
  }

  @override
  Future<Json> addReminder(Json body) async {
    _find('vehicles', body['vehicle_id'] as String);
    if (body['due_date'] == null && body['due_mileage'] == null) {
      throw const PlusApiException('Add a date or mileage for this reminder.');
    }
    final record = <String, dynamic>{...body, 'id': _id(), 'completed': false};
    _rows('reminders').add(record);
    return record;
  }

  @override
  Future<Json> completeReminder(String id) async {
    final row = _find('reminders', id);
    row['completed'] = true;
    return row;
  }

  @override
  Future<Json> updateReminder(String id, Json body) async {
    final row = _find('reminders', id);
    final merged = {...row, ...body};
    if (merged['due_date'] == null && merged['due_mileage'] == null) {
      throw const PlusApiException('Add a date or mileage for this reminder.');
    }
    if (body['vehicle_id'] != null) {
      _find('vehicles', body['vehicle_id'] as String);
    }
    row.addAll(body);
    return row;
  }

  @override
  Future<void> deleteReminder(String id) async {
    _find('reminders', id);
    _rows('reminders').removeWhere((r) => r['id'] == id);
  }

  @override
  Future<Json> reopenReminder(String id) async {
    final row = _find('reminders', id);
    row['completed'] = false;
    return row;
  }

  Json _editableEstimate(String id) {
    final row = _find('estimates', id);
    if (row['status'] != 'draft' ||
        (row['delivery_status'] ?? 'draft') != 'draft') {
      throw const PlusApiException(
        'This estimate has been shared and can no longer be changed.',
        409,
        'estimate_locked',
      );
    }
    return row;
  }

  @override
  Future<Json> updateEstimate(String id, Json body) async {
    final row = _editableEstimate(id);
    row.addAll(body);
    row['updated_at'] = DateTime.now().toIso8601String();
    return row;
  }

  @override
  Future<void> deleteEstimate(String id) async {
    _editableEstimate(id);
    _rows('estimates').removeWhere((e) => e['id'] == id);
    _photoBytes.removeWhere((key, _) => key.startsWith('$id/'));
  }

  @override
  Future<void> deletePhoto(String estimateId, String photoId) async {
    final row = _editableEstimate(estimateId);
    final photos = row['photos'] as List;
    if (!photos.any((p) => p['id'] == photoId)) {
      throw const PlusApiException('Not found.', 404);
    }
    photos.removeWhere((p) => p['id'] == photoId);
    _photoBytes.remove('$estimateId/$photoId');
  }

  @override
  Future<AssistantAnswer> askAssistant(Json body) async {
    final message = (body['message'] as String).toLowerCase();
    final vehicleId = body['vehicle_id'] as String?;
    if (vehicleId != null) _find('vehicles', vehicleId);
    final urgent = RegExp(
      r'brakes? (fail(ed|ure)?|not working)|smoke|overheat|fuel leak|burning smell|airbag|high voltage|unsafe|oil pressure',
    ).hasMatch(message);
    if (urgent) {
      return AssistantAnswer.fromJson({
        'reply':
            'That may need urgent professional attention. If you are driving, stop somewhere safe and arrange professional help. I can help you find a repair shop; tell me your ZIP code and what happened.',
        'intent': 'clarify',
        'specialty': 'mechanical',
      });
    }
    if (RegExp(r'schedul|appointment|book').hasMatch(message) &&
        RegExp(r'my shop|saved shop').hasMatch(message)) {
      return AssistantAnswer.fromJson({
        'reply':
            'Choose your saved shop and preferred times, then review the exact request before authorizing it. This demo will not contact a shop.',
        'intent': 'shop_outreach',
      });
    }
    if (RegExp(r'history|last service|parts source').hasMatch(message)) {
      final records = _history
          .where((r) => vehicleId == null || r['vehicle_id'] == vehicleId)
          .toList();
      return AssistantAnswer.fromJson({
        'reply': records.isEmpty
            ? 'You have no service history saved for this car yet. Open Service history to add work you have already had done.'
            : 'Your personal history includes ${records.length} service records. Open Service history to review the dates, shops and parts details you added.',
        'intent': 'history',
      });
    }
    final requested = body['specialty'] as String?;
    final specialty =
        requested ??
        (RegExp(r'dent|ding|hail|pdr').hasMatch(message)
            ? 'pdr'
            : RegExp(
                r'collision|bumper|accident|bodywork|paint',
              ).hasMatch(message)
            ? 'collision'
            : RegExp(
                r'oil|tire|tyre|filter|maintenance|service',
              ).hasMatch(message)
            ? 'maintenance'
            : RegExp(
                r'brake|noise|engine|light|battery|mechanic',
              ).hasMatch(message)
            ? 'mechanical'
            : null);
    final wantsProvider = RegExp(
      r'find|connect|someone|technician|tech\b|shop|book|request|come |repair|fix',
    ).hasMatch(message);
    if (wantsProvider) {
      if (specialty == null) {
        return AssistantAnswer.fromJson({
          'reply':
              'What would you like help with: a dent, collision damage, routine maintenance, or a mechanical issue?',
          'intent': 'clarify',
        });
      }
      final postal = body['postal_code'] as String? ?? '';
      if (postal.isEmpty || vehicleId == null) {
        return AssistantAnswer.fromJson({
          'reply':
              'Choose your vehicle and add a ZIP code in your profile so I can find providers who cover your area.',
          'intent': 'clarify',
          'specialty': specialty,
        });
      }
      final mobile =
          body['mobile_only'] == true ||
          RegExp(
            r'at (my )?(home|house|work)|mobile|driveway|come to',
          ).hasMatch(message);
      final discovery = await discoverProviders({
        ...body,
        'specialty': specialty,
        'mobile_only': mobile,
      });
      final providers = [
        ...rowsOf(discovery, 'providers'),
        ...rowsOf(discovery, 'shop_visit_alternatives'),
      ];
      return AssistantAnswer.fromJson({
        'reply': providers.isEmpty
            ? 'I could not find a participating provider for that service and ZIP code. You can adjust the service or look for a shop instead of mobile help.'
            : 'Here are sample nearby options for ${specialtyLabel(specialty).toLowerCase()}. Check whether each offers a shop visit or mobile service, then review your request. The provider must confirm availability.',
        'intent': 'find_provider',
        'specialty': specialty,
        'providers': providers,
        'discovery': {...discovery}
          ..remove('providers')
          ..remove('shop_visit_alternatives'),
      });
    }
    final reply = RegExp(r'oil').hasMatch(message)
        ? 'Your owner’s manual gives the correct oil specification and service interval for your engine. Check the date and mileage of your last service, then save a reminder in your garage. Tell me your vehicle and I can help you find service.'
        : RegExp(r'tire|tyre|pressure').hasMatch(message)
        ? 'Use the cold tire pressure on the driver-door placard or in your owner’s manual. Check with a gauge when the tires are cold. If a tire keeps losing pressure or has visible damage, have a technician inspect it.'
        : RegExp(r'estimate|cost|price').hasMatch(message)
        ? 'An estimate separates the work, parts and labor needed for your repair. Your Estimates tab holds the shop’s figures and review status. I can help you find a PDR technician or collision shop for a specific concern.'
        : _unmatchedReply;
    final videos =
        RegExp(r'how|video|tutorial').hasMatch(message) &&
            RegExp(r'oil|tire|tyre|pressure|filter').hasMatch(message)
        ? <Json>[
            {
              'title': 'Search YouTube for this maintenance topic',
              'url': Uri.https('www.youtube.com', '/results', {
                'search_query':
                    '${vehicleId == null ? '' : Vehicle.fromJson(_find('vehicles', vehicleId)).title} ${RegExp(r'tire|tyre|pressure').hasMatch(message)
                        ? 'check tire pressure'
                        : message.contains('oil')
                        ? 'oil service'
                        : 'air filter replacement'}',
              }).toString(),
              'source': 'YouTube search · review vehicle compatibility',
            },
          ]
        : <Json>[];
    return AssistantAnswer.fromJson({
      'reply': reply,
      'intent': reply == _unmatchedReply ? 'unmatched' : 'advice',
      'specialty': specialty,
      'videos': videos,
      if (reply == _unmatchedReply)
        'discovery': {
          'postal_code': (_state['profile'] as Json)['postal_code'],
          'specialty': specialty,
        },
    });
  }
}

const _unmatchedReply =
    "I can't answer that one yet. I can explain an estimate, plan routine maintenance, or find a technician near you.";

class _DemoReceiptApi extends ReceiptApi {
  _DemoReceiptApi(this.repository, this.recordId, this.isCurrent);
  final DemoPlusRepository repository;
  final String recordId;
  final bool Function() isCurrent;
  Json record() {
    if (!isCurrent()) {
      throw const PlusApiException('Sign in again to continue.', 401);
    }
    return repository._workspaceFind(repository._history, recordId);
  }

  @override
  Future<Json> upload(ReceiptPending value) async {
    final row = record();
    return repository._once(
      'receipt:${value.operationId}',
      {
        'record_id': recordId,
        'sha256': value.sha256,
        'filename': value.filename,
      },
      () {
        final receipts = row['receipts'] as List;
        if (receipts.length >= 10) {
          throw const PlusApiException(
            'This entry already has 10 receipts.',
            422,
          );
        }
        final id = repository._id();
        final result = <String, dynamic>{
          'id': id,
          'filename': value.filename,
          'content_type': value.mimeType,
          'byte_size': value.bytes.length,
          'created_at': DateTime.now().toIso8601String(),
        };
        receipts.add(result);
        repository._receiptBytes[id] = Uint8List.fromList(value.bytes);
        return result;
      },
    );
  }

  @override
  Future<Uint8List> read(String id) async {
    final row = record();
    if (!rowsOf(row, 'receipts').any((r) => r['id'] == id)) {
      throw const PlusApiException('Receipt unavailable.', 404);
    }
    return Uint8List.fromList(repository._receiptBytes[id]!);
  }

  @override
  Future<void> delete(String id) async {
    final row = record();
    (row['receipts'] as List).removeWhere((r) => r['id'] == id);
    repository._receiptBytes.remove(id);
  }
}
