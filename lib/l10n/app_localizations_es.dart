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
  String get settingsBiometricRequiresAndroid11Subtitle => 'El desbloqueo biométrico requiere Android 11 o superior: esta versión de Android no puede exigir autenticación solo biométrica en el KeyStore.';

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
  String get settingsHardwareBackedKeys => 'Clave en el KeyStore';

  @override
  String get settingsVaultEncryptionReady => 'Cifrado del vault conectado end-to-end';

  @override
  String get settingsCapabilitySupported => 'Disponible';

  @override
  String get settingsCapabilityUnsupported => 'No disponible';

  @override
  String get settingsCapabilityUnknown => 'No se pudo determinar';

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
  String get securityShowPassword => 'Mostrar contraseña';

  @override
  String get securityHidePassword => 'Ocultar contraseña';

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
  String get entryFavoriteLabel => 'Favorita';

  @override
  String get entryMarkFavoriteTooltip => 'Marcar como favorita';

  @override
  String get entryUnmarkFavoriteTooltip => 'Quitar de favoritas';

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
  String get entryPasswordHistoryTitle => 'Contraseñas anteriores';

  @override
  String get entryPasswordHistoryHint => 'Contraseñas que guardamos al cambiar el secreto. Primero las más recientes.';

  @override
  String get entryPasswordHistoryCopyTooltip => 'Copiar contraseña anterior';

  @override
  String get entryPasswordHistoryRevealTooltip => 'Mostrar contraseña anterior';

  @override
  String get entryPasswordHistoryHideTooltip => 'Ocultar contraseña anterior';

  @override
  String get totpTitle => 'Código de un solo uso';

  @override
  String get totpCopyCode => 'Copiar código';

  @override
  String totpSecondsRemaining(int seconds) {
    return '${seconds}s restantes';
  }

  @override
  String get totpUnavailable => 'No se pudo leer el código de un solo uso de esta entrada.';

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
  String get filterFavorites => 'Favoritas';

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
  String get editorFavoriteLabel => 'Entrada favorita';

  @override
  String get editorFavoriteHint => 'Las favoritas aparecen bajo el filtro Favoritas del tablero.';

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
  String get accessTitle => 'El autofill está listo';

  @override
  String get accessSubtitle => 'El servicio de autofill de Android de Vaulta está registrado en este dispositivo. Completa inicios de sesión en el navegador y en apps que verifican su sitio web en Android 12 o superior.';

  @override
  String get accessHeroTitle => 'Completa inicios de sesión sin copiar y pegar';

  @override
  String get accessHeroBody => 'Elegí Vaulta como servicio de autofill en los ajustes de Android y desbloqueá cuando un inicio de sesión pida una contraseña.';

  @override
  String get accessPlatformAndroid => 'Android';

  @override
  String get accessComingSoon => 'Disponible ahora';

  @override
  String get accessStatusTitle => 'Servicio de autofill registrado';

  @override
  String get accessStatusBody => 'El servicio de autofill de Vaulta está activo en este dispositivo. Nada en esta pantalla cambia los ajustes del sistema: elegí Vaulta en Ajustes → Servicio de autofill para empezar a completar.';

  @override
  String get accessUnlockPostureTitle => 'Postura de desbloqueo';

  @override
  String get accessUnlockPostureBody => 'Las solicitudes de autofill van a usar el mismo estado de desbloqueo que el resto de la app.';

  @override
  String get accessUnlocked => 'Vault desbloqueado';

  @override
  String get accessLocked => 'Vault bloqueado';

  @override
  String get accessLockNow => 'Bloquear vault ahora';

  @override
  String get accessRoadmapTitle => 'Lo que viene';

  @override
  String get accessRoadmapBody => 'El autofill de iOS y desktop todavía está pendiente. El llenado en apps de Android (más allá de sitios web verificados) está limitado por las reglas de verificación de dominio de la plataforma.';

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
  String get backupExportClearTextAction => 'Exportar sin cifrar (CSV/JSON)';

  @override
  String get backupClearTextTitle => 'Exportar archivo sin cifrar';

  @override
  String get backupClearTextReauthBody => 'Vuelve a ingresar tu master password para exportar el vault en texto plano.';

  @override
  String backupClearTextItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'El archivo tendrá $count entradas.',
      one: 'El archivo tendrá 1 entrada.',
    );
    return '$_temp0';
  }

  @override
  String get backupClearTextWarning => 'Este archivo NO está cifrado. Cualquiera que lo abra va a leer todas tus contraseñas, incluidas las apps que lo sincronicen a la nube. Borralo apenas termines de migrar.';

  @override
  String get backupClearTextFormatLabel => 'Formato';

  @override
  String get backupClearTextFormatCsv => 'CSV — gestores de contraseñas y planillas';

  @override
  String get backupClearTextFormatJson => 'JSON — todos los campos, sin pérdida de datos';

  @override
  String get backupClearTextConfirm => 'Entiendo que el archivo va a quedar sin cifrar en el disco.';

  @override
  String get backupClearTextCreateAction => 'Exportar archivo sin cifrar';

  @override
  String get backupClearTextSuccess => 'Archivo sin cifrar guardado. Borralo cuando ya no lo necesites.';

  @override
  String get backupClearTextExportFailed => 'No se pudo crear el archivo sin cifrar. Intenta de nuevo.';

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

  @override
  String get syncSignInTitle => 'Inicia sesion para sincronizar';

  @override
  String get syncSignInBody => 'Tu vault sigue cifrado en este dispositivo. La cuenta solo transporta texto cifrado entre tus dispositivos.';

  @override
  String get syncEmailLabel => 'Correo';

  @override
  String get syncPasswordLabel => 'Contrasena';

  @override
  String get syncSignInAction => 'Entrar';

  @override
  String get syncSignInInvalid => 'Correo o contrasena incorrectos.';

  @override
  String get syncSignInOffline => 'No se pudo llegar al servidor. Revisa tu conexion.';

  @override
  String get syncSignInRequired => 'Inicia sesion para sincronizar este vault.';

  @override
  String get securityMessageStateUnreadable => 'No pudimos leer el estado seguro del dispositivo. Reiniciá la configuración.';

  @override
  String get securityMessagePasswordConfirmationMismatch => 'La confirmación no coincide con la master password.';

  @override
  String get securityMessageNewPasswordConfirmationMismatch => 'La confirmación no coincide con la nueva master password.';

  @override
  String get securityMessageNewPasswordMustDifferFromCurrent => 'La nueva master password debe ser distinta de la actual.';

  @override
  String securityMessageMasterPasswordTooShort(String minimum) {
    return 'Usá al menos $minimum caracteres.';
  }

  @override
  String securityMessageMasterPasswordTooLong(String maximum) {
    return 'Usá como máximo $maximum caracteres.';
  }

  @override
  String get securityMessageMasterPasswordBreached => 'Esa contraseña aparece en listas de contraseñas filtradas. Elegí otra.';

  @override
  String get securityMessageBiometricNotAvailableOnDevice => 'El desbloqueo biométrico no está disponible en este dispositivo.';

  @override
  String get securityMessageBiometricNotEnrolled => 'No hay biometría registrada en este dispositivo. Configurá la huella o el reconocimiento facial en los ajustes del sistema y reintentá.';

  @override
  String get securityMessageNoMasterPasswordConfigured => 'Todavía no configuraste una master password.';

  @override
  String get securityMessagePasswordMismatch => 'La master password no coincide.';

  @override
  String get securityMessageCurrentPasswordMismatch => 'La master password actual no coincide.';

  @override
  String get securityMessageBiometricUnlockNotWired => 'El desbloqueo biométrico no está conectado en este dispositivo.';

  @override
  String get securityMessageBiometricIdentityRejected => 'No pudimos verificar tu identidad. Ingresá la master password.';

  @override
  String securityMessageBiometricKeyRejected(String reason) {
    return 'La plataforma rechazó la clave biométrica ($reason). Re-enrolá biometría o usá la master password.';
  }

  @override
  String get securityMessageBiometricKeyInconsistent => 'La plataforma devolvió una clave inconsistente. Ingresá la master password y re-enrolá biometría.';

  @override
  String get securityMessageBiometricSessionRecoveryFailed => 'No pudimos recuperar tu sesión con biometría. Re-enrolá biometría o usá la master password.';

  @override
  String get securityMessageVaultCannotBeOpened => 'Este vault no se puede abrir: la clave guardada está dañada. Restaurá una copia o volvé a importar el vault.';

  @override
  String get securityMessageMasterPasswordNeedsMigration => 'Tu master password es de un formato anterior. Desbloqueá una vez con ella para que Vaulta vuelva a cifrar el vault y reintentá.';

  @override
  String securityMessageBiometricEnrollmentFailed(String reason) {
    return 'No pudimos preparar la huella en este dispositivo. Reintentá o usá la master password. [$reason]';
  }

  @override
  String get securityMessageUnlockBeforeChangingMasterPassword => 'Desbloqueá Vaulta antes de cambiar la master password.';

  @override
  String get securityMessageSessionNotInMemory => 'No hay una sesión de vault válida en memoria. Volvé a desbloquear.';

  @override
  String get securityMessageSessionRecordKeyMismatch => 'La sesión activa no coincide con la clave maestra vigente. Volvé a desbloquear antes de reintentar.';

  @override
  String get securityMessageRekeyFailed => 'No pudimos completar el re-cifrado del vault. Se mantuvo tu clave actual para evitar inconsistencias.';

  @override
  String get securityMessageRecordSaveFailed => 'No pudimos guardar la nueva master password. Se mantuvo tu clave actual para evitar inconsistencias.';

  @override
  String get securityMessageRekeyRollbackFailed => 'Falló el guardado de la nueva master password y no pudimos confirmar un rollback completo. Vaulta queda bloqueada por seguridad.';

  @override
  String get securityMessageRecordMigrationRollbackFailed => 'No pudimos actualizar el cifrado del vault y el rollback tampoco se completó. Vaulta queda bloqueada por seguridad.';

  @override
  String get securityMessageItemsMigrationFailed => 'No pudimos actualizar el cifrado del vault. Tus datos siguen intactos; volvé a desbloquear para reintentar.';

  @override
  String get securityMessageMasterPasswordCreated => 'Master password creada. Tu sesión local queda protegida por el sistema.';

  @override
  String get securityMessageMasterPasswordChanged => 'Master password actualizada y vault re-cifrado con una nueva clave.';

  @override
  String get securityMessageVaultUnlocked => 'Vaulta desbloqueada.';

  @override
  String get securityMessageVaultUnlockedAndMigrated => 'Vaulta desbloqueada y migrada a cifrado v3.';

  @override
  String get securityMessageVaultUnlockedMigrationDeferred => 'Vaulta desbloqueada. La mejora de cifrado se reintentará en el próximo desbloqueo.';

  @override
  String get securityMessageVaultUnlockedWithBiometrics => 'Vaulta desbloqueada con biometría.';

  @override
  String get securityMessageBiometricNeedsPasswordFirst => 'Tocá \"Activar desbloqueo biométrico\" abajo para preparar tu huella. La master password no se guarda ni se envía a ningún servidor.';

  @override
  String get securityMessageBiometricEnabled => 'Biometría activada. La próxima vez podrás desbloquear Vaulta con tu biometría.';

  @override
  String get securityMessageBiometricDisabled => 'Biometría desactivada. Solo queda la master password.';

  @override
  String get securityMessageBiometricEnrollmentReady => 'Listo. La próxima vez podrás desbloquear Vaulta con tu huella.';

  @override
  String get securityMessageVaultLocked => 'Vaulta bloqueada.';

  @override
  String securityMessageVaultLockedWithReason(String reason) {
    return 'Vaulta bloqueada. $reason';
  }

  @override
  String get securityMessageVaultLockedOnBackground => 'Vaulta bloqueada automáticamente al salir de primer plano.';

  @override
  String get securityMessageVaultLockedOnIdle => 'Vaulta bloqueada automáticamente por inactividad.';

  @override
  String get securityMessageVaultLockedSessionRevoked => 'La sesión de este dispositivo se revocó. Vaulta se bloqueó por seguridad.';

  @override
  String get securityMessageVaultLockedAllSessionsRevoked => 'Se revocaron todas las sesiones de tu cuenta. Vaulta se bloqueó por seguridad.';

  @override
  String get securityMessageAutoLockBackgroundEnabled => 'Auto-lock al ir a background activado.';

  @override
  String get securityMessageAutoLockBackgroundDisabled => 'Auto-lock al ir a background desactivado.';

  @override
  String securityMessageIdleTimeoutEnabled(String duration) {
    return 'Auto-lock por inactividad activado ($duration).';
  }

  @override
  String get securityMessageIdleTimeoutDisabled => 'Auto-lock por inactividad desactivado.';
}
