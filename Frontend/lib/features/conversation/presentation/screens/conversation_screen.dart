import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';

class ConversationScreen extends StatelessWidget {
  const ConversationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkNavy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'สนทนา AI',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'สะพานเชื่อมการสื่อสารระหว่างผู้ใช้ภาษามือและบุคคลทั่วไปผ่านเสียงและข้อความ',
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.textMutedDark.withAlpha(220),
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: AppTheme.cardDark,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: AppTheme.borderDark, width: 1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppTheme.successGreen.withAlpha(46),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.record_voice_over_outlined,
                            size: 32,
                            color: AppTheme.successGreen,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'โหมดสนทนาสองทาง',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textLight,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'เปลี่ยนเสียงพูดเป็นข้อความพร้อมแปลภาษามือตอบกลับแบบเรียลไทม์',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMutedDark.withAlpha(180),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () {},
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.successGreen,
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            child: Text('เริ่มการสนทนา'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
