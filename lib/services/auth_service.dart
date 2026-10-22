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
        final Map<String, dynamic> userData =
            Map<String, dynamic>.from(decoded['user']);

        // Normalize customer designation object so the website detects customer role
        if (isCustomer(userData)) {
          userData['designation'] = {'id': 106, 'name': 'Customer'};
          userData['designationName'] = 'Customer';
        }

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

  /// Check if user map represents a customer
  static bool isCustomer(Map<String, dynamic>? user) {
    if (user == null) return false;
    if (user['customerId'] != null && user['customerId'].toString().isNotEmpty) {
      return true;
    }
    if (user['designationId'] == 106 || user['designationId'] == '106') {
      return true;
    }
    final des = user['designation'];
    if (des is Map && des['name']?.toString().toLowerCase() == 'customer') {
      return true;
    }
    if (des is String && des.toLowerCase() == 'customer') {
      return true;
    }
    final desName = user['designationName']?.toString().toLowerCase();
    if (desName == 'customer') {
      return true;
    }
    return false;
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
        final user = Map<String, dynamic>.from(decoded['user']);
        if (isCustomer(user)) {
          user['designation'] = {'id': 106, 'name': 'Customer'};
          user['designationName'] = 'Customer';
        }
        return user;
      }
    } catch (e) {
      debugPrint("Error parsing stored auth data: $e");
    }
    return null;
  }

  /// Get the exact auth JSON string to inject into WebView localStorage
  static Future<String?> getAuthJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_authKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['user'] != null) {
        final user = Map<String, dynamic>.from(decoded['user']);
        if (isCustomer(user)) {
          user['designation'] = {'id': 106, 'name': 'Customer'};
          user['designationName'] = 'Customer';
          return jsonEncode({'user': user});
        }
      }
    } catch (e) {
      debugPrint("Error normalizing auth JSON: $e");
    }
    return raw;
  }

  /// Save or update raw auth JSON string
  static Future<void> saveAuthJson(String rawJson) async {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic> && decoded['user'] != null) {
        final user = Map<String, dynamic>.from(decoded['user']);
        if (isCustomer(user)) {
          user['designation'] = {'id': 106, 'name': 'Customer'};
          user['designationName'] = 'Customer';
          rawJson = jsonEncode({'user': user});
        }
      }
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authKey, rawJson);
  }

  static const String _lastWebsiteKey = 'last_opened_website_url';

  /// Get the last opened website URL
  static Future<String?> getLastOpenedWebsite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastWebsiteKey);
  }

  /// Save the last opened website URL
  static Future<void> setLastOpenedWebsite(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastWebsiteKey, url);
  }

  /// Clear the last opened website URL
  static Future<void> clearLastOpenedWebsite() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastWebsiteKey);
  }

  /// Log out and clear stored session
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final authData = prefs.getString(_authKey);
    String userId = '';
    if (authData != null && authData.isNotEmpty) {
      try {
        final decoded = jsonDecode(authData);
        if (decoded is Map<String, dynamic> && decoded['user'] != null) {
          userId = decoded['user']['id']?.toString() ?? '';
        }
      } catch (e) {
        debugPrint("Error extracting userId for logout: $e");
      }
    }

    try {
      await PushTokenService.unregisterToken(userId);
    } catch (e) {
      debugPrint("Push token unregistration error: $e");
    }

    await prefs.remove(_authKey);
    await prefs.remove(_lastWebsiteKey);
  }
}

