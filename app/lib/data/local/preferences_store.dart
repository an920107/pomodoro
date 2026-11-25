import 'package:shared_preferences/shared_preferences.dart';

/// Persistence abstraction for App-local preferences and Phase 1/2 toggles.
abstract class PreferencesStore {
  String? get lastDeviceId;
  Future<void> setLastDeviceId(String? value);

  String? get lastDeviceName;
  Future<void> setLastDeviceName(String? value);

  bool get isMockBleMode;
  Future<void> setMockBleMode(bool value);

  bool get dndEnabled;
  Future<void> setDndEnabled(bool value);

  bool get appLockEnabled;
  Future<void> setAppLockEnabled(bool value);

  List<String> get blacklistedPackages;
  Future<void> setBlacklistedPackages(List<String> packages);
}

abstract final class PreferencesKeys {
  static const String lastDeviceId = 'pref_last_device_id';
  static const String lastDeviceName = 'pref_last_device_name';
  static const String isMockBleMode = 'pref_is_mock_ble_mode';
  static const String dndEnabled = 'pref_dnd_enabled';
  static const String appLockEnabled = 'pref_app_lock_enabled';
  static const String blacklistedPackages = 'pref_blacklisted_packages';
}

/// [PreferencesStore] backed by [SharedPreferences].
class SharedPreferencesStore implements PreferencesStore {
  SharedPreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  String? get lastDeviceId => _prefs.getString(PreferencesKeys.lastDeviceId);

  @override
  Future<void> setLastDeviceId(String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(PreferencesKeys.lastDeviceId);
    } else {
      await _prefs.setString(PreferencesKeys.lastDeviceId, value);
    }
  }

  @override
  String? get lastDeviceName =>
      _prefs.getString(PreferencesKeys.lastDeviceName);

  @override
  Future<void> setLastDeviceName(String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(PreferencesKeys.lastDeviceName);
    } else {
      await _prefs.setString(PreferencesKeys.lastDeviceName, value);
    }
  }

  @override
  bool get isMockBleMode =>
      _prefs.getBool(PreferencesKeys.isMockBleMode) ?? true;

  @override
  Future<void> setMockBleMode(bool value) async {
    await _prefs.setBool(PreferencesKeys.isMockBleMode, value);
  }

  @override
  bool get dndEnabled => _prefs.getBool(PreferencesKeys.dndEnabled) ?? false;

  @override
  Future<void> setDndEnabled(bool value) async {
    await _prefs.setBool(PreferencesKeys.dndEnabled, value);
  }

  @override
  bool get appLockEnabled =>
      _prefs.getBool(PreferencesKeys.appLockEnabled) ?? false;

  @override
  Future<void> setAppLockEnabled(bool value) async {
    await _prefs.setBool(PreferencesKeys.appLockEnabled, value);
  }

  @override
  List<String> get blacklistedPackages => List<String>.unmodifiable(
    _prefs.getStringList(PreferencesKeys.blacklistedPackages) ?? const [],
  );

  @override
  Future<void> setBlacklistedPackages(List<String> packages) async {
    await _prefs.setStringList(PreferencesKeys.blacklistedPackages, packages);
  }
}

/// Ephemeral [PreferencesStore] for isolated unit and widget tests.
class InMemoryPreferencesStore implements PreferencesStore {
  InMemoryPreferencesStore({
    this._lastDeviceId,
    this._lastDeviceName,
    this._isMockBleMode = true,
    this._dndEnabled = false,
    this._appLockEnabled = false,
    List<String> blacklistedPackages = const [],
  }) : _blacklistedPackages = List<String>.unmodifiable(blacklistedPackages);

  String? _lastDeviceId;
  String? _lastDeviceName;
  bool _isMockBleMode;
  bool _dndEnabled;
  bool _appLockEnabled;
  List<String> _blacklistedPackages;

  @override
  String? get lastDeviceId => _lastDeviceId;

  @override
  Future<void> setLastDeviceId(String? value) async {
    _lastDeviceId = (value == null || value.isEmpty) ? null : value;
  }

  @override
  String? get lastDeviceName => _lastDeviceName;

  @override
  Future<void> setLastDeviceName(String? value) async {
    _lastDeviceName = (value == null || value.isEmpty) ? null : value;
  }

  @override
  bool get isMockBleMode => _isMockBleMode;

  @override
  Future<void> setMockBleMode(bool value) async {
    _isMockBleMode = value;
  }

  @override
  bool get dndEnabled => _dndEnabled;

  @override
  Future<void> setDndEnabled(bool value) async {
    _dndEnabled = value;
  }

  @override
  bool get appLockEnabled => _appLockEnabled;

  @override
  Future<void> setAppLockEnabled(bool value) async {
    _appLockEnabled = value;
  }

  @override
  List<String> get blacklistedPackages => _blacklistedPackages;

  @override
  Future<void> setBlacklistedPackages(List<String> packages) async {
    _blacklistedPackages = List<String>.unmodifiable(packages);
  }
}
