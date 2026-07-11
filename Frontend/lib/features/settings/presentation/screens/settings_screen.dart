import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
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
      backgroundColor: AppTheme.darkNavy,
      body: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  const Text(
                    'การตั้งค่า',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textLight,
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
                        SwitchListTile(
                          title: const Text(
                            'โหมดกลางคืน (Dark Mode)',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'ปรับโทนสีพื้นหลังให้สบายตาในที่มืด',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.isDarkMode,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleDarkMode,
                        ),
                        _buildDivider(),
                        SwitchListTile(
                          title: const Text(
                            'แสดงโครงกระดูกมือ (Hand Skeleton)',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'แสดงเส้นและจุด MediaPipe บนภาพกล้อง',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
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
                                  const Text(
                                    'ความเชื่อมั่นขั้นต่ำ (Confidence)',
                                    style: TextStyle(
                                      color: AppTheme.textLight,
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
                                  color: AppTheme.textMutedDark.withAlpha(200),
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
                          title: const Text(
                            'ความละเอียดกล้องหลัง',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'เลือกความคมชัดสำหรับการสแกนท่าทาง',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          trailing: DropdownButton<String>(
                            value: settings.cameraResolution,
                            dropdownColor: AppTheme.cardDark,
                            style: const TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w600,
                            ),
                            underline: const SizedBox(),
                            items: const [
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
                      ],
                    ),
                    const SizedBox(height: 24),

                    _buildSectionHeader(
                      'เสียงและการสั่นแจ้งเตือน (Audio & Haptics)',
                    ),
                    _buildCard(
                      children: [
                        SwitchListTile(
                          title: const Text(
                            'อ่านออกเสียงอัตโนมัติ (Auto TTS)',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'พูดข้อความที่แปลได้ทันทีเมื่อตรวจพบประโยค',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                          value: settings.autoSpeak,
                          activeThumbColor: AppTheme.primaryAccent,
                          onChanged: notifier.toggleAutoSpeak,
                        ),
                        _buildDivider(),
                        SwitchListTile(
                          title: const Text(
                            'สั่นแจ้งเตือนเมื่อพบคำศัพท์',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'ตอบสนองด้วยการสั่นสั้นๆ เมื่อแปลผลสำเร็จ',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
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
                          title: const Text(
                            'โหมดจำลอง (Demo Mode)',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            'ใช้ข้อมูลตัวอย่างแทนการเชื่อมต่อเซิร์ฟเวอร์จริง',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
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
                              const Text(
                                'ที่อยู่เซิร์ฟเวอร์ที่ใช้งาน (Connected Server IP)',
                                style: TextStyle(
                                  color: AppTheme.textLight,
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
                                  color: AppTheme.darkNavy,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppTheme.borderDark,
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
                                        style: const TextStyle(
                                          color: AppTheme.textLight,
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
                    _buildCard(
                      children: [
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryAccent.withAlpha(46),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.info_outline,
                              color: AppTheme.primaryAccent,
                            ),
                          ),
                          title: const Text(
                            'SignMind AI v1.0.0',
                            style: TextStyle(
                              color: AppTheme.textLight,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'Made with Love by Beammzz, Chengzy-gif, KrasidithSun ❤️',
                            style: TextStyle(
                              color: AppTheme.textMutedDark.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
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
                                AppTheme.textMutedLight,
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
                              title: const Text(
                                'เซิร์ฟเวอร์ AI & gRPC',
                                style: TextStyle(
                                  color: AppTheme.textLight,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                thaiLabel,
                                style: TextStyle(
                                  color: AppTheme.textMutedDark.withAlpha(200),
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMutedLight,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderDark, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: AppTheme.cardDark,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(color: AppTheme.borderDark, height: 1, thickness: 1);
  }
}
