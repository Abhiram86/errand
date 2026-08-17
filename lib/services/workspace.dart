import 'dart:io';

import 'package:flutter/services.dart';

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

  Directory get root {
    return Directory('/storage/emulated/0');
  }
}
