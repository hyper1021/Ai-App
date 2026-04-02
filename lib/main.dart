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
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';

// ══════════════════════════════════════════════════════════════
// 1. ENTRY POINT
// ══════════════════════════════════════════════════════════════

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  runApp(const SkyGenApp());
}

// ══════════════════════════════════════════════════════════════
// 2. THEME NOTIFIER
// ══════════════════════════════════════════════════════════════

class ThemeNotifier extends ChangeNotifier {
  bool _dark = false;
  bool get isDark => _dark;
  void toggle() { _dark = !_dark; notifyListeners(); }
}

final themeNotifier = ThemeNotifier();

// ══════════════════════════════════════════════════════════════
// 3. COLOURS
// ══════════════════════════════════════════════════════════════

class C {
  static bool dark = false;

  static Color get bg      => dark ? const Color(0xFF0F1117) : const Color(0xFFF5F5F7);
  static Color get card    => dark ? const Color(0xFF1A1D27) : const Color(0xFFFFFFFF);
  static Color get accent  => const Color(0xFF5B6FF2);
  static Color get accentL => dark ? const Color(0xFF1E2240) : const Color(0xFFEEF0FE);
  static Color get ink     => dark ? const Color(0xFFF1F2F6) : const Color(0xFF111827);
  static Color get ink2    => dark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);
  static Color get border  => dark ? const Color(0xFF2D3148) : const Color(0xFFE5E7EB);
  static Color get userBub => dark ? const Color(0xFF22263A) : const Color(0xFFF0F0F3);
  static Color get red     => const Color(0xFFEF4444);
  static Color get green   => const Color(0xFF10B981);
  static const grad1 = Color(0xFF5B6FF2);
  static const grad2 = Color(0xFF8B5CF6);
}

const String kLogoUrl  = 'https://www.cdn.hyper-bd.site/photo/logo.png';
const String kImgBBKey = '4685fa1e1d227aec0ce07733cd571ff9';
const String kDevTg    = 'https://t.me/BD_Prime_Minister';

// ══════════════════════════════════════════════════════════════
// 4. DATA MODELS
// ══════════════════════════════════════════════════════════════

enum MsgType   { user, ai }
enum GenStatus { waiting, streaming, completed, error, stopped }

class PendingImage {
  final File   file;
  final String localSrc;
  String? uploadedUrl;
  String? ocrText;
  String? description;
  bool isLoading;
  bool isError;

  PendingImage({required this.file, required this.localSrc,
      this.isLoading = true, this.isError = false});
}

class ChatMsg {
  final String id;
  String text;
  String visibleText;
  final MsgType type;
  List<String>? imgUrls;
  GenStatus status;
  final int ts;
  bool liked;
  bool disliked;

  ChatMsg({
    required this.id, required this.text, String? visibleText,
    required this.type, this.imgUrls, this.status = GenStatus.completed,
    required this.ts, this.liked = false, this.disliked = false,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : '');

  Map<String, dynamic> toMap() => {
    'id': id, 'text': text, 'visibleText': visibleText,
    'type': type.index, 'imgUrls': imgUrls, 'status': status.index,
    'ts': ts, 'liked': liked, 'disliked': disliked,
  };

  factory ChatMsg.fromMap(Map<String, dynamic> m) => ChatMsg(
    id: m['id'], text: m['text'], visibleText: m['visibleText'],
    type: MsgType.values[m['type']],
    imgUrls: m['imgUrls'] != null ? List<String>.from(m['imgUrls']) : null,
    status: GenStatus.values[m['status']], ts: m['ts'],
    liked: m['liked'] ?? false, disliked: m['disliked'] ?? false,
  );
}

class Session {
  final String id;
  String title;
  final int createdAt;
  bool isPinned;
  List<ChatMsg> messages;
  bool titleGenerated; // track if AI title was already generated

  Session({
    required this.id, required this.title, required this.createdAt,
    this.isPinned = false, required this.messages, this.titleGenerated = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id, 'title': title, 'createdAt': createdAt,
    'isPinned': isPinned, 'titleGenerated': titleGenerated,
    'messages': messages.map((m) => m.toMap()).toList(),
  };

  factory Session.fromMap(Map<String, dynamic> m) => Session(
    id: m['id'], title: m['title'], createdAt: m['createdAt'],
    isPinned: m['isPinned'] ?? false,
    titleGenerated: m['titleGenerated'] ?? false,
    messages: (m['messages'] as List).map((e) => ChatMsg.fromMap(e)).toList(),
  );
}

// ══════════════════════════════════════════════════════════════
// 5. ROOT APP
// ══════════════════════════════════════════════════════════════

class SkyGenApp extends StatefulWidget {
  const SkyGenApp({super.key});
  @override
  State<SkyGenApp> createState() => _SkyGenAppState();
}

class _SkyGenAppState extends State<SkyGenApp> {
  @override
  void initState() {
    super.initState();
    themeNotifier.addListener(() => setState(() { C.dark = themeNotifier.isDark; }));
  }

  @override
  Widget build(BuildContext context) {
    C.dark = themeNotifier.isDark;
    final brightness = themeNotifier.isDark ? Brightness.dark : Brightness.light;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: themeNotifier.isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: C.bg,
      systemNavigationBarIconBrightness: themeNotifier.isDark ? Brightness.light : Brightness.dark,
    ));
    return MaterialApp(
      title: 'SkyGen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: C.bg,
        primaryColor: C.accent,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
            seedColor: C.accent, brightness: brightness),
      ),
      home: const SplashScreen(),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 6. SPLASH SCREEN
// ══════════════════════════════════════════════════════════════

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale, _glow, _fade;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const NetworkImage(kLogoUrl), context);
    });
    _ctrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 2200));
    _scale = Tween(begin: 0.65, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.0, 0.55, curve: Curves.elasticOut)));
    _glow = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.3, 0.85, curve: Curves.easeOut)));
    _fade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.0, 0.35, curve: Curves.easeIn)));
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 2700), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(PageRouteBuilder(
          pageBuilder: (_, __, ___) => const ChatScreen(),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
          transitionDuration: const Duration(milliseconds: 450),
        ));
      }
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => FadeTransition(
            opacity: _fade,
            child: Transform.scale(
              scale: _scale.value,
              child: Stack(alignment: Alignment.center, children: [
                for (int i = 0; i < 3; i++)
                  Opacity(
                    opacity: (_glow.value * (0.38 - i * 0.11)).clamp(0, 1.0),
                    child: Container(
                      width: 90.0 + i * 38, height: 90.0 + i * 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: C.accent.withOpacity(0.55 - i * 0.14),
                            width: 1.5),
                      ),
                    ),
                  ),
                _LogoCircle(size: 78),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 7. LOGO WIDGET (reusable circular logo)
// ══════════════════════════════════════════════════════════════

class _LogoCircle extends StatelessWidget {
  final double size;
  const _LogoCircle({required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: kLogoUrl, width: size, height: size, fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: size, height: size,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [C.grad1, C.grad2]), shape: BoxShape.circle),
          child: Icon(Icons.school_rounded, color: Colors.white, size: size * 0.48),
        ),
        errorWidget: (_, __, ___) => Container(
          width: size, height: size,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [C.grad1, C.grad2]), shape: BoxShape.circle),
          child: Icon(Icons.school_rounded, color: Colors.white, size: size * 0.48),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 8. CHAT SCREEN
// ══════════════════════════════════════════════════════════════

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final _inputCtrl   = TextEditingController();
  final _scrollCtrl  = ScrollController();
  final _searchCtrl  = TextEditingController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  List<Session> _sessions   = [];
  String  _currentId        = '';
  bool    _isTempSession    = true;
  bool    _isGenerating     = false;
  bool    _stopRequested    = false;
  File?   _storageFile;
  File?   _memoryFile;

  List<PendingImage> _pendingImages = [];

  // TTS
  final AudioPlayer _ttsPlayer = AudioPlayer();
  List<String> _ttsQueue       = [];
  bool  _isPlayingTTS          = false;
  bool  _isTTSLoading          = false;
  String? _speakingId;

  // Scroll FAB
  bool _showScrollFab = false;

  // AI Memory
  List<String> _aiMemory = [];

  // Drawer search
  String _searchQuery = '';

  // ── SYSTEM PROMPT ────────────────────────────────────────
  final String _sysBase = r"""
You are "SkyGen" — a smart, friendly English language tutor and AI assistant for Bangladeshi students. You were created by MD. Jaid Bin Siyam, developer at Hyper Squad. Only reveal this when the user explicitly asks who made you.

════ RESPONSE LENGTH RULES ════
• Greetings (Hi, Hello, How are you, etc.) → reply SHORT, 1-2 sentences max. Use friendly emojis. 🙂
• Simple yes/no questions → answer briefly.
• Questions about topics (tenses, grammar, vocabulary, etc.) → give COMPLETE, PROPER answers with all relevant details, subtypes, examples. Do NOT cut short.
• Translation requests → translate only, nothing extra.
• Writing tasks (essays, letters) → write the full content requested.
• RULE: Match response length to what the question actually needs. Never over-explain, never under-explain.

════ EMOJI USAGE ════
• Use relevant emojis naturally in responses to make them engaging. 😊📚✏️
• Greetings: always use emojis.
• Educational content: use sparingly for headers/points.
• Don't overdo it.

════ LANGUAGE RULES ════
• ALWAYS mirror the user's language exactly:
  - Bengali → reply in Bengali
  - English → reply in English
  - Banglish → reply in Banglish
• Natural Bengali can include English terms (like grammar terms: Present Tense, Noun, etc.)
• Grammar terms always in English regardless of reply language.

════ TITLE GENERATION (FIRST MESSAGE ONLY) ════
ONLY when this tag is present in the instructions: [GENERATE_TITLE]
Add at the very END of your response (after all content):
<<<TITLE: Your title here>>>
Title: 10–100 characters, relevant to the topic.
NEVER generate a title unless [GENERATE_TITLE] is explicitly in the instruction.

════ MEMORY SYSTEM ════
If the user shares personally useful long-term info (class, name, age, goals, native language), add at the END of your response:
<<<MEMORY: ["fact 1", "fact 2"]>>>
Only save genuinely important facts. Keep concise. Never mention you're saving memory to the user.

════ WHAT YOU HELP WITH ════
① Grammar — All 12 tenses (with structure, rules, all subtypes, examples), Parts of Speech, Voice, Narration, Transformation, Articles, Punctuation, Spelling.
② Vocabulary — Meanings, synonyms, antonyms, idioms, phrasal verbs, confusing words.
③ Translation — Any language pair the user asks for. Translate only.
④ Writing — Essays, letters, applications, dialogues, CV, summaries, reports.
⑤ Comprehension — Passages, main idea, tone, inference.
⑥ SSC/HSC Prep — Board exam questions, fill-in-blanks, cloze, model questions.
⑦ Image Help — Analyze text/content from uploaded images.
⑧ Spoken English — Daily phrases, formal intro, pronunciation tips.

════ IDENTITY ════
Name: SkyGen | Creator: MD. Jaid Bin Siyam (Hyper Squad) | Reveal only when asked.

════ OFF-TOPIC ════
Non-English topics: "I can only help with English learning! 📚 Ask me anything about English."
""";

  String _buildSystemInstruction({bool needTitle = false}) {
    String full = _sysBase;
    if (needTitle) {
      full += '\n\n[GENERATE_TITLE] — Add <<<TITLE: ...>>> at the end of your response.';
    }
    if (_aiMemory.isNotEmpty) {
      full += '\n\n════ USER MEMORY (Always use this context) ════\n';
      for (int i = 0; i < _aiMemory.length; i++) {
        full += '• ${_aiMemory[i]}\n';
      }
    }
    return full;
  }

  final List<Map<String, dynamic>> _quickCards = [
    {'icon': Icons.auto_fix_high_rounded, 'label': 'Grammar Check',  'color': C.grad1},
    {'icon': Icons.translate_rounded,     'label': 'Translation',    'color': C.green},
    {'icon': Icons.school_rounded,        'label': 'Learn Tenses',   'color': Color(0xFFF59E0B)},
    {'icon': Icons.edit_note_rounded,     'label': 'Essay Writing',  'color': C.red},
  ];

  @override
  void initState() {
    super.initState();
    _initStorage();
    _ttsPlayer.onPlayerComplete.listen((_) => _playNextTTS());
    _scrollCtrl.addListener(_onScroll);
    themeNotifier.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _ttsPlayer.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final distFromBottom =
        _scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels;
    final show = distFromBottom > 200;
    if (show != _showScrollFab) setState(() => _showScrollFab = show);
  }

  // ── Storage ──────────────────────────────────────────────
  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_v5.json');
      _memoryFile  = File('${dir.path}/skygen_memory.json');
      if (await _storageFile!.exists()) {
        final raw = await _storageFile!.readAsString();
        final d   = jsonDecode(raw);
        setState(() {
          _sessions = (d['sessions'] as List).map((e) => Session.fromMap(e)).toList();
          _sortSessions();
        });
      }
      if (await _memoryFile!.exists()) {
        final raw = await _memoryFile!.readAsString();
        final d   = jsonDecode(raw);
        setState(() => _aiMemory = List<String>.from(d['memory'] ?? []));
      }
    } catch (_) {}
    _newTempSession();
  }

  Future<void> _save() async {
    if (_storageFile == null) return;
    try {
      await _storageFile!.writeAsString(
          jsonEncode({'sessions': _sessions.map((s) => s.toMap()).toList()}));
    } catch (_) {}
  }

  Future<void> _saveMemory() async {
    if (_memoryFile == null) return;
    try {
      await _memoryFile!.writeAsString(jsonEncode({'memory': _aiMemory}));
    } catch (_) {}
  }

  void _addToMemory(List<String> items) {
    for (final item in items) {
      if (item.isNotEmpty && !_aiMemory.contains(item)) _aiMemory.add(item);
    }
    if (_aiMemory.length > 10) _aiMemory = _aiMemory.sublist(_aiMemory.length - 10);
    _saveMemory();
  }

  void _sortSessions() {
    _sessions.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  void _newTempSession() {
    setState(() {
      _currentId     = 'temp${DateTime.now().millisecondsSinceEpoch}';
      _isTempSession = true;
      _isGenerating  = false;
      _inputCtrl.clear();
      _pendingImages.clear();
    });
  }

  void _switchSession(String id) {
    setState(() {
      _currentId     = id;
      _isTempSession = false;
      _isGenerating  = false;
      _pendingImages.clear();
    });
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBot(force: true));
  }

  void _scrollToBot({bool force = false}) {
    if (!_scrollCtrl.hasClients) return;
    if (force || !_showScrollFab) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Session get _curSession => _isTempSession
      ? _sessions.firstWhere((s) => s.id == _currentId,
          orElse: () => Session(id: _currentId, title: 'New Chat',
              createdAt: DateTime.now().millisecondsSinceEpoch, messages: []))
      : _sessions.firstWhere((s) => s.id == _currentId,
          orElse: () => _sessions.isNotEmpty ? _sessions.first
              : Session(id: _currentId, title: 'New Chat',
                  createdAt: DateTime.now().millisecondsSinceEpoch, messages: []));

  // ── Image Upload (ImgBB) ─────────────────────────────────
  Future<void> _pickImages() async {
    if (_pendingImages.length >= 3) {
      _showToast('Maximum 3 images allowed.');
      return;
    }
    try {
      final picker = ImagePicker();
      final files  = await picker.pickMultiImage();
      if (files.isEmpty) return;
      final slots  = 3 - _pendingImages.length;
      for (final xf in files.take(slots)) {
        final pending = PendingImage(file: File(xf.path), localSrc: xf.path);
        setState(() => _pendingImages.add(pending));
        _uploadAndAnalyze(pending);
      }
    } catch (e) {
      _showToast('Error picking image: $e');
    }
  }

  Future<void> _uploadAndAnalyze(PendingImage p) async {
    try {
      final uri = Uri.parse('https://api.imgbb.com/1/upload?key=$kImgBBKey');
      final req = http.MultipartRequest('POST', uri);
      req.files.add(await http.MultipartFile.fromPath('image', p.file.path));
      final res  = await req.send();
      if (res.statusCode == 200) {
        final body = await res.stream.bytesToString();
        final data = jsonDecode(body);
        if (data['success'] == true) {
          p.uploadedUrl = data['data']['url'] as String;
          await Future.wait([_fetchOCR(p), _fetchDesc(p)]);
          if (mounted) setState(() => p.isLoading = false);
          return;
        }
      }
      // Upload failed
      if (mounted) setState(() { p.isLoading = false; p.isError = true; });
    } catch (_) {
      if (mounted) setState(() { p.isLoading = false; p.isError = true; });
    }
  }

  Future<void> _fetchOCR(PendingImage p) async {
    try {
      final r = await http.post(Uri.parse('https://gen-z-ocr.vercel.app/api'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'url': p.uploadedUrl}));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body);
        if (d['ok'] == true) p.ocrText = d['results']['answer'] as String?;
      }
    } catch (_) {}
  }

  Future<void> _fetchDesc(PendingImage p) async {
    try {
      final r = await http.get(
          Uri.parse('https://gen-z-describer.vercel.app/api?url=${p.uploadedUrl}'));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body);
        if (d['ok'] == true) p.description = d['results']['description'] as String?;
      }
    } catch (_) {}
  }

  // ── Send ─────────────────────────────────────────────────
  Future<void> _send() async {
    if (_isGenerating) return;
    final prompt = _inputCtrl.text.trim();
    if (prompt.isEmpty && _pendingImages.isEmpty) return;
    if (_pendingImages.any((p) => p.isLoading)) {
      _showToast('Images are still uploading, please wait…');
      return;
    }

    setState(() => _isGenerating = true);
    final imgs = List<PendingImage>.from(_pendingImages);
    _inputCtrl.clear();
    setState(() => _pendingImages.clear());

    // Determine if this is first message (need title)
    final isFirst = _isTempSession;

    if (_isTempSession) {
      final sess = Session(id: _currentId, title: 'New Chat',
          createdAt: DateTime.now().millisecondsSinceEpoch, messages: []);
      setState(() {
        _sessions.insert(0, sess);
        _isTempSession = false;
        _sortSessions();
      });
    }

    // Only successful uploads
    final imgUrls = imgs
        .where((i) => i.uploadedUrl != null && !i.isError)
        .map((i) => i.uploadedUrl!)
        .toList();

    final userMsg = ChatMsg(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: prompt, type: MsgType.user,
      imgUrls: imgUrls.isNotEmpty ? imgUrls : null,
      ts: DateTime.now().millisecondsSinceEpoch,
    );

    final sess = _sessions.firstWhere((s) => s.id == _currentId);
    setState(() { sess.messages.add(userMsg); _stopRequested = false; });
    _scrollToBot(force: true);
    _save();

    await _streamAI(prompt, imgs, sess: sess, isFirst: isFirst);
  }

  String _buildPrompt(String userPrompt, List<PendingImage> imgs,
      {required bool needTitle}) {
    String imgCtx = '';
    for (int i = 0; i < imgs.length; i++) {
      if (imgs[i].uploadedUrl == null || imgs[i].isError) continue;
      imgCtx += '\n[Image ${i + 1}]\n';
      if (imgs[i].ocrText?.isNotEmpty == true) imgCtx += '  OCR: ${imgs[i].ocrText}\n';
      if (imgs[i].description?.isNotEmpty == true) imgCtx += '  Visual: ${imgs[i].description}\n';
    }

    final sess  = _sessions.firstWhere((s) => s.id == _currentId);
    final msgs  = sess.messages;
    String hist = '';
    final start = max(0, msgs.length - 51);
    for (int i = start; i < msgs.length - 1; i++) {
      final m = msgs[i];
      if (m.status == GenStatus.completed) {
        hist += '${m.type == MsgType.user ? "User" : "AI"}: ${m.text}\n';
      }
    }

    String full = '[System Instruction]\n${_buildSystemInstruction(needTitle: needTitle)}\n\n';
    if (hist.isNotEmpty)   full += '[Chat History]\n$hist\n';
    if (imgCtx.isNotEmpty) full += '[Images]\n$imgCtx\n';
    full += '[User Message]\nUser: ${userPrompt.isEmpty ? "(Image sent)" : userPrompt}';
    return full;
  }

  Future<void> _streamAI(String prompt, List<PendingImage> imgs,
      {required Session sess, required bool isFirst}) async {
    // needTitle only on first message and title not yet generated
    final needTitle = isFirst && !sess.titleGenerated;

    final aiId = 'ai${DateTime.now().millisecondsSinceEpoch}';
    _addAiMsg(aiId, '', GenStatus.waiting);

    try {
      final fullPrompt = _buildPrompt(prompt, imgs, needTitle: needTitle);
      final client = http.Client();
      final req    = http.Request('POST', Uri.parse('https://www.api.hyper-bd.site/Ai/'));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'q': fullPrompt, 'format': 'sse'});

      final res = await client.send(req);
      if (res.statusCode != 200) throw Exception('Server Error ${res.statusCode}');

      _updateStatus(aiId, GenStatus.streaming);
      String streamed  = '';
      String buf       = '';
      bool firstChunk  = true;

      await for (final chunk in res.stream.transform(utf8.decoder)) {
        if (_stopRequested) {
          _updateStatus(aiId, GenStatus.stopped, text: _cleanTags(streamed));
          client.close();
          break;
        }
        buf += chunk;
        while (buf.contains('\n\n')) {
          final idx  = buf.indexOf('\n\n');
          final line = buf.substring(0, idx).trim();
          buf        = buf.substring(idx + 2);
          if (line.startsWith('data: ')) {
            final ds = line.substring(6).trim();
            if (ds == '[DONE]') break;
            try {
              final j   = jsonDecode(ds);
              final ans = j['results']?['answer'] as String?;
              if (ans != null) {
                if (firstChunk && ans.trim().isEmpty) continue;
                firstChunk = false;
                streamed  += ans;
                // Show cleaned text (hide <<<...>>> blocks)
                _updateText(aiId, _cleanTagsForDisplay(streamed));
              }
            } catch (_) {}
          }
        }
      }

      if (!_stopRequested) {
        // Parse TITLE (only for first message)
        if (needTitle) {
          final titleMatch = RegExp(r'<<<TITLE:\s*(.+?)>>>').firstMatch(streamed);
          if (titleMatch != null) {
            final title = titleMatch.group(1)!.trim();
            final si = _sessions.indexWhere((s) => s.id == _currentId);
            if (si != -1) {
              setState(() {
                _sessions[si].title          = title;
                _sessions[si].titleGenerated = true;
              });
              _save();
            }
          }
        }

        // Parse MEMORY
        final memMatch = RegExp(r'<<<MEMORY:\s*(\[[\s\S]+?\])>>>').firstMatch(streamed);
        if (memMatch != null) {
          try {
            final arr = jsonDecode(memMatch.group(1)!) as List;
            _addToMemory(arr.map((e) => e.toString()).toList());
          } catch (_) {}
        }

        final clean = _cleanTags(streamed);
        _updateStatus(aiId, GenStatus.completed, text: clean);
      }
    } catch (e) {
      _updateStatus(aiId, GenStatus.error, text: '⚠️ Error: $e');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _save();
    }
  }

  // Clean ALL tags from final text
  String _cleanTags(String text) {
    return text
        .replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '')
        .replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '')
        .trim();
  }

  // For streaming display: hide any partial or full <<<...>>> blocks
  String _cleanTagsForDisplay(String text) {
    // Remove complete tags
    String clean = text
        .replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '')
        .replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '');
    // Remove partial tag that hasn't closed yet (starts with < or <<<)
    clean = clean.replaceAll(RegExp(r'<{1,3}[^>]*$'), '');
    return clean.trim();
  }

  void _addAiMsg(String id, String text, GenStatus status) {
    final sess = _sessions.firstWhere((s) => s.id == _currentId);
    setState(() => sess.messages.add(ChatMsg(
      id: id, text: text, visibleText: '',
      type: MsgType.ai, status: status,
      ts: DateTime.now().millisecondsSinceEpoch,
    )));
    _scrollToBot();
  }

  void _updateText(String id, String text) {
    final si = _sessions.indexWhere((s) => s.id == _currentId);
    if (si == -1) return;
    final mi = _sessions[si].messages.indexWhere((m) => m.id == id);
    if (mi != -1) {
      setState(() {
        _sessions[si].messages[mi].visibleText = text;
        _sessions[si].messages[mi].text        = text;
      });
      _scrollToBot();
    }
  }

  void _updateStatus(String id, GenStatus status, {String? text}) {
    if (!mounted) return;
    final si = _sessions.indexWhere((s) => s.id == _currentId);
    if (si == -1) return;
    final mi = _sessions[si].messages.indexWhere((m) => m.id == id);
    if (mi != -1) {
      setState(() {
        _sessions[si].messages[mi].status = status;
        if (text != null) {
          _sessions[si].messages[mi].text        = text;
          _sessions[si].messages[mi].visibleText = text;
        }
      });
      if (status == GenStatus.completed) _scrollToBot();
    }
  }

  // ── TTS ──────────────────────────────────────────────────
  Future<void> _handleTTS(String id, String text) async {
    if (_speakingId == id && _isPlayingTTS) {
      await _ttsPlayer.pause();
      setState(() => _isPlayingTTS = false);
      return;
    }
    if (_speakingId == id && !_isPlayingTTS && !_isTTSLoading) {
      await _ttsPlayer.resume();
      setState(() => _isPlayingTTS = true);
      return;
    }
    await _ttsPlayer.stop();
    setState(() {
      _speakingId   = id;
      _isPlayingTTS = false;
      _isTTSLoading = true;
      _ttsQueue.clear();
    });
    final chunks = _chunkText(text.replaceAll(RegExp(r'```[\s\S]*?```'), ''));
    if (chunks.isEmpty) {
      setState(() { _isTTSLoading = false; _speakingId = null; });
      return;
    }
    try {
      final urls = await Future.wait(chunks.map((c) => _buildTTSUrl(c)));
      if (!mounted) return;
      _ttsQueue.addAll(urls);
      setState(() { _isTTSLoading = false; _isPlayingTTS = true; });
      await _playNextTTS();
    } catch (_) {
      if (mounted) setState(() { _isTTSLoading = false; _isPlayingTTS = false; _speakingId = null; });
    }
  }

  List<String> _chunkText(String text, {int size = 190}) {
    final chunks = <String>[];
    String t = text.trim();
    while (t.isNotEmpty) {
      if (t.length <= size) { chunks.add(t); break; }
      int cut = -1;
      for (final bc in ['।', '.', '\n', '?', '!', ',', ';', ':']) {
        final pos = t.lastIndexOf(bc, size);
        if (pos > 80) { cut = pos + 1; break; }
      }
      if (cut < 0) { cut = t.lastIndexOf(' ', size); if (cut < 80) cut = size; }
      chunks.add(t.substring(0, cut).trim());
      t = t.substring(cut).trim();
    }
    return chunks.where((s) => s.isNotEmpty).toList();
  }

  Future<String> _buildTTSUrl(String text) async {
    return 'https://murf.ai/Prod/anonymous-tts/audio'
        '?text=${Uri.encodeComponent(text)}'
        '&voiceId=VM017230562791058FV&style=Conversational';
  }

  Future<void> _playNextTTS() async {
    if (_ttsQueue.isEmpty) {
      setState(() { _isPlayingTTS = false; _speakingId = null; });
      return;
    }
    try {
      await _ttsPlayer.play(UrlSource(_ttsQueue.removeAt(0)));
    } catch (_) { _playNextTTS(); }
  }

  // ── Reaction ─────────────────────────────────────────────
  void _setReaction(String msgId, bool like) {
    final si = _sessions.indexWhere((s) => s.id == _currentId);
    if (si == -1) return;
    final mi = _sessions[si].messages.indexWhere((m) => m.id == msgId);
    if (mi == -1) return;
    setState(() {
      if (like) {
        _sessions[si].messages[mi].liked    = !_sessions[si].messages[mi].liked;
        _sessions[si].messages[mi].disliked = false;
      } else {
        _sessions[si].messages[mi].disliked = !_sessions[si].messages[mi].disliked;
        _sessions[si].messages[mi].liked    = false;
      }
    });
    _save();
  }

  // ── Delete confirmation ────────────────────────────────
  Future<bool> _confirmDelete() async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: C.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete Chat',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
        content: Text('Are you sure? This cannot be undone.',
            style: TextStyle(fontSize: 14, color: C.ink2)),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: C.border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text('Cancel', style: TextStyle(color: C.ink2, fontWeight: FontWeight.w600)),
          )),
          const SizedBox(width: 10),
          Expanded(child: ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: C.red, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Delete',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          )),
        ])],
      ),
    ) ?? false;
  }

  // ── Toast ─────────────────────────────────────────────────
  OverlayEntry? _toastEntry;
  void _showToast(String msg) {
    _toastEntry?.remove();
    _toastEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: 24, right: 24,
        bottom: MediaQuery.of(context).size.height * 0.42,
        child: Material(
          color: Colors.transparent,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: C.ink.withOpacity(0.88), borderRadius: BorderRadius.circular(20)),
            child: Text(msg,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center),
          )),
        ),
      ),
    );
    Overlay.of(context).insert(_toastEntry!);
    Future.delayed(const Duration(milliseconds: 1800), () {
      _toastEntry?.remove(); _toastEntry = null;
    });
  }

  // ── Image fullscreen viewer ────────────────────────────
  void _openImageViewer(String url) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _ImageViewerPage(imageUrl: url),
    ));
  }

  // ══════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final msgs = _curSession.messages;
    return Scaffold(
      key:             _scaffoldKey,
      backgroundColor: C.bg,
      drawer:          _buildDrawer(),
      appBar:          _buildAppBar(),
      body: Stack(children: [
        Column(children: [
          Expanded(
            child: msgs.isEmpty
                ? _buildWelcome()
                : ListView.builder(
                    controller: _scrollCtrl,
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    itemCount: msgs.length,
                    itemBuilder: (ctx, i) => RepaintBoundary(
                      child: _BubbleWidget(
                        key:          ValueKey(msgs[i].id),
                        msg:          msgs[i],
                        isPlayingTTS: _isPlayingTTS && _speakingId == msgs[i].id,
                        isTTSLoading: _isTTSLoading && _speakingId == msgs[i].id,
                        onSpeak:     (id, text) => _handleTTS(id, text),
                        onCopy:      (text) => Clipboard.setData(ClipboardData(text: text)),
                        onLike:      (id) => _setReaction(id, true),
                        onDislike:   (id) => _setReaction(id, false),
                        onImageTap:  (url) => _openImageViewer(url),
                      ),
                    ),
                  ),
          ),
          _buildInput(),
        ]),
        if (_showScrollFab)
          Positioned(
            bottom: _inputHeight + 12,
            left: 0, right: 0,
            child: Center(child: _ScrollFab(onTap: () {
              setState(() => _showScrollFab = false);
              _scrollCtrl.animateTo(
                _scrollCtrl.position.maxScrollExtent + 200,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
              );
            })),
          ),
      ]),
    );
  }

  double get _inputHeight {
    final pad = MediaQuery.of(context).padding.bottom;
    return 72 + pad + (_pendingImages.isNotEmpty ? 70 : 0);
  }

  // ── AppBar ────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: C.card,
      elevation: 0, scrolledUnderElevation: 0,
      toolbarHeight: 52, leadingWidth: 120,
      leading: Row(children: [
        const SizedBox(width: 4),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            child: SizedBox(width: 40, height: 40,
                child: Icon(Icons.menu_rounded, color: C.ink, size: 22)),
          ),
        ),
        const SizedBox(width: 6),
        Text('SkyGen', style: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w800, color: C.ink, letterSpacing: -0.2)),
      ]),
      actions: [
        Material(
          color: Colors.transparent, shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () { if (!_isTempSession) _newTempSession(); },
            child: Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, border: Border.all(color: C.border, width: 1.5)),
              child: Icon(Icons.add_rounded, color: C.ink, size: 20),
            ),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  // ── Drawer ────────────────────────────────────────────────
  Widget _buildDrawer() {
    final filtered = _searchQuery.isEmpty
        ? _sessions
        : _sessions.where((s) =>
            s.title.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Drawer(
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(
        child: Column(children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Row(children: [
              _LogoCircle(size: 34),
              const SizedBox(width: 9),
              Text('SkyGen', style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
              const Spacer(),
              GestureDetector(
                onTap: () { if (!_isTempSession) _newTempSession(); Navigator.pop(context); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: C.accentL, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Icon(Icons.add_rounded, color: C.accent, size: 14),
                    const SizedBox(width: 4),
                    Text('New', style: TextStyle(
                        color: C.accent, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ]),
          ),

          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                  color: C.bg, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: C.border)),
              child: Row(children: [
                const SizedBox(width: 10),
                Icon(Icons.search_rounded, color: C.ink2, size: 15),
                const SizedBox(width: 6),
                Expanded(child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(fontSize: 13, color: C.ink),
                  decoration: InputDecoration(
                    hintText: 'Search chats…',
                    hintStyle: TextStyle(color: C.ink2, fontSize: 13),
                    border: InputBorder.none, isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                )),
                if (_searchQuery.isNotEmpty)
                  GestureDetector(
                    onTap: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); },
                    child: Padding(padding: const EdgeInsets.only(right: 8),
                        child: Icon(Icons.close_rounded, color: C.ink2, size: 13)),
                  ),
              ]),
            ),
          ),

          Divider(height: 1, color: C.border),

          // Session list
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text('No chats yet.',
                    style: TextStyle(color: C.ink2, fontSize: 13)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final s      = filtered[i];
                      if (s.messages.isEmpty) return const SizedBox.shrink();
                      final active = s.id == _currentId && !_isTempSession;
                      return Material(
                        color: active ? C.accentL : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _switchSession(s.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            child: Row(children: [
                              Icon(s.isPinned ? Icons.push_pin_rounded
                                  : Icons.chat_bubble_outline_rounded,
                                  size: 14, color: active ? C.accent : C.ink2),
                              const SizedBox(width: 9),
                              Expanded(child: Text(s.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13,
                                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                      color: active ? C.accent : C.ink))),
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert_rounded, size: 15, color: C.ink2),
                                padding: EdgeInsets.zero, iconSize: 15,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                color: C.card, elevation: 4,
                                onSelected: (val) async {
                                  if (val == 'pin') {
                                    setState(() { s.isPinned = !s.isPinned; _sortSessions(); });
                                    _save();
                                    HapticFeedback.lightImpact();
                                  } else if (val == 'delete') {
                                    final ok = await _confirmDelete();
                                    if (ok) {
                                      await Future.delayed(const Duration(milliseconds: 300));
                                      setState(() {
                                        _sessions.remove(s);
                                        if (_currentId == s.id) _newTempSession();
                                      });
                                      _save();
                                      HapticFeedback.mediumImpact();
                                    }
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'pin',
                                    child: Row(children: [
                                      Icon(s.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                                          size: 14, color: C.accent),
                                      const SizedBox(width: 8),
                                      Text(s.isPinned ? 'Unpin' : 'Pin',
                                          style: TextStyle(fontSize: 13, color: C.ink)),
                                    ])),
                                  PopupMenuItem(value: 'delete',
                                    child: Row(children: [
                                      Icon(Icons.delete_outline_rounded, size: 14, color: C.red),
                                      const SizedBox(width: 8),
                                      Text('Delete', style: TextStyle(fontSize: 13, color: C.red)),
                                    ])),
                                ],
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          Divider(height: 1, color: C.border),

          // Settings button
          InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              _showSettingsSheet();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Icon(Icons.settings_outlined, size: 18, color: C.ink2),
                const SizedBox(width: 10),
                Text('Settings', style: TextStyle(fontSize: 13, color: C.ink, fontWeight: FontWeight.w500)),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, size: 18, color: C.ink2),
              ]),
            ),
          ),

          Divider(height: 1, color: C.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('SkyGen can make mistake, double check output',
                style: TextStyle(fontSize: 10.5, color: C.ink2),
                textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }

  // ── Settings Bottom Sheet ─────────────────────────────────
  void _showSettingsSheet() {
    Navigator.pop(context); // close drawer first
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(
        aiMemory: _aiMemory,
        onClearMemory: (newList) { setState(() => _aiMemory = newList); _saveMemory(); },
        onClearAllChats: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: C.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Delete All Chats',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
              content: Text('All chats will be deleted. Memory and settings will remain.',
                  style: TextStyle(fontSize: 14, color: C.ink2)),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              actions: [Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: C.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: Text('Cancel', style: TextStyle(color: C.ink2, fontWeight: FontWeight.w600)),
                )),
                const SizedBox(width: 10),
                Expanded(child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(backgroundColor: C.red, elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: const Text('Delete All',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                )),
              ])],
            ),
          ) ?? false;
          if (ok) {
            setState(() { _sessions.clear(); _newTempSession(); });
            _save();
            HapticFeedback.heavyImpact();
          }
        },
      ),
    );
  }

  // ── Welcome ───────────────────────────────────────────────
  Widget _buildWelcome() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _LogoCircle(size: 72),
          const SizedBox(height: 18),
          Text('What can I help with?',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.ink),
              textAlign: TextAlign.center),
          const SizedBox(height: 28),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, childAspectRatio: 1.75,
              crossAxisSpacing: 10, mainAxisSpacing: 10,
            ),
            itemCount: _quickCards.length,
            itemBuilder: (ctx, i) {
              final c = _quickCards[i];
              return Material(
                color: C.card, borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14), onTap: () {},
                  child: Container(
                    decoration: BoxDecoration(
                        border: Border.all(color: C.border),
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.all(13),
                    child: Row(children: [
                      Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                            color: (c['color'] as Color).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8)),
                        child: Icon(c['icon'] as IconData,
                            color: c['color'] as Color, size: 15),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(c['label'] as String,
                          style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w700, color: C.ink))),
                    ]),
                  ),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }

  // ── Input ─────────────────────────────────────────────────
  Widget _buildInput() {
    final pad = MediaQuery.of(context).padding.bottom;
    return Container(
      color: C.card,
      child: Column(children: [
        Divider(height: 1, color: C.border),
        if (_pendingImages.isNotEmpty)
          SizedBox(
            height: 70,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              scrollDirection: Axis.horizontal,
              itemCount: _pendingImages.length,
              itemBuilder: (ctx, i) {
                final img = _pendingImages[i];
                return Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 56, height: 56,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: img.isError ? C.red : C.border,
                          width: img.isError ? 2 : 1),
                      image: DecorationImage(
                          image: FileImage(img.file), fit: BoxFit.cover),
                    ),
                    child: img.isLoading
                        ? Container(
                            decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.38),
                                borderRadius: BorderRadius.circular(10)),
                            child: const Center(child: SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))))
                        : img.isError
                            ? Container(
                                decoration: BoxDecoration(
                                    color: C.red.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(10)),
                                child: const Center(
                                    child: Icon(Icons.error_outline, color: Colors.white, size: 20)))
                            : img.uploadedUrl != null
                                ? Align(
                                    alignment: Alignment.bottomRight,
                                    child: Container(
                                      width: 16, height: 16, margin: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                          color: C.green, shape: BoxShape.circle),
                                      child: const Icon(Icons.check, size: 10, color: Colors.white),
                                    ))
                                : null,
                  ),
                  if (!img.isLoading)
                    Positioned(
                      top: -6, right: 2,
                      child: GestureDetector(
                        onTap: () => setState(() => _pendingImages.removeAt(i)),
                        child: Container(
                          width: 18, height: 18,
                          decoration: BoxDecoration(color: C.red, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 11, color: Colors.white)),
                      ),
                    ),
                ]);
              },
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, pad + 6),
          child: Container(
            decoration: BoxDecoration(
                color: C.bg, borderRadius: BorderRadius.circular(18),
                border: Border.all(color: C.border)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 7),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9), onTap: _pickImages,
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                          color: C.accentL, borderRadius: BorderRadius.circular(9)),
                      child: Icon(Icons.image_outlined, color: C.accent, size: 16)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                controller: _inputCtrl,
                enabled: !_isGenerating,
                maxLines: 5, minLines: 1,
                style: TextStyle(fontSize: 14.5, color: C.ink),
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Ask anything...',
                  hintStyle: TextStyle(color: C.ink2, fontSize: 14.5),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
              )),
              Padding(
                padding: const EdgeInsets.only(right: 7, bottom: 7),
                child: GestureDetector(
                  onTap: _isGenerating
                      ? () => setState(() => _stopRequested = true)
                      : _send,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      gradient: _isGenerating ? null
                          : const LinearGradient(colors: [C.grad1, C.grad2],
                              begin: Alignment.topLeft, end: Alignment.bottomRight),
                      color: _isGenerating ? C.red : null,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      _isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                      color: Colors.white, size: 18),
                  ),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: pad > 0 ? 2 : 6),
          child: Text('SkyGen can make mistake, double check output',
              style: TextStyle(fontSize: 10.5, color: C.ink2),
              textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 9. SETTINGS BOTTOM SHEET
// ══════════════════════════════════════════════════════════════

class _SettingsSheet extends StatefulWidget {
  final List<String> aiMemory;
  final void Function(List<String>) onClearMemory;
  final VoidCallback onClearAllChats;

  const _SettingsSheet({
    required this.aiMemory,
    required this.onClearMemory,
    required this.onClearAllChats,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _showMemory    = false;
  bool _showAbout     = false;

  @override
  Widget build(BuildContext context) {
    if (_showMemory) return _buildMemoryPage();
    if (_showAbout)  return _buildAboutPage();
    return _buildMainSheet();
  }

  Widget _buildMainSheet() {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle bar
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          width: 36, height: 4,
          decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
          child: Row(children: [
            Text('Settings', style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
            const Spacer(),
            GestureDetector(
              onTap: () { HapticFeedback.lightImpact(); Navigator.pop(context); },
              child: Container(
                width: 30, height: 30,
                decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.close_rounded, size: 16, color: C.ink2),
              ),
            ),
          ]),
        ),
        Divider(height: 1, color: C.border),

        // Dark mode toggle
        _SettingsTile(
          icon: themeNotifier.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          title: themeNotifier.isDark ? 'Light Mode' : 'Dark Mode',
          trailing: Switch(
            value: themeNotifier.isDark,
            activeColor: C.accent,
            onChanged: (_) { themeNotifier.toggle(); HapticFeedback.lightImpact(); setState(() {}); },
          ),
          onTap: () { themeNotifier.toggle(); HapticFeedback.lightImpact(); setState(() {}); },
        ),

        // Manage Memory
        _SettingsTile(
          icon: Icons.memory_rounded,
          title: 'Manage Memory',
          onTap: () { HapticFeedback.lightImpact(); setState(() => _showMemory = true); },
        ),

        // Delete all chats
        _SettingsTile(
          icon: Icons.delete_sweep_outlined,
          title: 'Delete All Chats',
          iconColor: C.red,
          textColor: C.red,
          onTap: () {
            HapticFeedback.mediumImpact();
            Navigator.pop(context);
            widget.onClearAllChats();
          },
        ),

        // Developer
        _SettingsTile(
          icon: Icons.code_rounded,
          title: 'Developer',
          onTap: () async {
            HapticFeedback.lightImpact();
            final uri = Uri.parse(kDevTg);
            if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
          },
        ),

        // About App
        _SettingsTile(
          icon: Icons.info_outline_rounded,
          title: 'About App',
          onTap: () { HapticFeedback.lightImpact(); setState(() => _showAbout = true); },
        ),

        SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
      ]),
    );
  }

  Widget _buildMemoryPage() {
    final memory = widget.aiMemory;
    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(children: [
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          width: 36, height: 4,
          decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            GestureDetector(
              onTap: () { HapticFeedback.lightImpact(); setState(() => _showMemory = false); },
              child: Icon(Icons.arrow_back_rounded, color: C.ink, size: 22),
            ),
            const SizedBox(width: 12),
            Text('Manage Memory', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
            const Spacer(),
            if (memory.isNotEmpty)
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  widget.onClearMemory([]);
                  setState(() {});
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: C.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text('Clear All', style: TextStyle(color: C.red, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
          ]),
        ),
        Divider(height: 1, color: C.border),
        Expanded(
          child: memory.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.memory_rounded, color: C.ink2, size: 32),
                  const SizedBox(height: 10),
                  Text('No memories yet', style: TextStyle(color: C.ink2, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text('SkyGen will remember useful info from your chats.',
                      style: TextStyle(color: C.ink2, fontSize: 12), textAlign: TextAlign.center),
                ]))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: memory.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: C.border),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(children: [
                      Icon(Icons.circle, size: 6, color: C.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text(memory[i],
                          style: TextStyle(fontSize: 13, color: C.ink))),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          final updated = List<String>.from(memory)..removeAt(i);
                          widget.onClearMemory(updated);
                          setState(() {});
                        },
                        child: Icon(Icons.close_rounded, size: 16, color: C.ink2),
                      ),
                    ]),
                  ),
                ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
      ]),
    );
  }

  Widget _buildAboutPage() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(children: [
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          width: 36, height: 4,
          decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            GestureDetector(
              onTap: () { setState(() => _showAbout = false); },
              child: Icon(Icons.arrow_back_rounded, color: C.ink, size: 22),
            ),
            const SizedBox(width: 12),
            Text('About App', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
          ]),
        ),
        Divider(height: 1, color: C.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: _LogoCircle(size: 64)),
              const SizedBox(height: 16),
              Center(child: Text('SkyGen', style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w800, color: C.ink))),
              Center(child: Text('English AI Tutor',
                  style: TextStyle(fontSize: 13, color: C.ink2))),
              const SizedBox(height: 20),
              _AboutItem(icon: Icons.school_rounded,
                  title: 'What it does',
                  desc: 'SkyGen is your personal English tutor — grammar, translation, vocabulary, SSC/HSC prep, and more.'),
              _AboutItem(icon: Icons.auto_fix_high_rounded,
                  title: 'Key Features',
                  desc: 'Grammar correction • Translation • Tense learning • Essay & letter writing • Image text analysis • Voice reading'),
              _AboutItem(icon: Icons.memory_rounded,
                  title: 'Smart Memory',
                  desc: 'SkyGen remembers important info about you across sessions for a personalized experience.'),
              _AboutItem(icon: Icons.code_rounded,
                  title: 'Developer',
                  desc: 'MD. Jaid Bin Siyam — Hyper Squad\n@BD_Prime_Minister'),
              const SizedBox(height: 8),
              Center(child: Text('Version 1.0.0',
                  style: TextStyle(fontSize: 11, color: C.ink2))),
            ]),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
      ]),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String   title;
  final Widget?  trailing;
  final Color?   iconColor;
  final Color?   textColor;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon, required this.title, required this.onTap,
    this.trailing, this.iconColor, this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 18, color: iconColor ?? C.ink2),
          const SizedBox(width: 14),
          Expanded(child: Text(title, style: TextStyle(
              fontSize: 14, color: textColor ?? C.ink, fontWeight: FontWeight.w500))),
          trailing ?? Icon(Icons.chevron_right_rounded, size: 18, color: C.ink2),
        ]),
      ),
    );
  }
}

class _AboutItem extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String   desc;
  const _AboutItem({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
              color: C.accentL, borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: C.accent, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: C.ink)),
          const SizedBox(height: 3),
          Text(desc, style: TextStyle(fontSize: 12, color: C.ink2, height: 1.45)),
        ])),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 10. SCROLL FAB
// ══════════════════════════════════════════════════════════════

class _ScrollFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: C.card, shape: BoxShape.circle,
          border: Border.all(color: C.border, width: 1.5),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: Icon(Icons.keyboard_double_arrow_down_rounded, color: C.ink, size: 20),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 11. IMAGE FULL SCREEN VIEWER
// ══════════════════════════════════════════════════════════════

class _ImageViewerPage extends StatefulWidget {
  final String imageUrl;
  const _ImageViewerPage({required this.imageUrl});

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  final _transform = TransformationController();

  @override
  void dispose() { _transform.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 0.5, maxScale: 5.0,
          child: CachedNetworkImage(
            imageUrl: widget.imageUrl,
            fit: BoxFit.contain,
            placeholder: (_, __) => const Center(
                child: CircularProgressIndicator(color: Colors.white)),
            errorWidget: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white, size: 48),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 12. BUBBLE WIDGET
// ══════════════════════════════════════════════════════════════

class _BubbleWidget extends StatefulWidget {
  final ChatMsg msg;
  final bool    isPlayingTTS;
  final bool    isTTSLoading;
  final void Function(String, String) onSpeak;
  final void Function(String)         onCopy;
  final void Function(String)         onLike;
  final void Function(String)         onDislike;
  final void Function(String)         onImageTap;

  const _BubbleWidget({
    super.key,
    required this.msg, required this.isPlayingTTS, required this.isTTSLoading,
    required this.onSpeak, required this.onCopy, required this.onLike,
    required this.onDislike, required this.onImageTap,
  });

  @override
  State<_BubbleWidget> createState() => _BubbleState();
}

class _BubbleState extends State<_BubbleWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late Animation<double>   _fadeAnim;
  bool _copiedFlash = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    // Show action bar immediately for already-completed messages (loaded from storage)
    if (widget.msg.type == MsgType.ai && widget.msg.status == GenStatus.completed) {
      _fadeCtrl.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_BubbleWidget old) {
    super.didUpdateWidget(old);
    // Animate in when streaming completes
    if (widget.msg.status == GenStatus.completed &&
        old.msg.status != GenStatus.completed &&
        widget.msg.type == MsgType.ai) {
      _fadeCtrl.forward();
    }
  }

  @override
  void dispose() { _fadeCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.msg.type == MsgType.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: isUser ? _buildUser() : _buildAI(),
    );
  }

  Widget _buildUser() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: GestureDetector(
          // Long press = silent copy, no toast
          onLongPress: () {
            if (widget.msg.text.isNotEmpty) {
              widget.onCopy(widget.msg.text);
              HapticFeedback.mediumImpact();
            }
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (widget.msg.imgUrls?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6, runSpacing: 6, alignment: WrapAlignment.end,
                  children: widget.msg.imgUrls!.map((url) =>
                    GestureDetector(
                      onTap: () => widget.onImageTap(url),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CachedNetworkImage(
                          imageUrl: url, width: 108, height: 108, fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(width: 108, height: 108, color: C.border),
                        ),
                      ),
                    )).toList(),
                ),
              ),
            if (widget.msg.text.isNotEmpty)
              Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: C.userBub,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16), topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
                  ),
                ),
                child: Text(widget.msg.text,
                    style: TextStyle(fontSize: 14.5, color: C.ink, height: 1.45)),
              ),
          ]),
        )),
      ],
    );
  }

  Widget _buildAI() {
    final isWaiting = widget.msg.status == GenStatus.waiting ||
        (widget.msg.status == GenStatus.streaming && widget.msg.visibleText.isEmpty);
    final isDone = widget.msg.status == GenStatus.completed;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isWaiting)
        const _ThinkingDots()
      else ...[
        if (widget.msg.visibleText.isNotEmpty)
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.92),
            child: MarkdownBody(
              data: widget.msg.visibleText,
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: TextStyle(fontSize: 14.5, color: C.ink, height: 1.55),
                code: TextStyle(fontSize: 13, fontFamily: 'monospace',
                    backgroundColor: C.bg, color: C.accent),
                codeblockDecoration: BoxDecoration(
                    color: C.bg, borderRadius: BorderRadius.circular(10)),
                h1: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: C.ink),
                h2: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink),
                h3: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: C.ink),
                strong: TextStyle(fontWeight: FontWeight.w700, color: C.ink),
                tableBorder: TableBorder.all(color: C.border),
                tableHead: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                tableBody: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          ),

        if (widget.msg.status == GenStatus.error)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: C.red.withOpacity(0.08), borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.red.withOpacity(0.2))),
            child: Text(widget.msg.text, style: TextStyle(color: C.red, fontSize: 13)),
          ),

        if (isDone && widget.msg.text.isNotEmpty)
          FadeTransition(
            opacity: _fadeAnim,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _AIActionBar(
                msg: widget.msg,
                isPlayingTTS: widget.isPlayingTTS,
                isTTSLoading: widget.isTTSLoading,
                copiedFlash: _copiedFlash,
                onCopy: () {
                  widget.onCopy(widget.msg.text);
                  HapticFeedback.lightImpact();
                  setState(() => _copiedFlash = true);
                  Future.delayed(const Duration(milliseconds: 1300), () {
                    if (mounted) setState(() => _copiedFlash = false);
                  });
                },
                onSpeak:   () => widget.onSpeak(widget.msg.id, widget.msg.text),
                onLike:    () { widget.onLike(widget.msg.id); HapticFeedback.lightImpact(); },
                onDislike: () { widget.onDislike(widget.msg.id); HapticFeedback.lightImpact(); },
              ),
            ),
          ),
      ],
    ]);
  }
}

// ── AI Action bar ─────────────────────────────────────────────
class _AIActionBar extends StatelessWidget {
  final ChatMsg  msg;
  final bool     isPlayingTTS;
  final bool     isTTSLoading;
  final bool     copiedFlash;
  final VoidCallback onCopy, onSpeak, onLike, onDislike;

  const _AIActionBar({
    required this.msg, required this.isPlayingTTS, required this.isTTSLoading,
    required this.copiedFlash, required this.onCopy, required this.onSpeak,
    required this.onLike, required this.onDislike,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Btn(
        icon:  copiedFlash ? Icons.check_rounded : Icons.copy_rounded,
        color: copiedFlash ? C.green : C.ink2, onTap: onCopy,
      ),
      isTTSLoading
          ? SizedBox(width: 30, height: 30,
              child: Center(child: SizedBox(width: 13, height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2, color: C.ink2))))
          : _Btn(
              icon:  isPlayingTTS ? Icons.pause_rounded : Icons.volume_up_rounded,
              color: isPlayingTTS ? C.accent : C.ink2, onTap: onSpeak,
            ),
      _Btn(icon: Icons.thumb_up_rounded,
          color: msg.liked    ? C.accent : C.ink2, onTap: onLike),
      _Btn(icon: Icons.thumb_down_rounded,
          color: msg.disliked ? C.red    : C.ink2, onTap: onDislike),
    ]);
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final VoidCallback onTap;
  const _Btn({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8), onTap: onTap,
        child: Container(width: 30, height: 30,
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: color)),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 13. THINKING DOTS ANIMATION
// ══════════════════════════════════════════════════════════════

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();
  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_ctrl.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
            final y = sin(t * pi) * 5.0;
            return Transform.translate(
              offset: Offset(0, -y),
              child: Container(
                width: 7, height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: C.accent.withOpacity(0.45 + 0.55 * sin(t * pi)),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
