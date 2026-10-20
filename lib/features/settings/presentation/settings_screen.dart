import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/app_locale_controller.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/local_encrypted_vault_repository.dart';
import '../../../core/security/native_biometric_auth_service.dart';
import '../../../core/security/secure_storage_service.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../../core/sync/device_registration_repository.dart';
import '../../../core/sync/sync_conflict.dart';
import '../../../core/sync/sync_conflict_resolver.dart';
import '../../../core/sync/device_session_revocation_service.dart';
import '../../../core/update/update_service.dart';
import '../../security/presentation/unlock_throttle_text.dart';
import 'update_section.dart';

/// "Settings" tab: local unlock posture (biometric toggle, idle
/// timeout, lock now, change master password), sync conflict list,
/// connected device list with revocation, update section, language
/// selector, and about/roadmap footer.
///
/// All optional services (conflict resolver, revocation service,
/// secure storage) are only rendered when provided, so the screen
/// stays usable in stripped-down configurations.
class SettingsScreen extends StatefulWidget {
  /// Builds the settings tab. [securityController] and
  /// [localeController] are required; the other services are
  /// optional and only enable their respective sections when
  /// provided.
  const SettingsScreen({
    super.key,
    required this.securityController,
    required this.localeController,
    this.conflictResolver,
    this.revocationService,
    this.secureStorage,
  });

  /// Controller that owns the local unlock posture toggles
  /// (biometric enable, auto-lock, idle timeout, master password).
  final VaultSecurityController securityController;

  /// Locale controller for the in-app language switcher.
  final AppLocaleController localeController;

  /// Optional resolver used to list and resolve pending sync
  /// conflicts.
  final SyncConflictResolver? conflictResolver;

  /// Optional service that lists and revokes registered device
  /// sessions.
  final DeviceSessionRevocationService? revocationService;

  /// Optional secure storage used by the embedded
  /// [UpdateService] to remember which build has already been
  /// prompted.
  final SecureStorageService? secureStorage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<List<SyncConflictRecord>> _conflictsFuture;
  late Future<List<DeviceSessionView>> _devicesFuture;
  bool _revocationInProgress = false;
  bool _currentDeviceRevocationHandled = false;
  NativeBiometricCapability _biometricCapability =
      NativeBiometricCapability.empty;
  bool _enrollingBiometric = false;

  @override
  void initState() {
    super.initState();
    _conflictsFuture = _loadConflicts();
    _devicesFuture = _loadDevices();
    unawaited(_refreshBiometricCapability());
  }

  Future<void> _refreshBiometricCapability() async {
    final cap = await widget.securityController.probeBiometricCapability();
    if (!mounted) return;
    if (cap.canUseStrongOrCredential !=
            _biometricCapability.canUseStrongOrCredential ||
        cap.needsEnrollment != _biometricCapability.needsEnrollment) {
      setState(() => _biometricCapability = cap);
    } else if (!_biometricCapability.canUseStrong &&
        !_biometricCapability.canUseWeak &&
        (cap.canUseStrong || cap.canUseWeak)) {
      setState(() => _biometricCapability = cap);
    }
  }

  Future<void> _openBiometricEnrollment() async {
    if (_enrollingBiometric) return;
    setState(() => _enrollingBiometric = true);
    try {
      final ok = await widget.securityController.openBiometricEnrollment();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.biometricEnrollUnavailable)),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshBiometricCapability();
    } finally {
      if (mounted) {
        setState(() => _enrollingBiometric = false);
      }
    }
  }

  Future<void> _openChangeMasterPasswordDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _ChangeMasterPasswordDialog(
          controller: widget.securityController,
        );
      },
    );
  }

  Future<List<SyncConflictRecord>> _loadConflicts() async {
    final resolver = widget.conflictResolver;
    if (resolver == null) {
      return const [];
    }
    return resolver.readPendingConflicts();
  }

  Future<List<DeviceSessionView>> _loadDevices() async {
    final revocationService = widget.revocationService;
    if (revocationService == null) {
      return const [];
    }
    return revocationService.listDevices();
  }

  void _refreshConflicts() {
    setState(() {
      _conflictsFuture = _loadConflicts();
    });
  }

  void _refreshDevices() {
    setState(() {
      _devicesFuture = _loadDevices();
    });
  }

  Future<void> _revokeDevice(
    BuildContext context,
    DeviceSessionView device,
  ) async {
    final revocationService = widget.revocationService;
    if (revocationService == null) {
      return;
    }
    if (_revocationInProgress) {
      return;
    }

    if (device.isCurrentDevice && !device.isRevoked) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(context.l10n.settingsRevokeCurrentDeviceTitle),
            content: Text(context.l10n.settingsRevokeCurrentDeviceBody),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(false);
                },
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(true);
                },
                child: Text(context.l10n.settingsRevokeNow),
              ),
            ],
          );
        },
      );

      if (shouldContinue != true) {
        return;
      }
    }

    setState(() {
      _revocationInProgress = true;
    });

    try {
      await revocationService.revokeDevice(deviceId: device.deviceId);

      if (!context.mounted) {
        return;
      }

      if (device.isCurrentDevice) {
        await _handleCurrentDeviceRevocation(
          context,
          status: DeviceSessionStatus.revokedDevice,
          lockReason: context.l10n.settingsCurrentDeviceRevokedBody,
        );
        return;
      }

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.settingsDeviceRevokedMessage)),
      );
      _refreshDevices();
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.settingsRevokeDeviceError)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revocationInProgress = false;
        });
      }
    }
  }

  Future<void> _handleCurrentDeviceRevocation(
    BuildContext context, {
    required DeviceSessionStatus status,
    required String lockReason,
  }) async {
    if (_currentDeviceRevocationHandled) {
      return;
    }

    _currentDeviceRevocationHandled = true;

    if (!context.mounted) {
      return;
    }

    final title = switch (status) {
      DeviceSessionStatus.revokedAll => context.l10n.settingsRevokedAllTitle,
      _ => context.l10n.settingsCurrentDeviceRevokedTitle,
    };
    final message = switch (status) {
      DeviceSessionStatus.revokedAll => context.l10n.settingsRevokedAllBody,
      _ => context.l10n.settingsCurrentDeviceRevokedBody,
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: Text(context.l10n.settingsLockNow),
            ),
          ],
        );
      },
    );

    if (!context.mounted) {
      return;
    }

    await widget.securityController.lock(reason: lockReason);
  }

  Future<void> _revokeAllOtherDevices(BuildContext context) async {
    final revocationService = widget.revocationService;
    if (revocationService == null) {
      return;
    }
    if (_revocationInProgress) {
      return;
    }

    setState(() {
      _revocationInProgress = true;
    });

    try {
      await revocationService.revokeAllOtherDevices();

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.settingsRevokeOthersDone)),
      );
      _refreshDevices();
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.settingsRevokeOthersFailed)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revocationInProgress = false;
        });
      }
    }
  }

  String _statusCode(DeviceSessionStatus status) {
    return switch (status) {
      DeviceSessionStatus.active => 'active',
      DeviceSessionStatus.revokedDevice => 'revoked_device',
      DeviceSessionStatus.revokedAll => 'revoked_all',
      DeviceSessionStatus.unknown => 'unknown',
    };
  }

  String _formatSeenAt(BuildContext context, DateTime? date) {
    final l10n = context.l10n;
    if (date == null) {
      return l10n.settingsDeviceNeverSeen;
    }
    return DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(date.toLocal());
  }

  Future<void> _resolveConflict(
    BuildContext context,
    SyncConflictRecord conflict,
    SyncConflictResolution resolution,
  ) async {
    final resolver = widget.conflictResolver;
    if (resolver == null) {
      return;
    }

    final result = await resolver.resolve(
      conflictId: conflict.id,
      resolution: resolution,
    );

    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
    _refreshConflicts();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final securityController = widget.securityController;
    final localeController = widget.localeController;
    final idleTimeoutPresets = <_IdleTimeoutPreset>[
      _IdleTimeoutPreset(
        seconds: 0,
        label: l10n.idleNever,
        description: l10n.idleDisabled,
      ),
      _IdleTimeoutPreset(
        seconds: 60,
        label: l10n.idleOneMinute,
        description: l10n.idleStrict,
      ),
      _IdleTimeoutPreset(
        seconds: 300,
        label: l10n.idleFiveMinutes,
        description: l10n.idleRecommended,
      ),
      _IdleTimeoutPreset(
        seconds: 900,
        label: l10n.idleFifteenMinutes,
        description: l10n.idleRelaxed,
      ),
    ];

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xxxl,
        ),
        children: [
          AppPanel(
            child: AnimatedBuilder(
              animation: securityController,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsLocalUnlockPostureTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n.settingsLocalUnlockPostureDescription,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _CapabilityRow(
                      title: l10n.settingsMasterPasswordCreated,
                      enabled: true,
                    ),
                    _CapabilityRow(
                      title: l10n.settingsBiometricsAvailable,
                      enabled: securityController.canOfferBiometricToggle,
                    ),
                    _CapabilityRow(
                      title: l10n.settingsBiometricsEnabled,
                      enabled: securityController.biometricEnabled,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: securityController.biometricEnabled,
                        onChanged: securityController.busy
                            ? null
                            : (value) {
                                securityController.setBiometricEnabled(value);
                              },
                        title: Text(l10n.settingsUnlockWithBiometrics),
                        subtitle: Text(
                          securityController.canOfferBiometricToggle
                              ? l10n.settingsBiometricSupportedSubtitle(
                                  securityController
                                      .biometricAvailability
                                      .label,
                                )
                              : l10n.settingsBiometricUnavailableSubtitle,
                        ),
                      ),
                    ),
                    if (_biometricCapability.needsEnrollment) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _BiometricEnrollBanner(
                        title: l10n.biometricEnrollCta,
                        subtitle: l10n.biometricEnrollSubtitle,
                        actionLabel: l10n.biometricEnrollAction,
                        busy: _enrollingBiometric,
                        onAction: _openBiometricEnrollment,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: securityController.autoLockOnBackgroundEnabled,
                        onChanged: securityController.busy
                            ? null
                            : (value) {
                                securityController
                                    .setAutoLockOnBackgroundEnabled(value);
                              },
                        title: Text(l10n.settingsAutoLockBackgroundTitle),
                        subtitle: Text(l10n.settingsAutoLockBackgroundSubtitle),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<_IdleTimeoutPreset>(
                      key: ValueKey<int>(securityController.idleTimeoutSeconds),
                      initialValue: _resolveIdlePreset(
                        securityController.idleTimeoutSeconds,
                        idleTimeoutPresets,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.settingsIdleTimeoutLabel,
                      ),
                      items: idleTimeoutPresets
                          .map(
                            (preset) => DropdownMenuItem<_IdleTimeoutPreset>(
                              value: preset,
                              child: Text(
                                '${preset.label} - ${preset.description}',
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: securityController.busy
                          ? null
                          : (preset) {
                              if (preset == null) {
                                return;
                              }
                              securityController.setIdleTimeoutSeconds(
                                preset.seconds,
                              );
                            },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: securityController.busy
                                ? null
                                : securityController.lock,
                            icon: const Icon(Icons.lock_rounded),
                            label: Text(l10n.settingsLockNow),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: securityController.busy
                                ? null
                                : () {
                                    _openChangeMasterPasswordDialog(context);
                                  },
                            icon: const Icon(Icons.password_rounded),
                            label: Text(l10n.settingsChangeMasterPassword),
                          ),
                        ),
                      ],
                    ),
                    if (securityController.message case final message?) ...[
                      const SizedBox(height: AppSpacing.md),
                      AppBanner(
                        message: message,
                        tone: securityController.messageIsError
                            ? AppBannerTone.danger
                            : AppBannerTone.info,
                        icon: securityController.messageIsError
                            ? Icons.error_outline_rounded
                            : Icons.info_outline_rounded,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          if (widget.conflictResolver != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppPanel(
              child: FutureBuilder<List<SyncConflictRecord>>(
                future: _conflictsFuture,
                builder: (context, snapshot) {
                  final conflicts =
                      snapshot.data ?? const <SyncConflictRecord>[];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.settingsConflictsTitle,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.settingsConflictsRefresh,
                            onPressed: _refreshConflicts,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      if (snapshot.connectionState != ConnectionState.done)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                          child: LinearProgressIndicator(),
                        )
                      else if (snapshot.hasError)
                        _InlineLoadError(
                          message: l10n.settingsConflictsLoadError,
                          retryLabel: l10n.retry,
                          onRetry: _refreshConflicts,
                        )
                      else if (conflicts.isEmpty)
                        Text(
                          l10n.settingsConflictsEmpty,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      else
                        for (final conflict in conflicts) ...[
                          _SyncConflictCard(
                            conflict: conflict,
                            onKeepLocal: () {
                              _resolveConflict(
                                context,
                                conflict,
                                SyncConflictResolution.keepLocal,
                              );
                            },
                            onKeepRemote: () {
                              _resolveConflict(
                                context,
                                conflict,
                                SyncConflictResolution.keepRemote,
                              );
                            },
                          ),
                          if (conflict != conflicts.last)
                            const SizedBox(height: AppSpacing.sm),
                        ],
                    ],
                  );
                },
              ),
            ),
          ],
          if (widget.revocationService != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppPanel(
              child: FutureBuilder<List<DeviceSessionView>>(
                future: _devicesFuture,
                builder: (context, snapshot) {
                  final devices = snapshot.data ?? const <DeviceSessionView>[];
                  DeviceSessionView? currentDevice;
                  for (final device in devices) {
                    if (device.isCurrentDevice) {
                      currentDevice = device;
                      break;
                    }
                  }
                  final currentDeviceRevoked =
                      currentDevice != null && currentDevice.isRevoked;

                  if (snapshot.connectionState == ConnectionState.done &&
                      currentDeviceRevoked &&
                      !_currentDeviceRevocationHandled) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) {
                        return;
                      }
                      final status = currentDevice!.status;
                      final reason = switch (status) {
                        DeviceSessionStatus.revokedAll =>
                          l10n.settingsRevokedAllBody,
                        _ => l10n.settingsCurrentDeviceRevokedBody,
                      };
                      _handleCurrentDeviceRevocation(
                        context,
                        status: status,
                        lockReason: reason,
                      );
                    });
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.settingsSessionsTitle,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.settingsSessionsRefresh,
                            onPressed: _refreshDevices,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        l10n.settingsSessionsSubtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      OutlinedButton.icon(
                        onPressed:
                            securityController.busy || _revocationInProgress
                            ? null
                            : () {
                                _revokeAllOtherDevices(context);
                              },
                        icon: const Icon(Icons.devices_fold_rounded),
                        label: Text(l10n.settingsRevokeOtherDevices),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (snapshot.connectionState != ConnectionState.done)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                          child: LinearProgressIndicator(),
                        )
                      else if (snapshot.hasError)
                        _InlineLoadError(
                          message: l10n.settingsSessionsLoadError,
                          retryLabel: l10n.retry,
                          onRetry: _refreshDevices,
                        )
                      else if (devices.isEmpty)
                        Text(
                          l10n.settingsNoDevices,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      else
                        for (final device in devices) ...[
                          _DeviceSessionCard(
                            title: device.deviceName ?? device.deviceId,
                            subtitle:
                                '${device.platform ?? '-'} - ${device.appVersion ?? '-'}',
                            seenAtLabel: _formatSeenAt(
                              context,
                              device.lastSeenAt,
                            ),
                            currentLabel: device.isCurrentDevice
                                ? l10n.settingsCurrentDeviceLabel
                                : null,
                            revoked: device.isRevoked,
                            statusCode: _statusCode(device.status),
                            revokeActionLabel: l10n.settingsRevokeDevice,
                            statusActiveLabel: l10n.settingsSessionStatusActive,
                            statusRevokedLabel:
                                l10n.settingsSessionStatusRevoked,
                            revokingInProgress: _revocationInProgress,
                            currentDeviceRevocationHint:
                                l10n.settingsDeviceRevokeHint,
                            onRevoke: device.isRevoked
                                ? null
                                : () {
                                    _revokeDevice(context, device);
                                  },
                          ),
                          if (device != devices.last)
                            const SizedBox(height: AppSpacing.sm),
                        ],
                    ],
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          UpdateSection(
            service: UpdateService(
              owner: 'Rene-Kuhm',
              repo: 'vaulta',
              storage: widget.secureStorage,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settingsRoadmapTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.settingsRoadmapNotes,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _CapabilityRow(
                  title: l10n.settingsSecureStorage,
                  enabled:
                      LocalEncryptedVaultRepository.securityPlan.secureStorage,
                ),
                _CapabilityRow(
                  title: l10n.settingsBiometricUnlock,
                  enabled: LocalEncryptedVaultRepository
                      .securityPlan
                      .biometricUnlock,
                ),
                _CapabilityRow(
                  title: l10n.settingsHardwareBackedKeys,
                  enabled: LocalEncryptedVaultRepository
                      .securityPlan
                      .hardwareBackedKeys,
                ),
                _CapabilityRow(
                  title: l10n.settingsVaultEncryptionReady,
                  enabled: LocalEncryptedVaultRepository
                      .securityPlan
                      .vaultEncryptionReady,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppPanel(
            child: AnimatedBuilder(
              animation: localeController,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.languageSectionTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    DropdownButtonFormField<Locale>(
                      key: ValueKey<String>(
                        localeController.locale?.languageCode ?? 'es',
                      ),
                      initialValue:
                          localeController.locale ?? const Locale('es'),
                      decoration: InputDecoration(
                        labelText: l10n.languageSelectorLabel,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: const Locale('es'),
                          child: Text(l10n.languageSpanish),
                        ),
                        DropdownMenuItem(
                          value: const Locale('en'),
                          child: Text(l10n.languageEnglish),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        localeController.setLocale(value);
                      },
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.crimson.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(
                          AppSpacing.radiusMd,
                        ),
                        border: Border.all(
                          color: AppColors.crimson.withValues(alpha: 0.28),
                        ),
                      ),
                      child: const Icon(
                        Icons.info_outline_rounded,
                        color: AppColors.crimsonBright,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        l10n.aboutTitle,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.aboutCreator,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.aboutAgency,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _IdleTimeoutPreset _resolveIdlePreset(
    int seconds,
    List<_IdleTimeoutPreset> presets,
  ) {
    for (final preset in presets) {
      if (preset.seconds == seconds) {
        return preset;
      }
    }
    return presets[2];
  }
}

class _InlineLoadError extends StatelessWidget {
  const _InlineLoadError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppBanner(
      message: message,
      tone: AppBannerTone.danger,
      icon: Icons.error_outline_rounded,
      action: FilledButton.tonalIcon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text(retryLabel),
      ),
    );
  }
}

class _IdleTimeoutPreset {
  const _IdleTimeoutPreset({
    required this.seconds,
    required this.label,
    required this.description,
  });
  final int seconds;
  final String label;
  final String description;
}

class _SyncConflictCard extends StatelessWidget {
  const _SyncConflictCard({
    required this.conflict,
    required this.onKeepLocal,
    required this.onKeepRemote,
  });

  final SyncConflictRecord conflict;
  final VoidCallback onKeepLocal;
  final VoidCallback onKeepRemote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expectedVersion = conflict.expectedVersion?.toString() ?? 'unknown';
    final remoteVersion = conflict.currentVersion?.toString() ?? 'unknown';
    final subtitle =
        conflict.message ?? context.l10n.settingsConflictsReasonFallback;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        color: AppColors.warning.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sync_problem_rounded, color: AppColors.warning),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  conflict.localRecordId,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            context.l10n.settingsConflictsVersionRow(
              expectedVersion,
              remoteVersion,
            ),
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onKeepRemote,
                  icon: const Icon(Icons.cloud_done_rounded),
                  label: Text(context.l10n.syncConflictKeepRemote),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onKeepLocal,
                  icon: const Icon(Icons.upload_rounded),
                  label: Text(context.l10n.syncConflictKeepLocal),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceSessionCard extends StatelessWidget {
  const _DeviceSessionCard({
    required this.title,
    required this.subtitle,
    required this.seenAtLabel,
    required this.revoked,
    required this.statusCode,
    required this.revokeActionLabel,
    required this.statusActiveLabel,
    required this.statusRevokedLabel,
    required this.revokingInProgress,
    required this.currentDeviceRevocationHint,
    this.currentLabel,
    this.onRevoke,
  });

  final String title;
  final String subtitle;
  final String seenAtLabel;
  final bool revoked;
  final String statusCode;
  final String? currentLabel;
  final String revokeActionLabel;
  final String statusActiveLabel;
  final String statusRevokedLabel;
  final bool revokingInProgress;
  final String currentDeviceRevocationHint;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        color: AppColors.crimson.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.crimson.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AppPill(
                label: revoked ? statusRevokedLabel : statusActiveLabel,
                tint: revoked ? AppPillTint.danger : AppPillTint.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(seenAtLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            context.l10n.settingsDeviceStatusLabel(statusCode),
            style: theme.textTheme.labelLarge?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (currentLabel case final label?) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppColors.crimsonBright,
              ),
            ),
            if (onRevoke != null) ...[
              const SizedBox(height: 4),
              Text(
                currentDeviceRevocationHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.warning,
                ),
              ),
            ],
          ],
          if (onRevoke != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: revokingInProgress ? null : onRevoke,
                icon: const Icon(Icons.block_rounded),
                label: Text(revokeActionLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.title, required this.enabled});
  final String title;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled
        ? AppColors.success
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(
              enabled
                  ? Icons.verified_user_rounded
                  : Icons.radio_button_unchecked,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
        ],
      ),
    );
  }
}

class _ChangeMasterPasswordDialog extends StatefulWidget {
  const _ChangeMasterPasswordDialog({required this.controller});
  final VaultSecurityController controller;

  @override
  State<_ChangeMasterPasswordDialog> createState() =>
      _ChangeMasterPasswordDialogState();
}

class _ChangeMasterPasswordDialogState
    extends State<_ChangeMasterPasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirmation = true;
  String? _formFeedback;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return AlertDialog(
      title: Text(context.l10n.changeMasterPasswordTitle),
      content: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _currentController,
                  obscureText: _obscureCurrent,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.changeMasterPasswordCurrent,
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscureCurrent = !_obscureCurrent;
                        });
                      },
                      icon: Icon(
                        _obscureCurrent
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _newController,
                  obscureText: _obscureNew,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.changeMasterPasswordNew,
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscureNew = !_obscureNew;
                        });
                      },
                      icon: Icon(
                        _obscureNew
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _confirmationController,
                  obscureText: _obscureConfirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.changeMasterPasswordConfirm,
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscureConfirmation = !_obscureConfirmation;
                        });
                      },
                      icon: Icon(
                        _obscureConfirmation
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  context.l10n.changeMasterPasswordHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_formFeedback case final feedback?) ...[
                  const SizedBox(height: AppSpacing.sm),
                  AppBanner(
                    message: feedback,
                    tone: AppBannerTone.danger,
                    icon: Icons.error_outline_rounded,
                  ),
                ],
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: controller.busy
              ? null
              : () {
                  Navigator.of(context).pop();
                },
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: controller.busy ? null : _submit,
          child: controller.busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.apply),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _formFeedback = null;
    });

    final changed = await widget.controller.changeMasterPassword(
      currentPassword: _currentController.text,
      newPassword: _newController.text,
      confirmation: _confirmationController.text,
    );

    if (!mounted) {
      return;
    }

    if (changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.masterPasswordUpdatedSuccess)),
      );
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      // A throttled attempt leaves `message` null; explain the lockout
      // (or the secure-storage failure) in the user's language.
      _formFeedback =
          widget.controller.message ??
          unlockThrottleMessage(context.l10n, widget.controller) ??
          context.l10n.changeMasterPasswordErrorFallback;
    });
  }
}

class _BiometricEnrollBanner extends StatelessWidget {
  const _BiometricEnrollBanner({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.busy,
    required this.onAction,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final bool busy;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return AppBanner(
      message: '$title\n$subtitle',
      tone: AppBannerTone.warning,
      icon: Icons.fingerprint_rounded,
      action: FilledButton.icon(
        onPressed: busy ? null : onAction,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.open_in_new_rounded, size: 18),
        label: Text(actionLabel),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          minimumSize: const Size(0, 40),
        ),
      ),
    );
  }
}
