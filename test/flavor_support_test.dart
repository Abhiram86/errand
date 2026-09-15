import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/main.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/tools/act_tool.dart';
import 'package:errand/tools/screen_tool.dart';

class UnsupportedA11yService extends A11yService {
  @override
  Future<bool> isSupported({bool forceRefresh = false}) async => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool> isRestricted() async => false;
}

class SupportedA11yService extends A11yService {
  final bool enabled;
  SupportedA11yService({this.enabled = true});

  @override
  Future<bool> isSupported({bool forceRefresh = false}) async => true;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> isRestricted() async => false;
}

void main() {
  group('System prompt flavor checks', () {
    test('omits screen & device capabilities section when a11ySupported is false (lite)', () {
      final prompt = systemPromptFor(
        Directory('/tmp'),
        screenAccess: false,
        screenRestricted: false,
        a11ySupported: false,
      );

      expect(prompt, isNot(contains('Screen & Device Capabilities (DISABLED)')));
      expect(prompt, isNot(contains('Screen & Device Capabilities (ENABLED)')));
      expect(prompt, isNot(contains('Accessibility Service')));
      expect(prompt, contains('Current working directory: /tmp'));
    });

    test('includes DISABLED section when a11ySupported is true and screenAccess is false (full)', () {
      final prompt = systemPromptFor(
        Directory('/tmp'),
        screenAccess: false,
        screenRestricted: false,
        a11ySupported: true,
      );

      expect(prompt, contains('Screen & Device Capabilities (DISABLED)'));
      expect(prompt, contains('Screen Access is currently off'));
    });

    test('includes ENABLED section when a11ySupported is true and screenAccess is true (full)', () {
      final prompt = systemPromptFor(
        Directory('/tmp'),
        screenAccess: true,
        screenRestricted: false,
        a11ySupported: true,
      );

      expect(prompt, contains('Screen & Device Capabilities (ENABLED)'));
    });

    test('includes development & diagnostics section when isDebug is true', () {
      final prompt = systemPromptFor(
        Directory('/tmp'),
        isDebug: true,
      );

      expect(prompt, contains('Development & Diagnostics (DEBUG MODE)'));
      expect(prompt, contains('Transparent technical inspection'));
      expect(prompt, contains('Normal proactive execution'));
    });

    test('omits development & diagnostics section when isDebug is false', () {
      final prompt = systemPromptFor(
        Directory('/tmp'),
        isDebug: false,
      );

      expect(prompt, isNot(contains('Development & Diagnostics (DEBUG MODE)')));
      expect(prompt, isNot(contains('Transparent technical inspection')));
    });
  });

  group('ToolRegistry flavor checks', () {
    test('ToolRegistry includes screen and screen_act when enableA11yTools is true (full)', () {
      final registry = ToolRegistry.defaults(
        currentDir: Directory('/tmp'),
        enableA11yTools: true,
      );
      final names = registry.all.map((t) => t.name).toList();
      expect(names, containsAll(['screen', 'screen_act']));
    });

    test('ToolRegistry excludes screen and screen_act when enableA11yTools is false (lite)', () {
      final registry = ToolRegistry.defaults(
        currentDir: Directory('/tmp'),
        enableA11yTools: false,
      );
      final names = registry.all.map((t) => t.name).toList();
      expect(names.contains('screen'), isFalse);
      expect(names.contains('screen_act'), isFalse);
    });
  });

  group('Tool handlers when a11y is unsupported', () {
    test('screen tool fails cleanly when a11y is unsupported', () async {
      final tool = screenTool(service: UnsupportedA11yService());
      const call = ToolCall(id: '1', name: 'screen', arguments: {'action': 'read'});
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Screen access is not supported in this build of Errand'));
    });

    test('act tool (screen_act) fails cleanly when a11y is unsupported', () async {
      final tool = actTool(service: UnsupportedA11yService());
      expect(tool.name, equals('screen_act'));
      const call = ToolCall(id: '2', name: 'screen_act', arguments: {'action': 'tap', 'ref': 1});
      final result = await tool.handler(call);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Screen actions are not supported in this build of Errand'));
    });
  });
}
