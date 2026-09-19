/// Public pages and contacts published with the Estimoto + web release.
///
/// The API origin also serves the web app and its static legal pages, so the
/// links follow `PLUS_API_URL` and fall back to the production origin for demo
/// builds that have no API configured.
library;

const _configuredOrigin = String.fromEnvironment('PLUS_API_URL');
const productionOrigin = 'https://estimoto-plus-api.fly.dev';
const supportEmail = 'support@estimoto.io';

String get plusPublicOrigin {
  final uri = Uri.tryParse(_configuredOrigin);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty) {
    return productionOrigin;
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
}

String get privacyPolicyUrl => '$plusPublicOrigin/privacy.html';
String get termsOfUseUrl => '$plusPublicOrigin/terms.html';
String get discoveryTermsUrl => '$plusPublicOrigin/discovery-terms.html';
String get discoveryPrivacyUrl => '$plusPublicOrigin/discovery-privacy.html';
