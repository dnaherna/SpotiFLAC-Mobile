import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/mime_utils.dart';

const _settingsKey = 'app_settings';

/// Regular expression to detect iOS app container paths.
/// Matches paths like /var/mobile/Containers/Data/Application/{UUID}
/// or /private/var/mobile/Containers/Data/Application/{UUID}
final _iosContainerRootPattern = RegExp(
  r'^(/private)?/var/mobile/Containers/Data/Application/[A-F0-9\-]+/?$',
  caseSensitive: false,
);
final _iosContainerPathWithoutLeadingSlashPattern = RegExp(
  r'^(private/)?var/mobile/Containers/Data/Application/[A-F0-9\-]+/.+',
  caseSensitive: false,
);
final _iosLegacyRelativeDocumentsPattern = RegExp(
  r'^Data/Application/[A-F0-9\-]+/Documents(?:/(.*))?$',
  caseSensitive: false,
);
final _iosNestedLegacyDocumentsPattern = RegExp(
  r'/Documents/Data/Application/[A-F0-9\-]+/Documents(?:/(.*))?$',
  caseSensitive: false,
);

String _normalizeRecoveredIosSuffix(String suffix) {
  final trimmed = suffix.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
}

String _joinRecoveredIosPath(String documentsPath, String suffix) {
  final normalizedSuffix = _normalizeRecoveredIosSuffix(suffix);
  if (normalizedSuffix.isEmpty) return documentsPath;
  return '$documentsPath/$normalizedSuffix';
}

/// Checks if a path is a valid writable directory on iOS.
/// Returns false if:
/// - The path is the app container root (not writable)
/// - The path is an iCloud Drive path (not accessible by Go backend)
/// - The path is outside the app sandbox
bool isValidIosWritablePath(String path) {
  if (!Platform.isIOS) return true;
  if (path.isEmpty) return false;
  if (!path.startsWith('/')) return false;

  if (_iosContainerRootPattern.hasMatch(path)) {
    return false;
  }

  if (path.contains('Mobile Documents') ||
      path.contains('CloudDocs') ||
      path.contains('com~apple~CloudDocs')) {
    return false;
  }

  if (_iosNestedLegacyDocumentsPattern.hasMatch(path)) {
    return false;
  }

  final containerPattern = RegExp(
    r'/var/mobile/Containers/Data/Application/[A-F0-9\-]+',
    caseSensitive: false,
  );
  final match = containerPattern.firstMatch(path);
  if (match != null) {
    final remainingPath = path.substring(match.end);
    if (remainingPath.isEmpty || remainingPath == '/') {
      return false;
    }
  }

  return true;
}

/// Validates and potentially corrects an iOS path.
/// Returns a valid Documents subdirectory path if the input is invalid.
Future<String> validateOrFixIosPath(
  String path, {
  String subfolder = 'SpotiFLAC',
}) async {
  if (!Platform.isIOS) return path;

  final trimmed = path.trim();
  final docDir = await getApplicationDocumentsDirectory();

  final nestedLegacyMatch = _iosNestedLegacyDocumentsPattern.firstMatch(
    trimmed,
  );
  if (nestedLegacyMatch != null) {
    return _joinRecoveredIosPath(docDir.path, nestedLegacyMatch.group(1) ?? '');
  }

  if (isValidIosWritablePath(trimmed)) {
    return trimmed;
  }

  final candidates = <String>[];

  if (trimmed.isNotEmpty) {
    candidates.add(trimmed);
  }

  if (_iosContainerPathWithoutLeadingSlashPattern.hasMatch(trimmed)) {
    candidates.add('/$trimmed');
  }

  final legacyRelativeMatch = _iosLegacyRelativeDocumentsPattern.firstMatch(
    trimmed,
  );
  if (legacyRelativeMatch != null) {
    candidates.add(
      _joinRecoveredIosPath(docDir.path, legacyRelativeMatch.group(1) ?? ''),
    );
  }

  if (!trimmed.startsWith('/')) {
    final documentsMarker = 'Documents/';
    final index = trimmed.indexOf(documentsMarker);
    if (index >= 0) {
      final suffix = trimmed.substring(index + documentsMarker.length).trim();
      candidates.add(_joinRecoveredIosPath(docDir.path, suffix));
    }
  }

  for (final candidate in candidates) {
    if (isValidIosWritablePath(candidate)) {
      return candidate;
    }
  }

  final musicDir = Directory('${docDir.path}/$subfolder');
  if (!await musicDir.exists()) {
    await musicDir.create(recursive: true);
  }
  return musicDir.path;
}

/// Detailed result for iOS path validation
class IosPathValidationResult {
  final bool isValid;
  final String? correctedPath;
  final String? errorReason;

  const IosPathValidationResult({
    required this.isValid,
    this.correctedPath,
    this.errorReason,
  });
}

/// Validates an iOS path and returns detailed information about the result.
IosPathValidationResult validateIosPath(String path) {
  if (!Platform.isIOS) {
    return const IosPathValidationResult(isValid: true);
  }

  if (path.isEmpty) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason: 'Path is empty',
    );
  }

  if (!path.startsWith('/')) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Invalid path format. Please choose a local folder from Files.',
    );
  }

  if (_iosContainerRootPattern.hasMatch(path)) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Cannot write to app container root. Please choose a subfolder like Documents.',
    );
  }

  if (path.contains('Mobile Documents') ||
      path.contains('CloudDocs') ||
      path.contains('com~apple~CloudDocs')) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'iCloud Drive is not supported. Please choose a local folder.',
    );
  }

  if (_iosNestedLegacyDocumentsPattern.hasMatch(path)) {
    return const IosPathValidationResult(
      isValid: false,
      errorReason:
          'Invalid iOS app folder path. Please choose App Documents or another local folder.',
    );
  }

  final containerPattern = RegExp(
    r'/var/mobile/Containers/Data/Application/[A-F0-9\-]+',
    caseSensitive: false,
  );
  final match = containerPattern.firstMatch(path);
  if (match != null) {
    final remainingPath = path.substring(match.end);
    if (remainingPath.isEmpty || remainingPath == '/') {
      return const IosPathValidationResult(
        isValid: false,
        errorReason:
            'Cannot write to app container root. Please use the default folder or choose a different location.',
      );
    }
  }

  return const IosPathValidationResult(isValid: true);
}

class FileAccessStat {
  final int? size;
  final DateTime? modified;

  const FileAccessStat({this.size, this.modified});
}

class _IosLocalLibraryAccess {
  final String folderPath;
  final String bookmark;

  const _IosLocalLibraryAccess({
    required this.folderPath,
    required this.bookmark,
  });
}

bool isContentUri(String? path) {
  return path != null && path.startsWith('content://');
}

String _stripTrailingSlash(String path) {
  var normalized = path.trim();
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String _normalizeIosPathForCompare(String path) {
  final normalized = _stripTrailingSlash(path);
  if (normalized.startsWith('/private/var/')) {
    return normalized.substring('/private'.length);
  }
  return normalized;
}

bool _isSameOrChildPath(String path, String folderPath) {
  final normalizedPath = _normalizeIosPathForCompare(path);
  final normalizedFolder = _normalizeIosPathForCompare(folderPath);
  if (normalizedPath.isEmpty || normalizedFolder.isEmpty) return false;
  return normalizedPath == normalizedFolder ||
      normalizedPath.startsWith('$normalizedFolder/');
}

Future<_IosLocalLibraryAccess?> _readIosLocalLibraryAccess() async {
  if (!Platform.isIOS) return null;

  try {
    final prefs = await SharedPreferences.getInstance();
    final rawSettings = prefs.getString(_settingsKey);
    if (rawSettings == null || rawSettings.isEmpty) return null;

    final decoded = jsonDecode(rawSettings);
    if (decoded is! Map) return null;

    final folderPath = (decoded['localLibraryPath'] as String? ?? '').trim();
    final bookmark = (decoded['localLibraryBookmark'] as String? ?? '').trim();
    if (folderPath.isEmpty || bookmark.isEmpty) return null;

    return _IosLocalLibraryAccess(
      folderPath: folderPath,
      bookmark: bookmark,
    );
  } catch (_) {
    return null;
  }
}

Future<T> _withIosLocalLibraryAccess<T>(
  String path,
  Future<T> Function() action,
) async {
  if (!Platform.isIOS || path.isEmpty || !path.startsWith('/')) {
    return action();
  }

  final access = await _readIosLocalLibraryAccess();
  if (access == null || !_isSameOrChildPath(path, access.folderPath)) {
    return action();
  }

  final resolvedPath = await PlatformBridge.startAccessingIosBookmark(
    access.bookmark,
  );
  final didStartAccess = resolvedPath != null;
  try {
    return await action();
  } finally {
    if (didStartAccess) {
      await PlatformBridge.stopAccessingIosBookmark();
    }
  }
}

bool isSameContentUri(String? first, String? second) {
  if (first == null || second == null) return false;
  if (first == second) return true;
  if (!isContentUri(first) || !isContentUri(second)) return false;

  String decode(String value) {
    try {
      return Uri.decodeFull(value);
    } catch (_) {
      return value;
    }
  }

  return decode(first) == decode(second);
}

/// Pattern matching CUE virtual path suffixes like #track01, #track12, etc.
final _cueTrackSuffix = RegExp(r'#track\d+$');

const cueVirtualTrackRequiresSplitMessage =
    'This CUE track is virtual. Use Split into Tracks first.';

/// Whether the path is a CUE virtual path (contains #trackNN suffix).
bool isCueVirtualPath(String? path) {
  return path != null && _cueTrackSuffix.hasMatch(path);
}

/// Strip the #trackNN suffix from a CUE virtual path to get the base .cue path.
/// Returns the path unchanged if it's not a CUE virtual path.
String stripCueTrackSuffix(String path) {
  return path.replaceFirst(_cueTrackSuffix, '');
}

Future<bool> fileExists(String? path) async {
  if (path == null || path.isEmpty) return false;
  final realPath = isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path;
  if (isContentUri(realPath)) {
    return PlatformBridge.safExists(realPath);
  }
  return _withIosLocalLibraryAccess(realPath, () => File(realPath).exists());
}

Future<void> deleteFile(String? path) async {
  if (path == null || path.isEmpty) return;
  // CUE virtual paths should NOT be deleted through this function —
  // deleting album.cue would remove ALL tracks. Callers should handle
  // CUE deletion specially (e.g. only delete when all tracks are removed).
  if (isCueVirtualPath(path)) return;
  if (isContentUri(path)) {
    await PlatformBridge.safDelete(path);
    return;
  }
  try {
    await File(path).delete();
  } catch (_) {}
}

Future<FileAccessStat?> fileStat(String? path) async {
  if (path == null || path.isEmpty) return null;
  final realPath = isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path;
  if (isContentUri(realPath)) {
    final stat = await PlatformBridge.safStat(realPath);
    final exists = stat['exists'] as bool? ?? true;
    if (!exists) return null;
    return FileAccessStat(
      size: stat['size'] as int?,
      modified: stat['modified'] != null
          ? DateTime.fromMillisecondsSinceEpoch(stat['modified'] as int)
          : null,
    );
  }

  return _withIosLocalLibraryAccess(realPath, () async {
    final stat = await FileStat.stat(realPath);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return FileAccessStat(size: stat.size, modified: stat.modified);
  });
}

Future<void> openFile(String path) async {
  if (isCueVirtualPath(path)) {
    throw Exception(cueVirtualTrackRequiresSplitMessage);
  }

  final realPath = path;
  if (isContentUri(realPath)) {
    await PlatformBridge.openContentUri(realPath, mimeType: '');
    return;
  }
  await _withIosLocalLibraryAccess(realPath, () async {
    final mimeType = audioMimeTypeForPath(realPath);
    final result = await OpenFilex.open(realPath, type: mimeType);
    if (result.type != ResultType.done) {
      throw Exception(result.message);
    }
  });
}
