// ignore_for_file: deprecated_member_use
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

// ═══════════════════════════════════════════════════
// 1. ENTRY POINT
// ═══════════════════════════════════════════════════
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  runApp(const SkyGenApp());
}

// ═══════════════════════════════════════════════════
// 2. THEME
// ═══════════════════════════════════════════════════
class ThemeNotifier extends ChangeNotifier {
  bool _dark = false;
  bool get isDark => _dark;
  void toggle() { _dark = !_dark; notifyListeners(); }
}
final themeNotifier = ThemeNotifier();

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

// ═══════════════════════════════════════════════════
// 3. CONSTANTS
// ═══════════════════════════════════════════════════
const String kLogoUrl  = 'https://www.cdn.hyper-bd.site/photo/logo.png';
const String kDevUrl   = 'https://www.cdn.hyper-bd.site/photo/dev.png';
const String kImgBBKey = '4685fa1e1d227aec0ce07733cd571ff9';
const String kDevTg    = 'https://t.me/BD_Prime_Minister';
const String kDevWa    = 'https://wa.me/8801761844968';

// ═══════════════════════════════════════════════════
// 4. MODELS
// ═══════════════════════════════════════════════════
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
  bool titleGenerated;

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

// ═══════════════════════════════════════════════════
// 5. TTS CACHE (in-memory + disk)
// ═══════════════════════════════════════════════════
class TtsCache {
  static final Map<String, String> _mem = {};
  static Directory? _dir;

  static Future<void> init() async {
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/tts_cache');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
  }

  static String _key(String text) =>
      text.hashCode.toRadixString(16).padLeft(8, '0');

  static Future<String?> get(String text) async {
    final k = _key(text);
    if (_mem.containsKey(k)) return _mem[k];
    if (_dir == null) return null;
    final f = File('${_dir!.path}/$k.mp3');
    if (await f.exists()) {
      _mem[k] = f.path;
      return f.path;
    }
    return null;
  }

  static Future<String> store(String text, List<int> bytes) async {
    final k = _key(text);
    if (_dir == null) await init();
    final f = File('${_dir!.path}/$k.mp3');
    await f.writeAsBytes(bytes);
    _mem[k] = f.path;
    return f.path;
  }
}

// ═══════════════════════════════════════════════════
// 6. ROOT APP
// ═══════════════════════════════════════════════════
class SkyGenApp extends StatefulWidget {
  const SkyGenApp({super.key});
  @override
  State<SkyGenApp> createState() => _SkyGenAppState();
}

class _SkyGenAppState extends State<SkyGenApp> {
  @override
  void initState() {
    super.initState();
    TtsCache.init();
    themeNotifier.addListener(() => setState(() { C.dark = themeNotifier.isDark; }));
  }

  @override
  Widget build(BuildContext context) {
    C.dark = themeNotifier.isDark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: C.dark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: C.bg,
      systemNavigationBarIconBrightness: C.dark ? Brightness.light : Brightness.dark,
    ));
    final brightness = C.dark ? Brightness.dark : Brightness.light;
    return MaterialApp(
      title: 'SkyGen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true, brightness: brightness,
        scaffoldBackgroundColor: C.bg, primaryColor: C.accent,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: C.accent, brightness: brightness),
      ),
      home: const SplashScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════
// 7. REUSABLE LOGO CIRCLE
// ═══════════════════════════════════════════════════
class _LogoCircle extends StatelessWidget {
  final double size;
  final String url;
  const _LogoCircle({required this.size, this.url = kLogoUrl});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url, width: size, height: size, fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: size, height: size,
          decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [C.grad1, C.grad2]), shape: BoxShape.circle),
          child: Icon(Icons.person_rounded, color: Colors.white, size: size * 0.5),
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

// ═══════════════════════════════════════════════════
// 8. SPLASH SCREEN  (improved animation)
// ═══════════════════════════════════════════════════
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen> with TickerProviderStateMixin {
  late AnimationController _logoCtrl, _ringCtrl, _textCtrl;
  late Animation<double> _logoScale, _logoFade, _ringScale, _ringOpacity, _textFade;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const NetworkImage(kLogoUrl), context);
      precacheImage(const NetworkImage(kDevUrl), context);
    });

    _logoCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _ringCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
    _textCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

    _logoScale   = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.elasticOut));
    _logoFade    = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _logoCtrl, curve: const Interval(0.0, 0.4)));
    _ringScale   = Tween(begin: 0.8, end: 1.6).animate(CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOut));
    _ringOpacity = Tween(begin: 0.6, end: 0.0).animate(CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOut));
    _textFade    = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeIn));

    _logoCtrl.forward().then((_) {
      _textCtrl.forward();
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) {
          _ringCtrl.dispose();
          Navigator.of(context).pushReplacement(PageRouteBuilder(
            pageBuilder: (_, __, ___) => const ChatScreen(),
            transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
            transitionDuration: const Duration(milliseconds: 500),
          ));
        }
      });
    });
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    if (_ringCtrl.isAnimating) _ringCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_logoCtrl, _ringCtrl, _textCtrl]),
          builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 160, height: 160,
              child: Stack(alignment: Alignment.center, children: [
                // Pulsing ring
                Transform.scale(
                  scale: _ringScale.value,
                  child: Opacity(
                    opacity: _ringOpacity.value,
                    child: Container(width: 100, height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: C.accent, width: 2),
                      ),
                    ),
                  ),
                ),
                // Second ring offset
                Transform.scale(
                  scale: (_ringScale.value * 0.7).clamp(0.0, 2.0),
                  child: Opacity(
                    opacity: (_ringOpacity.value * 0.5).clamp(0.0, 1.0),
                    child: Container(width: 120, height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: C.grad2, width: 1.5),
                      ),
                    ),
                  ),
                ),
                // Logo
                FadeTransition(
                  opacity: _logoFade,
                  child: Transform.scale(
                    scale: _logoScale.value,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(
                          color: C.accent.withOpacity(0.4),
                          blurRadius: 24, spreadRadius: 2,
                        )],
                      ),
                      child: _LogoCircle(size: 88),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            FadeTransition(
              opacity: _textFade,
              child: Column(children: [
                Text('SkyGen', style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800,
                    color: C.ink, letterSpacing: -0.5)),
                const SizedBox(height: 4),
                Text('English AI Tutor', style: TextStyle(
                    fontSize: 13, color: C.ink2, fontWeight: FontWeight.w500)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// 9. CHAT SCREEN
// ═══════════════════════════════════════════════════
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
  final AudioPlayer _ttsPlayer  = AudioPlayer();
  List<String>      _ttsQueue   = [];   // file paths ready to play
  List<String>      _ttsPending = [];   // text chunks being fetched
  bool   _isPlayingTTS          = false;
  bool   _isTTSLoading          = false;
  String? _speakingId;

  // Scroll FAB
  bool _showScrollFab = false;

  // AI Memory
  List<String> _aiMemory = [];
  String _searchQuery = '';

  // Input has content?
  bool get _canSend {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final hasImg  = _pendingImages.isNotEmpty && !_pendingImages.any((p) => p.isLoading);
    return (hasText || hasImg) && !_isGenerating;
  }

  // ── SYSTEM PROMPT ──────────────────────────────
  final String _sysBase = r"""
You are "SkyGen" — a smart, friendly English language tutor and AI assistant for Bangladeshi students. Created by MD. Jaid Bin Siyam (Hyper Squad). Reveal creator only when user explicitly asks.

════ FORMATTING & RESPONSE STYLE ════
• Always structure responses clearly. Use bullet points, numbered lists, bold headers where helpful.
• Educational answers: use **bold** for key terms, proper headings, clear examples.
• Tables: use markdown tables for comparisons or structured data.
• Keep responses well-organized and easy to scan — not walls of text.
• Greetings (Hi/Hello/How are you) → 1-2 sentences, friendly emojis. 🙂
• Questions (grammar, tenses, vocabulary) → COMPLETE answer with ALL subtypes, rules, examples. Never cut short.
• Translation → translate ONLY, no commentary.
• Writing tasks → full content.
• Always match length to what the question needs.

════ EMOJI USAGE ════
• Greetings: always use 1-2 emojis.
• Educational: use emojis for section headers sparingly (📌 ✏️ 📚 💡).
• Avoid overusing.

════ LANGUAGE RULES ════
• Mirror user's language exactly: Bengali→Bengali, English→English, Banglish→Banglish.
• Grammar terms always in English regardless of reply language.
• Bengali responses may naturally include English grammar terms.

════ TITLE GENERATION ════
ONLY when [GENERATE_TITLE] tag is in instruction:
Add at very END: <<<TITLE: Short meaningful title>>>
Title: 3–6 words, concise, relevant. Professional. NEVER generate unless tag present.

════ MEMORY SYSTEM ════
If user shares important personal info (name, class, age, goals, learning level):
Add at END: <<<MEMORY: ["single clear fact"]>>>
Rules: 20–150 characters per fact. Only genuinely useful long-term facts. One fact at a time unless truly multiple distinct facts exist. Never tell user you're saving memory.

════ SUBJECTS ════
① Grammar — All 12 tenses with full structure, rules, subtypes, examples
② Vocabulary — meanings, synonyms, antonyms, idioms, phrasal verbs
③ Translation — any language pair, translate only
④ Writing — essays, letters, applications, CV, summaries
⑤ Comprehension — passages, main idea, inference
⑥ SSC/HSC Prep — board exam formats, model questions
⑦ Images — analyze text/content from uploaded images
⑧ Spoken English — daily phrases, pronunciation tips

════ OFF-TOPIC ════
"I can only help with English learning! 📚 What would you like to learn today?"
""";

  String _buildSysInstruction({bool needTitle = false}) {
    String full = _sysBase;
    if (needTitle) full += '\n\n[GENERATE_TITLE] — Add <<<TITLE: ...>>> at end of response.';
    if (_aiMemory.isNotEmpty) {
      full += '\n\n════ LONG-TERM USER MEMORY ════\n(Use this to personalize responses)\n';
      for (final m in _aiMemory) full += '• $m\n';
    }
    return full;
  }

  @override
  void initState() {
    super.initState();
    _initStorage();
    _ttsPlayer.onPlayerComplete.listen((_) => _playNextTTS());
    _scrollCtrl.addListener(_onScroll);
    _inputCtrl.addListener(() => setState(() {}));
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
    final dist = _scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels;
    final show = dist > 200;
    if (show != _showScrollFab) setState(() => _showScrollFab = show);
  }

  // ── Storage ──────────────────────────────────────
  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_v6.json');
      _memoryFile  = File('${dir.path}/skygen_mem_v2.json');
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
    try { await _memoryFile!.writeAsString(jsonEncode({'memory': _aiMemory})); } catch (_) {}
  }

  void _addToMemory(List<String> items) {
    for (final item in items) {
      final trimmed = item.trim();
      if (trimmed.length >= 20 && !_aiMemory.contains(trimmed)) {
        _aiMemory.add(trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed);
      }
    }
    if (_aiMemory.length > 10) _aiMemory = _aiMemory.sublist(_aiMemory.length - 10);
    setState(() {});
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

  // ── Network check ─────────────────────────────────
  Future<bool> _hasInternet() async {
    try {
      final r = await http.get(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Image upload (ImgBB) ──────────────────────────
  Future<void> _pickImages() async {
    if (_pendingImages.length >= 3) { _showToast('Maximum 3 images allowed.'); return; }
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      for (final xf in files.take(3 - _pendingImages.length)) {
        final p = PendingImage(file: File(xf.path), localSrc: xf.path);
        setState(() => _pendingImages.add(p));
        _uploadAndAnalyze(p);
      }
    } catch (e) { _showToast('Error: $e'); }
  }

  Future<void> _uploadAndAnalyze(PendingImage p) async {
    try {
      final req = http.MultipartRequest(
          'POST', Uri.parse('https://api.imgbb.com/1/upload?key=$kImgBBKey'));
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
      final r = await http.get(Uri.parse(
          'https://gen-z-describer.vercel.app/api?url=${p.uploadedUrl}'));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body);
        if (d['ok'] == true) p.description = d['results']['description'] as String?;
      }
    } catch (_) {}
  }

  // ── Send ──────────────────────────────────────────
  Future<void> _send() async {
    if (_isGenerating) return;
    final prompt = _inputCtrl.text.trim();
    if (prompt.isEmpty && _pendingImages.isEmpty) return;
    if (_pendingImages.any((p) => p.isLoading)) {
      _showToast('Images still uploading…'); return;
    }

    setState(() => _isGenerating = true);
    final imgs = List<PendingImage>.from(_pendingImages);
    _inputCtrl.clear();
    setState(() => _pendingImages.clear());

    final isFirst = _isTempSession;
    if (_isTempSession) {
      final s = Session(id: _currentId, title: 'New Chat',
          createdAt: DateTime.now().millisecondsSinceEpoch, messages: []);
      setState(() { _sessions.insert(0, s); _isTempSession = false; _sortSessions(); });
    }

    final imgUrls = imgs.where((i) => i.uploadedUrl != null && !i.isError)
        .map((i) => i.uploadedUrl!).toList();

    final userMsg = ChatMsg(
      id: '${DateTime.now().millisecondsSinceEpoch}',
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

  String _buildPrompt(String userPrompt, List<PendingImage> imgs, {required bool needTitle}) {
    String imgCtx = '';
    for (int i = 0; i < imgs.length; i++) {
      if (imgs[i].uploadedUrl == null || imgs[i].isError) continue;
      imgCtx += '\n[Image ${i+1}]\n';
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
    String full = '[System]\n${_buildSysInstruction(needTitle: needTitle)}\n\n';
    if (hist.isNotEmpty)   full += '[History]\n$hist\n';
    if (imgCtx.isNotEmpty) full += '[Images]\n$imgCtx\n';
    full += '[User]: ${userPrompt.isEmpty ? "(image sent)" : userPrompt}';
    return full;
  }

  Future<void> _streamAI(String prompt, List<PendingImage> imgs,
      {required Session sess, required bool isFirst}) async {
    final needTitle = isFirst && !sess.titleGenerated;
    final aiId = 'ai${DateTime.now().millisecondsSinceEpoch}';
    _addAiMsg(aiId, '', GenStatus.waiting);

    try {
      // Check internet first
      if (!await _hasInternet()) {
        _updateStatus(aiId, GenStatus.error,
            text: '⚠️ No internet connection. Please check your network and try again.');
        return;
      }

      final client = http.Client();
      final req    = http.Request('POST', Uri.parse('https://www.api.hyper-bd.site/Ai/'));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'q': _buildPrompt(prompt, imgs, needTitle: needTitle), 'format': 'sse'});

      http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(seconds: 30));
      } catch (_) {
        _updateStatus(aiId, GenStatus.error,
            text: '⚠️ Connection error. Please check your internet and try again.');
        return;
      }

      if (res.statusCode != 200) {
        _updateStatus(aiId, GenStatus.error,
            text: '⚠️ API error (${res.statusCode}). Please try again.');
        client.close();
        return;
      }

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
                _updateText(aiId, _cleanTagsDisplay(streamed));
              }
            } catch (_) {}
          }
        }
      }

      if (!_stopRequested) {
        // Parse TITLE
        if (needTitle) {
          final m = RegExp(r'<<<TITLE:\s*(.+?)>>>').firstMatch(streamed);
          if (m != null) {
            final t  = m.group(1)!.trim();
            final si = _sessions.indexWhere((s) => s.id == _currentId);
            if (si != -1) setState(() { _sessions[si].title = t; _sessions[si].titleGenerated = true; });
            _save();
          }
        }
        // Parse MEMORY
        final mm = RegExp(r'<<<MEMORY:\s*(\[[\s\S]+?\])>>>').firstMatch(streamed);
        if (mm != null) {
          try {
            final arr = jsonDecode(mm.group(1)!) as List;
            _addToMemory(arr.map((e) => e.toString()).toList());
          } catch (_) {}
        }
        _updateStatus(aiId, GenStatus.completed, text: _cleanTags(streamed));
      }
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('socket') || msg.contains('network') ||
          msg.contains('dns') || msg.contains('connection')) {
        _updateStatus(aiId, GenStatus.error,
            text: '⚠️ No internet connection. Please check your network.');
      } else {
        _updateStatus(aiId, GenStatus.error,
            text: '⚠️ Something went wrong. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _save();
    }
  }

  String _cleanTags(String t) => t
      .replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '')
      .replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '')
      .trim();

  String _cleanTagsDisplay(String t) {
    String c = t
        .replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '')
        .replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '');
    c = c.replaceAll(RegExp(r'<{1,3}[^>]*$'), '');
    return c.trim();
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

  // ── TTS  (parallel pre-fetch + disk cache) ────────
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
      _ttsPending.clear();
    });

    final chunks = _chunkText(text.replaceAll(RegExp(r'```[\s\S]*?```'), ''));
    if (chunks.isEmpty) {
      setState(() { _isTTSLoading = false; _speakingId = null; });
      return;
    }

    // Fetch all chunks in parallel (with cache)
    try {
      final paths = await Future.wait(chunks.map(_fetchTTSPath));
      if (!mounted) return;
      // First chunk ready → start playing immediately, others will queue
      setState(() { _isTTSLoading = false; _isPlayingTTS = true; _ttsQueue = paths; });
      await _playNextTTS();
    } catch (_) {
      if (mounted) setState(() { _isTTSLoading = false; _isPlayingTTS = false; _speakingId = null; });
    }
  }

  Future<String> _fetchTTSPath(String text) async {
    // Check cache first
    final cached = await TtsCache.get(text);
    if (cached != null) return cached;

    // Download
    final url = 'https://murf.ai/Prod/anonymous-tts/audio'
        '?text=${Uri.encodeComponent(text)}'
        '&voiceId=VM017230562791058FV&style=Conversational';
    final res = await http.get(Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0', 'Accept': 'audio/mpeg, */*'});
    if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
      return await TtsCache.store(text, res.bodyBytes);
    }
    throw Exception('TTS fetch failed');
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

  Future<void> _playNextTTS() async {
    if (_ttsQueue.isEmpty) {
      setState(() { _isPlayingTTS = false; _speakingId = null; });
      return;
    }
    final path = _ttsQueue.removeAt(0);
    try { await _ttsPlayer.play(DeviceFileSource(path)); } catch (_) { _playNextTTS(); }
  }

  // ── Reaction ──────────────────────────────────────
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

  // ── Delete confirm ────────────────────────────────
  Future<bool> _confirmDelete(BuildContext ctx) async {
    return await showDialog<bool>(
      context: ctx, barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: C.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete Chat', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
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
            child: const Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          )),
        ])],
      ),
    ) ?? false;
  }

  // ── Rename dialog ─────────────────────────────────
  Future<void> _renameSession(Session s) async {
    final ctrl = TextEditingController(text: s.title);
    final ok   = await showDialog<bool>(
      context: context, barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: C.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Rename Chat', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
        content: TextField(
          controller: ctrl,
          maxLength: 100, maxLines: 1,
          style: TextStyle(fontSize: 14, color: C.ink),
          decoration: InputDecoration(
            counterText: '',
            hintText: 'Chat title…',
            hintStyle: TextStyle(color: C.ink2),
            filled: true, fillColor: C.bg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: C.border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: C.accent)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
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
              backgroundColor: C.accent, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          )),
        ])],
      ),
    ) ?? false;
    ctrl.dispose();
    if (ok) {
      final newTitle = ctrl.text.trim();
      if (newTitle.isNotEmpty) {
        setState(() => s.title = newTitle);
        _save();
      }
    }
  }

  // ── Toast (center overlay) ────────────────────────
  OverlayEntry? _toastEntry;
  void _showToast(String msg) {
    _toastEntry?.remove();
    _toastEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: 40, right: 40,
        top: MediaQuery.of(context).size.height * 0.44,
        child: Material(
          color: Colors.transparent,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
                color: C.ink.withOpacity(0.9), borderRadius: BorderRadius.circular(20)),
            child: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center),
          )),
        ),
      ),
    );
    Overlay.of(context).insert(_toastEntry!);
    Future.delayed(const Duration(milliseconds: 1600), () {
      _toastEntry?.remove(); _toastEntry = null;
    });
  }

  // ── Image fullscreen viewer ───────────────────────
  void _openImage(String url) => Navigator.push(context, MaterialPageRoute(
      builder: (_) => _ImageViewerPage(imageUrl: url)));

  // ═══════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final msgs = _curSession.messages;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: C.bg,
      drawer: _buildDrawer(),
      appBar: _buildAppBar(),
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
                        key: ValueKey(msgs[i].id),
                        msg: msgs[i],
                        isPlayingTTS: _isPlayingTTS && _speakingId == msgs[i].id,
                        isTTSLoading: _isTTSLoading && _speakingId == msgs[i].id,
                        onSpeak:    (id, t) => _handleTTS(id, t),
                        onCopy:     (t) {
                          Clipboard.setData(ClipboardData(text: t));
                          _showToast('Copied ✓');
                        },
                        onLike:     (id) => _setReaction(id, true),
                        onDislike:  (id) => _setReaction(id, false),
                        onImageTap: (url) => _openImage(url),
                      ),
                    ),
                  ),
          ),
          _buildInput(),
        ]),
        // Scroll FAB
        AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          bottom: _showScrollFab ? _inputHeight + 12 : -60,
          left: 0, right: 0,
          child: Center(child: _ScrollFab(onTap: () {
            setState(() => _showScrollFab = false);
            _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent + 200,
                duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          })),
        ),
      ]),
    );
  }

  double get _inputHeight {
    final pad = MediaQuery.of(context).padding.bottom;
    return 72 + pad + (_pendingImages.isNotEmpty ? 72 : 0);
  }

  // ── AppBar ─────────────────────────────────────────
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: C.card,
      elevation: 0, scrolledUnderElevation: 0,
      toolbarHeight: 52, leadingWidth: 130,
      leading: Row(children: [
        const SizedBox(width: 4),
        Tooltip(
          message: 'Menu',
          child: Material(color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
              child: SizedBox(width: 40, height: 40,
                  child: Icon(Icons.menu_rounded, color: C.ink, size: 22)),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text('SkyGen', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800,
            color: C.ink, letterSpacing: -0.2)),
      ]),
      actions: [
        Tooltip(
          message: 'New Chat',
          child: Material(color: Colors.transparent, shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () { if (!_isTempSession) _newTempSession(); },
              child: Container(width: 38, height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    border: Border.all(color: C.border, width: 1.5)),
                child: Icon(Icons.add_rounded, color: C.ink, size: 20)),
            ),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  // ── Drawer ─────────────────────────────────────────
  Widget _buildDrawer() {
    final filtered = _searchQuery.isEmpty
        ? _sessions
        : _sessions.where((s) =>
            s.title.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Drawer(
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(child: Column(children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
          child: Row(children: [
            _LogoCircle(size: 34),
            const SizedBox(width: 9),
            Text('SkyGen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
            const Spacer(),
            // Theme toggle icon
            Tooltip(
              message: C.dark ? 'Light Mode' : 'Dark Mode',
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => RotationTransition(
                    turns: anim, child: FadeTransition(opacity: anim, child: child)),
                child: Material(
                  key: ValueKey(C.dark),
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () { themeNotifier.toggle(); HapticFeedback.lightImpact(); },
                    child: Container(
                      width: 34, height: 34,
                      alignment: Alignment.center,
                      child: Icon(
                        C.dark ? Icons.wb_sunny_rounded : Icons.nightlight_round,
                        color: C.dark ? const Color(0xFFFBBF24) : const Color(0xFF6366F1),
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // New chat icon only
            Tooltip(
              message: 'New Chat',
              child: Material(color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () { if (!_isTempSession) _newTempSession(); Navigator.pop(context); },
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.add_rounded, color: C.accent, size: 18),
                  ),
                ),
              ),
            ),
          ]),
        ),

        // Search
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Container(
            height: 36,
            decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10),
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
                  border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero,
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

        // Session list with AnimatedList-style
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text('No chats yet.', style: TextStyle(color: C.ink2, fontSize: 13)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final s      = filtered[i];
                    if (s.messages.isEmpty) return const SizedBox.shrink();
                    final active = s.id == _currentId && !_isTempSession;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(vertical: 1),
                      decoration: BoxDecoration(
                        color: active ? C.accentL : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _switchSession(s.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: Row(children: [
                              Icon(s.isPinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
                                  size: 13, color: active ? C.accent : C.ink2),
                              const SizedBox(width: 8),
                              Expanded(child: Text(s.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13,
                                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                      color: active ? C.accent : C.ink))),
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert_rounded, size: 14, color: C.ink2),
                                padding: EdgeInsets.zero, iconSize: 14,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                color: C.card, elevation: 4,
                                onSelected: (val) async {
                                  if (val == 'pin') {
                                    HapticFeedback.lightImpact();
                                    setState(() { s.isPinned = !s.isPinned; _sortSessions(); });
                                    _save();
                                  } else if (val == 'rename') {
                                    await _renameSession(s);
                                  } else if (val == 'delete') {
                                    final ok = await _confirmDelete(ctx);
                                    if (ok) {
                                      HapticFeedback.mediumImpact();
                                      await Future.delayed(const Duration(milliseconds: 250));
                                      setState(() {
                                        _sessions.remove(s);
                                        if (_currentId == s.id) _newTempSession();
                                      });
                                      _save();
                                    }
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'pin', child: Row(children: [
                                    Icon(s.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                                        size: 14, color: C.accent),
                                    const SizedBox(width: 8),
                                    Text(s.isPinned ? 'Unpin' : 'Pin',
                                        style: TextStyle(fontSize: 13, color: C.ink)),
                                  ])),
                                  PopupMenuItem(value: 'rename', child: Row(children: [
                                    Icon(Icons.edit_rounded, size: 14, color: C.ink2),
                                    const SizedBox(width: 8),
                                    Text('Rename', style: TextStyle(fontSize: 13, color: C.ink)),
                                  ])),
                                  PopupMenuItem(value: 'delete', child: Row(children: [
                                    Icon(Icons.delete_outline_rounded, size: 14, color: C.red),
                                    const SizedBox(width: 8),
                                    Text('Delete', style: TextStyle(fontSize: 13, color: C.red)),
                                  ])),
                                ],
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        Divider(height: 1, color: C.border),
        // Settings button
        InkWell(
          onTap: () { HapticFeedback.lightImpact(); _showSettings(); },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Icon(Icons.settings_outlined, size: 17, color: C.ink2),
              const SizedBox(width: 10),
              Text('Settings', style: TextStyle(fontSize: 13, color: C.ink, fontWeight: FontWeight.w500)),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 17, color: C.ink2),
            ]),
          ),
        ),
        Divider(height: 1, color: C.border),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('SkyGen can make mistake, double check output',
              style: TextStyle(fontSize: 10, color: C.ink2),
              textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ])),
    );
  }

  // ── Settings sheet ────────────────────────────────
  void _showSettings() {
    Navigator.pop(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(
        aiMemory: _aiMemory,
        onClearMemory: (list) { setState(() => _aiMemory = list); _saveMemory(); },
        onClearAllChats: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: C.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Delete All Chats',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
              content: Text('All chats will be deleted. Memory will remain.',
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

  // ── Welcome screen ────────────────────────────────
  Widget _buildWelcome() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _LogoCircle(size: 72),
          const SizedBox(height: 16),
          Text('What can I help with?',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.ink),
              textAlign: TextAlign.center),
          const SizedBox(height: 28),
          GridView.builder(
            shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, childAspectRatio: 1.75,
              crossAxisSpacing: 10, mainAxisSpacing: 10,
            ),
            itemCount: 4,
            itemBuilder: (ctx, i) {
              final cards = [
                {'icon': Icons.auto_fix_high_rounded, 'label': 'Grammar Check',  'color': C.grad1},
                {'icon': Icons.translate_rounded,     'label': 'Translation',    'color': C.green},
                {'icon': Icons.school_rounded,        'label': 'Learn Tenses',   'color': const Color(0xFFF59E0B)},
                {'icon': Icons.edit_note_rounded,     'label': 'Essay Writing',  'color': C.red},
              ];
              final c = cards[i];
              return Material(
                color: C.card, borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14), onTap: () {},
                  child: Container(
                    decoration: BoxDecoration(
                        border: Border.all(color: C.border), borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.all(13),
                    child: Row(children: [
                      Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                            color: (c['color'] as Color).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8)),
                        child: Icon(c['icon'] as IconData, color: c['color'] as Color, size: 15),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(c['label'] as String,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.ink))),
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

  // ── Input area ────────────────────────────────────
  Widget _buildInput() {
    final pad = MediaQuery.of(context).padding.bottom;
    final active = _canSend;
    return Container(
      color: C.card,
      child: Column(children: [
        Divider(height: 1, color: C.border),
        // Image previews
        if (_pendingImages.isNotEmpty)
          SizedBox(height: 72,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              scrollDirection: Axis.horizontal,
              itemCount: _pendingImages.length,
              itemBuilder: (ctx, i) {
                final img = _pendingImages[i];
                return Stack(clipBehavior: Clip.none, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 56, height: 56,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: img.isError ? C.red : (img.isLoading ? C.border : C.green),
                          width: img.isError ? 2 : 1.5),
                      image: DecorationImage(image: FileImage(img.file), fit: BoxFit.cover),
                    ),
                    child: img.isLoading
                        ? Container(
                            decoration: BoxDecoration(color: Colors.black.withOpacity(0.38),
                                borderRadius: BorderRadius.circular(10)),
                            child: const Center(child: SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))))
                        : img.isError
                            ? Container(
                                decoration: BoxDecoration(color: C.red.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(10)),
                                child: const Center(child: Icon(Icons.error_outline, color: Colors.white, size: 20)))
                            : Align(alignment: Alignment.bottomRight,
                                child: Container(width: 15, height: 15, margin: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(color: C.green, shape: BoxShape.circle),
                                  child: const Icon(Icons.check, size: 9, color: Colors.white))),
                  ),
                  if (!img.isLoading)
                    Positioned(top: -6, right: 2,
                      child: GestureDetector(
                        onTap: () => setState(() => _pendingImages.removeAt(i)),
                        child: Container(width: 18, height: 18,
                          decoration: BoxDecoration(color: C.red, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 11, color: Colors.white)),
                      )),
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
              Tooltip(
                message: 'Attach image',
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 7),
                  child: Material(color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(9), onTap: _pickImages,
                      child: Container(width: 32, height: 32,
                        decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(9)),
                        child: Icon(Icons.image_outlined, color: C.accent, size: 16)),
                    ),
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
              Tooltip(
                message: _isGenerating ? 'Stop' : 'Send message',
                child: Padding(
                  padding: const EdgeInsets.only(right: 7, bottom: 7),
                  child: GestureDetector(
                    onTap: _isGenerating ? () => setState(() => _stopRequested = true) : _send,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        gradient: (_isGenerating || active)
                            ? const LinearGradient(colors: [C.grad1, C.grad2],
                                begin: Alignment.topLeft, end: Alignment.bottomRight)
                            : null,
                        color: (!_isGenerating && !active) ? C.ink2.withOpacity(0.3) : null,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        _isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                        color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: pad > 0 ? 2 : 6),
          child: Text('SkyGen can make mistake, double check output',
              style: TextStyle(fontSize: 10, color: C.ink2),
              textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════
// 10. SETTINGS SHEET
// ═══════════════════════════════════════════════════
class _SettingsSheet extends StatefulWidget {
  final List<String>       aiMemory;
  final void Function(List<String>) onClearMemory;
  final VoidCallback       onClearAllChats;
  const _SettingsSheet({required this.aiMemory, required this.onClearMemory, required this.onClearAllChats});
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _showMemory = false;
  bool _showAbout  = false;
  bool _showDev    = false;

  @override
  Widget build(BuildContext context) {
    if (_showMemory) return _memoryPage();
    if (_showAbout)  return _aboutPage();
    if (_showDev)    return _devPage();
    return _mainSheet();
  }

  Widget _handle() => Container(
    margin: const EdgeInsets.only(top: 10, bottom: 4),
    width: 36, height: 4,
    decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3)),
  );

  Widget _mainSheet() {
    return Container(
      decoration: BoxDecoration(color: C.card,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 16, 10),
          child: Row(children: [
            Text('Settings', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
            const Spacer(),
            GestureDetector(
              onTap: () { HapticFeedback.lightImpact(); Navigator.pop(context); },
              child: Container(width: 30, height: 30,
                decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.close_rounded, size: 16, color: C.ink2)),
            ),
          ]),
        ),
        Divider(height: 1, color: C.border),
        _tile(icon: Icons.memory_rounded, title: 'Manage Memory',
            onTap: () { HapticFeedback.lightImpact(); setState(() => _showMemory = true); }),
        _tile(icon: Icons.delete_sweep_outlined, title: 'Delete All Chats',
            onTap: () { HapticFeedback.mediumImpact(); widget.onClearAllChats(); }),
        _tile(icon: Icons.code_rounded, title: 'Developer',
            onTap: () { HapticFeedback.lightImpact(); setState(() => _showDev = true); }),
        _tile(icon: Icons.info_outline_rounded, title: 'About App',
            onTap: () { HapticFeedback.lightImpact(); setState(() => _showAbout = true); }),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
      ]),
    );
  }

  Widget _tile({required IconData icon, required String title, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 18, color: C.ink2),
          const SizedBox(width: 14),
          Expanded(child: Text(title, style: TextStyle(fontSize: 14, color: C.ink, fontWeight: FontWeight.w500))),
          Icon(Icons.chevron_right_rounded, size: 18, color: C.ink2),
        ]),
      ),
    );
  }

  Widget _subPageShell({required String title, required Widget child,
      required VoidCallback onBack, double heightFactor = 0.65}) {
    return Container(
      height: MediaQuery.of(context).size.height * heightFactor,
      decoration: BoxDecoration(color: C.card,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      child: Column(children: [
        _handle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Row(children: [
            GestureDetector(onTap: onBack,
                child: Icon(Icons.arrow_back_rounded, color: C.ink, size: 22)),
            const SizedBox(width: 12),
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
          ]),
        ),
        Divider(height: 1, color: C.border),
        Expanded(child: child),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
      ]),
    );
  }

  Widget _memoryPage() {
    final mem = widget.aiMemory;
    return _subPageShell(
      title: 'Manage Memory',
      onBack: () => setState(() => _showMemory = false),
      child: mem.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.memory_rounded, color: C.ink2, size: 32),
              const SizedBox(height: 10),
              Text('No memories yet', style: TextStyle(color: C.ink2, fontSize: 14)),
              const SizedBox(height: 6),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text('SkyGen will remember important info from your chats.',
                    style: TextStyle(color: C.ink2, fontSize: 12), textAlign: TextAlign.center)),
            ]))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(children: [
                  Text('${mem.length} item${mem.length > 1 ? "s" : ""}',
                      style: TextStyle(fontSize: 12, color: C.ink2)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () { widget.onClearMemory([]); setState(() {}); HapticFeedback.mediumImpact(); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          color: C.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text('Clear All', style: TextStyle(color: C.red, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
              ),
              Expanded(child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: mem.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: C.border),
                itemBuilder: (_, i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 6, height: 6, margin: const EdgeInsets.only(top: 6, right: 12),
                        decoration: BoxDecoration(color: C.accent, shape: BoxShape.circle),
                      ),
                      Expanded(child: Text(mem[i], style: TextStyle(fontSize: 13, color: C.ink, height: 1.4))),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          final upd = List<String>.from(mem)..removeAt(i);
                          widget.onClearMemory(upd);
                          setState(() {});
                        },
                        child: Icon(Icons.close_rounded, size: 16, color: C.ink2),
                      ),
                    ]),
                  ),
                ),
              )),
            ]),
    );
  }

  Widget _aboutPage() {
    return _subPageShell(
      title: 'About App', heightFactor: 0.72,
      onBack: () => setState(() => _showAbout = false),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: _LogoCircle(size: 64)),
          const SizedBox(height: 14),
          Center(child: Text('SkyGen', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.ink))),
          Center(child: Text('English AI Tutor', style: TextStyle(fontSize: 12, color: C.ink2))),
          const SizedBox(height: 20),
          _aboutItem(Icons.school_rounded, 'What is SkyGen?',
              'SkyGen is a powerful AI-powered English tutor built specifically for Bangladeshi students. It helps with grammar, translation, vocabulary, writing, and exam prep — all in one place.'),
          _aboutItem(Icons.auto_fix_high_rounded, 'Key Features',
              '• Grammar correction & explanation\n• English ↔ Bengali translation\n• All 12 tenses with full breakdown\n• Essay, letter & application writing\n• SSC / HSC board exam preparation\n• Image text analysis (OCR)\n• Voice reading (TTS)\n• Smart AI memory across sessions'),
          _aboutItem(Icons.memory_rounded, 'Smart Memory',
              'SkyGen remembers important information about you — like your class, learning goals, and preferences — so every conversation feels personalized.'),
          _aboutItem(Icons.language_rounded, 'Language Support',
              'SkyGen mirrors your language naturally. Chat in Bengali, English, or Banglish — SkyGen will respond the same way.'),
          _aboutItem(Icons.verified_rounded, 'Accuracy',
              'While SkyGen strives for accuracy, it can occasionally make mistakes. Always double-check important answers, especially for exams.'),
          const SizedBox(height: 8),
          Center(child: Text('Version 1.0.0', style: TextStyle(fontSize: 11, color: C.ink2))),
        ]),
      ),
    );
  }

  Widget _devPage() {
    return _subPageShell(
      title: 'Developer', heightFactor: 0.75,
      onBack: () => setState(() => _showDev = false),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: _LogoCircle(size: 64, url: kDevUrl)),
          const SizedBox(height: 14),
          Center(child: Text('MD. Jaid Bin Siyam', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: C.ink))),
          Center(child: Text('Student & Developer · Hyper Squad', style: TextStyle(fontSize: 12, color: C.ink2))),
          const SizedBox(height: 22),
          _aboutItem(Icons.person_rounded, 'About',
              'A passionate developer from Bangladesh, currently a student. Builds apps, websites, Telegram bots, and automation tools alongside his studies — driven by curiosity and a love for technology.'),
          _aboutItem(Icons.code_rounded, 'What he does',
              '• Flutter & mobile app development\n• Web development & backend systems\n• Telegram bot development\n• Automation & scripting\n• AI-powered tools and products'),
          _aboutItem(Icons.stars_rounded, 'SkyGen',
              'SkyGen is one of his personal projects — built to help fellow students master English with the help of AI. Every feature is crafted with care.'),
          const SizedBox(height: 16),
          Text('Contact', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: C.ink)),
          const SizedBox(height: 10),
          _contactBtn(Icons.telegram, 'Telegram', kDevTg),
          const SizedBox(height: 8),
          _contactBtn(Icons.chat_rounded, 'WhatsApp', kDevWa),
        ]),
      ),
    );
  }

  Widget _aboutItem(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 34, height: 34,
          decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: C.accent, size: 16)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: C.ink)),
          const SizedBox(height: 3),
          Text(desc, style: TextStyle(fontSize: 12, color: C.ink2, height: 1.5)),
        ])),
      ]),
    );
  }

  Widget _contactBtn(IconData icon, String label, String url) {
    return Material(
      color: C.bg, borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          HapticFeedback.lightImpact();
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
              border: Border.all(color: C.border), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(icon, size: 18, color: C.accent),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.ink)),
            const Spacer(),
            Icon(Icons.open_in_new_rounded, size: 14, color: C.ink2),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// 11. SCROLL FAB
// ═══════════════════════════════════════════════════
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
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1),
              blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: Icon(Icons.keyboard_double_arrow_down_rounded, color: C.ink, size: 20),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// 12. IMAGE VIEWER
// ═══════════════════════════════════════════════════
class _ImageViewerPage extends StatefulWidget {
  final String imageUrl;
  const _ImageViewerPage({required this.imageUrl});
  @override
  State<_ImageViewerPage> createState() => _ImageViewerState();
}
class _ImageViewerState extends State<_ImageViewerPage> {
  final _tc = TransformationController();
  @override
  void dispose() { _tc.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          leading: IconButton(icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.pop(context))),
      body: Center(child: InteractiveViewer(
        transformationController: _tc, minScale: 0.5, maxScale: 5.0,
        child: CachedNetworkImage(
          imageUrl: widget.imageUrl, fit: BoxFit.contain,
          placeholder: (_, __) => const Center(child: CircularProgressIndicator(color: Colors.white)),
          errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white, size: 48),
        ),
      )),
    );
  }
}

// ═══════════════════════════════════════════════════
// 13. BUBBLE WIDGET
// ═══════════════════════════════════════════════════
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
    super.key, required this.msg, required this.isPlayingTTS, required this.isTTSLoading,
    required this.onSpeak, required this.onCopy, required this.onLike,
    required this.onDislike, required this.onImageTap,
  });
  @override
  State<_BubbleWidget> createState() => _BubbleState();
}

class _BubbleState extends State<_BubbleWidget> with SingleTickerProviderStateMixin {
  late AnimationController _fc;
  late Animation<double>   _fa;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _fc = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _fa = CurvedAnimation(parent: _fc, curve: Curves.easeOut);
    // Show actions immediately for already-completed messages
    if (widget.msg.type == MsgType.ai && widget.msg.status == GenStatus.completed) {
      _fc.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_BubbleWidget old) {
    super.didUpdateWidget(old);
    if (widget.msg.status == GenStatus.completed &&
        old.msg.status != GenStatus.completed &&
        widget.msg.type == MsgType.ai) {
      _fc.forward();
    }
  }

  @override
  void dispose() { _fc.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: widget.msg.type == MsgType.user ? _user() : _ai(),
    );
  }

  Widget _user() => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [Flexible(child: GestureDetector(
      onLongPress: () {
        if (widget.msg.text.isNotEmpty) {
          widget.onCopy(widget.msg.text);
          HapticFeedback.mediumImpact();
        }
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (widget.msg.imgUrls?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end,
              children: widget.msg.imgUrls!.map((url) => GestureDetector(
                onTap: () => widget.onImageTap(url),
                child: ClipRRect(borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(imageUrl: url, width: 108, height: 108, fit: BoxFit.cover,
                    placeholder: (_, __) => Container(width: 108, height: 108, color: C.border))),
              )).toList(),
            ),
          ),
        if (widget.msg.text.isNotEmpty)
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
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
    ))],
  );

  Widget _ai() {
    final isWaiting = widget.msg.status == GenStatus.waiting ||
        (widget.msg.status == GenStatus.streaming && widget.msg.visibleText.isEmpty);
    final isDone = widget.msg.status == GenStatus.completed;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isWaiting)
        const _ThinkingDots()
      else ...[
        if (widget.msg.visibleText.isNotEmpty)
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
            child: MarkdownBody(
              data: widget.msg.visibleText, selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: TextStyle(fontSize: 14.5, color: C.ink, height: 1.6),
                code: TextStyle(fontSize: 13, fontFamily: 'monospace', backgroundColor: C.bg, color: C.accent),
                codeblockDecoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10)),
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
            opacity: _fa,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _aBtn(
                  icon:  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  color: _copied ? C.green : C.ink2,
                  tip:   'Copy',
                  onTap: () {
                    widget.onCopy(widget.msg.text);
                    HapticFeedback.lightImpact();
                    setState(() => _copied = true);
                    Future.delayed(const Duration(milliseconds: 1300),
                        () { if (mounted) setState(() => _copied = false); });
                  },
                ),
                widget.isTTSLoading
                    ? SizedBox(width: 30, height: 30,
                        child: Center(child: SizedBox(width: 13, height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2, color: C.ink2))))
                    : _aBtn(
                        icon:  widget.isPlayingTTS ? Icons.pause_rounded : Icons.volume_up_rounded,
                        color: widget.isPlayingTTS ? C.accent : C.ink2,
                        tip:   widget.isPlayingTTS ? 'Pause' : 'Listen',
                        onTap: () => widget.onSpeak(widget.msg.id, widget.msg.text),
                      ),
                _aBtn(icon: Icons.thumb_up_rounded,
                    color: widget.msg.liked    ? C.accent : C.ink2, tip: 'Like',
                    onTap: () { widget.onLike(widget.msg.id); HapticFeedback.lightImpact(); }),
                _aBtn(icon: Icons.thumb_down_rounded,
                    color: widget.msg.disliked ? C.red    : C.ink2, tip: 'Dislike',
                    onTap: () { widget.onDislike(widget.msg.id); HapticFeedback.lightImpact(); }),
              ]),
            ),
          ),
      ],
    ]);
  }

  Widget _aBtn({required IconData icon, required Color color,
      required String tip, required VoidCallback onTap}) {
    return Tooltip(
      message: tip,
      child: Material(color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap,
          child: Container(width: 30, height: 30, alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(icon, key: ValueKey(icon), size: 15, color: color),
              ))),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// 14. THINKING DOTS
// ═══════════════════════════════════════════════════
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();
  @override
  State<_ThinkingDots> createState() => _TDState();
}
class _TDState extends State<_ThinkingDots> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Row(mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_c.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(0, -sin(t * pi) * 5.0),
              child: Container(
                width: 7, height: 7, margin: const EdgeInsets.only(right: 5),
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
