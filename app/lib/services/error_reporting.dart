import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// First-party crash and error reporting.
///
/// Uncaught Flutter and platform errors are posted, without any customer
/// identity or token, to the API's anonymous `/v1/client-errors` route. The
/// reporter keeps only the error type, a bounded message and the first stack
/// frames, sends each distinct error once per session and never more than a
/// small number of reports overall, so a crash loop cannot flood the server.
class ClientErrorReporter {
  ClientErrorReporter({
    required Uri apiOrigin,
    required this.platform,
    required this.appVersion,
    required this.buildNumber,
    this.sourceSha = '',
    http.Client? client,
    this.maxReports = 20,
  }) : _endpoint = apiOrigin.resolve('/v1/client-errors'),
       _client = client ?? http.Client();
  final Uri _endpoint;
  final http.Client _client;
  final String platform, appVersion, buildNumber, sourceSha;
  final int maxReports;
  final _seen = <String>{};
  int _sent = 0;
  int get sent => _sent;

  /// Installs the global handlers. Existing handlers keep running so debug
  /// output and the red error screen behave as before.
  void install() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutter?.call(details);
      unawaited(report(details.exception, details.stack, context: 'flutter'));
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(report(error, stack, context: 'platform'));
      return previousPlatform?.call(error, stack) ?? true;
    };
  }

  Map<String, String> payload(
    Object error,
    StackTrace? stack, {
    String context = '',
  }) {
    final kind = error.runtimeType.toString();
    final message = _clip(error.toString(), 500);
    final frames = (stack?.toString() ?? '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(12)
        .join('\n');
    return {
      'platform': platform,
      'app_version': appVersion,
      'build_number': buildNumber,
      'source_sha': sourceSha,
      'kind': _clip(context.isEmpty ? kind : '$kind ($context)', 100),
      'message': message,
      'stack': _clip(frames, 4000),
    };
  }

  Future<bool> report(
    Object error,
    StackTrace? stack, {
    String context = '',
  }) async {
    final body = payload(error, stack, context: context);
    final key =
        '${body['kind']}|${body['message']}|${body['stack']!.split('\n').take(3).join()}';
    if (_sent >= maxReports || !_seen.add(key)) return false;
    _sent++;
    try {
      final response = await _client
          .post(
            _endpoint,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 202;
    } catch (_) {
      return false; // Reporting must never itself surface as an error.
    }
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}
