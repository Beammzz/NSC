import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';

class MainScaffold extends ConsumerWidget {
  const MainScaffold({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  void _onTap(BuildContext context, int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = navigationShell.currentIndex;

    // Publish the active tab so tab-scoped resources (e.g. the scanner's
    // native camera preview) mount only while their tab is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(bottomTabIndexProvider) != currentIndex) {
        ref.read(bottomTabIndexProvider.notifier).setIndex(currentIndex);
      }
    });

    final tabs = [
      _TabItem(label: 'สแกน', glyph: '⌘', index: 0),
      _TabItem(label: 'เรียนรู้', glyph: '📖', index: 1),
      _TabItem(label: 'ตั้งค่า', glyph: '⚙', index: 2),
    ];

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTheme.darkNavy,
          border: Border(
            top: BorderSide(color: AppTheme.borderDark, width: 1),
          ),
        ),
        padding: const EdgeInsets.only(top: 8, bottom: 24, left: 8, right: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: tabs.map((tab) {
            final isSelected = currentIndex == tab.index;
            final iconBg = isSelected
                ? AppTheme.primaryAccent
                : AppTheme.borderDark.withAlpha(35);
            final iconFg = isSelected ? Colors.white : AppTheme.textMutedDark;
            final labelColor = isSelected ? AppTheme.textLight : AppTheme.textMutedDark;

            return GestureDetector(
              onTap: () => _onTap(context, tab.index),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: iconBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        tab.glyph,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: iconFg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _TabItem {
  final String label;
  final String glyph;
  final int index;

  _TabItem({required this.label, required this.glyph, required this.index});
}

/// The active bottom-navigation tab index (0 = scanner). Kept in sync by
/// [MainScaffold] so tab-scoped widgets can react to visibility.
class BottomTabIndex extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) => state = index;
}

final bottomTabIndexProvider =
    NotifierProvider<BottomTabIndex, int>(BottomTabIndex.new);
