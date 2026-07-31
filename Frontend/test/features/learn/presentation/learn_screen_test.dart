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
  testWidgets('roadmap shows lesson icons only — no topic names, no words',
      (tester) async {
    await tester.pumpWidget(_wrap());
    // Let the simulated repository's fetch delays resolve.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('เรียนรู้ภาษามือ'), findsOneWidget);

    // The path itself names nothing: neither topic titles nor their words.
    expect(find.text('คำพื้นฐานและทักทาย'), findsNothing);
    expect(find.text('ผู้คนและครอบครัว'), findsNothing);
    expect(find.text('ขอโทษ'), findsNothing);

    // Nodes render with their progress ring. The count is not asserted: the
    // ListView only builds the nodes inside the test viewport.
    expect(find.text('👋'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('pressing a lesson icon opens the sheet and starts the topic',
      (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump(const Duration(milliseconds: 500));

    // The icon itself is the tap target.
    await tester.tap(find.text('👋'));
    await tester.pumpAndSettle();

    // The sheet is where the lesson gets named, counted, and started.
    expect(find.text('คำพื้นฐานและทักทาย'), findsOneWidget);
    expect(find.text('ผ่านแล้ว 0 จาก 5 คำ'), findsOneWidget);
    expect(find.text('เริ่มเรียน'), findsOneWidget);
    // Still no word list, even in the sheet.
    expect(find.text('ขอโทษ'), findsNothing);
  });

  testWidgets('a finished topic offers ฝึกทำใหม่ behind a confirmation',
      (tester) async {
    final repo = SimulatedLearnRepository();
    // runAsync: the repository's fetches sleep on a real timer, which the
    // fake clock inside testWidgets would never advance.
    await tester.runAsync(() async {
      final topics = await repo.fetchTopics();
      for (final exercise in topics.first.exercises) {
        await repo.recordAttempt(exercise.id, 0.95);
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [learnRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: LearnScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('👋'));
    await tester.pumpAndSettle();

    expect(find.text('ผ่านแล้ว 5 จาก 5 คำ'), findsOneWidget);
    expect(find.text('ฝึกทำใหม่'), findsOneWidget);
    expect(find.text('เริ่มเรียน'), findsNothing);

    // Wiping progress is destructive, so it asks first.
    await tester.tap(find.text('ฝึกทำใหม่'));
    await tester.pumpAndSettle();
    expect(find.text('ฝึกทำใหม่?'), findsOneWidget);
    expect(find.text('ล้างและเริ่มใหม่'), findsOneWidget);

    // Backing out leaves the progress untouched.
    await tester.tap(find.text('ยกเลิก'));
    await tester.pumpAndSettle();
    expect(await repo.fetchProgress(), hasLength(5));
  });

  testWidgets('a locked topic offers no start button', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump(const Duration(milliseconds: 500));

    // Second seeded topic is locked until the first one is finished.
    await tester.tap(find.byIcon(Icons.lock_outline).first);
    await tester.pumpAndSettle();

    expect(find.text('ผู้คนและครอบครัว'), findsOneWidget);
    expect(find.text('ผ่านหัวข้อก่อนหน้าเพื่อปลดล็อก'), findsOneWidget);
    expect(find.text('เริ่มเรียน'), findsNothing);
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
