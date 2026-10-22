import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

class PushTokenService {
  static StreamSubscription<String>? _refreshSubscription;

  /// Register FCM token on server
  static Future<void> registerToken(String userId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) {
        return;
      }

      final response = await http.post(
        Uri.parse("${AppConstants.apiBaseUrl}/saveToken"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "userId": userId,
          "token": token,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint("[PushTokenService] ✅ Token registered successfully for user: $userId");
      } else {
        debugPrint("[PushTokenService] ⚠️ Server error registering token: ${response.body}");
      }
    } catch (e) {
      debugPrint("[PushTokenService] ❌ Error registering token: $e");
    }
  }

  /// Listen for FCM token refresh
  static void listenTokenRefresh(String userId) {
    _refreshSubscription?.cancel();
    _refreshSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      registerToken(userId);
    });
  }

  /// Unregister FCM token on server and delete FCM token locally on device
  static Future<void> unregisterToken(String userId) async {
    try {
      _refreshSubscription?.cancel();
      _refreshSubscription = null;

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        final response = await http.post(
          Uri.parse("${AppConstants.apiBaseUrl}/removeToken"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            if (userId.isNotEmpty) "userId": userId,
            "token": token,
          }),
        );
        debugPrint("[PushTokenService] Remove token response: ${response.statusCode}");
      } else if (userId.isNotEmpty) {
        await http.post(
          Uri.parse("${AppConstants.apiBaseUrl}/removeToken"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "userId": userId,
          }),
        );
      }

      // Invalidate the FCM token on device so no more messages are received
      // and a new token will be generated upon subsequent login.
      await FirebaseMessaging.instance.deleteToken();
      debugPrint("[PushTokenService] ✅ Token unregistered and deleted locally");
    } catch (e) {
      debugPrint("[PushTokenService] ❌ Error unregistering token: $e");
    }
  }
}
