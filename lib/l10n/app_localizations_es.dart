// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Vaulta';

  @override
  String get navVault => 'Vault';

  @override
  String get navAccess => 'Acceso';

  @override
  String get navSettings => 'Ajustes';

  @override
  String get brandFooter => 'Tecnodespegue.com';

  @override
  String get languageSectionTitle => 'Idioma';

  @override
  String get languageSelectorLabel => 'Idioma de la app';

  @override
  String get languageEnglish => 'Inglés';

  @override
  String get languageSpanish => 'Español';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get aboutTitle => 'Acerca de';

  @override
  String get aboutCreator => 'Creada por René Kuhm, fundador de Tecnodespegue.';

  @override
  String get aboutAgency => 'Tecnodespegue.com';

  @override
  String get settingsLocalUnlockPostureTitle => 'Postura de desbloqueo local';

  @override
  String get settingsLocalUnlockPostureDescription => 'Vaulta guarda el estado sensible en Keychain / Keystore. En Android, la biometría desbloquea el vault con una clave protegida por hardware; en otras plataformas se usa master password.';

  @override
  String get settingsMasterPasswordCreated => 'Master password creada';

  @override
  String get settingsBiometricsAvailable => 'Biometría disponible';

  @override
  String get settingsBiometricsEnabled => 'Biometría activada';

  @override
  String get settingsUnlockWithBiometrics => 'Usar biometría para desbloquear en Android';

  @override
  String settingsBiometricSupportedSubtitle(Object biometricLabel) {
    return 'Usa $biometricLabel para desbloquear el vault en Android. La master password sigue siendo necesaria para recuperar acceso, activar o re-enrolar biometría.';
  }

  @override
  String get settingsBiometricUnavailableSubtitle => 'No hay biometría configurada o soportada en este entorno.';

  @override
  String get settingsAutoLockBackgroundTitle => 'Auto-lock al pasar a background';

  @override
  String get settingsAutoLockBackgroundSubtitle => 'Bloquea Vaulta automaticamente si la app queda inactive, paused o detached.';

  @override
  String get settingsIdleTimeoutLabel => 'Auto-lock por inactividad en foreground';

  @override
  String get settingsLockNow => 'Bloquear ahora';

  @override
  String get settingsChangeMasterPassword => 'Cambiar master password';

  @override
  String get settingsSessionsTitle => 'Dispositivos y sesiones';

  @override
  String get settingsSessionsSubtitle => 'Podés revocar un equipo puntual o cortar el resto de sesiones activas.';

  @override
  String get settingsSessionsRefresh => 'Refrescar sesiones';

  @override
  String get settingsRevokeOtherDevices => 'Revocar todas las otras sesiones';

  @override
  String get settingsRevokeDevice => 'Revocar dispositivo';

  @override
  String get settingsRevokeCurrentDeviceTitle => 'Revocar este dispositivo?';

  @override
  String get settingsRevokeCurrentDeviceBody => 'Revocar el dispositivo actual va a bloquear esta sesión inmediatamente. Vas a tener que desbloquear de nuevo para continuar.';

  @override
  String get settingsRevokeNow => 'Revocar ahora';

  @override
  String get settingsRevokeDeviceError => 'No pudimos revocar este dispositivo. Reintenta en unos segundos.';

  @override
  String get settingsRevokedAllTitle => 'Sesion revocada en todos los dispositivos';

  @override
  String get settingsRevokedAllBody => 'El acceso de tu cuenta fue revocado para todas las sesiones. Este dispositivo se va a bloquear por seguridad.';

  @override
  String get settingsCurrentDeviceRevokedTitle => 'Dispositivo actual revocado';

  @override
  String get settingsCurrentDeviceRevokedBody => 'Este dispositivo ya no tiene una sesión activa. Vaulta se va a bloquear por seguridad.';

  @override
  String get settingsNoDevices => 'No hay dispositivos registrados para este usuario.';

  @override
  String get settingsCurrentDeviceLabel => 'Este dispositivo';

  @override
  String get settingsSessionStatusActive => 'Activa';

  @override
  String get settingsSessionStatusRevoked => 'Revocada';

  @override
  String get settingsDeviceNeverSeen => 'Sin actividad registrada';

  @override
  String get settingsDeviceRevokedMessage => 'Dispositivo revocado correctamente.';

  @override
  String get settingsRevokeOthersDone => 'Se revocaron las otras sesiones activas.';

  @override
  String get settingsRevokeOthersFailed => 'No pudimos revocar las otras sesiones. Reintenta en unos segundos.';

  @override
  String get settingsRoadmapTitle => 'Roadmap de seguridad de plataforma';

  @override
  String get settingsRoadmapNotes => 'Los ítems del vault usan el payload v4 de ADR-001: Argon2id deriva una KEK desde la master password, una DEK aleatoria abre la bóveda y cada ítem se sella con AES-256-GCM bajo su propia clave, con el ciphertext atado a su id de registro, id de clave de ítem, versión de clave de ítem e IV. Android recupera la DEK con biometría mediante una clave del KeyStore; iOS/macOS quedan pendientes.';

  @override
  String get settingsSecureStorage => 'Almacenamiento seguro';

  @override
  String get settingsBiometricUnlock => 'Recovery biométrico de clave';

  @override
  String get settingsHardwareBackedKeys => 'Claves con respaldo de hardware';

  @override
  String get settingsVaultEncryptionReady => 'Cifrado del vault conectado end-to-end';

  @override
  String get settingsConflictsTitle => 'Conflictos de sync';

  @override
  String get settingsConflictsEmpty => 'Sin conflictos pendientes. La cola de sync está limpia.';

  @override
  String get settingsConflictsRefresh => 'Refrescar';

  @override
  String get settingsConflictsLoadError => 'No pudimos cargar los conflictos de sync. Reintenta.';

  @override
  String get settingsSessionsLoadError => 'No pudimos cargar las sesiones de dispositivos. Reintenta.';

  @override
  String get settingsConflictsKindConflict => 'Conflicto';

  @override
  String get settingsConflictsReasonFallback => 'Conflicto CAS detectado al enviar la mutación.';

  @override
  String settingsConflictsVersionRow(Object expected, Object remote) {
    return 'Base local v$expected · Remoto v$remote';
  }

  @override
  String settingsDeviceStatusLabel(Object code) {
    return 'estado: $code';
  }

  @override
  String get settingsDeviceRevokeHint => 'Si revocás este dispositivo, Vaulta se va a bloquear de inmediato.';

  @override
  String get idleNever => 'Nunca';

  @override
  String get idleDisabled => 'Desactivado';

  @override
  String get idleOneMinute => '1 minuto';

  @override
  String get idleFiveMinutes => '5 minutos';

  @override
  String get idleFifteenMinutes => '15 minutos';

  @override
  String get idleStrict => 'Estricto';

  @override
  String get idleRecommended => 'Recomendado';

  @override
  String get idleRelaxed => 'Relajado';

  @override
  String get changeMasterPasswordTitle => 'Cambiar master password';

  @override
  String get changeMasterPasswordCurrent => 'Master password actual';

  @override
  String get changeMasterPasswordNew => 'Nueva master password';

  @override
  String get changeMasterPasswordConfirm => 'Confirmar nueva master password';

  @override
  String get changeMasterPasswordHint => 'Este cambio vuelve a cifrar todo el vault con una clave nueva.';

  @override
  String get cancel => 'Cancelar';

  @override
  String get apply => 'Aplicar';

  @override
  String get masterPasswordUpdatedSuccess => 'Master password actualizada correctamente.';

  @override
  String get changeMasterPasswordErrorFallback => 'No pudimos cambiar la master password. Revisa los datos e intenta de nuevo.';

  @override
  String get securityOnboardingEyebrow => 'Onboarding seguro';

  @override
  String get securityOnboardingTitle => 'Creamos tu llave maestra sin atajos peligrosos.';

  @override
  String get securityOnboardingSubtitle => 'La master password valida acceso local y deriva la clave que cifra los items del vault.';

  @override
  String get securityMasterPasswordTitle => 'Master password';

  @override
  String get securityMasterPasswordDescription => 'Pedimos 12+ caracteres con mezcla real. Nada de guardar la clave en texto plano.';

  @override
  String get securityMasterPasswordRequired => 'Hace falta una master password.';

  @override
  String get securityMasterPasswordMinLength => 'Usa al menos 12 caracteres.';

  @override
  String get securityMasterPasswordMismatch => 'La confirmación no coincide con la master password.';

  @override
  String get securityCreateMasterPassword => 'Crear master password';

  @override
  String get securityConfirmMasterPassword => 'Confirmar master password';

  @override
  String get securityChecklistHash => 'Argon2id para verificar la master password.';

  @override
  String get securityChecklistDerive => 'Argon2id deriva una KEK que desenvuelve una DEK aleatoria del vault.';

  @override
  String get securityChecklistEncrypt => 'Items locales cifrados con AES-256-GCM y record guardado con Keychain / Keystore.';

  @override
  String get securityEnableBiometrics => 'Habilitar biometría';

  @override
  String securityBiometricAvailable(Object biometricLabel) {
    return 'Habilita $biometricLabel para desbloquear Vaulta en Android. La master password sigue siendo el camino de recuperación y re-enrolamiento.';
  }

  @override
  String get securityBiometricUnavailable => 'El desbloqueo biométrico no está disponible: no hay biometría enrolled, o esta versión de Android no puede exigir una biometría. Igual vas a poder entrar con tu master password.';

  @override
  String get securityCreateSecureAccess => 'Crear acceso seguro al vault';

  @override
  String get securityUnlockEyebrow => 'Desbloquear';

  @override
  String get securityUnlockTitle => 'Tu vault queda cerrado hasta validar identidad real.';

  @override
  String securityUnlockBiometricSubtitle(Object biometricLabel) {
    return 'Usa tu master password o la biometría ya activada en este dispositivo.';
  }

  @override
  String get securityUnlockPasswordSubtitle => 'Usa tu master password para recuperar acceso.';

  @override
  String get securityUnlockBiometricHint => 'Escribí tu master password o tocá la huella para desbloquear.';

  @override
  String get securityUnlockPasswordHint => 'Escribí tu master password para desbloquear el vault.';

  @override
  String securityUnlockLockedOut(String time) {
    return 'Demasiados intentos fallidos. Podés reintentar en $time.';
  }

  @override
  String get securityUnlockStateUnavailable => 'Vaulta no pudo registrar este intento en el almacenamiento seguro, así que no verificó la contraseña. Reintentá; si se repite, reiniciá la app.';

  @override
  String get securityProtectedAccess => 'Acceso protegido';

  @override
  String get securityUnlockVault => 'Desbloquear vault';

  @override
  String get securityBiometricButton => 'Biometria';

  @override
  String get dashboardDecryptError => 'Vaulta no pudo descifrar el vault local en este momento.';

  @override
  String get dashboardDecryptErrorAdvice => 'Bloquea y desbloquea de nuevo con tu master password, despues reintenta. Ocultamos el detalle para no filtrar estado sensible.';

  @override
  String get entryDetailTitle => 'Detalle de entrada';

  @override
  String get entryEditTooltip => 'Editar entrada';

  @override
  String get entryDeleteTooltip => 'Eliminar entrada';

  @override
  String get entryUsernameLabel => 'Usuario';

  @override
  String get entryWebsiteLabel => 'Sitio web';

  @override
  String get entryStrengthLabel => 'Fortaleza';

  @override
  String get entryUpdatedLabel => 'Actualizado';

  @override
  String get entrySecretTitle => 'Secreto';

  @override
  String get entryShowSecret => 'Mostrar';

  @override
  String get entryHideSecret => 'Ocultar';

  @override
  String get copySecret => 'Copiar secreto';

  @override
  String get secretCopiedLocally => 'Secreto copiado. El portapapeles se limpiará en 30 segundos si no cambia.';

  @override
  String get clipboardCleared => 'Portapapeles limpiado.';

  @override
  String get entryNotesTitle => 'Notas';

  @override
  String get entryDeleteDialogTitle => 'Eliminar entrada?';

  @override
  String get entryDeleteDialogBody => 'Esto elimina el registro cifrado del vault local. El recovery remoto no está disponible en modo offline.';

  @override
  String get entryDeleteConfirm => 'Eliminar';

  @override
  String get retry => 'Reintentar';

  @override
  String get newEntry => 'Nueva entrada';

  @override
  String get entryCreatedMessage => 'Entrada cifrada creada.';

  @override
  String get vaultUpdatedMessage => 'Vault actualizado de forma local.';

  @override
  String get dashboardSubtitle => 'Tu centro de control cifrado';

  @override
  String get dashboardHeroTitle => 'Protegido por hardware del sistema';

  @override
  String get dashboardHeroBody => 'El vault local cifra cada entrada con AES-256-GCM. CRUD local, búsqueda, filtros y generador de passwords están listos; el sync remoto queda opcional y experimental.';

  @override
  String dashboardPillTrustedDevices(int count) {
    return '$count dispositivos confiables';
  }

  @override
  String get dashboardPillSyncEnabled => 'Sync seguro activo';

  @override
  String get dashboardPillSyncDisabled => 'Vault cifrado offline';

  @override
  String dashboardPillWeakNeedRotation(int count) {
    return '$count passwords necesitan rotacion';
  }

  @override
  String get dashboardQuickActionsEyebrow => 'Acción';

  @override
  String get securityScore => 'Puntaje de seguridad';

  @override
  String get vaultEntries => 'Entradas del vault';

  @override
  String get weakPasswords => 'Passwords debiles';

  @override
  String get reusedItems => 'Items reutilizados';

  @override
  String get trustedDevices => 'Dispositivos confiables';

  @override
  String get priorityActions => 'Acciones prioritarias';

  @override
  String get dashboardQuickActionsSummary => 'Ahora el vault es real: alta, edicion, detalle y borrado con cifrado preservado end-to-end.';

  @override
  String get createEncryptedEntry => 'Crear entrada cifrada';

  @override
  String get createEncryptedEntrySubtitle => 'Agrega nuevas credenciales y guardalas cifradas en reposo.';

  @override
  String get planNextHardeningStep => 'Planificar siguiente hardening';

  @override
  String get dashboardRoadmapSyncEnabled => 'El sync remoto es experimental y requiere una sesión Supabase configurada.';

  @override
  String get dashboardRoadmapSyncDisabled => 'Release offline-first: vault local, búsqueda, filtros y generador funcionan sin sync cloud.';

  @override
  String get vaultEntriesSectionTitle => 'Entradas del vault';

  @override
  String get searchVault => 'Buscar titulo, usuario o sitio';

  @override
  String get filter => 'Filtro';

  @override
  String get filterAllEntries => 'Todas las entradas';

  @override
  String get filterWeakOnly => 'Solo passwords debiles';

  @override
  String get filterWithNotes => 'Entradas con notas';

  @override
  String get resetFilters => 'Restablecer filtros';

  @override
  String get noResultsTitle => 'Ninguna entrada coincide con los filtros';

  @override
  String get noResultsSubtitle => 'Probá otra búsqueda o reiniciá filtros para ver todo otra vez.';

  @override
  String get emptyVaultTitle => 'Tu vault esta vacio';

  @override
  String get emptyVaultSubtitle => 'Crea tu primera entrada y Vaulta la cifra antes de persistirla.';

  @override
  String get createFirstEntry => 'Crear primera entrada';

  @override
  String itemsTotal(int count) {
    return '$count total';
  }

  @override
  String itemsShownOfTotal(int shown, int total) {
    return '$shown visibles - $total total';
  }

  @override
  String get editorTitleEdit => 'Editar entrada';

  @override
  String get editorTitleNew => 'Nueva entrada';

  @override
  String get editorIdentityTitle => 'Identidad';

  @override
  String get editorTitleLabel => 'Titulo';

  @override
  String get editorTitleHint => 'GitHub, banco, Wi-Fi...';

  @override
  String get editorTitleValidation => 'Dale un titulo claro a esta entrada.';

  @override
  String get editorUsernameLabel => 'Usuario o email';

  @override
  String get editorUsernameValidation => 'Agrega el identificador de la cuenta.';

  @override
  String get editorCategoryLabel => 'Categoria';

  @override
  String get editorCategoryWork => 'Trabajo';

  @override
  String get editorCategoryFinance => 'Finanzas';

  @override
  String get editorCategoryPersonal => 'Personal';

  @override
  String get editorCategoryInfrastructure => 'Infraestructura';

  @override
  String get editorSecretTitle => 'Secreto';

  @override
  String get editorSecretDescription => 'Vaulta recalcula la fortaleza localmente antes de recifrar la entrada.';

  @override
  String get editorSecretLabel => 'Password o secreto';

  @override
  String get editorSecretRequiredValidation => 'Guarda un secreto real, no un campo vacio.';

  @override
  String get editorSecretMinValidation => 'Usa al menos 8 caracteres.';

  @override
  String get editorGeneratorTitle => 'Generador de passwords';

  @override
  String editorGeneratorChars(int count) {
    return '$count caracteres';
  }

  @override
  String get editorGenerateInsert => 'Generar e insertar';

  @override
  String get editorWebsiteLabel => 'Sitio web o app';

  @override
  String get editorWebsiteHint => 'https://ejemplo.com';

  @override
  String get editorNotesLabel => 'Notas';

  @override
  String get editorNotesHint => 'Codigos de recuperacion, contexto, recordatorios...';

  @override
  String get editorSaveChanges => 'Guardar cambios';

  @override
  String get editorCreateEntry => 'Crear entrada';

  @override
  String get editorGeneratorSetRequired => 'Elegi al menos un set de caracteres para generar.';

  @override
  String get editorGeneratedInserted => 'Password generada e insertada.';

  @override
  String get syncConflictsTitle => 'Conflictos de sincronizacion';

  @override
  String get syncConflictsSubtitle => 'Un cambio remoto llego mientras tu edicion local estaba pendiente. Elegí qué version conservar.';

  @override
  String get syncConflictsEmpty => 'Sin conflictos pendientes. Todo sincronizado.';

  @override
  String get syncConflictsLoadError => 'No pudimos cargar los conflictos pendientes. Reintenta.';

  @override
  String get syncConflictResolveError => 'No pudimos resolver este conflicto. Reintenta.';

  @override
  String syncConflictsBannerLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'conflictos',
      one: 'conflicto',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return '$count $_temp0 de sync pendiente$_temp1';
  }

  @override
  String get syncConflictsBannerAction => 'Revisar';

  @override
  String get syncConflictLocalVersion => 'Tu version';

  @override
  String get syncConflictRemoteVersion => 'Version remota';

  @override
  String get syncConflictKeepLocal => 'Quedarme con la mia';

  @override
  String get syncConflictKeepRemote => 'Usar la remota';

  @override
  String get syncConflictKindUpsert => 'Conflicto de edicion';

  @override
  String get syncConflictKindDelete => 'Conflicto de borrado';

  @override
  String get biometricSlotExpired => 'La clave biométrica del vault no está lista o fue invalidada. Ingresa tu master password y vuelve a activar biometría.';

  @override
  String get biometricUnlockSuccess => 'Verificación biométrica aceptada.';

  @override
  String get biometricEnrollCta => 'Configurar biometría en el dispositivo';

  @override
  String get biometricEnrollSubtitle => 'Tu dispositivo no tiene biometría registrada (huella o reconocimiento facial). Abrí los ajustes del sistema para activarla.';

  @override
  String get biometricEnrollAction => 'Abrir ajustes';

  @override
  String get biometricEnrollUnavailable => 'La biometría no está disponible en este dispositivo. Usa la master password para desbloquear.';

  @override
  String get securitySetupBiometricCta => 'Activar desbloqueo biométrico';

  @override
  String get securitySetupBiometricDialogTitle => 'Activar desbloqueo biométrico';

  @override
  String get securitySetupBiometricDialogBody => 'Ingresa tu master password una sola vez para que Vaulta pueda cifrar la clave que protege tu huella.';

  @override
  String get securitySetupBiometricDialogAction => 'Activar';

  @override
  String get securitySetupBiometricDialogCancel => 'Cancelar';

  @override
  String get securitySetupBiometricSuccess => 'Listo. La próxima vez podrás desbloquear Vaulta con tu huella.';

  @override
  String get securitySetupBiometricError => 'No pudimos activar la huella. Verifica tu master password e intenta de nuevo.';

  @override
  String get updateTitle => 'Actualizaciones';

  @override
  String get updateInstalled => 'Instalada';

  @override
  String get updateRemote => 'Remota';

  @override
  String get updateDescription => 'Las versiones estables se publican desde releases etiquetadas. Antes de instalar, cada descarga se verifica contra los checksums SHA-256 de la release y el certificado de firma de la app.';

  @override
  String get updateCheck => 'Buscar actualizaciones';

  @override
  String get updateChecking => 'Buscando...';

  @override
  String get updateDownload => 'Descargar e instalar';

  @override
  String get updateDownloading => 'Descargando APK...';

  @override
  String get updateInstalling => 'Abriendo instalador...';

  @override
  String get updateRetry => 'Reintentar';

  @override
  String get updateUpToDateTitle => 'Al día';

  @override
  String get updateUpToDateBody => 'La version instalada coincide con la ultima publicada en este canal.';

  @override
  String get updateErrorTitle => 'No pudimos comprobar actualizaciones';

  @override
  String get updateInstallerFailed => 'No pudimos abrir el instalador del sistema. Verifica que \"Fuentes desconocidas\" este habilitado.';

  @override
  String updateAvailableVersion(Object tag) {
    return 'Nueva version $tag';
  }

  @override
  String updateReleaseId(Object id) {
    return 'release #$id';
  }

  @override
  String updateAvailableBanner(Object tag) {
    return 'Nueva version $tag disponible';
  }

  @override
  String get updateActionUpdate => 'Actualizar';

  @override
  String get updateDevChannelTitle => 'Canal dev';

  @override
  String get updateDevChannelSubtitle => 'Recibe la build continua que se publica con cada cambio en master. Menos probada que las versiones estables; las descargas se verifican igual.';

  @override
  String get updateChecksumMissing => 'Actualizacion rechazada: la release no publica un checksum SHA-256 para esta APK, asi que no se puede verificar.';

  @override
  String get updateChecksumMismatch => 'Actualizacion rechazada: la APK descargada no coincide con el checksum SHA-256 publicado. Se elimino.';

  @override
  String get updateSignatureMismatch => 'Actualizacion rechazada: la APK descargada no esta firmada con el mismo certificado que la app instalada. Se elimino.';

  @override
  String get updateInstallPrompt => 'Confirma la instalacion en la pantalla del sistema.';

  @override
  String get updateInstallFailed => 'No pudimos abrir el instalador. Andá a Ajustes para habilitar \"Fuentes desconocidas\" y volve a intentar.';

  @override
  String updateGenericError(Object error) {
    return 'Error al actualizar: $error';
  }

  @override
  String get accessEyebrow => 'Autofill y acceso';

  @override
  String get accessTitle => 'El autofill está en camino';

  @override
  String get accessSubtitle => 'Vaulta todavía no puede completar contraseñas en otras apps. Esta pantalla te va a guiar en la configuración apenas salga el servicio de autofill para Android.';

  @override
  String get accessHeroTitle => 'Autofill: próximamente';

  @override
  String get accessHeroBody => 'Mientras tanto, abrí la entrada en Vaulta y copiá el secreto. Los secretos copiados se borran del portapapeles automáticamente.';

  @override
  String get accessPlatformAndroid => 'Primero en Android';

  @override
  String get accessComingSoon => 'Próximamente';

  @override
  String get accessStatusTitle => 'No disponible en esta versión';

  @override
  String get accessStatusBody => 'Esta versión no registra un servicio de autofill de Android, así que Vaulta todavía no aparece en Ajustes → Servicio de Autofill. Nada en esta pantalla cambia los ajustes del sistema.';

  @override
  String get accessUnlockPostureTitle => 'Postura de desbloqueo';

  @override
  String get accessUnlockPostureBody => 'Cuando salga el autofill, sus solicitudes van a usar el mismo estado de desbloqueo que el resto de la app.';

  @override
  String get accessUnlocked => 'Vault desbloqueado';

  @override
  String get accessLocked => 'Vault bloqueado';

  @override
  String get accessLockNow => 'Bloquear vault ahora';

  @override
  String get accessRoadmapTitle => 'Lo que viene';

  @override
  String get accessRoadmapBody => 'Lo próximo: un servicio nativo de autofill para Android que reutiliza esta pantalla. El autofill de iOS y desktop viene después.';

  @override
  String get accessPlatformBiometrics => 'Desbloqueo biométrico';

  @override
  String get accessPlatformOffline => 'Offline por defecto';

  @override
  String get accessSetupTitle => 'Configuracion en tres pasos';

  @override
  String get accessSetupSubtitle => 'En Android 11 y superiores el sistema expone un servicio de Autofill al que Vaulta se puede conectar.';

  @override
  String get accessSetupStep1Title => 'Abrí Ajustes de Android';

  @override
  String get accessSetupStep1Body => 'Andá a Sistema → Idiomas y entrada → Servicio de Autofill.';

  @override
  String get accessSetupStep2Title => 'Elegí Vaulta';

  @override
  String get accessSetupStep2Body => 'Seleccioná Vaulta como servicio activo. Android va a pedir confirmacion.';

  @override
  String get accessSetupStep3Title => 'Desbloqueá y aprobá';

  @override
  String get accessSetupStep3Body => 'La próxima vez que toques un campo de password, Vaulta pide biometria o master password y completa la entrada correcta.';

  @override
  String get backupSectionTitle => 'Copia de seguridad cifrada';

  @override
  String get backupSectionSubtitle => 'Exporta tu vault a un archivo .vaulta cifrado para restaurarlo en un dispositivo nuevo. Guarda el archivo fuera de este dispositivo.';

  @override
  String get backupExportAction => 'Exportar copia';

  @override
  String get backupRestoreAction => 'Restaurar copia';

  @override
  String get backupExportTitle => 'Exportar copia cifrada';

  @override
  String get backupReauthBody => 'Vuelve a ingresar tu master password para exportar el vault.';

  @override
  String get backupMasterPasswordLabel => 'Master password';

  @override
  String get backupContinue => 'Continuar';

  @override
  String get backupMasterPasswordMismatch => 'La master password no coincide.';

  @override
  String backupItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'La copia contendra $count entradas.',
      one: 'La copia contendra 1 entrada.',
    );
    return '$_temp0';
  }

  @override
  String get backupPasswordLabel => 'Password de la copia';

  @override
  String get backupPasswordConfirmLabel => 'Confirmar password de la copia';

  @override
  String get backupPasswordHint => 'Al menos 12 caracteres, y que no aparezca en listas de contrasenas filtradas. Una frase larga es mejor.';

  @override
  String get backupPasswordWarning => 'Vaulta no puede recuperar la password de la copia. Si la olvidas, nadie podra abrir esta copia, ni siquiera tu.';

  @override
  String backupPasswordTooShort(int min) {
    return 'Usa al menos $min caracteres.';
  }

  @override
  String get backupPasswordWeak => 'Esa contrasena aparece en listas de contrasenas filtradas. Elegi otra.';

  @override
  String get backupPasswordMismatch => 'La confirmacion no coincide con la password de la copia.';

  @override
  String get backupCreateAction => 'Crear copia';

  @override
  String get backupSaveAgain => 'Guardar archivo';

  @override
  String get backupSaveCancelled => 'Se cancelo el guardado. No se escribio ningun archivo.';

  @override
  String get backupExportSuccess => 'Copia cifrada guardada.';

  @override
  String get backupExportFailed => 'No se pudo crear la copia. Intenta de nuevo.';

  @override
  String get backupReauthExpired => 'Tu confirmacion vencio. Vuelve a iniciar la exportacion.';

  @override
  String get backupRestoreTitle => 'Restaurar copia';

  @override
  String get backupRestoreIntro => 'Elige un archivo .vaulta e ingresa su password. No se escribe nada en tu vault hasta que confirmes.';

  @override
  String get backupPickFile => 'Elegir archivo de copia';

  @override
  String get backupPickFailed => 'No se pudo abrir el archivo.';

  @override
  String get backupUnlockAction => 'Abrir copia';

  @override
  String get backupOpenFailed => 'No se pudo abrir la copia. Revisa la password de la copia; el archivo tambien puede estar danado o modificado.';

  @override
  String get backupUnsupportedVersion => 'Esta copia la creo una version mas nueva de Vaulta. Actualiza la app e intenta de nuevo.';

  @override
  String get backupPreviewTitle => 'Contenido de la copia';

  @override
  String backupPreviewCreatedAt(String date) {
    return 'Creada el $date';
  }

  @override
  String backupPreviewSummary(int total, int fresh, int conflicts, int duplicates) {
    return '$total entradas: $fresh nuevas, $conflicts conservadas junto a una similar, $duplicates ya estan en tu vault.';
  }

  @override
  String get backupConflictSuffix => ' (restaurada)';

  @override
  String backupRestoreConfirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restaurar $count entradas',
      one: 'Restaurar 1 entrada',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreNothing => 'Todas las entradas de esta copia ya estan en tu vault.';

  @override
  String backupRestoreSuccess(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se restauraron $count entradas.',
      one: 'Se restauro 1 entrada.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreFailed => 'La restauracion se interrumpio. Se conservaron las entradas escritas antes del error.';

  @override
  String get backupRestoreLocked => 'Desbloquea Vaulta para restaurar una copia.';
}
