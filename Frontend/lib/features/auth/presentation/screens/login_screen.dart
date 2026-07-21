import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

enum ServerConfigOption {
  defaultServer,
  demoOffline,
  customServer,
}

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
  ServerConfigOption _selectedServerOption = ServerConfigOption.demoOffline;

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
    if (settings.useSimulatedStream) {
      _selectedServerOption = ServerConfigOption.demoOffline;
    } else if (settings.serverUrl == 'https://signmind.harumi.dev' ||
        settings.serverUrl.isEmpty) {
      _selectedServerOption = ServerConfigOption.defaultServer;
    } else {
      _selectedServerOption = ServerConfigOption.customServer;
    }
  }

  void _onServerOptionSelected(ServerConfigOption? option) {
    if (option == null) return;
    setState(() {
      _selectedServerOption = option;
      if (option == ServerConfigOption.demoOffline) {
        _isDemoMode = true;
      } else {
        _isDemoMode = false;
        if (option == ServerConfigOption.defaultServer) {
          _urlController.text = 'https://signmind.harumi.dev';
        }
      }
    });
  }

  String _getOptionShortLabel(ServerConfigOption option) {
    return switch (option) {
      ServerConfigOption.defaultServer => 'เซิร์ฟเวอร์หลัก',
      ServerConfigOption.demoOffline => 'โหมดสาธิตออฟไลน์',
      ServerConfigOption.customServer => 'กำหนดที่อยู่เซิร์ฟเวอร์เอง',
    };
  }

  String _getOptionLongLabel(ServerConfigOption option) {
    return switch (option) {
      ServerConfigOption.defaultServer => 'เซิร์ฟเวอร์หลัก (Main Server)',
      ServerConfigOption.demoOffline => 'โหมดสาธิตออฟไลน์ (Demo Offline)',
      ServerConfigOption.customServer => 'กำหนดที่อยู่เซิร์ฟเวอร์เอง (Custom URL)',
    };
  }

  IconData _getOptionIcon(ServerConfigOption option) {
    return switch (option) {
      ServerConfigOption.defaultServer => Icons.cloud_outlined,
      ServerConfigOption.demoOffline => Icons.cloud_off_outlined,
      ServerConfigOption.customServer => Icons.tune_outlined,
    };
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
      backgroundColor: context.scaffoldBackgroundColor,
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
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.asset(
                            'assets/icons/app_icon.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'SignMind AI',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: context.textColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ระบบแปลภาษามือไทยเรียลไทม์',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.textMutedColor.withAlpha(220),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Minimal Server Configuration (Dropdown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'เซิร์ฟเวอร์:',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textMutedColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryAccent.withAlpha(25),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: AppTheme.primaryAccent.withAlpha(100),
                                width: 1.2,
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<ServerConfigOption>(
                                key: const Key('serverModeDropdown'),
                                value: _selectedServerOption,
                                isExpanded: true,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: AppTheme.primaryAccent,
                                  size: 18,
                                ),
                                dropdownColor: context.cardColor,
                                borderRadius: BorderRadius.circular(14),
                                onChanged: _onServerOptionSelected,
                                selectedItemBuilder: (BuildContext context) {
                                  return ServerConfigOption.values.map<Widget>((
                                    option,
                                  ) {
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        _getOptionShortLabel(option),
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.primaryAccent,
                                        ),
                                      ),
                                    );
                                  }).toList();
                                },
                                items: ServerConfigOption.values.map((option) {
                                  return DropdownMenuItem<ServerConfigOption>(
                                    value: option,
                                    child: Row(
                                      children: [
                                        Icon(
                                          _getOptionIcon(option),
                                          size: 16,
                                          color: _selectedServerOption == option
                                              ? AppTheme.primaryAccent
                                              : context.textMutedColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            _getOptionLongLabel(option),
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight:
                                                  _selectedServerOption == option
                                                      ? FontWeight.w600
                                                      : FontWeight.normal,
                                              color: _selectedServerOption == option
                                                  ? AppTheme.primaryAccent
                                                  : context.textColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (_selectedServerOption ==
                      ServerConfigOption.customServer) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: context.cardColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ที่อยู่เซิร์ฟเวอร์ (Custom Server URL):',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.textMutedColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            key: const Key('loginServerUrlField'),
                            controller: _urlController,
                            style: TextStyle(
                              color: context.textColor,
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'https://signmind.harumi.dev',
                              hintStyle: TextStyle(
                                color: context.textMutedColor.withAlpha(150),
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
                              fillColor: context.scaffoldBackgroundColor,
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: context.borderColor,
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
                      ),
                    ),
                  ],

                  if (_isDemoMode) ...[
                    // Offline Demo Card
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: context.cardColor,
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
                          Text(
                            'โหมดสาธิตออฟไลน์ (Simulated Mode)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: context.textColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'จำลองการตรวจจับภาษามือ 5 คำพื้นฐานแบบเรียลไทม์โดยไม่ต้องพึ่งพาเซิร์ฟเวอร์ภายนอก เหมาะสำหรับทดสอบ UI และการใช้งานเบื้องต้น',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: context.textMutedColor.withAlpha(220),
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
                        color: context.cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: context.borderColor,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TabBar(
                            controller: _tabController,
                            indicatorColor: AppTheme.primaryAccent,
                            labelColor: context.textColor,
                            unselectedLabelColor: context.textMutedColor,
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
                                      style: TextStyle(
                                        color: context.textColor,
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
                            style: TextStyle(color: context.textColor),
                            decoration: InputDecoration(
                              labelText: 'อีเมล (Email)',
                              labelStyle: TextStyle(
                                color: context.textMutedColor,
                              ),
                              prefixIcon: const Icon(
                                Icons.email_outlined,
                                color: AppTheme.primaryAccent,
                              ),
                              filled: true,
                              fillColor: context.scaffoldBackgroundColor,
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
                            style: TextStyle(color: context.textColor),
                            decoration: InputDecoration(
                              labelText: 'รหัสผ่าน (Password)',
                              labelStyle: TextStyle(
                                color: context.textMutedColor,
                              ),
                              prefixIcon: const Icon(
                                Icons.lock_outline,
                                color: AppTheme.primaryAccent,
                              ),
                              filled: true,
                              fillColor: context.scaffoldBackgroundColor,
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
                                            context.textMutedColor.withAlpha(180),
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
                                            context.textColor.withAlpha(230),
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
