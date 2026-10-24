# Vault key cross-device sync (wrapped DEK)

La sync de ítems es inútil entre dispositivos si la DEK por-vault no viaja: cada
ítem se sella con `HKDF-SHA256(DEK, salt, info)`, y la DEK es aleatoria y local.
Esta feature sincroniza la DEK **envuelta** (ya cifrada con la KEK de la master
password) como metadata de vault, para que un segundo dispositivo con la misma
master password reconstruya la misma sesión.

Base: `feat/enterprise-closure` · Verificación: `flutter analyze` + `flutter test`.

## Specs

S1. Existe una tabla `vault_keys` (una fila por usuario) con RLS owner-only y dos
RPC `security invoker`: `rpc_vault_get_key()` (devuelve la fila o vacío) y
`rpc_vault_put_key(p_key_id text, p_record_json text)` (upsert). El `record_json`
es el `MasterPasswordRecord.encode()` completo — la DEK envuelta y el verifier,
que no revelan la master password ni la DEK.

S2. El cliente puede serializar/deserializar la metadata de clave de vault a/desde
el cable, reutilizando `MasterPasswordRecord.encode()`/`decode()` (sin un formato
nuevo). Un record reconstruido pasa `verify()` y `deriveVaultKey()` igual que uno
local.

S3. La lifecycle de sync (re)sincroniza la clave de vault: en `onSessionStarted`
hace pull de la clave remota y, si existe un record local, lo pushea (upsert
idempotente). El push también corre tras `createMasterPassword` y tras un rekey.

S4. Un dispositivo sin record local que firma sesión y encuentra una clave remota
la adopta como record local, de modo que la pantalla de onboarding pasa a ser
"unlock" en lugar de "create". No se pisan records locales existentes.

S5. Verificado end-to-end: en el emulador A se crea un ítem y viaja a `vault_blobs`
como solo ciphertext; en un segundo emulador con el mismo usuario y la misma master
password el ítem aparece tras desbloquear.

## Tasks

- T1: migración `vault_keys` + RPC `rpc_vault_get_key`/`rpc_vault_put_key` + RLS.
- T2: `VaultKeySyncRepository` (puerto) + impl Supabase (get/put).
- T3: `VaultKeySyncService` que reconcilia local↔remoto (pull/adopt + push).
- T4: cablear el service a la lifecycle (`onSessionStarted`) y al alta/rekey.
- T5: `VaultSecurityController.adoptRemoteVaultRecord` + gate que la adopta.
- T6: tests (repo, service, adopción, round-trip) + `flutter analyze` + `flutter test`.
- T7: verificación en dos emuladores (S5) y limpieza.

## Log

L1 (2026-10-23, decisión del usuario): ante la pregunta de cómo distribuir la clave
de vault, eligió «Sincronizar la DEK envuelta» (sync_wrapped_dek): push de la DEK
envuelta —ya cifrada con la KEK de la master password— como blob de metadata de
vault, conservando el modelo cripto actual.

L2 (2026-10-23, S5 verificado en dispositivo): device A creó el ítem «SyncTest» y
pusheó a `vault_blobs` solo ciphertext (key_version 4 + salt) y a `vault_keys` la
DEK envuelta (key_id `tuW1VCEXSUWm1i-n`). Un segundo dispositivo (mismo usuario,
simulado con `pm clear` + re-sign-in) adoptó la clave remota: la pantalla pasó de
onboarding a «Unlock», la master password `masterpass1234` abrió el vault y el ítem
apareció (Vault entries 1, score 70). Confirmado: el mismo DEK se reconstruye en el
segundo dispositivo.

L3 (2026-10-23, gap de UX pendiente): tras el pull, el dashboard no se refresca solo:
un dispositivo recién adoptado muestra «Vault entries 0» hasta un pull-to-refresh o
un reinicio. El ítem sí está descifrado y guardado; solo falta re-leer la lista. Queda
como seguimiento menor, no bloquea S5.
