import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/secret_field_guard.dart';
import '../domain/vault_item.dart';

/// Form screen used both to create a new [VaultItem] and to edit an
/// existing one. Includes a built-in password generator with
/// character-class toggles and a length slider.
/// Form screen used both to create a new [VaultItem] and to edit an
/// existing one. Includes a built-in password generator with
/// character-class toggles and a length slider.
class VaultEntryEditorScreen extends StatefulWidget {
  /// Builds the editor. When [initialItem] is `null`, the screen is
  /// in "create" mode; otherwise the fields are pre-filled with the
  /// entry's data.
  const VaultEntryEditorScreen({super.key, this.initialItem});

  /// When `null`, the screen is in "create" mode; otherwise the
  /// fields are pre-filled with this entry's data.
  final VaultItem? initialItem;

  /// `true` when the screen is editing an existing entry (i.e.
  /// [initialItem] is not `null`). Drives the AppBar title and the
  /// primary button label.
  bool get isEditing => initialItem != null;

  @override
  State<VaultEntryEditorScreen> createState() => _VaultEntryEditorScreenState();
}

class _VaultEntryEditorScreenState extends State<VaultEntryEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final Random _random = Random.secure();

  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _secretController;
  late final TextEditingController _websiteController;
  late final TextEditingController _notesController;

  late VaultCategory _category;
  bool _obscureSecret = true;
  double _generatedLength = 16;
  bool _includeUppercase = true;
  bool _includeLowercase = true;
  bool _includeNumbers = true;
  bool _includeSymbols = true;

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _titleController = TextEditingController(text: item?.title ?? '');
    _usernameController = TextEditingController(text: item?.username ?? '');
    _secretController = TextEditingController(text: item?.secret ?? '');
    _websiteController = TextEditingController(text: item?.website ?? '');
    _notesController = TextEditingController(text: item?.notes ?? '');
    _category = item?.category ?? VaultCategory.personal;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _secretController.dispose();
    _websiteController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.isEditing ? l10n.editorTitleEdit : l10n.editorTitleNew,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppSectionHeader(
                        eyebrow: l10n.editorIdentityTitle,
                        title: l10n.editorIdentityTitle,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _titleController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.editorTitleLabel,
                          hintText: l10n.editorTitleHint,
                          prefixIcon: const Icon(Icons.title_rounded),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return l10n.editorTitleValidation;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _usernameController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.editorUsernameLabel,
                          prefixIcon: const Icon(Icons.person_rounded),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return l10n.editorUsernameValidation;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      DropdownButtonFormField<VaultCategory>(
                        initialValue: _category,
                        decoration: InputDecoration(
                          labelText: l10n.editorCategoryLabel,
                          prefixIcon: const Icon(Icons.category_rounded),
                        ),
                        items: VaultCategory.values
                            .map(
                              (category) => DropdownMenuItem(
                                value: category,
                                child: Text(
                                  category.localizedLabel(context),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _category = value);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.editorSecretTitle,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        l10n.editorSecretDescription,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SecretFieldCopyBlocker(
                        child: TextFormField(
                          controller: _secretController,
                          obscureText: _obscureSecret,
                          // No Copy/Cut/Share/Translate on the secret; see
                          // secret_field_guard.dart.
                          contextMenuBuilder: secretFieldContextMenuBuilder,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: l10n.editorSecretLabel,
                            prefixIcon: const Icon(Icons.password_rounded),
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(
                                  () => _obscureSecret = !_obscureSecret,
                                );
                              },
                              icon: Icon(
                                _obscureSecret
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
                              ),
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return l10n.editorSecretRequiredValidation;
                            }
                            if (value.trim().length < 8) {
                              return l10n.editorSecretMinValidation;
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppColors.crimson.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.radiusLg,
                          ),
                          border: Border.all(
                            color: AppColors.crimson.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.auto_awesome_rounded,
                                  color: AppColors.crimsonBright,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Expanded(
                                  child: Text(
                                    l10n.editorGeneratorTitle,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                                Text(
                                  l10n.editorGeneratorChars(
                                    _generatedLength.round(),
                                  ),
                                  style: theme.textTheme.labelLarge,
                                ),
                              ],
                            ),
                            Slider(
                              min: 8,
                              max: 32,
                              divisions: 24,
                              label: '${_generatedLength.round()}',
                              value: _generatedLength,
                              onChanged: (value) {
                                setState(() => _generatedLength = value);
                              },
                            ),
                            Wrap(
                              spacing: AppSpacing.xs,
                              runSpacing: AppSpacing.xs,
                              children: [
                                FilterChip(
                                  label: const Text('A-Z'),
                                  selected: _includeUppercase,
                                  onSelected: (selected) {
                                    setState(
                                      () => _includeUppercase = selected,
                                    );
                                  },
                                ),
                                FilterChip(
                                  label: const Text('a-z'),
                                  selected: _includeLowercase,
                                  onSelected: (selected) {
                                    setState(
                                      () => _includeLowercase = selected,
                                    );
                                  },
                                ),
                                FilterChip(
                                  label: const Text('0-9'),
                                  selected: _includeNumbers,
                                  onSelected: (selected) {
                                    setState(
                                      () => _includeNumbers = selected,
                                    );
                                  },
                                ),
                                FilterChip(
                                  label: const Text('#!?'),
                                  selected: _includeSymbols,
                                  onSelected: (selected) {
                                    setState(
                                      () => _includeSymbols = selected,
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            FilledButton.tonalIcon(
                              onPressed: _generateAndInsertPassword,
                              icon: const Icon(Icons.auto_awesome_rounded),
                              label: Text(l10n.editorGenerateInsert),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _websiteController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.editorWebsiteLabel,
                          hintText: l10n.editorWebsiteHint,
                          prefixIcon: const Icon(Icons.link_rounded),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _notesController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: InputDecoration(
                          labelText: l10n.editorNotesLabel,
                          hintText: l10n.editorNotesHint,
                          prefixIcon: const Padding(
                            padding: EdgeInsets.only(bottom: 56),
                            child: Icon(Icons.notes_rounded),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.lock_rounded),
                    label: Text(
                      widget.isEditing
                          ? l10n.editorSaveChanges
                          : l10n.editorCreateEntry,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final baseItem = widget.initialItem;
    final now = DateTime.now();
    final secret = _secretController.text.trim();
    final item = VaultItem(
      id: baseItem?.id ?? 'entry-${now.microsecondsSinceEpoch}',
      title: _titleController.text.trim(),
      username: _usernameController.text.trim(),
      secret: secret,
      category: _category,
      strengthScore: estimatePasswordStrength(secret),
      lastUpdatedLabel: formatVaultUpdatedLabel(now, now: now),
      website: _normalizeOptional(_websiteController.text),
      notes: _normalizeOptional(_notesController.text),
      updatedAt: now,
    );

    Navigator.of(context).pop(item);
  }

  void _generateAndInsertPassword() {
    final generated = _generatePassword(
      length: _generatedLength.round(),
      includeUppercase: _includeUppercase,
      includeLowercase: _includeLowercase,
      includeNumbers: _includeNumbers,
      includeSymbols: _includeSymbols,
    );

    if (generated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.editorGeneratorSetRequired)),
      );
      return;
    }

    _secretController
      ..text = generated
      ..selection = TextSelection.collapsed(offset: generated.length);

    setState(() => _obscureSecret = true);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.editorGeneratedInserted)),
    );
  }

  String? _generatePassword({
    required int length,
    required bool includeUppercase,
    required bool includeLowercase,
    required bool includeNumbers,
    required bool includeSymbols,
  }) {
    const uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lowercase = 'abcdefghijkmnopqrstuvwxyz';
    const numbers = '23456789';
    const symbols = '!@#%^&*()-_=+[]{}:,.?/';

    final sets = <String>[
      if (includeUppercase) uppercase,
      if (includeLowercase) lowercase,
      if (includeNumbers) numbers,
      if (includeSymbols) symbols,
    ];

    if (sets.isEmpty) {
      return null;
    }

    final allChars = sets.join();
    final chars = <String>[];

    for (final set in sets) {
      chars.add(set[_random.nextInt(set.length)]);
    }

    while (chars.length < length) {
      chars.add(allChars[_random.nextInt(allChars.length)]);
    }

    for (var i = chars.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final temp = chars[i];
      chars[i] = chars[j];
      chars[j] = temp;
    }

    return chars.join();
  }

  String? _normalizeOptional(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

extension on VaultCategory {
  String localizedLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (this) {
      VaultCategory.work => l10n.editorCategoryWork,
      VaultCategory.finance => l10n.editorCategoryFinance,
      VaultCategory.personal => l10n.editorCategoryPersonal,
      VaultCategory.infrastructure => l10n.editorCategoryInfrastructure,
    };
  }
}
