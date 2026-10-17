import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'data/api_repository.dart';
import 'data/auth_storage.dart';
import 'data/customer_auth.dart';
import 'data/pending_request_store.dart';
import 'data/demo_repository.dart';
import 'data/repository.dart';
import 'screens/welcome_screen.dart';
import 'state/plus_controller.dart';
import 'theme.dart';

const apiUrl = String.fromEnvironment('PLUS_API_URL');
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const autoDemo = bool.fromEnvironment('PLUS_DEMO', defaultValue: false);
const devToken = String.fromEnvironment('PLUS_DEV_TOKEN');
bool get authConfigured =>
    supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty && apiUrl.isNotEmpty;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? setupError;
  if (authConfigured) {
    try {
      final uri = Uri.parse(supabaseUrl);
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException();
      }
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseKey,
        authOptions: FlutterAuthClientOptions(
          localStorage: kIsWeb
              ? const EmptyLocalStorage()
              : const SecureAuthStorage(),
        ),
      );
    } catch (_) {
      setupError =
          'Sign-in could not start. You can try again later or explore the demo.';
    }
  }
  runApp(
    PlusLauncher(
      setupError: setupError,
      auth: authConfigured && setupError == null
          ? SupabaseCustomerAuth()
          : null,
    ),
  );
}

class PlusLauncher extends StatefulWidget {
  const PlusLauncher({
    super.key,
    this.setupError,
    this.auth,
    this.repositoryFactory,
    this.pendingStore,
  });
  final String? setupError;
  final CustomerAuth? auth;
  final PlusRepository Function(Future<String?> Function() token)?
  repositoryFactory;
  final PendingRequestStore? pendingStore;
  @override
  State<PlusLauncher> createState() => _PlusLauncherState();
}

class _PlusLauncherState extends State<PlusLauncher> {
  PlusController? controller;
  final _pendingExits = <PlusController>{};
  StreamSubscription<String?>? authSubscription;
  String? error, liveUserId;
  @override
  void initState() {
    super.initState();
    error = widget.setupError;
    if (autoDemo) {
      controller = PlusController(DemoPlusRepository());
    } else if (!kReleaseMode && devToken.isNotEmpty && apiUrl.isNotEmpty) {
      try {
        controller = PlusController(
          ApiPlusRepository(baseUrl: apiUrl, token: () async => devToken),
          pendingStore: widget.pendingStore ?? SecurePendingRequestStore(),
        );
      } catch (_) {
        error =
            'The local API configuration could not start. Check the server address.';
      }
    }
    final auth = widget.auth;
    if (auth != null && widget.setupError == null) {
      authSubscription = auth.identities.listen(
        _identityChanged,
        onError: (Object _, StackTrace _) {
          if (!mounted || controller?.repository.isDemo == true) return;
          setState(
            () => error =
                'Your sign-in could not refresh. Check your connection or sign in again.',
          );
          controller?.reportSessionError();
        },
      );
      if (auth.userId != null && controller == null) _openLive(auth.userId!);
    }
  }

  void _identityChanged(String? userId) {
    if (!mounted || controller?.repository.isDemo == true) return;
    if (userId == null) {
      _clearController();
    } else if (controller == null || liveUserId != userId) {
      _openLive(userId);
    }
  }

  void _openLive(String userId) {
    final previous = controller;
    previous?.invalidateSession();
    // Drop all previous customer data before exposing another customer's token.
    setState(() {
      controller = null;
      liveUserId = null;
      error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    try {
      Future<String?> boundToken() async {
        final auth = widget.auth!;
        if (auth.userId != userId) {
          throw const PlusApiException(
            'Your account changed. Please sign in again.',
            401,
          );
        }
        final value = await auth.accessToken();
        if (auth.userId != userId) {
          throw const PlusApiException(
            'Your account changed. Please sign in again.',
            401,
          );
        }
        return value;
      }

      final repository =
          widget.repositoryFactory?.call(boundToken) ??
          ApiPlusRepository(baseUrl: apiUrl, token: boundToken);
      setState(() {
        liveUserId = userId;
        controller = PlusController(
          repository,
          pendingStore: widget.pendingStore ?? SecurePendingRequestStore(),
        );
      });
    } catch (_) {
      setState(
        () => error =
            'Sign-in could not start. Check your connection and try again.',
      );
    }
  }

  void _clearController() {
    final previous = controller;
    previous?.invalidateSession();
    if (mounted) {
      setState(() {
        controller = null;
        liveUserId = null;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
  }

  Future<void> _exit(
    PlusController originalController,
    String? originalUserId,
  ) async {
    bool current() =>
        mounted &&
        identical(controller, originalController) &&
        liveUserId == originalUserId;
    if (!current() || !_pendingExits.add(originalController)) return;
    final auth = widget.auth;
    try {
      if (!originalController.repository.isDemo && auth != null) {
        // An identity event can still be queued when the old button is tapped.
        if (auth.userId != originalUserId) return;
        try {
          await auth.signOut();
        } catch (_) {
          if (current() &&
              identical(widget.auth, auth) &&
              auth.userId == originalUserId) {
            setState(
              () => error = 'Sign-out could not complete. Please try again.',
            );
            originalController.reportSessionError();
          }
          return;
        }
        if (!identical(widget.auth, auth) ||
            (auth.userId != null && auth.userId != originalUserId)) {
          return;
        }
      }
      if (current()) _clearController();
    } finally {
      // Account B may have its own exit pending while account A finishes.
      _pendingExits.remove(originalController);
    }
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentController = controller;
    final currentUserId = liveUserId;
    if (currentController != null) {
      return EstimotoPlusApp(
        key: ObjectKey(currentController),
        controller: currentController,
        onExit: () => _exit(currentController, currentUserId),
      );
    }
    return MaterialApp(
      title: 'Estimoto +',
      debugShowCheckedModeBanner: false,
      theme: plusTheme(),
      home: WelcomeScreen(
        authAvailable: widget.auth != null && widget.setupError == null,
        setupError: error,
        onDemo: () =>
            setState(() => controller = PlusController(DemoPlusRepository())),
      ),
    );
  }
}
