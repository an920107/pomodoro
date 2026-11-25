import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';

/// Persisted ESP32 configuration (`CMD_CFG_GET 100` / `CMD_CFG_SET 101`).
class DeviceConfig {
  const DeviceConfig({
    required this.focusMinutes,
    required this.breakMinutes,
    required this.mute,
    required this.awayCm,
    required this.awayGraceSeconds,
  });

  const DeviceConfig.defaults()
      : focusMinutes = BleProtocolConstants.defaultFocusMinutes,
        breakMinutes = BleProtocolConstants.defaultBreakMinutes,
        mute = false,
        awayCm = BleProtocolConstants.defaultAwayCm,
        awayGraceSeconds = BleProtocolConstants.defaultAwayGraceSec;

  factory DeviceConfig.fromData(Map<String, dynamic> data) {
    final focusMin = data['focus_min'];
    final breakMin = data['break_min'];
    final mute = data['mute'];
    final awayCm = data['away_cm'];
    final awayGrace = data['away_grace'];

    if (focusMin is! int ||
        breakMin is! int ||
        mute is! bool ||
        awayCm is! int ||
        awayGrace is! int) {
      throw const PacketValidationException('Invalid DeviceConfig payload');
    }

    return DeviceConfig(
      focusMinutes: focusMin,
      breakMinutes: breakMin,
      mute: mute,
      awayCm: awayCm,
      awayGraceSeconds: awayGrace,
    );
  }

  final int focusMinutes;
  final int breakMinutes;
  final bool mute;
  final int awayCm;
  final int awayGraceSeconds;

  void validate() {
    if (focusMinutes < BleProtocolConstants.minFocusMinutes ||
        focusMinutes > BleProtocolConstants.maxFocusMinutes) {
      throw const PacketValidationException(
        'focus_min must be within 1..120',
      );
    }
    if (breakMinutes < BleProtocolConstants.minBreakMinutes ||
        breakMinutes > BleProtocolConstants.maxBreakMinutes) {
      throw const PacketValidationException(
        'break_min must be within 1..60',
      );
    }
    if (awayCm < BleProtocolConstants.minAwayCm ||
        awayCm > BleProtocolConstants.maxAwayCm) {
      throw const PacketValidationException(
        'away_cm must be within 20..300',
      );
    }
    if (awayGraceSeconds < BleProtocolConstants.minAwayGraceSec ||
        awayGraceSeconds > BleProtocolConstants.maxAwayGraceSec) {
      throw const PacketValidationException(
        'away_grace must be within 1..60',
      );
    }
  }

  Map<String, dynamic> toData() => <String, dynamic>{
        'focus_min': focusMinutes,
        'break_min': breakMinutes,
        'mute': mute,
        'away_cm': awayCm,
        'away_grace': awayGraceSeconds,
      };

  DeviceConfig copyWith({
    int? focusMinutes,
    int? breakMinutes,
    bool? mute,
    int? awayCm,
    int? awayGraceSeconds,
  }) {
    return DeviceConfig(
      focusMinutes: focusMinutes ?? this.focusMinutes,
      breakMinutes: breakMinutes ?? this.breakMinutes,
      mute: mute ?? this.mute,
      awayCm: awayCm ?? this.awayCm,
      awayGraceSeconds: awayGraceSeconds ?? this.awayGraceSeconds,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceConfig &&
        other.focusMinutes == focusMinutes &&
        other.breakMinutes == breakMinutes &&
        other.mute == mute &&
        other.awayCm == awayCm &&
        other.awayGraceSeconds == awayGraceSeconds;
  }

  @override
  int get hashCode =>
      Object.hash(focusMinutes, breakMinutes, mute, awayCm, awayGraceSeconds);

  @override
  String toString() =>
      'DeviceConfig(focus: $focusMinutes, break: $breakMinutes, mute: $mute, awayCm: $awayCm, awayGrace: $awayGraceSeconds)';
}
