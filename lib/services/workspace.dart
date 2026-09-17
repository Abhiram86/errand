import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class StorageAccess {
  static const _channel = MethodChannel('storage_access');

  Future<bool> get hasPermission async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } on MissingPluginException {
      // Treat an unavailable platform channel as no permission.
    } on PlatformException {
      // Treat a failed platform request as no permission.
    }
  }
}

class Workspace {
  static final instance = Workspace._();

  Workspace._();

  final StorageAccess _access = StorageAccess();

  Future<bool> hasPermission() {
    return _access.hasPermission;
  }

  Future<void> requestPermission() {
    return _access.requestPermission();
  }

  /// System root for user-accessible storage (acts as the boundary for tool discovery and reading).
  Directory get root {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0');
    }
    return Directory.current;
  }

  /// Default directory for user-visible files and exports created by Errand.
  Directory get documentsDir {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Documents/Errand');
    }
    return Directory(p.join(Directory.systemTemp.path, 'Errand', 'Documents'));
  }

  /// Ephemeral scratch directory for temporary scripts, intermediate logs, and test runs.
  Directory get scratchDir {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Documents/Errand/.scratch');
    }
    return Directory(p.join(Directory.systemTemp.path, 'Errand', 'scratch'));
  }

  /// Default working directory for new conversations and relative file operations.
  Directory get defaultDir => documentsDir;

  /// Ensures default directories exist on disk.
  Future<void> ensureDefaultDirectories() async {
    try {
      final doc = documentsDir;
      if (!await doc.exists()) {
        await doc.create(recursive: true);
      }
      final scratch = scratchDir;
      if (!await scratch.exists()) {
        await scratch.create(recursive: true);
      }
    } catch (_) {
      // Ignored if permissions are not granted yet.
    }
  }
}
