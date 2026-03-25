import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

class ApiService {
  static Future<bool> saveToken(String userId, String token) async {
    final url = Uri.parse("${AppConstants.apiBaseUrl}/saveToken");

    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "userId": userId,
        "token": token,
      }),
    );

    if (response.statusCode == 200) {
      return true;
    } else {
      print("Error saving token: ${response.body}");
      return false;
    }
  }
}
