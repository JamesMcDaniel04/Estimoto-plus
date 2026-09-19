import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small per-customer flags such as a dismissed checklist.
///
/// Keys are namespaced per customer so one device shared by two accounts
/// never leaks a preference across them.
abstract class LocalStore {
  Future<String?> read(String customerId, String name);
  Future<void> write(String customerId, String name, String value);
  Future<void> clear(String customerId);
}

class MemoryLocalStore extends LocalStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String customerId, String name) async =>
      _values['$customerId/$name'];
  @override
  Future<void> write(String customerId, String name, String value) async =>
      _values['$customerId/$name'] = value;
  @override
  Future<void> clear(String customerId) async =>
      _values.removeWhere((key, _) => key.startsWith('$customerId/'));
}

class SecureLocalStore extends LocalStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _names = ['getting_started_dismissed'];
  String _key(String customerId, String name) =>
      'estimoto_plus_pref_${base64Url.encode(utf8.encode(customerId))}_$name';
  @override
  Future<String?> read(String customerId, String name) async {
    try {
      return await _storage.read(key: _key(customerId, name));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String customerId, String name, String value) async {
    try {
      await _storage.write(key: _key(customerId, name), value: value);
    } catch (_) {
      // A preference that cannot be kept simply shows again next time.
    }
  }

  @override
  Future<void> clear(String customerId) async {
    for (final name in _names) {
      try {
        await _storage.delete(key: _key(customerId, name));
      } catch (_) {}
    }
  }
}
