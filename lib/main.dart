import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

// -----------------------------------------------------------------------------
// MAIN ENTRY POINT
// -----------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Shared Preferences before app start
  final prefs = await SharedPreferences.getInstance();
  
  runApp(SkyGenApp(prefs: prefs));
}

class SkyGenApp extends StatelessWidget {
  final SharedPreferences prefs;

  const SkyGenApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SkyGen AI',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF101010),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4facfe),
          secondary: Color(0xFF00f2fe),
          surface: Color(0xFF1E1E1E),
          background: Color(0xFF101010),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101010),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: ChatScreen(prefs: prefs),
    );
  }
}

// -----------------------------------------------------------------------------
// DATA MODELS
// -----------------------------------------------------------------------------

enum MessageRole { user, ai }
enum MessageStatus { sending, loading, generating, complete, error }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String text;      // For User
  String? imageUrl;       // For AI
  String? localPath;      // For Downloaded Image
  MessageStatus status;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.imageUrl,
    this.localPath,
    required this.status,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.toString(),
    'text': text,
    'imageUrl': imageUrl,
    'localPath': localPath,
    'status': status.toString(),
    'timestamp': timestamp.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      role: MessageRole.values.firstWhere((e) => e.toString() == json['role']),
      text: json['text'],
      imageUrl: json['imageUrl'],
      localPath: json['localPath'],
      status: MessageStatus.values.firstWhere((e) => e.toString() == json['status']),
      timestamp: DateTime.parse(json['timestamp']),
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
// CHAT CONTROLLER / PROVIDER LOGIC
// -----------------------------------------------------------------------------

class ChatController extends ChangeNotifier {
  final SharedPreferences prefs;
  List<ChatSession> sessions = [];
  String? currentSessionId;
  final ScrollController scrollController = ScrollController();
  bool isTyping = false;

  ChatController(this.prefs) {
    loadSessions();
  }

  ChatSession? get currentSession {
    if (currentSessionId == null) return null;
    try {
      return sessions.firstWhere((s) => s.id == currentSessionId);
    } catch (e) {
      return null;
    }
  }

  void loadSessions() {
    final String? data = prefs.getString('chat_history');
    if (data != null) {
      final List<dynamic> jsonList = jsonDecode(data);
      sessions = jsonList.map((json) => ChatSession.fromJson(json)).toList();
      // Sort by newest first
      sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    
    if (sessions.isNotEmpty) {
      currentSessionId = sessions.first.id;
    } else {
      createNewSession();
    }
    notifyListeners();
  }

  void saveSessions() {
    final String data = jsonEncode(sessions.map((s) => s.toJson()).toList());
    prefs.setString('chat_history', data);
    notifyListeners();
  }

  void createNewSession() {
    final newSession = ChatSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: "New Chat",
      createdAt: DateTime.now(),
      messages: [],
    );
    sessions.insert(0, newSession);
    currentSessionId = newSession.id;
    saveSessions();
    
    // Auto scroll to bottom reset
    if(scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  void switchSession(String sessionId) {
    currentSessionId = sessionId;
    notifyListeners();
    // Small delay to allow UI to build then scroll to bottom
    Future.delayed(const Duration(milliseconds: 100), scrollToBottom);
  }

  void scrollToBottom() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // CORE IMAGE GENERATION LOGIC
  Future<void> sendMessage(String prompt) async {
    if (currentSession == null) createNewSession();
    final session = currentSession!;

    // 1. Update Title if it's the first message
    if (session.messages.isEmpty) {
      session.title = prompt.length > 20 ? "${prompt.substring(0, 20)}..." : prompt;
    }

    // 2. Add User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      text: prompt,
      status: MessageStatus.complete,
      timestamp: DateTime.now(),
    );
    session.messages.add(userMsg);
    notifyListeners();
    scrollToBottom();

    // 3. Add AI Placeholder (Loading)
    isTyping = true;
    notifyListeners();
    
    // Simulate "Reading" time
    await Future.delayed(const Duration(milliseconds: 600));

    final aiMsgId = "${DateTime.now().millisecondsSinceEpoch}_ai";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      role: MessageRole.ai,
      text: "Generating image...",
      status: MessageStatus.generating,
      timestamp: DateTime.now(),
    );
    
    session.messages.add(aiMsg);
    isTyping = false;
    notifyListeners();
    scrollToBottom();

    // 4. API Call
    try {
      // Step A: Request Generation
      final url = Uri.parse("https://gen-z-image.vercel.app/gen");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (response.statusCode != 200) throw Exception("API Error");

      final data = jsonDecode(response.body);
      final String generationId = data["results"]["id"];

      // Step B: Wait (Simulate processing)
      await Future.delayed(const Duration(seconds: 6));

      // Step C: Check Result
      final checkUrl = Uri.parse("https://gen-z-image.vercel.app/check?id=$generationId");
      final checkResponse = await http.get(checkUrl);

      final checkData = jsonDecode(checkResponse.body);
      final List<dynamic> urls = checkData["results"]["urls"];
      
      if (urls.isNotEmpty) {
        // Update Message to Complete
        aiMsg.imageUrl = urls[0];
        aiMsg.status = MessageStatus.complete;
      } else {
        throw Exception("No image returned");
      }

    } catch (e) {
      aiMsg.status = MessageStatus.error;
      aiMsg.text = "Failed to generate image. Please try again.";
    }

    saveSessions();
    scrollToBottom();
  }

  Future<void> downloadImage(String url, BuildContext context) async {
    try {
      final dir = await getExternalStorageDirectory(); // Or getApplicationDocumentsDirectory
      // Create a specific folder if needed, or just save to root of app storage
      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final savePath = "${dir!.path}/$fileName";
      final file = File(savePath);

      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);

      // Find message and update local path
      // (Simplified: In a real app we'd search properly, here we assume current context)
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Image saved to $savePath"),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Download failed"), backgroundColor: Colors.red),
      );
    }
  }
}

// -----------------------------------------------------------------------------
// UI SCREEN
// -----------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const ChatScreen({super.key, required this.prefs});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late ChatController controller;
  final TextEditingController textController = TextEditingController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    controller = ChatController(widget.prefs);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final session = controller.currentSession;
        
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: const Color(0xFF101010),
          drawer: _buildDrawer(),
          appBar: AppBar(
            backgroundColor: const Color(0xFF141414),
            leading: IconButton(
              icon: const Icon(Icons.history, color: Colors.white70),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("SkyGen AI", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                if (session != null)
                  Text(
                    session.title, 
                    style: const TextStyle(fontSize: 12, color: Colors.white54, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.add, color: Colors.blueAccent),
                onPressed: () {
                  controller.createNewSession();
                },
              )
            ],
          ),
          body: Column(
            children: [
              // Chat Area
              Expanded(
                child: session == null || session.messages.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      controller: controller.scrollController,
                      padding: const EdgeInsets.only(bottom: 20, top: 10),
                      itemCount: session.messages.length + (controller.isTyping ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == session.messages.length) {
                           // Show typing indicator
                           return const Padding(
                             padding: EdgeInsets.only(left: 16, bottom: 12),
                             child: TypingIndicator(),
                           );
                        }
                        return ChatBubble(
                          message: session.messages[index], 
                          onDownload: (url) => controller.downloadImage(url, context),
                        );
                      },
                    ),
              ),

              // Input Area
              _buildInputArea(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Colors.blueAccent.withOpacity(0.2), blurRadius: 20, spreadRadius: 5)
              ]
            ),
            child: const Icon(Icons.auto_awesome, size: 50, color: Colors.blueAccent),
          ),
          const SizedBox(height: 20),
          const Text(
            "SkyGen Image AI",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 10),
          const Text(
            "Imagine anything. Create everything.",
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF121212),
      child: Column(
        children: [
          SafeArea(
            child: Container(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.blueAccent),
                  const SizedBox(width: 10),
                  const Text("History", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: Colors.white54),
                    onPressed: () {
                      Navigator.pop(context);
                      controller.createNewSession();
                    },
                  )
                ],
              ),
            ),
          ),
          const Divider(color: Colors.white10),
          Expanded(
            child: ListView.builder(
              itemCount: controller.sessions.length,
              itemBuilder: (context, index) {
                final s = controller.sessions[index];
                final isSelected = s.id == controller.currentSessionId;
                return ListTile(
                  tileColor: isSelected ? const Color(0xFF1E1E1E) : null,
                  title: Text(
                    s.title,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    DateFormat('MMM d, h:mm a').format(s.createdAt),
                    style: const TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                  onTap: () {
                    controller.switchSession(s.id);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          )
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF141414),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF252525),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: textController,
                  style: const TextStyle(color: Colors.white),
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: "Describe an image...",
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                  onSubmitted: (_) => _handleSend(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _handleSend,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Colors.blueAccent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_upward, color: Colors.white),
              ),
            )
          ],
        ),
      ),
    );
  }

  void _handleSend() {
    final text = textController.text.trim();
    if (text.isEmpty) return;
    textController.clear();
    FocusScope.of(context).unfocus();
    controller.sendMessage(text);
  }
}

// -----------------------------------------------------------------------------
// WIDGETS
// -----------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String) onDownload;

  const ChatBubble({super.key, required this.message, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              height: 30, width: 30,
              decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
          ],
          
          Flexible(
            child: isUser 
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2C),
                    borderRadius: BorderRadius.circular(20).copyWith(bottomRight: const Radius.circular(4)),
                  ),
                  child: Text(
                    message.text,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                )
              : _buildAIContent(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAIContent(BuildContext context) {
    if (message.status == MessageStatus.generating) {
      return Container(
        width: 250,
        height: 300,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
             CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
             SizedBox(height: 16),
             Text("Generating masterpiece...", style: TextStyle(color: Colors.white54, fontSize: 12))
          ],
        ),
      );
    }

    if (message.status == MessageStatus.error) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: Text(message.text, style: const TextStyle(color: Colors.redAccent)),
      );
    }

    // Image Ready
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 280, // Constrain width
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                Image.network(
                  message.imageUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return Container(
                      height: 280,
                      color: const Color(0xFF1E1E1E),
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  },
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: GestureDetector(
                    onTap: () => _showFullScreenImage(context, message.imageUrl!),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.fullscreen, color: Colors.white, size: 20),
                    ),
                  ),
                )
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 280,
          child: OutlinedButton.icon(
            onPressed: () => onDownload(message.imageUrl!),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text("Download"),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        )
      ],
    );
  }

  void _showFullScreenImage(BuildContext context, String url) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.transparent, iconTheme: const IconThemeData(color: Colors.white)),
        body: Center(child: Image.network(url)),
      )
    ));
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
      children: [
        Container(
          height: 30, width: 30,
          decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
          child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Row(
          children: List.generate(3, (index) {
            return FadeTransition(
              opacity: DelayTween(begin: 0.0, end: 1.0, delay: index * 0.2).animate(_controller),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 8, height: 8,
                decoration: const BoxDecoration(color: Colors.white54, shape: BoxShape.circle),
              ),
            );
          }),
        ),
      ],
    );
  }
}

// Helper for Staggered Animation
class DelayTween extends Tween<double> {
  DelayTween({required double begin, required double end, required this.delay}) : super(begin: begin, end: end);
  final double delay;

  @override
  double lerp(double t) => super.lerp((t - delay).clamp(0.0, 1.0));
}
