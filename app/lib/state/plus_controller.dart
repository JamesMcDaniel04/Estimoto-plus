import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../data/local_store.dart';
import '../data/repository.dart';
import '../data/pending_request_store.dart';
import '../data/snapshot_cache.dart';
import '../domain/models.dart';

class ChatEntry {
  ChatEntry.user(this.text)
    : answer = null,
      vehicleId = null,
      postalCode = '',
      mobileOnly = false,
      prompt = '';
  ChatEntry.assistant(
    this.answer, {
    this.vehicleId,
    this.postalCode = '',
    this.mobileOnly = false,
    this.prompt = '',
  }) : text = answer!.reply;
  final String? vehicleId;
  final String postalCode, prompt;
  final bool mobileOnly;
  final String text;
  final AssistantAnswer? answer;
  bool get isUser => answer == null;
}

class PlusController extends ChangeNotifier {
  PlusController(
    this.repository, {
    PendingRequestStore? pendingStore,
    SnapshotCache? snapshotCache,
    LocalStore? localStore,
    this.cacheOwnerId,
  }) : pendingStore = pendingStore ?? MemoryPendingRequestStore(),
       snapshotCache = snapshotCache ?? MemorySnapshotCache(),
       localStore = localStore ?? MemoryLocalStore();
  final PendingRequestStore pendingStore;
  final SnapshotCache snapshotCache;
  final LocalStore localStore;

  /// Identity the last-known-data cache is filed under. Null (demo, dev
  /// tokens) disables caching.
  final String? cacheOwnerId;

  /// When the current snapshot came from the cache because the server could
  /// not be reached, the time that copy was saved.
  DateTime? offlineSince;
  bool get isOffline => offlineSince != null;
  int get unreadNotifications => snapshot?.unreadNotifications ?? 0;
  PendingRequest? pendingRequest;
  final _pendingEstimates = <String, PendingRequest>{};
  final _sendingEstimates = <String>{};
  PendingRequest? pendingEstimate(String id) => _pendingEstimates[id];
  bool isCurrentCustomer(String id) =>
      !_disposed && _sessionActive && snapshot?.profile.id == id;
  String _estimateStorageKey(String customerId, String id) =>
      'estimate:$customerId:$id';
  int _refreshGeneration = 0;
  bool _sendingRequest = false;
  final PlusRepository repository;
  PlusSnapshot? snapshot;
  bool loading = false;
  bool asking = false;
  String? error;
  String? selectedVehicleId;
  int tab = 0;
  int historyRevision = 0;
  void historyChanged() {
    historyRevision++;
    _notify();
  }

  String discipline = 'pdr';
  final List<ChatEntry> messages = [];
  bool _disposed = false;
  bool _sessionActive = true;
  Vehicle? get selectedVehicle =>
      snapshot?.vehicle(selectedVehicleId ?? '') ??
      snapshot?.vehicles.firstOrNull;
  bool get isDemo => repository.isDemo || snapshot?.capabilities.demo == true;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearConversation() {
    messages.clear();
    _notify();
  }

  void selectTab(int value) {
    tab = value;
    _notify();
  }

  void selectVehicle(String value) {
    selectedVehicleId = value;
    _notify();
  }

  void selectDiscipline(String value) {
    discipline = value;
    _notify();
  }

  Future<void> refresh({bool quiet = false}) async {
    final generation = ++_refreshGeneration;
    loading = !quiet;
    error = null;
    _notify();
    try {
      final next = await repository.bootstrap();
      final pending = await pendingStore.read(next.profile.id);
      final estimates = <String, PendingRequest>{};
      for (final estimate in next.estimates) {
        final saved = await pendingStore.read(
          _estimateStorageKey(next.profile.id, estimate.id),
        );
        if (saved != null) estimates[estimate.id] = saved;
      }
      if (_disposed || generation != _refreshGeneration) return;
      snapshot = next;
      offlineSince = null;
      if (cacheOwnerId != null && !repository.isDemo) {
        // Never hold the UI on device storage; a lost write only means the
        // previous copy is what opens offline next time.
        unawaited(
          snapshotCache.write(cacheOwnerId!, next.raw).catchError((_) {}),
        );
      }
      // Knowledge is fetched separately from bootstrap. A successful refresh
      // must also invalidate receipt details and costs changed on the server.
      historyRevision++;
      pendingRequest = pending;
      _pendingEstimates
        ..clear()
        ..addAll(estimates);
      if (!snapshot!.vehicles.any((v) => v.id == selectedVehicleId)) {
        selectedVehicleId = snapshot!.vehicles.firstOrNull?.id;
      }
    } catch (e) {
      if (!_disposed && generation == _refreshGeneration) {
        error = readableError(e);
        if (snapshot == null && cacheOwnerId != null && !repository.isDemo) {
          await _restoreCachedSnapshot(generation);
        }
      }
    } finally {
      if (!_disposed && generation == _refreshGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  /// Opens the last saved copy of the account when the server is unreachable.
  /// Session errors (401) never restore data: a signed-out customer must not
  /// see cached records.
  Future<void> _restoreCachedSnapshot(int generation) async {
    final failure = error;
    if (failure == null || failure.contains('sign in')) return;
    final cached = await snapshotCache
        .read(cacheOwnerId!)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (_disposed || generation != _refreshGeneration || cached == null) return;
    try {
      snapshot = PlusSnapshot.fromJson(cached.document);
    } catch (_) {
      return;
    }
    offlineSince = cached.savedAt;
    historyRevision++;
    if (!snapshot!.vehicles.any((v) => v.id == selectedVehicleId)) {
      selectedVehicleId = snapshot!.vehicles.firstOrNull?.id;
    }
  }

  /// Forgets everything kept on this device for the signed-in customer.
  Future<void> clearDeviceData() async {
    final owner = cacheOwnerId ?? snapshot?.profile.id;
    if (owner == null) return;
    await snapshotCache.clear(owner);
    await localStore.clear(owner);
  }

  /// Marks the feed read on the server and refreshes the badge quietly.
  Future<Json> markNotificationsRead({
    List<String> ids = const [],
    bool all = false,
  }) async {
    final result = await repository.markNotificationsRead(ids: ids, all: all);
    if (!repository.isDemo) {
      await refresh(quiet: true);
    } else if (snapshot != null) {
      snapshot = PlusSnapshot.fromJson({
        ...snapshot!.raw,
        'unread_notifications': result['unread'] ?? 0,
      });
      _notify();
    }
    return result;
  }

  /// Revoke callback authority immediately, before Flutter disposes the old tree.
  void invalidateSession() {
    _sessionActive = false;
    ++_refreshGeneration;
    _notify();
  }

  /// Fetches the customer's complete data as JSON.
  Future<Json> exportAccount() => repository.exportAccount();

  /// Erases the account on the server and ends this session's authority.
  /// The launcher signs out and returns to Welcome once this completes.
  Future<Json> deleteAccount() async {
    final result = await repository.deleteAccount();
    accountDeleted = true;
    invalidateSession();
    return result;
  }

  bool accountDeleted = false;

  void reportSessionError() {
    error =
        'Your sign-in could not refresh. Check your connection or sign in again.';
    _notify();
  }

  Future<Json> sendRequest(
    Json body,
    ProviderProfile provider, {
    String? reviewTimeZone,
  }) async {
    final customerId = snapshot?.profile.id;
    if (customerId == null || !isCurrentCustomer(customerId)) {
      throw const PlusApiException('Please sign in again to continue.', 401);
    }
    void requireOwner() {
      if (!isCurrentCustomer(customerId)) {
        throw const PlusApiException(
          'Your account changed. Please sign in again.',
          401,
        );
      }
    }

    if (_sendingRequest) {
      throw const PlusApiException('Your request is already being sent.');
    }
    final frozenBody = freezeJson(body);
    _sendingRequest = true;
    ++_refreshGeneration;
    loading = false;
    try {
      final saved = pendingRequest ?? await pendingStore.read(customerId);
      requireOwner();
      if (saved != null &&
          canonicalJson(saved.body) != canonicalJson(frozenBody)) {
        pendingRequest = saved;
        throw const PlusApiException(
          'Confirm the outcome of your previous request before changing its details.',
        );
      }
      final attempt =
          saved ??
          PendingRequest(
            body: frozenBody,
            key: requestKey(),
            provider: provider,
            reviewTimeZone: reviewTimeZone,
          );
      await pendingStore.write(customerId, attempt);
      requireOwner();
      pendingRequest = attempt;
      _notify();
      final result = await repository.createRequest(attempt.body, attempt.key);
      requireOwner();
      await pendingStore.clear(customerId);
      requireOwner();
      pendingRequest = null;
      return result;
    } on PlusApiException catch (error) {
      // Definitive rejection permits new choices; ambiguous outcomes retain exact replay.
      if (isCurrentCustomer(customerId) &&
          ([400, 403, 404, 422].contains(error.statusCode) ||
              (error.statusCode == 409 &&
                  error.code == 'request_not_created'))) {
        await pendingStore.clear(customerId);
        requireOwner();
        pendingRequest = null;
      }
      rethrow;
    } finally {
      _sendingRequest = false;
      if (isCurrentCustomer(customerId)) _notify();
    }
  }

  Future<Json> saveVehicle(Json body, {String? id}) async {
    final result = await repository.saveVehicle(body, id: id);
    selectedVehicleId = result['id'] as String;
    await refresh();
    return result;
  }

  Future<Json> submitEstimate(
    String id,
    Json body,
    ProviderProfile provider,
  ) async {
    final customerId = snapshot?.profile.id;
    if (customerId == null || !isCurrentCustomer(customerId)) {
      throw const PlusApiException('Please sign in again to continue.', 401);
    }
    if (!_sendingEstimates.add(id)) {
      throw const PlusApiException('This estimate is already being submitted.');
    }
    final storageKey = _estimateStorageKey(customerId, id);
    ++_refreshGeneration;
    loading = false;
    try {
      final saved =
          _pendingEstimates[id] ?? await pendingStore.read(storageKey);
      if (saved != null && !mapEquals(saved.body, body)) {
        _pendingEstimates[id] = saved;
        throw const PlusApiException(
          'Confirm your previous submission before choosing another shop.',
        );
      }
      final attempt =
          saved ??
          PendingRequest(
            body: Map<String, dynamic>.from(body),
            key: 'estimate:$id',
            provider: provider,
          );
      if (attempt.body['share_contact'] != true ||
          attempt.body['provider_id'] != provider.id) {
        throw const PlusApiException(
          'Review your shop and sharing choice before submitting.',
          422,
        );
      }
      await pendingStore.write(storageKey, attempt);
      _pendingEstimates[id] = attempt;
      _notify();
      if (!isCurrentCustomer(customerId)) {
        throw const PlusApiException(
          'Your account changed. Please sign in again.',
          401,
        );
      }
      final result = await repository.submitEstimate(
        id,
        attempt.body,
        attempt.key,
      );
      await pendingStore.clear(storageKey);
      _pendingEstimates.remove(id);
      return result;
    } on PlusApiException catch (error) {
      if ([400, 403, 404, 422].contains(error.statusCode)) {
        await pendingStore.clear(storageKey);
        _pendingEstimates.remove(id);
      }
      rethrow;
    } finally {
      _sendingEstimates.remove(id);
      _notify();
    }
  }

  Future<void> ask(String message) async {
    final customer = snapshot?.profile.id;
    if (asking ||
        message.trim().isEmpty ||
        customer == null ||
        !isCurrentCustomer(customer)) {
      return;
    }
    final vehicle = selectedVehicle?.id, postal = snapshot!.profile.postalCode;
    final mobile = RegExp(
      r'mobile|come to me|come to my|at my (home|work|house)',
      caseSensitive: false,
    ).hasMatch(message);
    messages.add(ChatEntry.user(message.trim()));
    asking = true;
    _notify();
    try {
      final answer = await repository.askAssistant({
        'message': message.trim(),
        'vehicle_id': vehicle,
        'postal_code': postal,
        'mobile_only': mobile,
      });
      if (!isCurrentCustomer(customer)) return;
      if (selectedVehicle?.id != vehicle ||
          snapshot!.profile.postalCode != postal) {
        messages.add(
          ChatEntry.assistant(
            AssistantAnswer.fromJson({
              'reply':
                  'Your vehicle or service ZIP changed while I was checking. Ask again for the current selection.',
              'intent': 'clarify',
            }),
          ),
        );
        return;
      }
      messages.add(
        ChatEntry.assistant(
          answer,
          vehicleId: vehicle,
          postalCode: postal,
          mobileOnly: mobile,
          prompt: message.trim(),
        ),
      );
    } catch (e) {
      if (!isCurrentCustomer(customer)) return;
      messages.add(
        ChatEntry.assistant(
          AssistantAnswer.fromJson({
            'reply': readableError(e),
            'intent': 'advice',
          }),
        ),
      );
    } finally {
      asking = false;
      _notify();
    }
  }

  static String requestKey() => base64UrlEncode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );
  static String readableError(Object e) => e is PlusApiException
      ? e.message
      : 'We could not complete that action. Please try again.';
  @override
  void dispose() {
    _disposed = true;
    repository.close();
    super.dispose();
  }
}
