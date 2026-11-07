import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';

class ChatDetailScreen extends StatefulWidget {
  final String chatId;
  final String title;
  final String type; // "order" | "direct"
  final String? orderNumber;
  final String? subtitle;

  const ChatDetailScreen({
    super.key,
    required this.chatId,
    required this.title,
    required this.type,
    this.orderNumber,
    this.subtitle,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();

  bool _isLoadingInitial = true;
  bool _isLoadingOlder = false;
  bool _hasMoreOlder = false;
  String? _oldestCursor;
  String? _currentUserId;
  String? _currentUserName;
  Timer? _realtimeTimer;
  StreamSubscription? _pushSub;

  @override
  void initState() {
    super.initState();
    ChatService.activeChatId = widget.chatId;
    _loadCurrentUser();
    _loadInitialMessages();
    _scrollController.addListener(_onScroll);
    ChatService.markChatRead(widget.chatId);
    _startRealtimeSync();
  }

  void _startRealtimeSync() {
    _realtimeTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      _syncLatestMessages();
    });

    _pushSub = ChatService.onMessageReceived.listen((data) {
      if (data['chatId']?.toString() == widget.chatId) {
        _syncLatestMessages();
      }
    });
  }

  Future<void> _syncLatestMessages() async {
    if (_messages.isEmpty) return;
    final newestTime = _messages.first['createdAt']?.toString();
    if (newestTime == null || newestTime.isEmpty) return;

    final result =
        await ChatService.getNewerMessages(widget.chatId, after: newestTime);
    if (result['success'] == true && mounted) {
      final newMsgs = List<Map<String, dynamic>>.from(result['messages'] ?? []);
      if (newMsgs.isNotEmpty) {
        newMsgs.sort((a, b) => (b['createdAt'] ?? '')
            .toString()
            .compareTo((a['createdAt'] ?? '').toString()));
        setState(() {
          for (final msg in newMsgs.reversed) {
            final id = msg['id'];
            if (!_messages.any((m) => m['id'] == id)) {
              _messages.insert(0, msg);
            }
          }
        });
        ChatService.markChatRead(widget.chatId);
      }
    }
  }

  Future<void> _loadCurrentUser() async {
    final user = await AuthService.getCurrentUser();
    if (mounted && user != null) {
      setState(() {
        _currentUserId = (user['id'] ?? '').toString();
        _currentUserName =
            (user['name'] ?? user['username'] ?? 'User').toString();
      });
    }
  }

  Future<void> _loadInitialMessages() async {
    setState(() => _isLoadingInitial = true);
    final result = await ChatService.getChatMessages(widget.chatId, limit: 20);

    if (mounted) {
      final List<Map<String, dynamic>> msgs =
          List<Map<String, dynamic>>.from(result['messages'] ?? []);
      // Ensure messages are sorted descending (newest first at index 0 for reversed ListView)
      msgs.sort((a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()));

      setState(() {
        _messages.clear();
        _messages.addAll(msgs);
        _hasMoreOlder = result['hasMoreOlder'] ?? false;
        _oldestCursor = result['oldestCursor'];
        _isLoadingInitial = false;
      });
    }
  }

  void _onScroll() {
    // In a reversed ListView, maxScrollExtent represents the oldest messages at the top
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 80) {
      if (!_isLoadingOlder && _hasMoreOlder && _oldestCursor != null) {
        _loadOlderMessages();
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreOlder || _oldestCursor == null) return;
    setState(() => _isLoadingOlder = true);

    final result = await ChatService.getChatMessages(
      widget.chatId,
      limit: 20,
      before: _oldestCursor,
    );

    if (mounted) {
      final List<Map<String, dynamic>> older =
          List<Map<String, dynamic>>.from(result['messages'] ?? []);
      older.sort((a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()));

      setState(() {
        _messages.addAll(older);
        _hasMoreOlder = result['hasMoreOlder'] ?? false;
        _oldestCursor = result['oldestCursor'];
        _isLoadingOlder = false;
      });
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();

    // Optimistic message insertion
    final now = DateTime.now().toIso8601String();
    final tempId = "temp_${DateTime.now().millisecondsSinceEpoch}";
    final optimisticMsg = {
      'id': tempId,
      'chatId': widget.chatId,
      'senderId': _currentUserId ?? '',
      'senderName': _currentUserName ?? 'You',
      'text': text,
      'type': 'text',
      'createdAt': now,
      'isSending': true,
    };

    setState(() {
      _messages.insert(0, optimisticMsg);
    });

    final result = await ChatService.sendMessage(
      chatId: widget.chatId,
      text: text,
    );

    if (mounted) {
      if (result['success'] == true) {
        final serverMsg = result['message'];
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == tempId);
          if (idx != -1 && serverMsg != null) {
            _messages[idx] = Map<String, dynamic>.from(serverMsg);
          }
        });
      } else {
        // Show error indicator
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? 'Message failed to send'),
            backgroundColor: const Color(0xFFEF4444),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final period = dt.hour >= 12 ? 'PM' : 'AM';
      final min = dt.minute.toString().padLeft(2, '0');
      return '$hour:$min $period';
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _realtimeTimer?.cancel();
    _pushSub?.cancel();
    if (ChatService.activeChatId == widget.chatId) {
      ChatService.activeChatId = null;
    }
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOrder = widget.type == 'order';

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            _buildHeader(isOrder),

            // Message Timeline
            Expanded(
              child: _isLoadingInitial
                  ? const Center(
                      child: CircularProgressIndicator(
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                      ),
                    )
                  : _messages.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          controller: _scrollController,
                          reverse: true, // Pinned to bottom, 0 is newest
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          itemCount:
                              _messages.length + (_isLoadingOlder ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _messages.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Color(0xFF94A3B8)),
                                    ),
                                  ),
                                ),
                              );
                            }
                            final msg = _messages[index];
                            return _buildMessageItem(msg);
                          },
                        ),
            ),

            // Bottom Input Bar
            _buildBottomInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isOrder) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color:
                  isOrder ? const Color(0xFF0F172A) : const Color(0xFF2563EB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isOrder ? const Color(0xFF334155) : const Color(0xFF1D4ED8),
              ),
            ),
            child: Icon(
              isOrder
                  ? Icons.local_shipping_outlined
                  : Icons.person_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle!,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                color: Color(0xFF94A3B8), size: 20),
            tooltip: 'Refresh',
            onPressed: _loadInitialMessages,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 36,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No messages yet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Send a message to start the conversation',
            style: TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> msg) {
    final senderId = (msg['senderId'] ?? '').toString();
    final isMe = _currentUserId != null && senderId == _currentUserId;
    final isSystem = (msg['type'] ?? '') == 'system';
    final text = msg['text'] ?? '';
    final timeStr = _formatTimestamp(msg['createdAt']);
    final isSending = msg['isSending'] == true;

    if (isSystem) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
          ),
        ),
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF2563EB) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          border: Border.all(
            color: isMe ? const Color(0xFF1D4ED8) : const Color(0xFF334155),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isMe && (msg['senderName'] ?? '').isNotEmpty) ...[
              Text(
                msg['senderName'] ?? 'Colleague',
                style: const TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
            ],
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withOpacity(0.7)
                        : const Color(0xFF94A3B8),
                    fontSize: 10,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    isSending
                        ? Icons.access_time_rounded
                        : Icons.done_all_rounded,
                    size: 13,
                    color: isSending ? Colors.white70 : const Color(0xFF67E8F9),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(
          top: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: TextField(
                controller: _textController,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
                onSubmitted: (_) => _handleSendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: const Color(0xFF2563EB),
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              onTap: _handleSendMessage,
              borderRadius: BorderRadius.circular(22),
              child: const SizedBox(
                width: 42,
                height: 42,
                child: Icon(
                  Icons.send_rounded,
                  color: Colors.white,
                  size: 19,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
