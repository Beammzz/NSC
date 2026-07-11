import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';

class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});

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
                'เรียนรู้ภาษามือ',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'คลังคำศัพท์และหมวดหมู่ท่าทางพื้นฐาน 200 คำในภาษามือไทย',
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
                            color: const Color(0xFF7C4DCC).withAlpha(46),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.menu_book_outlined,
                            size: 32,
                            color: Color(0xFF7C4DCC),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'หมวดหมู่คำศัพท์พื้นฐาน',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textLight,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'ทบทวนคำศัพท์ภาษาไทยและวิดีโอตัวอย่างการทำสัญลักษณ์มือ',
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
                            backgroundColor: const Color(0xFF7C4DCC),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            child: Text('เข้าสู่คลังคำศัพท์'),
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
