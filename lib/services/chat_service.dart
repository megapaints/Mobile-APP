import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'auth_service.dart';

class ChatService {
  static const String _chatsCacheKey = 'cached_chats_list';
  static const String _messagesCachePrefix = 'cached_msgs_';

  /// 1. Get Paginated Chats for Current User
  static Future<Map<String, dynamic>> getChats({
    String? type,
    int limit = 15,
    String? cursor,
    bool forceRefresh = false,
  }) async {
    final currentUser = await AuthService.getCurrentUser();
    if (currentUser == null) {
      return {'success': false, 'error': 'User not authenticated', 'chats': []};
    }

    final userId = (currentUser['id'] ?? '').toString();

    // Check cache for initial page if not force refreshing
    if (cursor == null && !forceRefresh) {
      final cached = await getCachedChats();
      if (cached.isNotEmpty) {
        // Return cache first for instant render, then fetch in background if needed
      }
    }

    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/getChats");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "userId": userId,
          if (type != null) "type": type,
          "limit": limit,
          if (cursor != null) "cursor": cursor,
        }),
      );

      final dynamic decoded = jsonDecode(response.body);
      if (response.statusCode == 200 && decoded is Map<String, dynamic> && decoded['success'] == true) {
        final List<dynamic> rawChats = decoded['chats'] ?? [];
        final chats = List<Map<String, dynamic>>.from(rawChats);

        // Cache the first page
        if (cursor == null) {
          await _cacheChats(chats);
        }

        return {
          'success': true,
          'chats': chats,
          'nextCursor': decoded['nextCursor'],
          'hasMore': decoded['hasMore'] ?? false,
        };
      } else {
        return {
          'success': false,
          'error': decoded is Map ? decoded['error'] ?? 'Failed to load chats' : 'Failed to load chats',
          'chats': cursor == null ? await getCachedChats() : [],
          'hasMore': false,
        };
      }
    } catch (e) {
      debugPrint("[ChatService] getChats error: $e");
      final cached = cursor == null ? await getCachedChats() : <Map<String, dynamic>>[];
      return {
        'success': false,
        'error': 'Network error',
        'chats': cached,
        'hasMore': false,
      };
    }
  }

  /// 2. Get Paginated Messages for a Specific Chat
  static Future<Map<String, dynamic>> getChatMessages(
    String chatId, {
    int limit = 20,
    String? before,
  }) async {
    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/getChatMessages");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "chatId": chatId,
          "limit": limit,
          if (before != null) "before": before,
        }),
      );

      final dynamic decoded = jsonDecode(response.body);
      if (response.statusCode == 200 && decoded is Map<String, dynamic> && decoded['success'] == true) {
        final List<dynamic> rawMsgs = decoded['messages'] ?? [];
        final messages = List<Map<String, dynamic>>.from(rawMsgs);

        // Cache latest messages
        if (before == null) {
          await _cacheMessages(chatId, messages);
        }

        return {
          'success': true,
          'messages': messages,
          'oldestCursor': decoded['oldestCursor'],
          'hasMoreOlder': decoded['hasMoreOlder'] ?? false,
        };
      } else {
        return {
          'success': false,
          'error': decoded is Map ? decoded['error'] ?? 'Failed to load messages' : 'Failed to load messages',
          'messages': before == null ? await getCachedMessages(chatId) : [],
          'hasMoreOlder': false,
        };
      }
    } catch (e) {
      debugPrint("[ChatService] getChatMessages error: $e");
      final cached = before == null ? await getCachedMessages(chatId) : <Map<String, dynamic>>[];
      return {
        'success': false,
        'error': 'Network error',
        'messages': cached,
        'hasMoreOlder': false,
      };
    }
  }

  /// 3. Send a Message
  static Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    required String text,
    String type = 'text',
    String? attachmentUrl,
  }) async {
    final currentUser = await AuthService.getCurrentUser();
    if (currentUser == null) {
      return {'success': false, 'error': 'User not authenticated'};
    }

    final senderId = (currentUser['id'] ?? '').toString();
    final senderName = (currentUser['name'] ?? currentUser['username'] ?? 'User').toString();

    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/sendMessage");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "chatId": chatId,
          "senderId": senderId,
          "senderName": senderName,
          "text": text.trim(),
          "type": type,
          if (attachmentUrl != null) "attachmentUrl": attachmentUrl,
        }),
      );

      final dynamic decoded = jsonDecode(response.body);
      if (response.statusCode == 200 && decoded is Map<String, dynamic> && decoded['success'] == true) {
        return {
          'success': true,
          'message': decoded['message'],
        };
      } else {
        return {
          'success': false,
          'error': decoded is Map ? decoded['error'] ?? 'Failed to send message' : 'Failed to send message',
        };
      }
    } catch (e) {
      debugPrint("[ChatService] sendMessage error: $e");
      return {'success': false, 'error': 'Network error'};
    }
  }

  /// 4. Create or Get Chat (Direct or Order-Based)
  static Future<Map<String, dynamic>> createOrGetChat({
    required String type, // "direct" | "order"
    String? orderId,
    String? orderNumber,
    String? title,
    required List<String> participants,
    Map<String, dynamic>? participantDetails,
  }) async {
    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/createOrGetChat");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "type": type,
          if (orderId != null) "orderId": orderId,
          if (orderNumber != null) "orderNumber": orderNumber,
          if (title != null) "title": title,
          "participants": participants,
          if (participantDetails != null) "participantDetails": participantDetails,
        }),
      );

      final dynamic decoded = jsonDecode(response.body);
      if (response.statusCode == 200 && decoded is Map<String, dynamic> && decoded['success'] == true) {
        return {
          'success': true,
          'chat': decoded['chat'],
        };
      } else {
        return {
          'success': false,
          'error': decoded is Map ? decoded['error'] ?? 'Failed to open chat' : 'Failed to open chat',
        };
      }
    } catch (e) {
      debugPrint("[ChatService] createOrGetChat error: $e");
      return {'success': false, 'error': 'Network error'};
    }
  }

  /// 5. Mark Chat as Read
  static Future<void> markChatRead(String chatId) async {
    final currentUser = await AuthService.getCurrentUser();
    if (currentUser == null) return;
    final userId = (currentUser['id'] ?? '').toString();

    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/markChatRead");
      await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "chatId": chatId,
          "userId": userId,
        }),
      );
    } catch (e) {
      debugPrint("[ChatService] markChatRead error: $e");
    }
  }

  /// 6. Get Users for Directory (to start DMs)
  static Future<List<Map<String, dynamic>>> getChatUsers() async {
    try {
      final url = Uri.parse("${AppConstants.apiBaseUrl}/getChatUsers");
      final response = await http.get(url);
      final dynamic decoded = jsonDecode(response.body);
      if (response.statusCode == 200 && decoded is Map<String, dynamic> && decoded['success'] == true) {
        final List<dynamic> users = decoded['users'] ?? [];
        return List<Map<String, dynamic>>.from(users);
      }
    } catch (e) {
      debugPrint("[ChatService] getChatUsers error: $e");
    }
    return [];
  }

  // --- Local Cache Helpers ---

  static Future<List<Map<String, dynamic>>> getCachedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_chatsCacheKey);
      if (str != null && str.isNotEmpty) {
        final decoded = jsonDecode(str);
        if (decoded is List) {
          return List<Map<String, dynamic>>.from(decoded);
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<void> _cacheChats(List<Map<String, dynamic>> chats) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_chatsCacheKey, jsonEncode(chats));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getCachedMessages(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('$_messagesCachePrefix$chatId');
      if (str != null && str.isNotEmpty) {
        final decoded = jsonDecode(str);
        if (decoded is List) {
          return List<Map<String, dynamic>>.from(decoded);
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<void> _cacheMessages(String chatId, List<Map<String, dynamic>> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_messagesCachePrefix$chatId', jsonEncode(messages));
    } catch (_) {}
  }
}
