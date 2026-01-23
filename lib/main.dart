import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart'; 
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shimmer/shimmer.dart';

// ---------------------------------------------------------------------------
// MAIN ENTRY POINT
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Navigation Bar Color Fix (White for Light Mode)
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white, // Matches app BG
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
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
enum GenStatus { waiting, generating, streaming, completed, error, stopped }

class ChatMessage {
  final String id;
  final String text; 
  String visibleText; 
  final MessageType type;
  String? imageUrl; 
  String? attachedImageUrl; 
  GenStatus status;
  final int timestamp;
  String? modelName; // Store model name for specific messages

  ChatMessage({
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.imageUrl,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
    this.modelName,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : "");

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'visibleText': visibleText,
    'type': type.index,
    'imageUrl': imageUrl,
    'attachedImageUrl': attachedImageUrl,
    'status': status.index,
    'timestamp': timestamp,
    'modelName': modelName,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    visibleText: map['visibleText'],
    type: MessageType.values[map['type']],
    imageUrl: map['imageUrl'],
    attachedImageUrl: map['attachedImageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
    modelName: map['modelName'],
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
// CHAT SCREEN (MAIN UI)
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Logic Variables
  List<ChatSession> _sessions = [];
  List<String> _myStuffImages = []; 
  
  // Handling Temporary New Session
  String _currentSessionId = "";
  bool _isTempSession = true; 
  
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;
  File? _storageFile;

  // --- NEW FEATURES VARIABLES ---
  String _selectedModel = "SkyGen"; 
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;
  bool _showPlusIcon = true;
  
  // Search Drawer
  bool _isSearchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

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
    _searchController.dispose();
    super.dispose();
  }

  void _handleInputListener() {
    final shouldHide = _promptController.text.isNotEmpty;
    if (_showPlusIcon == shouldHide) {
       setState(() {
         _showPlusIcon = !shouldHide;
       });
    }
  }

  // --- STORAGE & SESSION MANAGEMENT ---

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_v6.json'); // Version bump
      
      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        final List<dynamic> imgList = jsonData['myStuff'] ?? [];

        setState(() {
          _sessions = sessionList.map((e) => ChatSession.fromMap(e)).toList();
          _myStuffImages = imgList.cast<String>().toList();
          _sortSessions();
        });
      }
      _createTempSession();
    } catch (e) {
      debugPrint("Error loading history: $e");
      _createTempSession();
    }
  }

  Future<void> _saveData() async {
    if (_storageFile == null) return;
    try {
      final Map<String, dynamic> data = {
        'sessions': _sessions.map((e) => e.toMap()).toList(),
        'myStuff': _myStuffImages,
      };
      await _storageFile!.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("Error saving data: $e");
    }
  }

  void _sortSessions() {
    _sessions.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  void _createTempSession() {
    final tempId = "temp_${DateTime.now().millisecondsSinceEpoch}";
    setState(() {
      _currentSessionId = tempId;
      _isTempSession = true;
      _isGenerating = false;
      _promptController.clear();
      _clearAttachment();
    });
  }

  void _startNewChatAction() {
    if (_isTempSession && _currentSession.messages.isEmpty) return;
    _createTempSession();
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
      _isTempSession = false;
      _isGenerating = false; 
      _clearAttachment();
    });
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  // --- HISTORY MANAGEMENT ---

  void _pinSession(String id) {
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index != -1) {
      setState(() {
        _sessions[index].isPinned = !_sessions[index].isPinned;
        _sortSessions();
      });
      _saveData();
    }
    Navigator.pop(context); 
  }

  void _deleteSession(String id) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete Chat?"),
      content: const Text("This action cannot be undone."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          // Find index for animation logic if needed, but simple removal here
          setState(() {
            _sessions.removeWhere((s) => s.id == id);
            if (_currentSessionId == id) _createTempSession();
          });
          _saveData();
          Navigator.pop(ctx); 
          Navigator.pop(context); 
          _showToast("Chat deleted", isError: false);
        }, child: const Text("Delete", style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  void _renameSession(String id) {
    final s = _sessions.firstWhere((s) => s.id == id);
    final controller = TextEditingController(text: s.title);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Rename Chat"),
      content: TextField(controller: controller, decoration: const InputDecoration(hintText: "Enter new name")),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          setState(() => s.title = controller.text.trim());
          _saveData();
          Navigator.pop(ctx);
          Navigator.pop(context);
        }, child: const Text("Save")),
      ],
    ));
  }

  ChatSession get _currentSession {
    if (_isTempSession) {
      return _sessions.firstWhere((s) => s.id == _currentSessionId, 
        orElse: () => ChatSession(id: _currentSessionId, title: "New Chat", createdAt: DateTime.now().millisecondsSinceEpoch, messages: [])
      );
    }
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

  // --- MODELS & ATTACHMENT ---

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
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              _buildModelTile("SkyGen", "Advanced Text AI Chat", Icons.chat_bubble_outline),
              const SizedBox(height: 10),
              _buildModelTile("Sky-Img", "AI Image Generation", Icons.image_outlined),
              const SizedBox(height: 10),
              _buildModelTile("Img Describer", "Image Understanding", Icons.remove_red_eye_outlined),
              const SizedBox(height: 10),
              _buildModelTile("Sky Coder", "Programming Model", Icons.code_rounded),
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

  Future<void> _openCustomGallery() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
        _showToast("Gallery permission denied", isError: true);
        await openAppSettings();
        return;
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => const CustomGalleryPicker(),
    ).then((file) {
      if (file != null && file is File) {
        setState(() {
          _pickedImage = file;
          _isUploadingImage = true;
        });
        _uploadToImgBB(file);
      }
    });
  }

  Future<void> _uploadToImgBB(File imageFile) async {
    try {
      if (!(await _checkInternet())) {
        _showToast("No Internet Connection", isError: true);
        _clearAttachment();
        return;
      }
      
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
        _pickedImage = null; 
        _isUploadingImage = false;
      });
      _showToast("Upload failed: $e", isError: true);
    }
  }

  void _clearAttachment() {
    setState(() {
      _pickedImage = null;
      _uploadedImgBBUrl = null;
      _isUploadingImage = false;
    });
  }

  Future<bool> _checkInternet() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // --- CORE LOGIC ---

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    
    if (prompt.isEmpty) {
      if (_pickedImage != null) _showToast("Text description is mandatory with image.", isError: true);
      return;
    }

    if (!(await _checkInternet())) {
      setState(() {
         if (_isTempSession) {
             final newSess = ChatSession(id: _currentSessionId, title: "Offline", createdAt: DateTime.now().millisecondsSinceEpoch, messages: []);
             _sessions.insert(0, newSess);
             _isTempSession = false;
         }
         final sess = _sessions.firstWhere((s) => s.id == _currentSessionId);
         sess.messages.add(ChatMessage(
           id: DateTime.now().millisecondsSinceEpoch.toString(),
           text: prompt,
           type: MessageType.user,
           attachedImageUrl: _uploadedImgBBUrl,
           timestamp: DateTime.now().millisecondsSinceEpoch,
         ));
         sess.messages.add(ChatMessage(
           id: "offline_${DateTime.now().millisecondsSinceEpoch}",
           text: "Internet connection unavailable. Please turn on internet and try again.",
           type: MessageType.ai,
           status: GenStatus.error,
           timestamp: DateTime.now().millisecondsSinceEpoch,
         ));
         _promptController.clear();
         _clearAttachment();
      });
      _scrollToBottom();
      return;
    }

    if (_isTempSession) {
      final newTitle = prompt.length > 25 ? "${prompt.substring(0, 25)}..." : prompt;
      final newSession = ChatSession(
        id: _currentSessionId, 
        title: newTitle, 
        createdAt: DateTime.now().millisecondsSinceEpoch, 
        messages: []
      );
      setState(() {
        _sessions.insert(0, newSession);
        _isTempSession = false;
        _sortSessions();
      });
    }

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      attachedImageUrl: _uploadedImgBBUrl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: _selectedModel,
    );

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);

    setState(() {
      currentSess.messages.add(userMsg);
      _promptController.clear();
      _isGenerating = true;
      _stopRequested = false;
    });
    
    _scrollToBottom();
    _saveData();

    String? attachment = _uploadedImgBBUrl;
    _clearAttachment(); 

    if (_selectedModel == "Sky-Img") {
      await _processImageGeneration(prompt, attachment);
    } else if (_selectedModel == "Img Describer" && attachment != null) {
      await _processDescriberFlow(prompt, attachment);
    } else if (_selectedModel == "Sky Coder") {
      await _processSkyCoder(prompt);
    } else {
      if (attachment != null) {
        await _processDescriberFlow(prompt, attachment); 
      } else {
        await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
      }
    }
  }

  // --- TYPING ANIMATION (Double Speed) ---

  Future<void> _streamResponse(String msgId, String fullText) async {
    if (!mounted) return;
    _updateMessageStatus(msgId, GenStatus.streaming, errorText: fullText); 
    
    int currentIndex = 0;
    const chunkSize = 10; // Increased speed (Double of 5)
    
    while (currentIndex < fullText.length) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped);
        return;
      }
      
      await Future.delayed(const Duration(milliseconds: 10)); // Faster tick
      
      currentIndex = min(currentIndex + chunkSize, fullText.length);
      final currentVisible = fullText.substring(0, currentIndex);
      
      final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
      if (sIndex != -1) {
        final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
        if (mIndex != -1) {
          setState(() {
            _sessions[sIndex].messages[mIndex].visibleText = currentVisible;
          });
        }
      }
    }
    _updateMessageStatus(msgId, GenStatus.completed, errorText: fullText);
    _saveData();
  }

  // --- API HANDLERS ---

  Future<void> _processTextAI(String prompt, String apiUrl, {Map<String, dynamic>? extraBody}) async {
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Thinking...", // Initial placeholder
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.waiting, 
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: _selectedModel,
    );

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(aiMsg));
    _scrollToBottom();

    try {
      final Map<String, dynamic> body = {"q": prompt};
      if (extraBody != null) body.addAll(extraBody);

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      if (_stopRequested) throw Exception("Stopped");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"] ?? "No response.";
        await _streamResponse(aiMsgId, answer);
      } else {
        throw Exception("API Error ${response.statusCode}");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  Future<void> _processSkyCoder(String prompt) async {
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Creating Codes...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Sky Coder",
    );

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(aiMsg));
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse("https://coder-bd.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"] ?? "No code generated.";
        await _streamResponse(aiMsgId, answer);
      } else {
        throw Exception("Coder API Failed");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  Future<void> _processDescriberFlow(String prompt, String imgUrl) async {
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Analyzing image...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: _selectedModel,
    )));
    _scrollToBottom();

    try {
      final descRes = await http.get(Uri.parse("https://gen-z-describer.vercel.app/api?url=$imgUrl"));
      if (descRes.statusCode != 200) throw Exception("Describer failed");
      
      final descData = jsonDecode(descRes.body);
      final description = descData["results"]["description"];

      final skyGenBody = {
        "q": prompt,
        "image": {
          "url": imgUrl,
          "description": description
        }
      };

      final response = await http.post(
        Uri.parse("https://ai-hyper.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(skyGenBody),
      );

       if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data["results"]["answer"];
        await _streamResponse(aiMsgId, answer);
      } else {
        throw Exception("SkyGen Refused Context");
      }

    } catch (e) {
       _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
       setState(() => _isGenerating = false);
       _saveData();
    }
  }

  Future<void> _processImageGeneration(String prompt, String? attachmentUrl) async {
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    
    // Immediately show placeholder for image generation
    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Generating Image...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.generating, // Special status for shimmer
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Sky-Img",
    )));
    _scrollToBottom();

    try {
      Uri genUrl;
      Map<String, dynamic> body;

      if (attachmentUrl != null) {
        genUrl = Uri.parse("https://gen-z-image.vercel.app/image/gen");
        body = {"q": prompt, "url": attachmentUrl};
      } else {
        genUrl = Uri.parse("https://gen-z-image.vercel.app/gen");
        body = {"q": prompt};
      }

      final response = await http.post(
        genUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 20));

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
    while (attempts < 30) {
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
            String finalUrl = urls.first;
            setState(() {
              _myStuffImages.insert(0, finalUrl);
            });
            // Update to completed with Image URL. Also change text to "Image Generated"
            _updateMessageStatus(msgId, GenStatus.completed, imageUrl: finalUrl, errorText: "Image Generated");
            return;
          }
        }
      } catch (_) {}
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Timeout.");
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? errorText}) {
    if (!mounted) return;
    
    int sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;

    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        var old = _sessions[sIndex].messages[mIndex];
        _sessions[sIndex].messages[mIndex] = ChatMessage(
          id: msgId,
          text: errorText ?? old.text,
          visibleText: status == GenStatus.completed ? (errorText ?? old.text) : old.visibleText,
          type: MessageType.ai,
          imageUrl: imageUrl,
          status: status,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          modelName: old.modelName,
        );
      });
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  // --- DOWNLOAD & TOAST ---

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(isError ? Icons.error_outline : Icons.check_circle_outline, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
      backgroundColor: isError ? Colors.redAccent : const Color(0xFF333333),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16), 
    ));
  }
  
  // Go to Chat Helper
  void _goToChatFromImage(String imageUrl) {
    for (var session in _sessions) {
      for (var msg in session.messages) {
        if (msg.imageUrl == imageUrl) {
          setState(() {
            _currentSessionId = session.id;
            _isTempSession = false;
            _isGenerating = false;
            _clearAttachment();
          });
          Navigator.pop(context); // Close full screen
          Navigator.of(context).popUntil((route) => route.isFirst); // Go to home
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
          return;
        }
      }
    }
    _showToast("Chat not found", isError: true);
  }

  // --- UI CONSTRUCTION ---

  @override
  Widget build(BuildContext context) {
    final currentMessages = _currentSession.messages;

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
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.black54, size: 20),
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
            onPressed: _startNewChatAction,
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
                        onToast: _showToast,
                        onGoToChat: _goToChatFromImage,
                      );
                    },
                  ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  // --- DRAWER ---
  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      width: _isSearchExpanded ? MediaQuery.of(context).size.width : 304,
      child: SafeArea(
        child: Column(
          children: [
            // Search Bar Area with Animation
            Padding(
              padding: const EdgeInsets.all(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: double.infinity,
                height: 50,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(_isSearchExpanded ? Icons.arrow_back : Icons.search),
                              color: Colors.grey,
                              onPressed: () {
                                if (_isSearchExpanded) {
                                  setState(() {
                                    _isSearchExpanded = false;
                                    _searchQuery = "";
                                    _searchController.clear();
                                  });
                                }
                              },
                            ),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                onTap: () => setState(() => _isSearchExpanded = true),
                                onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
                                decoration: const InputDecoration(
                                  hintText: "Search chats...",
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.only(bottom: 4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_isSearchExpanded) ...[
                      const SizedBox(width: 10),
                      IconButton(
                        onPressed: _startNewChatAction,
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
                          child: const Icon(Icons.add, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            // My Stuff Section
            if (!_isSearchExpanded && _myStuffImages.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context); // Close Drawer
                    Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(
                      images: _myStuffImages, 
                      onGoToChat: _goToChatFromImage,
                      onToast: _showToast,
                    )));
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("My Stuff", style: TextStyle(fontWeight: FontWeight.bold)),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 80,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: min(_myStuffImages.length, 3),
                  separatorBuilder: (_,__) => const SizedBox(width: 10),
                  itemBuilder: (ctx, i) {
                    return GestureDetector(
                      onTap: () {
                         Navigator.pop(context); // Close Drawer
                         Navigator.push(context, MaterialPageRoute(
                          builder: (_) => FullScreenImageViewer(
                            imageUrl: _myStuffImages[i], 
                            onToast: _showToast,
                            onGoToChat: _goToChatFromImage,
                          )
                        ));
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: _myStuffImages[i],
                          width: 80, height: 80, fit: BoxFit.cover,
                          placeholder: (context, url) => Container(color: Colors.grey[200]),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 30),
            ],

            // Chat List
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  if (session.messages.isEmpty) return const SizedBox.shrink();

                  if (_searchQuery.isNotEmpty && !session.title.toLowerCase().contains(_searchQuery)) {
                    return const SizedBox.shrink();
                  }

                  final isActive = session.id == _currentSessionId && !_isTempSession;
                  return ListTile(
                    tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                    leading: Icon(
                      session.isPinned ? Icons.push_pin : Icons.chat_bubble_outline_rounded,
                      color: session.isPinned ? const Color(0xFF007AFF) : Colors.black54,
                      size: 20,
                    ),
                    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                    onTap: () => _switchSession(session.id),
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.white,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                        builder: (ctx) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Drag Handle
                            Center(
                              child: Container(
                                width: 40, height: 4,
                                margin: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                              ),
                            ),
                            ListTile(
                              leading: const Icon(Icons.edit),
                              title: const Text("Rename"),
                              onTap: () => _renameSession(session.id),
                            ),
                            ListTile(
                              leading: const Icon(Icons.push_pin),
                              title: Text(session.isPinned ? "Unpin" : "Pin"),
                              onTap: () => _pinSession(session.id),
                            ),
                            ListTile(
                              leading: const Icon(Icons.delete, color: Colors.red),
                              title: const Text("Delete", style: TextStyle(color: Colors.red)),
                              onTap: () => _deleteSession(session.id),
                            ),
                            const SizedBox(height: 20),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- INPUT AREA (TELEGRAM STYLE) ---

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
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
          
          // Telegram Style Input
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _promptController,
                    enabled: !_isGenerating,
                    maxLines: 4,
                    minLines: 1,
                    style: const TextStyle(color: Colors.black87, fontSize: 16),
                    decoration: const InputDecoration(
                      hintText: "Message",
                      hintStyle: TextStyle(color: Colors.grey),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                
                // ATTACH BUTTON (Only shows if empty)
                if (_showPlusIcon)
                   IconButton(
                     icon: const Icon(Icons.attach_file, color: Colors.grey),
                     onPressed: _openCustomGallery,
                   ),

                // SEND BUTTON (Black when empty, Blue/Black when text)
                // Using Telegram style logic
                AnimatedContainer(
                   duration: const Duration(milliseconds: 200),
                   margin: const EdgeInsets.only(bottom: 6, right: 6),
                   decoration: BoxDecoration(
                     color: (_promptController.text.isNotEmpty || _pickedImage != null) ? const Color(0xFF007AFF) : (_isGenerating ? Colors.black : Colors.transparent),
                     shape: BoxShape.circle
                   ),
                   child: IconButton(
                     icon: Icon(
                       _isGenerating ? Icons.stop_rounded : Icons.arrow_upward,
                       color: (_promptController.text.isNotEmpty || _pickedImage != null || _isGenerating) ? Colors.white : Colors.grey,
                       size: 24,
                     ),
                     onPressed: _isGenerating ? () => setState(() => _stopRequested = true) : _handleSubmitted,
                     padding: const EdgeInsets.all(8),
                     constraints: const BoxConstraints(),
                   ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WIDGETS & HELPERS
// ---------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String, {bool isError}) onToast;
  final Function(String) onGoToChat;

  const ChatBubble({
    super.key, 
    required this.message, 
    required this.onToast,
    required this.onGoToChat,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.type == MessageType.user;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Content
          Flexible(
            child: isUser 
              ? _buildUserMessage(context) 
              : _buildAIMessage(context),
          ),
        ],
      ),
    );
  }

  Widget _buildUserMessage(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
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
               child: GestureDetector(
                 onTap: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => FullScreenImageViewer(
                      imageUrl: message.attachedImageUrl!, 
                      onToast: onToast,
                      onGoToChat: onGoToChat,
                    )
                  )),
                 child: ClipRRect(
                   borderRadius: BorderRadius.circular(10),
                   child: CachedNetworkImage(
                     imageUrl: message.attachedImageUrl!, 
                     width: 200, fit: BoxFit.cover,
                     placeholder: (c,u) => const CircularProgressIndicator(),
                   ),
                 ),
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
    bool isWaiting = message.status == GenStatus.waiting || message.status == GenStatus.generating;
    bool isStreaming = message.status == GenStatus.streaming;
    
    // Status Text
    String statusText = "Thinking...";
    if (message.text.contains("Generating Image")) statusText = "Generating Image...";
    else if (message.text.contains("Analyzing")) statusText = "Analyzing Image...";
    else if (message.text.contains("Codes")) statusText = "Creating Codes...";

    // Determine if we show rotating loader or static icon
    bool showLoader = isWaiting || isStreaming;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. HEADER (Custom Icon + Status + Dots)
        Row(
           children: [
             // Custom Icon with Loader
             Stack(
               alignment: Alignment.center,
               children: [
                 if (showLoader)
                   const SizedBox(
                     width: 32, height: 32,
                     child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87),
                   ),
                 ClipOval(
                   child: CachedNetworkImage(
                     imageUrl: "https://iili.io/f4Xfgfa.jpg", // Custom Icon
                     width: 24, height: 24, fit: BoxFit.cover,
                     placeholder: (c,u) => Container(color: Colors.grey[300]),
                     errorWidget: (c,u,e) => const Icon(Icons.auto_awesome),
                   ),
                 ),
               ],
             ),
             const SizedBox(width: 10),
             
             // Dots & Status Text
             if (isWaiting) ...[
                const TypingIndicator(),
                const SizedBox(width: 8),
                Text(statusText, style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
             ] else if (message.status == GenStatus.completed && message.imageUrl != null) ...[
                // Image Generated Text
                const Text("Image Generated", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
             ],
           ],
        ),

        const SizedBox(height: 8), // Gap before content

        // 2. CONTENT (Text / Image / Error) - Starts on NEXT LINE
        
        // Image Result (Or Placeholder if generating)
        if (message.status == GenStatus.generating && message.imageUrl == null)
          _buildShimmerPlaceholder()
        else if (message.imageUrl != null)
          _buildImagePreview(context, message.imageUrl!),
          
        // Text Result
        if (message.visibleText.isNotEmpty && message.imageUrl == null)
           Container(
             constraints: const BoxConstraints(maxWidth: 320),
             padding: const EdgeInsets.only(left: 4), 
             child: MarkdownBody(
               data: message.visibleText,
               selectable: true,
               builders: {
                 'code': CodeBlockBuilder(onToast),
               },
               styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                 p: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.5),
                 code: const TextStyle(fontFamily: 'monospace', backgroundColor: Color(0xFFF0F0F0), color: Colors.redAccent), // Inline code style
                 codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF282C34),
                    borderRadius: BorderRadius.circular(8),
                 ),
               ),
             ),
           ),
           
        // Error
        if (message.status == GenStatus.error)
          _buildErrorState(),
      ],
    );
  }

  Widget _buildShimmerPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Container(
        width: 300, height: 300,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16)
        ),
      ),
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
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
               builder: (_) => FullScreenImageViewer(
                 imageUrl: url, 
                 onToast: onToast,
                 onGoToChat: onGoToChat,
               )
             )),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (ctx, url) => _buildShimmerPlaceholder(),
                errorWidget: (context, url, error) => const SizedBox(height: 300, width: 300, child: Icon(Icons.error)),
              ),
            ),
          ),
          // Download Button Top Right
          Positioned(
            top: 10,
            right: 10,
            child: DownloadButton(url: url, onToast: onToast),
          ),
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

// ---------------------------------------------------------------------------
// DOWNLOAD BUTTON WITH LOADER
// ---------------------------------------------------------------------------

class DownloadButton extends StatefulWidget {
  final String url;
  final Function(String, {bool isError}) onToast;
  const DownloadButton({super.key, required this.url, required this.onToast});

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _isLoading = false;

  Future<void> _download() async {
    setState(() => _isLoading = true);
    if (Platform.isAndroid) await Permission.storage.request();

    try {
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

      final response = await http.get(Uri.parse(widget.url));
      await file.writeAsBytes(response.bodyBytes);

      widget.onToast("Download Successful");
    } catch (e) {
      widget.onToast("Save failed", isError: true);
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _isLoading ? null : _download,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          shape: BoxShape.circle,
        ),
        child: _isLoading 
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : const Icon(Icons.download_rounded, color: Colors.white, size: 20),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FULL SCREEN IMAGE VIEWER
// ---------------------------------------------------------------------------

class FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;
  final Function(String, {bool isError}) onToast;
  final Function(String) onGoToChat;

  const FullScreenImageViewer({
    super.key, 
    required this.imageUrl, 
    required this.onToast,
    required this.onGoToChat
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Zoomable Image
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                placeholder: (c,u) => const CircularProgressIndicator(color: Colors.white),
              ),
            ),
          ),
          
          // Top Buttons
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 20,
            child: Row(
              children: [
                _buildCircleButton(Icons.chat_bubble_outline, () => onGoToChat(imageUrl)),
                const SizedBox(width: 15),
                // Custom Download with Loader logic is needed, but we can reuse DownloadButton
                DownloadButton(url: imageUrl, onToast: onToast), // Reusing widget
                const SizedBox(width: 15),
                _buildCircleButton(Icons.close, () => Navigator.pop(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24)
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MARKDOWN CODE BLOCK BUILDER
// ---------------------------------------------------------------------------

class CodeBlockBuilder extends MarkdownElementBuilder {
  final Function(String, {bool isError}) onToast;
  CodeBlockBuilder(this.onToast);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var language = '';
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      language = lg.substring(9);
    }
    return CodeBlockWidget(code: element.textContent, language: language, onToast: onToast);
  }
}

class CodeBlockWidget extends StatelessWidget {
  final String code;
  final String language;
  final Function(String, {bool isError}) onToast;

  const CodeBlockWidget({super.key, required this.code, required this.language, required this.onToast});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF282C34),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF21252B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(language.isEmpty ? 'CODE' : language.toUpperCase(),
                    style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                GestureDetector(
                  onTap: () {
                     Clipboard.setData(ClipboardData(text: code));
                     onToast("Copied to clipboard");
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.copy, color: Colors.grey, size: 14),
                      SizedBox(width: 4),
                      Text("Copy", style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              code,
              language: language.isEmpty ? 'plaintext' : language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(12),
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CUSTOM GALLERY PICKER
// ---------------------------------------------------------------------------

class CustomGalleryPicker extends StatefulWidget {
  const CustomGalleryPicker({super.key});

  @override
  State<CustomGalleryPicker> createState() => _CustomGalleryPickerState();
}

class _CustomGalleryPickerState extends State<CustomGalleryPicker> {
  List<AssetEntity> _images = [];

  @override
  void initState() {
    super.initState();
    _fetchImages();
  }

  Future<void> _fetchImages() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (albums.isNotEmpty) {
      final recent = await albums.first.getAssetListRange(start: 0, end: 100); 
      setState(() {
        _images = recent;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top Header with Drag Handle & Close
        Container(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 24), // Balance
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close, color: Colors.black54),
              ),
            ],
          ),
        ),
        // Grid
        Expanded(
          child: _images.isEmpty 
            ? const Center(child: CircularProgressIndicator())
            : GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: _images.length,
                itemBuilder: (_, index) {
                  return GestureDetector(
                    onTap: () async {
                       File? file = await _images[index].file;
                       if (mounted) Navigator.pop(context, file);
                    },
                    child: _MediaThumbnail(asset: _images[index]),
                  );
                },
              ),
        ),
      ],
    );
  }
}

class _MediaThumbnail extends StatelessWidget {
  final AssetEntity asset;
  const _MediaThumbnail({required this.asset});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done && snapshot.data != null) {
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
          );
        }
        return Container(color: Colors.grey[200]);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// MY STUFF PAGE
// ---------------------------------------------------------------------------

class MyStuffPage extends StatelessWidget {
  final List<String> images;
  final Function(String) onGoToChat;
  final Function(String, {bool isError}) onToast;

  const MyStuffPage({
    super.key, 
    required this.images,
    required this.onGoToChat,
    required this.onToast
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Stuff")),
      body: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, 
          crossAxisSpacing: 4, 
          mainAxisSpacing: 4
        ),
        itemCount: images.length,
        itemBuilder: (ctx, i) {
          return GestureDetector(
             onTap: () {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => FullScreenImageViewer(
                    imageUrl: images[i], 
                    onToast: onToast,
                    onGoToChat: onGoToChat,
                  )
                ));
             },
             child: ClipRRect(
               borderRadius: BorderRadius.circular(4),
               child: CachedNetworkImage(imageUrl: images[i], fit: BoxFit.cover),
             ),
          );
        },
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
          // CUSTOM ICON INSTEAD OF AUTO AWESOME
          ClipOval(
             child: CachedNetworkImage(
               imageUrl: "https://iili.io/f4Xfgfa.jpg", // Custom Icon
               width: 60, height: 60, fit: BoxFit.cover,
               placeholder: (c,u) => Container(color: Colors.grey[300], width: 60, height: 60),
               errorWidget: (c,u,e) => const Icon(Icons.auto_awesome, size: 60),
             ),
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
      width: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start, // Left aligned
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final double value = sin((_controller.value * 2 * pi) + (index * 1.0));
              return Opacity(
                opacity: (value + 1) / 2.0 * 0.6 + 0.4,
                child: Container(
                  margin: const EdgeInsets.only(right: 3),
                  width: 6, height: 6,
                  decoration: const BoxDecoration(color: Colors.grey, shape: BoxShape.circle),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
