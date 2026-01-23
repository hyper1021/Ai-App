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
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shimmer/shimmer.dart';
import 'package:audioplayers/audioplayers.dart';

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
  String? modelName;
  // For Music: list of maps {title, audio_url, cover_url, duration, lyrics}
  List<Map<String, dynamic>>? musicResults;

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
    this.musicResults,
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
    'musicResults': musicResults,
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
    musicResults: map['musicResults'] != null
        ? List<Map<String, dynamic>>.from(map['musicResults'])
        : null,
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
  List<Map<String, dynamic>> _myStuffItems = [];

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
      _storageFile = File('${dir.path}/skygen_data_v9.json');

      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        final List<dynamic> myStuffList = jsonData['myStuff'] ?? [];

        setState(() {
          _sessions = sessionList.map((e) => ChatSession.fromMap(e)).toList();
          if (myStuffList.isNotEmpty && myStuffList.first is String) {
             _myStuffItems = myStuffList.map((e) => {
               'type': 'image',
               'url': e as String
             }).toList();
          } else {
             _myStuffItems = List<Map<String, dynamic>>.from(myStuffList);
          }
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
        'myStuff': _myStuffItems,
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
    final tempId = "temp${DateTime.now().millisecondsSinceEpoch}";
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
    // FIXED: Added (_) to accept Duration
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

  // --- MODEL SELECTOR (FIXED UI) ---

  void _openModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true, 
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.6, // Limit height
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 10),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  children: [
                    _buildModelTile("SkyGen", "Advanced Text AI Chat", Icons.chat_bubble_outline),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky-Img", "High Quality Image Gen", Icons.photo_camera_back),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky-Img v2", "Classic Image Gen (Supports Input)", Icons.image_outlined),
                    const SizedBox(height: 10),
                    _buildModelTile("Img Describer", "Image Understanding", Icons.remove_red_eye_outlined),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky Coder", "Programming Model", Icons.code_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky Music", "AI Music Generator", Icons.music_note_rounded),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF007AFF)),
          ],
        ),
      ),
    );
  }

  // --- SYSTEM IMAGE PICKER ---

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        setState(() {
          _pickedImage = File(image.path);
          _isUploadingImage = true;
        });
        _uploadToImgBB(File(image.path));
      }
    } catch (e) {
      _showToast("Picker Error: $e", isError: true);
    }
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
          
          // Auto switch to v2 if image is attached and model is Sky-Img (v1)
          if (_selectedModel == "Sky-Img") {
            _selectedModel = "Sky-Img v2";
            _showToast("Switched to v2 for Image Input");
          }
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

    // Validations
    if (prompt.isEmpty && _pickedImage == null) return;
    if (_pickedImage != null && prompt.isEmpty && _selectedModel != "Img Describer") {
       _showToast("Text description is mandatory with image.", isError: true);
       return;
    }

    if (!(await _checkInternet())) {
      _showToast("No Internet Connection", isError: true);
      return;
    }

    // Initialize Temp Session
    if (_isTempSession) {
      String titleText = prompt.isNotEmpty ? prompt : "Image Analysis";
      final newTitle = titleText.length > 25 ? "${titleText.substring(0, 25)}..." : titleText;
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

    // Determine actual model based on attachment
    String activeModel = _selectedModel;
    if (_uploadedImgBBUrl != null && activeModel == "Sky-Img") {
      activeModel = "Sky-Img v2"; // v1 doesn't support image input
    }

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      attachedImageUrl: _uploadedImgBBUrl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: activeModel,
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

    // Routing
    if (activeModel == "Sky-Img") {
      await _processSkyImgV1(prompt);
    } else if (activeModel == "Sky-Img v2") {
      await _processSkyImgV2(prompt, attachment);
    } else if (activeModel == "Img Describer" && attachment != null) {
      await _processDescriberFlow(attachment); 
    } else if (activeModel == "Sky Coder") {
      await _processSkyCoder(prompt);
    } else if (activeModel == "Sky Music") {
      await _processMusicGeneration(prompt);
    } else {
      if (attachment != null) {
        await _processDescriberFlow(attachment); 
      } else {
        await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
      }
    }
  }

  // --- ERROR PARSER HELPER ---
  String _parseError(dynamic responseBody) {
    try {
      final data = jsonDecode(responseBody);
      if (data['ok'] == false) {
         if (data['error'] != null && data['error']['message'] != null) {
            return data['error']['message'];
         }
      }
    } catch (_) {}
    return "Something went wrong.";
  }

  // --- TYPING ANIMATION ---

  Future<void> _streamResponse(String msgId, String fullText) async {
    if (!mounted) return;
    _updateMessageStatus(msgId, GenStatus.streaming, errorText: fullText);

    int currentIndex = 0;
    const chunkSize = 10; 

    while (currentIndex < fullText.length) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 10)); 
      
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
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    final aiMsg = ChatMessage(
      id: aiMsgId,
      text: "Thinking...",
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
        if (data['ok'] == false) throw Exception(_parseError(response.body));
        
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
    await _processTextAI(prompt, "https://coder-bd.vercel.app/api");
  }

  Future<void> _processDescriberFlow(String imgUrl) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Analyzing Image...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.waiting,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Img Describer",
    )));
    _scrollToBottom();

    try {
      final descRes = await http.get(Uri.parse("https://gen-z-describer.vercel.app/api?url=$imgUrl"));
      if (descRes.statusCode != 200) throw Exception("Describer failed");
      
      final descData = jsonDecode(descRes.body);
      if (descData['ok'] == false) throw Exception(_parseError(descRes.body));

      final description = descData["results"]["description"];
      await _streamResponse(aiMsgId, description);

    } catch (e) {
       _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
       setState(() => _isGenerating = false);
       _saveData();
    }
  }

  // --- SKY IMAGE V1 (Main Version) ---
  Future<void> _processSkyImgV1(String prompt) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    
    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Generating Image...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.generating, 
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Sky-Img",
    )));
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse("https://sky-img.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == false) throw Exception(_parseError(response.body));

        // Version 1 returns photo inside results
        String photoUrl = data["results"]["photo"];
        _handleSuccessImage(aiMsgId, photoUrl);
      } else {
        throw Exception("Server Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: $e");
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  // --- SKY IMAGE V2 (Old Version / Image to Image) ---
  Future<void> _processSkyImgV2(String prompt, String? attachmentUrl) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);

    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Generating Image...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.generating, 
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Sky-Img v2",
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
      ).timeout(const Duration(seconds: 40));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == false) throw Exception(_parseError(response.body));

        _currentGenId = data["results"]["id"];
        await _pollForImageV2(aiMsgId, _currentGenId!);
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

  Future<void> _pollForImageV2(String msgId, String generationId) async {
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
          if (data['ok'] == false) throw Exception(_parseError(response.body));

          final List<dynamic> urls = data["results"]["urls"] ?? [];
          if (urls.isNotEmpty) {
            _handleSuccessImage(msgId, urls.first);
            return;
          }
        }
      } catch (_) {}
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Timeout.");
  }

  void _handleSuccessImage(String msgId, String url) {
    setState(() {
      _myStuffItems.insert(0, {
        'type': 'image',
        'url': url
      });
    });
    _updateMessageStatus(msgId, GenStatus.completed, imageUrl: url, errorText: "Image Generated");
  }

  // --- SKY MUSIC LOGIC (UPDATED WITH POLLING & JSON PARSING) ---

  Future<void> _processMusicGeneration(String prompt) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);

    setState(() => currentSess.messages.add(ChatMessage(
      id: aiMsgId,
      text: "Composing Music (This may take 3-5 mins)...",
      visibleText: "",
      type: MessageType.ai,
      status: GenStatus.generating, 
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: "Sky Music",
    )));
    _scrollToBottom();

    try {
      final styles = ['Rap', 'Pop', 'Rock', 'Jazz', 'Classical', 'Lofi'];
      final randomStyle = styles[Random().nextInt(styles.length)];
      
      final body = {
        "q": prompt,
        "title": "Random",
        "style": randomStyle,
        "gender": "random"
      };

      final response = await http.post(
        Uri.parse("https://gen-z-music.vercel.app/gen"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == false) throw Exception(_parseError(response.body));

        final List<dynamic> ids = data["results"]["song_ids"] ?? [];
        if (ids.isNotEmpty) {
          await _pollForMusic(aiMsgId, ids.join(","));
        } else {
          throw Exception("No Song IDs returned");
        }
      } else {
        throw Exception("Music API Failed");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: $e");
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  Future<void> _pollForMusic(String msgId, String ids) async {
    // 1. Initial Waiting (30s) as requested
    await Future.delayed(const Duration(seconds: 30));

    int attempts = 0;
    // Increased loops for long wait time (up to 5 mins approx)
    while (attempts < 60) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped, errorText: "Stopped.");
        return;
      }
      
      try {
        final checkUrl = Uri.parse("https://gen-z-music.vercel.app/check");
        final response = await http.post(
          checkUrl,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"id": ids}),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['ok'] == false) throw Exception(_parseError(response.body));

          final List<dynamic> results = data["results"];
          
          // If results empty, still processing
          if (results.isEmpty) {
            await Future.delayed(const Duration(seconds: 5));
            attempts++;
            continue; 
          }

          // Check for valid data
          List<Map<String, dynamic>> musicList = [];
          
          for (var res in results) {
            // Using the full URL at the bottom of the object (as requested, 'url' key)
            String? audioUrl = res['url']; 
            
            if (audioUrl != null && audioUrl.isNotEmpty) {
               final musicItem = {
                 'type': 'music',
                 'title': "Music Track", 
                 'audio_url': audioUrl,
                 'cover_url': res['cover_url'],
                 // Using lyrics as the descriptive title content for expansion
                 'lyrics': res['lyrics'] ?? "No Description Available" 
               };
               musicList.add(musicItem);
               
               // Add to My Stuff
               setState(() {
                 _myStuffItems.insert(0, musicItem);
               });
            }
          }

          if (musicList.isNotEmpty) {
             final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
             if (sIndex != -1) {
                final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
                if (mIndex != -1) {
                  setState(() {
                    _sessions[sIndex].messages[mIndex] = ChatMessage(
                      id: msgId,
                      text: "Music Generated",
                      visibleText: "Music Generated",
                      type: MessageType.ai,
                      status: GenStatus.completed,
                      timestamp: DateTime.now().millisecondsSinceEpoch,
                      modelName: "Sky Music",
                      musicResults: musicList,
                    );
                  });
                  _scrollToBottom();
                }
             }
             return;
          }
        }
      } catch (_) {}
      
      // Wait before next retry
      await Future.delayed(const Duration(seconds: 5));
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Music Creation Timeout.");
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? errorText}) {
    if (!mounted) return;

    int sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;

    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        var old = _sessions[sIndex].messages[mIndex];
        String finalVisibleText = old.visibleText;
        String finalText = errorText ?? old.text;

        _sessions[sIndex].messages[mIndex] = ChatMessage(
          id: msgId,
          text: finalText,
          visibleText: status == GenStatus.completed ? finalText : old.visibleText,
          type: MessageType.ai,
          imageUrl: imageUrl,
          status: status,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          modelName: old.modelName,
          musicResults: old.musicResults,
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

  void _goToChatFromImage(String url) {
    for (var session in _sessions) {
      for (var msg in session.messages) {
        if (msg.imageUrl == url || (msg.musicResults != null && msg.musicResults!.any((m) => m['cover_url'] == url))) {
          setState(() {
            _currentSessionId = session.id;
            _isTempSession = false;
            _isGenerating = false;
            _clearAttachment();
          });
          Navigator.pop(context);
          Navigator.of(context).popUntil((route) => route.isFirst);
          // FIXED: Added (_) to accept Duration
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
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
                child: const Icon(Icons.add, color: Colors.black87),
              ),
              onPressed: _startNewChatAction,
            ),
          ),
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
            // Search Bar
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
            if (!_isSearchExpanded && _myStuffItems.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context); 
                    Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(
                      items: _myStuffItems, 
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
                  itemCount: min(_myStuffItems.length, 3),
                  separatorBuilder: (_,__) => const SizedBox(width: 10),
                  itemBuilder: (ctx, i) {
                    final item = _myStuffItems[i];
                    final isMusic = item['type'] == 'music';
                    final url = isMusic ? item['cover_url'] : item['url'];
                    
                    return GestureDetector(
                      onTap: () {
                         Navigator.pop(context); 
                         Navigator.push(context, MaterialPageRoute(
                          builder: (_) => FullScreenViewer(
                            item: item,
                            onToast: _showToast,
                            onGoToChat: _goToChatFromImage,
                          )
                        ));
                      },
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: url,
                              width: 80, height: 80, fit: BoxFit.cover,
                              placeholder: (context, url) => Container(color: Colors.grey[200]),
                            ),
                          ),
                          if (isMusic)
                            const Positioned.fill(
                              child: Center(
                                child: Icon(Icons.music_note, color: Colors.white, size: 24),
                              ),
                            )
                        ],
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
                    trailing: isActive ? null : const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                    onTap: () => _switchSession(session.id),
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.white,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                        builder: (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                trailing: const Icon(Icons.chevron_right, size: 16),
                                onTap: () => _renameSession(session.id),
                              ),
                              ListTile(
                                leading: const Icon(Icons.push_pin),
                                title: Text(session.isPinned ? "Unpin" : "Pin"),
                                trailing: const Icon(Icons.chevron_right, size: 16),
                                onTap: () => _pinSession(session.id),
                              ),
                              ListTile(
                                leading: const Icon(Icons.delete, color: Colors.red),
                                title: const Text("Delete", style: TextStyle(color: Colors.red)),
                                trailing: const Icon(Icons.chevron_right, size: 16, color: Colors.red),
                                onTap: () => _deleteSession(session.id),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
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

  // --- INPUT AREA ---

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

          // Input Field
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                
                if (_showPlusIcon)
                   SizedBox(
                     width: 40, height: 40,
                     child: IconButton(
                       icon: Transform.rotate(
                         angle: -pi / 4, 
                         child: const Icon(Icons.attach_file, color: Colors.grey),
                       ),
                       onPressed: _pickImage,
                     ),
                   ),

                SizedBox(
                   width: 40, height: 40,
                   child: IconButton(
                     style: IconButton.styleFrom(
                       backgroundColor: (_promptController.text.isNotEmpty || _pickedImage != null || _isGenerating) ? const Color(0xFF007AFF) : Colors.transparent,
                       shape: const CircleBorder(),
                     ),
                     icon: Icon(
                       _isGenerating ? Icons.stop_rounded : Icons.arrow_upward,
                       color: (_promptController.text.isNotEmpty || _pickedImage != null || _isGenerating) ? Colors.white : Colors.grey,
                       size: 22,
                     ),
                     onPressed: _isGenerating ? () => setState(() => _stopRequested = true) : _handleSubmitted,
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
// CHAT BUBBLE & HELPERS
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
                  // FIXED: Added (_) to accept Context
                  builder: (_) => FullScreenViewer(
                    item: {'type': 'image', 'url': message.attachedImageUrl!},
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
          if (message.text.isNotEmpty)
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

    String statusText = "Thinking...";
    if (message.text.contains("Generating Image") || message.modelName!.contains("Sky-Img")) statusText = "Generating Image...";
    else if (message.text.contains("Analyzing") || message.modelName == "Img Describer") statusText = "Analyzing Image...";
    else if (message.text.contains("Codes") || message.modelName == "Sky Coder") statusText = "Creating Codes...";
    else if (message.text.contains("Music") || message.modelName == "Sky Music") statusText = "Composing Music...";

    bool showLoader = isWaiting || isStreaming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // HEADER
        Row(
           children: [
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
                     imageUrl: "https://iili.io/f4Xfgfa.jpg", 
                     width: 24, height: 24, fit: BoxFit.cover,
                     placeholder: (c,u) => Container(color: Colors.grey[300]),
                     errorWidget: (c,u,e) => const Icon(Icons.auto_awesome),
                   ),
                 ),
               ],
             ),
             const SizedBox(width: 10),
             
             if (isWaiting) ...[
                const TypingIndicator(),
                const SizedBox(width: 8),
                Text(statusText, style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
             ] else if (message.status == GenStatus.completed) ...[
               if (message.imageUrl != null)
                  const Text("Image Generated", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
               else if (message.musicResults != null)
                  const Text("Music Created", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
               else
                  const Text("Response Crafted", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
             ],
           ],
        ),

        const SizedBox(height: 8),

        // 1. Image Placeholder / Result
        if (message.status == GenStatus.generating && message.imageUrl == null && message.modelName!.contains("Sky-Img"))
          _buildShimmerPlaceholder()
        else if (message.imageUrl != null)
          _buildImagePreview(context, message.imageUrl!),
          
        // 2. Music Placeholders / Result
        if (message.status == GenStatus.generating && message.modelName == "Sky Music")
          Column(
            children: [
              const SizedBox(height: 10),
               _buildMusicSkeleton(),
               const SizedBox(height: 10),
               _buildMusicSkeleton(),
            ],
          )
        else if (message.musicResults != null)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: message.musicResults!.map((m) => MusicCard(music: m, onToast: onToast)).toList(),
          ),

        // 3. Text
        if (message.visibleText.isNotEmpty && message.imageUrl == null && message.musicResults == null)
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
                 code: const TextStyle(fontFamily: 'monospace', backgroundColor: Color(0xFFF0F0F0), color: Colors.redAccent),
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

  Widget _buildMusicSkeleton() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Container(
        width: 300, height: 70,
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
              // FIXED: Added (_) to accept Context
              builder: (_) => FullScreenViewer(
                item: {'type': 'image', 'url': url},
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
// MUSIC CARD (NEW DESIGN)
// ---------------------------------------------------------------------------

class MusicCard extends StatefulWidget {
  final Map<String, dynamic> music;
  final Function(String, {bool isError}) onToast;
  const MusicCard({super.key, required this.music, required this.onToast});

  @override
  State<MusicCard> createState() => _MusicCardState();
}

class _MusicCardState extends State<MusicCard> with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isExpanded = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _player.play(UrlSource(widget.music['audio_url']));
      }
      setState(() => _isPlaying = !_isPlaying);
    } catch (e) {
      widget.onToast("Cannot play audio", isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 320, 
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!)
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Image | Play | Music Text | Download | Expand
          Row(
            children: [
              // Cover + Play
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: widget.music['cover_url'],
                      width: 50, height: 50, fit: BoxFit.cover,
                    ),
                  ),
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                      child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              
              // "Music" Label
              const Text("Music", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              
              const Spacer(),

              // Download Button
              DownloadButton(url: widget.music['audio_url'], onToast: widget.onToast),
              
              const SizedBox(width: 8),

              // Expand Button (>)
              InkWell(
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(_isExpanded ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right, color: Colors.grey),
                ),
              ),
            ],
          ),
          
          // Expanded Lyric/Title Area
          if (_isExpanded)
             Padding(
               padding: const EdgeInsets.only(top: 12),
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   const Divider(),
                   Text(
                     widget.music['lyrics'] ?? widget.music['title'],
                     style: const TextStyle(fontSize: 14, height: 1.5, color: Colors.black87),
                   ),
                 ],
               ),
             )
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

      final ext = widget.url.endsWith(".mp3") ? "mp3" : "png";
      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.$ext";
      final file = File("${directory.path}/$fileName");

      final response = await http.get(Uri.parse(widget.url));
      await file.writeAsBytes(response.bodyBytes);

      widget.onToast("Saved successfully");
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
          color: Colors.black.withOpacity(0.8),
          shape: BoxShape.circle,
        ),
        child: _isLoading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.download_rounded, color: Colors.white, size: 18),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FULL SCREEN VIEWER
// ---------------------------------------------------------------------------

class FullScreenViewer extends StatelessWidget {
  final Map<String, dynamic> item; 
  final Function(String, {bool isError}) onToast;
  final Function(String) onGoToChat;

  const FullScreenViewer({
    super.key,
    required this.item,
    required this.onToast,
    required this.onGoToChat
  });

  @override
  Widget build(BuildContext context) {
    bool isMusic = item['type'] == 'music';
    String displayUrl = isMusic ? item['cover_url'] : item['url'];
    String downloadUrl = isMusic ? item['audio_url'] : item['url'];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: CachedNetworkImage(
                    imageUrl: displayUrl,
                    fit: BoxFit.contain,
                    placeholder: (c,u) => const CircularProgressIndicator(color: Colors.white),
                  ),
                ),
                if (isMusic) ...[
                   const SizedBox(height: 20),
                   const Icon(Icons.music_note, color: Colors.white, size: 40),
                   const Text("AI Music Track", style: TextStyle(color: Colors.white)),
                ]
              ],
            ),
          ),
          
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 20,
            child: Row(
              children: [
                _buildCircleButton(Icons.chat_bubble_outline, () => onGoToChat(displayUrl)),
                const SizedBox(width: 15),
                DownloadButton(url: downloadUrl, onToast: onToast), 
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
// MY STUFF PAGE
// ---------------------------------------------------------------------------

class MyStuffPage extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Function(String) onGoToChat;
  final Function(String, {bool isError}) onToast;

  const MyStuffPage({
    super.key,
    required this.items,
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
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          final isMusic = item['type'] == 'music';
          final url = isMusic ? item['cover_url'] : item['url'];

          return GestureDetector(
             onTap: () {
                Navigator.push(context, MaterialPageRoute(
                  // FIXED: Added (_)
                  builder: (_) => FullScreenViewer(
                    item: item, 
                    onToast: onToast,
                    onGoToChat: onGoToChat,
                  )
                ));
             },
             child: Stack(
               fit: StackFit.expand,
               children: [
                 ClipRRect(
                   borderRadius: BorderRadius.circular(4),
                   child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                 ),
                 Positioned(
                   top: 4, right: 4,
                   child: Container(
                     padding: const EdgeInsets.all(4),
                     decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                     child: Icon(
                       isMusic ? Icons.music_note : Icons.image, 
                       color: Colors.white, size: 12
                     ),
                   ),
                 ),
               ],
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
          ClipOval(
            child: CachedNetworkImage(
              imageUrl: "https://iili.io/f4Xfgfa.jpg",
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
        mainAxisAlignment: MainAxisAlignment.start,
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
