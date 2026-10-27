# ADR-003: Politica de sesion y revocacion por dispositivo/global con Supabase

- Estado: Aprobado
- Fecha: 2026-03-23

## Contexto

La app necesita control de sesiones para reducir riesgo ante robo de dispositivo o token filtrado. Supabase maneja autenticacion y refresh rotation, pero la revocacion efectiva debe definirse a nivel de dominio.

## Decision

Se congela una politica dual de revocacion:

1. Revocacion por dispositivo: cada login registra una sesion de dispositivo en tabla de dominio (`device_sessions`) con `user_id`, `device_id`, `session_ref`, `issued_at`, `revoked_at`.
2. Revocacion global: se guarda `revoke_all_after` por usuario; cualquier sesion emitida antes de esa marca queda invalida.
3. Validacion en cada operacion sensible: RLS/RPC compara claims JWT (`sub`, `iat`, y `session_id` o `session_ref`) contra estado de revocacion.
4. Logout de dispositivo actual: revoca solo su `session_ref`.
5. Logout global (compromiso): actualiza `revoke_all_after=now()` y fuerza reautenticacion de todos los dispositivos.
6. Acceso offline: permitido solo para datos ya cifrados locales; cualquier sync/escritura remota requiere sesion vigente.

## Alternativas consideradas

- Confiar solo en expiracion natural de JWT: ventana de riesgo alta post-incidente.
- Revocacion solo global: simple pero mala UX cuando solo un dispositivo esta comprometido.
- Revocacion solo por dispositivo: no cubre escenarios de exfiltracion amplia de tokens.

## Consecuencias / tradeoffs

- Seguridad: mejor capacidad de respuesta ante incidente real.
- Complejidad: aumenta logica de validacion en backend (RLS/RPC/Edge).
- Operacion: requiere limpieza de sesiones historicas y observabilidad de rechazos por revocacion.
- UX: usuarios pueden verse forzados a relogin tras revocacion global.

## Criterios de aceptacion verificables

- Revocar un dispositivo invalida sus operaciones remotas sin afectar otros dispositivos activos.
- Revocacion global invalida toda sesion con `iat < revoke_all_after`.
- Un token valido criptograficamente pero revocado es rechazado por capa de autorizacion.
- Tras revocacion, el cliente muestra flujo de reautenticacion antes de sincronizar.

## Implementacion por lotes

- Batch R1: definir tablas/politicas (`device_sessions`, `user_security`) y reglas RLS base.
- Batch R2: implementar endpoints/RPC de revocacion por dispositivo y global.
- Batch R3: integrar cliente Flutter (logout selectivo/global, manejo de 401/403 y re-login guiado).
