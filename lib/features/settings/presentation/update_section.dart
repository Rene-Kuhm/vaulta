import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/update/update_service.dart';
import '../../../l10n/app_localizations.dart';

/// Maps an error thrown by [UpdateService] to the text shown to the
/// user. Verification failures get a dedicated localized message;
/// anything else falls back to the error's own description.
String localizedUpdateError(AppLocalizations l10n, Object error) {
  if (error is UpdateVerificationException) {
    switch (error.failure) {
      case UpdateVerificationFailure.checksumMissing:
        return l10n.updateChecksumMissing;
      case UpdateVerificationFailure.checksumMismatch:
        return l10n.updateChecksumMismatch;
      case UpdateVerificationFailure.signatureMismatch:
        return l10n.updateSignatureMismatch;
    }
  }
  return error.toString();
}

/// Settings subsection that owns the in-app update flow: queries
/// [UpdateService] for a new build, exposes a download + install
/// button, and renders the corresponding banners. Localized to the
/// current locale via [l10n].
class UpdateSection extends StatefulWidget {
  /// Builds the update section. [service] is the only required
  /// dependency; everything else is read from the [BuildContext]
  /// and the [l10n] extension.
  const UpdateSection({super.key, required this.service});

  /// Service used to query the release feed, download the APK, and
  /// open the platform install prompt.
  final UpdateService service;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

enum _UpdateState {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  installing,
  failed,
}

class _UpdateSectionState extends State<UpdateSection> {
  _UpdateState _state = _UpdateState.idle;
  String? _errorMessage;
  UpdateInfo? _info;
  String _currentVersion = '…';
  bool _devChannel = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentVersion());
    unawaited(_loadReleaseChannel());
  }

  Future<void> _loadReleaseChannel() async {
    final channel = await widget.service.releaseChannel();
    if (!mounted) return;
    setState(() => _devChannel = channel == UpdateReleaseChannel.dev);
  }

  Future<void> _setDevChannel(bool enabled) async {
    await widget.service.setReleaseChannel(
      enabled ? UpdateReleaseChannel.dev : UpdateReleaseChannel.stable,
    );
    if (!mounted) return;
    // The previous result belongs to the other channel; force a new
    // check instead of offering a stale download.
    setState(() {
      _devChannel = enabled;
      _state = _UpdateState.idle;
      _info = null;
      _errorMessage = null;
    });
  }

  Future<void> _loadCurrentVersion() async {
    final v = await widget.service.currentVersion();
    if (!mounted) return;
    setState(() => _currentVersion = v);
  }

  Future<void> _checkForUpdate() async {
    setState(() {
      _state = _UpdateState.checking;
      _errorMessage = null;
    });
    try {
      final info = await widget.service.checkForUpdate();
      if (!mounted) return;
      if (info.available) {
        setState(() {
          _state = _UpdateState.updateAvailable;
          _info = info;
        });
      } else {
        setState(() {
          _state = _UpdateState.upToDate;
          _info = info;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.failed;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _state = _UpdateState.downloading;
      _errorMessage = null;
    });
    try {
      final path = await widget.service.downloadApk(info);
      if (!mounted) return;
      setState(() => _state = _UpdateState.installing);
      final ok = await widget.service.openInstallPrompt(path);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _state = _UpdateState.failed;
          _errorMessage = context.l10n.updateInstallerFailed;
        });
        return;
      }
      await widget.service.markBuildPrompted(info);
      setState(() => _state = _UpdateState.idle);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.failed;
        _errorMessage = localizedUpdateError(context.l10n, error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.updateTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _VersionRow(
            label: l10n.updateInstalled,
            value: _currentVersion,
            highlighted: _state == _UpdateState.upToDate,
          ),
          if (_info != null && (_info!.tagName.isNotEmpty)) ...[
            const SizedBox(height: AppSpacing.xxs),
            _VersionRow(
              label: l10n.updateRemote,
              value:
                  '${_info!.tagName} (${l10n.updateReleaseId(_info!.releaseId)})',
              highlighted: _state == _UpdateState.updateAvailable,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.updateDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _devChannel,
              onChanged: _isBusy ? null : _setDevChannel,
              title: Text(l10n.updateDevChannelTitle),
              subtitle: Text(l10n.updateDevChannelSubtitle),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildAction(theme, l10n),
          if (_state == _UpdateState.upToDate) ...[
            const SizedBox(height: AppSpacing.md),
            _UpToDateBanner(),
          ],
          if (_state == _UpdateState.updateAvailable && _info != null) ...[
            const SizedBox(height: AppSpacing.md),
            _UpdateAvailablePanel(info: _info!),
          ],
          if (_state == _UpdateState.failed && _errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            _ErrorBanner(message: _errorMessage!),
          ],
        ],
      ),
    );
  }

  bool get _isBusy =>
      _state == _UpdateState.checking ||
      _state == _UpdateState.downloading ||
      _state == _UpdateState.installing;

  Widget _buildAction(ThemeData theme, AppLocalizations l10n) {
    switch (_state) {
      case _UpdateState.idle:
      case _UpdateState.upToDate:
        return FilledButton.icon(
          onPressed: _checkForUpdate,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(l10n.updateCheck),
        );
      case _UpdateState.checking:
        return _BusyButton(label: l10n.updateChecking);
      case _UpdateState.updateAvailable:
        return FilledButton.icon(
          onPressed: _downloadAndInstall,
          icon: const Icon(Icons.download_rounded),
          label: Text(l10n.updateDownload),
        );
      case _UpdateState.downloading:
        return _BusyButton(label: l10n.updateDownloading);
      case _UpdateState.installing:
        return _BusyButton(label: l10n.updateInstalling);
      case _UpdateState.failed:
        return FilledButton.icon(
          onPressed: _checkForUpdate,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(l10n.updateRetry),
        );
    }
  }
}

class _BusyButton extends StatelessWidget {
  const _BusyButton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: null,
      icon: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      label: Text(label),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.label,
    required this.value,
    this.highlighted = false,
  });

  final String label;
  final String value;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: highlighted
                  ? AppColors.crimsonBright
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _UpdateAvailablePanel extends StatelessWidget {
  const _UpdateAvailablePanel({required this.info});
  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final changelog = info.changelog.trim();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.crimson.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: AppColors.crimson.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.system_update_alt_rounded,
                color: AppColors.crimsonBright,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  l10n.updateAvailableVersion(info.tagName),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (changelog.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              changelog,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _UpToDateBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppBanner(
      tone: AppBannerTone.success,
      icon: Icons.check_circle_outline_rounded,
      message: '${l10n.updateUpToDateTitle} - ${l10n.updateUpToDateBody}',
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.danger),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  l10n.updateErrorTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppColors.danger,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
