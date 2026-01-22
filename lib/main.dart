import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
// import 'package:intl/intl.dart'; // এই লাইনটা ডিলিট করা হয়েছে কারণ এটার দরকার নেই

// ---------------------------------------------------------------------------
// MAIN ENTRY POINT
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Status bar style for White Theme (Dark Icons)
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark, // Dark icons for white bg
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  runApp(const SkyGenApp());
}

// ---------------------------------------------------------------------------
// APP CONFIGURATION
// ---------------------------------------------------------------------------

class SkyGenApp extends StatelessWidget {
  const SkyGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkyGen AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF), // Professional Blue
          brightness: Brightness.light,
          background: const Color(0xFFFFFFFF),
          surface: const Color(0xFFF9F9F9),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            letterSpacing: -0.5,
          ),
        ),
        fontFamily: 'Roboto', 
      ),
      home: const ChatScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// DATA MODELS
// ---------------------------------------------------------------------------

enum MessageType { user, ai }
enum GenStatus { waiting, generating, completed, error, stopped }

class ChatMessage {
  final String id;
  final String text;
  final MessageType type;
  String? imageUrl;
  GenStatus status;
  final int timestamp;

  ChatMessage({
    required this.id,
    required this.text,
    required this.type,
    this.imageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'type': type.index,
    'imageUrl': imageUrl,
    'status': status.index,
    'timestamp': timestamp,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    type: MessageType.values[map['type']],
    imageUrl: map['imageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
  );
}

class ChatSession {
  final String id;
  String title; // First prompt usually
  final int createdAt;
  List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'createdAt': createdAt,
    'messages': messages.map((m) => m.toMap()).toList(),
  };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
    id: map['id'],
    title: map['title'],
    createdAt: map['createdAt'],
    messages: (map['messages'] as List).map((e) => ChatMessage.fromMap(e)).toList(),
  );
}

// ---------------------------------------------------------------------------
// CHAT SCREEN (MAIN UI)
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Logic Variables
  List<ChatSession> _sessions = [];
  String _currentSessionId = "";
  
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;
  File? _storageFile;

  @override
  void initState() {
    super.initState();
    _initStorage();
  }

  // --- STORAGE & SESSION MANAGEMENT ---

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_v3.json');
      
      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _sessions = jsonList.map((e) => ChatSession.fromMap(e)).toList();
          // Sort by newest first
          _sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        });
      }

      // If no sessions, create one, else load the most recent
      if (_sessions.isEmpty) {
        _createNewSession(isFirstLoad: true);
      } else {
        setState(() {
          _currentSessionId = _sessions.first.id;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (e) {
      debugPrint("Error loading history: $e");
      _createNewSession(isFirstLoad: true);
    }
  }

  Future<void> _saveData() async {
    if (_storageFile == null) return;
    try {
      final String data = jsonEncode(_sessions.map((e) => e.toMap()).toList());
      await _storageFile!.writeAsString(data);
    } catch (e) {
      debugPrint("Error saving data: $e");
    }
  }

  void _createNewSession({bool isFirstLoad = false}) {
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    final newSession = ChatSession(
      id: newId, 
      title: "New Chat", 
      createdAt: DateTime.now().millisecondsSinceEpoch, 
      messages: []
    );

    setState(() {
      _sessions.insert(0, newSession); // Add to top
      _currentSessionId = newId;
      _isGenerating = false;
      _promptController.clear();
    });

    if (!isFirstLoad) {
      _saveData();
      // Close drawer if open
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        Navigator.pop(context); 
      }
    }
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
      _isGenerating = false; 
    });
    Navigator.pop(context); // Close drawer
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  ChatSession get _currentSession {
    return _sessions.firstWhere((s) => s.id == _currentSessionId, orElse: () => _sessions.first);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // --- CORE LOGIC: IMAGE GENERATION ---

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    // Update Session Title if it's the first message
    final sessionIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sessionIndex != -1 && _sessions[sessionIndex].messages.isEmpty) {
      setState(() {
        _sessions[sessionIndex].title = prompt.length > 20 ? "${prompt.substring(0, 20)}..." : prompt;
      });
    }

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _currentSession.messages.add(userMsg);
      _promptController.clear();
      _isGenerating = true;
      _stopRequested = false;
    });
    
    _scrollToBottom();
    _saveData();

    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Generating image...",
      type: MessageType.ai,
      status: GenStatus.generating,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _currentSession.messages.add(aiMsg);
    });
    _scrollToBottom();

    try {
      // API 1: Request
      final genUrl = Uri.parse("https://gen-z-image.vercel.app/gen");
      // Use try-catch specifically for network errors
      final response = await http.post(
        genUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      ).timeout(const Duration(seconds: 20));

      if (_stopRequested) throw Exception("Stopped by user");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _currentGenId = data["results"]["id"];
        await _pollForImage(aiMsgId, _currentGenId!);
      } else {
        throw Exception("Server Error: ${response.statusCode}");
      }
    } catch (e) {
      String errorMsg = "Something went wrong.";
      if (e.toString().contains("SocketException")) {
        errorMsg = "No Internet Connection. Please check your data/wifi.";
      } else if (e.toString().contains("Timeout")) {
        errorMsg = "Request timed out. Server is busy.";
      }
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: errorMsg);
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _currentGenId = null;
        });
        _saveData();
      }
    }
  }

  Future<void> _pollForImage(String msgId, String generationId) async {
    int attempts = 0;
    const maxAttempts = 30; // ~60 seconds
    
    while (attempts < maxAttempts) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped, errorText: "Generation stopped.");
        return;
      }

      await Future.delayed(const Duration(seconds: 2));
      
      try {
        final checkUrl = Uri.parse("https://gen-z-image.vercel.app/check?id=$generationId");
        final response = await http.get(checkUrl);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List<dynamic> urls = data["results"]["urls"] ?? [];

          if (urls.isNotEmpty) {
            _updateMessageStatus(msgId, GenStatus.completed, imageUrl: urls.first);
            return;
          }
        }
      } catch (e) {
        debugPrint("Polling flicker: $e");
      }
      attempts++;
    }
    
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Generation took too long.");
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? errorText}) {
    if (!mounted) return;
    final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;

    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        _sessions[sIndex].messages[mIndex] = ChatMessage(
          id: msgId,
          text: errorText ?? (status == GenStatus.completed ? "Image generated successfully" : _sessions[sIndex].messages[mIndex].text),
          type: MessageType.ai,
          imageUrl: imageUrl,
          status: status,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      });
      _saveData();
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  Future<void> _downloadImage(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final file = File("${dir.path}/$fileName");

      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: const [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 10),
                Text("Saved to Documents Folder"),
              ],
            ),
            backgroundColor: Colors.black87,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Save failed: $e")),
        );
      }
    }
  }

  // --- UI CONSTRUCTION ---

  @override
  Widget build(BuildContext context) {
    // Current messages to display
    final currentMessages = _sessions.isEmpty 
        ? <ChatMessage>[] 
        : _currentSession.messages;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      
      // 1. DRAWER (HISTORY)
      drawer: Drawer(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
              width: double.infinity,
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("SkyGen History", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  SizedBox(height: 5),
                  Text("Your creative journey", style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final bool isActive = session.id == _currentSessionId;
                  return ListTile(
                    tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                    leading: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.black54),
                    title: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                        color: Colors.black87,
                      ),
                    ),
                    onTap: () => _switchSession(session.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),

      // 2. APP BAR (Redesigned)
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, size: 28),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text("SkyGen AI"),
        centerTitle: false,
        titleSpacing: 0,
        actions: [
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add, color: Colors.black87),
            ),
            tooltip: "New Chat",
            onPressed: () => _createNewSession(),
          ),
          const SizedBox(width: 16),
        ],
      ),

      // 3. BODY
      body: Column(
        children: [
          Expanded(
            child: currentMessages.isEmpty
                ? const WelcomePlaceholder()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                    itemCount: currentMessages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: currentMessages[index],
                        onDownload: _downloadImage,
                      );
                    },
                  ),
          ),
          
          // 4. INPUT AREA
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -5),
          )
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF2F4F7), // Light grey input bg
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _promptController,
                enabled: !_isGenerating,
                maxLines: 4,
                minLines: 1,
                style: const TextStyle(color: Colors.black87, fontSize: 16),
                decoration: const InputDecoration(
                  hintText: "Describe an image...",
                  hintStyle: TextStyle(color: Colors.grey),
                  contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _isGenerating ? null : _handleSubmitted(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _isGenerating ? () => setState(() => _stopRequested = true) : _handleSubmitted,
            child: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: _isGenerating ? Colors.redAccent : Colors.black,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WIDGETS
// ---------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String) onDownload;

  const ChatBubble({super.key, required this.message, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    final isUser = message.type == MessageType.user;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const CircleAvatar(
              radius: 14,
              backgroundColor: Colors.black,
              child: Icon(Icons.auto_awesome, size: 14, color: Colors.white),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: isUser 
              ? _buildUserMessage() 
              : _buildAIMessage(context),
          ),
        ],
      ),
    );
  }

  Widget _buildUserMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F2), // Light grey for user
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        message.text,
        style: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.4),
      ),
    );
  }

  Widget _buildAIMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.status == GenStatus.completed && message.imageUrl != null)
          _buildImagePreview(context, message.imageUrl!)
        else if (message.status == GenStatus.generating)
          _buildGeneratingState()
        else if (message.status == GenStatus.error || message.status == GenStatus.stopped)
          _buildErrorState(),
      ],
    );
  }

  Widget _buildImagePreview(BuildContext context, String url) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return const SizedBox(
                  height: 300,
                  width: 300,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              },
            ),
            Positioned(
              bottom: 10,
              right: 10,
              child: GestureDetector(
                onTap: () => onDownload(url),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.download_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratingState() {
    return Container(
      width: 260,
      height: 260,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          TypingIndicator(),
          SizedBox(height: 16),
          Text("Creating masterpiece...", style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFCDCD)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message.text,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }
}

class WelcomePlaceholder extends StatelessWidget {
  const WelcomePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome_rounded, size: 40, color: Colors.black87),
          ),
          const SizedBox(height: 24),
          const Text(
            "What can I create for you?",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "Start by typing a prompt below",
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
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
    return SizedBox(
      width: 50,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final double value = sin((_controller.value * 2 * pi) + (index * 1.0));
              return Opacity(
                opacity: (value + 1) / 2.0 * 0.6 + 0.4,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
