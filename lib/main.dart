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
    systemNavigationBarColor: Color(0xFFFAFAFA),
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
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
        primaryColor: const Color(0xFF5B6FF2),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B6FF2),
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFAFAFA),
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
          titleTextStyle: TextStyle(
            color: Color(0xFF1A1A2E),
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFamily: 'Roboto',
          ),
        ),
        fontFamily: 'Roboto',
      ),
      home: const ChatScreen(),
    );
  }
}

// ==============================================================================
// 2. THEME & CONSTANTS
// ==============================================================================

class AppColors {
  static const primary = Color(0xFF5B6FF2);
  static const primaryLight = Color(0xFFEEF0FE);
  static const surface = Color(0xFFFAFAFA);
  static const cardBg = Color(0xFFFFFFFF);
  static const userBubble = Color(0xFFF2F2F5);
  static const textPrimary = Color(0xFF1A1A2E);
  static const textSecondary = Color(0xFF6B7280);
  static const border = Color(0xFFE5E7EB);
  static const inputBg = Color(0xFFFFFFFF);
  static const success = Color(0xFF10B981);
  static const error = Color(0xFFEF4444);
}

// ==============================================================================
// 3. DATA MODELS
// ==============================================================================

enum MessageType { user, ai }
enum GenStatus { waiting, generating, streaming, completed, error, stopped }

class ChatMessage {
  final String id;
  String text;
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
        attachedImageUrls: map['attachedImageUrls'] != null
            ? List<String>.from(map['attachedImageUrls'])
            : null,
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
        messages: (map['messages'] as List)
            .map((e) => ChatMessage.fromMap(e))
            .toList(),
      );
}

// ==============================================================================
// 4. MAIN CHAT SCREEN
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

  // Custom Image Upload API
  final String _imageUploadApi = "https://api.hyper-bd.site/img-upload/";

  // ---- System Instruction (Detailed) ----
  final String _systemInstruction = """
You are "English Tutor AI" — an expert English language assistant built exclusively for Bangladeshi students (Class 6–12, SSC, HSC, and general learners). Your sole purpose is to help users master the English language fully and confidently.

=== YOUR CAPABILITIES ===
You can handle ALL of the following:

1. GRAMMAR — Tenses (Present, Past, Future — Simple, Continuous, Perfect, Perfect Continuous), Parts of Speech (Noun, Pronoun, Verb, Adjective, Adverb, Preposition, Conjunction, Interjection), Voice (Active/Passive), Narration (Direct/Indirect), Sentence Types, Clause, Phrase, Transformation of Sentences, Degree of Comparison, Subject-Verb Agreement, Articles (a, an, the), Punctuation, Spelling corrections.

2. VOCABULARY — Word meanings, synonyms, antonyms, one-word substitution, idioms and phrases, phrasal verbs, confusing words (affect/effect, their/there/they're), word formation (prefix/suffix), contextual word use.

3. TRANSLATION — Bengali to English and English to Bengali translation, both formal and informal.

4. WRITING — Paragraphs, Essays, Emails (formal/informal), Applications, Letters, Compositions, Dialogues, Story writing, Report writing, Summary writing, CV writing.

5. READING & COMPREHENSION — Explaining English passages, answering comprehension questions, identifying main idea, tone, inference.

6. PRONUNCIATION GUIDANCE — Phonetic hints, commonly mispronounced words by Bengali speakers.

7. SSC / HSC BOARD EXAM PREP — Model questions, fill-in-the-blanks, right form of verbs, rearranging sentences, cloze tests, synonym/antonym, seen/unseen comprehension, dialogue completion, formal/informal letter formats.

8. IMAGE-BASED HELP — If a user sends an image of English text, question, paragraph or a textbook page, analyze the image and explain, correct, or answer accordingly.

9. SPOKEN ENGLISH — Common phrases, daily conversation practice, how to express opinions formally in English.

=== LANGUAGE STYLE ===
- Always respond in a MIX of Bengali and English where helpful. Use Bengali to explain rules and concepts. Use English for examples, sentences, grammar terms, tense names, headings, and technical labels.
- Write numbers in Bengali (e.g., ১, ২, ৩) when listing points in Bengali context, but use English numerals (1, 2, 3) inside English examples or tables.
- Tense names MUST be written in English (e.g., Present Perfect Continuous Tense).
- Grammar terms like Noun, Verb, Adjective, Subject, Predicate — always write in English.
- Keep responses concise unless the user explicitly asks for a detailed explanation.
- Use bullet points, tables, and examples for clarity.
- Always give at least 1–2 example sentences in English when explaining a rule.
- Never use overly complex vocabulary when simpler words will do.

=== RULES ===
1. ONLY help with English language learning, grammar, writing, translation, vocabulary, or English-related academic topics. Do not help with any off-topic requests (math, coding, news, personal advice, etc.).
2. If a user asks something unrelated, politely decline and redirect: "আমি শুধু ইংরেজি শেখার বিষয়ে সাহায্য করতে পারি। English-related কোনো প্রশ্ন থাকলে জিজ্ঞেস করুন!"
3. If the user writes in Bengali, respond primarily in Bengali with English examples.
4. If the user writes in English, respond in English (with Bengali notes where helpful).
5. Always be encouraging, patient, and supportive — treat every learner with respect.
6. Never make the user feel bad for making mistakes. Instead, gently correct and teach.
""";

  // Suggestion prompts for Welcome Screen
  final List<Map<String, dynamic>> _suggestions = [
    {
      'icon': Icons.auto_fix_high_rounded,
      'label': 'Grammar Check',
      'prompt': 'আমার এই sentence টা grammar check করে দাও: "She don\'t like mango."',
      'color': Color(0xFF5B6FF2),
    },
    {
      'icon': Icons.translate_rounded,
      'label': 'Translation',
      'prompt': 'এই বাক্যটা ইংরেজিতে অনুবাদ করো: "আমি প্রতিদিন সকালে ঘুম থেকে উঠি।"',
      'color': Color(0xFF10B981),
    },
    {
      'icon': Icons.school_rounded,
      'label': 'Tense শেখো',
      'prompt': 'Present Perfect Tense কী? বাংলায় সহজ করে বুঝিয়ে দাও উদাহরণসহ।',
      'color': Color(0xFFF59E0B),
    },
    {
      'icon': Icons.edit_note_rounded,
      'label': 'Essay Writing',
      'prompt': 'SSC পরীক্ষার জন্য "Digital Bangladesh" বিষয়ে একটি paragraph লিখতে সাহায্য করো।',
      'color': Color(0xFFEF4444),
    },
    {
      'icon': Icons.spellcheck_rounded,
      'label': 'Vocabulary',
      'prompt': '"Perseverance" শব্দের অর্থ, synonym, antonym এবং একটি example sentence দাও।',
      'color': Color(0xFF8B5CF6),
    },
    {
      'icon': Icons.mail_outline_rounded,
      'label': 'Letter/Application',
      'prompt': 'Headmaster-এর কাছে ৩ দিনের ছুটির জন্য একটি formal application লিখে দাও।',
      'color': Color(0xFF0EA5E9),
    },
  ];

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
      _storageFile = File('${dir.path}/english_ai_data_v2.json');
      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        final Map<String, dynamic> jsonData = jsonDecode(content);
        final List<dynamic> sessionList = jsonData['sessions'] ?? [];
        setState(() {
          _sessions =
              sessionList.map((e) => ChatSession.fromMap(e)).toList();
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
      await _storageFile!.writeAsString(jsonEncode(
          {'sessions': _sessions.map((e) => e.toMap()).toList()}));
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
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom());
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
      return _sessions.firstWhere(
        (s) => s.id == _currentSessionId,
        orElse: () => ChatSession(
          id: _currentSessionId,
          title: "New Chat",
          createdAt: DateTime.now().millisecondsSinceEpoch,
          messages: [],
        ),
      );
    }
    return _sessions.firstWhere((s) => s.id == _currentSessionId,
        orElse: () => _sessions.first);
  }

  // --------------------------------------------------------------------------
  // INPUT & PROCESSING
  // --------------------------------------------------------------------------

  Future<void> _pickImages() async {
    if (_pickedImages.length >= 3) {
      _showToast("সর্বোচ্চ ৩টি ছবি যোগ করা যাবে।", isError: true);
      return;
    }
    try {
      final ImagePicker picker = ImagePicker();
      final List<XFile> images = await picker.pickMultiImage();
      if (images.isNotEmpty) {
        setState(() {
          int slots = 3 - _pickedImages.length;
          _pickedImages
              .addAll(images.take(slots).map((e) => File(e.path)));
        });
      }
    } catch (e) {
      _showToast("Error: $e", isError: true);
    }
  }

  // Upload using custom API (hyper-bd.site) — same response format as ImgBB
  Future<List<String>> _uploadImages() async {
    List<String> uploadedUrls = [];
    for (File img in _pickedImages) {
      try {
        final uri = Uri.parse(_imageUploadApi);
        var request = http.MultipartRequest('POST', uri);
        request.files
            .add(await http.MultipartFile.fromPath('image', img.path));
        var res = await request.send();
        if (res.statusCode == 200) {
          var responseBody = await res.stream.bytesToString();
          final data = jsonDecode(responseBody);
          if (data['success'] == true) {
            uploadedUrls.add(data['data']['url']);
          }
        }
      } catch (e) {
        debugPrint("Image upload failed: $e");
      }
    }
    return uploadedUrls;
  }

  Future<void> _handleSubmitted({String? suggestionPrompt}) async {
    if (_isGenerating) return;
    final prompt =
        suggestionPrompt ?? _promptController.text.trim();
    if (prompt.isEmpty && _pickedImages.isEmpty) return;

    setState(() => _isGenerating = true);
    List<String> uploadedUrls = [];

    if (_pickedImages.isNotEmpty) {
      setState(() => _isUploadingImage = true);
      uploadedUrls = await _uploadImages();
      setState(() => _isUploadingImage = false);
    }

    _promptController.clear();
    _pickedImages.clear();

    if (_isTempSession) {
      String titleText =
          prompt.isNotEmpty ? prompt : "English Lesson";
      titleText = titleText.replaceAll('\n', ' ');
      if (titleText.length > 30) titleText = titleText.substring(0, 30);

      final newSession = ChatSession(
        id: _currentSessionId,
        title: titleText,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        messages: [],
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
      attachedImageUrls:
          uploadedUrls.isNotEmpty ? uploadedUrls : null,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final currentSess =
        _sessions.firstWhere((s) => s.id == _currentSessionId);
    setState(() {
      currentSess.messages.add(userMsg);
      _stopRequested = false;
    });
    _scrollToBottom();
    _saveData();

    await _processAIStream(prompt, uploadedUrls);
  }

  Future<String> _buildFinalPrompt(
      String userPrompt, List<String> imageUrls) async {
    String imageContext = "";

    if (imageUrls.isNotEmpty) {
      imageContext +=
          "\n\n[User attached ${imageUrls.length} image(s). Context below:]\n";
      for (int i = 0; i < imageUrls.length; i++) {
        imageContext += "Image ${i + 1}:\n";
        try {
          if (i > 0) await Future.delayed(const Duration(seconds: 1));

          final ocrRes = await http.post(
            Uri.parse("https://gen-z-ocr.vercel.app/api"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"url": imageUrls[i]}),
          );
          if (ocrRes.statusCode == 200) {
            final ocrData = jsonDecode(ocrRes.body);
            if (ocrData['ok'] == true) {
              imageContext +=
                  "- Text in Image: ${ocrData['results']['answer']}\n";
            }
          }

          final descRes = await http.get(Uri.parse(
              "https://gen-z-describer.vercel.app/api?url=${imageUrls[i]}"));
          if (descRes.statusCode == 200) {
            final descData = jsonDecode(descRes.body);
            if (descData['ok'] == true) {
              imageContext +=
                  "- Image Description: ${descData['results']['description']}\n";
            }
          }
        } catch (e) {
          imageContext += "- (Failed to analyze this image)\n";
        }
      }
    }

    String historyContext = "";
    final currentSess =
        _sessions.firstWhere((s) => s.id == _currentSessionId);
    final msgs = currentSess.messages;
    int startIndex = max(0, msgs.length - 51);

    for (int i = startIndex; i < msgs.length - 1; i++) {
      final m = msgs[i];
      if (m.status == GenStatus.completed) {
        historyContext +=
            "${m.type == MessageType.user ? 'User' : 'Tutor'}: ${m.text}\n";
      }
    }

    String finalPrompt =
        "[System Instruction]\n$_systemInstruction\n\n";
    if (historyContext.isNotEmpty) {
      finalPrompt += "[Chat History]\n$historyContext\n";
    }
    finalPrompt += imageContext;
    finalPrompt +=
        "\n[Current User Message]\nUser: ${userPrompt.isEmpty ? '(Sent an image)' : userPrompt}";

    return finalPrompt;
  }

  Future<void> _processAIStream(
      String userPrompt, List<String> imageUrls) async {
    final aiMsgId = "ai${DateTime.now().millisecondsSinceEpoch}";

    String initText = imageUrls.isNotEmpty
        ? "Analyzing images & thinking..."
        : "Thinking...";
    _addAIMessage(aiMsgId, initText, GenStatus.waiting);

    try {
      String fullContextPrompt =
          await _buildFinalPrompt(userPrompt, imageUrls);

      final client = http.Client();
      final request = http.Request(
          'POST', Uri.parse("https://www.api.hyper-bd.site/Ai/"));
      request.headers['Content-Type'] = 'application/json';
      request.body =
          jsonEncode({"q": fullContextPrompt, "format": "sse"});

      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception("Server Error ${response.statusCode}");
      }

      _updateMessageStatus(aiMsgId, GenStatus.streaming,
          errorText: "");
      String streamedText = "";
      String buffer = "";

      await for (var chunk
          in response.stream.transform(utf8.decoder)) {
        if (_stopRequested) {
          _updateMessageStatus(aiMsgId, GenStatus.stopped,
              errorText: streamedText);
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
            if (dataStr == '[DONE]') break;
            try {
              final json = jsonDecode(dataStr);
              if (json['results'] != null &&
                  json['results']['answer'] != null) {
                streamedText += json['results']['answer'];
                _updateVisibleText(aiMsgId, streamedText);
              }
            } catch (_) {}
          }
        }
      }

      if (!_stopRequested) {
        _updateMessageStatus(aiMsgId, GenStatus.completed,
            errorText: streamedText);
      }
    } catch (e) {
      _updateMessageStatus(aiMsgId, GenStatus.error,
          errorText: "⚠️ Error: $e");
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _saveData();
    }
  }

  void _addAIMessage(String id, String text, GenStatus status) {
    final currentSess =
        _sessions.firstWhere((s) => s.id == _currentSessionId);
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
    int sIndex =
        _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex]
        .messages
        .indexWhere((m) => m.id == msgId);
    if (mIndex != -1) {
      setState(() {
        _sessions[sIndex].messages[mIndex].visibleText = text;
        _sessions[sIndex].messages[mIndex].text = text;
      });
      _scrollToBottom();
    }
  }

  void _updateMessageStatus(String msgId, GenStatus status,
      {String? errorText}) {
    if (!mounted) return;
    int sIndex =
        _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex]
        .messages
        .indexWhere((m) => m.id == msgId);
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

    String cleanText =
        text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    final RegExp chunker =
        RegExp(r'.{1,190}(?:\s|$)', dotAll: true);
    final chunks = chunker
        .allMatches(cleanText)
        .map((m) => m.group(0)!.trim())
        .toList();

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
      final url =
          "https://murf.ai/Prod/anonymous-tts/audio?text=$encoded&voiceId=VM017230562791058FV&style=Conversational";
      await _ttsPlayer.play(UrlSource(url));
    } catch (e) {
      _playNextTTSChunk();
    }
  }

  void _updateMessageSpeechState(
      String msgId, bool isSpeaking, bool isLoading) {
    int sIndex =
        _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (sIndex == -1) return;
    final mIndex = _sessions[sIndex]
        .messages
        .indexWhere((m) => m.id == msgId);
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
      content: Text(message,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      backgroundColor:
          isError ? AppColors.error : const Color(0xFF1A1A2E),
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
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
      backgroundColor: AppColors.surface,
      drawer: _buildDrawer(),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: currentMessages.isEmpty
                ? _buildWelcomeScreen()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 16),
                    itemCount: currentMessages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: currentMessages[index],
                        onToast: _showToast,
                        onSpeak: _handleTTSAction,
                        isPlayingTTS: _isPlayingTTS &&
                            _currentSpeakingMsgId ==
                                currentMessages[index].id,
                      );
                    },
                  ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      leading: GestureDetector(
        onTap: () => _scaffoldKey.currentState?.openDrawer(),
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: const Icon(Icons.menu_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF5B6FF2), Color(0xFF8B5CF6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.school_rounded,
                color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          const Text("English Tutor",
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
        ],
      ),
      centerTitle: true,
      actions: [
        GestureDetector(
          onTap: () {
            if (!_isTempSession) _createTempSession();
          },
          child: Container(
            margin: const EdgeInsets.only(right: 12, top: 10, bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Icon(Icons.add_rounded,
                    color: AppColors.primary, size: 18),
                SizedBox(width: 4),
                Text("New",
                    style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: AppColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF5B6FF2), Color(0xFF8B5CF6)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.school_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(height: 12),
                  const Text("English Tutor AI",
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  const Text("Chat History",
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
            ),

            // New Chat Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GestureDetector(
                onTap: () {
                  if (!_isTempSession) _createTempSession();
                  Navigator.pop(context);
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF5B6FF2), Color(0xFF8B5CF6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text("New Chat",
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text("Recent Chats",
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                      letterSpacing: 0.8)),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  if (session.messages.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  final isActive =
                      session.id == _currentSessionId && !_isTempSession;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.primaryLight
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppColors.primary.withOpacity(0.15)
                              : AppColors.border,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          session.isPinned
                              ? Icons.push_pin_rounded
                              : Icons.chat_bubble_outline_rounded,
                          size: 15,
                          color: isActive
                              ? AppColors.primary
                              : AppColors.textSecondary,
                        ),
                      ),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: isActive
                              ? AppColors.primary
                              : AppColors.textPrimary,
                        ),
                      ),
                      onTap: () => _switchSession(session.id),
                      trailing: PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert_rounded,
                            size: 16, color: AppColors.textSecondary),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        onSelected: (val) {
                          if (val == 'pin') {
                            setState(() {
                              _sessions[index].isPinned =
                                  !_sessions[index].isPinned;
                              _sortSessions();
                            });
                            _saveData();
                          } else if (val == 'delete') {
                            setState(() {
                              _sessions.removeAt(index);
                              if (_currentSessionId == session.id) {
                                _createTempSession();
                              }
                            });
                            _saveData();
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'pin',
                            child: Row(children: [
                              Icon(
                                session.isPinned
                                    ? Icons.push_pin_outlined
                                    : Icons.push_pin_rounded,
                                size: 16,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(session.isPinned ? 'Unpin' : 'Pin'),
                            ]),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(children: [
                              Icon(Icons.delete_outline_rounded,
                                  size: 16, color: AppColors.error),
                              const SizedBox(width: 8),
                              const Text('Delete',
                                  style:
                                      TextStyle(color: AppColors.error)),
                            ]),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(16),
              child: const Text(
                "English Tutor AI — Powered by Hyper BD",
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
      child: Column(
        children: [
          // Hero Section
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF5B6FF2), Color(0xFF8B5CF6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF5B6FF2).withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child:
                const Icon(Icons.school_rounded, color: Colors.white, size: 38),
          ),
          const SizedBox(height: 20),
          const Text(
            "আপনার English Tutor! 👋",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            "Grammar, Translation, Vocabulary, SSC/HSC Exam — সব কিছু এক জায়গায়।",
            style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Feature Tags
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _buildTag("📝 Grammar Fix"),
              _buildTag("🔤 Vocabulary"),
              _buildTag("🌐 Translation"),
              _buildTag("📚 SSC / HSC"),
              _buildTag("✍️ Essay & Letter"),
              _buildTag("🖼️ Image to Text"),
            ],
          ),
          const SizedBox(height: 32),

          // Suggestion Cards
          Align(
            alignment: Alignment.centerLeft,
            child: const Text(
              "Quick Start করুন",
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 1.55,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: _suggestions.length,
            itemBuilder: (context, index) {
              final s = _suggestions[index];
              return GestureDetector(
                onTap: () =>
                    _handleSubmitted(suggestionPrompt: s['prompt']),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: (s['color'] as Color).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(s['icon'] as IconData,
                            color: s['color'] as Color, size: 17),
                      ),
                      const Spacer(),
                      Text(
                        s['label'] as String,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        "Tap to try →",
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
            fontSize: 12,
            color: AppColors.primary,
            fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image Thumbnails
          if (_pickedImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _pickedImages.map((file) {
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(right: 10),
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                            image: DecorationImage(
                                image: FileImage(file),
                                fit: BoxFit.cover),
                          ),
                          child: _isUploadingImage
                              ? Container(
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.black.withOpacity(0.4),
                                    borderRadius:
                                        BorderRadius.circular(10),
                                  ),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white),
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        Positioned(
                          right: 2,
                          top: -6,
                          child: GestureDetector(
                            onTap: () => setState(
                                () => _pickedImages.remove(file)),
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: const BoxDecoration(
                                color: AppColors.error,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close,
                                  size: 11, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),

          // Input Row
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Image Picker Button
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 8, bottom: 8),
                      child: GestureDetector(
                        onTap: _pickImages,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                              Icons.image_outlined,
                              color: AppColors.primary,
                              size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Text Field
                    Expanded(
                      child: TextField(
                        controller: _promptController,
                        enabled: !_isGenerating,
                        maxLines: 5,
                        minLines: 1,
                        style: const TextStyle(
                            fontSize: 15, color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          hintText: "ask anything...",
                          hintStyle: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 15),
                          contentPadding: EdgeInsets.symmetric(
                              vertical: 10, horizontal: 4),
                          border: InputBorder.none,
                        ),
                      ),
                    ),

                    // Send / Stop Button
                    Padding(
                      padding:
                          const EdgeInsets.only(right: 8, bottom: 8),
                      child: GestureDetector(
                        onTap: _isGenerating
                            ? () =>
                                setState(() => _stopRequested = true)
                            : _handleSubmitted,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            gradient: _isGenerating
                                ? null
                                : const LinearGradient(
                                    colors: [
                                      Color(0xFF5B6FF2),
                                      Color(0xFF8B5CF6)
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                            color: _isGenerating
                                ? AppColors.error
                                : null,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _isGenerating
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Bottom note
          Padding(
            padding:
                const EdgeInsets.only(top: 6, left: 4),
            child: const Text(
              "English grammar, translation, SSC/HSC সব বিষয়ে জিজ্ঞেস করুন।",
              style: TextStyle(
                  fontSize: 10, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ==============================================================================
// 5. CHAT BUBBLE WIDGET
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
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            // AI Avatar
            Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.only(top: 2, right: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5B6FF2), Color(0xFF8B5CF6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.school_rounded,
                  color: Colors.white, size: 15),
            ),
          ],
          Flexible(
            child: isUser
                ? _buildUserMessage(context)
                : _buildAIMessage(context),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildUserMessage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (message.attachedImageUrls != null &&
            message.attachedImageUrls!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: message.attachedImageUrls!
                  .map((url) => ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: url,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          placeholder: (c, u) => Container(
                            width: 120,
                            height: 120,
                            color: AppColors.border,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        if (message.text.isNotEmpty)
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72),
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.userBubble,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Text(
              message.text,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
                height: 1.45,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAIMessage(BuildContext context) {
    bool isWaiting = message.status == GenStatus.waiting ||
        message.status == GenStatus.generating;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: Name + TTS
        Row(
          children: [
            const Text(
              "English Tutor",
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.textPrimary),
            ),
            if (isWaiting) ...[
              const SizedBox(width: 10),
              _ThinkingDots(),
            ],
            const Spacer(),
            if (message.status == GenStatus.completed &&
                message.text.isNotEmpty)
              GestureDetector(
                onTap: () => onSpeak(message.id, message.text),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isPlayingTTS
                        ? AppColors.primaryLight
                        : AppColors.border.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: message.isTTSLoading
                      ? const Center(
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary),
                          ),
                        )
                      : Icon(
                          isPlayingTTS
                              ? Icons.pause_rounded
                              : Icons.volume_up_rounded,
                          color: isPlayingTTS
                              ? AppColors.primary
                              : AppColors.textSecondary,
                          size: 15,
                        ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),

        // Message Content
        if (message.visibleText.isNotEmpty)
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.80),
            child: MarkdownBody(
              data: message.visibleText,
              selectable: true,
              styleSheet:
                  MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                    height: 1.55),
                code: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  backgroundColor: Color(0xFFF3F4F6),
                  color: Color(0xFF5B6FF2),
                ),
                codeblockDecoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10),
                ),
                h1: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
                h2: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
                h3: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
                strong: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
                tableHead: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13),
                tableBody:
                    const TextStyle(fontSize: 13, height: 1.4),
                tableBorder: TableBorder.all(
                    color: AppColors.border, width: 1),
              ),
            ),
          ),

        if (message.status == GenStatus.error)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppColors.error.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: AppColors.error, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message.text,
                    style: const TextStyle(
                        color: AppColors.error, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),

        // Copy button for completed messages
        if (message.status == GenStatus.completed &&
            message.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.text));
                onToast("Copied to clipboard!");
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.copy_rounded,
                      size: 13, color: AppColors.textSecondary),
                  SizedBox(width: 4),
                  Text("Copy",
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ==============================================================================
// 6. THINKING DOTS ANIMATION
// ==============================================================================

class _ThinkingDots extends StatefulWidget {
  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            double opacity = (sin((_controller.value * 2 * pi) -
                            (i * pi / 3)) +
                        1) /
                    2;
            return Container(
              margin: const EdgeInsets.only(right: 3),
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.3 + opacity * 0.7),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
