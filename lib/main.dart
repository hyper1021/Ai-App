import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// MAIN ENTRY POINT
// ---------------------------------------------------------------------------

void main() {
  // Ensure bindings are initialized before calling native code (path_provider)
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set preferred orientation to portrait only for mobile layout stability
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style for dark theme integration
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xff121212),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const SkyGenApp());
}

// ---------------------------------------------------------------------------
// APP WIDGET
// ---------------------------------------------------------------------------

class SkyGenApp extends StatelessWidget {
  const SkyGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkyGen AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
          background: const Color(0xff121212),
          surface: const Color(0xff1E1E1E),
        ),
        scaffoldBackgroundColor: const Color(0xff121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff121212),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: Colors.white,
          ),
        ),
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
  final String text; // Prompt for user, or status text for AI
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

  // Convert to Map for JSON storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'text': text,
      'type': type.index,
      'imageUrl': imageUrl,
      'status': status.index,
      'timestamp': timestamp,
    };
  }

  // Create from Map
  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'],
      text: map['text'],
      type: MessageType.values[map['type']],
      imageUrl: map['imageUrl'],
      status: GenStatus.values[map['status']],
      timestamp: map['timestamp'],
    );
  }
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
  final List<ChatMessage> _messages = [];
  
  bool _isGenerating = false;
  String? _currentGenId; // ID from API 1
  bool _stopRequested = false;

  // Persistence File
  File? _historyFile;

  @override
  void initState() {
    super.initState();
    _initStorage();
  }

  // Initialize local storage (File based, no SharedPrefs needed)
  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _historyFile = File('${dir.path}/chat_history.json');
      
      if (await _historyFile!.exists()) {
        final content = await _historyFile!.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _messages.addAll(jsonList.map((e) => ChatMessage.fromMap(e)).toList());
        });
        // Scroll to bottom after loading
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (e) {
      debugPrint("Error loading history: $e");
    }
  }

  // Save chat to local file
  Future<void> _saveHistory() async {
    if (_historyFile == null) return;
    try {
      final String data = jsonEncode(_messages.map((e) => e.toMap()).toList());
      await _historyFile!.writeAsString(data);
    } catch (e) {
      debugPrint("Error saving history: $e");
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200, // Extra padding
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // -------------------------------------------------------------------------
  // CORE LOGIC: IMAGE GENERATION
  // -------------------------------------------------------------------------

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    // 1. Add User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _messages.add(userMsg);
      _promptController.clear();
      _isGenerating = true;
      _stopRequested = false;
    });
    
    _scrollToBottom();
    _saveHistory();

    // 2. Add Placeholder AI Message
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Generating image...",
      type: MessageType.ai,
      status: GenStatus.generating,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _messages.add(aiMsg);
    });
    _scrollToBottom();

    // 3. Start API Call
    try {
      // API 1: Request Generation
      final genUrl = Uri.parse("https://gen-z-image.vercel.app/gen");
      final response = await http.post(
        genUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (_stopRequested) throw Exception("Stopped by user");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _currentGenId = data["results"]["id"];
        
        // Start Polling
        await _pollForImage(aiMsgId, _currentGenId!);
      } else {
        throw Exception("Server rejected request");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: ${e.toString()}");
    } finally {
      setState(() {
        _isGenerating = false;
        _currentGenId = null;
      });
      _saveHistory();
    }
  }

  // API 2: Poll for result
  Future<void> _pollForImage(String msgId, String generationId) async {
    int attempts = 0;
    const maxAttempts = 30; // 60 seconds timeout approx
    
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
            // Success!
            _updateMessageStatus(msgId, GenStatus.completed, imageUrl: urls.first);
            return;
          }
          // If empty, it's still processing, loop continues
        }
      } catch (e) {
        // Network flicker, just continue
        debugPrint("Polling error: $e");
      }

      attempts++;
    }
    
    // Timeout
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Timeout: Generation took too long.");
  }

  void _updateMessageStatus(String id, GenStatus status, {String? imageUrl, String? errorText}) {
    final index = _messages.indexWhere((m) => m.id == id);
    if (index != -1) {
      setState(() {
        _messages[index] = ChatMessage(
          id: _messages[index].id,
          text: errorText ?? (status == GenStatus.completed ? "Here is your image" : _messages[index].text),
          type: _messages[index].type,
          imageUrl: imageUrl,
          status: status,
          timestamp: _messages[index].timestamp,
        );
      });
      _saveHistory();
      if (status == GenStatus.completed) {
        _scrollToBottom();
      }
    }
  }

  void _stopGeneration() {
    setState(() {
      _stopRequested = true;
    });
  }

  // -------------------------------------------------------------------------
  // IMAGE DOWNLOAD LOGIC
  // -------------------------------------------------------------------------

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
                Icon(Icons.check_circle, color: Colors.greenAccent),
                SizedBox(width: 10),
                Text("Image saved to Documents"),
              ],
            ),
            backgroundColor: const Color(0xff333333),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Download failed: $e")),
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // UI BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: Color(0xFF00E5FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome, color: Colors.black, size: 16),
            ),
            const SizedBox(width: 10),
            const Text("SkyGen AI"),
          ],
        ),
      ),
      body: Column(
        children: [
          // Chat List
          Expanded(
            child: _messages.isEmpty
                ? const EmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(top: 10, bottom: 20, left: 16, right: 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return MessageBubble(
                        message: _messages[index],
                        onDownload: _downloadImage,
                      );
                    },
                  ),
          ),

          // Input Area
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xff1E1E1E),
                border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xff2C2C2C),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _promptController,
                        enabled: !_isGenerating,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: _isGenerating ? "Wait for image..." : "Describe an image...",
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _isGenerating ? null : _handleSubmitted(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _isGenerating ? _stopGeneration : _handleSubmitted,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: _isGenerating ? Colors.redAccent : const Color(0xFF00E5FF),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (_isGenerating ? Colors.red : const Color(0xFF00E5FF)).withOpacity(0.3),
                            blurRadius: 8,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Icon(
                        _isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                        color: Colors.black,
                        size: 26,
                      ),
                    ),
                  ),
                ],
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

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String) onDownload;

  const MessageBubble({
    super.key,
    required this.message,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.type == MessageType.user;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Header (Name)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              isUser ? "You" : "SkyGen AI",
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.6),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 6),
          
          // Content
          isUser
            ? _buildUserBubble(context)
            : _buildAIBubble(context),
        ],
      ),
    );
  }

  Widget _buildUserBubble(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
      decoration: const BoxDecoration(
        color: Color(0xff333333),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(18),
          topRight: Radius.circular(4),
          bottomLeft: Radius.circular(18),
          bottomRight: Radius.circular(18),
        ),
      ),
      child: Text(
        message.text,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }

  Widget _buildAIBubble(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logic for Image State
          if (message.status == GenStatus.completed && message.imageUrl != null)
            _buildImageCard(context, message.imageUrl!)
          else if (message.status == GenStatus.generating)
            _buildLoadingCard()
          else if (message.status == GenStatus.error || message.status == GenStatus.stopped)
            _buildErrorCard(),
        ],
      ),
    );
  }

  Widget _buildImageCard(BuildContext context, String url) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        color: Colors.black,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const SizedBox(
                  height: 250,
                  child: Center(child: CircularProgressIndicator()),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return const SizedBox(
                  height: 200, 
                  child: Center(child: Icon(Icons.broken_image, color: Colors.grey)),
                );
              },
            ),
          ),
          InkWell(
            onTap: () => onDownload(url),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xff252525),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.download_rounded, size: 20, color: Colors.white),
                  SizedBox(width: 8),
                  Text("Download", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      height: 250,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xff1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          TypingIndicator(),
          SizedBox(height: 16),
          Text(
            "Dreaming up your image...",
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff2C1515),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
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

// ---------------------------------------------------------------------------
// ANIMATIONS
// ---------------------------------------------------------------------------

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
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
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
                  decoration: const BoxDecoration(
                    color: Color(0xFF00E5FF),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
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
            decoration: BoxDecoration(
              color: const Color(0xff2C2C2C),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 15,
                  spreadRadius: 2,
                )
              ],
            ),
            child: const Icon(Icons.auto_awesome_mosaic_rounded, size: 48, color: Color(0xFF00E5FF)),
          ),
          const SizedBox(height: 20),
          const Text(
            "SkyGen AI",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Imagine anything.\nJust type a prompt to start.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Colors.white54,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
