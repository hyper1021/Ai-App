import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui'; // For formatting

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
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

// ==============================================================================
// 1. APP CONFIGURATION & ENTRY POINT
// ==============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Set Orientation to Portrait Only
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configure System UI Overlay
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark, // Dark icons for white background
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  runApp(const SkyGenApp());
}

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
        primaryColor: const Color(0xFF007AFF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.light,
          background: const Color(0xFFFFFFFF),
          surface: const Color(0xFFFFFFFF),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            fontFamily: 'Roboto',
          ),
        ),
        // Tooltip customization for "Hover" effect
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
        ),
        fontFamily: 'Roboto',
      ),
      home: const ChatScreen(),
    );
  }
}

// ==============================================================================
// 2. DATA MODELS
// ==============================================================================

enum MessageType { user, ai }
enum GenStatus { waiting, generating, streaming, completed, error, stopped }

/// Represents a single message in the chat
class ChatMessage {
  final String id;
  final String text;
  String visibleText;
  final MessageType type;
  
  // Attachments & Media
  String? imageUrl;          // Result Image URL
  String? videoPath;         // Result Video (Local or URL)
  String? attachedImageUrl;  // User uploaded image
  
  // Status & Metadata
  GenStatus status;
  final int timestamp;
  String? modelName;
  
  // Music Specific
  List<Map<String, dynamic>>? musicResults;

  // TTS State (Runtime Only - Not saved to JSON)
  bool isSpeaking;
  bool isTTSLoading; 

  ChatMessage({
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.imageUrl,
    this.videoPath,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
    this.modelName,
    this.musicResults,
    this.isSpeaking = false,
    this.isTTSLoading = false,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : "");

  // Serialization for Storage
  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'visibleText': visibleText,
    'type': type.index,
    'imageUrl': imageUrl,
    'videoPath': videoPath,
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
    videoPath: map['videoPath'],
    attachedImageUrl: map['attachedImageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
    modelName: map['modelName'],
    musicResults: map['musicResults'] != null
        ? List<Map<String, dynamic>>.from(map['musicResults'])
        : null,
  );
}

/// Represents a Chat Session
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

// ==============================================================================
// 3. MAIN CHAT SCREEN
// ==============================================================================

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  // Controllers
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _searchController = TextEditingController();

  // State Variables
  List<ChatSession> _sessions = [];
  List<Map<String, dynamic>> _myStuffItems = []; // {type, url, thumbnail, title...}
  
  String _currentSessionId = "";
  bool _isTempSession = true;
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;
  File? _storageFile;

  // New Feature States
  String _selectedModel = "SkyGen"; // Default
  bool _isModelLocked = false;      // If user selected a model via buttons
  
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;
  bool _showPlusIcon = true;

  // Drawer Search
  bool _isSearchExpanded = false;
  String _searchQuery = "";

  // Animations
  late AnimationController _buttonsAnimController;

  // TTS Player
  final AudioPlayer _ttsPlayer = AudioPlayer();
  List<String> _ttsQueue = [];
  bool _isPlayingTTS = false;
  String? _currentSpeakingMsgId;

  // Floating Copy Overlay
  OverlayEntry? _copyOverlayEntry;

  @override
  void initState() {
    super.initState();
    _initStorage();
    _promptController.addListener(_handleInputListener);
    
    // Animation for home buttons
    _buttonsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _buttonsAnimController.forward();

    // Listen to TTS completion
    _ttsPlayer.onPlayerComplete.listen((event) {
      _playNextTTSChunk();
    });
  }

  @override
  void dispose() {
    _promptController.removeListener(_handleInputListener);
    _promptController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _buttonsAnimController.dispose();
    _ttsPlayer.dispose();
    _removeCopyOverlay(); // Ensure overlay is removed
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

  // --------------------------------------------------------------------------
  // STORAGE & SESSION MANAGEMENT
  // --------------------------------------------------------------------------

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_v17_pro.json');

      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        final List<dynamic> myStuffList = jsonData['myStuff'] ?? [];

        setState(() {
          _sessions = sessionList.map((e) => ChatSession.fromMap(e)).toList();
          // Ensure backward compatibility for MyStuff
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
      _pickedImage = null;
      _uploadedImgBBUrl = null;
      _isUploadingImage = false;
      
      // Re-trigger animation for home buttons
      _buttonsAnimController.reset();
      _buttonsAnimController.forward();
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

  // --------------------------------------------------------------------------
  // HISTORY ACTIONS (PIN, DELETE, RENAME)
  // --------------------------------------------------------------------------

  void _pinSession(String id) {
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index != -1) {
      setState(() {
        _sessions[index].isPinned = !_sessions[index].isPinned;
        _sortSessions();
      });
      _saveData();
      _showToast(_sessions[index].isPinned ? "Chat Pinned" : "Chat Unpinned");
    }
    Navigator.pop(context); // Close sheet
  }

  void _confirmDeleteSession(String id) {
    Navigator.pop(context); // Close bottom sheet first
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete Chat?"),
      content: const Text("This action cannot be undone. All associated media will be removed from history."),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          Navigator.pop(ctx);
          _performDelete(id);
        }, child: const Text("Delete", style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  Future<void> _performDelete(String id) async {
    final sessionIndex = _sessions.indexWhere((s) => s.id == id);
    if (sessionIndex == -1) return;
    final session = _sessions[sessionIndex];

    // Delete media
    for (var msg in session.messages) {
      await _deleteMediaFile(msg.videoPath);
    }
    
    // Remove from MyStuff based on URL matching
    final messagesUrls = <String>{};
    for(var m in session.messages) {
      if(m.imageUrl != null) messagesUrls.add(m.imageUrl!);
      if(m.videoPath != null) messagesUrls.add(m.videoPath!);
      if(m.musicResults != null) {
        for(var music in m.musicResults!) {
          if(music['audio_url'] != null) messagesUrls.add(music['audio_url']);
        }
      }
    }

    setState(() {
      _myStuffItems.removeWhere((item) {
        final url = item['type'] == 'music' ? item['audio_url'] : item['url'];
        return messagesUrls.contains(url);
      });
      _sessions.removeAt(sessionIndex);
      if (_currentSessionId == id) _createTempSession();
    });
    
    _saveData();
    _showToast("Chat deleted");
  }

  void _renameSession(String id) {
    Navigator.pop(context); // Close sheet
    final s = _sessions.firstWhere((s) => s.id == id);
    final controller = TextEditingController(text: s.title);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Rename Chat"),
      content: TextField(
        controller: controller, 
        decoration: const InputDecoration(hintText: "Enter new name", border: OutlineInputBorder()),
        autofocus: true,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          setState(() => s.title = controller.text.trim());
          _saveData();
          Navigator.pop(ctx);
        }, child: const Text("Save")),
      ],
    ));
  }

  Future<void> _deleteMediaFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
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

  // --------------------------------------------------------------------------
  // MODEL SELECTOR
  // --------------------------------------------------------------------------

  void _setModel(String model) {
    setState(() {
      _selectedModel = model;
      _isModelLocked = true;
    });
  }

  void _openModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white, // FIX: Set explicit color to avoid bleed
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return SizedBox( // Use SizedBox to constrain height
          height: MediaQuery.of(context).size.height * 0.65, 
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text("Select Model", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    _buildModelTile("SkyGen", "Advanced Assistant (Default)", Icons.auto_awesome),
                    _buildModelTile("Sky OCR", "Extract Text from Images", Icons.document_scanner),
                    _buildModelTile("Sky-Img", "High Quality Image Generation", Icons.photo_filter),
                    _buildModelTile("Sky-Img v2", "Image Gen with Input Support", Icons.add_photo_alternate),
                    _buildModelTile("Sky Video", "AI Video Creator", Icons.video_library),
                    _buildModelTile("Sky Music", "AI Music Composer", Icons.music_note),
                    _buildModelTile("Sky Coder", "Specialized Code Helper", Icons.code),
                    _buildModelTile("Img Describer", "Image Analysis & Vision", Icons.remove_red_eye),
                    const SizedBox(height: 30),
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
        setState(() {
          _selectedModel = id;
          _isModelLocked = true; // User explicitly selected
        });
        Navigator.pop(context);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF0F9F6) : Colors.white,
          border: Border.all(color: isSelected ? const Color(0xFF007AFF) : Colors.grey[200]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF007AFF).withOpacity(0.1) : Colors.grey[100],
                shape: BoxShape.circle
              ),
              child: Icon(icon, color: isSelected ? const Color(0xFF007AFF) : Colors.grey[600], size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(id, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isSelected ? const Color(0xFF007AFF) : Colors.black87)),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF007AFF)),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // INPUT & PROCESSING
  // --------------------------------------------------------------------------

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
        setState(() => _pickedImage = null);
        return;
      }

      const apiKey = "0ffd290312c6b0ca9bb005414f44df2f"; 
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

  Future<void> _handleSubmitted() async {
    if (_isGenerating) return;

    final prompt = _promptController.text.trim();
    final attachment = _uploadedImgBBUrl;

    if (prompt.isEmpty && _pickedImage == null) return;
    
    if (_pickedImage != null && prompt.isEmpty && _selectedModel != "Img Describer") {
       _showToast("Text description is mandatory with image.", isError: true);
       return;
    }

    if (!(await _checkInternet())) {
      _showToast("No Internet Connection", isError: true);
      return; 
    }

    String activeModel = _selectedModel;
    // Auto-Correction logic
    if (activeModel == "Sky OCR" && attachment == null) activeModel = "SkyGen";
    if (attachment != null && activeModel == "Sky-Img") activeModel = "Sky-Img v2";

    _promptController.clear();
    File? localImage = _pickedImage; 
    _clearAttachment(); 

    if (_isTempSession) {
      String titleText = prompt.isNotEmpty ? prompt : "Image Analysis";
      titleText = titleText.replaceAll('\n', ' ');
      if (titleText.length > 25) titleText = titleText.substring(0, 25);
      
      final newSession = ChatSession(
        id: _currentSessionId, 
        title: titleText, 
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
      attachedImageUrl: attachment, // This is the remote URL
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: activeModel,
    );

    if (attachment != null && localImage != null) {
      _localImageCache[attachment] = localImage;
    }

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(userMsg);
      _isGenerating = true;
      _stopRequested = false;
    });
    _scrollToBottom();
    _saveData();

    try {
      if (activeModel == "Sky-Img") {
        await _processSkyImgV1(prompt);
      } else if (activeModel == "Sky-Img v2") {
        await _processSkyImgV2(prompt, attachment);
      } else if (activeModel == "Sky Video") {
        await _processSkyVideo(prompt);
      } else if (activeModel == "Sky OCR" && attachment != null) {
        await _processSkyOCR(attachment);
      } else if (activeModel == "Sky Coder") {
        await _processSkyCoder(prompt);
      } else if (activeModel == "Sky Music") {
        await _processMusicGeneration(prompt);
      } else if (activeModel == "Img Describer" && attachment != null) {
        await _processDescriberFlow(attachment);
      } else {
        if (attachment != null) {
          await _processDescriberFlow(attachment);
        } else {
          await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
        }
      }
    } catch (e) {
       setState(() => _isGenerating = false);
       _showToast("An error occurred: $e", isError: true);
    }
  }

  // Local Cache for immediate preview
  static final Map<String, File> _localImageCache = {};

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

  // --- API HANDLERS ---

  Future<void> _processSkyOCR(String imageUrl) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Extracting text...", "Sky OCR", GenStatus.generating);

    try {
      final response = await http.post(
        Uri.parse("https://gen-z-ocr.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"url": imageUrl}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final results = data['results'];
          final String answer = results['answer'] ?? "";
          final String note = results['note'] ?? "";
          
          String finalOutput = answer;
          if (note.isNotEmpty) {
            finalOutput += "\n\n**Note:** $note";
          }
          
          await _streamResponse(aiMsgId, finalOutput);
        } else {
          throw Exception("OCR Processing Failed");
        }
      } else {
        throw Exception("Server Error ${response.statusCode}");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
      setState(() => _isGenerating = false);
      _saveData();
    }
  }

  Future<void> _processTextAI(String prompt, String apiUrl) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Thinking...", "SkyGen", GenStatus.waiting);

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
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
    _addAIMessage(aiMsgId, "Analyzing Image...", "Img Describer", GenStatus.waiting);

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

  Future<void> _streamResponse(String msgId, String fullText) async {
    if (!mounted) return;
    _updateMessageStatus(msgId, GenStatus.streaming, errorText: fullText);

    int currentIndex = 0;
    while (currentIndex < fullText.length) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 15)); 
      
      currentIndex = min(currentIndex + 8, fullText.length);
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

  Future<void> _processSkyVideo(String prompt) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Generating Video (approx 3 mins)...", "Sky Video", GenStatus.generating);

    try {
      final response = await http.post(
        Uri.parse("https://gen-z-video.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == false) throw Exception("Failed to generate video");

        final videoUrl = data["video_url"];
        final cachedPath = await _cacheMedia(videoUrl, "mp4");
        
        String? thumbPath = await VideoThumbnail.thumbnailFile(
          video: cachedPath,
          thumbnailPath: (await getTemporaryDirectory()).path,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 512, 
          quality: 75,
        );

        _handleSuccessVideo(aiMsgId, cachedPath, thumbPath);
      } else {
        throw Exception("Server Error ${response.statusCode}");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: $e");
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  Future<void> _processSkyImgV1(String prompt) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Generating Image...", "Sky-Img", GenStatus.generating);

    try {
      final response = await http.post(
        Uri.parse("https://sky-img.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == false) throw Exception(_parseError(response.body));

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

  Future<void> _processSkyImgV2(String prompt, String? attachmentUrl) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Generating Image...", "Sky-Img v2", GenStatus.generating);

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

  Future<void> _processMusicGeneration(String prompt) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    _addAIMessage(aiMsgId, "Composing Music...", "Sky Music", GenStatus.generating);

    try {
      final styles = ['Rap', 'Pop', 'Rock', 'Jazz', 'Classical', 'Lofi'];
      final randomStyle = styles[Random().nextInt(styles.length)];
      
      final body = {
        "q": prompt,
        "title": "SkyGen Tune",
        "style": randomStyle,
        "gender": "female"
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
    await Future.delayed(const Duration(seconds: 20)); // Wait before first poll
    int attempts = 0;
    while (attempts < 60) {
      if (_stopRequested) return;
      
      try {
        final checkUrl = Uri.parse("https://gen-z-music.vercel.app/check");
        final response = await http.post(
          checkUrl,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"id": ids}),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['results'] != null && (data['results'] as List).isNotEmpty) {
            List<Map<String, dynamic>> musicList = [];
            for (var res in data['results']) {
              if (res['url'] != null) {
                final item = {
                   'type': 'music',
                   'audio_url': res['url'],
                   'cover_url': res['cover_url'],
                   'lyrics': res['lyrics'] ?? "Instrumental",
                   'title': res['title'] ?? "AI Music"
                };
                musicList.add(item);
                setState(() => _myStuffItems.insert(0, item));
              }
            }
            if (musicList.isNotEmpty) {
              _updateMessageStatus(msgId, GenStatus.completed, musicResults: musicList);
              return;
            }
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 5));
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Music Timeout");
  }

  // --- TTS ---
  
  Future<void> _handleTTSAction(String msgId, String text) async {
    if (_currentSpeakingMsgId == msgId && _isPlayingTTS) {
      // Pause
      await _ttsPlayer.pause();
      setState(() => _isPlayingTTS = false);
      return;
    } 
    
    if (_currentSpeakingMsgId == msgId && !_isPlayingTTS) {
      // Resume
      await _ttsPlayer.resume();
      setState(() => _isPlayingTTS = true);
      return;
    }

    // New Speech Request: Set Loading State
    _updateMessageSpeechState(msgId, false, true); // isSpeaking=false, isLoading=true

    await _ttsPlayer.stop();
    setState(() {
      _currentSpeakingMsgId = msgId;
      _isPlayingTTS = true;
      _ttsQueue.clear();
    });

    String cleanText = text.replaceAll(RegExp(r'```[\s\S]*?```'), ''); 
    cleanText = cleanText.replaceAll(RegExp(r'[^\x00-\x7F]+'), ''); 
    
    final RegExp chunker = RegExp(r'.{1,190}(?:\s|$)', dotAll: true);
    final chunks = chunker.allMatches(cleanText).map((m) => m.group(0)!.trim()).toList();
    
    if (chunks.isEmpty) {
        _updateMessageSpeechState(msgId, false, false);
        return;
    }

    _ttsQueue.addAll(chunks);
    
    // First Play
    await _playNextTTSChunk();
    
    // Set UI state for the message to Speaking
    _updateMessageSpeechState(msgId, true, false); // isSpeaking=true, isLoading=false
  }

  Future<void> _playNextTTSChunk() async {
    if (_ttsQueue.isEmpty) {
      setState(() {
        _isPlayingTTS = false;
        _currentSpeakingMsgId = null;
      });
      // Update UI to stop icon
      for (var s in _sessions) {
         for (var m in s.messages) {
            if (m.isSpeaking) {
               setState(() => m.isSpeaking = false);
            }
         }
      }
      return;
    }

    final chunk = _ttsQueue.removeAt(0);
    try {
      final encoded = Uri.encodeComponent(chunk);
      final url = "https://murf.ai/Prod/anonymous-tts/audio?text=$encoded&voiceId=VM017230562791058FV&style=Conversational";
      await _ttsPlayer.play(UrlSource(url));
    } catch (e) {
      debugPrint("TTS Error: $e");
      _playNextTTSChunk(); 
    }
  }

  // --- HELPERS ---

  void _addAIMessage(String id, String text, String model, GenStatus status) {
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(ChatMessage(
      id: id,
      text: text,
      visibleText: "",
      type: MessageType.ai,
      status: status,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: model,
    )));
    _scrollToBottom();
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? errorText, List<Map<String, dynamic>>? musicResults, String? videoPath}) {
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
          imageUrl: imageUrl ?? old.imageUrl,
          videoPath: videoPath ?? old.videoPath,
          status: status,
          timestamp: old.timestamp,
          modelName: old.modelName,
          musicResults: musicResults ?? old.musicResults,
          isSpeaking: old.isSpeaking,
          isTTSLoading: old.isTTSLoading
        );
      });
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  void _updateMessageSpeechState(String msgId, bool isSpeaking, bool isLoading) {
    int sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        _sessions[sIndex].messages[mIndex].isSpeaking = isSpeaking;
        _sessions[sIndex].messages[mIndex].isTTSLoading = isLoading;
      });
    }
  }

  Future<String> _cacheMedia(String url, String ext) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = "media_${DateTime.now().millisecondsSinceEpoch}.$ext";
      final file = File('${dir.path}/$fileName');
      final response = await http.get(Uri.parse(url));
      await file.writeAsBytes(response.bodyBytes);
      return file.path;
    } catch (e) {
      return url;
    }
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

  void _handleSuccessVideo(String msgId, String path, String? thumbPath) {
    setState(() {
      _myStuffItems.insert(0, {
        'type': 'video',
        'url': path,
        'thumbnail': thumbPath
      });
    });
    _updateMessageStatus(msgId, GenStatus.completed, videoPath: path, errorText: "Video Generated");
  }

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

  void _goToChatFromMedia(String url) {
    for (var session in _sessions) {
      for (var msg in session.messages) {
        if (msg.imageUrl == url || 
            msg.videoPath == url || 
            (msg.musicResults != null && msg.musicResults!.any((m) => m['audio_url'] == url))) {
          _switchSession(session.id);
          return;
        }
      }
    }
    _showToast("Source chat not found (deleted?)", isError: true);
  }

  // --------------------------------------------------------------------------
  // UI BUILDERS
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final currentMessages = _currentSession.messages;

    return GestureDetector(
      onTap: _removeCopyOverlay, // Close overlay on tap elsewhere
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.white,
        drawer: _buildDrawer(),
        appBar: _buildAppBar(),
        body: Column(
          children: [
            Expanded(
              child: currentMessages.isEmpty
                  ? _buildWelcomeScreen()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                      itemCount: currentMessages.length,
                      itemBuilder: (context, index) {
                        return ChatBubble(
                          message: currentMessages[index],
                          onToast: _showToast,
                          onGoToChat: _goToChatFromMedia,
                          onSpeak: _handleTTSAction,
                          isPlayingTTS: _isPlayingTTS && _currentSpeakingMsgId == currentMessages[index].id,
                          onLongPress: (pos) => _showCustomCopyMenu(context, pos, currentMessages[index].text),
                        );
                      },
                    ),
            ),
            _buildInputArea(),
          ],
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.menu_rounded, size: 28),
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
      ),
      // Empty title to make space
      title: const SizedBox.shrink(),
      actions: [
        // Model Selector moved here
        GestureDetector(
          onTap: _openModelSelector,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_selectedModel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)), 
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.black54, size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12), // Gap as requested

        // New Chat Button
        IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
            child: const Icon(Icons.add, color: Colors.black87, size: 20),
          ),
          onPressed: _startNewChatAction,
        ),
        
        // Simulated 3-dots (optional visual filler if needed, or just padding)
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      width: _isSearchExpanded ? MediaQuery.of(context).size.width : 304,
      child: SafeArea(
        child: Column(
          children: [
            // Animated Search Bar
            Padding(
              padding: const EdgeInsets.all(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: double.infinity,
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

            // My Stuff Link
            if (!_isSearchExpanded && _myStuffItems.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context); 
                    Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(
                      items: _myStuffItems, 
                      onGoToChat: _goToChatFromMedia,
                      onToast: _showToast,
                    )));
                  },
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("My Stuff", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              
              // Recent Items Preview
              SizedBox(
                height: 80,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: min(_myStuffItems.length, 3),
                  separatorBuilder: (_,__) => const SizedBox(width: 10),
                  itemBuilder: (ctx, i) {
                    final item = _myStuffItems[i];
                    final isVideo = item['type'] == 'video';
                    final isMusic = item['type'] == 'music';
                    final url = isMusic ? item['cover_url'] : item['url'];
                    final thumb = item['thumbnail'];
                    
                    return GestureDetector(
                      onTap: () {
                         Navigator.pop(context); 
                         Navigator.push(context, MaterialPageRoute(
                          builder: (_) => FullScreenViewer(
                            item: item,
                            onToast: _showToast,
                            onGoToChat: _goToChatFromMedia,
                          )
                        ));
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          children: [
                            isVideo && thumb != null
                              ? Image.file(File(thumb), width: 80, height: 80, fit: BoxFit.cover)
                              : CachedNetworkImage(
                                  imageUrl: url ?? "",
                                  width: 80, height: 80, fit: BoxFit.cover,
                                  placeholder: (c,u) => Container(color: Colors.grey[200]),
                                  errorWidget: (c,u,e) => Container(color: Colors.grey[300], child: const Icon(Icons.error)),
                                ),
                            if (isVideo)
                               const Positioned.fill(child: Center(child: Icon(Icons.play_circle_outline, color: Colors.white))),
                            if (isMusic)
                               const Positioned.fill(child: Center(child: Icon(Icons.music_note, color: Colors.white))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 30),
            ],

            // Session List
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                    tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                    leading: Icon(
                      session.isPinned ? Icons.push_pin : Icons.chat_bubble_outline_rounded,
                      color: session.isPinned ? const Color(0xFF007AFF) : Colors.black54,
                      size: 20,
                    ),
                    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                    trailing: const Icon(Icons.chevron_right, size: 16, color: Colors.grey), // Arrow added
                    onTap: () => _switchSession(session.id),
                    onLongPress: () => _showSessionOptions(session),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSessionOptions(ChatSession session) {
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
              leading: const Icon(Icons.edit_outlined),
              title: const Text("Rename"),
              onTap: () => _renameSession(session.id),
            ),
            ListTile(
              leading: Icon(session.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(session.isPinned ? "Unpin" : "Pin"),
              onTap: () => _pinSession(session.id),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text("Delete", style: TextStyle(color: Colors.red)),
              onTap: () => _confirmDeleteSession(session.id),
            ),
          ],
        ),
      ),
    );
  }

  // --- WELCOME SCREEN (New Design) ---

  Widget _buildWelcomeScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40),
        child: Column(
          children: [
            // Logo
            ClipOval(
              child: Image.network(
                "https://iili.io/f4Xfgfa.jpg",
                width: 70, height: 70, fit: BoxFit.cover,
                errorBuilder: (c,e,s) => const Icon(Icons.auto_awesome, size: 60, color: Color(0xFF007AFF)),
              ),
            ),
            const SizedBox(height: 30),
            
            // Text
            const Text(
              "What can I help with?",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87),
              textAlign: TextAlign.center,
            ),
            
            const SizedBox(height: 40),
            
            // 4-Button Grid (Fade In Animation)
            FadeTransition(
              opacity: _buttonsAnimController,
              child: SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero).animate(CurvedAnimation(parent: _buttonsAnimController, curve: Curves.easeOut)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _buildHomeButton("Create Image", Icons.image_outlined, "Sky-Img", Colors.purple),
                        const SizedBox(width: 12),
                        _buildHomeButton("Create Video", Icons.videocam_outlined, "Sky Video", Colors.orange),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildHomeButton("Create Music", Icons.music_note_outlined, "Sky Music", Colors.pink),
                        const SizedBox(width: 12),
                        _buildHomeButton("Generate Code", Icons.code_outlined, "Sky Coder", Colors.blue),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeButton(String title, IconData icon, String modelId, Color color) {
    return Expanded(
      child: Material(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _setModel(modelId),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[200]!),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- INPUT AREA (Revised Design) ---

  Widget _buildInputArea() {
    // Should show pill if: A model is explicitly selected OR an image is uploaded
    bool showPill = _isModelLocked || _pickedImage != null;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, -4))
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Plus Button (Attach)
          if (_showPlusIcon)
            Container(
              margin: const EdgeInsets.only(bottom: 6, right: 8),
              width: 36, height: 36,
              decoration: BoxDecoration(color: Colors.grey[200], shape: BoxShape.circle),
              child: Tooltip(
                message: "Attach Image",
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add, color: Colors.black54, size: 20),
                  onPressed: _pickImage,
                ),
              ),
            ),

          // Main Input Container
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // THE PILL (Model / Image Indicator)
                  if (showPill)
                     Padding(
                       padding: const EdgeInsets.only(left: 12, top: 10, right: 12),
                       child: _buildInputPill(),
                     ),

                  // Text Field
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                         Expanded(
                           child: TextField(
                             controller: _promptController,
                             enabled: !_isGenerating,
                             maxLines: 5,
                             minLines: 1,
                             style: const TextStyle(fontSize: 16),
                             decoration: const InputDecoration(
                               hintText: "Message",
                               hintStyle: TextStyle(color: Colors.grey),
                               contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                               border: InputBorder.none,
                             ),
                           ),
                         ),
                         
                         // Send/Stop Button
                         Padding(
                           padding: const EdgeInsets.only(bottom: 6, right: 6),
                           child: Tooltip(
                             message: _isGenerating ? "Stop Generation" : "Send Message", // Tooltip Hover
                             child: GestureDetector(
                               onTap: _isGenerating ? () => setState(() => _stopRequested = true) : _handleSubmitted,
                               child: AnimatedContainer(
                                 duration: const Duration(milliseconds: 200),
                                 width: 34, height: 34,
                                 decoration: BoxDecoration(
                                   color: (_promptController.text.isNotEmpty || _pickedImage != null || _isGenerating) 
                                       ? Colors.black 
                                       : Colors.grey[300],
                                   shape: BoxShape.circle,
                                 ),
                                 child: Icon(
                                   _isGenerating ? Icons.stop_rounded : Icons.arrow_upward,
                                   color: (_promptController.text.isNotEmpty || _pickedImage != null || _isGenerating) 
                                       ? Colors.white 
                                       : Colors.grey[500],
                                   size: 20,
                                 ),
                               ),
                             ),
                           ),
                         ),
                      ],
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

  Widget _buildInputPill() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey[300]!),
        boxShadow: [
           BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0,2))
        ]
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon or Image Thumb
          if (_pickedImage != null)
             GestureDetector(
               onTap: () {
                 // Full Screen Preview
                 Navigator.push(context, MaterialPageRoute(builder: (_) => FullScreenViewer(
                   item: {'type': 'image', 'url': _pickedImage!.path}, // Using path for local
                   onToast: _showToast,
                   onGoToChat: _goToChatFromMedia,
                   isLocal: true,
                 )));
               },
               child: ClipRRect(
                 borderRadius: BorderRadius.circular(6),
                 child: Stack(
                    children: [
                      Image.file(_pickedImage!, width: 40, height: 40, fit: BoxFit.cover),
                      if (_isUploadingImage)
                        const Positioned.fill(child: ColoredBox(color: Colors.black45, child: Center(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))))),
                    ]
                 )
               ),
             )
          else
             Icon(_getModelIcon(_selectedModel), size: 20, color: const Color(0xFF007AFF)),
          
          const SizedBox(width: 8),
          
          // Model Name Text
          GestureDetector(
            onTap: _openModelSelector,
            child: Text(
              _pickedImage != null ? "Image Attached" : _selectedModel,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.black87),
            ),
          ),
          
          const SizedBox(width: 8),

          // Close Button
          GestureDetector(
            onTap: () {
              setState(() {
                _clearAttachment(); // Removes image
                _isModelLocked = false; // Unlocks model
                _selectedModel = "SkyGen"; // Reset to default
              });
            },
            child: const Icon(Icons.close, size: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  IconData _getModelIcon(String id) {
    if (id.contains("Video")) return Icons.videocam;
    if (id.contains("Music")) return Icons.music_note;
    if (id.contains("Img")) return Icons.image;
    if (id.contains("Code")) return Icons.code;
    if (id.contains("OCR")) return Icons.document_scanner;
    return Icons.auto_awesome;
  }

  // --- COPY OVERLAY (Floating on Message) ---
  void _showCustomCopyMenu(BuildContext context, Offset position, String text) {
    _removeCopyOverlay(); // Clear previous if any
    
    // Calculate position slightly below the touch
    final overlayState = Overlay.of(context);
    final top = position.dy + 20;
    final left = position.dx - 40;

    _copyOverlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: top,
        left: max(16, min(left, MediaQuery.of(context).size.width - 100)),
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: text));
              _showToast("Copied");
              _removeCopyOverlay();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Text("Copy", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    overlayState.insert(_copyOverlayEntry!);
    
    // Auto remove after 3 seconds
    Future.delayed(const Duration(seconds: 3), _removeCopyOverlay);
  }

  void _removeCopyOverlay() {
    _copyOverlayEntry?.remove();
    _copyOverlayEntry = null;
  }
}

// ==============================================================================
// 4. CHAT BUBBLE WIDGET
// ==============================================================================

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String, {bool isError}) onToast;
  final Function(String) onGoToChat;
  final Function(String, String) onSpeak;
  final bool isPlayingTTS;
  final Function(Offset)? onLongPress; // For Copy Position

  const ChatBubble({
    super.key,
    required this.message,
    required this.onToast,
    required this.onGoToChat,
    required this.onSpeak,
    required this.isPlayingTTS,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.type == MessageType.user;

    // DETECT LONG PRESS FOR COPY OVERLAY
    return GestureDetector(
      onLongPressStart: (details) {
         if (onLongPress != null) onLongPress!(details.globalPosition);
      },
      child: Padding(
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
      ),
    );
  }

  Widget _buildUserMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (message.attachedImageUrl != null)
           Padding(
             padding: const EdgeInsets.only(bottom: 8),
             child: GestureDetector(
               onTap: () {
                 // Open Full Screen (User Uploaded)
                 Navigator.push(context, MaterialPageRoute(
                   builder: (_) => FullScreenViewer(
                     item: {'type': 'image', 'url': message.attachedImageUrl!},
                     onToast: onToast,
                     onGoToChat: onGoToChat,
                     hideActions: true, // No download buttons for user's own upload
                   )
                 ));
               },
               child: Hero(
                 tag: message.attachedImageUrl!,
                 child: ClipRRect(
                   borderRadius: BorderRadius.circular(12),
                   child: CachedNetworkImage(
                     imageUrl: message.attachedImageUrl!,
                     width: 250, fit: BoxFit.cover,
                     placeholder: (c,u) => Container(width: 250, height: 250, color: Colors.grey[200]),
                   ),
                 ),
               ),
             ),
           ),
           
        Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF2F2F2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            message.text,
            style: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildAIMessage(BuildContext context) {
    bool isWaiting = message.status == GenStatus.waiting || message.status == GenStatus.generating;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // HEADER ROW (Icon + Name + Dots + TTS)
        Row(
           children: [
             const SizedBox(width: 4),
             Container(
               width: 26, height: 26,
               decoration: BoxDecoration(
                 border: Border.all(color: Colors.grey[200]!),
                 shape: BoxShape.circle,
               ),
               child: ClipOval(
                 child: Image.network(
                   "https://iili.io/f4Xfgfa.jpg", 
                   fit: BoxFit.cover,
                   errorBuilder: (c,e,s) => const Icon(Icons.auto_awesome, size: 16),
                 ),
               ),
             ),
             const SizedBox(width: 8),
             
             Text(
               message.modelName ?? "SkyGen", 
               style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)
             ),
             
             // INLINE THINKING DOTS
             if (isWaiting) ...[
                const SizedBox(width: 10),
                const TypingIndicator(isRed: false), 
             ],

             const Spacer(),
             
             // TTS VOLUME BUTTON
             if (message.status == GenStatus.completed && message.text.isNotEmpty && message.imageUrl == null)
               GestureDetector(
                 onTap: () => onSpeak(message.id, message.text),
                 child: Padding(
                   padding: const EdgeInsets.only(right: 16),
                   child: message.isTTSLoading
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(
                          isPlayingTTS ? Icons.pause_circle_filled : Icons.volume_up_rounded,
                          color: isPlayingTTS ? const Color(0xFF007AFF) : Colors.grey[400],
                          size: 18,
                        ),
                 ),
               ),
           ],
        ),

        const SizedBox(height: 6),

        // CONTENT (Left Aligned, No heavy indent)
        Padding(
          padding: const EdgeInsets.only(left: 4), // Minimal padding to align with Icon flow
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Image Result
              if (message.status == GenStatus.generating && message.modelName!.contains("Img"))
                 _buildShimmerPlaceholder()
              else if (message.imageUrl != null)
                _buildImagePreview(context, message.imageUrl!),

              // 2. Video Result
              if (message.status == GenStatus.generating && message.modelName!.contains("Video"))
                 _buildShimmerPlaceholder()
              else if (message.videoPath != null)
                _buildVideoPreview(context, message.videoPath!),

              // 3. Music Result
              if (message.status == GenStatus.generating && message.modelName!.contains("Music"))
                 _buildMusicSkeleton()
              else if (message.musicResults != null)
                Wrap(
                  spacing: 10, runSpacing: 10,
                  children: message.musicResults!.map((m) => MusicCard(music: m, onToast: onToast)).toList(),
                ),

              // 4. Text Content (Markdown)
              if (message.visibleText.isNotEmpty && message.imageUrl == null && message.videoPath == null)
                Container(
                   margin: const EdgeInsets.only(top: 4),
                   constraints: const BoxConstraints(maxWidth: 340), // Slightly wider
                   child: MarkdownBody(
                     data: message.visibleText,
                     selectable: false, // Selection disabled (use Copy overlay)
                     builders: {
                       'code': CodeBlockBuilder(onToast),
                     },
                     styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                       p: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.5),
                       code: const TextStyle(fontFamily: 'monospace', backgroundColor: Color(0xFFF4F4F4), color: Colors.redAccent),
                       codeblockDecoration: BoxDecoration(
                          color: const Color(0xFF282C34),
                          borderRadius: BorderRadius.circular(8),
                       ),
                     ),
                   ),
                ),
              
              // 5. Error
              if (message.status == GenStatus.error)
                 Container(
                   padding: const EdgeInsets.all(10),
                   decoration: BoxDecoration(color: Colors.red[50], borderRadius: BorderRadius.circular(8)),
                   child: Text(message.text, style: TextStyle(color: Colors.red[800])),
                 ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShimmerPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.white,
      child: Container(
        width: 250, height: 250,
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
      highlightColor: Colors.white,
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
      width: 250, height: 250, 
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => FullScreenViewer(
                item: {'type': 'image', 'url': url},
                onToast: onToast,
                onGoToChat: onGoToChat,
              )
            )),
            child: Hero(
              tag: url,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  width: 250, height: 250,
                  placeholder: (c,u) => _buildShimmerPlaceholder(),
                  errorWidget: (c,u,e) => const Icon(Icons.broken_image),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8, right: 8,
            child: DownloadButton(url: url, onToast: onToast),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview(BuildContext context, String videoPath) {
    return Container(
      width: 250, height: 250,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(Icons.movie_creation_outlined, size: 60, color: Colors.white24),
          
          GestureDetector(
            onTap: () {
               Navigator.push(context, MaterialPageRoute(
                  builder: (_) => FullScreenViewer(
                    item: {'type': 'video', 'url': videoPath},
                    onToast: onToast,
                    onGoToChat: onGoToChat,
                  )
                ));
            },
            child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 50),
          ),
        ],
      ),
    );
  }
}

// ==============================================================================
// 5. HELPER WIDGETS (MUSIC, DOWNLOAD, TYPING)
// ==============================================================================

class MusicCard extends StatefulWidget {
  final Map<String, dynamic> music;
  final Function(String, {bool isError}) onToast;
  const MusicCard({super.key, required this.music, required this.onToast});

  @override
  State<MusicCard> createState() => _MusicCardState();
}

class _MusicCardState extends State<MusicCard> {
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
      width: 300,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 5)],
      ),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _togglePlay,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: widget.music['cover_url'],
                        width: 50, height: 50, fit: BoxFit.cover,
                        errorWidget: (c,u,e) => Container(color: Colors.grey, width: 50, height: 50),
                      ),
                    ),
                    Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.music['title'] ?? "Song", style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(widget.music['style'] ?? "Generated", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              DownloadButton(url: widget.music['audio_url'], onToast: widget.onToast),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                child: Icon(_isExpanded ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right, color: Colors.grey),
              ),
            ],
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(widget.music['lyrics'], style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}

class DownloadButton extends StatefulWidget {
  final String url;
  final Function(String, {bool isError}) onToast;
  
  const DownloadButton({super.key, required this.url, required this.onToast});

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _isLoading = false;

  Future<void> _saveFile() async {
    setState(() => _isLoading = true);
    
    // Strict Permission Logic
    bool granted = false;
    if (Platform.isAndroid) {
       if (await Permission.storage.request().isGranted) granted = true;
       else if (await Permission.manageExternalStorage.request().isGranted) granted = true;
       else if (await Permission.photos.request().isGranted && await Permission.videos.request().isGranted) granted = true;
    } else granted = true;

    if (!granted) {
      widget.onToast("Permission Denied. Please allow storage access.", isError: true);
      setState(() => _isLoading = false);
      openAppSettings();
      return;
    }

    try {
      Directory? saveDir;
      if (Platform.isAndroid) {
        saveDir = Directory('/storage/emulated/0/SkyGen');
        if (!await saveDir.exists()) {
           try {
             await saveDir.create(recursive: true);
           } catch (e) {
             saveDir = Directory('/storage/emulated/0/Documents/SkyGen');
             await saveDir.create(recursive: true);
           }
        }
      } else {
        saveDir = await getApplicationDocumentsDirectory();
      }

      String ext = "png";
      if (widget.url.endsWith("mp4")) ext = "mp4";
      if (widget.url.endsWith("mp3")) ext = "mp3";
      
      final fileName = "SkyGen_${DateTime.now().millisecondsSinceEpoch}.$ext";
      final file = File("${saveDir.path}/$fileName");
      
      if (widget.url.startsWith('/')) {
        await File(widget.url).copy(file.path);
      } else {
        final res = await http.get(Uri.parse(widget.url));
        await file.writeAsBytes(res.bodyBytes);
      }

      widget.onToast("Saved successfully"); 
    } catch (e) {
      widget.onToast("Save Failed: $e", isError: true);
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _isLoading ? null : _saveFile,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
        child: _isLoading 
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.download_rounded, color: Colors.white, size: 16),
      ),
    );
  }
}

class TypingIndicator extends StatefulWidget {
  final bool isRed;
  const TypingIndicator({super.key, required this.isRed});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();
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
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (_, __) {
               final val = sin((_controller.value * 2 * pi) + i);
               return Container(
                 margin: const EdgeInsets.only(right: 3),
                 width: 6, height: 6,
                 decoration: BoxDecoration(
                   color: widget.isRed ? Colors.red : Colors.grey.withOpacity(0.5 + (val * 0.3)),
                   shape: BoxShape.circle,
                 ),
               );
            },
          );
        }),
      ),
    );
  }
}

// ==============================================================================
// 6. FULL SCREEN VIEWER & MY STUFF
// ==============================================================================

class FullScreenViewer extends StatefulWidget {
  final Map<String, dynamic> item; 
  final Function(String, {bool isError}) onToast;
  final Function(String) onGoToChat;
  final bool isLocal;
  final bool hideActions;

  const FullScreenViewer({
    super.key,
    required this.item,
    required this.onToast,
    required this.onGoToChat,
    this.isLocal = false,
    this.hideActions = false,
  });

  @override
  State<FullScreenViewer> createState() => _FullScreenViewerState();
}

class _FullScreenViewerState extends State<FullScreenViewer> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isVideo = false;

  @override
  void initState() {
    super.initState();
    _isVideo = widget.item['type'] == 'video';
    if (_isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final path = widget.item['url'];
    if (path.startsWith('/') || widget.isLocal) {
       _videoController = VideoPlayerController.file(File(path));
    } else {
       _videoController = VideoPlayerController.networkUrl(Uri.parse(path));
    }

    await _videoController!.initialize();
    _chewieController = ChewieController(
      videoPlayerController: _videoController!,
      autoPlay: true,
      looping: true,
      showOptions: false, 
      allowFullScreen: false,
    );
    setState(() {});
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String displayUrl = widget.item['type'] == 'music' ? widget.item['cover_url'] : widget.item['url'];
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _isVideo
                ? (_chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
                    ? Chewie(controller: _chewieController!)
                    : const CircularProgressIndicator(color: Colors.white))
                : InteractiveViewer(
                    child: widget.isLocal 
                        ? Image.file(File(displayUrl))
                        : CachedNetworkImage(imageUrl: displayUrl),
                  ),
          ),
          
          Positioned(
            top: 40, right: 20,
            child: Row(
              children: [
                if (!widget.hideActions && !widget.isLocal)
                  _circleBtn(Icons.chat_bubble, () => widget.onGoToChat(displayUrl)),
                if (!widget.hideActions) 
                   const SizedBox(width: 15),
                if (!widget.hideActions)
                   DownloadButton(url: widget.item['url'], onToast: widget.onToast),
                const SizedBox(width: 15),
                _circleBtn(Icons.close, () => Navigator.pop(context)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class MyStuffPage extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Function(String) onGoToChat;
  final Function(String, {bool isError}) onToast;

  const MyStuffPage({super.key, required this.items, required this.onGoToChat, required this.onToast});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Stuff")),
      body: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
           crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          final isVideo = item['type'] == 'video';
          final isMusic = item['type'] == 'music';
          final url = isMusic ? item['cover_url'] : item['url'];
          final thumb = item['thumbnail'];

          return GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
               builder: (_) => FullScreenViewer(item: item, onToast: onToast, onGoToChat: onGoToChat))),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: isVideo && thumb != null
                     ? Image.file(File(thumb), fit: BoxFit.cover)
                     : CachedNetworkImage(
                         imageUrl: url ?? "", 
                         fit: BoxFit.cover,
                         placeholder: (c,u) => Container(color: Colors.grey[200]),
                       ),
                ),
                if (isVideo) const Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 30)),
                if (isMusic) const Center(child: Icon(Icons.music_note, color: Colors.white, size: 30)),
                
                // Type Badge
                Positioned(
                  top: 4, right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                    child: Icon(
                      isVideo ? Icons.videocam : (isMusic ? Icons.music_note : Icons.image),
                      color: Colors.white, size: 10,
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

// ==============================================================================
// 7. CODE BLOCK WIDGET (Markdown)
// ==============================================================================

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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF282C34),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
               color: Color(0xFF21252B),
               borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(language.toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: element.textContent));
                    onToast("Code copied");
                  },
                  child: const Row(
                    children: [Icon(Icons.copy, color: Colors.grey, size: 12), SizedBox(width: 4), Text("Copy", style: TextStyle(color: Colors.grey, fontSize: 10))],
                  ),
                )
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              element.textContent,
              language: language.isEmpty ? 'plaintext' : language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(12),
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
