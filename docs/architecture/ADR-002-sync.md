# ADR-002: Modelo de sincronizacion con versionado, CAS, idempotencia y tombstones

- Estado: Aprobado
- Fecha: 2026-03-23
- Ultima actualizacion: 2026-10-20 (enmienda "el payload de item v4 no viaja por el cable")

## Contexto

La sincronizacion E2E con Supabase requiere evitar sobrescrituras silenciosas, duplicados por reintentos y reaparicion de datos borrados. Se necesita un contrato determinista para clientes moviles con conectividad intermitente.

## Decision

Se congela un modelo de sync orientado a consistencia optimista:

1. Versionado por registro: cada secreto tiene `version` monotona creciente por usuario.
2. CAS (Compare-And-Set): update/delete exige `expected_version`; si no coincide, retorna conflicto.
3. Idempotencia por mutacion: cada operacion de escritura via API usa `idempotency_key` (UUID) para deduplicar reintentos.
4. Tombstones: los borrados son logicos (`deleted_at` + `version`) y se sincronizan igual que updates.
5. Upsert controlado: crear/editar usa llaves estables por entidad (`record_id`) y validacion de ownership via RLS.
6. Reconciliacion cliente: pull incremental por `updated_at`/cursor + resolucion de conflicto explicita en cliente.

## Alternativas consideradas

- Last-write-wins sin CAS: simple pero propenso a perdida silenciosa de cambios.
- Bloqueos pesimistas server-side: mayor complejidad y peor UX offline.
- Hard delete inmediato: rompe convergencia multi-dispositivo y recuperacion de estado.

## Consecuencias / tradeoffs

- Confiabilidad: se minimiza corrupcion por carreras y reintentos.
- Complejidad: sube el costo de backend y cliente por manejo de conflictos.
- Almacenamiento: tombstones aumentan volumen hasta politica de purge.
- UX: el usuario puede ver conflictos explicitos en escenarios concurrentes.

## Criterios de aceptacion verificables

- Un update con `expected_version` desactualizada devuelve conflicto verificable.
- Repetir la misma mutacion con igual `idempotency_key` no duplica ni reescribe resultados.
- Un delete en un dispositivo llega a los demas como tombstone y no reaparece tras sync.
- El pull incremental reproduce estado convergente en dos clientes con orden distinto de eventos.

## Implementacion por lotes

- Batch S1: definir schema SQL/RLS de versionado, tombstones e idempotency log.
- Batch S2: exponer RPC/API con CAS e idempotencia, incluyendo codigos de conflicto.
- Batch S3: integrar engine de sync cliente (cola local, retry seguro, resolucion de conflicto).

## Enmienda 2026-10-20: el payload de item v4 no viaja por el cable

- Estado: Aceptada
- Fecha: 2026-10-20
- Complementa: no reemplaza la decision de versionado / CAS / idempotencia
  de este ADR. Solo acota que formato de item puede circular por el.
- Referencia: ADR-001, "Amendment 2026-10-20: master password record v3
  and item payload v4".

### Problema

Desde `4533a94` cada item se cifra con su propia clave, derivada con
`HKDF-SHA256(DEK, salt = 16 bytes aleatorios, info = "vaulta:item:v4|<rid>|<kid>|<iv>")`
(ADR-001, seccion 4). El `salt` es parte del input de la derivacion: sin
el, el dispositivo receptor calcula una clave distinta y el payload no
abre.

El esquema no tiene donde llevar ese `salt`. La tabla `vault_blobs` expone
`ciphertext`, `nonce`, `gcm_tag` y `key_version`, y nada mas
(`supabase/migrations/20260323100000_initial_vault_schema.sql:35-39`).
El codec del cable tampoco lo transporta: codifica
`base64url_nopad(rid) + "." + base64(ciphertext)` y nada mas
(`lib/core/sync/sync_item_payload_codec.dart:31-39`).

### Decision

**El repositorio decide no encolar la mutacion. No la encola rota.**

`_extractSyncPayload` devuelve `null` para cualquier payload de version 4
o superior (`local_encrypted_vault_repository.dart:405-407`), y `saveItem`
solo emite la mutacion cuando ese valor no es `null` (`:196-212`). La
escritura local sigue ocurriendo; lo que no se emite es el upsert al
backend. Falla cerrado: es preferible que un cambio no se propague a que
se propague algo que el otro dispositivo no puede leer.

Los tombstones no se ven afectados: no llevan ciphertext
(`local_encrypted_vault_repository.dart:217-231`).

### Por que hoy no se pierde nada

Un build de release no tiene sync. El bootstrap devuelve `null` salvo que
el APK se haya compilado con `--dart-define=SUPABASE_URL=...` y
`--dart-define=SUPABASE_ANON_KEY=...`
(`lib/core/sync/device_sync_bootstrap.dart:46-51`), y ningun workflow del
repo pasa esos defines (`.github/workflows/`). La superficie de sync solo
existe en builds que el proyecto produce a mano y con esas credenciales.

### Consecuencias

- **Sync no es funcional con el formato actual.** Cualquier vault que
  haya llegado a item v4 deja de propagar cambios de item por el
  backend, en silencio y sin error visible para el usuario. No es una
  degradacion parcial: es la funcionalidad ausente.
- Quien tenga un build con sync habilitado debe saber esto antes de
  habilitarlo. No hay aviso en la UI.
- Los demas controles de este ADR (CAS por `expected_version`,
  idempotencia, tombstones, pull incremental, resolucion de conflictos,
  `payloadRejected` como diagnostico) siguen validos e intactos para los
  payloads que si circulan (v1/v2/v3).
- `key_version` deja de poder usarse comoproxy de "el formato mas nuevo
  que un dispositivo entiende". Un payload v4 nunca se encola, asi que
  ningun receptor vera jamas un `key_version = 4`: el valor mas alto que
  puede viajar por el cable sigue siendo 3, aunque el formato local ya
  sea 4.

### Trabajo pendiente requerido

1. Transportar el `salt` de la clave de item por el cable: o una columna
   nueva en `vault_blobs`, o dentro del valor codificado de `ciphertext`
   junto al `rid`.
2. Actualizar el RPC de escritura y el de lectura, y el
   `sync_item_payload_codec.dart`, de forma versionada para que un cliente
   viejo no descarte silenciosamente la columna nueva.
3. Cubrir el camino de ida y vuelta con un test que afirme que un payload
   v4 con su `salt` abre en un segundo dispositivo con una sesion
   distinta.
4. recien entonces levantar el rechazo `>= 4` de
   `local_encrypted_vault_repository.dart:405-407`.

Mientras 1-4 no esten, este ADR debe leerse como: "el protocolo de sync
sigue siendo correcto, pero el formato de item que produce Vaulta hoy no
es transportable por el".
