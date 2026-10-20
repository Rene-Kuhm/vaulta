# Arquitectura - ADR

Este directorio documenta decisiones de arquitectura para destrabar la implementacion E2E con Supabase sin tocar la logica funcional de Flutter.

- [ADR-001: Derivacion de claves y blob cifrado v2](./ADR-001-crypto.md)
- [ADR-002: Modelo de sync con versionado, CAS e idempotencia](./ADR-002-sync.md)
- [ADR-003: Politica de sesion y revocacion con Supabase](./ADR-003-session-revocation.md)
- [ADR-004: Roadmap de la capa `lib/core/sync/`](./ADR-004-roadmap-sync.md)
- [ADR-005: Hygiene de repositorio, lints y cobertura](./ADR-005-repo-hygiene.md)

Estado inicial del pack: aprobado para implementacion por lotes.

## Otros documentos de arquitectura

- [CRYPTO.md](./CRYPTO.md) — entry point para un audit externo de criptografia. Indice de fuentes, contrato criptografico, y lista de preguntas para el auditor.
- [../security/hardening-status.md](../security/hardening-status.md) — estado de cada control de seguridad (Shipped / In progress / Planned) con evidencia `archivo:linea`. En ingles.
- [THREAT_MODEL.md](./THREAT_MODEL.md) — modelo de amenaza honesto: que defendemos, que NO defendemos, y los riesgos residuales que el usuario acepta al elegir Vaulta.
