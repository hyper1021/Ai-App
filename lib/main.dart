import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:permission_handler/permission_handler.dart';

// ---------------------------------------------------------------------------
// MAIN ENTRY POINT
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
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
          seedColor: const Color(0xFF007AFF),
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
  String? imageUrl; // Result image from AI
  String? attachedImageUrl; // User uploaded image
  GenStatus status;
  final int timestamp;

  ChatMessage({
    required this.id,
    required this.text,
    required this.type,
    this.imageUrl,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'type': type.index,
    'imageUrl': imageUrl,
    'attachedImageUrl': attachedImageUrl,
    'status': status.index,
    'timestamp': timestamp,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    type: MessageType.values[map['type']],
    imageUrl: map['imageUrl'],
    attachedImageUrl: map['attachedImageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
  );
}

class ChatSession {
  final String id;
  String title;
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

  // --- NEW FEATURES VARIABLES ---
  String _selectedModel = "SkyGen"; // Defaults to Text AI
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;
  bool _showPlusIcon = true; // For single line logic

  @override
  void initState() {
    super.initState();
    _initStorage();
    _promptController.addListener(_handleInputListener);
  }

  @override
  void dispose() {
    _promptController.removeListener(_handleInputListener);
    _promptController.dispose();
    super.dispose();
  }

  void _handleInputListener() {
    // Hide plus icon if multiline
    final isMultiline = _promptController.text.contains('\n') || _promptController.text.length > 30;
    if (_showPlusIcon == isMultiline) {
       setState(() {
         _showPlusIcon = !isMultiline;
       });
    }
    // Update UI for send button state
    setState(() {}); 
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
          _sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        });
      }

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
      _sessions.insert(0, newSession);
      _currentSessionId = newId;
      _isGenerating = false;
      _promptController.clear();
      _clearAttachment(); // Clear image on new chat
    });

    if (!isFirstLoad) {
      _saveData();
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        Navigator.pop(context); 
      }
    }
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
      _isGenerating = false; 
      _clearAttachment();
    });
    Navigator.pop(context);
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

  // --- NEW: MODEL & ATTACHMENT LOGIC ---

  void _openModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.5,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Select AI Model", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              _buildModelTile("SkyGen", "Advanced Text AI Chat", Icons.chat_bubble_outline),
              const SizedBox(height: 10),
              _buildModelTile("Sky-Img", "AI Image Generation", Icons.image_outlined),
            ],
          ),
        );
      },
    );
  }

  Widget _buildModelTile(String id, String subtitle, IconData icon) {
    final isSelected = _selectedModel == id;
    return InkWell(
      onTap: () {
        setState(() => _selectedModel = id);
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF007AFF).withOpacity(0.1) : Colors.grey[50],
          border: Border.all(color: isSelected ? const Color(0xFF007AFF) : Colors.grey[200]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF007AFF) : Colors.black54),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            const Spacer(),
            if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF007AFF)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    // Request permission only on click
    if (Platform.isAndroid) {
      // Android 13+ use PHOTOS, older use STORAGE
      Map<Permission, PermissionStatus> statuses = await [
        Permission.storage,
        Permission.photos,
      ].request();
    }

    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      
      if (image != null) {
        setState(() {
          _pickedImage = File(image.path);
          _isUploadingImage = true;
        });
        
        await _uploadToImgBB(File(image.path));
      }
    } catch (e) {
      debugPrint("Image picker error: $e");
    }
  }

  Future<void> _uploadToImgBB(File imageFile) async {
    try {
      // Free ImgBB API Key (Ideally this should be user provided or env var)
      // Using a generic logic structure. 
      const apiKey = "6d207e02198a847aa98d0a2a901485a5"; 
      final uri = Uri.parse("https://api.imgbb.com/1/upload?key=$apiKey");
      
      var request = http.MultipartRequest('POST', uri);
      request.files.add(await http.MultipartFile.fromPath('image', imageFile.path));
      
      var res = await request.send();
      var responseBody = await res.stream.bytesToString();
      
      if (res.statusCode == 200) {
        final data = jsonDecode(responseBody);
        setState(() {
          _uploadedImgBBUrl = data['data']['url'];
          _isUploadingImage = false;
        });
      } else {
        throw Exception("ImgBB Upload Failed");
      }
    } catch (e) {
      setState(() {
        _pickedImage = null; // Remove preview on fail
        _isUploadingImage = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Upload failed: $e")));
    }
  }

  void _clearAttachment() {
    setState(() {
      _pickedImage = null;
      _uploadedImgBBUrl = null;
      _isUploadingImage = false;
    });
  }

  // --- CORE LOGIC: SEND MESSAGE ---

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    // Rule: Text mandatory. Image + Text OK. Image alone NO.
    if (prompt.isEmpty) return; 

    // Update Session Title
    final sessionIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sessionIndex != -1 && _sessions[sessionIndex].messages.isEmpty) {
      setState(() {
        _sessions[sessionIndex].title = prompt.length > 20 ? "${prompt.substring(0, 20)}..." : prompt;
      });
    }

    // Add User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      attachedImageUrl: _uploadedImgBBUrl, // Save attached image URL
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

    // Determine Logic based on Model and Attachment
    if (_selectedModel == "SkyGen" && _uploadedImgBBUrl == null) {
      await _processTextAI(prompt);
    } else {
      await _processImageGeneration(prompt, _uploadedImgBBUrl);
    }

    // Clear attachment after sending
    _clearAttachment();
  }

  // --- LOGIC: TEXT AI ---
  Future<void> _processTextAI(String prompt) async {
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Thinking...",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() => _currentSession.messages.add(aiMsg));
    _scrollToBottom();

    try {
      final url = Uri.parse("https://ai-hyper.vercel.app/api");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (_stopRequested) throw Exception("Stopped");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"] ?? "No response.";
        _updateMessageStatus(aiMsgId, GenStatus.completed, errorText: answer);
      } else {
        throw Exception("API Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  // --- LOGIC: IMAGE GENERATION ---
  Future<void> _processImageGeneration(String prompt, String? attachmentUrl) async {
     final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Generating image...",
      type: MessageType.ai,
      status: GenStatus.generating,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() => _currentSession.messages.add(aiMsg));
    _scrollToBottom();

    try {
      Uri genUrl;
      Map<String, dynamic> body;

      if (attachmentUrl != null) {
        // Image + Text API
        genUrl = Uri.parse("https://gen-z-image.vercel.app/image/gen");
        body = {"q": prompt, "url": attachmentUrl};
      } else {
        // Text to Image API
        genUrl = Uri.parse("https://gen-z-image.vercel.app/gen");
        body = {"q": prompt};
      }

      final response = await http.post(
        genUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 20));

      if (_stopRequested) throw Exception("Stopped");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _currentGenId = data["results"]["id"];
        await _pollForImage(aiMsgId, _currentGenId!);
      } else {
        throw Exception("Server Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: $e");
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
    const maxAttempts = 30; 
    
    while (attempts < maxAttempts) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped, errorText: "Stopped.");
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
      } catch (e) { /* ignore */ }
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Timeout.");
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
          text: errorText ?? _sessions[sIndex].messages[mIndex].text,
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

  // --- DOWNLOAD LOGIC ---

  Future<void> _downloadImage(String url) async {
    // Request Storage Permission
    if (Platform.isAndroid) {
       var status = await Permission.storage.request();
       if (status.isDenied) {
         // Try Manage External for Android 11+ if needed, but stick to simple first
         // For GitHub build safety, simple write external
       }
    }

    try {
      // Create Folder /SkyGen/
      Directory? directory;
      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/SkyGen');
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final file = File("${directory.path}/$fileName");

      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Saved to ${file.path}"),
            backgroundColor: Colors.black87,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Save failed: $e")));
      }
    }
  }

  // --- UI CONSTRUCTION ---

  @override
  Widget build(BuildContext context) {
    final currentMessages = _sessions.isEmpty ? <ChatMessage>[] : _currentSession.messages;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      
      drawer: _buildDrawer(),

      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, size: 28),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: GestureDetector(
          onTap: _openModelSelector,
          child: Row(
            children: [
              Text(_selectedModel),
              const Icon(Icons.arrow_drop_down, color: Colors.black54),
            ],
          ),
        ),
        centerTitle: false,
        actions: [
           IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
              child: const Icon(Icons.add, color: Colors.black87),
            ),
            onPressed: () => _createNewSession(),
          ),
          const SizedBox(width: 16),
        ],
      ),

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
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
            width: double.infinity,
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
                final isActive = session.id == _currentSessionId;
                return ListTile(
                  tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                  leading: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.black54),
                  title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                  onTap: () => _switchSession(session.id),
                );
              },
            ),
          ),
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
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -5))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Preview Attachment
          if (_pickedImage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(_pickedImage!, height: 80, width: 80, fit: BoxFit.cover),
                  ),
                  if (_isUploadingImage)
                    const Positioned.fill(child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                  Positioned(
                    top: 2, right: 2,
                    child: GestureDetector(
                      onTap: _clearAttachment,
                      child: Container(
                         padding: const EdgeInsets.all(2),
                         decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                         child: const Icon(Icons.close, size: 16, color: Colors.red),
                      ),
                    ),
                  )
                ],
              ),
            ),
          
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F4F7),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // UPLOAD BUTTON (Plus Icon)
                      if (_showPlusIcon)
                        IconButton(
                          icon: const Icon(Icons.add, color: Colors.grey),
                          onPressed: _pickImage,
                        ),
                      
                      Expanded(
                        child: TextField(
                          controller: _promptController,
                          enabled: !_isGenerating,
                          maxLines: 4,
                          minLines: 1,
                          style: const TextStyle(color: Colors.black87, fontSize: 16),
                          decoration: const InputDecoration(
                            hintText: "Message...",
                            hintStyle: TextStyle(color: Colors.grey),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => _isGenerating ? null : _handleSubmitted(),
                        ),
                      ),
                    ],
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
                    color: (_promptController.text.isEmpty) && !_isGenerating 
                        ? Colors.grey 
                        : (_isGenerating ? Colors.redAccent : Colors.black),
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
        color: const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.attachedImageUrl != null)
            Padding(
               padding: const EdgeInsets.only(bottom: 8),
               child: ClipRRect(
                 borderRadius: BorderRadius.circular(10),
                 child: Image.network(message.attachedImageUrl!, width: 150, fit: BoxFit.cover),
               ),
            ),
          Text(
            message.text,
            style: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildAIMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.status == GenStatus.completed && message.imageUrl != null)
          _buildImagePreview(context, message.imageUrl!)
        else if (message.status == GenStatus.completed && message.imageUrl == null)
           // Text AI Response (Markdown)
           Container(
             constraints: const BoxConstraints(maxWidth: 300),
             child: MarkdownBody(
               data: message.text,
               styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                 p: const TextStyle(fontSize: 16, color: Colors.black87),
               ),
             ),
           )
        else if (message.status == GenStatus.generating || message.status == GenStatus.waiting)
          _buildGeneratingState(message.status == GenStatus.generating ? "Creating masterpiece..." : "Thinking...")
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

  Widget _buildGeneratingState(String text) {
    return Container(
      width: 260,
      height: 100, // Smaller for text AI, fixed height for consistency
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const TypingIndicator(),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
            decoration: BoxDecoration(color: Colors.grey[50], shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome_rounded, size: 40, color: Colors.black87),
          ),
          const SizedBox(height: 24),
          const Text("What can I create for you?", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text("Select a model or type a prompt", style: TextStyle(color: Colors.grey)),
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
                  width: 8, height: 8,
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
