import 'dart:typed_data';

typedef Json = Map<String, dynamic>;

class VehiclePhoto {
  const VehiclePhoto(this.bytes, {required this.source});
  final Uint8List bytes;
  final String source;
  bool get isUpload => source == 'upload';
  String get label => isUpload ? 'Your photo' : 'Representative image';
}

String textOf(Json data, String key, [String fallback = '']) =>
    data[key]?.toString() ?? fallback;
int intOf(Json data, String key, [int fallback = 0]) =>
    (data[key] as num?)?.toInt() ?? fallback;
List<Json> rowsOf(Json data, String key) => (data[key] as List? ?? [])
    .map((row) => Map<String, dynamic>.from(row as Map))
    .toList();
String specialtyLabel(String value) => switch (value) {
  'pdr' => 'PDR',
  'collision' => 'Collision',
  'maintenance' => 'Maintenance',
  'mechanical' => 'Mechanical',
  _ => value,
};

class CustomerProfile {
  CustomerProfile.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get name => textOf(json, 'name');
  String get firstName =>
      name.trim().isEmpty ? 'there' : name.trim().split(' ').first;
  String get email => textOf(json, 'email');
  String get phone => textOf(json, 'phone');
  String get postalCode => textOf(json, 'postal_code');
  bool get emailUpdates => json['email_updates'] != false;
}

class Vehicle {
  Vehicle.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  int get year => intOf(json, 'year');
  String get make => textOf(json, 'make');
  String get model => textOf(json, 'model');
  String get nickname => textOf(json, 'nickname');
  String get vin => textOf(json, 'vin');
  int get mileage => intOf(json, 'mileage');
  String get title => '$year $make $model';
  String get displayName => nickname.isEmpty ? '$make $model' : nickname;
  String get imageVersion => textOf(json, 'image_version');
}

/// Published provider media, reviewed local artwork or licensed Commons photos.
/// Arbitrary website images and private signed URLs are never accepted.
class ProviderMedia {
  const ProviderMedia._(
    this.url,
    this.kind,
    this.attribution,
    this.sourceUrl, {
    this.darkBackground = false,
  });
  final Uri url, sourceUrl;
  final String kind, attribution;
  final bool darkBackground;

  static ProviderMedia? fromJson(
    Object? value, {
    required String providerSource,
    required String providerSourceId,
    Object? mediaIdentity,
  }) {
    if (value is! Map) return null;
    var imageSource = providerSource, imageSourceId = providerSourceId;
    if (mediaIdentity != null) {
      if (mediaIdentity is! Map ||
          mediaIdentity['source'] is! String ||
          mediaIdentity['source_id'] is! String) {
        return null;
      }
      final source = mediaIdentity['source'] as String;
      final sourceId = mediaIdentity['source_id'] as String;
      // Discovery may retain the participating provider for requests while
      // borrowing artwork from its exact, reviewed public-listing duplicate.
      // An independent row cannot override its own listing identity.
      if ((source != providerSource || sourceId != providerSourceId) &&
          !(providerSource == 'estimoto' && source == 'openstreetmap')) {
        return null;
      }
      imageSource = source;
      imageSourceId = sourceId;
    }
    if (imageSource == 'openstreetmap' &&
        !RegExp(
          r'^(node|way|relation):[1-9][0-9]{0,18}$',
        ).hasMatch(imageSourceId)) {
      return null;
    }
    final url = value['url'], kind = value['kind'];
    final attribution = value['attribution'], source = value['source_url'];
    if (url is! String ||
        kind is! String ||
        attribution is! String ||
        source is! String ||
        attribution.trim().isEmpty ||
        attribution.length > 1000 ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(attribution)) {
      return null;
    }
    Uri? safeUri(String value) {
      if (value.isEmpty || value.length > 2048 || value != value.trim()) {
        return null;
      }
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.port != 443) {
        return null;
      }
      return uri;
    }

    final imageUri = safeUri(url), sourceUri = safeUri(source);
    if (imageUri == null || sourceUri == null || sourceUri.hasQuery) {
      return null;
    }
    if (kind == 'logo' && imageSource == 'estimoto') {
      if (!RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
          ).hasMatch(imageSourceId) ||
          imageUri.host != 'pdr-estimating-api.fly.dev' ||
          imageUri.path != '/public/plus/providers/$imageSourceId/logo' ||
          imageUri.hasQuery ||
          sourceUri.host != 'www.estimoto.io' ||
          !const ['', '/'].contains(sourceUri.path)) {
        return null;
      }
    } else if (imageSource == 'openstreetmap' &&
        const ['logo', 'photo'].contains(kind) &&
        imageUri.host == 'estimoto-plus-api.fly.dev') {
      final sourceParts = imageSourceId.split(':');
      final parts = imageUri.pathSegments;
      if (sourceParts.length != 2 ||
          !const ['node', 'way', 'relation'].contains(sourceParts[0]) ||
          !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(sourceParts[1]) ||
          parts.length != 5 ||
          parts[0] != 'public' ||
          parts[1] != 'shop-media' ||
          parts[2] != sourceParts[0] ||
          parts[3] != sourceParts[1] ||
          !RegExp(r'^[a-f0-9]{64}\.png$').hasMatch(parts[4]) ||
          imageUri.hasQuery) {
        return null;
      }
    } else if (kind == 'photo' && imageSource == 'openstreetmap') {
      final parts = imageUri.pathSegments;
      if (imageUri.host != 'commons.wikimedia.org' ||
          parts.length != 4 ||
          parts[0] != 'wiki' ||
          parts[1] != 'Special:Redirect' ||
          parts[2] != 'file' ||
          imageUri.query != 'width=320') {
        return null;
      }
      final file = parts[3];
      final sourceParts = sourceUri.pathSegments;
      if (file.isEmpty ||
          file.length > 255 ||
          RegExp(r'[/\\?#\x00-\x1F\x7F]').hasMatch(file) ||
          sourceUri.host != 'commons.wikimedia.org' ||
          sourceParts.length != 2 ||
          sourceParts[0] != 'wiki' ||
          sourceParts[1] != 'File:$file') {
        return null;
      }
    } else {
      return null;
    }
    return ProviderMedia._(
      imageUri,
      kind,
      attribution.trim(),
      sourceUri,
      darkBackground: value['background'] == 'dark',
    );
  }
}

class ProviderProfile {
  ProviderProfile.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get name => textOf(json, 'name');
  String get kind => textOf(json, 'kind', 'shop');
  String get city => textOf(json, 'city');
  String get address => textOf(json, 'address');
  String get displayAddress =>
      json['verification'] is Map &&
          json['verification']['status'] == 'contact_confirmed'
      ? '${json['verification']['address']}'
      : address;
  String get phone => textOf(json, 'phone');
  String get description => textOf(json, 'description');
  List<String> get specialties =>
      (json['specialties'] as List? ?? []).cast<String>();
  List<String> get postalCodes =>
      (json['postal_codes'] as List? ?? []).cast<String>();
  String get source => textOf(json, 'source', 'estimoto');
  String get sourceId => textOf(json, 'source_id', id);
  ProviderMedia? get media => ProviderMedia.fromJson(
    json['media'],
    providerSource: source,
    providerSourceId: sourceId,
    mediaIdentity: json['media_identity'],
  );
  bool get independent => source != 'estimoto';
  List<String> get requestModes => independent || !acceptingRequests
      ? []
      : json.containsKey('request_modes')
      ? (json['request_modes'] as List? ?? [])
            .whereType<String>()
            .where((s) => ['shop_visit', 'mobile'].contains(s))
            .toList()
      : [if (kind == 'shop') 'shop_visit', if (mobileService) 'mobile'];
  double? get distanceMiles => (json['distance_miles'] as num?)?.toDouble();
  bool get mobileService => json['mobile_service'] == true;
  bool get acceptingRequests => json['accepting_requests'] == true;
  bool matches({
    String? specialty,
    String postalCode = '',
    bool mobileOnly = false,
  }) =>
      acceptingRequests &&
      (specialty == null || specialties.contains(specialty)) &&
      (postalCode.isEmpty || postalCodes.contains(postalCode.trim())) &&
      (!mobileOnly || mobileService);
}

class ServiceRequest {
  ServiceRequest.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get vehicleId => textOf(json, 'vehicle_id');
  String get providerId => textOf(json, 'provider_id');
  String get specialty => textOf(json, 'specialty', 'pdr');
  String get description => textOf(json, 'description');
  String get preferredTime => textOf(json, 'preferred_time');
  String get status => textOf(json, 'status', 'requested');
  String get deliveryStatus => textOf(json, 'delivery_status', 'queued');
  List<Json> get events => rowsOf(json, 'events');
  bool get canCancel => status == 'requested' || status == 'accepted';
  String get statusLabel => switch (status) {
    'requested' => 'Waiting for a response',
    'accepted' => 'Request accepted',
    'scheduled' => 'Scheduled',
    'declined' => 'Provider unavailable',
    'cancelled' => 'Cancelled',
    'completed' => 'Completed',
    _ => 'Status unavailable',
  };
  String get deliveryLabel => switch (deliveryStatus) {
    'queued' => 'Waiting to send',
    'delivered' => 'Delivered to provider',
    'failed' => 'Could not deliver',
    'local_preview' => 'Demo request · stays in this preview',
    'cancelled' => 'Delivery cancelled',
    _ => 'Delivery status unavailable',
  };
}

class CustomerEstimate {
  CustomerEstimate.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get vehicleId => textOf(json, 'vehicle_id');
  String get discipline => textOf(json, 'discipline', 'pdr');
  String get status => textOf(json, 'status', 'draft');
  String get description => textOf(json, 'description');
  String get providerName => textOf(json, 'provider_name');
  int? get amountCents => (json['amount_cents'] as num?)?.toInt();
  List<Json> get photos => rowsOf(json, 'photos');
  String get statusLabel => switch (status) {
    'draft' => 'Draft',
    'submitted' => 'Submitted',
    'reviewing' => 'Being reviewed',
    'ready' => 'Ready to review',
    'approved' => 'Approved',
    _ => 'Update pending',
  };
}

class CustomerRepair {
  CustomerRepair.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get vehicleId => textOf(json, 'vehicle_id');
  String get title => textOf(json, 'title', 'Your repair');
  String get providerName => textOf(json, 'provider_name');
  String get status => textOf(json, 'status');
  String get updatedAt => textOf(json, 'updated_at');
  String get estimatedCompletion => textOf(json, 'estimated_completion');
  List<Json> get stages => rowsOf(json, 'stages');
}

class ServiceReminder {
  ServiceReminder.fromJson(this.json);
  final Json json;
  String get id => textOf(json, 'id');
  String get vehicleId => textOf(json, 'vehicle_id');
  String get title => textOf(json, 'title');
  String get dueDate => textOf(json, 'due_date');
  int? get dueMileage => (json['due_mileage'] as num?)?.toInt();
  bool get completed => json['completed'] == true;
}

class Capabilities {
  Capabilities.fromJson(this.json);
  final Json json;
  bool get demo => json['demo'] == true;
  bool get liveRequests => json['live_requests'] == true;
  bool get liveEstimates => json['live_estimates'] == true;
  bool get carfax => json['carfax'] == true;
}

class PlusSnapshot {
  PlusSnapshot.fromJson(Json json)
    : profile = CustomerProfile.fromJson(
        Map<String, dynamic>.from(json['profile'] as Map? ?? {}),
      ),
      vehicles = rowsOf(json, 'vehicles').map(Vehicle.fromJson).toList(),
      providers = rowsOf(
        json,
        'providers',
      ).map(ProviderProfile.fromJson).toList(),
      estimates = rowsOf(
        json,
        'estimates',
      ).map(CustomerEstimate.fromJson).toList(),
      repairs = rowsOf(json, 'repairs').map(CustomerRepair.fromJson).toList(),
      requests = rowsOf(json, 'requests').map(ServiceRequest.fromJson).toList(),
      reminders = rowsOf(
        json,
        'reminders',
      ).map(ServiceReminder.fromJson).toList(),
      capabilities = Capabilities.fromJson(
        Map<String, dynamic>.from(json['capabilities'] as Map? ?? {}),
      ),
      unreadNotifications = intOf(json, 'unread_notifications'),
      raw = json;
  final CustomerProfile profile;
  final int unreadNotifications;

  /// The server document this snapshot was built from, kept for the
  /// last-known-data cache.
  final Json raw;
  final List<Vehicle> vehicles;
  final List<ProviderProfile> providers;
  final List<CustomerEstimate> estimates;
  final List<CustomerRepair> repairs;
  final List<ServiceRequest> requests;
  final List<ServiceReminder> reminders;
  final Capabilities capabilities;
  Vehicle? vehicle(String id) => vehicles.where((v) => v.id == id).firstOrNull;
  ProviderProfile? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

class AssistantAnswer {
  AssistantAnswer.fromJson(Json json)
    : reply = textOf(json, 'reply'),
      intent = textOf(json, 'intent', 'advice'),
      specialty = json['specialty'] as String?,
      providers = rowsOf(
        json,
        'providers',
      ).map(ProviderProfile.fromJson).toList(),
      videos = rowsOf(json, 'videos'),
      discovery = json['discovery'] is Map
          ? Map<String, dynamic>.from(json['discovery'] as Map)
          : null;
  final String reply;
  final String intent;
  final String? specialty;
  final List<ProviderProfile> providers;
  final List<Json> videos;
  final Json? discovery;
}
