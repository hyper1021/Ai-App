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
import 'package:cached_network_image/cached_network_image.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:audioplayers/audioplayers.dart';

// ==============================================================================
// 1. APP CONFIGURATION & ENTRY POINT
// ==============================================================================

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
  runApp(const EnglishLearningApp());
}

class EnglishLearningApp extends StatelessWidget {
  const EnglishLearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'English AI Tutor',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        primaryColor: const Color(0xFF007AFF),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007AFF)),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
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

class ChatMessage {
  final String id;
  String text; // FIX: Removed 'final' so the text can be updated during streaming
  String visibleText;
  final MessageType type;
  List<String>? attachedImageUrls; 
  GenStatus status;
  final int timestamp;
  bool isSpeaking;
  bool isTTSLoading;

  ChatMessage({
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.attachedImageUrls,
    this.status = GenStatus.completed,
    required this.timestamp,
    this.isSpeaking = false,
    this.isTTSLoading = false,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : "");

  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'visibleText': visibleText,
    'type': type.index,
    'attachedImageUrls': attachedImageUrls,
    'status': status.index,
    'timestamp': timestamp,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'],
    text: map['text'],
    visibleText: map['visibleText'],
    type: MessageType.values[map['type']],
    attachedImageUrls: map['attachedImageUrls'] != null ? List<String>.from(map['attachedImageUrls']) : null,
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

// ==============================================================================
// 3. MAIN CHAT SCREEN
// ==============================================================================

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  List<ChatSession> _sessions = [];
  String _currentSessionId = "";
  bool _isTempSession = true;
  bool _isGenerating = false;
  bool _stopRequested = false;
  File? _storageFile;

  List<File> _pickedImages = [];
  bool _isUploadingImage = false;
  
  // TTS Player
  final AudioPlayer _ttsPlayer = AudioPlayer();
  List<String> _ttsQueue = [];
  bool _isPlayingTTS = false;
  String? _currentSpeakingMsgId;
  
  // ImgBB API Key
  final String _imgBBApiKey = "0ffd290312c6b0ca9bb005414f44df2f";

  // System Instruction
  final String _systemInstruction = """
You are an expert English Language Tutor specifically designed for Bengali students (Class 8, SSC, HSC levels). 
Your ONLY purpose is to teach English grammar, vocabulary, sentence structures, and literature related to these academic levels.
Rules:
1. Keep your responses short and concise unless the user explicitly asks you to explain in detail.
2. If the user asks about anything outside of learning English or academics, politely decline and steer the conversation back to English.
3. You can answer in a mix of helpful Bengali and English to make learning easy.
4. If image contexts are provided, explain the text or content of the images in English or teach grammar/vocab based on them.
""";

  @override
  void initState() {
    super.initState();
    _initStorage();
    _ttsPlayer.onPlayerComplete.listen((event) => _playNextTTSChunk());
  }

  @override
  void dispose() {
    _promptController.dispose();
    _scrollController.dispose();
    _ttsPlayer.dispose();
    super.dispose();
  }

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/english_ai_data.json');
      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        setState(() {
          _sessions = sessionList.map((e) => ChatSession.fromMap(e)).toList();
          _sortSessions();
        });
      }
      _createTempSession();
    } catch (e) {
      _createTempSession();
    }
  }

  Future<void> _saveData() async {
    if (_storageFile == null) return;
    try {
      await _storageFile!.writeAsString(jsonEncode({'sessions': _sessions.map((e) => e.toMap()).toList()}));
    } catch (e) {}
  }

  void _sortSessions() {
    _sessions.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  void _createTempSession() {
    setState(() {
      _currentSessionId = "temp${DateTime.now().millisecondsSinceEpoch}";
      _isTempSession = true;
      _isGenerating = false;
      _promptController.clear();
      _pickedImages.clear();
    });
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
      _isTempSession = false;
      _isGenerating = false;
      _pickedImages.clear();
    });
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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

  ChatSession get _currentSession {
    if (_isTempSession) {
      return _sessions.firstWhere((s) => s.id == _currentSessionId,
        orElse: () => ChatSession(id: _currentSessionId, title: "New Chat", createdAt: DateTime.now().millisecondsSinceEpoch, messages: [])
      );
    }
    return _sessions.firstWhere((s) => s.id == _currentSessionId, orElse: () => _sessions.first);
  }

  // --------------------------------------------------------------------------
  // INPUT & PROCESSING
  // --------------------------------------------------------------------------

  Future<void> _pickImages() async {
    if (_pickedImages.length >= 3) {
      _showToast("You can upload a maximum of 3 images.", isError: true);
      return;
    }
    try {
      final ImagePicker picker = ImagePicker();
      final List<XFile> images = await picker.pickMultiImage();
      
      if (images.isNotEmpty) {
        setState(() {
          int availableSlots = 3 - _pickedImages.length;
          _pickedImages.addAll(images.take(availableSlots).map((e) => File(e.path)));
        });
      }
    } catch (e) {
      _showToast("Picker Error: $e", isError: true);
    }
  }

  Future<List<String>> _uploadImagesToImgBB() async {
    List<String> uploadedUrls = [];
    for (File img in _pickedImages) {
      try {
        final uri = Uri.parse("https://api.imgbb.com/1/upload?key=$_imgBBApiKey");
        var request = http.MultipartRequest('POST', uri);
        request.files.add(await http.MultipartFile.fromPath('image', img.path));
        var res = await request.send();
        if (res.statusCode == 200) {
          var responseBody = await res.stream.bytesToString();
          final data = jsonDecode(responseBody);
          uploadedUrls.add(data['data']['url']);
        }
      } catch (e) {
        debugPrint("Image upload failed: $e");
      }
    }
    return uploadedUrls;
  }

  Future<void> _handleSubmitted() async {
    if (_isGenerating) return;
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty && _pickedImages.isEmpty) return;

    setState(() => _isGenerating = true);
    List<String> uploadedUrls = [];
    
    // Upload Images if any
    if (_pickedImages.isNotEmpty) {
      setState(() => _isUploadingImage = true);
      uploadedUrls = await _uploadImagesToImgBB();
      setState(() => _isUploadingImage = false);
    }

    _promptController.clear();
    _pickedImages.clear();

    if (_isTempSession) {
      String titleText = prompt.isNotEmpty ? prompt : "English Lesson";
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

    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    final userMsg = ChatMessage(
      id: userMsgId,
      text: prompt,
      type: MessageType.user,
      attachedImageUrls: uploadedUrls.isNotEmpty ? uploadedUrls : null,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(userMsg);
      _stopRequested = false;
    });
    _scrollToBottom();
    _saveData();

    await _processAIStream(prompt, uploadedUrls);
  }

  // Build prompt including history (last 50 messages) and image analysis
  Future<String> _buildFinalPrompt(String userPrompt, List<String> imageUrls) async {
    String imageContext = "";
    
    // Process images via OCR & Describer
    if (imageUrls.isNotEmpty) {
      imageContext += "\n\n[User attached ${imageUrls.length} image(s). Context below:]\n";
      for (int i = 0; i < imageUrls.length; i++) {
        imageContext += "Image ${i+1}:\n";
        try {
          // 1 Sec delay between requests to avoid rate limit
          if (i > 0) await Future.delayed(const Duration(seconds: 1));
          
          // OCR Request
          final ocrRes = await http.post(
            Uri.parse("https://gen-z-ocr.vercel.app/api"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"url": imageUrls[i]}),
          );
          if (ocrRes.statusCode == 200) {
            final ocrData = jsonDecode(ocrRes.body);
            if (ocrData['ok'] == true) {
               imageContext += "- Text in Image: ${ocrData['results']['answer']}\n";
            }
          }
          
          // Describer Request
          final descRes = await http.get(Uri.parse("https://gen-z-describer.vercel.app/api?url=${imageUrls[i]}"));
          if (descRes.statusCode == 200) {
            final descData = jsonDecode(descRes.body);
            if (descData['ok'] == true) {
              imageContext += "- Image Description: ${descData['results']['description']}\n";
            }
          }
        } catch (e) {
           imageContext += "- (Failed to analyze this image)\n";
        }
      }
    }

    // Build History (Last 50 messages -> 25 user, 25 ai)
    String historyContext = "";
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    final msgs = currentSess.messages;
    int startIndex = max(0, msgs.length - 51); // Get last 50 (ignoring the current user message just added)
    
    for (int i = startIndex; i < msgs.length - 1; i++) {
       final m = msgs[i];
       if (m.status == GenStatus.completed) {
         historyContext += "${m.type == MessageType.user ? 'User' : 'Tutor'}: ${m.text}\n";
       }
    }

    String finalPrompt = "[System Instruction]\n$_systemInstruction\n\n";
    if (historyContext.isNotEmpty) {
      finalPrompt += "[Chat History]\n$historyContext\n";
    }
    finalPrompt += imageContext;
    finalPrompt += "\n[Current User Message]\nUser: ${userPrompt.isEmpty ? '(Sent an image)' : userPrompt}";
    
    return finalPrompt;
  }

  Future<void> _processAIStream(String userPrompt, List<String> imageUrls) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";
    
    // Show generating status (could be analyzing images first)
    String initText = imageUrls.isNotEmpty ? "Analyzing images & thinking..." : "Thinking...";
    _addAIMessage(aiMsgId, initText, GenStatus.waiting);

    try {
      String fullContextPrompt = await _buildFinalPrompt(userPrompt, imageUrls);
      
      final client = http.Client();
      final request = http.Request('POST', Uri.parse("https://www.api.hyper-bd.site/Ai/"));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({"q": fullContextPrompt, "format": "sse"});

      final response = await client.send(request);
      
      if (response.statusCode != 200) {
        throw Exception("Server Error ${response.statusCode}");
      }

      _updateMessageStatus(aiMsgId, GenStatus.streaming, errorText: "");
      String streamedText = "";
      String buffer = "";

      // Stream Listener
      await for (var chunk in response.stream.transform(utf8.decoder)) {
        if (_stopRequested) {
          _updateMessageStatus(aiMsgId, GenStatus.stopped, errorText: streamedText);
          client.close();
          break;
        }

        buffer += chunk;
        while (buffer.contains('\n\n')) {
          int index = buffer.indexOf('\n\n');
          String message = buffer.substring(0, index).trim();
          buffer = buffer.substring(index + 2);

          if (message.startsWith('data: ')) {
            String dataStr = message.substring(6).trim();
            if (dataStr == '[DONE]') {
              break;
            }
            try {
              final json = jsonDecode(dataStr);
              if (json['results'] != null && json['results']['answer'] != null) {
                streamedText += json['results']['answer'];
                _updateVisibleText(aiMsgId, streamedText);
              }
            } catch (_) {}
          }
        }
      }
      
      if (!_stopRequested) {
         _updateMessageStatus(aiMsgId, GenStatus.completed, errorText: streamedText);
      }
      
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error, errorText: "Error: $e");
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  void _addAIMessage(String id, String text, GenStatus status) {
    final currentSess = _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() => currentSess.messages.add(ChatMessage(
      id: id,
      text: text,
      visibleText: "",
      type: MessageType.ai,
      status: status,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    )));
    _scrollToBottom();
  }

  void _updateVisibleText(String msgId, String text) {
    int sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        _sessions[sIndex].messages[mIndex].visibleText = text;
        _sessions[sIndex].messages[mIndex].text = text; // Keep actual text updated
      });
      _scrollToBottom();
    }
  }

  void _updateMessageStatus(String msgId, GenStatus status, {String? errorText}) {
    if (!mounted) return;
    int sIndex = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex].messages.indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        var old = _sessions[sIndex].messages[mIndex];
        old.status = status;
        if (errorText != null) {
           old.text = errorText;
           old.visibleText = errorText;
        }
      });
      if (status == GenStatus.completed) _scrollToBottom();
    }
  }

  // --- TTS ---
  Future<void> _handleTTSAction(String msgId, String text) async {
    if (_currentSpeakingMsgId == msgId && _isPlayingTTS) {
      await _ttsPlayer.pause();
      setState(() => _isPlayingTTS = false);
      return;
    } 
    if (_currentSpeakingMsgId == msgId && !_isPlayingTTS) {
      await _ttsPlayer.resume();
      setState(() => _isPlayingTTS = true);
      return;
    }

    _updateMessageSpeechState(msgId, false, true);
    await _ttsPlayer.stop();
    setState(() {
      _currentSpeakingMsgId = msgId;
      _isPlayingTTS = true;
      _ttsQueue.clear();
    });

    String cleanText = text.replaceAll(RegExp(r'```[\s\S]*?```'), ''); 
    final RegExp chunker = RegExp(r'.{1,190}(?:\s|$)', dotAll: true);
    final chunks = chunker.allMatches(cleanText).map((m) => m.group(0)!.trim()).toList();
    
    if (chunks.isNotEmpty) {
      _ttsQueue.addAll(chunks);
      await _playNextTTSChunk();
      _updateMessageSpeechState(msgId, true, false); 
    } else {
      _updateMessageSpeechState(msgId, false, false);
    }
  }

  Future<void> _playNextTTSChunk() async {
    if (_ttsQueue.isEmpty) {
      setState(() {
        _isPlayingTTS = false;
        _currentSpeakingMsgId = null;
      });
      for (var s in _sessions) {
         for (var m in s.messages) {
            if (m.isSpeaking) setState(() => m.isSpeaking = false);
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
      _playNextTTSChunk(); 
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

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.redAccent : const Color(0xFF333333),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // --------------------------------------------------------------------------
  // UI BUILDERS
  // --------------------------------------------------------------------------

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
        title: const Text("English Tutor", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.black87),
            onPressed: () {
               if (!_isTempSession) _createTempSession();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
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
                        onSpeak: _handleTTSAction,
                        isPlayingTTS: _isPlayingTTS && _currentSpeakingMsgId == currentMessages[index].id,
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
      child: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.school, color: Color(0xFF007AFF), size: 30),
                  SizedBox(width: 12),
                  Text("Chat History", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  if (session.messages.isEmpty) return const SizedBox.shrink();

                  final isActive = session.id == _currentSessionId && !_isTempSession;
                  return ListTile(
                    tileColor: isActive ? Colors.grey[100] : Colors.transparent,
                    leading: Icon(
                      session.isPinned ? Icons.push_pin : Icons.chat_bubble_outline_rounded,
                      color: session.isPinned ? const Color(0xFF007AFF) : Colors.black54,
                    ),
                    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                    onTap: () => _switchSession(session.id),
                    trailing: IconButton(
                       icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                       onPressed: () {
                          setState(() {
                             _sessions.removeAt(index);
                             if (_currentSessionId == session.id) _createTempSession();
                          });
                          _saveData();
                       },
                    )
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 60),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.blue[50], shape: BoxShape.circle),
              child: const Icon(Icons.school, size: 60, color: Color(0xFF007AFF)),
            ),
            const SizedBox(height: 30),
            const Text(
              "Hi, I'm your English Tutor!",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              "Ask me anything about English Grammar, SSC/HSC syllabus, Vocabulary, or attach images to extract and explain texts.",
              style: TextStyle(fontSize: 16, color: Colors.grey, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, -4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image Thumbnails Row
          if (_pickedImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: _pickedImages.map((file) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(right: 12),
                        width: 50, height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          image: DecorationImage(image: FileImage(file), fit: BoxFit.cover)
                        ),
                        child: _isUploadingImage 
                           ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                           : null,
                      ),
                      Positioned(
                        right: 4, top: -8,
                        child: GestureDetector(
                          onTap: () => setState(() => _pickedImages.remove(file)),
                          child: const CircleAvatar(radius: 10, backgroundColor: Colors.red, child: Icon(Icons.close, size: 12, color: Colors.white)),
                        ),
                      )
                    ],
                  );
                }).toList(),
              ),
            ),
            
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 6, right: 8),
                width: 36, height: 36,
                decoration: BoxDecoration(color: Colors.grey[200], shape: BoxShape.circle),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.image, color: Colors.black54, size: 20),
                  onPressed: _pickImages,
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFFF0F0F0), borderRadius: BorderRadius.circular(26)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                       Expanded(
                         child: TextField(
                           controller: _promptController,
                           enabled: !_isGenerating,
                           maxLines: 5, minLines: 1,
                           style: const TextStyle(fontSize: 16),
                           decoration: const InputDecoration(
                             hintText: "Ask about Grammar, Tense...",
                             contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                             border: InputBorder.none,
                           ),
                         ),
                       ),
                       Padding(
                         padding: const EdgeInsets.only(bottom: 6, right: 6),
                         child: GestureDetector(
                           onTap: _isGenerating ? () => setState(() => _stopRequested = true) : _handleSubmitted,
                           child: Container(
                             width: 34, height: 34,
                             decoration: BoxDecoration(
                               color: _isGenerating ? Colors.redAccent : Colors.black,
                               shape: BoxShape.circle,
                             ),
                             child: Icon(
                               _isGenerating ? Icons.stop_rounded : Icons.arrow_upward,
                               color: Colors.white, size: 20,
                             ),
                           ),
                         ),
                       ),
                    ],
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

// ==============================================================================
// 4. CHAT BUBBLE WIDGET
// ==============================================================================

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String, {bool isError}) onToast;
  final Function(String, String) onSpeak;
  final bool isPlayingTTS;

  const ChatBubble({
    super.key,
    required this.message,
    required this.onToast,
    required this.onSpeak,
    required this.isPlayingTTS,
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
            child: isUser ? _buildUserMessage(context) : _buildAIMessage(context),
          ),
        ],
      ),
    );
  }

  Widget _buildUserMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (message.attachedImageUrls != null && message.attachedImageUrls!.isNotEmpty)
           Padding(
             padding: const EdgeInsets.only(bottom: 8),
             child: Wrap(
               spacing: 8, runSpacing: 8,
               alignment: WrapAlignment.end,
               children: message.attachedImageUrls!.map((url) => ClipRRect(
                   borderRadius: BorderRadius.circular(12),
                   child: CachedNetworkImage(
                     imageUrl: url, width: 120, height: 120, fit: BoxFit.cover,
                     placeholder: (c,u) => Container(width: 120, height: 120, color: Colors.grey[200]),
                   ),
               )).toList(),
             ),
           ),
           
        if (message.text.isNotEmpty)
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
        Row(
           children: [
             const SizedBox(width: 4),
             Container(
               width: 26, height: 26,
               decoration: BoxDecoration(border: Border.all(color: Colors.grey[200]!), shape: BoxShape.circle),
               child: const CircleAvatar(backgroundColor: Color(0xFF007AFF), child: Icon(Icons.school, color: Colors.white, size: 14)),
             ),
             const SizedBox(width: 8),
             const Text("English Tutor", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)),
             
             if (isWaiting) ...[
                const SizedBox(width: 10),
                const Text("Thinking...", style: TextStyle(color: Colors.grey, fontSize: 12, fontStyle: FontStyle.italic)), 
             ],

             const Spacer(),
             if (message.status == GenStatus.completed && message.text.isNotEmpty)
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
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.visibleText.isNotEmpty)
                Container(
                   margin: const EdgeInsets.only(top: 4),
                   constraints: const BoxConstraints(maxWidth: 340),
                   child: MarkdownBody(
                     data: message.visibleText,
                     selectable: true, 
                     styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                       p: const TextStyle(fontSize: 16, color: Colors.black87, height: 1.5),
                     ),
                   ),
                ),
              if (message.status == GenStatus.error)
                 Container(
                   margin: const EdgeInsets.only(top: 8),
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
}
