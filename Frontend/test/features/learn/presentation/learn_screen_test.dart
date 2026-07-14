import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/learn/data/repositories/learn_repository.dart';
import 'package:signmind/features/learn/presentation/screens/learn_screen.dart';

Widget _wrap() {
  return ProviderScope(
    overrides: [
      learnRepositoryProvider.overrideWithValue(SimulatedLearnRepository()),
    ],
    child: const MaterialApp(home: LearnScreen()),
  );
}

void main() {
  testWidgets('renders the roadmap with seeded topics and lock states',
      (tester) async {
    await tester.pumpWidget(_wrap());
    // Let the simulated repository's fetch delays resolve.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('เรียนรู้ภาษามือ'), findsOneWidget);
    expect(find.text('คำพื้นฐานและทักทาย'), findsOneWidget);
    expect(find.text('ผู้คนและครอบครัว'), findsOneWidget);

    // First topic unlocked: its exercise chips show; later topics locked.
    expect(find.text('ขอโทษ'), findsOneWidget);
    expect(find.text('ผ่านหัวข้อก่อนหน้าเพื่อปลดล็อก'), findsWidgets);
  });

  testWidgets('dictionary tab lists words grouped by category and filters',
      (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('คลังคำศัพท์'));
    // First frame builds the dictionary view and starts its fetch; the
    // second pump advances past the simulated fetch delay.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Categories near the top of the list are built and visible.
    expect(find.text('ตัวเลข'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // Filtering by category name surfaces its words and hides the rest.
    await tester.enterText(find.byType(TextField), 'สี');
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('สีแดง'), findsOneWidget);
    expect(find.text('สีเขียว'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });
}
