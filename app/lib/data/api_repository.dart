import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../domain/models.dart';
import 'repository.dart';
import '../services/calendar_errors.dart';
import '../services/receipt_api.dart';
import '../services/receipt_pending_types.dart';
import '../services/guided_capture_api.dart';
import '../services/guided_capture_pending_types.dart';

class ApiPlusRepository extends PlusRepository {
  ApiPlusRepository({
    required String baseUrl,
    required this.token,
    http.Client? client,
  }) : baseUri = Uri.parse(
         baseUrl.endsWith('/')
             ? baseUrl.substring(0, baseUrl.length - 1)
             : baseUrl,
       ),
       _client = client ?? http.Client() {
    if (!baseUri.hasAuthority ||
        (baseUri.scheme != 'https' &&
            !(baseUri.scheme == 'http' &&
                const [
                  'localhost',
                  '127.0.0.1',
                  '10.0.2.2',
                  '::1',
                ].contains(baseUri.host)))) {
      throw const PlusApiException(
        'A secure Estimoto + connection is required.',
      );
    }
    if (baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        (baseUri.path.isNotEmpty && baseUri.path != '/')) {
      throw const PlusApiException(
        'The Estimoto + address must be a server origin.',
      );
    }
  }
  final Uri baseUri;
  final Future<String?> Function() token;
  final http.Client _client;
  @override
  bool get isDemo => false;
  @override
  GuidedCaptureApi openGuidedCapture(
    String estimateId, {
    required bool Function() isCurrent,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,35}$').hasMatch(estimateId)) {
      throw const PlusApiException('This estimate is unavailable.', 404);
    }
    return _ApiGuidedCapture(this, estimateId, isCurrent);
  }

  @override
  ReceiptApi openReceiptRecord(
    String recordId, {
    required bool Function() isCurrent,
  }) => _ApiReceiptRecord(this, recordId, isCurrent);

  Future<Map<String, String>> _headers() async {
    final accessToken = await token();
    if (accessToken == null || accessToken.isEmpty) {
      throw const PlusApiException('Please sign in to continue.', 401);
    }
    return {
      'Authorization': 'Bearer $accessToken',
      'Accept': 'application/json',
    };
  }

  Future<Json> _send(
    String method,
    String path, {
    Json? body,
    String? idempotencyKey,
    bool collection = false,
    bool Function()? isCurrent,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    void check() {
      if (isCurrent != null && !isCurrent()) {
        throw const PlusApiException(
          'Your vehicle or account changed. Reopen this page to continue.',
          401,
        );
      }
    }

    check();
    final request = http.Request(method, baseUri.resolve(path));
    request.headers.addAll(await _headers());
    check();
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    request.followRedirects = false;
    try {
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
      check();
      return _decode(response, collection: collection);
    } on TimeoutException {
      throw const PlusApiException(
        'The connection timed out. Refresh to check whether your changes were saved before trying again.',
      );
    } on http.ClientException {
      throw const PlusApiException(
        'Could not connect. Check your connection and try again.',
      );
    }
  }

  Json _decode(http.Response response, {bool collection = false}) {
    if (response.statusCode == 401) {
      throw const PlusApiException(
        'Your session has ended. Please sign in again.',
        401,
      );
    }
    if (response.statusCode >= 300) {
      String? code, serverMessage;
      if (response.statusCode == 409) {
        try {
          final error = jsonDecode(response.body);
          if (error is Map && error['code'] == 'request_not_created') {
            code = 'request_not_created';
          } else if (error is Map &&
              const [
                'open_requests',
                'limit_reached',
              ].contains(error['code']) &&
              error['detail'] is String) {
            // These conflicts carry customer-ready wording from the server.
            code = error['code'] as String;
            serverMessage = error['detail'] as String;
          }
        } on FormatException {
          // An unrecognized conflict remains unresolved; never guess it was rejected.
        }
      }
      const errors = {
        403: 'This action is not available for your account.',
        404: 'This item is no longer available.',
        409: 'This item has changed. Refresh and try again.',
        413: 'Choose a photo smaller than 10 MB.',
        415: 'Choose a JPEG, PNG or WebP photo.',
        422: 'Check the details and try again.',
        429: 'Please wait a moment before trying again.',
        503:
            'This service is not connected yet. Your saved drafts are still available.',
      };
      final calendarMessage = safeCalendarError(
        response.statusCode,
        response.body,
      );
      throw PlusApiException(
        code == 'request_not_created'
            ? 'That provider is no longer available for this request. Choose another provider.'
            : serverMessage ??
                  calendarMessage ??
                  errors[response.statusCode] ??
                  'We could not complete that action. Please try again.',
        response.statusCode,
        code,
      );
    }
    if (response.body.isEmpty) return {};
    try {
      final decoded = jsonDecode(response.body);
      // Collection routes return bare arrays; keep object routes unchanged.
      if (collection && decoded is List) return {'items': decoded};
      return Map<String, dynamic>.from(decoded as Map);
    } on FormatException {
      throw const PlusApiException(
        'We received an unreadable response. Please try again.',
      );
    } on TypeError {
      throw const PlusApiException(
        'We received an unexpected response. Please try again.',
      );
    }
  }

  @override
  Future<Json> discoverProviders(Json query) => _send(
    'GET',
    Uri(
      path: '/v1/discovery',
      queryParameters: {
        if (query['postal_code'] != null)
          'postal_code': query['postal_code'].toString(),
        'radius_miles': '30',
        if (query['q'] != null) 'q': query['q'].toString(),
        'make_only': (query['make_only'] == true).toString(),
        if (query['vehicle_id'] != null)
          'vehicle_id': query['vehicle_id'].toString(),
        if (query['specialty'] != null)
          'specialty': query['specialty'].toString(),
        'mobile_only': (query['mobile_only'] == true).toString(),
      },
    ).toString(),
    timeout: const Duration(seconds: 90),
  );
  @override
  Future<List<Json>> listDiscoveryFavorites(String vehicleId) async => rowsOf(
    await _send(
      'GET',
      Uri(
        path: '/v1/discovery/favorites',
        queryParameters: {'vehicle_id': vehicleId},
      ).toString(),
      collection: true,
    ),
    'items',
  );
  @override
  Future<Json> saveDiscoveryFavorite(String specialty, Json body) => _send(
    'PUT',
    '/v1/discovery/favorites/${Uri.encodeComponent(specialty)}',
    body: body,
  );
  @override
  Future<void> deleteDiscoveryFavorite(
    String specialty,
    String vehicleId,
  ) async {
    await _send(
      'DELETE',
      Uri(
        path: '/v1/discovery/favorites/${Uri.encodeComponent(specialty)}',
        queryParameters: {'vehicle_id': vehicleId},
      ).toString(),
    );
  }

  @override
  Future<Json> getCalendarStatus() =>
      _send('GET', '/v1/calendar/google/status');
  @override
  Future<Json> connectGoogleCalendar() =>
      _send('POST', '/v1/calendar/google/connect');
  @override
  Future<Json> reconcileGoogleCalendar(String attemptId) => _send(
    'POST',
    '/v1/calendar/google/reconcile',
    body: {'attempt_id': attemptId},
  );
  @override
  Future<Json> listGoogleCalendars() =>
      _send('GET', '/v1/calendar/google/calendars');
  @override
  Future<Json> saveCalendarPreferences(Json body) =>
      _send('PUT', '/v1/calendar/google/preferences', body: body);
  @override
  Future<Json> findCalendarAvailability(Json body) =>
      _send('POST', '/v1/calendar/google/availability', body: body);
  @override
  Future<Json> disconnectGoogleCalendar() =>
      _send('DELETE', '/v1/calendar/google/connection');
  @override
  Future<Json> retryCalendarSync(Json body) =>
      _send('POST', '/v1/calendar/google/sync/retry', body: body);

  @override
  Future<PlusSnapshot> bootstrap() async =>
      PlusSnapshot.fromJson(await _send('GET', '/v1/bootstrap'));
  @override
  Future<Json> saveProfile(Json body) =>
      _send('PUT', '/v1/profile', body: body);
  @override
  Future<Json> saveVehicle(Json body, {String? id}) => _send(
    id == null ? 'POST' : 'PUT',
    id == null ? '/v1/vehicles' : '/v1/vehicles/${Uri.encodeComponent(id)}',
    body: body,
  );
  @override
  Future<void> deleteVehicle(String id) async {
    await _send('DELETE', '/v1/vehicles/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Json> exportAccount() =>
      _send('GET', '/v1/account/export', timeout: const Duration(seconds: 60));

  @override
  Future<Json> deleteAccount() =>
      _send('DELETE', '/v1/account', timeout: const Duration(seconds: 60));

  @override
  Future<VehiclePhoto?> getVehicleImage(String id) async {
    final request = http.Request(
      'GET',
      baseUri.resolve('/v1/vehicles/${Uri.encodeComponent(id)}/image'),
    );
    request.headers.addAll(await _headers());
    request.headers['Accept'] = 'image/webp';
    request.followRedirects = false;
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 204) {
        await response.stream.listen(null).cancel();
        return null;
      }
      if (response.statusCode != 200) {
        final body = await http.ByteStream(
          response.stream.take(1),
        ).toBytes().timeout(const Duration(seconds: 5));
        _decode(http.Response.bytes(body, response.statusCode));
      }
      final source = response.headers['x-vehicle-image-source'];
      if (response.headers['content-type']?.split(';').first.trim() !=
              'image/webp' ||
          !const ['upload', 'carsxe'].contains(source)) {
        await response.stream.listen(null).cancel();
        throw const PlusApiException(
          'This vehicle photo could not be displayed.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (bytes.length + chunk.length > 10 * 1024 * 1024) {
          throw const PlusApiException(
            'This vehicle photo is too large to display.',
          );
        }
        bytes.add(chunk);
      }
      return VehiclePhoto(bytes.takeBytes(), source: source!);
    } on TimeoutException {
      throw const PlusApiException(
        'Vehicle photo loading timed out. Try again.',
      );
    } on http.ClientException {
      throw const PlusApiException(
        'Could not load the vehicle photo. Check your connection.',
      );
    }
  }

  @override
  Future<Json> uploadVehicleImage(
    String id,
    Uint8List bytes,
    String filename,
  ) async {
    final subtype = switch (filename.split('.').last.toLowerCase()) {
      'jpg' || 'jpeg' => 'jpeg',
      'png' => 'png',
      'webp' => 'webp',
      _ => null,
    };
    if (subtype == null) {
      throw const PlusApiException('Choose a JPEG, PNG or WebP photo.');
    }
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw const PlusApiException('Choose a photo smaller than 10 MB.');
    }
    final request = http.MultipartRequest(
      'POST',
      baseUri.resolve('/v1/vehicles/${Uri.encodeComponent(id)}/image'),
    );
    request.followRedirects = false;
    request.headers.addAll(await _headers());
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: MediaType('image', subtype),
      ),
    );
    try {
      return _decode(
        await http.Response.fromStream(
          await _client.send(request).timeout(const Duration(seconds: 45)),
        ).timeout(const Duration(seconds: 45)),
      );
    } on TimeoutException {
      throw const PlusApiException(
        'Photo upload timed out. Refresh to check your saved photo before retrying.',
      );
    } on http.ClientException {
      throw const PlusApiException(
        'Photo upload failed. Check your connection and try again.',
      );
    }
  }

  @override
  Future<void> deleteVehicleImage(String id) async {
    await _send('DELETE', '/v1/vehicles/${Uri.encodeComponent(id)}/image');
  }

  @override
  Future<Json> createEstimate(Json body) =>
      _send('POST', '/v1/estimates', body: body);
  @override
  Future<Json> submitEstimate(String id, Json body, String idempotencyKey) =>
      _send(
        'POST',
        '/v1/estimates/${Uri.encodeComponent(id)}/submit',
        body: body,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<Uint8List> getPhoto(String estimateId, String photoId) async {
    final request = http.Request(
      'GET',
      baseUri.resolve(
        '/v1/estimates/${Uri.encodeComponent(estimateId)}/photos/${Uri.encodeComponent(photoId)}',
      ),
    );
    request.headers.addAll(await _headers());
    request.followRedirects = false;
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        final body = await http.ByteStream(
          response.stream.take(1),
        ).toBytes().timeout(const Duration(seconds: 5));
        _decode(http.Response.bytes(body, response.statusCode));
        throw const PlusApiException('This photo could not be loaded.');
      }
      final result = BytesBuilder(copy: false);
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (result.length + bytes.length > 10 * 1024 * 1024) {
          throw const PlusApiException('This photo is too large to display.');
        }
        result.add(bytes);
      }
      return result.takeBytes();
    } on TimeoutException {
      throw const PlusApiException('Photo loading timed out. Try again.');
    } on http.ClientException {
      throw const PlusApiException(
        'Could not load the photo. Check your connection.',
      );
    }
  }

  @override
  Future<Json> createRequest(Json body, String idempotencyKey) =>
      _send('POST', '/v1/requests', body: body, idempotencyKey: idempotencyKey);
  @override
  Future<Json> cancelRequest(String id) =>
      _send('POST', '/v1/requests/${Uri.encodeComponent(id)}/cancel');
  @override
  Future<Json> addReminder(Json body) =>
      _send('POST', '/v1/reminders', body: body);
  @override
  Future<Json> completeReminder(String id) =>
      _send('POST', '/v1/reminders/${Uri.encodeComponent(id)}/complete');
  @override
  Future<Json> updateReminder(String id, Json body) =>
      _send('PUT', '/v1/reminders/${Uri.encodeComponent(id)}', body: body);
  @override
  Future<void> deleteReminder(String id) async {
    await _send('DELETE', '/v1/reminders/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Json> reopenReminder(String id) =>
      _send('POST', '/v1/reminders/${Uri.encodeComponent(id)}/reopen');
  @override
  Future<Json> updateEstimate(String id, Json body) =>
      _send('PUT', '/v1/estimates/${Uri.encodeComponent(id)}', body: body);
  @override
  Future<void> deleteEstimate(String id) async {
    await _send('DELETE', '/v1/estimates/${Uri.encodeComponent(id)}');
  }

  @override
  Future<void> deletePhoto(String estimateId, String photoId) async {
    await _send(
      'DELETE',
      '/v1/estimates/${Uri.encodeComponent(estimateId)}/photos/${Uri.encodeComponent(photoId)}',
    );
  }

  @override
  Future<void> deleteShopOutreach(String id) async {
    await _send('DELETE', '/v1/shop-outreach/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Json> withdrawShopOutreach(String id) =>
      _send('POST', '/v1/shop-outreach/${Uri.encodeComponent(id)}/withdraw');
  @override
  Future<Json> updateKnowledgeRecord(String id, Json body) => _send(
    'PUT',
    '/v1/knowledge/records/${Uri.encodeComponent(id)}',
    body: body,
  );
  @override
  Future<Json> listVehicleValuations(String vehicleId) =>
      _send('GET', '/v1/vehicles/${Uri.encodeComponent(vehicleId)}/valuations');
  @override
  Future<void> deleteVehicleValuation(
    String vehicleId,
    String valuationId,
  ) async {
    await _send(
      'DELETE',
      '/v1/vehicles/${Uri.encodeComponent(vehicleId)}/valuations/${Uri.encodeComponent(valuationId)}',
    );
  }

  @override
  Future<AssistantAnswer> askAssistant(Json body) async =>
      AssistantAnswer.fromJson(
        await _send(
          'POST',
          '/v1/assistant',
          body: body,
          timeout: const Duration(seconds: 60),
        ),
      );

  @override
  Future<Json> uploadPhoto(
    String estimateId,
    Uint8List bytes,
    String filename,
    String label,
  ) async {
    final extension = filename.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'jpeg',
      'png' => 'png',
      'webp' => 'webp',
      _ => null,
    };
    if (mime == null) {
      throw const PlusApiException('Choose a JPEG, PNG or WebP photo.');
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw const PlusApiException('Choose a photo smaller than 10 MB.');
    }
    final request = http.MultipartRequest(
      'POST',
      baseUri.resolve(
        '/v1/estimates/${Uri.encodeComponent(estimateId)}/photos',
      ),
    );
    request.followRedirects = false;
    request.headers.addAll(await _headers());
    request.fields['label'] = label;
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: MediaType('image', mime),
      ),
    );
    try {
      return _decode(
        await http.Response.fromStream(
          await _client.send(request).timeout(const Duration(seconds: 45)),
        ).timeout(const Duration(seconds: 45)),
      );
    } on TimeoutException {
      throw const PlusApiException(
        'Photo upload timed out. Refresh your draft before retrying.',
      );
    } on http.ClientException {
      throw const PlusApiException(
        'Photo upload failed. Check your connection and try again.',
      );
    }
  }

  @override
  Future<List<Json>> listMyShops() async =>
      rowsOf(await _send('GET', '/v1/my-shops', collection: true), 'items');
  @override
  Future<Json> saveMyShop(Json body, {String? id}) => _send(
    id == null ? 'POST' : 'PUT',
    id == null ? '/v1/my-shops' : '/v1/my-shops/${Uri.encodeComponent(id)}',
    body: body,
  );
  @override
  Future<void> deleteMyShop(String id) async {
    await _send('DELETE', '/v1/my-shops/${Uri.encodeComponent(id)}');
  }

  @override
  Future<List<Json>> listShopOutreach() async => rowsOf(
    await _send('GET', '/v1/shop-outreach', collection: true),
    'items',
  );
  @override
  Future<Json> getShopOutreach(String id) =>
      _send('GET', '/v1/shop-outreach/${Uri.encodeComponent(id)}');
  @override
  Future<Json> createShopOutreach(Json body, String idempotencyKey) => _send(
    'POST',
    '/v1/shop-outreach',
    body: body,
    idempotencyKey: idempotencyKey,
  );
  @override
  Future<Json> authorizeShopOutreach(
    String id,
    Json body,
    String idempotencyKey,
  ) => _send(
    'POST',
    '/v1/shop-outreach/${Uri.encodeComponent(id)}/authorize',
    body: body,
    idempotencyKey: idempotencyKey,
  );
  @override
  Future<Json> lookupVehicleValue(
    String vehicleId,
    Json body, {
    required bool Function() isCurrent,
  }) => _send(
    'POST',
    '/v1/vehicles/${Uri.encodeComponent(vehicleId)}/valuation',
    body: body,
    isCurrent: isCurrent,
    timeout: const Duration(seconds: 45),
  );
  @override
  Future<Json> getKnowledge() => _send('GET', '/v1/knowledge');
  @override
  Future<Json> addKnowledgeRecord(Json body, String idempotencyKey) => _send(
    'POST',
    '/v1/knowledge/records',
    body: body,
    idempotencyKey: idempotencyKey,
  );
  @override
  Future<void> deleteKnowledgeRecord(String id) async {
    await _send('DELETE', '/v1/knowledge/records/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Json> saveKnowledgePreferences(Json body) =>
      _send('PUT', '/v1/knowledge/preferences', body: body);

  @override
  void close() => _client.close();
}

class _ApiGuidedCapture extends GuidedCaptureApi {
  _ApiGuidedCapture(this.repository, this.estimateId, this.isCurrent);
  final ApiPlusRepository repository;
  final String estimateId;
  final bool Function() isCurrent;
  @override
  Uri get pageUri => repository.baseUri.resolve('/capture/');
  void check() {
    if (!isCurrent()) {
      throw const PlusApiException(
        'Capture is paused or your account changed. Reopen the guide to continue.',
        401,
      );
    }
  }

  Future<Json> request(
    String method,
    String suffix, {
    Json? body,
    Uint8List? bytes,
    String? mimeType,
    Map<String, String>? fields,
  }) async {
    check();
    final headers = await repository._headers();
    check();
    final uri = repository.baseUri.resolve(
      '/v1/estimates/${Uri.encodeComponent(estimateId)}/capture$suffix',
    );
    final http.BaseRequest outgoing;
    if (bytes != null) {
      if (bytes.isEmpty ||
          bytes.length > maxGuidedCaptureBytes ||
          !const ['image/jpeg', 'image/png', 'image/webp'].contains(mimeType)) {
        throw const PlusApiException(
          'Choose a JPEG, PNG or WebP photo under 8 MB.',
          422,
        );
      }
      outgoing = http.MultipartRequest(method, uri)
        ..fields.addAll(fields!)
        ..files.add(
          http.MultipartFile.fromBytes(
            'photo',
            bytes,
            filename: 'capture',
            contentType: MediaType.parse(mimeType!),
          ),
        );
    } else {
      final value = http.Request(method, uri);
      if (body != null) {
        value.headers['Content-Type'] = 'application/json';
        value.body = jsonEncode(body);
      }
      outgoing = value;
    }
    outgoing.headers.addAll(headers);
    outgoing.followRedirects = false;
    check();
    try {
      final response = await repository._client
          .send(outgoing)
          .timeout(const Duration(seconds: 45));
      check();
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 8),
      )) {
        check();
        if (buffer.length + chunk.length > 128 * 1024) {
          throw const PlusApiException(
            'Capture received an unreadable response. Keep this photo and retry.',
            502,
          );
        }
        buffer.add(chunk);
      }
      check();
      final raw = utf8.decode(buffer.takeBytes());
      Json? decoded;
      try {
        final value = jsonDecode(raw);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {}
      if (response.statusCode >= 300) {
        final detail = decoded?['detail'];
        const safeDetails = {
          'This capture expired. Take the photo again.',
          'This photo is still saving. Retry the same photo shortly.',
          'This photo is being recovered. Retry the same photo shortly.',
          'The staged photo needs recovery. Keep the same capture and contact support.',
          'Photography is closed for this estimate.',
          'Photo storage limit reached. Contact support.',
          'Estimate photo limit reached.',
          'The VIN photo changed. Take another photo.',
          'The VIN photo changed. Try the new photo.',
          'The VIN photo changed. Review the new photo before confirming.',
          'Your saved VIN changed. Review it before confirming.',
          'Enter the 17 VIN characters shown on the label.',
          'VIN recognition is temporarily unavailable.',
          'Capture assistance is temporarily unavailable.',
          'Photo validation is busy. Keep this photo and retry shortly.',
        };
        final message = safeDetails.contains(detail)
            ? detail as String
            : switch (response.statusCode) {
                401 => 'Your session ended. Sign in again before continuing.',
                403 ||
                404 => 'This capture is unavailable for the current account.',
                409 =>
                  'This capture needs recovery. Keep the same photo and retry.',
                413 =>
                  'Photo storage is full or this photo is too large. Keep it and review recovery options.',
                422 =>
                  'Check this photo and capture step, then take the photo again.',
                429 => 'Please wait a moment, then retry the same photo.',
                _ =>
                  'Capture assistance is temporarily unavailable. Keep this photo and retry.',
              };
        throw PlusApiException(message, response.statusCode);
      }
      if (decoded == null) {
        throw const PlusApiException(
          'Capture received an unreadable response. Keep this photo and retry.',
          502,
        );
      }
      return decoded;
    } on TimeoutException {
      throw const PlusApiException(
        'Capture timed out. Keep the same photo and retry.',
        408,
      );
    } on http.ClientException {
      throw const PlusApiException(
        'The connection was interrupted. Keep the same photo and retry.',
        503,
      );
    } on FormatException {
      throw const PlusApiException(
        'Capture received an unreadable response. Keep this photo and retry.',
        502,
      );
    }
  }

  @override
  Future<Json> state() => request('GET', '');
  @override
  Future<Json> checkFrame({
    required Uint8List bytes,
    required String mimeType,
    required String captureKey,
    required String bodyStyle,
  }) => request(
    'POST',
    '/guidance',
    bytes: bytes,
    mimeType: mimeType,
    fields: {'capture_key': captureKey, 'body_style': bodyStyle},
  );
  @override
  Future<Json> save(GuidedCapturePending photo) {
    if (photo.estimateId != estimateId) {
      throw const PlusApiException(
        'This capture belongs to another estimate.',
        409,
      );
    }
    return request(
      'POST',
      '/photos',
      bytes: photo.bytes,
      mimeType: photo.mimeType,
      fields: {
        'capture_key': photo.captureKey,
        'body_style': photo.bodyStyle,
        'operation_id': photo.operationId,
      },
    );
  }

  @override
  Future<Json> recognize(String photoId) =>
      request('POST', '/vin/recognize', body: {'photo_id': photoId});
  @override
  Future<Json> confirm(Json body) =>
      request('POST', '/vin/confirm', body: body);
  @override
  Future<Json> help(String captureKey, String question) => request(
    'POST',
    '/help',
    body: {'capture_key': captureKey, 'question': question},
  );
}

class _ApiReceiptRecord extends ReceiptApi {
  _ApiReceiptRecord(this.repository, this.recordId, this.isCurrent);
  final ApiPlusRepository repository;
  final String recordId;
  final bool Function() isCurrent;
  void check() {
    if (!isCurrent()) {
      throw const PlusApiException(
        'Your account changed. Reopen your history to continue.',
        401,
      );
    }
  }

  Future<http.Response> request(
    String method, {
    String? receiptId,
    ReceiptPending? upload,
    String action = '',
    Json? body,
  }) async {
    check();
    final headers = await repository._headers();
    check();
    final path =
        '/v1/knowledge/records/${Uri.encodeComponent(recordId)}/receipts${receiptId == null ? '' : '/${Uri.encodeComponent(receiptId)}'}$action';
    final uri = repository.baseUri.resolve(path);
    final http.BaseRequest outgoing;
    if (upload != null) {
      if (upload.recordId != recordId) {
        throw const PlusApiException(
          'Open the original history entry for this receipt.',
          409,
        );
      }
      outgoing = http.MultipartRequest(method, uri)
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            upload.bytes,
            filename: upload.filename,
            contentType: MediaType.parse(upload.mimeType),
          ),
        );
      headers['Idempotency-Key'] = upload.operationId;
    } else {
      final jsonRequest = http.Request(method, uri);
      if (body != null) {
        headers['Content-Type'] = 'application/json';
        jsonRequest.body = jsonEncode(body);
      }
      outgoing = jsonRequest;
    }
    outgoing.headers.addAll(headers);
    outgoing.followRedirects = false;
    check();
    try {
      final response = await repository._client
          .send(outgoing)
          .timeout(const Duration(seconds: 60));
      check();
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        check();
        if (buffer.length + chunk.length > maxReceiptBytes) {
          throw const PlusApiException(
            'This receipt is too large to open.',
            413,
          );
        }
        buffer.add(chunk);
      }
      check();
      final result = http.Response.bytes(
        buffer.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
      if (result.statusCode >= 300) {
        throw PlusApiException(switch (result.statusCode) {
          401 => 'Your session ended. Sign in again to open your receipts.',
          403 || 404 => 'This history entry or receipt is no longer available.',
          409 =>
            action.isNotEmpty
                ? 'The recorded cost changed. Refresh and review the amount again.'
                : 'This saved upload conflicts with an earlier file. Refresh your receipts before discarding it.',
          410 =>
            'This receipt was deleted. Discard the saved upload to choose another file.',
          413 => 'Choose a receipt no larger than 10 MB.',
          415 => 'Choose a readable JPEG, PNG, WebP or PDF receipt.',
          422 =>
            action.isNotEmpty
                ? 'No supported receipt total is available. Enter the cost manually.'
                : 'This entry already has 10 receipts. Delete one before adding another.',
          429 => 'Please wait a moment, then retry the same saved receipt.',
          _ =>
            'The receipt could not be saved or opened. Retry when your connection is available.',
        }, result.statusCode);
      }
      return result;
    } on TimeoutException {
      throw const PlusApiException(
        'The receipt connection timed out. Retry the same saved file.',
        408,
      );
    } on http.ClientException {
      throw const PlusApiException(
        'The connection was interrupted. Retry the same saved receipt.',
        503,
      );
    }
  }

  @override
  Future<Json> upload(ReceiptPending value) async =>
      repository._decode(await request('POST', upload: value));
  @override
  Future<Uint8List> read(String receiptId) async =>
      (await request('GET', receiptId: receiptId)).bodyBytes;
  @override
  Future<void> delete(String receiptId) async {
    await request('DELETE', receiptId: receiptId);
  }

  @override
  Future<Json> parseTotal(String receiptId) async => repository._decode(
    await request('POST', receiptId: receiptId, action: '/parse-total'),
  );
  @override
  Future<Json> applyTotal(String receiptId, int? expectedCostCents) async =>
      repository._decode(
        await request(
          'POST',
          receiptId: receiptId,
          action: '/apply-total',
          body: {'expected_cost_cents': expectedCostCents},
        ),
      );
}
