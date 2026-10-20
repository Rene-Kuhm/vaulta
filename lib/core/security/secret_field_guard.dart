import 'package:flutter/material.dart';

/// Context-menu buttons a secret input field may show. Everything
/// else is dropped: Copy and Cut (they write to the plain clipboard,
/// without the sensitive flag or auto-clear), Share, Look Up, Search
/// Web, and the Android PROCESS_TEXT actions (Translate, etc., which
/// Flutter adds as [ContextMenuButtonType.custom]) that hand the
/// selected secret to another app.
const Set<ContextMenuButtonType> secretFieldAllowedMenuButtons = {
  ContextMenuButtonType.paste,
  ContextMenuButtonType.selectAll,
};

/// [EditableText.contextMenuBuilder] for fields that hold a secret.
/// Shows only the buttons in [secretFieldAllowedMenuButtons].
Widget secretFieldContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final items = editableTextState.contextMenuButtonItems
      .where((item) => secretFieldAllowedMenuButtons.contains(item.type))
      .toList();
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: items,
  );
}

/// Wraps a secret input field so keyboard copy and cut (Ctrl/Cmd+C,
/// Ctrl/Cmd+X) do nothing. Combine with
/// [secretFieldContextMenuBuilder] so the toolbar cannot copy either.
class SecretFieldCopyBlocker extends StatelessWidget {
  /// Blocks copy/cut shortcuts for the text field inside [child].
  const SecretFieldCopyBlocker({super.key, required this.child});

  /// The secret text field.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: DoNothingAction(),
      },
      child: child,
    );
  }
}
