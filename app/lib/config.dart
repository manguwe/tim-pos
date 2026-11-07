/// Build-time settings. Pass them when building, so nothing secret or shop-specific is in the code:
///
///   flutter build apk --release \
///     --dart-define=TIMPOS_SERVER_URL=https://pos.yourdomain.com \
///     --dart-define=TIMPOS_LICENCE_PUBLIC_KEY=<output of: npm run -s cli public-key --raw>
const String kServerUrl = String.fromEnvironment('TIMPOS_SERVER_URL', defaultValue: 'https://pos.example.com');

/// The 32-byte Ed25519 public key (base64url) that licence tokens are checked against.
/// It is public by design. The matching private key never leaves the server.
const String kLicencePublicKey = String.fromEnvironment('TIMPOS_LICENCE_PUBLIC_KEY', defaultValue: '');

const String kAppVersion = '1.0.0';
const int kBuildNumber = 1;
