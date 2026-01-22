import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const SkyGenApp());
}

// -----------------------------------------------------------------------------
// MODELS
// -----------------------------------------------------------------------------

class ChatMessage {
  final String id;
  final String role; // 'user' or 'ai'
  final String text;
  String imageUrl;
  String localPath;
  String status; // 'typing', 'generating', 'done', 'error'
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.imageUrl = "",
    this.localPath = "",
    this.status = "done",
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        "id": id,
        "role": role,
        "text": text,
        "imageUrl": imageUrl,
        "localPath": localPath,
        "status": status,
        "timestamp": timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json["id"],
        role: json["role"],
        text: json["text"],
        imageUrl: json["imageUrl"] ?? "",
        localPath: json["localPath"] ?? "",
        status: json["status"] ?? "done",
        timestamp: DateTime.parse(json["timestamp"]),
      );
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
        "id": id,
        "title": title,
        "createdAt": createdAt.toIso8601String(),
        "messages": messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json["id"],
        title: json["title"],
        createdAt: DateTime.parse(json["createdAt"]),
        messages: (json["messages"] as List)
            .map((m) => ChatMessage.fromJson(m))
            .toList(),
      );
}

// -----------------------------------------------------------------------------
// MAIN APP
// -----------------------------------------------------------------------------

class SkyGenApp extends StatelessWidget {
  const SkyGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SkyGen',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xff0F0F0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xff6C63FF),
          secondary: Color(0xff03DAC6),
          surface: Color(0xff1E1E1E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff0F0F0F),
          elevation: 0,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// CHAT SCREEN
// -----------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  // --- STORAGE & HISTORY MANAGEMENT ---

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> sessionIds = prefs.getStringList('chat_sessions') ?? [];
    List<ChatSession> loadedSessions = [];

    for (String id in sessionIds) {
      final String? data = prefs.getString('session_$id');
      if (data != null) {
        loadedSessions.add(ChatSession.fromJson(jsonDecode(data)));
      }
    }

    // Sort by date new to old
    loadedSessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    setState(() {
      _sessions = loadedSessions;
      if (_sessions.isNotEmpty) {
        _currentSessionId = _sessions.first.id;
      } else {
        _createNewSession();
      }
    });
    
    // Scroll to bottom after load
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _saveSession(ChatSession session) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Save specific session data
    await prefs.setString('session_${session.id}', jsonEncode(session.toJson()));

    // Update list of IDs if new
    List<String> sessionIds = prefs.getStringList('chat_sessions') ?? [];
    if (!sessionIds.contains(session.id)) {
      sessionIds.add(session.id);
      await prefs.setStringList('chat_sessions', sessionIds);
    }
  }

  void _createNewSession() {
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    final newSession = ChatSession(
      id: newId,
      title: "New Chat",
      createdAt: DateTime.now(),
      messages: [],
    );

    setState(() {
      _sessions.insert(0, newSession);
      _currentSessionId = newId;
    });
    _saveSession(newSession);
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
    });
    Navigator.pop(context); // Close drawer
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  ChatSession get currentSession {
    return _sessions.firstWhere((s) => s.id == _currentSessionId);
  }

  // --- UI ACTIONS ---

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _promptController.text.trim();
    if (text.isEmpty || _isLoading) return;

    _promptController.clear();
    FocusScope.of(context).unfocus();

    final session = currentSession;

    // 1. Add User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: "user",
      text: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      session.messages.add(userMsg);
      // Update title if it's the first message
      if (session.messages.length == 1) {
        session.title = text.length > 20 ? "${text.substring(0, 20)}..." : text;
      }
      _isLoading = true;
    });
    _scrollToBottom();
    _saveSession(session);

    // 2. Add AI Placeholder (Typing/Generating)
    final aiMsgId = "${DateTime.now().millisecondsSinceEpoch}_ai";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      role: "ai",
      text: "",
      status: "generating", // Start directly with generating for image flow
      timestamp: DateTime.now(),
    );

    setState(() {
      session.messages.add(aiMsg);
    });
    _scrollToBottom();

    // 3. API Logic
    try {
      await _generateImageApi(text, session, aiMsg);
    } catch (e) {
      setState(() {
        aiMsg.status = "error";
        aiMsg.text = "Error generating image.";
        _isLoading = false;
      });
      _saveSession(session);
    }
  }

  Future<void> _generateImageApi(String prompt, ChatSession session, ChatMessage aiMsg) async {
    // API 1: Request Generation
    final url1 = Uri.parse("https://gen-z-image.vercel.app/gen");
    final res1 = await http.post(
      url1,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"q": prompt}),
    );

    if (res1.statusCode != 200) throw Exception("Failed to start generation");

    final data1 = jsonDecode(res1.body);
    final String id = data1["results"]["id"];

    // Wait 6 seconds
    await Future.delayed(const Duration(seconds: 6));

    // API 2: Check Result
    final url2 = Uri.parse("https://gen-z-image.vercel.app/check?id=$id");
    final res2 = await http.get(url2);

    if (res2.statusCode != 200) throw Exception("Failed to fetch image");

    final data2 = jsonDecode(res2.body);
    final List urls = data2["results"]["urls"];

    if (urls.isEmpty) throw Exception("No image returned");

    final String imageUrl = urls[0];

    // Update AI Message
    setState(() {
      aiMsg.imageUrl = imageUrl;
      aiMsg.status = "done";
      _isLoading = false;
    });

    _saveSession(session);
    _scrollToBottom();
  }

  Future<void> _downloadImage(String imageUrl, BuildContext context) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;

      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final savePath = "${dir.path}/$fileName";
      final file = File(savePath);

      final res = await http.get(Uri.parse(imageUrl));
      await file.writeAsBytes(res.bodyBytes);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Image saved to $savePath"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to save image")),
        );
      }
    }
  }

  // --- BUILD METHODS ---

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) {
       // Minimal loading state or init logic
       return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final session = currentSession;

    return Scaffold(
      appBar: AppBar(
        title: const Text("SkyGen", style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewSession,
            tooltip: "New Chat",
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              itemCount: session.messages.length,
              itemBuilder: (context, index) {
                final msg = session.messages[index];
                return _buildMessageBubble(msg);
              },
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xff141414),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.only(top: 60, bottom: 20, left: 20),
            width: double.infinity,
            color: const Color(0xff1E1E1E),
            child: const Text(
              "History",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final s = _sessions[index];
                final isSelected = s.id == _currentSessionId;
                return ListTile(
                  tileColor: isSelected ? Colors.white10 : null,
                  title: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    DateFormat('MMM d, h:mm a').format(s.createdAt),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  onTap: () => _switchSession(s.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.role == 'user';
    
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: isUser ? Theme.of(context).colorScheme.primary : const Color(0xff2C2C2C),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: isUser ? const Radius.circular(20) : Radius.zero,
            bottomRight: isUser ? Radius.zero : const Radius.circular(20),
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser)
              Text(
                msg.text,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            
            if (!isUser) ...[
              if (msg.status == 'generating' || msg.status == 'typing') ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text("Generating image...", style: TextStyle(color: Colors.white70)),
                  ],
                ),
                // Placeholder card
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(12),
                  ),
                )
              ] else if (msg.status == 'done' && msg.imageUrl.isNotEmpty) ...[
                // Image Display
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    msg.imageUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        height: 200,
                        width: double.infinity,
                        color: Colors.black26,
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _downloadImage(msg.imageUrl, context),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text("Download"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                )
              ] else if (msg.status == 'error') ...[
                const Text("⚠ Error generating image.", style: TextStyle(color: Colors.redAccent)),
              ]
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xff141414),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _promptController,
              enabled: !_isLoading,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Describe an image...",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xff2C2C2C),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _isLoading ? null : _sendMessage,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isLoading ? Colors.grey : Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_upward, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
