import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Maps exceptions into short, non-technical copy for end users.
/// Never surfaces URLs, stack traces, hostnames, or raw API payloads.
String kpmsUserFacingMessage(Object error, {String? fallback}) {
  final resetCode = _kpmsBareExceptionCode(error);
  if (resetCode != null) {
    final mapped = _passwordResetEdgeErrorMessage(resetCode);
    if (mapped != null) return mapped;
  }
  if (error is AuthException) {
    return _authExceptionMessage(error);
  }
  if (error is SocketException) {
    return 'Unable to connect. Check your internet connection and try again.';
  }
  if (error is TimeoutException) {
    return 'The request timed out. Please wait a moment and try again.';
  }
  if (error is HttpException) {
    return 'A network error occurred. Please try again.';
  }
  if (error is HandshakeException || error is TlsException) {
    return 'A secure connection could not be established. Try again or switch networks.';
  }
  if (error is FormatException || error is TypeError) {
    return 'Some information was not in the expected format. Please review your input.';
  }

  final typeName = error.runtimeType.toString();
  if (typeName.contains('Postgrest') || typeName.contains('Realtime')) {
    return _postgresStyleMessage(error);
  }
  if (error is FunctionException) {
    final mapped = _messageForFunctionException(error);
    if (mapped != null) return mapped;
    return 'The server could not complete that action. Please try again.';
  }

  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('failed host lookup') ||
      lower.contains('socketexception') ||
      lower.contains('network is unreachable') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset')) {
    return 'Unable to connect. Check your internet connection and try again.';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return 'The request timed out. Please try again.';
  }
  if (lower.contains('jwt') && lower.contains('expired')) {
    return 'Your session has expired. Please sign in again.';
  }
  if (lower.contains('permission denied') || lower.contains('rls') || lower.contains('row-level security')) {
    return 'You do not have permission to do that.';
  }

  return fallback ?? 'Something went wrong. Please try again.';
}

/// `throw Exception('invalid_code')` from our repositories (Edge JSON `error` field).
String? _kpmsBareExceptionCode(Object error) {
  final s = error.toString();
  final m = RegExp(r'^Exception:\s*(\S+)\s*$').firstMatch(s);
  return m?.group(1);
}

String? _passwordResetEdgeErrorMessage(String code) {
  switch (code) {
    case 'invalid_code':
      return 'That verification code is incorrect. Check the code or request a new one.';
    case 'expired_code':
      return 'This code has expired. Request a new code and try again.';
    case 'rate_limited':
      return 'Too many reset requests for this email. Please wait an hour and try again.';
    case 'email_send_failed':
      return 'We could not send the email right now. Please try again in a few minutes.';
    case 'smtp_auth_failed':
      return 'Email could not be sent: sign-in to the mail server failed. Ask your administrator to check the app mail password (Gmail App Password).';
    case 'otp_storage_failed':
      return 'We could not save your reset request. Please try again in a moment.';
    case 'challenge_storage_failed':
      return 'We could not complete that step. Please request a new code and try again.';
    case 'user_lookup_failed':
      return 'Password reset is temporarily unavailable. Please try again later.';
    case 'service_unavailable':
    case 'smtp_not_configured':
      return 'Password reset is temporarily unavailable. Please try again later.';
    case 'invalid_or_expired_challenge':
      return 'This reset step has expired. Go back and verify your code again.';
    case 'password_update_failed':
      return 'Your new password could not be saved. Try a different password or start again.';
    case 'verify_locked':
      return 'Too many incorrect codes. Wait a few minutes, then request a new code.';
    case 'password_policy_failed':
      return 'Your password must be at least 8 characters.';
    case 'invalid_input':
    case 'invalid_json':
    case 'invalid_email':
      return 'Please check the information you entered and try again.';
    case 'edge_function_not_deployed':
      return 'Password reset could not be started. Please try again in a moment.';
    case 'method_not_allowed':
      return 'Something went wrong. Please try again.';
  }
  return null;
}

String? _messageForFunctionException(FunctionException e) {
  dynamic details = e.details;
  if (details is String) {
    try {
      final o = jsonDecode(details);
      if (o is Map) details = Map<String, dynamic>.from(o);
    } catch (_) {}
  }
  if (details is Map) {
    final err = details['error'] ?? details['message'];
    if (err is String && err.isNotEmpty) {
      final mapped = _passwordResetEdgeErrorMessage(err);
      if (mapped != null) return mapped;
    }
  }
  return null;
}

String _postgresStyleMessage(Object error) {
  final lower = error.toString().toLowerCase();
  if (lower.contains('jwt') && lower.contains('expired')) {
    return 'Your session has expired. Please sign in again.';
  }
  if (lower.contains('42501') || lower.contains('permission denied') || lower.contains('rls')) {
    return 'You do not have permission to do that.';
  }
  if (lower.contains('23505') || lower.contains('unique')) {
    return 'This record already exists.';
  }
  if (lower.contains('23503') || lower.contains('foreign key')) {
    return 'Related data is missing or was removed.';
  }
  if (lower.contains('p0001') || lower.contains('check_violation')) {
    return 'The data could not be saved. Please review the form and try again.';
  }
  return 'The server could not complete that request. Please try again.';
}

String _authExceptionMessage(AuthException e) {
  // gotrue wraps network/CORS/DNS failures and 5xx responses in AuthRetryableFetchException.
  // Its message embeds the request URI, so _looksTechnical would mask the real cause below.
  if (e is AuthRetryableFetchException) {
    if (e.statusCode == null) {
      return 'Unable to connect. Check your internet connection and try again.';
    }
    return 'The service is temporarily unavailable. Please try again in a moment.';
  }
  // Unexpected/undecodable response body — message is technical but has no keyword match.
  if (e is AuthUnknownException) {
    return 'Sign-in could not be completed. Please try again.';
  }
  final m = e.message.trim();
  final lower = m.toLowerCase();
  if (lower.contains('invalid login') || lower.contains('invalid credentials')) {
    return 'Incorrect email or password.';
  }
  if (lower.contains('email not confirmed') || lower.contains('not confirmed')) {
    return 'Please confirm your email before signing in.';
  }
  if (lower.contains('user already registered') || lower.contains('already been registered')) {
    return 'An account with this email already exists.';
  }
  if (lower.contains('password') && lower.contains('weak')) {
    return 'Password is too weak. Use a stronger password.';
  }
  if (lower.contains('rate limit') || lower.contains('too many')) {
    return 'Too many attempts. Please wait and try again.';
  }
  if (lower.contains('otp') && (lower.contains('expired') || lower.contains('invalid'))) {
    return 'That verification code is invalid or has expired. Request a new code.';
  }
  if (lower.contains('token') && (lower.contains('expired') || lower.contains('invalid'))) {
    return 'That verification code is invalid or has expired. Request a new code.';
  }
  if (lower.contains('recovery') && lower.contains('expired')) {
    return 'Password reset has expired. Start again from Forgot password.';
  }
  if (lower.contains('session') && (lower.contains('missing') || lower.contains('expired'))) {
    return 'Your session has expired. Please sign in again.';
  }
  if (_looksTechnical(m)) {
    return 'Sign-in could not be completed. Please try again.';
  }
  return m;
}

bool _looksTechnical(String m) {
  final lower = m.toLowerCase();
  return lower.contains('http') ||
      lower.contains('://') ||
      lower.contains('localhost') ||
      lower.contains('supabase') ||
      lower.contains('postgres') ||
      lower.contains('exception') ||
      lower.contains('stack') ||
      m.length > 160;
}
