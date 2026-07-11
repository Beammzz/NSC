import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/widgets/main_scaffold.dart';
import 'package:signmind/features/ai_tutor/presentation/screens/ai_tutor_screen.dart';
import 'package:signmind/features/conversation/presentation/screens/conversation_screen.dart';
import 'package:signmind/features/learn/presentation/screens/learn_screen.dart';
import 'package:signmind/features/scanner/presentation/screens/scanner_screen.dart';
import 'package:signmind/features/settings/presentation/screens/settings_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/scanner',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainScaffold(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/scanner',
                pageBuilder: (context, state) => const NoTransitionPage(
                  child: ScannerScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/tutor',
                pageBuilder: (context, state) => const NoTransitionPage(
                  child: AiTutorScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/conversation',
                pageBuilder: (context, state) => const NoTransitionPage(
                  child: ConversationScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/learn',
                pageBuilder: (context, state) => const NoTransitionPage(
                  child: LearnScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => const NoTransitionPage(
                  child: SettingsScreen(),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
