import 'package:flutter/foundation.dart';

@immutable
class AuthUser {
  final int id;
  final String email;
  final String role;

  const AuthUser({
    required this.id,
    required this.email,
    required this.role,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['id'] as num).toInt(),
      email: json['email'] as String,
      role: json['role'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'role': role,
  };
}

@immutable
class AuthState {
  final AuthUser? user;
  final String? accessToken;
  final bool isLoading;
  final String? error;
  final bool isSimulatedGuest;

  const AuthState({
    this.user,
    this.accessToken,
    this.isLoading = false,
    this.error,
    this.isSimulatedGuest = false,
  });

  bool get isAuthenticated => user != null || isSimulatedGuest;

  AuthState copyWith({
    AuthUser? user,
    String? accessToken,
    bool? isLoading,
    String? error,
    bool? isSimulatedGuest,
    bool clearUser = false,
    bool clearError = false,
  }) {
    return AuthState(
      user: clearUser ? null : (user ?? this.user),
      accessToken: clearUser ? null : (accessToken ?? this.accessToken),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isSimulatedGuest: clearUser ? false : (isSimulatedGuest ?? this.isSimulatedGuest),
    );
  }
}
