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
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';

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
      title: 'SkyGen',
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
// MODELS
// ---------------------------------------------------------------------------

enum MessageType { user, ai, offline }
enum GenStatus { waiting, generating, completed, error, stopped }
enum AIModel { skyGen, skyImg, imgDescriber, skyCoder }

class ChatMessage {
  final String id;
  String text;
  final MessageType type;
  String? imageUrl; 
  String? attachedImageUrl;
  GenStatus status;
  final int timestamp;
  bool isAnimated; // Controls typing effect

  ChatMessage({
    required this.id,
    required this.text,
    required this.type,
    this.imageUrl,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
    this.isAnimated = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'type': type.index,
    'imageUrl': imageUrl,
    'attachedImageUrl': attachedImageUrl,
    'status': status.index,
    'timestamp': timestamp,
    'isAnimated': false, // Never save animation state as true
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    type: MessageType.values[map['type']],
    imageUrl: map['imageUrl'],
    attachedImageUrl: map['attachedImageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
    isAnimated: false,
  );
}

class ChatSession {
  final String id;
  String title;
  final int createdAt;
  bool isPinned;
  List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    this.isPinned = false,
    required this.messages,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'createdAt': createdAt,
    'isPinned': isPinned,
    'messages': messages.map((m) => m.toMap()).toList(),
  };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
    id: map['id'],
    title: map['title'],
    createdAt: map['createdAt'],
    isPinned: map['isPinned'] ?? false,
    messages: (map['messages'] as List).map((e) => ChatMessage.fromMap(e)).toList(),
  );
}

// ---------------------------------------------------------------------------
// MAIN CHAT SCREEN
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Data
  List<ChatSession> _sessions = [];
  String _currentSessionId = "";
  File? _storageFile;

  // Logic
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;
  bool _isSearching = false; // Drawer search state
  
  // New Features Variables
  AIModel _selectedModel = AIModel.skyGen;
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;

  @override
  void initState() {
    super.initState();
    _initStorage();
    _promptController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  // --- STORAGE & SESSION ---

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_v5.json');
      
      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _sessions = jsonList.map((e) => ChatSession.fromMap(e)).toList();
          _sortSessions();
        });
      }

      if (_sessions.isEmpty) {
        _createNewSession(isFirstLoad: true);
      } else {
        setState(() => _currentSessionId = _sessions.first.id);
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (e) {
      _createNewSession(isFirstLoad: true);
    }
  }

  void _sortSessions() {
    _sessions.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  Future<void> _saveData() async {
    if (_storageFile == null) return;
    try {
      final String data = jsonEncode(_sessions.map((e) => e.toMap()).toList());
      await _storageFile!.writeAsString(data);
    } catch (e) {
      debugPrint("Save error: $e");
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
      _sortSessions();
      _currentSessionId = newId;
      _isGenerating = false;
      _promptController.clear();
      _clearAttachment();
    });

    if (!isFirstLoad) {
      _saveData();
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) Navigator.pop(context); 
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

  // --- MODELS & INPUT ---

  void _openModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.55,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // No title in model selector as per rules
              _buildModelTile(AIModel.skyGen, "SkyGen", "Default AI Chat Model", Icons.chat_bubble_outline),
              const SizedBox(height: 10),
              _buildModelTile(AIModel.skyImg, "Sky-Img", "Image Generation Model", Icons.image_outlined),
              const SizedBox(height: 10),
              _buildModelTile(AIModel.imgDescriber, "Img Describer", "Image Understanding", Icons.remove_red_eye_outlined),
              const SizedBox(height: 10),
              _buildModelTile(AIModel.skyCoder, "Sky Coder", "Programming Model", Icons.code),
            ],
          ),
        );
      },
    );
  }

  Widget _buildModelTile(AIModel model, String title, String subtitle, IconData icon) {
    final isSelected = _selectedModel == model;
    return InkWell(
      onTap: () {
        setState(() => _selectedModel = model);
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
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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

  // --- IMAGE PICKER & UPLOAD ---

  Future<void> _pickImage() async {
    // Custom gallery check
    if (Platform.isAndroid) {
      await [Permission.storage, Permission.photos].request();
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
      debugPrint("Picker error: $e");
    }
  }

  Future<void> _uploadToImgBB(File imageFile) async {
    try {
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
        throw Exception("Upload failed");
      }
    } catch (e) {
      setState(() {
        _pickedImage = null;
        _isUploadingImage = false;
      });
      _showToast("Image upload failed.", isError: true);
    }
  }

  void _clearAttachment() {
    setState(() {
      _pickedImage = null;
      _uploadedImgBBUrl = null;
      _isUploadingImage = false;
    });
  }

  // --- CORE CHAT LOGIC ---

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    
    // OFFLINE CHECK
    try {
      final result = await InternetAddress.lookup('google.com');
      if (result.isEmpty || result[0].rawAddress.isEmpty) throw Exception("Offline");
    } catch (_) {
      setState(() {
        _currentSession.messages.add(ChatMessage(
          id: DateTime.now().toString(),
          text: "Internet connection unavailable. Please turn on internet and try again.",
          type: MessageType.offline,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      });
      _scrollToBottom();
      return;
    }

    // Validation
    if (prompt.isEmpty) return; // Image alone not allowed rule
    if (_pickedImage != null && _uploadedImgBBUrl == null) {
      _showToast("Wait for image upload...", isError: true);
      return;
    }

    // Set Title if new
    final sessionIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sessionIndex != -1 && _sessions[sessionIndex].messages.isEmpty) {
      setState(() {
        _sessions[sessionIndex].title = prompt.length > 20 ? "${prompt.substring(0, 20)}..." : prompt;
      });
    }

    // User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      attachedImageUrl: _uploadedImgBBUrl,
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
    
    String? attachment = _uploadedImgBBUrl;
    _clearAttachment(); // Clear UI immediately

    // Route to Logic
    if (_selectedModel == AIModel.skyImg) {
      await _processImageGeneration(prompt, attachment);
    } else if (_selectedModel == AIModel.imgDescriber && attachment != null) {
      await _processImageDescriber(prompt, attachment);
    } else if (_selectedModel == AIModel.skyCoder) {
      await _processSkyCoder(prompt);
    } else {
      // Default SkyGen (Text)
      await _processSkyGen(prompt, attachment);
    }
  }

  // 1. SKYGEN (Text)
  Future<void> _processSkyGen(String prompt, String? attachment) async {
    final aiMsgId = _addPlaceholder();
    try {
      final url = Uri.parse("https://ai-hyper.vercel.app/api");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}), // Standard SkyGen ignores image currently
      );

      if (_stopRequested) throw Exception("Stopped");
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"] ?? "No response.";
        _updateMessageStatus(aiMsgId, GenStatus.completed, resultText: answer);
      } else {
        throw Exception("API Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, resultText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  // 2. SKY-IMG (Image Gen)
  Future<void> _processImageGeneration(String prompt, String? attachment) async {
    final aiMsgId = _addPlaceholder(isImageGen: true);
    try {
      Uri genUrl;
      Map<String, dynamic> body;

      if (attachment != null) {
        genUrl = Uri.parse("https://gen-z-image.vercel.app/image/gen");
        body = {"q": prompt, "url": attachment};
      } else {
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
      _updateMessageStatus(aiMsgId, GenStatus.error, resultText: "Failed: $e");
    } finally {
      if (mounted) setState(() { _isGenerating = false; _currentGenId = null; });
      _saveData();
    }
  }

  // 3. IMG DESCRIBER
  Future<void> _processImageDescriber(String prompt, String attachment) async {
    final aiMsgId = _addPlaceholder();
    try {
      // Step 1: Describe
      final descUrl = Uri.parse("https://gen-z-describer.vercel.app/api?url=$attachment");
      final descRes = await http.get(descUrl);
      String description = "";
      if (descRes.statusCode == 200) {
        final data = jsonDecode(descRes.body);
        description = data["results"]["description"] ?? "";
      }

      // Step 2: Combine and Send to SkyGen
      // "SkyGen" text API is rigid, we append description to prompt for context.
      final fullPrompt = "User said: $prompt. Image context: $description";
      
      final url = Uri.parse("https://ai-hyper.vercel.app/api");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": fullPrompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"] ?? "No response.";
        _updateMessageStatus(aiMsgId, GenStatus.completed, resultText: answer);
      } else {
        throw Exception("API Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, resultText: "Analysis failed: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  // 4. SKY CODER
  Future<void> _processSkyCoder(String prompt) async {
    final aiMsgId = _addPlaceholder();
    try {
      final url = Uri.parse("https://coder-bd.vercel.app/api");
      final response = await http.post(
         url,
         headers: {"Content-Type": "application/json"},
         body: jsonEncode({"q": prompt}),
      ).timeout(const Duration(minutes: 5)); // Long timeout

      if (_stopRequested) throw Exception("Stopped");
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Try various response keys in case API changed
        final answer = data["result"] ?? data["results"]?["answer"] ?? response.body; 
        _updateMessageStatus(aiMsgId, GenStatus.completed, resultText: answer);
      } else {
        throw Exception("Coder API Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, resultText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  // Helper: Poll
  Future<void> _pollForImage(String msgId, String generationId) async {
    int attempts = 0;
    while (attempts < 30) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped, resultText: "Stopped.");
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
      } catch (_) {}
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, resultText: "Timeout.");
  }

  String _addPlaceholder({bool isImageGen = false}) {
    final id = "ai_${DateTime.now().millisecondsSinceEpoch}";
    setState(() {
      _currentSession.messages.add(ChatMessage(
        id: id,
        text: isImageGen ? "Generating image..." : "Thinking...",
        type: MessageType.ai,
        status: GenStatus.generating,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    });
    _scrollToBottom();
    return id;
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? resultText}) {
    if (!mounted) return;
    final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;

    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        _sessions[sIndex].messages[mIndex] = ChatMessage(
          id: msgId,
          text: resultText ?? _sessions[sIndex].messages[mIndex].text,
          type: MessageType.ai,
          imageUrl: imageUrl,
          status: status,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isAnimated: status == GenStatus.completed && imageUrl == null, // Enable typing animation
        );
      });
      _saveData();
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  // --- DOWNLOAD ---

  Future<void> _downloadImage(String url) async {
    if (Platform.isAndroid) {
       await Permission.storage.request();
    }

    try {
      final dir = Directory('/storage/emulated/0/SkyGen');
      if (!await dir.exists()) await dir.create(recursive: true);

      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.png";
      final file = File("${dir.path}/$fileName");
      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);

      _showToast("Saved to SkyGen folder");
    } catch (e) {
      // Fallback
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File("${dir.path}/SkyGen_${DateTime.now().millisecondsSinceEpoch}.png");
        final response = await http.get(Uri.parse(url));
        await file.writeAsBytes(response.bodyBytes);
        _showToast("Saved to Documents");
      } catch (x) {
        _showToast("Save failed", isError: true);
      }
    }
  }

  // --- CUSTOM TOAST ---

  void _showToast(String message, {bool isError = false}) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 60,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isError ? Colors.redAccent : const Color(0xFF333333),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Row(
              children: [
                Icon(isError ? Icons.error_outline : Icons.check_circle, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 3), () => overlayEntry.remove());
  }

  // --- UI BUILD ---

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
          child: Text("SkyGen", style: TextStyle(color: Colors.black87)),
        ),
        centerTitle: true,
        actions: [
          IconButton(
             icon: const Icon(Icons.more_vert, color: Colors.black87),
             onPressed: () => _showMenuDialog(),
          ),
          const SizedBox(width: 8),
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
                        onToast: _showToast,
                      );
                    },
                  ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  // --- REDESIGNED DRAWER ---

  Widget _buildDrawer() {
    // Collect all images
    List<String> myStuffImages = [];
    for (var s in _sessions) {
      for (var m in s.messages) {
        if (m.imageUrl != null) myStuffImages.add(m.imageUrl!);
      }
    }

    return Drawer(
      backgroundColor: Colors.white,
      child: Column(
        children: [
          // Expanding Search
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.fromLTRB(16, 50, 16, 16),
            height: _isSearching ? MediaQuery.of(context).size.height : 120,
            color: Colors.white,
            child: Column(
              children: [
                Row(
                  children: [
                    if (_isSearching)
                      IconButton(icon: Icon(Icons.arrow_back), onPressed: () => setState(() => _isSearching = false)),
                    Expanded(
                      child: Container(
                        height: 45,
                        decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(24)),
                        child: TextField(
                          controller: _searchController,
                          onTap: () => setState(() => _isSearching = true),
                          onChanged: (val) => setState(() {}),
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search, color: Colors.grey),
                            hintText: "Search chats...",
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.only(top: 10),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.black87),
                      onPressed: () {
                         setState(() => _isSearching = false);
                         Navigator.pop(context);
                         _createNewSession();
                      },
                    )
                  ],
                ),
                if (_isSearching) ...[
                   const SizedBox(height: 20),
                   Expanded(
                     child: ListView(
                       children: _sessions.where((s) => s.title.toLowerCase().contains(_searchController.text.toLowerCase())).map((s) => 
                         ListTile(
                           title: Text(s.title),
                           onTap: () {
                             setState(() => _isSearching = false);
                             _switchSession(s.id);
                           },
                         )
                       ).toList(),
                     ),
                   )
                ]
              ],
            ),
          ),
          
          if (!_isSearching && myStuffImages.isNotEmpty) ...[
             _buildMyStuffSection(myStuffImages),
             const Divider(height: 1),
          ],
          
          if (!_isSearching)
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final session = _sessions[index];
                final isActive = session.id == _currentSessionId;
                return ListTile(
                  tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                  leading: Icon(
                    session.isPinned ? Icons.push_pin : Icons.chat_bubble_outline_rounded,
                    color: session.isPinned ? const Color(0xFF007AFF) : Colors.black54,
                    size: 20
                  ),
                  title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                  onTap: () => _switchSession(session.id),
                  onLongPress: () => _showSessionOptions(session),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyStuffSection(List<String> images) {
    final displayImages = images.take(3).toList();
    return Column(
      children: [
        ListTile(
          title: const Text("My Stuff", style: TextStyle(fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(images: images, onDownload: _downloadImage))),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: displayImages.map((url) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, width: 70, height: 70, fit: BoxFit.cover),
            ),
          )).toList(),
        )
      ],
    );
  }

  void _showSessionOptions(ChatSession session) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (context) => Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.edit), title: const Text("Rename"),
            onTap: () {
              Navigator.pop(context);
              _renameSession(session);
            }
          ),
          ListTile(
            leading: const Icon(Icons.push_pin), title: Text(session.isPinned ? "Unpin" : "Pin"),
            onTap: () {
              setState(() {
                session.isPinned = !session.isPinned;
                _sortSessions();
              });
              _saveData();
              Navigator.pop(context);
            }
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red), title: const Text("Delete", style: TextStyle(color: Colors.red)),
            onTap: () {
              setState(() {
                _sessions.removeWhere((s) => s.id == session.id);
                if (_sessions.isEmpty) _createNewSession();
                else if (_currentSessionId == session.id) _currentSessionId = _sessions.first.id;
              });
              _saveData();
              Navigator.pop(context);
            }
          ),
        ],
      ),
    );
  }

  void _renameSession(ChatSession session) {
    final c = TextEditingController(text: session.title);
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Rename Chat"),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        TextButton(onPressed: () {
          setState(() => session.title = c.text);
          _saveData();
          Navigator.pop(context);
        }, child: const Text("Save")),
      ],
    ));
  }

  // --- THREE DOT MENU (Bottom Sheet Style) ---

  void _showMenuDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        height: 180,
        child: Column(
          children: [
             Row(
               children: [
                 const Icon(Icons.search, color: Colors.grey),
                 const SizedBox(width: 10),
                 Expanded(
                   child: Container(
                     padding: const EdgeInsets.symmetric(horizontal: 10),
                     decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(20)),
                     child: TextField(
                       onTap: () {
                         Navigator.pop(context);
                         _scaffoldKey.currentState?.openDrawer();
                         setState(() => _isSearching = true);
                       },
                       decoration: const InputDecoration(border: InputBorder.none, hintText: "Search chats..."),
                       readOnly: true,
                     ),
                   ),
                 ),
                 const SizedBox(width: 10),
                 IconButton(
                   icon: const Icon(Icons.add_circle_outline, color: Colors.black87),
                   onPressed: () {
                     Navigator.pop(context);
                     _createNewSession();
                   },
                 )
               ],
             )
          ],
        ),
      ),
    );
  }

  // --- INPUT AREA ---

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
                  decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(24)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (_showPlusIcon)
                        IconButton(icon: const Icon(Icons.add, color: Colors.grey), onPressed: _pickImage),
                      Expanded(
                        child: TextField(
                          controller: _promptController,
                          enabled: !_isGenerating,
                          maxLines: 4, minLines: 1,
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
                  width: 50, height: 50,
                  decoration: BoxDecoration(
                    color: (_promptController.text.isEmpty) && !_isGenerating ? Colors.grey : (_isGenerating ? Colors.redAccent : Colors.black),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded, color: Colors.white, size: 26),
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
// SUB-PAGES & WIDGETS
// ---------------------------------------------------------------------------

class MyStuffPage extends StatelessWidget {
  final List<String> images;
  final Function(String) onDownload;

  const MyStuffPage({super.key, required this.images, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Stuff")),
      body: GridView.builder(
        padding: const EdgeInsets.all(10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10
        ),
        itemCount: images.length,
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () => onDownload(images[index]),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(images[index], fit: BoxFit.cover),
            ),
          );
        },
      ),
    );
  }
}

class ChatBubble extends StatefulWidget {
  final ChatMessage message;
  final Function(String) onDownload;
  final Function(String, {bool isError}) onToast;

  const ChatBubble({super.key, required this.message, required this.onDownload, required this.onToast});

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  String _visibleText = "";
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    if (widget.message.isAnimated && widget.message.type == MessageType.ai && widget.message.imageUrl == null) {
      _startTyping();
    } else {
      _visibleText = widget.message.text;
    }
  }

  void _startTyping() {
    int index = 0;
    _typingTimer = Timer.periodic(const Duration(milliseconds: 15), (timer) {
      if (index < widget.message.text.length) {
        if (mounted) setState(() => _visibleText += widget.message.text[index]);
        index++;
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.type == MessageType.user;
    final isOffline = widget.message.type == MessageType.offline;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: isOffline 
        ? Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red[50], borderRadius: BorderRadius.circular(12)),
              child: Text(widget.message.text, style: const TextStyle(color: Colors.red)),
            ),
          )
        : Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser) ...[
                const CircleAvatar(
                  radius: 16,
                  backgroundImage: AssetImage('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png'),
                  backgroundColor: Colors.transparent,
                  child: null,
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
      decoration: BoxDecoration(color: const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (widget.message.attachedImageUrl != null)
            Padding(
               padding: const EdgeInsets.only(bottom: 8),
               child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network(widget.message.attachedImageUrl!, width: 150, fit: BoxFit.cover)),
            ),
          Text(widget.message.text, style: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.4)),
        ],
      ),
    );
  }

  Widget _buildAIMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.message.status == GenStatus.completed && widget.message.imageUrl != null)
          _buildImagePreview(context, widget.message.imageUrl!)
        else if (widget.message.status == GenStatus.completed)
           Container(
             constraints: const BoxConstraints(maxWidth: 320),
             child: Markdown(
                data: _visibleText,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 16, color: Colors.black87),
                  code: const TextStyle(fontFamily: 'monospace', backgroundColor: Color(0xFFEEEEEE)),
                  codeblockDecoration: BoxDecoration(color: const Color(0xFF282c34), borderRadius: BorderRadius.circular(8)),
                ),
                builders: {
                  'code': CodeBlockBuilder(widget.onToast),
                },
             ),
           )
        else if (widget.message.status == GenStatus.generating || widget.message.status == GenStatus.waiting)
          _buildGeneratingState()
        else if (widget.message.status == GenStatus.error || widget.message.status == GenStatus.stopped)
          _buildErrorState(),
      ],
    );
  }

  Widget _buildImagePreview(BuildContext context, String url) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Image.network(url, fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) => progress == null ? child : const SizedBox(height: 300, width: 300, child: Center(child: CircularProgressIndicator())),
            ),
            Positioned(
              bottom: 10, right: 10,
              child: GestureDetector(
                onTap: () => widget.onDownload(url),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), shape: BoxShape.circle),
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue)),
          const SizedBox(width: 10),
          const TypingIndicator(),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFFFF0F0), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFFCDCD))),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Text(widget.message.text, style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PROFESSIONAL CODE BLOCK
// ---------------------------------------------------------------------------

class CodeBlockBuilder extends MarkdownElementBuilder {
  final Function(String, {bool isError}) onToast;
  CodeBlockBuilder(this.onToast);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var language = "CODE";
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      language = lg.replaceFirst('language-', '').toUpperCase();
    }
    final text = element.textContent.trim();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF282c34), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF21252b),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(language, style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: text));
                    onToast("Code copied!");
                  },
                  child: Row(
                    children: const [
                      Icon(Icons.copy, size: 14, color: Colors.grey),
                      SizedBox(width: 4),
                      Text("Copy", style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                )
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              text,
              language: language.toLowerCase(),
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(16),
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UTILS
// ---------------------------------------------------------------------------

class WelcomePlaceholder extends StatelessWidget {
  const WelcomePlaceholder({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80, height: 80,
            decoration: const BoxDecoration(
              image: DecorationImage(image: AssetImage('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png'))
            ),
          ),
          const SizedBox(height: 24),
          const Text("What can I help you with?", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
  late AnimationController _c;
  @override
  void initState() { super.initState(); _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(); }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(3, (i) => AnimatedBuilder(
          animation: _c,
          builder: (ctx, child) => Opacity(opacity: (sin((_c.value * 2 * pi) + i) + 1) / 2 * 0.6 + 0.4, child: child),
          child: const CircleAvatar(radius: 3, backgroundColor: Colors.black87),
        )),
      ),
    );
  }
}
