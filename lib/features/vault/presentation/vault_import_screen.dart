// ignore_for_file: prefer_const_constructors

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_repository.dart';
import '../../../core/security/vault_security_controller.dart';
import '../application/vault_duplicate_detector.dart';
import '../application/vault_import_models.dart';
import '../application/vault_import_parser.dart';
import '../domain/vault_item.dart';

/// Signature of the file picker the import screen uses, shaped after
/// `FilePicker.pickFiles` so tests can inject a fake instead of
/// opening the system dialog.
typedef VaultImportFilePicker =
    Future<FilePickerResult?> Function({
      required FileType type,
      List<String>? allowedExtensions,
    });

/// Modal screen that lets the user pick a CSV/JSON export from disk
/// and review the parsed [VaultImportPreview] before persisting the
/// new entries to the [VaultRepository].
/// Modal screen that lets the user pick a CSV/JSON export from disk
/// and review the parsed [VaultImportPreview] before persisting the
/// new entries to the [VaultRepository].
class VaultImportScreen extends StatefulWidget {
  /// Builds the import screen. [repository] and [existingItems] are
  /// required; [parser], [initialPreview], [securityController], and
  /// [pickFiles] are optional. The default [parser] is a stock
  /// [VaultImportParser]; [securityController] is needed to keep the
  /// auto-lock from firing while the system file picker holds the
  /// foreground; [pickFiles] defaults to the platform picker and is
  /// overridable so widget tests do not need the real dialog.
  const VaultImportScreen({
    super.key,
    required this.repository,
    required this.existingItems,
    VaultImportParser? parser,
    this.initialPreview,
    this.securityController,
    this.pickFiles,
  }) : parser = parser ?? const _DefaultVaultImportParser._();

  /// Vault repository used to persist confirmed candidates.
  final VaultRepository repository;

  /// Items already in the vault; used for duplicate detection.
  final List<VaultItem> existingItems;

  /// Parser implementation. Defaults to a stock [VaultImportParser].
  final VaultImportParser parser;

  /// Optional precomputed preview (for example, from a test harness).
  final VaultImportPreview? initialPreview;

  /// Optional controller. When provided, the screen asks it to stand
  /// down on the background auto-lock while the user is browsing
  /// the system file picker (which necessarily takes the foreground).
  /// The pause is released when the import finishes or the user
  /// backs out of the screen.
  final VaultSecurityController? securityController;

  /// Optional replacement for the platform file picker. `null` means
  /// the real one is used; tests inject a fake so they can drive the
  /// `.kdbx` unlock dialog without a native dialog.
  final VaultImportFilePicker? pickFiles;

  @override
  State<VaultImportScreen> createState() => _VaultImportScreenState();
}

class _VaultImportScreenState extends State<VaultImportScreen> {
  static const _duplicates = VaultDuplicateDetector();

  VaultImportPreview? _preview;
  String? _fileName;
  String? _error;
  bool _isPicking = false;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _preview = widget.initialPreview;
  }

  @override
  void dispose() {
    // Safety net for the rare case where the user backgrounds the app
    // or the screen is unmounted while a long-running flow counter is
    // still open. The controller's `lock()` already clamps the stack
    // to zero, but here we release eagerly so the very next
    // foreground loss resumes the normal auto-lock policy without
    // waiting for the user to lock the vault manually.
    widget.securityController?.endLongRunningFlow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final preview = _preview;
    final canImport = preview != null && preview.importableCount > 0;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          preview == null
              ? 'Importar credenciales'
              : 'Importar (${preview.importableCount})',
        ),
      ),
      body: AppHeroBackground(
        intensity: 0.55,
        child: SafeArea(
          bottom: canImport,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppSectionHeader(
                      eyebrow: 'IMPORTACION LOCAL',
                      title: 'Trae tus passwords a Vaulta',
                      subtitle:
                          'Carga CSV o JSON desde Notion, Chrome, Bitwarden, 1Password, LastPass, KeePass, Excel o Google Sheets, o una base KeePass .kdbx cifrada. Vaulta procesa el archivo localmente y cifra cada entrada al guardar.',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: const [
                        _ImportChip(label: 'CSV generico'),
                        _ImportChip(label: 'JSON'),
                        _ImportChip(label: 'Notion'),
                        _ImportChip(label: 'Chrome'),
                        _ImportChip(label: 'Bitwarden'),
                        _ImportChip(label: '1Password'),
                        _ImportChip(label: 'LastPass'),
                        _ImportChip(label: 'KeePass CSV'),
                        _ImportChip(label: 'KeePass KDBX'),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton.icon(
                      onPressed: _isPicking ? null : _pickFile,
                      icon: _isPicking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_rounded),
                      label: Text(
                        _isPicking ? 'Leyendo archivo...' : 'Elegir archivo',
                      ),
                    ),
                    if (_fileName != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _fileName!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      AppBanner(
                        message: _error!,
                        icon: Icons.error_outline_rounded,
                        tone: AppBannerTone.danger,
                      ),
                    ],
                  ],
                ),
              ),
              if (preview != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _ImportPreviewPanel(preview: preview),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: canImport
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Material(
                color: Colors.transparent,
                child: FilledButton.icon(
                  onPressed: _isImporting ? null : _confirmImport,
                  icon: _isImporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_rounded),
                  label: Text(
                    _isImporting
                        ? 'Importando...'
                        : 'Importar ${preview.importableCount} entradas',
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Future<void> _pickFile() async {
    setState(() {
      _isPicking = true;
      _error = null;
    });

    // The system file picker takes the foreground away from Flutter,
    // which trips the controller's `handleAppLifecycleState(inactive)`
    // branch and locks the vault mid-flow. We pause the auto-lock
    // for the duration of the pick so the user comes back to a
    // still-unlocked session. The pause is released by the finally
    // block below no matter how the pick ends.
    widget.securityController?.beginLongRunningFlow();

    FilePickerResult? result;
    try {
      result = await _pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'json', 'kdbx'],
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isPicking = false;
        _error = 'No pudimos abrir el selector de archivos: $error';
      });
      return;
    } finally {
      widget.securityController?.endLongRunningFlow();
    }

    if (!mounted) return;

    if (result == null || result.files.isEmpty) {
      setState(() {
        _isPicking = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccion cancelada.')),
      );
      return;
    }

    final file = result.files.single;
    final bytes = await _readPickedFileBytes(file);
    if (!mounted) return;

    if (bytes.isEmpty) {
      setState(() {
        _isPicking = false;
        _error = 'El archivo seleccionado esta vacio o no se pudo leer. '
            'Proba con otro archivo o reinicia la app.';
      });
      return;
    }

    // A KeePass database is encrypted binary: it cannot be decoded as
    // text, so it needs the master password (and optionally a key file)
    // before the parser can produce a preview.
    final isKdbx = widget.parser.isKdbxFile(fileName: file.name, bytes: bytes);
    final VaultImportPreview preview;
    if (isKdbx) {
      final credentials = await _askKdbxCredentials(file.name);
      if (credentials == null) {
        if (!mounted) return;
        setState(() {
          _isPicking = false;
        });
        return;
      }
      try {
        preview = await widget.parser.parseBytes(
          fileName: file.name,
          bytes: bytes,
          existingItems: widget.existingItems,
          masterPassword: credentials.password,
          keyFileBytes: credentials.keyFileBytes,
        );
      } on VaultImportException catch (error) {
        if (!mounted) return;
        setState(() {
          _isPicking = false;
          _fileName = file.name;
          // Drop the previous preview: importing it after a failed
          // unlock would attach the wrong file to the user's choice.
          _preview = null;
          _error = error.message;
        });
        // The password and the key file never leave this scope; they
        // are not logged, stored, or kept in state after the attempt.
        debugPrint(
          '[Vaulta/Import] kdbx unlock failed file=${file.name} '
          'bytes=${bytes.length} keyFile=${credentials.hasKeyFile}',
        );
        return;
      }
    } else {
      preview = widget.parser.parse(
        fileName: file.name,
        content: utf8.decode(bytes, allowMalformed: true),
        existingItems: widget.existingItems,
      );
    }
    if (!mounted) return;

    debugPrint(
      '[Vaulta/Import] preview file=${file.name} bytes=${bytes.length} '
      'source=${preview.source.name} candidates=${preview.candidates.length} '
      'importable=${preview.importableCount} duplicates=${preview.duplicateCount} '
      'rejected=${preview.rejectedCount}',
    );

    setState(() {
      _fileName = file.name;
      _preview = preview;
      _isPicking = false;
    });

    if (preview.importableCount == 0 && preview.rejected.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No se detectaron entradas validas. '
            'Revisa que el archivo tenga titulo y password reconocibles.',
          ),
        ),
      );
    }
  }

  Future<FilePickerResult?> _pickFiles({
    required FileType type,
    List<String>? allowedExtensions,
  }) {
    final injected = widget.pickFiles;
    if (injected != null) {
      return injected(type: type, allowedExtensions: allowedExtensions);
    }
    return FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      withData: true,
    );
  }

  Future<Uint8List> _readPickedFileBytes(PlatformFile file) async {
    final inMemoryBytes = file.bytes;
    if (inMemoryBytes != null && inMemoryBytes.isNotEmpty) {
      return inMemoryBytes;
    }

    final path = file.path;
    if (path != null && path.isNotEmpty) {
      try {
        return await File(path).readAsBytes();
      } catch (error) {
        debugPrint('[Vaulta/Import] readAsBytes failed: $error');
      }
    }

    return Uint8List(0);
  }

  /// Asks for the master password (and an optional key file) of a
  /// KeePass `.kdbx` database. Returns `null` when the user cancels.
  Future<_KdbxCredentials?> _askKdbxCredentials(String fileName) {
    return showDialog<_KdbxCredentials>(
      context: context,
      // The password field is the only way forward: tapping outside
      // would leave the pick flow half done.
      barrierDismissible: false,
      builder: (dialogContext) => _KdbxCredentialsDialog(
        fileName: fileName,
        pickKeyFile: _pickKdbxKeyFile,
      ),
    );
  }

  /// Opens the system picker for the optional KeePass key file. The
  /// picker steals the foreground, so the auto-lock is paused exactly
  /// like it is around [_pickFile].
  Future<_PickedKeyFile?> _pickKdbxKeyFile() async {
    widget.securityController?.beginLongRunningFlow();
    try {
      final result = await _pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return null;
      final picked = result.files.single;
      final bytes = await _readPickedFileBytes(picked);
      if (bytes.isEmpty) return null;
      return _PickedKeyFile(name: picked.name, bytes: bytes);
    } catch (error) {
      debugPrint('[Vaulta/Import] key file pick failed: $error');
      return null;
    } finally {
      widget.securityController?.endLongRunningFlow();
    }
  }

  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null) return;

    setState(() {
      _isImporting = true;
      _error = null;
    });
    var imported = 0;
    var skippedDuplicates = 0;
    try {
      final existingItems = await widget.repository.fetchItems();
      final knownItems = List<VaultItem>.of(existingItems);
      debugPrint(
        '[Vaulta/Import] confirm candidates=${preview.candidates.length} '
        'existing=${existingItems.length}',
      );
      for (final candidate in preview.candidates) {
        if (!candidate.canImport) continue;
        final duplicate = _duplicates.findDuplicate(candidate.item, knownItems);
        if (duplicate != null) {
          skippedDuplicates++;
          continue;
        }
        await widget.repository.saveItem(candidate.item);
        knownItems.add(candidate.item);
        imported++;
      }
      if (!mounted) return;

      if (imported == 0) {
        setState(() {
          _isImporting = false;
          _error = skippedDuplicates > 0
              ? 'No se importaron entradas nuevas: todas ya existen en Vaulta.'
              : 'No se importaron entradas. Revisa que el archivo tenga titulo, usuario y password reconocibles.';
        });
        debugPrint(
          '[Vaulta/Import] finished imported=0 skippedDuplicates=$skippedDuplicates',
        );
        return;
      }
      debugPrint(
        '[Vaulta/Import] finished imported=$imported '
        'skippedDuplicates=$skippedDuplicates',
      );
      Navigator.of(context).pop(
        VaultImportResult(
          imported: imported,
          skippedDuplicates: skippedDuplicates,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final errorText = error.toString();
      final isSessionLocked =
          errorText.contains('Vault encryption key unavailable') ||
          errorText.contains('Unlock with the master password');
      setState(() {
        if (isSessionLocked) {
          _error =
              'Tu sesion de Vaulta esta bloqueada. Desbloquea con la master '
              'password para poder importar.';
        } else {
          _error = 'La importacion se interrumpio: $error';
        }
        _isImporting = false;
      });
      debugPrint(
        '[Vaulta/Import] aborted error=$error isSessionLocked=$isSessionLocked',
      );
      if (isSessionLocked && mounted) {
        // Pop back to the dashboard so the security gate can take over
        // and prompt the user to unlock with the master password. The
        // selected preview is discarded on purpose: the user's
        // decision to import has to be retaken after unlock, with a
        // fresh session in memory.
        final navigator = Navigator.of(context);
        navigator.pop<VaultImportResult>(null);
      }
    }
  }
}

class _DefaultVaultImportParser extends VaultImportParser {
  const _DefaultVaultImportParser._();
}

/// Key file picked by the user for a KeePass database.
class _PickedKeyFile {
  /// Creates the value. [bytes] stay in memory for the single unlock
  /// attempt and are never written anywhere.
  const _PickedKeyFile({required this.name, required this.bytes});

  /// File name, shown in the dialog so the user can check it.
  final String name;

  /// Raw key file contents.
  final Uint8List bytes;
}

/// Master password plus optional key file collected for a `.kdbx`
/// import. Deliberately not stored outside the unlock attempt: the
/// dialog clears the text field and this object is dropped as soon as
/// the parser returns.
class _KdbxCredentials {
  const _KdbxCredentials({
    required this.password,
    this.keyFileBytes,
  });

  final String password;
  final Uint8List? keyFileBytes;

  bool get hasKeyFile => keyFileBytes != null;
}

/// Dialog that asks for the master password (and optional key file) of
/// a KeePass `.kdbx` database before the import preview is built.
///
/// Pops with a [_KdbxCredentials] when the user confirms, and `null`
/// when the user cancels.
class _KdbxCredentialsDialog extends StatefulWidget {
  const _KdbxCredentialsDialog({
    required this.fileName,
    required this.pickKeyFile,
  });

  final String fileName;
  final Future<_PickedKeyFile?> Function() pickKeyFile;

  @override
  State<_KdbxCredentialsDialog> createState() => _KdbxCredentialsDialogState();
}

class _KdbxCredentialsDialogState extends State<_KdbxCredentialsDialog> {
  final _passwordController = TextEditingController();
  _PickedKeyFile? _keyFile;
  bool _obscure = true;
  bool _pickingKeyFile = false;
  String? _feedback;

  @override
  void dispose() {
    // The typed password does not survive the dialog.
    _passwordController.clear();
    _passwordController.dispose();
    _keyFile = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Base KeePass .kdbx'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'La base ${widget.fileName} esta cifrada. Escribí su '
              'contraseña maestra para leerla: Vaulta la usa solo en '
              'memoria y no la guarda.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('import.kdbx.masterPassword'),
              controller: _passwordController,
              obscureText: _obscure,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                labelText: 'Contraseña maestra',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _keyFile == null
                        ? 'Archivo de llave (opcional)'
                        : _keyFile!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_keyFile != null)
                  IconButton(
                    tooltip: 'Quitar archivo de llave',
                    onPressed: _pickingKeyFile
                        ? null
                        : () => setState(() => _keyFile = null),
                    icon: const Icon(Icons.close_rounded),
                  ),
                TextButton.icon(
                  key: const Key('import.kdbx.pickKeyFile'),
                  onPressed: _pickingKeyFile ? null : _pickKeyFile,
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: Text(_keyFile == null ? 'Elegir' : 'Cambiar'),
                ),
              ],
            ),
            if (_feedback case final feedback?) ...[
              const SizedBox(height: AppSpacing.sm),
              AppBanner(
                message: feedback,
                icon: Icons.error_outline_rounded,
                tone: AppBannerTone.danger,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('import.kdbx.confirm'),
          onPressed: _confirm,
          child: const Text('Abrir base'),
        ),
      ],
    );
  }

  Future<void> _pickKeyFile() async {
    setState(() {
      _pickingKeyFile = true;
      _feedback = null;
    });
    final picked = await widget.pickKeyFile();
    if (!mounted) return;
    setState(() {
      _pickingKeyFile = false;
      if (picked != null) _keyFile = picked;
    });
  }

  void _confirm() {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() {
        _feedback = 'Escribí la contraseña maestra del archivo .kdbx.';
      });
      return;
    }
    final credentials = _KdbxCredentials(
      password: password,
      keyFileBytes: _keyFile?.bytes,
    );
    Navigator.of(context).pop(credentials);
  }
}

class _ImportChip extends StatelessWidget {
  const _ImportChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      avatar: const Icon(Icons.check_rounded, size: 16),
    );
  }
}

class _ImportPreviewPanel extends StatelessWidget {
  const _ImportPreviewPanel({required this.preview});

  final VaultImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = preview.candidates.take(25).toList(growable: false);

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            eyebrow: preview.source.label.toUpperCase(),
            title: 'Vista previa',
            subtitle:
                '${preview.importableCount} listas para importar, ${preview.duplicateCount} duplicadas, ${preview.rejectedCount} rechazadas.',
          ),
          const SizedBox(height: AppSpacing.md),
          if (preview.rejected.isNotEmpty)
            AppBanner(
              message:
                  'Algunas filas no se pueden importar porque no tienen campos reconocibles.',
              icon: Icons.report_problem_rounded,
              tone: AppBannerTone.warning,
            ),
          if (preview.rejected.isNotEmpty)
            const SizedBox(height: AppSpacing.md),
          for (final candidate in candidates) ...[
            _ImportCandidateTile(candidate: candidate),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (preview.candidates.length > candidates.length)
            Text(
              'Mostrando 25 de ${preview.candidates.length} entradas detectadas.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _ImportCandidateTile extends StatelessWidget {
  const _ImportCandidateTile({required this.candidate});

  final VaultImportCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = candidate.item;
    final statusColor = candidate.canImport
        ? AppColors.success
        : (candidate.isDuplicate ? AppColors.warning : AppColors.danger);
    final statusLabel = candidate.canImport
        ? 'Lista'
        : (candidate.isDuplicate ? 'Duplicada' : 'Revisar');

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: item.accentColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: Icon(item.icon, color: item.accentColor, size: 21),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (item.username.isNotEmpty) item.username,
                    if (item.website != null) item.website!,
                    item.category.label,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (candidate.issues.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    candidate.issues.map((issue) => issue.message).join(' '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                ],
                if (candidate.duplicateReason != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    candidate.duplicateReason!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
