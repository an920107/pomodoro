import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/protocol/protocol_exceptions.dart';
import '../../core/theme/app_theme.dart';
import '../../data/ble/ble_repository.dart';
import '../../data/ble/real_ble_repository.dart';
import '../../state/ble_providers.dart';

/// Modal bottom sheet for toggling Mock/Real BLE mode, inspecting adapter &
/// permission readiness, scanning peripherals, and connecting to SmartPomodoro.
class DeviceScanSheet extends ConsumerStatefulWidget {
  const DeviceScanSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const DeviceScanSheet(key: Key('sheet_device_scan')),
    );
  }

  @override
  ConsumerState<DeviceScanSheet> createState() => _DeviceScanSheetState();
}

class _DeviceScanSheetState extends ConsumerState<DeviceScanSheet> {
  late bool _includeAllDevices;
  String? _connectingDeviceId;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(bleRepositoryProvider);
    _includeAllDevices = repo is RealBleRepository ? repo.includeAllDevices : false;
  }

  Future<void> _startScan() async {
    final repo = ref.read(bleRepositoryProvider);
    try {
      await repo.startScan(includeAllDevices: _includeAllDevices);
    } on PomodoroProtocolException {
      // Error surfaced reactively through connectionStream banner inside sheet.
    }
  }

  Future<void> _connectTo(BleDeviceItem device) async {
    if (_connectingDeviceId != null) return;
    setState(() {
      _connectingDeviceId = device.id;
    });
    final repo = ref.read(bleRepositoryProvider);
    try {
      await repo.connect(device.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on PomodoroProtocolException {
      // Error surfaced via connectionStream card inside sheet.
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
        });
      }
    }
  }

  void _toggleIncludeAll(bool? value) {
    final next = value ?? false;
    setState(() {
      _includeAllDevices = next;
    });
    final repo = ref.read(bleRepositoryProvider);
    if (repo is RealBleRepository) {
      repo.setIncludeAllDevices(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMock = ref.watch(isMockBleModeProvider);
    final repo = ref.watch(bleRepositoryProvider);
    final connection =
        ref.watch(bleConnectionProvider).asData?.value ?? repo.currentConnection;
    final devices =
        ref.watch(bleScanResultsProvider).asData?.value ?? const <BleDeviceItem>[];
    final textTheme = Theme.of(context).textTheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    final isScanning = connection.state == BleConnectionState.scanning;
    final isConnecting =
        connection.state == BleConnectionState.connecting ||
        _connectingDeviceId != null;

    return SizedBox(
      height: maxHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '藍牙裝置與通訊模式',
                        style: textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '預設使用 Mock 虛擬韌體；接上 ESP32 時請切換為 Real BLE',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('btn_close_scan_sheet'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    key: const Key('btn_sheet_switch_mock'),
                    label: const Text('Mock 虛擬韌體 (預設)'),
                    selected: isMock,
                    onSelected: (_) {
                      ref.read(isMockBleModeProvider.notifier).setMockMode(true);
                    },
                  ),
                  ChoiceChip(
                    key: const Key('btn_sheet_switch_real'),
                    label: const Text('Real BLE 實體連線'),
                    selected: !isMock,
                    onSelected: (_) {
                      ref.read(isMockBleModeProvider.notifier).setMockMode(false);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (isMock) ...<Widget>[
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.memory_rounded,
                            size: 36,
                            color: AppColors.signalBreak,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '目前為 Mock 虛擬韌體模式',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '已自動連線至虛擬裝置 ${connection.device?.name ?? 'SmartPomodoro (Mock)'}。若要測試手機系統藍牙權限、真實 BLE 掃描或連接實體 ESP32，請上方切換至「Real BLE 實體連線」。',
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium?.copyWith(
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ] else ...<Widget>[
              if (!connection.isBluetoothAdapterOn) ...<Widget>[
                Container(
                  key: const Key('card_bt_adapter_off'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.signalFocus, width: 1.5),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.bluetooth_disabled_rounded,
                        color: AppColors.signalFocus,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '手機藍牙未開啟，請開啟系統藍牙以搜尋並連線 SmartPomodoro',
                          style: textTheme.bodyMedium?.copyWith(
                            color: AppColors.signalFocus,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ] else if (connection.errorMessage != null) ...<Widget>[
                Container(
                  key: const Key('card_ble_scan_error'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.signalWarn, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: AppColors.signalWarn,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              connection.errorMessage!,
                              style: textTheme.bodySmall?.copyWith(
                                color: AppColors.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (repo is RealBleRepository &&
                          (connection.errorMessage!.contains('權限') ||
                              connection.errorMessage!.contains('設定'))) ...<
                        Widget
                      >[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('btn_open_app_settings'),
                          onPressed: () {
                            unawaited(repo.openPermissionSettings());
                          },
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text('開啟系統權限設定'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (connection.state.isConnected &&
                  connection.device != null) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.signalBreak),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.bluetooth_connected_rounded,
                        color: AppColors.signalBreak,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              connection.device!.name,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              connection.device!.id,
                              style: textTheme.labelSmall?.copyWith(
                                color: AppColors.inkMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton(
                        key: const Key('btn_disconnect_ble'),
                        onPressed: () {
                          unawaited(repo.disconnect());
                        },
                        child: const Text('中斷連線'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('btn_start_ble_scan'),
                      onPressed: (!connection.isBluetoothAdapterOn ||
                              isConnecting)
                          ? null
                          : (isScanning ? () => unawaited(repo.stopScan()) : _startScan),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.ink,
                        foregroundColor: AppColors.surface,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: Icon(
                        isScanning
                            ? Icons.stop_circle_outlined
                            : Icons.bluetooth_searching_rounded,
                        size: 18,
                      ),
                      label: Text(isScanning ? '停止掃描' : '開始掃描 (10s)'),
                    ),
                  ),
                ],
              ),
              if (isScanning) ...<Widget>[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 3),
              ],
              CheckboxListTile(
                key: const Key('checkbox_include_all_ble'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: const Text('顯示全部附近 BLE 裝置'),
                subtitle: const Text(
                  '預設僅顯示 SmartPomodoro / ...5600 廣播裝置',
                ),
                value: _includeAllDevices,
                onChanged: _toggleIncludeAll,
              ),
              const SizedBox(height: 4),
              Expanded(
                child: devices.isEmpty
                    ? Container(
                        key: const Key('empty_ble_scan_results'),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceRecessed,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  isScanning
                                      ? Icons.radar_rounded
                                      : Icons.bluetooth_searching_rounded,
                                  size: 30,
                                  color: AppColors.inkMuted,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  isScanning
                                      ? '正在掃描附近 BLE 裝置...'
                                      : '找不到 SmartPomodoro 裝置（可切換回 Mock 模式進行測試）',
                                  textAlign: TextAlign.center,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                if (!isScanning)
                                  FilledButton.tonalIcon(
                                    key: const Key('btn_empty_fallback_mock'),
                                    onPressed: () {
                                      ref
                                          .read(isMockBleModeProvider.notifier)
                                          .setMockMode(true);
                                    },
                                    icon: const Icon(
                                      Icons.memory_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('切回 Mock 模擬模式'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: devices.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          final isThisConnected =
                              connection.state.isConnected &&
                              connection.device?.id == device.id;
                          final isThisConnecting = _connectingDeviceId == device.id;
                          return Container(
                            key: Key('ble_device_tile_${device.id}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: device.matchesPomodoroService
                                    ? AppColors.signalBreak
                                    : AppColors.border,
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.bluetooth_rounded,
                                  color: device.matchesPomodoroService
                                      ? AppColors.signalBreak
                                      : AppColors.inkMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        device.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        '${device.id} · ${device.rssi} dBm',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.labelSmall?.copyWith(
                                          color: AppColors.inkMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  key: Key('btn_connect_device_${device.id}'),
                                  onPressed:
                                      (isThisConnected ||
                                          isConnecting ||
                                          !connection.isBluetoothAdapterOn)
                                      ? null
                                      : () => _connectTo(device),
                                  child: Text(
                                    isThisConnected
                                        ? '已連線'
                                        : (isThisConnecting ? '連線中' : '連線'),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
