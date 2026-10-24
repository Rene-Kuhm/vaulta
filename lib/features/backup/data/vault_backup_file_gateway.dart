import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../../core/security/vault_backup_service.dart';

/// A `.vaulta` file picked by the user, read fully into memory.
class VaultBackupPickedFile {
  /// Builds a picked file.
  const VaultBackupPickedFile({required this.name, required this.bytes});

  /// Display name of the file.
  final String name;

  /// Raw envelope bytes (ciphertext; safe to hold in memory).
  final Uint8List bytes;
}

/// Platform file I/O for backups. Only ever handles the sealed
/// envelope, never plaintext. Abstracted so widget tests do not touch
/// platform channels.
abstract interface class VaultBackupFileGateway {
  /// Asks the user where to save [bytes] under the suggested
  /// [fileName]. [fileExtension] (without the dot) is the extension the
  /// platform save dialog filters on; it defaults to the encrypted
  /// `.vaulta` backup so existing callers keep their exact behavior.
  /// Returns false when the user cancelled.
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    String fileExtension = VaultBackupService.fileExtension,
  });

  /// Lets the user pick a backup file. Returns `null` when cancelled.
  /// Throws [VaultBackupException] with [VaultBackupFailure.malformed]
  /// when the file is empty, unreadable or larger than
  /// [VaultBackupService.maxEnvelopeBytes].
  Future<VaultBackupPickedFile?> pick();
}

/// [VaultBackupFileGateway] backed by `file_picker`: the Storage Access
/// Framework (`ACTION_CREATE_DOCUMENT` / `ACTION_OPEN_DOCUMENT`) on
/// Android, the native save/open dialogs on desktop.
class FilePickerVaultBackupFileGateway implements VaultBackupFileGateway {
  /// Builds the gateway.
  const FilePickerVaultBackupFileGateway();

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    String fileExtension = VaultBackupService.fileExtension,
  }) async {
    // On Android the plugin writes [bytes] to the SAF document the user
    // creates; on desktop it writes them to the chosen path.
    final path = await FilePicker.saveFile(
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [fileExtension],
      bytes: bytes,
    );
    return path != null;
  }

  @override
  Future<VaultBackupPickedFile?> pick() async {
    // `.vaulta` has no registered MIME type, so Android cannot filter
    // by it; the content is validated by VaultBackupService instead.
    final result = await FilePicker.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid
          ? null
          : const [VaultBackupService.fileExtension],
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    final file = result.files.single;
    if (file.size > VaultBackupService.maxEnvelopeBytes) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    var bytes = file.bytes;
    if ((bytes == null || bytes.isEmpty) && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } on FileSystemException {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    return VaultBackupPickedFile(name: file.name, bytes: bytes);
  }
}
