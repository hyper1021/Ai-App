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
// Fixed Imports
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:markdown/markdown.dart' as md;

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
enum GenStatus { waiting, generating, streaming, completed, error, stopped }

class ChatMessage {
  final String id;
  final String text; // The full text (final)
  String visibleText; // For typing effect
  final MessageType type;
  String? imageUrl; 
  String? attachedImageUrl; 
  GenStatus status;
  final int timestamp;

  ChatMessage({
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.imageUrl,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
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
  List<String> _myStuffImages = []; // Stores URLs of generated images
  String _currentSessionId = "";
  
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;
  File? _storageFile;

  // --- NEW FEATURES VARIABLES ---
  String _selectedModel = "SkyGen"; 
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;
  bool _showPlusIcon = true; // Added missing variable
  
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
    // Hide plus icon if multiline
    final isMultiline = _promptController.text.contains('\n') || _promptController.text.length > 30;
    if (_showPlusIcon == isMultiline) {
       setState(() {
         _showPlusIcon = !isMultiline;
       });
    }
    setState(() {}); 
  }

  // --- STORAGE & SESSION MANAGEMENT ---

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_v4.json');
      
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

  // --- HISTORY MANAGEMENT ---

  void _pinSession(String id) {
    setState(() {
      final s = _sessions.firstWhere((s) => s.id == id);
      s.isPinned = !s.isPinned;
      _sortSessions();
    });
    _saveData();
    Navigator.pop(context); // Close bottom sheet
  }

  void _deleteSession(String id) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete Chat?"),
      content: const Text("This action cannot be undone."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          setState(() {
            _sessions.removeWhere((s) => s.id == id);
            if (_sessions.isEmpty) _createNewSession();
            else if (_currentSessionId == id) _currentSessionId = _sessions.first.id;
          });
          _saveData();
          Navigator.pop(ctx); // Close dialog
          Navigator.pop(context); // Close bottom sheet
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

  // --- CUSTOM IMAGE PICKER ---

  Future<void> _openCustomGallery() async {
    if (Platform.isAndroid) {
       await Permission.storage.request();
       await Permission.photos.request();
    }
    
    // Check permission
    final PermissionStatus ps = await Permission.photos.status;
    final PermissionStatus ss = await Permission.storage.status;
    
    // Simple permission logic for stability
    if (ps.isDenied && ss.isDenied) {
        await Permission.photos.request();
        await Permission.storage.request();
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
        _showToast("Image attached", isError: false);
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

  // --- CORE LOGIC: SEND MESSAGE ---

  Future<void> _handleSubmitted() async {
    final prompt = _promptController.text.trim();
    
    if (prompt.isEmpty) {
      if (_pickedImage != null) {
         _showToast("Text description is mandatory with image.", isError: true);
      }
      return;
    }

    if (!(await _checkInternet())) {
      // Offline handling
      setState(() {
         _currentSession.messages.add(ChatMessage(
           id: DateTime.now().millisecondsSinceEpoch.toString(),
           text: prompt,
           type: MessageType.user,
           attachedImageUrl: _uploadedImgBBUrl,
           timestamp: DateTime.now().millisecondsSinceEpoch,
         ));
         _currentSession.messages.add(ChatMessage(
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

    // Set Title if new
    final sessionIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sessionIndex != -1 && _sessions[sessionIndex].messages.isEmpty) {
      setState(() {
        _sessions[sessionIndex].title = prompt.length > 25 ? "${prompt.substring(0, 25)}..." : prompt;
      });
    }

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

    // Logic Switch
    String? attachment = _uploadedImgBBUrl;
    _clearAttachment(); // Clear UI immediately

    if (_selectedModel == "Sky-Img") {
      await _processImageGeneration(prompt, attachment);
    } else if (_selectedModel == "Img Describer" && attachment != null) {
      await _processDescriberFlow(prompt, attachment);
    } else if (_selectedModel == "Sky Coder") {
      await _processSkyCoder(prompt);
    } else {
      // SkyGen Default
      if (attachment != null) {
        // Fallback to describer flow if image attached in SkyGen
        await _processDescriberFlow(prompt, attachment); 
      } else {
        await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
      }
    }
  }

  // --- TYPING ANIMATION HELPER ---

  Future<void> _streamResponse(String msgId, String fullText) async {
    if (!mounted) return;
    
    // Set status to streaming
    _updateMessageStatus(msgId, GenStatus.streaming, errorText: fullText); // Store full text

    int currentIndex = 0;
    const chunkSize = 5; // Chars per tick
    
    // Initial partial
    while (currentIndex < fullText.length) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped);
        return;
      }
      
      await Future.delayed(const Duration(milliseconds: 20)); // Typing speed
      
      currentIndex = min(currentIndex + chunkSize, fullText.length);
      final currentVisible = fullText.substring(0, currentIndex);
      
      // Update specific message
      final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
      if (sIndex == -1) break;
      final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
      
      if (mIndex != -1) {
        setState(() {
          _sessions[sIndex].messages[mIndex].visibleText = currentVisible;
        });
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
      text: "",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.waiting, // Show loading circle initially
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() => _currentSession.messages.add(aiMsg));
    _scrollToBottom();

    try {
      // FIX: Typed as Map<String, dynamic>
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
    // 5 Minute timeout handling
    final aiMsgId = "ai_${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() => _currentSession.messages.add(aiMsg));
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
    setState(() => _currentSession.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Analyzing image...",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    )));
    _scrollToBottom();

    try {
      // 1. Get Description
      final descRes = await http.get(Uri.parse("https://gen-z-describer.vercel.app/api?url=$imgUrl"));
      if (descRes.statusCode != 200) throw Exception("Describer failed");
      
      final descData = jsonDecode(descRes.body);
      final description = descData["results"]["description"];

      // 2. Send to SkyGen
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
    setState(() => _currentSession.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Generating image...",
      type: MessageType.ai,
      status: GenStatus.generating,
      timestamp: DateTime.now().millisecondsSinceEpoch,
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
            // Add to My Stuff
            setState(() {
              _myStuffImages.insert(0, finalUrl);
            });
            _updateMessageStatus(msgId, GenStatus.completed, imageUrl: finalUrl);
            _showToast("Image Generated!", isError: false);
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
    final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
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
        );
      });
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  // --- DOWNLOAD & TOAST ---

  void _showToast(String message, {bool isError = false}) {
    // For safer implementation, using SnackBar instead of Overlay to prevent build context errors
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
      margin: EdgeInsets.only(bottom: MediaQuery.of(context).size.height - 100, left: 10, right: 10),
    ));
  }
  
  Future<void> _downloadImage(String url) async {
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

      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);

      _showToast("Saved to ${file.path}");
    } catch (e) {
      _showToast("Save failed", isError: true);
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
              Text(_selectedModel), // No extra text
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

  // --- NEW DRAWER DESIGN ---

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      width: _isSearchExpanded ? MediaQuery.of(context).size.width : 304,
      child: SafeArea(
        child: Column(
          children: [
            // Search Bar Area
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 50,
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
                      onPressed: () => _createNewSession(),
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
            
            // My Stuff Section
            if (!_isSearchExpanded && _myStuffImages.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(images: _myStuffImages)));
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
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: _myStuffImages[i],
                        width: 80, height: 80, fit: BoxFit.cover,
                        placeholder: (context, url) => Container(color: Colors.grey[200]),
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
                  if (_searchQuery.isNotEmpty && !session.title.toLowerCase().contains(_searchQuery)) {
                    return const SizedBox.shrink();
                  }

                  final isActive = session.id == _currentSessionId;
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
                        builder: (ctx) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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

  // --- INPUT AREA WITH PREVIEW ---

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
                      // CUSTOM PICKER
                      if (_showPlusIcon)
                        IconButton(
                          icon: const Icon(Icons.add, color: Colors.grey),
                          onPressed: _openCustomGallery,
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
                    color: (_promptController.text.isEmpty && _pickedImage == null) && !_isGenerating 
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
// WIDGETS & HELPERS
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
            const SizedBox(width: 10),
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
               child: ClipRRect(
                 borderRadius: BorderRadius.circular(10),
                 child: CachedNetworkImage(
                   imageUrl: message.attachedImageUrl!, 
                   width: 200, fit: BoxFit.cover,
                   placeholder: (c,u) => const CircularProgressIndicator(),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.imageUrl != null)
          _buildImagePreview(context, message.imageUrl!),
          
        if (message.visibleText.isNotEmpty)
           Container(
             constraints: const BoxConstraints(maxWidth: 320),
             margin: const EdgeInsets.only(top: 4), // Below avatar
             child: MarkdownBody(
               data: message.visibleText,
               selectable: true,
               builders: {
                 'code': CodeBlockBuilder(),
               },
               styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                 p: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.5),
                 code: const TextStyle(fontFamily: 'monospace', backgroundColor: Colors.transparent),
                 codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF282C34),
                    borderRadius: BorderRadius.circular(8),
                 ),
               ),
             ),
           ),
           
        if (message.status == GenStatus.waiting || message.status == GenStatus.generating)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: TypingIndicator(),
          ),
          
        if (message.status == GenStatus.error)
          _buildErrorState(),
      ],
    );
  }

  Widget _buildImagePreview(BuildContext context, String url) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      margin: const EdgeInsets.only(bottom: 10),
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
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (ctx, url) => const SizedBox(
                height: 300, width: 300,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (context, url, error) => const SizedBox(height: 300, width: 300, child: Icon(Icons.error)),
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

  Widget _buildErrorState() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
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
// MARKDOWN CODE BLOCK BUILDER
// ---------------------------------------------------------------------------

class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var language = '';
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      language = lg.substring(9);
    }
    return CodeBlockWidget(code: element.textContent, language: language);
  }
}

class CodeBlockWidget extends StatelessWidget {
  final String code;
  final String language;

  const CodeBlockWidget({super.key, required this.code, required this.language});

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
                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied to clipboard"), duration: Duration(milliseconds: 600)));
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
      final recent = await albums.first.getAssetListRange(start: 0, end: 60); // Get top 60
      setState(() {
        _images = recent;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Gallery", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Expanded(
            child: _images.isEmpty 
              ? const Center(child: CircularProgressIndicator())
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
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
      ),
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
  const MyStuffPage({super.key, required this.images});

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
                // Open full view logic if needed, or re-use bubble preview
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
        mainAxisAlignment: MainAxisAlignment.start, // Left aligned
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final double value = sin((_controller.value * 2 * pi) + (index * 1.0));
              return Opacity(
                opacity: (value + 1) / 2.0 * 0.6 + 0.4,
                child: Container(
                  margin: const EdgeInsets.only(right: 4),
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
