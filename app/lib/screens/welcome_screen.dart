import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../brand_assets.dart';
import '../plus_links.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/vehicle_illustration.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.authAvailable,
    required this.onDemo,
    this.setupError,
  });
  final bool authAvailable;
  final VoidCallback onDemo;
  final String? setupError;
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final email = TextEditingController();
  final code = TextEditingController();
  bool sent = false, existingCode = false, busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> signIn() async {
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.text.trim())) {
      setState(
        () => error = email.text.trim().isEmpty
            ? 'Enter your email address.'
            : 'Enter a valid email address, such as name@example.com.',
      );
      return;
    }
    if (sent && !RegExp(r'^[0-9]{8}$').hasMatch(code.text.trim())) {
      setState(() => error = 'Enter the 8-digit code from your email.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final auth = Supabase.instance.client.auth;
      if (!sent) {
        await auth.signInWithOtp(
          email: email.text.trim(),
          emailRedirectTo: kIsWeb
              ? Uri.base.origin
              : 'io.estimoto.plus://login-callback/',
        );
        if (mounted) {
          setState(() {
            sent = true;
            existingCode = false;
          });
        }
      } else {
        await auth.verifyOTP(
          email: email.text.trim(),
          token: code.text.trim(),
          type: OtpType.email,
        );
      }
    } on AuthException {
      if (mounted) {
        setState(
          () => error = sent
              ? 'That code could not be verified. Check the code and try again.'
              : 'Could not send a sign-in email. Please wait a moment and try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not connect. Please check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PageBody(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                plusIconAsset,
                width: 72,
                height: 72,
                excludeFromSemantics: true,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // The wordmark shrinks instead of overflowing at large text sizes.
          const Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Estimoto +',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.7,
                ),
              ),
            ),
          ),
          const SizedBox(height: 42),
          // The headline wraps freely but caps its scale so single words fit.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.6,
            child: const Text(
              'A better home\nfor your car care.',
              style: TextStyle(
                fontSize: 38,
                height: 1.13,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.3,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Keep your vehicles together. Understand your repairs. Find the right person to help.',
            style: TextStyle(fontSize: 17, height: 1.5, color: context.plus.muted),
          ),
          const SizedBox(height: 28),
          Semantics(
            label: 'Illustration of a car',
            image: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: context.plus.navyCard,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const VehicleIllustration(),
            ),
          ),
          const SizedBox(height: 28),
          if (widget.authAvailable) ...[
            TextField(
              controller: email,
              enabled: !busy && (!sent || existingCode),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email address'),
            ),
            if (sent) ...[
              const SizedBox(height: 16),
              Text(
                existingCode
                    ? 'Enter the 8-digit code you already received.'
                    : 'Check your email. Open the sign-in link or enter the code below.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                enabled: !busy,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(labelText: 'Email code'),
              ),
            ],
            const SizedBox(height: 16),
            BusyButton(
              busy: busy,
              label: sent ? 'Verify & sign in' : 'Continue with email',
              icon: Icons.mail_outline,
              onPressed: signIn,
            ),
            if (!sent)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        sent = true;
                        existingCode = true;
                        error = null;
                      }),
                child: const Text('I already have a code'),
              ),
            if (sent)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        sent = false;
                        existingCode = false;
                        code.clear();
                        error = null;
                      }),
                child: const Text('Use another email'),
              ),
          ] else
            Text(
              'Early access is taking shape. Explore the customer experience with sample vehicles and providers.',
              style: TextStyle(color: context.plus.muted),
            ),
          if (error != null || widget.setupError != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                error ?? widget.setupError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: busy ? null : widget.onDemo,
              child: const Text('Explore demo'),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Demo activity stays in the preview. No shops or technicians are contacted.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.plus.muted),
          ),
          const SizedBox(height: 8),
          Text(
            'By continuing you agree to our terms and privacy policy.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.plus.muted),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: [
              TextButton(
                onPressed: () => openExternal(context, termsOfUseUrl),
                child: const Text('Terms of use'),
              ),
              TextButton(
                onPressed: () => openExternal(context, privacyPolicyUrl),
                child: const Text('Privacy policy'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
