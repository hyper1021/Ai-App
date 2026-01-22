import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// -----------------------------------------------------------------------------
// 1. MODELS
// -----------------------------------------------------------------------------

enum MessageRole { user, ai }
enum MessageStatus { none, generating, done, error, stopped }

class ChatMessage {
  final String id;
  final String chatId;
  final MessageRole role;
  final String text;
  String? imageUrl;
  String? localImagePath;
  MessageStatus status;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.text,
    this.imageUrl,
    this.localImagePath,
    this.status = MessageStatus.none,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'chatId': chatId,
        'role': role.toString(),
        'text': text,
        'imageUrl': imageUrl,
        'localImagePath': localImagePath,
        'status': status.toString(),
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      chatId: json['chatId'],
      role: json['role'] == 'MessageRole.user' ? MessageRole.user : MessageRole.ai,
      text: json['text'],
      imageUrl: json['imageUrl'],
      localImagePath: json['localImagePath'],
      status: _parseStatus(json['status']),
      timestamp: DateTime.parse(json['timestamp']),
    );
  }

  static MessageStatus _parseStatus(String? statusStr) {
    return MessageStatus.values.firstWhere(
      (e) => e.toString() == statusStr,
      orElse: () => MessageStatus.none,
    );
  }
}

class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'],
      title: json['title'],
      createdAt: DateTime.parse(json['createdAt']),
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
    );
  }
}

// -----------------------------------------------------------------------------
// 2. SERVICES (API & STORAGE)
// -----------------------------------------------------------------------------

class StorageService {
  static const String _storageKey = 'skygen_chats_v1';

  Future<void> saveChats(List<ChatSession> chats) async {
    final prefs = await SharedPreferences.getInstance();
    final String data = jsonEncode(chats.map((c) => c.toJson()).toList());
    await prefs.setString(_storageKey, data);
  }

  Future<List<ChatSession>> loadChats() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString(_storageKey);
    if (data == null) return [];
    try {
      final List<dynamic> decoded = jsonDecode(data);
      return decoded.map((e) => ChatSession.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }
}

class ImageApiService {
  static const String _genUrl = "https://gen-z-image.vercel.app/gen";
  static const String _checkUrl = "https://gen-z-image.vercel.app/check";

  Future<String> initiateGeneration(String prompt) async {
    try {
      final res = await http.post(
        Uri.parse(_genUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data["results"]["id"];
      }
      throw Exception("Failed to start generation");
    } catch (e) {
      throw Exception("Network error: $e");
    }
  }

  Future<String?> checkStatus(String id) async {
    try {
      final res = await http.get(Uri.parse("$_checkUrl?id=$id"));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List urls = data["results"]["urls"];
        if (urls.isNotEmpty) {
          return urls[0] as String;
        }
      }
    } catch (_) {}
    return null;
  }
}

// -----------------------------------------------------------------------------
// 3. STATE MANAGEMENT (PROVIDER)
// -----------------------------------------------------------------------------

class ChatProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();
  final ImageApiService _api = ImageApiService();
  final Uuid _uuid = const Uuid();

  List<ChatSession> _chats = [];
  String? _currentChatId;
  bool _isGenerating = false;
  bool _stopSignal = false;

  List<ChatSession> get chats => _chats;
  String? get currentChatId => _currentChatId;
  bool get isGenerating => _isGenerating;

  ChatSession? get currentChat {
    try {
      return _chats.firstWhere((c) => c.id == _currentChatId);
    } catch (_) {
      return null;
    }
  }

  ChatProvider() {
    _loadChats();
  }

  Future<void> _loadChats() async {
    _chats = await _storage.loadChats();
    // Sort by date desc
    _chats.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  void startNewChat() {
    _currentChatId = null; // UI will handle creating the actual object on first message
    notifyListeners();
  }

  void openChat(String chatId) {
    _currentChatId = chatId;
    notifyListeners();
  }

  void deleteChat(String chatId) {
    _chats.removeWhere((c) => c.id == chatId);
    if (_currentChatId == chatId) _currentChatId = null;
    _storage.saveChats(_chats);
    notifyListeners();
  }

  Future<void> sendMessage(String prompt) async {
    if (prompt.trim().isEmpty) return;

    // 1. Ensure Chat Session Exists
    ChatSession? chat = currentChat;
    if (chat == null) {
      final newId = _uuid.v4();
      chat = ChatSession(
        id: newId,
        title: prompt.length > 20 ? "${prompt.substring(0, 20)}..." : prompt,
        createdAt: DateTime.now(),
        messages: [],
      );
      _chats.insert(0, chat);
      _currentChatId = newId;
    }

    // 2. Add User Message
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      chatId: chat.id,
      role: MessageRole.user,
      text: prompt,
      timestamp: DateTime.now(),
    );
    chat.messages.add(userMsg);
    notifyListeners();

    // 3. Add AI Placeholder Message
    final aiMsgId = _uuid.v4();
    final aiMsg = ChatMessage(
      id: aiMsgId,
      chatId: chat.id,
      role: MessageRole.ai,
      text: "Generating image...",
      status: MessageStatus.generating,
      timestamp: DateTime.now(),
    );
    chat.messages.add(aiMsg);
    notifyListeners();

    _isGenerating = true;
    _stopSignal = false;

    try {
      // 4. Call API Step 1
      final genId = await _api.initiateGeneration(prompt);
      
      // 5. Poll API Step 2
      String? imageUrl;
      int attempts = 0;
      
      while (imageUrl == null && attempts < 30 && !_stopSignal) {
        await Future.delayed(const Duration(seconds: 2));
        if (_stopSignal) break;
        imageUrl = await _api.checkStatus(genId);
        attempts++;
      }

      if (_stopSignal) {
        aiMsg.status = MessageStatus.stopped;
        aiMsg.text = "Generation cancelled.";
      } else if (imageUrl != null) {
        aiMsg.imageUrl = imageUrl;
        aiMsg.status = MessageStatus.done;
        aiMsg.text = "Here is your image:";
      } else {
        aiMsg.status = MessageStatus.error;
        aiMsg.text = "Failed to generate image. Time out.";
      }

    } catch (e) {
      aiMsg.status = MessageStatus.error;
      aiMsg.text = "Error: ${e.toString()}";
    }

    _isGenerating = false;
    _storage.saveChats(_chats); // Persist
    notifyListeners();
  }

  void stopGeneration() {
    if (_isGenerating) {
      _stopSignal = true;
      notifyListeners();
    }
  }

  Future<void> downloadImage(String url, String messageId) async {
    try {
      final dir = await getExternalStorageDirectory();
      // Use Documents directory for cleaner internal storage or external for user visibility
      // The prompt requested external.
      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final savePath = "${dir!.path}/$fileName";
      final file = File(savePath);

      final res = await http.get(Uri.parse(url));
      await file.writeAsBytes(res.bodyBytes);

      // Update message with local path
      final chat = currentChat;
      if (chat != null) {
        final msg = chat.messages.firstWhere((m) => m.id == messageId);
        msg.localImagePath = savePath;
        _storage.saveChats(_chats);
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Download failed: $e");
      rethrow;
    }
  }
}

// -----------------------------------------------------------------------------
// 4. MAIN & UI COMPONENTS
// -----------------------------------------------------------------------------

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: const SkyGenApp(),
    ),
  );
}

class SkyGenApp extends StatelessWidget {
  const SkyGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SkyGen AI',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xff121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xff10a37f), // ChatGPT Green
          secondary: Color(0xff1A1A1A),
          surface: Color(0xff202123),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff202123),
          elevation: 0,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<ChatProvider>(context);
    final currentChat = provider.currentChat;

    return Scaffold(
      appBar: AppBar(
        title: Text(currentChat?.title ?? "New Chat"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => provider.startNewChat(),
          ),
        ],
      ),
      drawer: const ChatHistoryDrawer(),
      body: Column(
        children: [
          Expanded(
            child: currentChat == null || currentChat.messages.isEmpty
                ? const EmptyState()
                : ListView.builder(
                    reverse: false, // We want user at bottom, but standard chat flows down. 
                    // To behave like ChatGPT mobile: List fills from top, auto-scrolls.
                    // Implementation: Standard List, Controller to jump to bottom.
                    controller: _scrollController(currentChat.messages.length),
                    padding: const EdgeInsets.only(bottom: 20, top: 10),
                    itemCount: currentChat.messages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(message: currentChat.messages[index]);
                    },
                  ),
          ),
          const InputArea(),
        ],
      ),
    );
  }

  ScrollController _scrollController(int itemCount) {
    final controller = ScrollController();
    // Simple hack to auto scroll to bottom on new message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
    return controller;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xff202123),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome, size: 40, color: Colors.white70),
          ),
          const SizedBox(height: 20),
          const Text(
            "SkyGen AI",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          const Text(
            "Describe an image to start generation",
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class ChatHistoryDrawer extends StatelessWidget {
  const ChatHistoryDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    
    return Drawer(
      backgroundColor: const Color(0xff202123),
      child: Column(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff343541),
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                  alignment: Alignment.centerLeft,
                ),
                onPressed: () {
                  provider.startNewChat();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text("New chat", style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
          const Divider(color: Colors.white24),
          Expanded(
            child: ListView.builder(
              itemCount: provider.chats.length,
              itemBuilder: (context, index) {
                final chat = provider.chats[index];
                return ListTile(
                  title: Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  leading: const Icon(Icons.chat_bubble_outline, color: Colors.white54, size: 20),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white24, size: 20),
                    onPressed: () => provider.deleteChat(chat.id),
                  ),
                  onTap: () {
                    provider.openChat(chat.id);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "SkyGen v1.0 • Local Storage",
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          )
        ],
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      color: isUser ? const Color(0xff121212) : const Color(0xff444654).withOpacity(0.4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: isUser ? const Color(0xff5436DA) : const Color(0xff10a37f),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              isUser ? Icons.person : Icons.token,
              size: 20,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      message.text,
                      style: const TextStyle(fontSize: 16, height: 1.5, color: Colors.white),
                    ),
                  ),
                if (message.status == MessageStatus.generating)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: TypingIndicator(),
                  ),
                if (message.status == MessageStatus.done && message.imageUrl != null)
                   Padding(
                     padding: const EdgeInsets.only(top: 16),
                     child: ImagePreviewCard(message: message),
                   ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ImagePreviewCard extends StatelessWidget {
  final ChatMessage message;

  const ImagePreviewCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final isDownloaded = message.localImagePath != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: Colors.black26,
            constraints: const BoxConstraints(maxHeight: 400),
            child: isDownloaded 
              ? Image.file(File(message.localImagePath!), fit: BoxFit.cover)
              : Image.network(
                  message.imageUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return Container(
                      height: 250,
                      width: double.infinity,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    );
                  },
                ),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            side: const BorderSide(color: Colors.white24),
            elevation: 0,
          ),
          onPressed: () async {
            if (message.imageUrl != null) {
               await provider.downloadImage(message.imageUrl!, message.id);
               if (context.mounted) {
                 ScaffoldMessenger.of(context).showSnackBar(
                   const SnackBar(content: Text("Image saved to storage")),
                 );
               }
            }
          },
          icon: Icon(isDownloaded ? Icons.check : Icons.download, size: 16),
          label: Text(isDownloaded ? "Saved" : "Download"),
        )
      ],
    );
  }
}

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (index) {
        return FadeTransition(
          opacity: DelayTween(begin: 0.0, end: 1.0, delay: index * 0.2).animate(_controller),
          child: const Padding(
            padding: EdgeInsets.only(right: 4),
            child: CircleAvatar(radius: 4, backgroundColor: Colors.white70),
          ),
        );
      }),
    );
  }
}

class DelayTween extends Tween<double> {
  final double delay;
  DelayTween({super.begin, super.end, required this.delay});

  @override
  double lerp(double t) {
    return super.lerp((t - delay).clamp(0.0, 1.0));
  }
}

class InputArea extends StatefulWidget {
  const InputArea({super.key});

  @override
  State<InputArea> createState() => _InputAreaState();
}

class _InputAreaState extends State<InputArea> {
  final TextEditingController _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final isGenerating = provider.isGenerating;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xff202123),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                style: const TextStyle(color: Colors.white),
                enabled: !isGenerating,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: "Describe what to create...",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                if (isGenerating) {
                  provider.stopGeneration();
                } else {
                  if (_controller.text.trim().isNotEmpty) {
                    provider.sendMessage(_controller.text);
                    _controller.clear();
                  }
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isGenerating ? Colors.redAccent : const Color(0xff10a37f),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isGenerating ? Icons.stop : Icons.arrow_upward,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
