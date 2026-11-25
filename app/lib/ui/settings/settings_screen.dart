import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/protocol/mock_ble_self_check.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_self_check.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/device_config.dart';
import '../../state/ble_providers.dart';
import '../../state/config_controller.dart';
import '../../state/debug_mode_controller.dart';
import '../connection/device_scan_sheet.dart';
import 'focus_guard_screen.dart';
import 'packet_inspector_screen.dart';

/// Phase 1 device configuration screen (`CMD_CFG_GET 100` / `CMD_CFG_SET 101`).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const List<int> _focusPresets = <int>[15, 25, 30, 45, 60];
  static const List<int> _breakPresets = <int>[5, 10, 15];

  late int _focusMin;
  late int _breakMin;
  late bool _mute;
  late int _awayCm;
  late int _awayGrace;
  bool _dirty = false;

  bool _diagnosticsExpanded = false;
  bool _protoRunning = false;
  String? _protoResult;
  bool _protoError = false;
  bool _mockRunning = false;
  String? _mockResult;
  bool _mockError = false;

  @override
  void initState() {
    super.initState();
    _applyConfig(ref.read(configControllerProvider).config);
  }

  void _applyConfig(DeviceConfig cfg) {
    _focusMin = cfg.focusMinutes.clamp(
      BleProtocolConstants.minFocusMinutes,
      BleProtocolConstants.maxFocusMinutes,
    );
    _breakMin = cfg.breakMinutes.clamp(
      BleProtocolConstants.minBreakMinutes,
      BleProtocolConstants.maxBreakMinutes,
    );
    _mute = cfg.mute;
    _awayCm = cfg.awayCm.clamp(30, 150);
    _awayGrace = cfg.awayGraceSeconds.clamp(1, 30);
    _dirty = false;
  }

  Future<void> _reloadConfig() async {
    final controller = ref.read(configControllerProvider.notifier);
    final ok = await controller.loadConfig();
    if (!mounted) return;
    if (ok) {
      setState(() {
        _applyConfig(ref.read(configControllerProvider).config);
      });
    }
  }

  Future<void> _saveConfig() async {
    final controller = ref.read(configControllerProvider.notifier);
    final next = DeviceConfig(
      focusMinutes: _focusMin,
      breakMinutes: _breakMin,
      mute: _mute,
      awayCm: _awayCm,
      awayGraceSeconds: _awayGrace,
    );
    final ok = await controller.saveConfig(next);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('裝置設定已儲存')),
      );
    } else {
      final err =
          ref.read(configControllerProvider).errorMessage ?? '儲存失敗';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
    }
  }

  Future<void> _runProtocolCheck() async {
    if (_protoRunning) return;
    setState(() {
      _protoRunning = true;
      _protoError = false;
    });
    try {
      final summary = await runProtocolSelfCheck();
      if (!mounted) return;
      setState(() {
        _protoResult = summary;
        _protoError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _protoResult = '自檢失敗：$e';
        _protoError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _protoRunning = false;
        });
      }
    }
  }

  Future<void> _runMockCheck() async {
    if (_mockRunning) return;
    setState(() {
      _mockRunning = true;
      _mockError = false;
    });
    try {
      final summary = await runMockBleSelfCheck();
      if (!mounted) return;
      setState(() {
        _mockResult = summary;
        _mockError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mockResult = 'Mock 自檢失敗：$e';
        _mockError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _mockRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConfigState>(configControllerProvider, (prev, next) {
      if (!_dirty && prev?.config != next.config) {
        setState(() {
          _applyConfig(next.config);
        });
      }
    });

    final configState = ref.watch(configControllerProvider);
    final isDebug = ref.watch(debugModeProvider);
    final isMock = ref.watch(isMockBleModeProvider);
    final connection = ref.watch(bleConnectionProvider).asData?.value;
    final locked = configState.isLocked;
    final textTheme = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (isDebug)
            Card(
              key: const Key('card_ble_mode_settings'),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '通訊模式與藍牙裝置',
                            style: textTheme.titleMedium,
                          ),
                        ),
                        OutlinedButton.icon(
                          key: const Key('btn_open_scan_sheet'),
                          onPressed: () => DeviceScanSheet.show(context),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(
                            Icons.bluetooth_searching_rounded,
                            size: 16,
                          ),
                          label: const Text('掃描裝置'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        ChoiceChip(
                          key: const Key('chip_ble_mode_mock'),
                          label: const Text('Mock 虛擬韌體 (預設)'),
                          selected: isMock,
                          onSelected: (_) {
                            ref
                                .read(isMockBleModeProvider.notifier)
                                .setMockMode(true);
                          },
                        ),
                        ChoiceChip(
                          key: const Key('chip_ble_mode_real'),
                          label: const Text('Real BLE 實體連線'),
                          selected: !isMock,
                          onSelected: (_) {
                            ref
                                .read(isMockBleModeProvider.notifier)
                                .setMockMode(false);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              key: const Key('card_ble_device_normal'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Icon(
                      connection?.state.isConnected == true
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_searching_rounded,
                      size: 24,
                      color: connection?.state.isConnected == true
                          ? AppColors.signalBreak
                          : AppColors.ink,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('藍牙裝置連線', style: textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            connection?.state.isConnected == true &&
                                    connection?.device != null
                                ? '已連線：${connection!.device!.name}'
                                : '搜尋並配對附近的 SmartPomodoro 番茄鐘',
                            style: textTheme.bodySmall?.copyWith(
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const Key('btn_open_scan_sheet'),
                      onPressed: () => DeviceScanSheet.show(context),
                      icon: const Icon(
                        Icons.bluetooth_searching_rounded,
                        size: 16,
                      ),
                      label: const Text('掃描裝置'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (configState.errorMessage != null) ...<Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.signalFocus),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: AppColors.signalFocus,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      configState.errorMessage!,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.signalFocus,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed:
                        ref.read(configControllerProvider.notifier).clearError,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('計時時長設定', style: textTheme.titleMedium),
                  const SizedBox(height: 14),
                  _SettingHeaderRow(
                    label: '專注時長',
                    valueKey: const Key('txt_cfg_focus_min'),
                    valueText: '$_focusMin 分鐘',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _focusPresets.map((minutes) {
                      final selected = _focusMin == minutes;
                      return ChoiceChip(
                        key: Key('chip_focus_$minutes'),
                        label: Text('$minutes 分'),
                        selected: selected,
                        onSelected: locked
                            ? null
                            : (_) {
                                setState(() {
                                  _focusMin = minutes;
                                  _dirty = true;
                                });
                              },
                      );
                    }).toList(),
                  ),
                  Row(
                    children: <Widget>[
                      IconButton(
                        key: const Key('btn_focus_dec'),
                        onPressed: locked || _focusMin <= 1
                            ? null
                            : () {
                                setState(() {
                                  _focusMin--;
                                  _dirty = true;
                                });
                              },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('slider_cfg_focus_min'),
                          value: _focusMin.toDouble(),
                          min: 1,
                          max: 120,
                          divisions: 119,
                          onChanged: locked
                              ? null
                              : (val) {
                                  setState(() {
                                    _focusMin = val.round();
                                    _dirty = true;
                                  });
                                },
                        ),
                      ),
                      IconButton(
                        key: const Key('btn_focus_inc'),
                        onPressed: locked || _focusMin >= 120
                            ? null
                            : () {
                                setState(() {
                                  _focusMin++;
                                  _dirty = true;
                                });
                              },
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  _SettingHeaderRow(
                    label: '休息時長',
                    valueKey: const Key('txt_cfg_break_min'),
                    valueText: '$_breakMin 分鐘',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _breakPresets.map((minutes) {
                      final selected = _breakMin == minutes;
                      return ChoiceChip(
                        key: Key('chip_break_$minutes'),
                        label: Text('$minutes 分'),
                        selected: selected,
                        onSelected: locked
                            ? null
                            : (_) {
                                setState(() {
                                  _breakMin = minutes;
                                  _dirty = true;
                                });
                              },
                      );
                    }).toList(),
                  ),
                  Row(
                    children: <Widget>[
                      IconButton(
                        key: const Key('btn_break_dec'),
                        onPressed: locked || _breakMin <= 1
                            ? null
                            : () {
                                setState(() {
                                  _breakMin--;
                                  _dirty = true;
                                });
                              },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('slider_cfg_break_min'),
                          value: _breakMin.toDouble(),
                          min: 1,
                          max: 60,
                          divisions: 59,
                          onChanged: locked
                              ? null
                              : (val) {
                                  setState(() {
                                    _breakMin = val.round();
                                    _dirty = true;
                                  });
                                },
                        ),
                      ),
                      IconButton(
                        key: const Key('btn_break_inc'),
                        onPressed: locked || _breakMin >= 60
                            ? null
                            : () {
                                setState(() {
                                  _breakMin++;
                                  _dirty = true;
                                });
                              },
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('感測器與提示音設定', style: textTheme.titleMedium),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    key: const Key('switch_cfg_mute'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('靜音模式'),
                    subtitle: const Text('關閉裝置蜂鳴器，僅保留螢幕與 LED 提示'),
                    value: _mute,
                    onChanged: locked
                        ? null
                        : (val) {
                            setState(() {
                              _mute = val;
                              _dirty = true;
                            });
                          },
                  ),
                  const Divider(height: 16),
                  _SettingHeaderRow(
                    label: '離位判定距離',
                    valueKey: const Key('txt_cfg_away_cm'),
                    valueText: '$_awayCm cm',
                  ),
                  Slider(
                    key: const Key('slider_cfg_away_cm'),
                    value: _awayCm.toDouble(),
                    min: 30,
                    max: 150,
                    divisions: 24,
                    onChanged: locked
                        ? null
                        : (val) {
                            setState(() {
                              _awayCm = val.round();
                              _dirty = true;
                            });
                          },
                  ),
                  const SizedBox(height: 6),
                  _SettingHeaderRow(
                    label: '離位寬限時間',
                    valueKey: const Key('txt_cfg_away_grace'),
                    valueText: '$_awayGrace 秒',
                  ),
                  Slider(
                    key: const Key('slider_cfg_away_grace'),
                    value: _awayGrace.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    onChanged: locked
                        ? null
                        : (val) {
                            setState(() {
                              _awayGrace = val.round();
                              _dirty = true;
                            });
                          },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  key: const Key('btn_reload_config'),
                  onPressed: locked ? null : _reloadConfig,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('重新讀取'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: FilledButton(
                  key: const Key('btn_save_config'),
                  onPressed: locked ? null : _saveConfig,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    foregroundColor: AppColors.surface,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(configState.isSaving ? '套用中...' : '套用至裝置'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            key: const Key('card_focus_guard_entry'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.shield_outlined,
                    size: 24,
                    color: AppColors.signalFocus,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('專注守護（勿擾與 App 鎖定）', style: textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          '管理系統權限與專注期間封鎖的應用程式',
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('btn_open_focus_guard'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const FocusGuardScreen(),
                        ),
                      );
                    },
                    child: const Text('設定權限與黑名單'),
                  ),
                ],
              ),
            ),
          ),
          if (isDebug) ...<Widget>[
            const SizedBox(height: 16),
            Card(
              key: const Key('card_packet_inspector_entry'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.terminal_rounded,
                      size: 24,
                      color: AppColors.ink,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('BLE 封包即時監看器', style: textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            '免接電腦即時檢視與篩選 TX/RX JSON、握手同步與守護日誌',
                            style: textTheme.bodySmall?.copyWith(
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const Key('btn_open_packet_inspector'),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PacketInspectorScreen(),
                          ),
                        );
                      },
                      child: const Text('開啟監看器'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceRecessed,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: <Widget>[
                  InkWell(
                    key: const Key('btn_toggle_diagnostics'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      setState(() {
                        _diagnosticsExpanded = !_diagnosticsExpanded;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: <Widget>[
                          const Icon(
                            Icons.verified_outlined,
                            size: 18,
                            color: AppColors.ink,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '通訊與虛擬韌體自檢',
                              style: textTheme.titleMedium,
                            ),
                          ),
                          Icon(
                            _diagnosticsExpanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            color: AppColors.inkMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_diagnosticsExpanded) ...<Widget>[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          OutlinedButton.icon(
                            key: const Key('btn_protocol_self_check'),
                            onPressed: _protoRunning ? null : _runProtocolCheck,
                            icon: const Icon(Icons.verified_outlined, size: 18),
                            label: Text(
                              _protoRunning ? '執行中...' : '執行 v1.2 協定與佇列實機自檢',
                            ),
                          ),
                          if (_protoResult != null) ...<Widget>[
                            const SizedBox(height: 10),
                            _DiagnosticResultBox(
                              key: const Key('txt_protocol_self_check_result'),
                              text: _protoResult!,
                              hasError: _protoError,
                            ),
                          ],
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            key: const Key('btn_mock_ble_self_check'),
                            onPressed: _mockRunning ? null : _runMockCheck,
                            icon: const Icon(Icons.memory_outlined, size: 18),
                            label: Text(
                              _mockRunning ? '執行中...' : '執行 Mock 虛擬韌體閉環自檢',
                            ),
                          ),
                          if (_mockResult != null) ...<Widget>[
                            const SizedBox(height: 10),
                            _DiagnosticResultBox(
                              key: const Key('txt_mock_ble_self_check_result'),
                              text: _mockResult!,
                              hasError: _mockError,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingHeaderRow extends StatelessWidget {
  const _SettingHeaderRow({
    required this.label,
    required this.valueKey,
    required this.valueText,
  });

  final String label;
  final Key valueKey;
  final String valueText;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(label, style: textTheme.bodyLarge),
        Text(
          valueText,
          key: valueKey,
          style: textTheme.titleMedium,
        ),
      ],
    );
  }
}

class _DiagnosticResultBox extends StatelessWidget {
  const _DiagnosticResultBox({
    super.key,
    required this.text,
    required this.hasError,
  });

  final String text;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final accent = hasError ? AppColors.signalFocus : AppColors.signalBreak;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
