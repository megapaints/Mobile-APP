import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;

class PushTokenService {
  /// Register FCM token on server
  static Future<void> registerToken(String userId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
       // Fluttertoast.showToast(msg: "❌ No FCM token found");
        return;
      }

      //Fluttertoast.showToast(msg: "📡 Sending token to server...");

      final response = await http.post(
        Uri.parse("https://us-central1-mega-paints.cloudfunctions.net/api/saveToken"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "userId": userId,
          "token": token,
        }),
      );

      if (response.statusCode == 200) {
       // Fluttertoast.showToast(msg: "✅ Token registered successfully");
      } else {
       // Fluttertoast.showToast(msg: "⚠️ Server error: ${response.body}");
      }
    } catch (e) {
      //Fluttertoast.showToast(msg: "❌ Error registering token: $e");
    }
  }

  /// Listen for FCM token refresh
  static void listenTokenRefresh(String userId) {
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
     // Fluttertoast.showToast(msg: "🔄 Token refreshed: $newToken");
      registerToken(userId);
    });
  }
}
