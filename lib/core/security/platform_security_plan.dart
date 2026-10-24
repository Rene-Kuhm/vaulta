/// Tri-state answer to a capability question.
///
/// A capability question has three honest answers, not two. This used to
/// be a plain `bool` plus a static "what platform is this" guess, so
/// every failed probe, every platform the app had not run on, and every
/// exception thrown while asking the question were flattened into
/// `false`. The security screen then reported "no" for a capability that
/// worked, and the UI had no way to tell "no" apart from "we could not
/// find out".
///
/// [unknown] is a first-class answer here: a security screen that admits
/// ignorance is correct, one that invents a "no" is not. Code that
/// consumes these values must handle all three cases — mapping [unknown]
/// onto [unsupported] reintroduces the bug this type exists to prevent.
enum SecurityCapabilityState {
  /// The platform answered the question, and the answer is yes.
  supported,

  /// The platform answered the question, and the answer is no. This is
  /// the only state that may be rendered as "not available".
  unsupported,

  /// The question could not be answered: the probe threw, the platform
  /// channel is not registered, or the service is not wired on this
  /// build. Never render this as [unsupported].
  unknown;

  /// True when the capability was confirmed available.
  bool get isSupported => this == SecurityCapabilityState.supported;

  /// True when the capability was confirmed unavailable.
  bool get isUnsupported => this == SecurityCapabilityState.unsupported;

  /// True when the state could not be determined.
  bool get isUnknown => this == SecurityCapabilityState.unknown;

  /// Combines two answers for a capability that needs *both* to hold.
  ///
  /// A confirmed "no" wins over a maybe, and a maybe wins over a "yes":
  /// claiming support is only allowed when every input confirmed it.
  static SecurityCapabilityState both(
    SecurityCapabilityState first,
    SecurityCapabilityState second,
  ) {
    if (first.isUnsupported || second.isUnsupported) {
      return SecurityCapabilityState.unsupported;
    }
    if (first.isUnknown || second.isUnknown) {
      return SecurityCapabilityState.unknown;
    }
    return SecurityCapabilityState.supported;
  }
}

/// Snapshot of the security capabilities the current device can offer
/// *right now*, as answered by the services that implement them.
///
/// Built by `VaultSecurityController.probeSecurityPlan`, which asks the
/// same collaborators that perform the operations: the biometric gate,
/// the platform envelope-key provider and secure storage. There is no
/// static "if Android then true" path any more — that is what made the
/// screen disagree with the code it described.
class PlatformSecurityPlan {
  /// Creates a [PlatformSecurityPlan]. Every field is tri-state; see
  /// [SecurityCapabilityState].
  const PlatformSecurityPlan({
    required this.secureStorage,
    required this.biometricUnlock,
    required this.hardwareBackedKeys,
    required this.vaultEncryptionReady,
  });

  /// True when the OS can persist small secrets in a protected store
  /// (Android Keystore, iOS Keychain, Windows Credential Manager, etc.).
  final SecurityCapabilityState secureStorage;

  /// True when the vault DEK can be recovered with a biometric prompt on
  /// this device: a platform-protected envelope key is wired AND the
  /// platform reports the biometric it requires as available.
  final SecurityCapabilityState biometricUnlock;

  /// True when at least one path uses a key the platform holds (e.g. the
  /// Android KeyStore RSA-2048 wrapping key).
  final SecurityCapabilityState hardwareBackedKeys;

  /// True when all the pieces required to encrypt the vault are in
  /// place (Argon2id KDF, AES-GCM crypto service, secure storage).
  final SecurityCapabilityState vaultEncryptionReady;

  /// The pre-probe value: nothing has been asked yet, so nothing is
  /// claimed. The UI renders it as "unknown", never as "not available".
  static const PlatformSecurityPlan unknown = PlatformSecurityPlan(
    secureStorage: SecurityCapabilityState.unknown,
    biometricUnlock: SecurityCapabilityState.unknown,
    hardwareBackedKeys: SecurityCapabilityState.unknown,
    vaultEncryptionReady: SecurityCapabilityState.unknown,
  );
}
