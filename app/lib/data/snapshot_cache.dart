import 'dart:convert';
import '../domain/models.dart';
import 'snapshot_cache_unsupported.dart'
    if (dart.library.io) 'snapshot_cache_native.dart';

/// Last-known account data so the app can open offline.
///
/// The document is the server's own bootstrap response, kept in the app's
/// private support folder on native builds and only in memory on the web,
/// mirroring how sessions are stored. It is removed on sign-out and when the
/// account is deleted.
abstract class SnapshotCache {
  Future<CachedSnapshot?> read(String customerId);
  Future<void> write(String customerId, Json document);
  Future<void> clear(String customerId);

  /// The platform default: a private file on native builds, memory on web.
  static SnapshotCache platform() => createSnapshotCache();
}

class CachedSnapshot {
  CachedSnapshot(this.document, this.savedAt);
  factory CachedSnapshot.fromJson(Json value) => CachedSnapshot(
    Map<String, dynamic>.from(value['document'] as Map),
    DateTime.parse(value['saved_at'] as String),
  );
  final Json document;
  final DateTime savedAt;
  Json toJson() => {
    'saved_at': savedAt.toUtc().toIso8601String(),
    'document': document,
  };
}

class MemorySnapshotCache extends SnapshotCache {
  final _values = <String, String>{};
  @override
  Future<CachedSnapshot?> read(String customerId) async {
    final raw = _values[customerId];
    return raw == null
        ? null
        : CachedSnapshot.fromJson(jsonDecode(raw) as Json);
  }

  @override
  Future<void> write(String customerId, Json document) async =>
      _values[customerId] = jsonEncode(
        CachedSnapshot(document, DateTime.now()).toJson(),
      );
  @override
  Future<void> clear(String customerId) async => _values.remove(customerId);
}
