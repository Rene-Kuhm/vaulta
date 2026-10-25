<p align="center">
  <img src="docs/publication/vaulta-hero.png" alt="Vaulta - gestor de contrasenas cifrado por TecnoDespegue" width="100%">
</p>

<h1 align="center">Vaulta</h1>

<p align="center">
  <strong>Gestor de contrasenas cifrado, offline-first y multiplataforma (Android y Windows).</strong>
</p>

<p align="center">
  <a href="https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta.apk">Descargar APK (Android)</a>
  ·
  <a href="https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta-windows-bundle.zip">Descargar bundle Windows</a>
  ·
  <a href="https://github.com/Rene-Kuhm/vaulta/releases/latest">Ver release</a>
  ·
  <a href="https://www.tecnodespegue.com/">TecnoDespegue</a>
</p>

Vaulta es una aplicacion desarrollada por [TecnoDespegue](https://www.tecnodespegue.com/) para proteger credenciales sensibles con una experiencia moderna, rapida y consistente entre Android y Windows. El proyecto combina Flutter, Material 3, cifrado local real, desbloqueo biometrico en Android y un canal de actualizaciones para Android que distribuye una APK firmada desde GitHub Releases.

## Vision

Vaulta nace como una solucion de seguridad personal construida con el enfoque de TecnoDespegue: codigo real, arquitectura limpia, automatizacion confiable y decisiones tecnicas transparentes.

El objetivo es ofrecer un vault local para guardar, buscar y gestionar credenciales sin depender de una conexion permanente, sobre una base de sincronizacion entre dispositivos ya implementada pero apagada en los builds publicados, y abierta a auditorias de seguridad y distribucion publica.

## Funcionalidades principales

- Vault offline-first con persistencia local cifrada.
- Cifrado AES-256-GCM para payloads del vault.
- Derivacion de claves con Argon2id.
- DEK aleatoria por vault y envelope protegido.
- Desbloqueo con master password en todas las plataformas.
- Desbloqueo biometrico real en Android: una clave RSA-2048 del Android KeyStore, atada a biometria fuerte, protege el envelope de la DEK y solo se libera tras un `BiometricPrompt` con `CryptoObject`.
- Autofill nativo de Android: el servicio del sistema (`android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/VaultaAutofillService.kt`) responde a las solicitudes de llenado a traves del bridge al motor unico de la app (`VaultaAutofillBridge.kt`) y de una actividad de desbloqueo propia (`AutofillUnlockActivity.kt`), con la configuracion del servicio en `android/app/src/main/res/xml/autofill_service.xml` y el lado Dart en `lib/features/autofill/`. Llena inicios de sesion del navegador y de apps con sitio web verificado en Android 12 o superior, y cuando no hay coincidencia ofrece una busqueda dentro de Vaulta en vez de adivinar (ver [ADR-008](docs/architecture/ADR-008-autofill.md)).
- CRUD de credenciales con busqueda interna.
- Importacion local desde CSV y JSON con vista previa antes de guardar.
- Importacion desde bases KeePass (`.kdbx` 3.1 y 4.x), con master password y key file opcionales.
- TOTP integrado (RFC 6238): un item guarda su secreto `otpauth://` y la app muestra el codigo vigente con cuenta regresiva.
- Historial de contrasenas por item: al rotar un secreto, el anterior queda recuperable con la fecha en que se reemplazo.
- Exportacion en texto plano a CSV y JSON, detras de una advertencia explicita y una re-autenticacion, para poder migrar a otro gestor.
- Reporte de salud del vault: que items son debiles y cuales comparten secreto, con cada uno abrible desde el reporte.
- Dashboard con metricas de seguridad del vault.
- Estados de carga, error, vacio y resultados.
- Bloqueo automatico al salir de primer plano y por inactividad (15 minutos por defecto, configurable).
- Borrado automatico del portapapeles 30 segundos despues de copiar un secreto, si el contenido no cambio.
- Canal de actualizaciones Android dentro de la app, que consulta el release `dev-latest` de GitHub.
- Build de Windows con tema oscuro forzado para garantizar contraste correcto sobre el fondo del escritorio.
- Publicacion automatica en CI de la APK firmada `vaulta.apk` en el release `dev-latest`. El bundle de Windows (`vaulta-windows-bundle.zip`) se publica a mano en los releases estables y no tiene firma de codigo.

## Capturas

<table>
  <tr>
    <td width="25%"><img src="docs/publication/screenshots/01-onboarding.png" alt="Onboarding y creacion del vault" width="100%"></td>
    <td width="25%"><img src="docs/publication/screenshots/02-dashboard.png" alt="Dashboard con metricas de seguridad" width="100%"></td>
    <td width="25%"><img src="docs/publication/screenshots/03-search.png" alt="Busqueda interna de credenciales" width="100%"></td>
    <td width="25%"><img src="docs/publication/screenshots/04-editor.png" alt="Editor de credenciales" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub>Onboarding</sub></td>
    <td align="center"><sub>Dashboard</sub></td>
    <td align="center"><sub>Busqueda</sub></td>
    <td align="center"><sub>Editor</sub></td>
  </tr>
  <tr>
    <td width="25%"><img src="docs/publication/screenshots/05-detail.png" alt="Detalle de una credencial" width="100%"></td>
    <td width="25%"><img src="docs/publication/screenshots/06-access.png" alt="Desbloqueo biometrico" width="100%"></td>
    <td width="25%"><img src="docs/publication/screenshots/07-settings.png" alt="Ajustes y canal de actualizaciones" width="100%"></td>
    <td width="25%"></td>
  </tr>
  <tr>
    <td align="center"><sub>Detalle</sub></td>
    <td align="center"><sub>Desbloqueo</sub></td>
    <td align="center"><sub>Ajustes</sub></td>
    <td></td>
  </tr>
</table>

## Estado del producto

Vaulta esta en etapa MVP release-ready para Android y Windows desktop. La app ya cuenta con cifrado local, biometria Android, APK firmada con canal de actualizaciones, iconos Android personalizados y auditoria funcional reciente del buscador interno y las pantallas principales.

Plataformas soportadas:

- **Android**: experiencia completa, incluye autofill del sistema, desbloqueo biometrico y canal de actualizaciones dentro de la app. El autofill esta implementado: el servicio, el bridge, la actividad de desbloqueo y el lado Dart existen y responden a las solicitudes de Android (ver la lista de funcionalidades y [ADR-008](docs/architecture/ADR-008-autofill.md)). La pestana "Acceso" (`lib/features/access/presentation/access_screen.dart`) muestra el estado del servicio en el dispositivo, la postura de desbloqueo que condiciona cada llenado y donde se elige Vaulta como servicio de autofill en los ajustes de Android; no cambia ajustes del sistema por su cuenta. Fuera de Android no hay autofill: no hay Credential Provider de iOS, ni llenado en el build de Windows, ni extension de navegador, ni passkeys.
- **Windows desktop**: build nativo x64 (`vaulta.exe`) que reutiliza el mismo vault cifrado, persistencia local segura (Windows Credential Manager) y todas las funciones de gestion de credenciales. El desbloqueo es solo con master password: `local_auth` puede detectar Windows Hello, pero el desbloqueo biometrico del vault no esta conectado fuera de Android.

El desbloqueo biometrico esta implementado solo para Android. En Windows, iOS, macOS, Linux y web se usa la master password hasta implementar bindings equivalentes por plataforma.

> Nota de seguridad: Vaulta cifra datos locales, pero todavia no cuenta con auditoria criptografica externa. No se debe presentar como producto de seguridad certificado hasta completar una revision independiente.

## Hoja de ruta / Roadmap

Lo siguiente **todavia no esta disponible** en ninguna version publicada:

- Autofill fuera de Android: no hay Credential Provider de iOS, ni autofill en el build de Windows, ni extension de navegador, ni passkeys.
- Sincronizacion con cuenta entre dispositivos en los builds publicados: la base ya existe y funciona (la DEK envuelta viaja en la tabla `vault_keys` con `rpc_vault_get_key` / `rpc_vault_put_key`, ver [Seguridad](#seguridad)), pero esta apagada porque el pipeline de CI no define `SUPABASE_URL` ni `SUPABASE_ANON_KEY`.
- Firma de codigo para el binario de Windows.
- Auditoria criptografica externa.

El estado detallado de cada control de seguridad, con evidencia en el codigo, esta en [docs/security/hardening-status.md](docs/security/hardening-status.md) (en ingles).

## Stack tecnico

- Flutter (Android + Windows desktop)
- Dart `^3.11.3`
- Material 3
- `flutter_secure_storage` (Android Keystore + Windows Credential Manager)
- `BiometricPrompt` nativo via MethodChannel en Android; `local_auth` solo para detectar capacidades biometricas en el resto de plataformas
- `cryptography`
- `supabase_flutter`
- Android KeyStore
- Visual Studio Build Tools 2022 (toolchain de Windows)
- GitHub Actions
- GitHub Releases

## Arquitectura

```text
lib/
  app/
    bootstrap/        Arranque y configuracion principal
    design_system/   Componentes visuales reutilizables
    theme/           Tokens, colores y tema Material
  core/
    security/        Master password, cifrado, biometria y storage seguro
    storage/         Persistencia del vault en SQLite y migracion desde el blob cifrado
    sync/            Contratos y servicios de sincronizacion opcional
    update/          Verificacion de actualizaciones
  features/
    access/          Pestana "Acceso": estado del autofill y postura de desbloqueo
    autofill/        Lado Dart del autofill: canal con el servicio nativo y armado de candidatos
    backup/          Backup cifrado `.vaulta`
    health/          Reporte de salud del vault
    home/            Shell principal y navegacion
    security/        Gate de bloqueo y desbloqueo
    vault/           Dashboard, busqueda, detalle y editor de credenciales
    settings/        Configuracion, biometria, sync y actualizaciones
    sync/            Formularios de la sync opcional con Supabase
    totp/            Codigos TOTP (RFC 6238)
```

## Seguridad

Vaulta implementa una postura de seguridad local basada en:

- Master password como factor principal de recuperacion.
- Argon2id para derivacion de clave.
- AES-256-GCM para cifrado autenticado.
- Clave DEK independiente del password del usuario.
- Envelope protegido para desbloqueo biometrico en Android.
- Exportacion y restauracion de backup cifrado (`.vaulta`, Argon2id + AES-256-GCM, password propia distinta de la master password; ver [ADR-006](docs/architecture/ADR-006-encrypted-backup.md)).
- La pantalla de seguridad reporta las capacidades del dispositivo consultando a los servicios que las implementan, con tres estados (disponible, no disponible, no se pudo determinar) en vez de asumir un `false`.
- Bloqueo automatico al salir de primer plano o por inactividad.
- Borrado automatico del portapapeles tras copiar un secreto.
- Manejo explicito de estados de error y sesiones revocadas.

La sincronizacion remota con Supabase existe como base tecnica experimental y esta apagada en los builds publicados: solo se activa si el build define `SUPABASE_URL` y `SUPABASE_ANON_KEY` con `--dart-define`, y el pipeline de CI no los define.

Esa base incluye la parte que hace falta para que el mismo vault se abra en dos dispositivos: la DEK envuelta se guarda como metadata en la tabla `vault_keys`, con RLS por dueno y las RPC `rpc_vault_get_key` / `rpc_vault_put_key` ([migracion](supabase/migrations/20261023140000_add_vault_key_sync.sql), cliente en `lib/core/sync/supabase_vault_key_sync_repository.dart`), de modo que un segundo dispositivo con la misma master password reconstruye la misma DEK. Quedo verificado entre dos emuladores el 2026-10-23 ([odd/tasks/vault-key-cross-device-sync.md](odd/tasks/vault-key-cross-device-sync.md)). En los builds publicados sigue apagada porque el pipeline no define las claves de Supabase.

## Instalacion Android

Descargar el APK firmado desde el release actual:

[vaulta.apk](https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta.apk)

Instalacion manual por ADB:

```bash
adb install -r vaulta.apk
```

Tambien se puede actualizar desde la app:

```text
Ajustes > Buscar actualizaciones
```

## Instalacion Windows

Descargar el bundle completo desde el release actual:

[vaulta-windows-bundle.zip](https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta-windows-bundle.zip)

Una vez descargado:

1. Extraer todo el contenido del ZIP en una carpeta, por ejemplo `C:\Program Files\Vaulta\`. El paquete incluye `vaulta.exe`, todas las DLLs de runtime de Flutter, los plugins de Windows y la carpeta `data/` con assets.
2. Ejecutar `vaulta.exe`. La primera vez que se abra, Windows SmartScreen puede pedir confirmacion ("Mas informacion" -> "Ejecutar de todas formas") porque el binario no tiene firma de codigo (Authenticode); la app funciona normalmente despues de aprobarlo.

> Importante: el ejecutable no se distribuye suelto porque necesita todas las DLLs y la carpeta `data/` en el mismo directorio. Si movés solo `vaulta.exe` a otra carpeta, la aplicacion no va a arrancar.

El vault se persiste en el perfil de usuario con cifrado AES-256-GCM y la master key se guarda en Windows Credential Manager via `flutter_secure_storage_windows`.

## Desarrollo local

Requisitos:

- Flutter estable
- Dart compatible con el SDK del proyecto
- Android Studio o toolchain Android para builds Android
- Visual Studio 2022 Build Tools con la workload "Desktop development with C++" + componente "C++ ATL" para builds Windows

Comandos principales:

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Build Android release:

```bash
flutter build apk --release
```

Build Windows release:

```bash
flutter build windows --release
```

El artefacto queda en `build/windows/x64/runner/Release/gestor_contrasenas.exe` y todas las DLLs de plugins en el mismo directorio. El nombre `vaulta.exe` del bundle publicado se asigna a mano al empaquetar; el build genera `gestor_contrasenas.exe` (`BINARY_NAME` en `windows/CMakeLists.txt`).

La firma Android release requiere secretos fuera del repositorio. Ver [docs/android-release-signing.md](docs/android-release-signing.md).

## Validacion

Validaciones esperadas antes de publicar cambios:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build windows --release
```

GitHub Actions tiene dos workflows:

- `flutter-ci.yml`: en cada push y pull request ejecuta `flutter analyze`, `flutter test` y un umbral de cobertura del 60% sobre `lib/core/security` (`scripts/check_coverage.sh`).
- `dev-apk-release.yml`: en cada push a `master` analiza, compila la APK release firmada con la clave de upload y la publica como `vaulta.apk` en el release `dev-latest`, que es el que consulta el actualizador de la app.

Ningun workflow compila ni firma el build de Windows. El bundle de Windows se sube a mano a los releases estables (por ejemplo `v1.0.22`).

## Documentacion relacionada

- [Estado del hardening de seguridad](docs/security/hardening-status.md)
- [ADR-008: autofill en Android](docs/architecture/ADR-008-autofill.md)
- [Modelo de amenaza](docs/architecture/THREAT_MODEL.md)
- [Contrato criptografico](docs/architecture/CRYPTO.md)
- [Firma y release Android](docs/android-release-signing.md)
- [Checklist de publicacion en stores](docs/store-release-checklist.md)
- [Plantilla de politica de privacidad](docs/privacy-policy-template.md)

## TecnoDespegue

TecnoDespegue desarrolla software fullstack, apps moviles multiplataforma y automatizaciones con IA para negocios que necesitan sistemas reales, escalables y mantenibles.

- Web: [tecnodespegue.com](https://www.tecnodespegue.com/)
- Especialidades: Flutter, Dart, Next.js, TypeScript, Python, automatizaciones con IA, APIs, integraciones y optimizacion de procesos.
- Enfoque: foco tecnico, codigo limpio, comunicacion transparente y entregas medibles.

## Licencia

Este proyecto se distribuye bajo la **Licencia MIT** (Copyright 2026 Rene Kuhm). Ver el archivo [`LICENSE`](./LICENSE) en la raiz para el texto completo.
