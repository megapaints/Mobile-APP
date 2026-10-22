import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final List<Map<String, dynamic>> _chats = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _selectedTab = 'all'; // 'all', 'order', 'direct'
  bool _isLoadingInitial = true;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  String? _nextCursor;
  String? _currentUserId;
  String _searchQuery = '';
  StreamSubscription? _chatListPushSub;

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
    _loadChats(refresh: true);
    _scrollController.addListener(_onScroll);
    _chatListPushSub = ChatService.onMessageReceived.listen((_) {
      if (mounted) {
        _loadChats(refresh: true);
      }
    });
  }

  Future<void> _loadCurrentUser() async {
    final user = await AuthService.getCurrentUser();
    if (mounted && user != null) {
      setState(() {
        _currentUserId = (user['id'] ?? '').toString();
      });
    }
  }

  Future<void> _loadChats({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _isLoadingInitial = true;
        _nextCursor = null;
        _hasMore = false;
      });
    }

    final typeParam = _selectedTab == 'all' ? null : _selectedTab;
    final result = await ChatService.getChats(
      type: typeParam,
      limit: 15,
      cursor: refresh ? null : _nextCursor,
      forceRefresh: refresh,
    );

    if (mounted) {
      final List<Map<String, dynamic>> newChats =
          List<Map<String, dynamic>>.from(result['chats'] ?? []);

      setState(() {
        if (refresh) {
          _chats.clear();
          _chats.addAll(newChats);
        } else {
          _chats.addAll(newChats);
        }
        _hasMore = result['hasMore'] ?? false;
        _nextCursor = result['nextCursor'];
        _isLoadingInitial = false;
        _isLoadingMore = false;
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 100) {
      if (!_isLoadingMore && _hasMore && _nextCursor != null) {
        setState(() => _isLoadingMore = true);
        _loadChats(refresh: false);
      }
    }
  }

  void _onTabChanged(String tab) {
    if (_selectedTab == tab) return;
    setState(() {
      _selectedTab = tab;
    });
    _loadChats(refresh: true);
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final difference = now.difference(dt);

      if (difference.inDays == 0) {
        final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
        final period = dt.hour >= 12 ? 'PM' : 'AM';
        final min = dt.minute.toString().padLeft(2, '0');
        return '$hour:$min $period';
      } else if (difference.inDays == 1) {
        return 'Yesterday';
      } else if (difference.inDays < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days[dt.weekday - 1];
      } else {
        return '${dt.day}/${dt.month}/${dt.year.toString().substring(2)}';
      }
    } catch (_) {
      return '';
    }
  }

  Future<void> _openNewChatDialog() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _NewChatSheet(
        currentUserId: _currentUserId ?? '',
        onChatSelected: (chat) {
          Navigator.pop(ctx);
          _openChatDetail(chat);
        },
      ),
    );
  }

  void _openChatDetail(Map<String, dynamic> chat) {
    final chatId = (chat['id'] ?? '').toString();
    final title = (chat['title'] ?? 'Chat').toString();
    final type = (chat['type'] ?? 'direct').toString();
    final orderNumber = chat['orderNumber']?.toString();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          chatId: chatId,
          title: title,
          type: type,
          orderNumber: orderNumber,
        ),
      ),
    ).then((_) {
      // Refresh list on return to clear unread badges
      _loadChats(refresh: true);
    });
  }

  @override
  void dispose() {
    _chatListPushSub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredChats = _chats.where((chat) {
      if (_searchQuery.isEmpty) return true;
      final title = (chat['title'] ?? '').toString().toLowerCase();
      final orderNo = (chat['orderNumber'] ?? '').toString().toLowerCase();
      final lastMsg = (chat['lastMessage']?['text'] ?? '').toString().toLowerCase();
      final query = _searchQuery.toLowerCase();
      return title.contains(query) || orderNo.contains(query) || lastMsg.contains(query);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            _buildAppBar(),

            // Search Bar
            _buildSearchBar(),

            // Filter Tabs (All / Orders / Direct)
            _buildSegmentedTabs(),

            // Chat List View
            Expanded(
              child: RefreshIndicator(
                color: const Color(0xFF2563EB),
                backgroundColor: const Color(0xFF1E293B),
                onRefresh: () => _loadChats(refresh: true),
                child: _isLoadingInitial
                    ? const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                        ),
                      )
                    : filteredChats.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            itemCount: filteredChats.length + (_isLoadingMore ? 1 : 0),
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              if (index == filteredChats.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(Color(0xFF94A3B8)),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final chat = filteredChats[index];
                              return _buildChatCard(chat);
                            },
                          ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: _openNewChatDialog,
        child: const Icon(Icons.edit_outlined, size: 22),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              'Messages & Team Chat',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF94A3B8), size: 21),
            tooltip: 'Refresh',
            onPressed: () => _loadChats(refresh: true),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: Color(0xFF94A3B8), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Search chats, orders, colleagues...',
                  hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 11),
                ),
                onChanged: (val) {
                  setState(() => _searchQuery = val.trim());
                },
              ),
            ),
            if (_searchQuery.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
                child: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentedTabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _buildTabChip('all', 'All Chats'),
          const SizedBox(width: 8),
          _buildTabChip('order', '📦 Order Chats'),
          const SizedBox(width: 8),
          _buildTabChip('direct', '💬 Direct'),
        ],
      ),
    );
  }

  Widget _buildTabChip(String key, String label) {
    final isSelected = _selectedTab == key;
    return GestureDetector(
      onTap: () => _onTabChanged(key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF334155),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? Colors.white : const Color(0xFF94A3B8),
          ),
        ),
      ),
    );
  }

  Widget _buildChatCard(Map<String, dynamic> chat) {
    final isOrder = chat['type'] == 'order';
    final title = chat['title'] ?? (isOrder ? 'Order Chat' : 'Direct Message');
    final lastMsg = chat['lastMessage'];
    final lastText = lastMsg?['text'] ?? 'No messages yet';
    final lastTime = _formatTimestamp(lastMsg?['createdAt'] ?? chat['updatedAt']);

    final unreadCounts = chat['unreadCounts'] as Map<String, dynamic>?;
    final unread = _currentUserId != null ? (unreadCounts?[_currentUserId] ?? 0) as int : 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openChatDetail(chat),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: unread > 0 ? const Color(0xFF3B82F6).withOpacity(0.5) : const Color(0xFF334155),
            ),
          ),
          child: Row(
            children: [
              // Avatar / Icon
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: isOrder ? const Color(0xFF0F172A) : const Color(0xFF2563EB),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isOrder ? const Color(0xFF334155) : const Color(0xFF1D4ED8),
                  ),
                ),
                child: Icon(
                  isOrder ? Icons.local_shipping_outlined : Icons.person_outline_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),

              // Chat Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (lastTime.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            lastTime,
                            style: TextStyle(
                              color: unread > 0 ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
                              fontSize: 11,
                              fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            lastText,
                            style: TextStyle(
                              color: unread > 0 ? const Color(0xFFE2E8F0) : const Color(0xFF94A3B8),
                              fontSize: 13,
                              fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2563EB),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              unread > 99 ? '99+' : unread.toString(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: const Icon(
              Icons.forum_outlined,
              size: 40,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No conversations yet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Order rooms and personal chats will appear here',
            style: TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal Sheet to start a new chat with a colleague or order
class _NewChatSheet extends StatefulWidget {
  final String currentUserId;
  final ValueChanged<Map<String, dynamic>> onChatSelected;

  const _NewChatSheet({
    required this.currentUserId,
    required this.onChatSelected,
  });

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  final TextEditingController _orderNumberController = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  bool _isLoadingUsers = true;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers() async {
    final users = await ChatService.getChatUsers();
    if (mounted) {
      setState(() {
        _users = users.where((u) => u['id']?.toString() != widget.currentUserId).toList();
        _isLoadingUsers = false;
      });
    }
  }

  Future<void> _startDirectChat(Map<String, dynamic> colleague) async {
    setState(() => _isCreating = true);
    final colleagueId = (colleague['id'] ?? '').toString();
    final colleagueName = (colleague['name'] ?? colleague['username'] ?? 'Colleague').toString();
    final colleagueRole = (colleague['role'] ?? 'Staff').toString();

    final result = await ChatService.createOrGetChat(
      type: 'direct',
      title: colleagueName,
      participants: [widget.currentUserId, colleagueId],
      participantDetails: {
        colleagueId: {'name': colleagueName, 'role': colleagueRole},
      },
    );

    if (mounted) {
      setState(() => _isCreating = false);
      if (result['success'] == true && result['chat'] != null) {
        widget.onChatSelected(Map<String, dynamic>.from(result['chat']));
      }
    }
  }

  Future<void> _startOrderChat() async {
    final orderNo = _orderNumberController.text.trim();
    if (orderNo.isEmpty) return;

    setState(() => _isCreating = true);
    final result = await ChatService.createOrGetChat(
      type: 'order',
      orderId: orderNo,
      orderNumber: orderNo,
      title: 'Order #$orderNo',
      participants: [widget.currentUserId],
    );

    if (mounted) {
      setState(() => _isCreating = false);
      if (result['success'] == true && result['chat'] != null) {
        widget.onChatSelected(Map<String, dynamic>.from(result['chat']));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sheet Header
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Start Conversation',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Order Chat Section
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Order Chat',
                    style: TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _orderNumberController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'Enter Order # (e.g. 1042)',
                            hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isCreating ? null : _startOrderChat,
                        child: const Text('Open Room', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Direct Colleague Directory
            const Text(
              'TEAM MEMBERS',
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: _isLoadingUsers
                  ? const Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                      ),
                    )
                  : _users.isEmpty
                      ? const Center(
                          child: Text(
                            'No team members found',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _users.length,
                          separatorBuilder: (_, __) => const Divider(color: Color(0xFF334155), height: 1),
                          itemBuilder: (context, index) {
                            final user = _users[index];
                            final name = (user['name'] ?? user['username'] ?? 'Staff').toString();
                            final role = (user['role'] ?? 'Colleague').toString();
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(vertical: 4),
                              leading: CircleAvatar(
                                radius: 18,
                                backgroundColor: const Color(0xFF2563EB),
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                              ),
                              subtitle: Text(
                                role,
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              ),
                              trailing: const Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF38BDF8), size: 18),
                              onTap: _isCreating ? null : () => _startDirectChat(user),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
