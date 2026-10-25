/// Single export point for APIs that are part of the sync layer's
/// internal contract. Files outside `lib/core/sync/` should import
/// from this barrel instead of the individual files. The wrapped
/// declarations are intended for backend adapters only; features
/// should depend on the higher-level sync APIs in
/// `device_registration_service.dart`.
///
/// See `docs/adr/0004-sync-layer-roadmap.md` for the rationale
/// (intent: discourage `lib/features/` from coupling to backend
/// details).
library;

export 'device_registration_repository.dart';
export 'device_session_revocation_service.dart';
