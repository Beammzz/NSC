import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

void main() {
  testWidgets('SignAvatar renders procedural figure when frames are empty or null',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SignAvatar(word: 'สวัสดี', frames: null),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(SignAvatar), findsOneWidget);
  });

  testWidgets('SignAvatar renders data frame keypoints including hand keypoints',
      (tester) async {
    // 7 pose points + 1 hand point to verify both head/body and hand loops execute.
    final sampleFrames = [
      List.generate(8, (i) => LandmarkPoint(0.1 * i, 0.1 * i, 0.0)),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SignAvatar(word: '1', frames: sampleFrames),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(SignAvatar), findsOneWidget);
  });
}
