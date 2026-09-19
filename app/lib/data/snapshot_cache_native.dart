import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import 'snapshot_cache.dart';

SnapshotCache createSnapshotCache() => FileSnapshotCache();

/// One private file per customer under the app support directory. File
/// names are hashes so account identifiers never appear in paths.
class FileSnapshotCache extends SnapshotCache {
  FileSnapshotCache({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _supportDirectory;

  Future<File> _file(String customerId) async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/snapshot_cache_v1');
    await directory.create(recursive: true);
    final name = sha256.convert(utf8.encode(customerId)).toString();
    return File('${directory.path}/$name.json');
  }

  @override
  Future<CachedSnapshot?> read(String customerId) async {
    try {
      final file = await _file(customerId);
      if (!await file.exists()) return null;
      return CachedSnapshot.fromJson(
        jsonDecode(await file.readAsString()) as Json,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String customerId, Json document) async {
    try {
      final file = await _file(customerId);
      final staging = File('${file.path}.tmp');
      await staging.writeAsString(
        jsonEncode(CachedSnapshot(document, DateTime.now()).toJson()),
        flush: true,
      );
      await staging.rename(file.path);
    } catch (_) {
      // Offline reads simply fall back to the previous copy, if any.
    }
  }

  @override
  Future<void> clear(String customerId) async {
    try {
      final file = await _file(customerId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
