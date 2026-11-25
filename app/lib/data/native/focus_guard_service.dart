import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Supported Android special permissions managed by FocusGuard.
enum FocusPermissionKind {
  dnd('dnd'),
  usageAccess('usageAccess'),
  overlay('overlay'),
  notifications('notifications');

  const FocusPermissionKind(this.wireValue);

  final String wireValue;
}

/// Snapshot of required Android system permissions for FocusGuard.
class FocusGuardPermissions {
  const FocusGuardPermissions({
    this.dndGranted = false,
    this.usageAccessGranted = false,
    this.overlayGranted = false,
    this.notificationsGranted = true,
  });

  factory FocusGuardPermissions.fromMap(Map<Object?, Object?> map) {
    return FocusGuardPermissions(
      dndGranted: map['dndGranted'] == true,
      usageAccessGranted: map['usageAccessGranted'] == true,
      overlayGranted: map['overlayGranted'] == true,
      notificationsGranted: map['notificationsGranted'] != false,
    );
  }

  final bool dndGranted;
  final bool usageAccessGranted;
  final bool overlayGranted;
  final bool notificationsGranted;

  bool get allCoreGranted => dndGranted && usageAccessGranted && overlayGranted;
}

/// Launcher application entry available for FocusGuard blacklisting.
class InstalledAppInfo {
  const InstalledAppInfo({
    required this.packageName,
    required this.appName,
    this.isSystemApp = false,
  });

  factory InstalledAppInfo.fromMap(Map<Object?, Object?> map) {
    final pkg = (map['packageName'] as String?) ?? '';
    final name = (map['appName'] as String?) ?? pkg;
    return InstalledAppInfo(
      packageName: pkg,
      appName: name,
      isSystemApp: map['isSystemApp'] == true,
    );
  }

  final String packageName;
  final String appName;
  final bool isSystemApp;
}

/// Abstraction over Android native FocusGuard platform channels so controllers
/// and UI can be tested deterministically without a live Android device.
abstract class FocusGuardPlatformService {
  bool get isSupportedPlatform;

  Future<FocusGuardPermissions> checkPermissions();

  Future<bool> openPermissionSettings(FocusPermissionKind kind);

  Future<List<InstalledAppInfo>> getInstalledApps();

  Future<void> startOrUpdateGuard({
    required int remainingSeconds,
    required bool dndEnabled,
    required bool appLockEnabled,
    required List<String> blacklistedPackages,
    String? taskTitle,
  });

  Future<void> stopGuard();
}

/// Safe no-op [FocusGuardPlatformService] for VM tests and non-Android targets
/// (`docs/spec.md` §6.2 fallback surface).
class NoOpFocusGuardService implements FocusGuardPlatformService {
  const NoOpFocusGuardService();

  @override
  bool get isSupportedPlatform => false;

  @override
  Future<FocusGuardPermissions> checkPermissions() async =>
      const FocusGuardPermissions();

  @override
  Future<bool> openPermissionSettings(FocusPermissionKind kind) async => false;

  @override
  Future<List<InstalledAppInfo>> getInstalledApps() async =>
      const <InstalledAppInfo>[];

  @override
  Future<void> startOrUpdateGuard({
    required int remainingSeconds,
    required bool dndEnabled,
    required bool appLockEnabled,
    required List<String> blacklistedPackages,
    String? taskTitle,
  }) async {}

  @override
  Future<void> stopGuard() async {}
}

/// Production [FocusGuardPlatformService] bridged to Kotlin `FocusGuardChannel`.
class MethodChannelFocusGuardService implements FocusGuardPlatformService {
  MethodChannelFocusGuardService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.example.pomodoro/focus_guard';

  final MethodChannel _channel;

  @override
  bool get isSupportedPlatform => !kIsWeb && Platform.isAndroid;

  @override
  Future<FocusGuardPermissions> checkPermissions() async {
    if (!isSupportedPlatform) {
      return const FocusGuardPermissions();
    }
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'checkPermissions',
    );
    if (raw == null) return const FocusGuardPermissions();
    return FocusGuardPermissions.fromMap(raw);
  }

  @override
  Future<bool> openPermissionSettings(FocusPermissionKind kind) async {
    if (!isSupportedPlatform) return false;
    final opened = await _channel.invokeMethod<bool>(
      'openPermissionSettings',
      <String, dynamic>{'kind': kind.wireValue},
    );
    return opened == true;
  }

  @override
  Future<List<InstalledAppInfo>> getInstalledApps() async {
    if (!isSupportedPlatform) return const <InstalledAppInfo>[];
    final rawList = await _channel.invokeListMethod<Object?>(
      'getInstalledApps',
    );
    if (rawList == null) return const <InstalledAppInfo>[];
    return rawList
        .whereType<Map<Object?, Object?>>()
        .map(InstalledAppInfo.fromMap)
        .where((app) => app.packageName.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> startOrUpdateGuard({
    required int remainingSeconds,
    required bool dndEnabled,
    required bool appLockEnabled,
    required List<String> blacklistedPackages,
    String? taskTitle,
  }) async {
    if (!isSupportedPlatform) return;
    await _channel.invokeMethod<void>('startOrUpdateGuard', <String, dynamic>{
      'remainingSeconds': remainingSeconds,
      'dndEnabled': dndEnabled,
      'appLockEnabled': appLockEnabled,
      'blacklistedPackages': blacklistedPackages,
      'taskTitle': taskTitle,
    });
  }

  @override
  Future<void> stopGuard() async {
    if (!isSupportedPlatform) return;
    await _channel.invokeMethod<void>('stopGuard');
  }
}
