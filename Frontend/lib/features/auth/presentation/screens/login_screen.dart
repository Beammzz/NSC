import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _urlController;
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  late final TabController _tabController;
  bool _isDemoMode = false;
  bool _rememberCredentials = true;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _urlController = TextEditingController(text: settings.serverUrl);
    _rememberCredentials = settings.rememberCredentials;
    _emailController = TextEditingController(
      text: _rememberCredentials ? settings.savedEmail : '',
    );
    _passwordController = TextEditingController(
      text: _rememberCredentials ? settings.savedPassword : '',
    );
    _tabController = TabController(length: 2, vsync: this);
    _isDemoMode = settings.useSimulatedStream;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _toggleRememberCredentials(bool? value) {
    if (value == null) return;
    setState(() {
      _rememberCredentials = value;
    });
    ref.read(settingsProvider.notifier).setRememberCredentials(value);
  }

  Future<void> _submitLogin() async {
    FocusScope.of(context).unfocus();
    final notifier = ref.read(authProvider.notifier);
    final success = await notifier.login(
      _emailController.text,
      _passwordController.text,
      _urlController.text,
    );
    if (success && mounted) {
      ref.read(settingsProvider.notifier).saveLoginCredentials(
            _emailController.text,
            _passwordController.text,
            _rememberCredentials,
          );
      context.go('/landing');
    }
  }

  Future<void> _submitSignup() async {
    FocusScope.of(context).unfocus();
    final notifier = ref.read(authProvider.notifier);
    final success = await notifier.signup(
      _emailController.text,
      _passwordController.text,
      _urlController.text,
    );
    if (success && mounted) {
      ref.read(settingsProvider.notifier).saveLoginCredentials(
            _emailController.text,
            _passwordController.text,
            _rememberCredentials,
          );
      context.go('/landing');
    }
  }

  void _enterDemoMode() {
    FocusScope.of(context).unfocus();
    ref.read(authProvider.notifier).enterSimulatedGuestMode();
    context.go('/landing');
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: AppTheme.darkNavy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero Brand Badge
                  Center(
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppTheme.primaryAccent,
                            AppTheme.primaryAccent.withAlpha(180),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryAccent.withAlpha(80),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        '⌘',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'SignMind AI',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textLight,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ระบบแปลภาษามือไทยเรียลไทม์',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.textMutedDark.withAlpha(220),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Server IP Configuration Card (moved from Settings)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: AppTheme.cardDark,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppTheme.borderDark.withAlpha(140),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.dns_outlined,
                                    color: AppTheme.primaryAccent,
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      'ตั้งค่าเซิร์ฟเวอร์ (Server IP)',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textLight,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Demo mode chip
                            FilterChip(
                              label: Text(
                                'โหมดสาธิตออฟไลน์',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _isDemoMode
                                      ? AppTheme.darkNavy
                                      : AppTheme.textLight,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              selected: _isDemoMode,
                              selectedColor: AppTheme.primaryAccent,
                              backgroundColor: AppTheme.darkNavy,
                              onSelected: (val) {
                                setState(() {
                                  _isDemoMode = val;
                                });
                              },
                            ),
                          ],
                        ),
                        if (!_isDemoMode) ...[
                          const SizedBox(height: 12),
                          Text(
                            'ที่อยู่เซิร์ฟเวอร์ SignMind Backend (WebSocket / HTTP):',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textMutedDark.withAlpha(200),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            key: const Key('loginServerUrlField'),
                            controller: _urlController,
                            style: const TextStyle(
                              color: AppTheme.textLight,
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'https://signmind.harumi.dev',
                              hintStyle: TextStyle(
                                color: AppTheme.textMutedDark.withAlpha(150),
                                fontFamily: 'monospace',
                                fontSize: 14,
                              ),
                              prefixIcon: const Icon(
                                Icons.link,
                                color: AppTheme.primaryAccent,
                                size: 18,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              filled: true,
                              fillColor: AppTheme.darkNavy,
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: AppTheme.borderDark,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: AppTheme.primaryAccent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  if (_isDemoMode) ...[
                    // Offline Demo Card
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: AppTheme.cardDark,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.primaryAccent.withAlpha(120),
                        ),
                      ),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.cloud_off_outlined,
                            size: 40,
                            color: AppTheme.primaryAccent,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'โหมดสาธิตออฟไลน์ (Simulated Mode)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textLight,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'จำลองการตรวจจับภาษามือ 5 คำพื้นฐานแบบเรียลไทม์โดยไม่ต้องพึ่งพาเซิร์ฟเวอร์ภายนอก เหมาะสำหรับทดสอบ UI และการใช้งานเบื้องต้น',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.textMutedDark.withAlpha(220),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              key: const Key('enterDemoModeButton'),
                              onPressed: _enterDemoMode,
                              icon: const Icon(Icons.rocket_launch_outlined),
                              label: const Text(
                                'เข้าใช้งานทันที (Demo Mode)',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Live Server Auth Card
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: AppTheme.cardDark,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.borderDark.withAlpha(140),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TabBar(
                            controller: _tabController,
                            indicatorColor: AppTheme.primaryAccent,
                            labelColor: AppTheme.textLight,
                            unselectedLabelColor: AppTheme.textMutedDark,
                            labelStyle: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                            tabs: const [
                              Tab(text: 'เข้าสู่ระบบ (Sign In)'),
                              Tab(text: 'สมัครสมาชิก (Sign Up)'),
                            ],
                          ),
                          const SizedBox(height: 20),

                          if (authState.error != null) ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: const Color(0xFFCF6679).withAlpha(40),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFCF6679).withAlpha(150),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline,
                                    color: Color(0xFFCF6679),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      authState.error!,
                                      style: const TextStyle(
                                        color: AppTheme.textLight,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          TextFormField(
                            key: const Key('loginEmailField'),
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            style: const TextStyle(color: AppTheme.textLight),
                            decoration: InputDecoration(
                              labelText: 'อีเมล (Email)',
                              labelStyle: TextStyle(
                                color: AppTheme.textMutedDark.withAlpha(200),
                              ),
                              prefixIcon: const Icon(
                                Icons.email_outlined,
                                color: AppTheme.primaryAccent,
                              ),
                              filled: true,
                              fillColor: AppTheme.darkNavy,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),

                          TextFormField(
                            key: const Key('loginPasswordField'),
                            controller: _passwordController,
                            obscureText: true,
                            style: const TextStyle(color: AppTheme.textLight),
                            decoration: InputDecoration(
                              labelText: 'รหัสผ่าน (Password)',
                              labelStyle: TextStyle(
                                color: AppTheme.textMutedDark.withAlpha(200),
                              ),
                              prefixIcon: const Icon(
                                Icons.lock_outline,
                                color: AppTheme.primaryAccent,
                              ),
                              filled: true,
                              fillColor: AppTheme.darkNavy,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          InkWell(
                            key: const Key('rememberCredentialsTile'),
                            onTap: () => _toggleRememberCredentials(
                              !_rememberCredentials,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 4,
                                horizontal: 2,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Checkbox(
                                      key: const Key(
                                        'rememberCredentialsCheckbox',
                                      ),
                                      value: _rememberCredentials,
                                      activeColor: AppTheme.primaryAccent,
                                      side: BorderSide(
                                        color:
                                            AppTheme.textMutedDark.withAlpha(180),
                                        width: 1.8,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      onChanged: _toggleRememberCredentials,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'จำข้อมูลเข้าสู่ระบบ (Remember credentials)',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            AppTheme.textLight.withAlpha(230),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          AnimatedBuilder(
                            animation: _tabController,
                            builder: (context, _) {
                              final isSignin = _tabController.index == 0;
                              return SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  key: Key(
                                    isSignin
                                        ? 'loginSubmitButton'
                                        : 'signupSubmitButton',
                                  ),
                                  onPressed: authState.isLoading
                                      ? null
                                      : (isSignin
                                            ? _submitLogin
                                            : _submitSignup),
                                  child: authState.isLoading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(
                                          isSignin
                                              ? 'เข้าสู่ระบบ (Sign In)'
                                              : 'สมัครสมาชิกใหม่ (Create Account)',
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
