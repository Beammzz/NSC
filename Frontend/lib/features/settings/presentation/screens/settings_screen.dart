import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/settings/presentation/providers/ota_update_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: ref.read(settingsProvider).serverUrl,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final connectionStatus = settings.useSimulatedStream
        ? ConnectionStatus.connected
        : ref.watch(tslConnectionStatusProvider).value ??
              ConnectionStatus.disconnected;

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Text(
                    'การตั้งค่า',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: context.textColor,
                    ),
                  ),
                ],
              ),
            ),

            // Scrollable Settings Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionHeader('การแสดงผลและธีม (Display & Theme)'),
                    _buildCard(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'รูปแบบธีม (App Theme)',
                                style: TextStyle(
                                  color: context.textColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'เลือกธีมการแสดงผลของแอปพลิเคชัน',
                                style: TextStyle(
                                  color: context.textMutedColor.withAlpha(200),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _buildThemeSelector(
                                settings.themeMode,
                                notifier.setThemeMode,
                              ),
                            ],
                          ),
                        ),
                        _buildDivider(),
                        SwitchListTile(
                          title: Text(
                            'แสดงโครงกระดูกมือ (Hand Skeleton)',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'แสดงเส้นและจุด MediaPipe บนภาพกล้อง',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.showHandSkeleton,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleHandSkeleton,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _buildSectionHeader(
                      'การตรวจจับและกล้อง (Camera & Scanner)',
                    ),
                    _buildCard(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'ความเชื่อมั่นขั้นต่ำ (Confidence)',
                                    style: TextStyle(
                                      color: context.textColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    '≥ ${(settings.confidenceThreshold * 100).round()}%',
                                    style: const TextStyle(
                                      color: AppTheme.primaryAccent,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'ระบบจะแสดงคำแปลเมื่อความแม่นยำสูงกว่าค่านี้',
                                style: TextStyle(
                                  color: context.textMutedColor.withAlpha(200),
                                  fontSize: 12,
                                ),
                              ),
                              Slider(
                                value: settings.confidenceThreshold,
                                min: 0.70,
                                max: 0.95,
                                divisions: 5,
                                activeColor: AppTheme.primaryAccent,
                                onChanged: notifier.setConfidenceThreshold,
                              ),
                            ],
                          ),
                        ),
                        _buildDivider(),
                        ListTile(
                          title: Text(
                            'ความละเอียดกล้องหลัง',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'เลือกความคมชัดสำหรับการสแกนท่าทาง',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          trailing: DropdownButton<String>(
                            value: settings.cameraResolution,
                            dropdownColor: context.cardColor,
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w600,
                            ),
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(
                                value: '480p',
                                child: Text('480p SD'),
                              ),
                              DropdownMenuItem(
                                value: '720p',
                                child: Text('720p (แนะนำ)'),
                              ),
                              DropdownMenuItem(
                                value: '1080p',
                                child: Text('1080p HD'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                notifier.setCameraResolution(val);
                              }
                            },
                          ),
                        ),
                        _buildDivider(),
                        SwitchListTile(
                          title: Text(
                            'โหมดดีบัก (Debug Mode)',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'แสดง FPS, เวลาหน่วง, และค่าความเชื่อมั่นบนกล้อง',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.showDebugOverlay,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleDebugOverlay,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _buildSectionHeader(
                      'เสียงและการสั่นแจ้งเตือน (Audio & Haptics)',
                    ),
                    _buildCard(
                      children: [
                        SwitchListTile(
                          title: Text(
                            'อ่านออกเสียงอัตโนมัติ (Auto TTS)',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'พูดข้อความที่แปลได้ทันทีเมื่อตรวจพบประโยค',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.autoSpeak,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleAutoSpeak,
                        ),
                        _buildDivider(),
                        SwitchListTile(
                          title: Text(
                            'สั่นแจ้งเตือนเมื่อพบคำศัพท์',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'ตอบสนองด้วยการสั่นสั้นๆ เมื่อแปลผลสำเร็จ',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.hapticFeedback,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleHapticFeedback,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _buildSectionHeader('เซิร์ฟเวอร์ (Server Connection)'),
                    _buildCard(
                      children: [
                        SwitchListTile(
                          title: Text(
                            'โหมดจำลอง (Demo Mode)',
                            style: TextStyle(
                              color: context.textColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'ใช้ข้อมูลตัวอย่างแทนการเชื่อมต่อเซิร์ฟเวอร์จริง',
                            style: TextStyle(
                              color: context.textMutedColor.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.useSimulatedStream,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleSimulatedStream,
                        ),
                        _buildDivider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ที่อยู่เซิร์ฟเวอร์ที่ใช้งาน (Connected Server IP)',
                                style: TextStyle(
                                  color: context.textColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: context.isDarkMode
                                      ? AppTheme.darkNavy
                                      : AppTheme.lightSurface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: context.borderColor,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.dns_outlined,
                                      color: AppTheme.primaryAccent,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        settings.useSimulatedStream
                                            ? 'โหมดสาธิตออฟไลน์ (Simulated Mode)'
                                            : settings.serverUrl,
                                        style: TextStyle(
                                          color: context.textColor,
                                          fontFamily: 'monospace',
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  key: const Key('changeServerLoginButton'),
                                  onPressed: () {
                                    ref.read(authProvider.notifier).logout();
                                    context.go('/login');
                                  },
                                  icon: const Icon(Icons.login_outlined),
                                  label: const Text(
                                    'เปลี่ยนเซิร์ฟเวอร์ / เข้าสู่ระบบ (Login Page)',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _buildSectionHeader('เกี่ยวกับแอปพลิเคชัน (About System)'),
                    Builder(
                      builder: (context) {
                        final otaState = ref.watch(otaUpdateProvider);
                        final otaNotifier = ref.read(otaUpdateProvider.notifier);
                        final versionString = otaState.currentPatch != null
                            ? 'SignMind AI v1.0.0 (Patch #${otaState.currentPatch})'
                            : 'SignMind AI v1.0.0';

                        return _buildCard(
                          children: [
                            ListTile(
                              leading: Container(
                                width: 40,
                                height: 40,
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryAccent.withAlpha(46),
                                  shape: BoxShape.circle,
                                ),
                                child: Image.asset(
                                  'assets/icons/app_icon.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                              title: Text(
                                versionString,
                                style: TextStyle(
                                  color: context.textColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Made with Love by Beammzz, Chengzy-gif, KrasidithSun ❤️',
                                style: TextStyle(
                                  color: context.textMutedColor.withAlpha(200),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            _buildDivider(),
                            _buildOtaUpdateSection(
                              context,
                              otaState,
                              otaNotifier,
                            ),
                            _buildDivider(),
                            Builder(
                              builder: (context) {
                                final (
                                  label,
                                  thaiLabel,
                                  color,
                                  icon,
                                ) = switch (connectionStatus) {
                                  ConnectionStatus.connected => (
                                    'ACTIVE',
                                    'สถานะ: เชื่อมต่อและพร้อมใช้งาน (WebSocket WSS)',
                                    AppTheme.successGreen,
                                    Icons.cloud_done_outlined,
                                  ),
                                  ConnectionStatus.connecting => (
                                    'CONNECTING',
                                    'สถานะ: กำลังเชื่อมต่อ...',
                                    AppTheme.warningOrange,
                                    Icons.cloud_sync_outlined,
                                  ),
                                  ConnectionStatus.disconnected => (
                                    'DISCONNECTED',
                                    'สถานะ: ไม่ได้เชื่อมต่อกับเซิร์ฟเวอร์',
                                    context.textMutedColor,
                                    Icons.cloud_off_outlined,
                                  ),
                                };
                                return ListTile(
                                  leading: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: color.withAlpha(46),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(icon, color: color),
                                  ),
                                  title: Text(
                                    'เซิร์ฟเวอร์ AI & gRPC',
                                    style: TextStyle(
                                      color: context.textColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    thaiLabel,
                                    style: TextStyle(
                                      color: context.textMutedColor.withAlpha(200),
                                      fontSize: 12,
                                    ),
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: color.withAlpha(46),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: color.withAlpha(128),
                                      ),
                                    ),
                                    child: Text(
                                      label,
                                      style: TextStyle(
                                        color: color,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeSelector(
    ThemeMode currentMode,
    ValueChanged<ThemeMode> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildThemeOption(
            title: 'อัตโนมัติ',
            subtitle: 'System',
            icon: Icons.brightness_auto_outlined,
            mode: ThemeMode.system,
            currentMode: currentMode,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeOption(
            title: 'โหมดมืด',
            subtitle: 'Dark',
            icon: Icons.dark_mode_outlined,
            mode: ThemeMode.dark,
            currentMode: currentMode,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeOption(
            title: 'โหมดสว่าง',
            subtitle: 'Light',
            icon: Icons.light_mode_outlined,
            mode: ThemeMode.light,
            currentMode: currentMode,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildThemeOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required ThemeMode mode,
    required ThemeMode currentMode,
    required ValueChanged<ThemeMode> onChanged,
  }) {
    final isSelected = currentMode == mode;
    final color = isSelected ? AppTheme.primaryAccent : context.textMutedColor;
    final bgColor = isSelected
        ? AppTheme.primaryAccent.withAlpha(46)
        : (context.isDarkMode
            ? AppTheme.darkNavy.withAlpha(128)
            : AppTheme.lightSurface);
    final borderColor = isSelected
        ? AppTheme.primaryAccent
        : context.borderColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(mode),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected
                    ? (context.isDarkMode
                        ? Colors.white
                        : AppTheme.primaryAccentHover)
                    : color,
                size: 22,
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: TextStyle(
                  color: isSelected
                      ? (context.isDarkMode
                          ? Colors.white
                          : AppTheme.primaryAccentHover)
                      : context.textColor,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: color.withAlpha(200),
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.textMutedColor,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.borderColor, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: context.cardColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(color: context.borderColor, height: 1, thickness: 1);
  }

  Widget _buildOtaUpdateSection(
    BuildContext context,
    OtaUpdateState otaState,
    OtaUpdateNotifier otaNotifier,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.system_update_outlined,
                    color: AppTheme.primaryAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'อัปเดตแอปพลิเคชัน (Shorebird OTA)',
                    style: TextStyle(
                      color: context.textColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              if (otaState.status == OtaStatus.checking)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.primaryAccent,
                  ),
                )
              else if (otaState.status == OtaStatus.updateAvailable)
                _buildBadge('UPDATE AVAILABLE', AppTheme.warningOrange)
              else if (otaState.status == OtaStatus.readyToRestart)
                _buildBadge('PATCH READY', AppTheme.successGreen)
              else if (otaState.status == OtaStatus.upToDate)
                _buildBadge('LATEST', AppTheme.successGreen)
              else if (!otaState.isAvailable)
                _buildBadge('BASE RELEASE', context.textMutedColor),
            ],
          ),
          const SizedBox(height: 8),
          if (otaState.status == OtaStatus.downloading) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'กำลังดาวน์โหลดอัปเดต...',
                  style: TextStyle(
                    color: context.textColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '${(otaState.downloadProgress * 100).toInt()}%',
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: otaState.downloadProgress,
                backgroundColor: AppTheme.primaryAccent.withAlpha(30),
                color: AppTheme.primaryAccent,
                minHeight: 6,
              ),
            ),
          ] else if (otaState.status == OtaStatus.readyToRestart) ...[
            Text(
              'ดาวน์โหลดและติดตั้งอัปเดตเรียบร้อยแล้ว กรุณารีสตาร์ทแอปเพื่อปรับใช้แพตช์',
              style: TextStyle(
                color: context.textMutedColor.withAlpha(220),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('restartAppButton'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.successGreen,
                  foregroundColor: Colors.white,
                ),
                onPressed: otaNotifier.restartApp,
                icon: const Icon(Icons.restart_alt_outlined),
                label: const Text('รีสตาร์ทแอปพลิเคชัน (Restart App)'),
              ),
            ),
          ] else if (otaState.status == OtaStatus.updateAvailable) ...[
            Text(
              'พบแพตช์อัปเดตใหม่ สามารถดาวน์โหลดและติดตั้งได้ทันที',
              style: TextStyle(
                color: context.textMutedColor.withAlpha(220),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('downloadUpdateButton'),
                onPressed: otaNotifier.downloadUpdate,
                icon: const Icon(Icons.download_outlined),
                label: const Text('ดาวน์โหลดอัปเดต (Download Update)'),
              ),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    !otaState.isAvailable
                        ? 'ระบบอัปเดต Shorebird (พร้อมใช้งานในโหมด Release)'
                        : (otaState.status == OtaStatus.upToDate
                            ? 'แอปพลิเคชันของคุณเป็นเวอร์ชันล่าสุดแล้ว'
                            : 'ตรวจสอบสถานะอัปเดตล่าสุดจาก Shorebird'),
                    style: TextStyle(
                      color: context.textMutedColor.withAlpha(200),
                      fontSize: 12,
                    ),
                  ),
                ),
                if (otaState.isAvailable)
                  TextButton.icon(
                    key: const Key('checkForUpdatesButton'),
                    onPressed: otaNotifier.checkPatchVersionAndStatus,
                    icon: const Icon(Icons.refresh_outlined, size: 16),
                    label: const Text('ตรวจสอบ', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

