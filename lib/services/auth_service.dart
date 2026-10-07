import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'push_token_service.dart';

class AuthService {
  static const String _authKey = 'auth';

  /// Authenticate against the unified backend
  static Future<Map<String, dynamic>> login(
      String username, String password) async {
    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/login");

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username.trim(),
          "password": password,
        }),
      );

      final dynamic decoded = jsonDecode(response.body);

      if (response.statusCode == 200 &&
          decoded is Map<String, dynamic> &&
          decoded['success'] == true &&
          decoded['user'] != null) {
        final userData = decoded['user'];
        final authPayload = jsonEncode({'user': userData});

        // Save auth data to SharedPreferences matching the web localStorage format
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_authKey, authPayload);

        // Register FCM Push token for this user
        final userId = userData['id']?.toString() ?? '';
        if (userId.isNotEmpty) {
          try {
            await PushTokenService.registerToken(userId);
            PushTokenService.listenTokenRefresh(userId);
          } catch (e) {
            debugPrint("Push token registration error: $e");
          }
        }

        return {
          'success': true,
          'user': userData,
        };
      } else {
        final errorMsg = decoded is Map<String, dynamic> && decoded['error'] != null
            ? decoded['error'].toString()
            : 'Invalid username or password';
        return {
          'success': false,
          'error': errorMsg,
        };
      }
    } catch (e) {
      debugPrint("Login exception: $e");
      return {
        'success': false,
        'error': 'Network error. Please check your connection and try again.',
      };
    }
  }

  /// Check if a user is currently logged in
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final authData = prefs.getString(_authKey);
    return authData != null && authData.isNotEmpty;
  }

  /// Get the current logged in user details
  static Future<Map<String, dynamic>?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final authData = prefs.getString(_authKey);
    if (authData == null || authData.isEmpty) return null;

    try {
      final decoded = jsonDecode(authData);
      if (decoded is Map<String, dynamic> && decoded['user'] != null) {
        return Map<String, dynamic>.from(decoded['user']);
      }
    } catch (e) {
      debugPrint("Error parsing stored auth data: $e");
    }
    return null;
  }

  /// Get the exact auth JSON string to inject into WebView localStorage
  static Future<String?> getAuthJson() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_authKey);
  }

  /// Save or update raw auth JSON string
  static Future<void> saveAuthJson(String rawJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authKey, rawJson);
  }

  /// Log out and clear stored session
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_authKey);
  }
}
