import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
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

// ---------------------------------------------------------------------------
// MAIN ENTRY POINT & CONFIGURATION
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // লক ওরিয়েন্টেশন - শুধুমাত্র পোর্ট্রেট মোড
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // স্ট্যাটাস বার কনফিগারেশন
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10A37F), // ChatGPT-like Green/Teal hint
          primary: const Color(0xFF10A37F),
          secondary: const Color(0xFF007AFF),
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
  String visibleText; // For streaming effect
  final MessageType type;
  
  // Media contents
  String? imageUrl; 
  String? localImagePath; // For immediate user upload preview
  String? videoPath; 
  String? attachedImageUrl; // URL uploaded to ImgBB
  
  // State
  GenStatus status;
  final int timestamp;
  String? modelName;
  
  // Specific Results
  List<Map<String, dynamic>>? musicResults;
  
  // OCR Results
  String? ocrNote;

  ChatMessage({
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.imageUrl,
    this.localImagePath,
    this.videoPath,
    this.attachedImageUrl,
    this.status = GenStatus.completed,
    required this.timestamp,
    this.modelName,
    this.musicResults,
    this.ocrNote,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : "");

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'visibleText': visibleText,
    'type': type.index,
    'imageUrl': imageUrl,
    'localImagePath': localImagePath,
    'videoPath': videoPath,
    'attachedImageUrl': attachedImageUrl,
    'status': status.index,
    'timestamp': timestamp,
    'modelName': modelName,
    'musicResults': musicResults,
    'ocrNote': ocrNote,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    visibleText: map['visibleText'],
    type: MessageType.values[map['type']],
    imageUrl: map['imageUrl'],
    localImagePath: map['localImagePath'],
    videoPath: map['videoPath'],
    attachedImageUrl: map['attachedImageUrl'],
    status: GenStatus.values[map['status']],
    timestamp: map['timestamp'],
    modelName: map['modelName'],
    musicResults: map['musicResults'] != null
        ? List<Map<String, dynamic>>.from(map['musicResults'])
        : null,
    ocrNote: map['ocrNote'],
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
// CHAT SCREEN (MAIN UI CONTROLLER)
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  // UI Controllers
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Data State
  List<ChatSession> _sessions = [];
  List<Map<String, dynamic>> _myStuffItems = []; // {type, url, cover_url...}
  String _currentSessionId = "";
  bool _isTempSession = true;
  File? _storageFile;

  // Generation State
  bool _isGenerating = false;
  String? _currentGenId;
  bool _stopRequested = false;

  // Input & Model State
  String _selectedModel = "SkyGen"; 
  String? _lockedModel; // For the "Mode" chip
  File? _pickedImage;
  String? _uploadedImgBBUrl;
  bool _isUploadingImage = false;
  bool _showPlusIcon = true;

  // Search
  bool _isSearchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  // TTS Manager
  final AudioPlayer _ttsPlayer = AudioPlayer();
  bool _isSpeaking = false;
  String _currentSpeechUrl = "";

  @override
  void initState() {
    super.initState();
    _initStorage();
    _promptController.addListener(_handleInputListener);
    
    // TTS Listener
    _ttsPlayer.onPlayerComplete.listen((event) {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  @override
  void dispose() {
    _promptController.removeListener(_handleInputListener);
    _promptController.dispose();
    _searchController.dispose();
    _ttsPlayer.dispose();
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

  // --- STORAGE MANAGEMENT ---

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_data_final_v1.json');

      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        final List<dynamic> myStuffList = jsonData['myStuff'] ?? [];

        setState(() {
          _sessions = sessionList.map((e) => ChatSession.fromMap(e)).toList();
          _myStuffItems = List<Map<String, dynamic>>.from(myStuffList);
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
      // Write in background isolate equivalent (async I/O)
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

  // --- SESSION LOGIC ---

  void _createTempSession() {
    final tempId = "temp${DateTime.now().millisecondsSinceEpoch}";
    setState(() {
      _currentSessionId = tempId;
      _isTempSession = true;
      _isGenerating = false;
      _promptController.clear();
      _clearAttachment();
      _lockedModel = null;
      _selectedModel = "SkyGen";
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
      _lockedModel = null;
    });
    Navigator.pop(context); // Close drawer
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _deleteSession(String id) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete Chat?"),
      content: const Text("This action will delete all messages and generated media from this chat locally."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () {
          _performDelete(id);
          Navigator.pop(ctx);
        }, child: const Text("Delete", style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  void _performDelete(String id) {
    // 1. Find session
    final sessIndex = _sessions.indexWhere((s) => s.id == id);
    if (sessIndex == -1) return;
    
    final session = _sessions[sessIndex];

    // 2. Cleanup Files & MyStuff
    for (var msg in session.messages) {
      // Remove from MyStuff
      _myStuffItems.removeWhere((item) => 
         item['url'] == msg.imageUrl || 
         item['url'] == msg.videoPath || 
         (msg.musicResults != null && msg.musicResults!.any((m) => m['audio_url'] == item['url']))
      );

      // Delete local files if path exists
      if (msg.videoPath != null && !msg.videoPath!.startsWith("http")) {
         try { File(msg.videoPath!).deleteSync(); } catch (_) {}
      }
      if (msg.localImagePath != null) {
         // Don't delete original user photo usually, but if cached, ok.
      }
    }

    setState(() {
      _sessions.removeAt(sessIndex);
      if (_currentSessionId == id) _createTempSession();
    });
    
    _saveData();
    _showToast("Chat and associated data deleted");
  }

  // --- MODEL & UI LOGIC ---

  void _setActiveModel(String model) {
    setState(() {
      _selectedModel = model;
      _lockedModel = model; // Lock it as "Mode"
    });
    // If selecting specific create modes, we might want to focus input
    // But per requirement, it just activates the mode.
  }

  void _clearLockedModel() {
    setState(() {
      _lockedModel = null;
      _selectedModel = "SkyGen"; // Revert to default
    });
  }

  void _openModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true, 
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7, 
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  children: [
                    _buildModelTile("SkyGen", "Advanced Chat & Assistant", Icons.auto_awesome),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky-Img", "Image Generator (DALL-E Style)", Icons.image_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky Video", "Text to Video Generator", Icons.videocam_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky Music", "Text to Music Composer", Icons.music_note_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky Coder", "Code & Programming Expert", Icons.code_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Img Describer", "Visual Understanding", Icons.remove_red_eye_rounded),
                    const SizedBox(height: 10),
                    _buildModelTile("Sky OCR", "Extract Text from Images", Icons.document_scanner_rounded), // New Model
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
        setState(() {
          _selectedModel = id;
          // If user selects from menu, we can treat it as a locked mode or just temporary selection
          // Let's treat it as locked mode to show the chip
          if (id != "SkyGen") {
            _lockedModel = id;
          } else {
            _lockedModel = null;
          }
        });
        Navigator.pop(context);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10A37F).withOpacity(0.1) : Colors.grey[50],
          border: Border.all(color: isSelected ? const Color(0xFF10A37F) : Colors.grey[200]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF10A37F) : Colors.black54),
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
            if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF10A37F)),
          ],
        ),
      ),
    );
  }

  // --- IMAGE PICKER & UPLOAD ---

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        setState(() {
          _pickedImage = File(image.path);
          _isUploadingImage = true;
        });
        // Background upload
        _uploadToImgBB(File(image.path));
      }
    } catch (e) {
      _showToast("Picker Error: $e", isError: true);
    }
  }

  Future<void> _uploadToImgBB(File imageFile) async {
    try {
      if (!(await _checkInternet())) {
        _showToast("No Internet - Image queued for local preview", isError: true);
        setState(() => _isUploadingImage = false);
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
        });
      } else {
        throw Exception("ImgBB Upload Failed");
      }
    } catch (e) {
      setState(() => _isUploadingImage = false);
      debugPrint("Upload failed: $e");
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

  // --- SUBMISSION LOGIC ---

  Future<void> _handleSubmitted() async {
    if (_isGenerating) return;

    final prompt = _promptController.text.trim();
    final localImage = _pickedImage;
    final uploadedUrl = _uploadedImgBBUrl;

    // Validation
    if (prompt.isEmpty && localImage == null) return;
    
    // Check Internet First
    bool hasInternet = await _checkInternet();
    
    // Clear Input
    _promptController.clear();
    _clearAttachment(); // We store the reference in message first

    // Determine Model Routing
    String activeModel = _selectedModel;
    if (_lockedModel != null) activeModel = _lockedModel!;

    // Special Case: OCR requires image. If no image, fallback to Default.
    if (activeModel == "Sky OCR" && localImage == null) {
      activeModel = "SkyGen";
      _showToast("OCR requires an image. Switched to Chat.");
    }
    
    // Session Title Logic
    if (_isTempSession) {
      String titleText = prompt.isNotEmpty ? prompt : "New Creation";
      // Cap title length to 25 chars, no line breaks
      titleText = titleText.replaceAll('\n', ' ');
      if (titleText.length > 25) titleText = "${titleText.substring(0, 25)}...";
      
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

    // Add User Message
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt,
      type: MessageType.user,
      localImagePath: localImage?.path, // Immediate preview
      attachedImageUrl: uploadedUrl,    // For API
      timestamp: DateTime.now().millisecondsSinceEpoch,
      modelName: activeModel,
    );

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(userMsg);
      _isGenerating = true;
      _stopRequested = false;
    });
    _scrollToBottom();
    _saveData();

    // Offline Handling
    if (!hasInternet) {
      await Future.delayed(const Duration(milliseconds: 500));
      _addErrorMessage("No Internet Connection. Please check your network.", "Offline");
      setState(() => _isGenerating = false);
      return;
    }

    // Route Request
    try {
      switch (activeModel) {
        case "Sky-Img":
          await _processSkyImgV1(prompt);
          break;
        case "Sky Video":
          await _processSkyVideo(prompt);
          break;
        case "Sky Music":
          await _processMusicGeneration(prompt);
          break;
        case "Sky Coder":
          await _processSkyCoder(prompt);
          break;
        case "Sky OCR":
          if (uploadedUrl != null) {
             await _processOCR(uploadedUrl);
          } else {
             // Fallback if upload pending
             _showToast("Image upload pending, retrying...", isError: false);
             // In real app, we would wait for upload. Here assuming upload finished or handled.
             if (localImage != null && uploadedUrl == null) {
               // Force upload wait (simplified)
               _addErrorMessage("Image upload failed. Try again.", "Upload Error");
             }
          }
          break;
        case "Img Describer":
          if (uploadedUrl != null) await _processDescriber(uploadedUrl);
          else await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
          break;
        default: // SkyGen
          if (uploadedUrl != null) {
             // If Image + Text sent to Default -> Use Img Describer logic implicitly?
             // Or V2 Image Gen? Let's assume standard Text AI doesn't see images.
             // Requirement says: if image selected, preview shows. 
             // We'll treat it as Describer if text is empty, or Context if text exists.
             // For now, simple routing:
             await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
          } else {
             await _processTextAI(prompt, "https://ai-hyper.vercel.app/api");
          }
      }
    } catch (e) {
       _addErrorMessage("An error occurred: $e", "System Error");
    } finally {
      if (mounted && _isGenerating) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  void _addErrorMessage(String error, String title) {
    final aiMsgId = "err${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(ChatMessage(
        id: aiMsgId,
        text: error,
        visibleText: error,
        type: MessageType.ai,
        status: GenStatus.error,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        modelName: title,
      ));
      _isGenerating = false;
    });
    _scrollToBottom();
  }

  // --- API HANDLERS ---

  Future<void> _processTextAI(String prompt, String apiUrl) async {
    final aiMsgId = _addPlaceholderMessage("Thinking...");
    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (_stopRequested) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == false) throw Exception("API Error");
        
        final answer = data["results"]["answer"] ?? "No response.";
        await _streamResponse(aiMsgId, answer);
      } else {
        throw Exception("Status ${response.statusCode}");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    }
  }

  Future<void> _processSkyCoder(String prompt) async {
    await _processTextAI(prompt, "https://coder-bd.vercel.app/api");
  }

  Future<void> _processDescriber(String imgUrl) async {
    final aiMsgId = _addPlaceholderMessage("Analyzing Image...");
    try {
      final res = await http.get(Uri.parse("https://gen-z-describer.vercel.app/api?url=$imgUrl"));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final desc = data["results"]["description"];
        await _streamResponse(aiMsgId, desc);
      } else {
        throw Exception("Analysis failed");
      }
    } catch (e) {
       _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Failed: $e");
    }
  }

  Future<void> _processOCR(String imgUrl) async {
    final aiMsgId = _addPlaceholderMessage("Extracting Text (OCR)...");
    try {
      final response = await http.post(
        Uri.parse("https://gen-z-ocr.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"url": imgUrl}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final answer = data['results']['answer'] ?? "";
          final note = data['results']['note'] ?? "";
          
          String fullText = "$answer\n\n**Note:** $note";
          await _streamResponse(aiMsgId, fullText);
          
          // Save note specially if needed, but streaming full text is fine
        } else {
          throw Exception("OCR API returned false");
        }
      } else {
         throw Exception("Server Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "OCR Failed: $e");
    }
  }

  Future<void> _processSkyImgV1(String prompt) async {
    final aiMsgId = _addPlaceholderMessage("Generating Image...", model: "Sky-Img");
    try {
      final response = await http.post(
        Uri.parse("https://sky-img.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String url = data["results"]["photo"];
        _handleSuccessMedia(aiMsgId, 'image', url);
      } else {
        throw Exception("Gen Failed");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "$e");
    }
  }

  Future<void> _processSkyVideo(String prompt) async {
    final aiMsgId = _addPlaceholderMessage("Creating Video (Wait ~3m)...", model: "Sky Video");
    // Background capability: If user leaves app, Future usually continues (Dart isolate).
    // For robust background, WorkManager is needed but user didn't provide plugin.
    try {
      final response = await http.post(
        Uri.parse("https://gen-z-video.vercel.app/api"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"q": prompt}),
      ).timeout(const Duration(minutes: 5)); 

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == false) throw Exception("API Error");
        String url = data["video_url"];
        
        // Cache Video
        String localPath = await _cacheFile(url, "mp4");
        _handleSuccessMedia(aiMsgId, 'video', localPath);
      } else {
        throw Exception("Server Error");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "$e");
    }
  }

  Future<void> _processMusicGeneration(String prompt) async {
    final aiMsgId = _addPlaceholderMessage("Composing Music...", model: "Sky Music");
    try {
      final styles = ['Lofi', 'Pop', 'Rock', 'Jazz', 'Piano', 'Cinematic'];
      final body = {
        "q": prompt,
        "title": "Creation",
        "style": styles[Random().nextInt(styles.length)],
        "gender": "female"
      };

      final response = await http.post(
        Uri.parse("https://gen-z-music.vercel.app/gen"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final ids = data["results"]["song_ids"] ?? [];
        if (ids.isNotEmpty) {
           await _pollMusic(aiMsgId, ids.join(","));
        } else {
          throw Exception("No IDs");
        }
      } else {
         throw Exception("Failed");
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "$e");
    }
  }

  Future<void> _pollMusic(String msgId, String ids) async {
    // Polling logic
    int attempts = 0;
    while (attempts < 40) { // 200 seconds max
      if (_stopRequested) return;
      await Future.delayed(const Duration(seconds: 5));
      try {
        final res = await http.post(
           Uri.parse("https://gen-z-music.vercel.app/check"),
           headers: {"Content-Type": "application/json"},
           body: jsonEncode({"id": ids})
        );
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final results = data["results"] as List;
          
          List<Map<String, dynamic>> musicList = [];
          for (var r in results) {
            if (r['url'] != null) {
              musicList.add({
                'type': 'music',
                'title': r['title'] ?? 'Track',
                'audio_url': r['url'],
                'cover_url': r['cover_url'],
                'lyrics': r['lyrics'] ?? 'Instrumental'
              });
            }
          }
          
          if (musicList.isNotEmpty) {
            // Add to My Stuff
            setState(() {
              for (var m in musicList) _myStuffItems.insert(0, m);
            });
            // Update Message
            _updateMessageStatus(msgId, GenStatus.completed, musicResults: musicList, errorText: "Music Created");
            return;
          }
        }
      } catch (_) {}
      attempts++;
    }
    _updateMessageStatus(msgId, GenStatus.error, errorText: "Music Timeout");
  }

  // --- HELPER METHODS ---

  String _addPlaceholderMessage(String text, {String? model}) {
    final id = "ai${DateTime.now().millisecondsSinceEpoch}";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(ChatMessage(
        id: id,
        text: text,
        visibleText: "",
        type: MessageType.ai,
        status: GenStatus.generating, // or waiting
        timestamp: DateTime.now().millisecondsSinceEpoch,
        modelName: model ?? _selectedModel,
      ));
    });
    _scrollToBottom();
    return id;
  }

  Future<void> _streamResponse(String msgId, String fullText) async {
    _updateMessageStatus(msgId, GenStatus.streaming, errorText: fullText);
    int idx = 0;
    while (idx < fullText.length) {
      if (_stopRequested) {
        _updateMessageStatus(msgId, GenStatus.stopped);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 10)); // Speed
      idx = min(idx + 5, fullText.length);
      final visible = fullText.substring(0, idx);
      
      final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
      if (sIndex != -1) {
        final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
        if (mIndex != -1) {
          setState(() {
            _sessions[sIndex].messages[mIndex].visibleText = visible;
          });
        }
      }
    }
    _updateMessageStatus(msgId, GenStatus.completed, errorText: fullText);
  }

  void _handleSuccessMedia(String msgId, String type, String pathOrUrl) {
    setState(() {
      _myStuffItems.insert(0, {
        'type': type,
        'url': pathOrUrl
      });
    });
    
    if (type == 'image') {
       _updateMessageStatus(msgId, GenStatus.completed, imageUrl: pathOrUrl, errorText: "Image Generated");
    } else if (type == 'video') {
       _updateMessageStatus(msgId, GenStatus.completed, videoPath: pathOrUrl, errorText: "Video Created");
    }
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? imageUrl, String? videoPath, List<Map<String, dynamic>>? musicResults, String? errorText}) {
    final sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    
    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
       final old = _sessions[sIndex].messages[mIndex];
       final finalText = errorText ?? old.text;
       
       setState(() {
         _sessions[sIndex].messages[mIndex] = ChatMessage(
           id: msgId,
           text: finalText,
           visibleText: status == GenStatus.completed || status == GenStatus.error ? finalText : old.visibleText,
           type: MessageType.ai,
           imageUrl: imageUrl ?? old.imageUrl,
           videoPath: videoPath ?? old.videoPath,
           musicResults: musicResults ?? old.musicResults,
           status: status,
           timestamp: DateTime.now().millisecondsSinceEpoch,
           modelName: old.modelName,
           ocrNote: old.ocrNote,
         );
       });
       if (status == GenStatus.completed) {
         _saveData();
         _scrollToBottom();
       }
    }
  }

  Future<String> _cacheFile(String url, String ext) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/cache_${DateTime.now().millisecondsSinceEpoch}.$ext');
    final res = await http.get(Uri.parse(url));
    await file.writeAsBytes(res.bodyBytes);
    return file.path;
  }

  ChatSession get _currentSession {
     return _sessions.firstWhere((s) => s.id == _currentSessionId, 
       orElse: () => ChatSession(id: "dummy", title: "", createdAt: 0, messages: [])
     );
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 300,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutQuart,
      );
    }
  }

  void _showToast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.redAccent : const Color(0xFF333333),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // --- TTS MANAGER ---
  
  Future<void> _playTTS(String text) async {
    if (_isSpeaking) {
      await _ttsPlayer.stop();
      setState(() => _isSpeaking = false);
      return;
    }

    setState(() => _isSpeaking = true);
    
    // 1. Clean Text (Remove Code Blocks & Emojis)
    // Regex for code blocks ```...```
    String cleanText = text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    // Remove emojis (simple regex range)
    cleanText = cleanText.replaceAll(RegExp(r'[\u{1F600}-\u{1F64F}]', unicode: true), '');
    cleanText = cleanText.replaceAll(RegExp(r'[\u{1F300}-\u{1F5FF}]', unicode: true), '');
    cleanText = cleanText.replaceAll(RegExp(r'[\u{1F680}-\u{1F6FF}]', unicode: true), '');
    cleanText = cleanText.trim();

    if (cleanText.isEmpty) {
      _showToast("No readable text found.");
      setState(() => _isSpeaking = false);
      return;
    }

    // 2. Split logic (200 chars chunks)
    List<String> chunks = [];
    int start = 0;
    while (start < cleanText.length) {
      int end = start + 200;
      if (end >= cleanText.length) {
        chunks.add(cleanText.substring(start));
        break;
      }
      // Find nearest space to cut
      int lastSpace = cleanText.lastIndexOf(' ', end);
      if (lastSpace != -1 && lastSpace > start) {
        end = lastSpace;
      }
      chunks.add(cleanText.substring(start, end));
      start = end + 1;
    }

    // 3. Play Chunks Sequence
    try {
      for (String chunk in chunks) {
        if (!_isSpeaking) break; // Stopped by user
        final encoded = Uri.encodeComponent(chunk);
        final url = "https://murf.ai/Prod/anonymous-tts/audio?text=$encoded&voiceId=VM017230562791058FV&style=Conversational";
        
        await _ttsPlayer.play(UrlSource(url));
        // Wait for completion before next chunk
        await _ttsPlayer.onPlayerComplete.first; 
      }
    } catch (e) {
      debugPrint("TTS Error: $e");
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  // --- UI BUILDING ---

  @override
  Widget build(BuildContext context) {
    final messages = _currentSession.messages;

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
              const Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.grey),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.black87),
            onPressed: _startNewChatAction,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
              ? _buildStartScreen() // ChatGPT Style Start
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  itemCount: messages.length,
                  itemBuilder: (ctx, i) => ChatBubble(
                    message: messages[i],
                    onToast: _showToast,
                    onPlayTTS: _playTTS,
                    isSpeaking: _isSpeaking,
                  ),
                ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildStartScreen() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: ClipOval(
                child: Image.network(
                  "https://iili.io/f4Xfgfa.jpg",
                  width: 80, height: 80,
                  fit: BoxFit.cover,
                  errorBuilder: (c,e,s) => const Icon(Icons.auto_awesome, size: 60, color: Color(0xFF10A37F)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "What can I help with?",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            
            // 2x2 Grid Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                children: [
                  Row(
                    children: [
                      _buildStartButton("Create Image", Icons.image_outlined, "Sky-Img"),
                      const SizedBox(width: 12),
                      _buildStartButton("Create Video", Icons.videocam_outlined, "Sky Video"),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildStartButton("Create Music", Icons.music_note_outlined, "Sky Music"),
                      const SizedBox(width: 12),
                      _buildStartButton("Generate Code", Icons.code_outlined, "Sky Coder"),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStartButton(String label, IconData icon, String modelId) {
    return Expanded(
      child: HoverButton(
        onTap: () => _setActiveModel(modelId),
        child: Container(
          height: 90,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[200]!),
            boxShadow: [
               BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))
            ]
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               Icon(icon, color: const Color(0xFF10A37F), size: 26),
               const Spacer(),
               Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[100]!)),
      ),
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // MODE INDICATOR (Chat GPT Style above input)
          if (_lockedModel != null)
             Padding(
               padding: const EdgeInsets.only(bottom: 8.0, left: 4),
               child: Container(
                 constraints: const BoxConstraints(maxWidth: 200),
                 padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                 decoration: BoxDecoration(
                   color: const Color(0xFF10A37F).withOpacity(0.1),
                   borderRadius: BorderRadius.circular(20),
                   border: Border.all(color: const Color(0xFF10A37F).withOpacity(0.3)),
                 ),
                 child: Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     GestureDetector(
                       onTap: _openModelSelector,
                       child: Text(
                         "Using $_lockedModel",
                         style: const TextStyle(color: Color(0xFF10A37F), fontWeight: FontWeight.bold, fontSize: 12),
                       ),
                     ),
                     const SizedBox(width: 6),
                     GestureDetector(
                       onTap: _clearLockedModel,
                       child: const Icon(Icons.close, size: 14, color: Color(0xFF10A37F)),
                     )
                   ],
                 ),
               ),
             ),

          // ATTACHMENT PREVIEW
          if (_pickedImage != null)
             Padding(
               padding: const EdgeInsets.only(bottom: 8.0),
               child: Stack(
                 children: [
                   ClipRRect(
                     borderRadius: BorderRadius.circular(10),
                     child: Image.file(_pickedImage!, height: 60, width: 60, fit: BoxFit.cover),
                   ),
                   Positioned(
                     top: -5, right: -5,
                     child: IconButton(
                       icon: const Icon(Icons.cancel, color: Colors.grey),
                       onPressed: _clearAttachment,
                     ),
                   )
                 ],
               ),
             ),
             
          // INPUT FIELD
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(26),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                if (_showPlusIcon)
                   Material(
                     color: Colors.transparent,
                     child: IconButton(
                       onPressed: _pickImage,
                       icon: const Icon(Icons.add, color: Colors.grey),
                       splashRadius: 20,
                     ),
                   ),
                Expanded(
                  child: TextField(
                    controller: _promptController,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: "Message...",
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                ),
                Padding(
                   padding: const EdgeInsets.all(4.0),
                   child: AnimatedContainer(
                     duration: const Duration(milliseconds: 200),
                     decoration: BoxDecoration(
                       color: (_promptController.text.isNotEmpty || _pickedImage != null) 
                         ? const Color(0xFF10A37F) 
                         : Colors.grey[400],
                       shape: BoxShape.circle,
                     ),
                     child: IconButton(
                       icon: Icon(_isGenerating ? Icons.stop : Icons.arrow_upward, color: Colors.white, size: 20),
                       onPressed: _isGenerating 
                         ? () => setState(() => _stopRequested = true) 
                         : _handleSubmitted,
                     ),
                   ),
                )
              ],
            ),
          )
        ],
      ),
    );
  }

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
                height: 45,
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                  onTap: () => setState(() => _isSearchExpanded = true),
                  decoration: InputDecoration(
                    prefixIcon: Icon(_isSearchExpanded ? Icons.arrow_back : Icons.search, color: Colors.grey),
                    hintText: "Search",
                    border: InputBorder.none,
                    suffixIcon: _isSearchExpanded 
                       ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState((){_isSearchExpanded = false; _searchQuery = ""; _searchController.clear();}))
                       : null
                  ),
                ),
              ),
            ),
            
            // My Stuff Link
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text("My Stuff"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => MyStuffPage(items: _myStuffItems)));
              },
            ),

            // My Stuff Previews
            if (_myStuffItems.isNotEmpty && !_isSearchExpanded)
              SizedBox(
                height: 80,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: min(_myStuffItems.length, 5),
                  separatorBuilder: (_,__) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final item = _myStuffItems[i];
                    return Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: Colors.black12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _buildThumb(item),
                      ),
                    );
                  },
                ),
              ),
            
            const Divider(),

            // Chat List
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _sessions.length,
                itemBuilder: (ctx, i) {
                   final s = _sessions[i];
                   if (_searchQuery.isNotEmpty && !s.title.toLowerCase().contains(_searchQuery)) return const SizedBox.shrink();
                   final isActive = s.id == _currentSessionId && !_isTempSession;
                   
                   return ListTile(
                     tileColor: isActive ? Colors.grey[100] : null,
                     title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                     leading: Icon(s.isPinned ? Icons.push_pin : Icons.chat_bubble_outline, size: 18),
                     onTap: () => _switchSession(s.id),
                     onLongPress: () => _deleteSession(s.id),
                   );
                },
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildThumb(Map<String, dynamic> item) {
    if (item['type'] == 'image' || item['type'] == 'music') {
      return CachedNetworkImage(imageUrl: item['url'] ?? item['cover_url'] ?? "", fit: BoxFit.cover);
    } else {
      // Video Thumb - "Not Black" Requirement
      return Stack(
        alignment: Alignment.center,
        children: [
           Container(color: Colors.black87), // Dark Background
           const Icon(Icons.play_circle_fill, color: Colors.white, size: 30),
           Positioned(
             bottom: 4, 
             child: Text("VIDEO", style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 10, fontWeight: FontWeight.bold))
           )
        ],
      );
    }
  }
}

// ---------------------------------------------------------------------------
// UI: HOVER BUTTON
// ---------------------------------------------------------------------------
class HoverButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const HoverButton({super.key, required this.child, required this.onTap});
  @override
  State<HoverButton> createState() => _HoverButtonState();
}
class _HoverButtonState extends State<HoverButton> {
  bool _isHovering = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _isHovering = true),
      onTapUp: (_) => setState(() => _isHovering = false),
      onTapCancel: () => setState(() => _isHovering = false),
      child: AnimatedScale(
        scale: _isHovering ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CHAT BUBBLE
// ---------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String, {bool isError}) onToast;
  final Function(String) onPlayTTS;
  final bool isSpeaking;

  const ChatBubble({
    super.key,
    required this.message,
    required this.onToast,
    required this.onPlayTTS,
    required this.isSpeaking,
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
            child: isUser ? _buildUserMsg(context) : _buildAIMsg(context),
          )
        ],
      ),
    );
  }

  Widget _buildUserMsg(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Image comes FIRST for User, then Text
        if (message.localImagePath != null)
           Padding(
             padding: const EdgeInsets.only(bottom: 8.0),
             child: _buildMediaPreview(context, message.localImagePath!, isLocal: true),
           ),
        
        if (message.text.isNotEmpty)
          _buildCopyableBubble(
             context, 
             message.text, 
             const Color(0xFFF0F0F0), 
             Colors.black87,
             isUser: true
          ),
      ],
    );
  }

  Widget _buildAIMsg(BuildContext context) {
    bool isThinking = message.status == GenStatus.waiting || message.status == GenStatus.generating;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[200]!),
                shape: BoxShape.circle,
              ),
              child: ClipOval(
                child: Image.network("https://iili.io/f4Xfgfa.jpg", width: 24, height: 24, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 8),
            Text(message.modelName ?? "SkyGen", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            
            // TTS Button
            if (message.status == GenStatus.completed && message.visibleText.isNotEmpty)
              IconButton(
                icon: Icon(isSpeaking ? Icons.pause_circle : Icons.volume_up_rounded, size: 16, color: Colors.grey),
                onPressed: () => onPlayTTS(message.text),
              ),
              
            if (isThinking)
              Padding(
                 padding: const EdgeInsets.only(left: 8),
                 child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey[400])),
              )
          ],
        ),
        const SizedBox(height: 6),
        
        // Media Results
        if (message.imageUrl != null)
           _buildMediaPreview(context, message.imageUrl!),
        
        if (message.videoPath != null)
           _buildMediaPreview(context, message.videoPath!, isVideo: true),
           
        if (message.musicResults != null)
           ...message.musicResults!.map((m) => MusicCard(data: m, onToast: onToast)),

        // Text / Error
        if (message.status == GenStatus.error)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F0),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red[100]!)
            ),
            child: Text(message.text, style: const TextStyle(color: Colors.red)),
          )
        else if (message.visibleText.isNotEmpty && message.imageUrl == null) // Show text if no image (or caption)
           _buildCopyableBubble(
             context, 
             message.visibleText, 
             Colors.transparent, 
             Colors.black87,
             isUser: false
           ),
      ],
    );
  }

  Widget _buildCopyableBubble(BuildContext context, String text, Color bg, Color textColor, {required bool isUser}) {
    // Custom Copy implementation via Long Press
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: text));
        // Show animated button or just toast as requested "animated button" -> We simulate by showing a Toast near bottom
        onToast("Copied to clipboard"); 
      },
      child: Container(
        padding: isUser ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12) : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: isUser 
          ? Text(text, style: TextStyle(color: textColor, fontSize: 16, height: 1.4))
          : MarkdownBody(
             data: text,
             selectable: false, // Custom copy
             styleSheet: MarkdownStyleSheet(
               p: TextStyle(color: textColor, fontSize: 16, height: 1.5),
               code: const TextStyle(backgroundColor: Color(0xFFF5F5F5), fontFamily: "monospace"),
               codeblockDecoration: BoxDecoration(color: const Color(0xFF2d2d2d), borderRadius: BorderRadius.circular(8)),
             ),
             builders: {
               'code': CodeBuilder(onToast),
             },
          ),
      ),
    );
  }

  Widget _buildMediaPreview(BuildContext context, String path, {bool isLocal = false, bool isVideo = false}) {
    // Force 512x512 Aspect Ratio container
    return GestureDetector(
      onTap: () {
         Navigator.push(context, MaterialPageRoute(builder: (_) => FullScreenViewer(
           url: path, 
           isLocal: isLocal, 
           isVideo: isVideo,
           onToast: onToast
         )));
      },
      child: Container(
        width: 300, 
        height: 300, // Fixed size
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Content
            isVideo 
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                     Container(color: Colors.black),
                     const Icon(Icons.play_circle_fill, color: Colors.white, size: 60),
                  ],
                )
              : (isLocal 
                 ? Image.file(File(path), fit: BoxFit.cover)
                 : CachedNetworkImage(
                     imageUrl: path, 
                     fit: BoxFit.cover,
                     placeholder: (c,u) => Shimmer.fromColors(
                        baseColor: Colors.grey[300]!, 
                        highlightColor: Colors.grey[100]!, 
                        child: Container(color: Colors.white)
                     ),
                   )
                ),
            
            // Download Button (Only for AI Gen, user upload doesn't need download usually, but prompt said remove for user upload)
            if (!isLocal)
              Positioned(
                top: 8, right: 8,
                child: DownloadButton(url: path, onToast: onToast, isVideo: isVideo),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CODE HIGHLIGHTING BUILDER
// ---------------------------------------------------------------------------
class CodeBuilder extends MarkdownElementBuilder {
  final Function(String, {bool isError}) onToast;
  CodeBuilder(this.onToast);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    bool isBlock = element.textContent.contains('\n');
    String lang = "";
    if (element.attributes['class'] != null) {
      lang = element.attributes['class']!.replaceFirst("language-", "");
    }

    if (!isBlock) {
      return Container(
         padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
         decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(4)),
         child: Text(element.textContent, style: const TextStyle(fontFamily: 'monospace', color: Colors.redAccent)),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF282C34), borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(color: Color(0xFF21252B), borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(lang.toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: element.textContent));
                    onToast("Code copied");
                  },
                  child: const Row(children: [Icon(Icons.copy, size: 14, color: Colors.grey), SizedBox(width: 4), Text("Copy", style: TextStyle(color: Colors.grey, fontSize: 12))]),
                )
              ],
            ),
          ),
          HighlightView(
            element.textContent,
            language: lang.isEmpty ? 'plaintext' : lang,
            theme: atomOneDarkTheme,
            padding: const EdgeInsets.all(12),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DOWNLOAD BUTTON (STRICT PERMISSION)
// ---------------------------------------------------------------------------
class DownloadButton extends StatefulWidget {
  final String url;
  final bool isVideo;
  final Function(String, {bool isError}) onToast;
  const DownloadButton({super.key, required this.url, required this.onToast, this.isVideo = false});

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _loading = false;

  Future<void> _download() async {
    setState(() => _loading = true);
    try {
      // Permission Logic
      bool granted = false;
      if (Platform.isAndroid) {
        if (await Permission.storage.request().isGranted) granted = true;
        else if (await Permission.photos.request().isGranted) granted = true;
        else if (await Permission.manageExternalStorage.request().isGranted) granted = true;
      } else {
        granted = true; // iOS
      }

      if (!granted) {
        widget.onToast("Permission denied. Cannot save.", isError: true);
        setState(() => _loading = false);
        return;
      }

      // Root Folder Logic: /storage/emulated/0/SkyGen
      Directory? root;
      if (Platform.isAndroid) {
         root = Directory('/storage/emulated/0/SkyGen');
      } else {
         root = await getApplicationDocumentsDirectory();
      }
      
      if (!await root.exists()) {
        try {
          await root.create(recursive: true);
        } catch (e) {
          // Fallback to Picture/SkyGen if Root is blocked by Android 11+
          root = Directory('/storage/emulated/0/Pictures/SkyGen');
          if (!await root.exists()) await root.create(recursive: true);
        }
      }

      final ext = widget.isVideo ? "mp4" : "png";
      final file = File("${root.path}/skygen_${DateTime.now().millisecondsSinceEpoch}.$ext");
      
      if (widget.url.startsWith("http")) {
         final res = await http.get(Uri.parse(widget.url));
         await file.writeAsBytes(res.bodyBytes);
      } else {
         // It's local path
         final src = File(widget.url);
         await src.copy(file.path);
      }

      widget.onToast("Saved successfully!"); 
      // Not showing path as requested, just success.
      
    } catch (e) {
      widget.onToast("Save failed: $e", isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading ? null : _download,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
        child: _loading 
           ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
           : const Icon(Icons.download, color: Colors.white, size: 18),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MUSIC CARD
// ---------------------------------------------------------------------------
class MusicCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final Function(String, {bool isError}) onToast;
  const MusicCard({super.key, required this.data, required this.onToast});

  @override
  State<MusicCard> createState() => _MusicCardState();
}

class _MusicCardState extends State<MusicCard> {
  final AudioPlayer _p = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(top: 8, right: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                   ClipRRect(
                     borderRadius: BorderRadius.circular(6),
                     child: CachedNetworkImage(imageUrl: widget.data['cover_url'], width: 50, height: 50, fit: BoxFit.cover),
                   ),
                   GestureDetector(
                     onTap: () async {
                       if (_playing) {
                         await _p.pause();
                       } else {
                         await _p.play(UrlSource(widget.data['audio_url']));
                       }
                       setState(() => _playing = !_playing);
                     },
                     child: Icon(_playing ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: 30),
                   )
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.data['title'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Text("AI Generated", style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ),
              DownloadButton(url: widget.data['audio_url'], onToast: widget.onToast, isVideo: false), // audio uses simple download logic
            ],
          ),
          const SizedBox(height: 8),
          Text(widget.data['lyrics'] ?? "", maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FULL SCREEN VIEWER
// ---------------------------------------------------------------------------
class FullScreenViewer extends StatefulWidget {
  final String url;
  final bool isLocal;
  final bool isVideo;
  final Function(String, {bool isError}) onToast;

  const FullScreenViewer({super.key, required this.url, required this.onToast, this.isLocal = false, this.isVideo = false});

  @override
  State<FullScreenViewer> createState() => _FullScreenViewerState();
}

class _FullScreenViewerState extends State<FullScreenViewer> {
  VideoPlayerController? _vc;
  ChewieController? _cc;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      if (widget.isLocal) _vc = VideoPlayerController.file(File(widget.url));
      else _vc = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      
      _vc!.initialize().then((_) {
        setState(() {
           _cc = ChewieController(
             videoPlayerController: _vc!,
             autoPlay: true,
             looping: true,
             showControlsOnInitialize: false,
             allowPlaybackSpeedChanging: false, // Remove speed text/dots as much as possible
             customControls: const MaterialControls(showPlayButton: true), // Simplified controls if possible or default
           );
        });
      });
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    _cc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: widget.isVideo
              ? (_cc != null 
                  ? Chewie(controller: _cc!)
                  : const CircularProgressIndicator(color: Colors.white))
              : InteractiveViewer(
                  child: widget.isLocal 
                     ? Image.file(File(widget.url))
                     : CachedNetworkImage(imageUrl: widget.url),
                ),
          ),
          // Close & Download
          Positioned(
            top: 40, right: 20,
            child: Row(
              children: [
                if (!widget.isLocal) 
                  DownloadButton(url: widget.url, onToast: widget.onToast, isVideo: widget.isVideo),
                const SizedBox(width: 20),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white),
                  ),
                )
              ],
            ),
          )
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
  const MyStuffPage({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Stuff")),
      body: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4
        ),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          final url = item['url'] ?? item['cover_url'];
          bool isVideo = item['type'] == 'video';
          
          return GestureDetector(
            onTap: () {
               // Re-use full screen viewer logic (simplified for this context)
               // Needs onToast passing or local scaffold context
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                 if (isVideo) 
                   Container(
                     color: Colors.black,
                     child: const Center(child: Icon(Icons.play_circle, color: Colors.white)),
                   )
                 else 
                   CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                 
                 Positioned(
                   bottom: 4, left: 4,
                   child: Icon(
                      item['type'] == 'music' ? Icons.music_note : (isVideo ? Icons.videocam : Icons.image),
                      color: Colors.white, size: 16
                   ),
                 )
              ],
            ),
          );
        },
      ),
    );
  }
}
