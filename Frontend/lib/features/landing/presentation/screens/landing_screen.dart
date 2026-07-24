import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final features = [
      _FeatureCardData(
        title: 'สแกนแปลภาษามือ',
        subtitle: 'Live TSL Scanner & Translator',
        description:
            'แปลภาษามือไทยเป็นข้อความและเสียงพูดแบบเรียลไทม์ ด้วย AI วิเคราะห์ท่าทางมือและร่างกาย 441 มิติ',
        accentColor: AppTheme.successGreen,
        icon: Icons.camera_alt_outlined,
        route: '/scanner',
      ),
      _FeatureCardData(
        title: 'เรียนรู้ภาษามือ',
        subtitle: 'Dictionary & Exercises',
        description:
            'คลังคำศัพท์ภาษามือไทยพร้อมภาพจำลองท่าทาง และแบบฝึกหัดตามหมวดหมู่แบบแผนที่บทเรียน ผ่านเมื่อทำท่าถูกต้องตามเกณฑ์ความเชื่อมั่นของ AI',
        accentColor: AppTheme.warningOrange,
        icon: Icons.menu_book_outlined,
        route: '/learn',
      ),
    ];

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar / Brand Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withAlpha(50),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.primaryAccent.withAlpha(120),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Image.asset(
                          'assets/icons/app_icon.png',
                          fit: BoxFit.contain,
                          color: context.isDarkMode ? Colors.white : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SignMind AI',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: context.textColor,
                          letterSpacing: 0.3,
                        ),
                      ),
                      Text(
                        'ศูนย์แนะนำฟีเจอร์ระบบ',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMutedColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Main scrollable feature registry content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Section Title
                    Text(
                      'ฟีเจอร์ทั้งหมดในระบบ (Feature Registry)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: context.textColor,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Feature Cards
                    ...features.map((feature) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _FeatureCard(
                          data: feature,
                          onTap: () => context.go(feature.route),
                        ),
                      );
                    }),

                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),

            // Bottom floating CTA button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  key: const Key('enterMainAppHeroButton'),
                  onPressed: () => context.go('/scanner'),
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('เข้าสู่แอป'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureCardData {
  final String title;
  final String subtitle;
  final String description;
  final Color accentColor;
  final IconData icon;
  final String route;

  _FeatureCardData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.accentColor,
    required this.icon,
    required this.route,
  });
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.data,
    required this.onTap,
  });

  final _FeatureCardData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: Key('featureCard_${data.route}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: data.accentColor.withAlpha(35),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: data.accentColor.withAlpha(100)),
                ),
                alignment: Alignment.center,
                child: Icon(data.icon, color: data.accentColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: context.textMutedColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      data.description,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.textColor,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: context.textMutedColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
