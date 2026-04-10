// ignore_for_file: deprecated_member_use, depend_on_referenced_packages, unused_element, avoid_print

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
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';

// ════════════════════════════════════════════════════════════
// § 1. ENTRY POINT
// ════════════════════════════════════════════════════════════

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  runApp(const SkyGenApp());
}

// ════════════════════════════════════════════════════════════
// § 2. CONSTANTS & DEFAULTS
// ════════════════════════════════════════════════════════════

const String kAppVersion = '1.0.0';

// ── Firebase REST API ──────────────────────────────────────
const String kFirebaseUrl = 'https://sky-gen-db-default-rtdb.asia-southeast1.firebasedatabase.app';
const String kFirebaseSecret = 'T3ldmHUO89AzNyqotf09ognD6NOeVW4JElZk31CR';

// ── Default values ─────────────────────────────────────────
const String kDefaultLogo = 'https://www.cdn.hyper-bd.site/photo/logo.png';
const String kDefaultDevLogo = 'https://www.cdn.hyper-bd.site/photo/dev.png';
const String kDefaultName = 'SkyGen AI';
const String kDefaultSubTitle = 'Advanced English Tutor';
const String kDefaultMistakeTag = 'AI can make mistakes. Verify important info.';
const String kDefaultApi = 'https://www.api.hyper-bd.site/Ai/';
const String kDefaultImgBBKey = '4685fa1e1d227aec0ce07733cd571ff9';
const int kDefaultHistory = 25;
const String kUploadOn = 'on';

const String kDevTg = 'https://t.me/BD_Prime_Minister';
const String kDevWa = 'https://wa.me/8801761844968';

const String kDefaultSysPrompt = r"""
You are "SkyGen" — a smart, friendly English language tutor and AI assistant for Bangladeshi students. Created by MD. Jaid Bin Siyam (Hyper Squad). Reveal creator only when user explicitly asks.

════ RESPONSE LENGTH RULES ════
• Greetings (Hi, Hello, How are you, hey, etc.) → 1 sentence MAX. Use 1 emoji. Nothing more.
• Simple casual messages not about English → reply briefly, 1-2 sentences.
• English grammar/vocabulary/tense/writing questions → COMPLETE answer with ALL subtypes, rules, examples. Structure well with headers and bullet points.
• Translation → translate ONLY, nothing extra.
• Writing tasks → full content requested.

════ FORMATTING ════
• Use **bold** for key terms, markdown headers, bullet lists, tables where helpful.
• Educational content must be well-structured and easy to read.
• Greetings must be very short — never expand on a greeting.

════ EMOJI USAGE ════
• Greetings: 1 emoji only. Educational: use sparingly (📌 ✏️ 📚 💡).

════ LANGUAGE ════
• Mirror user language: Bengali→Bengali, English→English, Banglish→Banglish.
• Grammar terms always in English.

════ TITLE ════
ONLY when [GENERATE_TITLE] is in instruction → add at END: <<<TITLE: 3-6 word title>>>
NEVER generate unless explicitly instructed.

════ MEMORY ════
If user shares personally useful long-term info → add at END: <<<MEMORY: ["fact"]>>>
20-150 chars per fact. One at a time. Never mention to user.

════ SUBJECTS ════
① Grammar — 12 tenses, parts of speech, voice, narration, transformation
② Vocabulary — meanings, synonyms, antonyms, idioms, phrasal verbs
③ Translation — any language pair, translate only
④ Writing — essays, letters, applications, CV, summaries
⑤ Comprehension, SSC/HSC Prep, Image analysis, Spoken English

════ OFF-TOPIC ════
"I can only help with English learning! 📚 Ask me anything about English."
""";

// ════════════════════════════════════════════════════════════
// § 3. MODEL CLASS
// ════════════════════════════════════════════════════════════

class AIModel {
  final String id;
  final String name;
  final String description;
  final String apiEndpoint;
  final String systemInstruction;
  final bool isDefault;
  final int order;

  AIModel({
    required this.id,
    required this.name,
    required this.description,
    required this.apiEndpoint,
    required this.systemInstruction,
    required this.isDefault,
    required this.order,
  });

  factory AIModel.fromMap(String id, Map<String, dynamic> map) {
    return AIModel(
      id: id,
      name: map['name'] ?? 'Unknown Model',
      description: map['description'] ?? '',
      apiEndpoint: map['api'] ?? kDefaultApi,
      systemInstruction: (map['system_instruction'] ?? kDefaultSysPrompt).replaceAll(r'\n', '\n'),
      isDefault: map['is_default'] ?? false,
      order: map['order'] ?? 999,
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 4. APP CONFIG (loaded from Firebase)
// ════════════════════════════════════════════════════════════

class AppConfig {
  static String logoUrl = kDefaultLogo;
  static String devLogoUrl = kDefaultDevLogo;
  static String appName = kDefaultName;
  static String subTitle = kDefaultSubTitle;
  static String mistakeTag = kDefaultMistakeTag;
  static String uploadStatus = kUploadOn;
  static String imgBBKey = kDefaultImgBBKey;
  static int totalHistory = kDefaultHistory;
  static String remoteVersion = kAppVersion;
  static String updateNotes = '';
  static String downloadUrl = '';

  // Models
  static List<AIModel> models = [];
  static AIModel? _currentModel;
  static AIModel get currentModel => _currentModel ?? _getDefaultModel();

  static AIModel _getDefaultModel() {
    if (models.isEmpty) {
      // Provide a fallback model if DB fails
      return AIModel(
        id: 'default',
        name: kDefaultName,
        description: kDefaultSubTitle,
        apiEndpoint: kDefaultApi,
        systemInstruction: kDefaultSysPrompt,
        isDefault: true,
        order: 0,
      );
    }
    return models.firstWhere((m) => m.isDefault, orElse: () => models.first);
  }

  static void setCurrentModel(AIModel model) {
    _currentModel = model;
  }

  static bool get hasUpdate =>
      remoteVersion != kAppVersion &&
      remoteVersion.isNotEmpty &&
      downloadUrl.isNotEmpty;

  static Future<void> load() async {
    try {
      // Load Config
      final configUrl = '$kFirebaseUrl/config.json?auth=$kFirebaseSecret';
      final configRes = await http.get(Uri.parse(configUrl)).timeout(const Duration(seconds: 8));
      if (configRes.statusCode == 200) {
        final d = jsonDecode(configRes.body);
        if (d != null) {
          final map = Map<String, dynamic>.from(d);
          logoUrl = map['logo'] ?? kDefaultLogo;
          devLogoUrl = map['dev_logo'] ?? kDefaultDevLogo;
          appName = map['app_name'] ?? map['name'] ?? kDefaultName;
          subTitle = map['sub_title'] ?? kDefaultSubTitle;
          mistakeTag = map['mistake_tag'] ?? kDefaultMistakeTag;
          uploadStatus = map['upload_status'] ?? kUploadOn;
          imgBBKey = map['imgbb_api_key'] ?? kDefaultImgBBKey;
          totalHistory = int.tryParse('${map['total_history'] ?? kDefaultHistory}') ?? kDefaultHistory;
          final app = map['app'] as Map<String, dynamic>? ?? {};
          remoteVersion = app['version'] ?? kAppVersion;
          updateNotes = (app['update'] ?? '').replaceAll(r'\n', '\n');
          downloadUrl = app['download'] ?? '';
        }
      }

      // Load Models
      final modelsUrl = '$kFirebaseUrl/models.json?auth=$kFirebaseSecret&orderBy="order"';
      final modelsRes = await http.get(Uri.parse(modelsUrl)).timeout(const Duration(seconds: 8));
      if (modelsRes.statusCode == 200) {
        final d = jsonDecode(modelsRes.body);
        if (d != null && d is Map) {
          final List<AIModel> loadedModels = [];
          d.forEach((key, value) {
            try {
              loadedModels.add(AIModel.fromMap(key, Map<String, dynamic>.from(value)));
            } catch (e) {
              print('Error parsing model $key: $e');
            }
          });
          loadedModels.sort((a, b) => a.order.compareTo(b.order));
          models = loadedModels;
        }
      }
      
      // Ensure current model is set
      _currentModel = _getDefaultModel();
    } catch (e) {
      print('Error loading config: $e');
    }
  }
}

// ════════════════════════════════════════════════════════════
// § 5. FIREBASE REST API HELPER
// ════════════════════════════════════════════════════════════

class FirebaseDB {
  static String _url(String path) => '$kFirebaseUrl/$path.json?auth=$kFirebaseSecret';

  static Future<dynamic> get(String path) async {
    try {
      final res = await http.get(Uri.parse(_url(path))).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return jsonDecode(res.body);
    } catch (_) {}
    return null;
  }

  static Future<bool> set(String path, dynamic data) async {
    try {
      final res = await http.put(Uri.parse(_url(path)),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data)).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> patch(String path, Map<String, dynamic> data) async {
    try {
      final res = await http.patch(Uri.parse(_url(path)),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data)).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> delete(String path) async {
    try {
      final res = await http.delete(Uri.parse(_url(path))).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ════════════════════════════════════════════════════════════
// § 6. AUTH SERVICE
// ════════════════════════════════════════════════════════════

class AuthUser {
  final String uid;
  final String name;
  final String email;
  AuthUser({required this.uid, required this.name, required this.email});

  Map<String, dynamic> toMap() => {'uid': uid, 'name': name, 'email': email};
  factory AuthUser.fromMap(Map<String, dynamic> m) =>
      AuthUser(uid: m['uid'] ?? '', name: m['name'] ?? '', email: m['email'] ?? '');
}

class AuthService {
  static AuthUser? _current;
  static AuthUser? get current => _current;
  static bool get isLoggedIn => _current != null;
  static File? _authFile;

  static Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _authFile = File('${dir.path}/skygen_auth.json');
    if (await _authFile!.exists()) {
      try {
        final raw = await _authFile!.readAsString();
        final d = jsonDecode(raw);
        _current = AuthUser.fromMap(d);
      } catch (_) {}
    }
  }

  static String _hashPassword(String password) {
    var hash = 0;
    for (final c in password.codeUnits) hash = ((hash << 5) - hash) + c;
    return hash.toRadixString(16);
  }

  static String _makeUid(String email) =>
      email.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').toLowerCase();

  static Future<String?> register(String name, String email, String password) async {
    final uid = _makeUid(email);
    final existing = await FirebaseDB.get('users/$uid/profile');
    if (existing != null) return 'Email already registered.';

    final profile = {
      'uid': uid,
      'name': name,
      'email': email,
      'password': _hashPassword(password),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    final ok = await FirebaseDB.set('users/$uid/profile', profile);
    if (!ok) return 'Registration failed. Check your internet.';

    _current = AuthUser(uid: uid, name: name, email: email);
    await _saveLocal();
    return null;
  }

  static Future<String?> login(String email, String password) async {
    final uid = _makeUid(email);
    final data = await FirebaseDB.get('users/$uid/profile');
    if (data == null) return 'No account found with this email.';

    final stored = data['password'] ?? '';
    if (stored != _hashPassword(password)) return 'Incorrect password.';

    _current = AuthUser(uid: uid, name: data['name'] ?? '', email: email);
    await _saveLocal();
    return null;
  }

  static Future<void> logout() async {
    _current = null;
    if (_authFile != null && await _authFile!.exists()) {
      await _authFile!.delete();
    }
  }

  static Future<void> updateName(String name) async {
    if (_current == null) return;
    _current = AuthUser(uid: _current!.uid, name: name, email: _current!.email);
    await FirebaseDB.patch('users/${_current!.uid}/profile', {'name': name});
    await _saveLocal();
  }

  static Future<void> _saveLocal() async {
    if (_authFile == null || _current == null) return;
    await _authFile!.writeAsString(jsonEncode(_current!.toMap()));
  }
}

// ════════════════════════════════════════════════════════════
// § 7. THEME NOTIFIER
// ════════════════════════════════════════════════════════════

class ThemeNotifier extends ChangeNotifier {
  bool _dark = false;
  bool get isDark => _dark;

  static File? _file;

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/skygen_theme.json');
    if (await _file!.exists()) {
      try {
        final d = jsonDecode(await _file!.readAsString());
        _dark = d['dark'] == true;
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> toggle() async {
    _dark = !_dark;
    notifyListeners();
    try {
      await _file?.writeAsString(jsonEncode({'dark': _dark}));
    } catch (_) {}
  }
}

final themeNotifier = ThemeNotifier();

// ════════════════════════════════════════════════════════════
// § 8. COLOURS
// ════════════════════════════════════════════════════════════

class C {
  static bool dark = false;
  static Color get bg => dark ? const Color(0xFF0A0C10) : const Color(0xFFF8F9FC);
  static Color get card => dark ? const Color(0xFF161A22) : const Color(0xFFFFFFFF);
  static Color get accent => const Color(0xFF6366F1);
  static Color get accentL => dark ? const Color(0xFF1E2240) : const Color(0xFFEEF0FE);
  static Color get ink => dark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
  static Color get ink2 => dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  static Color get border => dark ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0);
  static Color get userBub => dark ? const Color(0xFF22263A) : const Color(0xFFF1F5F9);
  static Color get red => const Color(0xFFEF4444);
  static Color get green => const Color(0xFF10B981);
  static const grad1 = Color(0xFF6366F1);
  static const grad2 = Color(0xFF8B5CF6);
}

// ════════════════════════════════════════════════════════════
// § 9. DATA MODELS
// ════════════════════════════════════════════════════════════

enum MsgType { user, ai }
enum GenStatus { waiting, streaming, completed, error, stopped }

class PendingImage {
  final File file;
  final String localSrc;
  String? uploadedUrl;
  String? ocrText;
  String? description;
  bool isLoading;
  bool isError;
  PendingImage(
      {required this.file,
      required this.localSrc,
      this.isLoading = true,
      this.isError = false});
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
    required this.id,
    required this.text,
    String? visibleText,
    required this.type,
    this.imgUrls,
    this.status = GenStatus.completed,
    required this.ts,
    this.liked = false,
    this.disliked = false,
  }) : visibleText = visibleText ?? (status == GenStatus.completed ? text : '');

  Map<String, dynamic> toMap() => {
        'id': id,
        'text': text,
        'visibleText': visibleText,
        'type': type.index,
        'imgUrls': imgUrls,
        'status': status.index,
        'ts': ts,
        'liked': liked,
        'disliked': disliked,
      };
  factory ChatMsg.fromMap(Map<String, dynamic> m) => ChatMsg(
        id: m['id'],
        text: m['text'],
        visibleText: m['visibleText'],
        type: MsgType.values[m['type']],
        imgUrls: m['imgUrls'] != null ? List<String>.from(m['imgUrls']) : null,
        status: GenStatus.values[m['status']],
        ts: m['ts'],
        liked: m['liked'] ?? false,
        disliked: m['disliked'] ?? false,
      );
}

class Session {
  final String id;
  String title;
  final int createdAt;
  bool isPinned;
  List<ChatMsg> messages;
  bool titleGenerated;
  String modelId; // Track which model was used for this session

  Session({
    required this.id,
    required this.title,
    required this.createdAt,
    this.isPinned = false,
    required this.messages,
    this.titleGenerated = false,
    this.modelId = 'default',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'isPinned': isPinned,
        'titleGenerated': titleGenerated,
        'modelId': modelId,
        'messages': messages.map((m) => m.toMap()).toList(),
      };
  factory Session.fromMap(Map<String, dynamic> m) => Session(
        id: m['id'],
        title: m['title'],
        createdAt: m['createdAt'],
        isPinned: m['isPinned'] ?? false,
        titleGenerated: m['titleGenerated'] ?? false,
        modelId: m['modelId'] ?? 'default',
        messages: (m['messages'] as List).map((e) => ChatMsg.fromMap(e)).toList(),
      );
}

// ════════════════════════════════════════════════════════════
// § 10. TTS CACHE
// ════════════════════════════════════════════════════════════

class TtsCache {
  static final Map<String, String> _mem = {};
  static Directory? _dir;

  static Future<void> init() async {
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/tts_cache');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
  }

  static String _key(String text) => text.hashCode.toRadixString(16).padLeft(8, '0');

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

// ════════════════════════════════════════════════════════════
// § 11. ROOT APP
// ════════════════════════════════════════════════════════════

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
    themeNotifier.addListener(() => setState(() {
          C.dark = themeNotifier.isDark;
        }));
    themeNotifier.load().then((_) => setState(() {
          C.dark = themeNotifier.isDark;
        }));
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
    final br = C.dark ? Brightness.dark : Brightness.light;
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: br,
        scaffoldBackgroundColor: C.bg,
        primaryColor: C.accent,
        fontFamily: GoogleFonts.inter().fontFamily,
        colorScheme: ColorScheme.fromSeed(seedColor: C.accent, brightness: br),
      ),
      home: const SplashScreen(),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 12. REUSABLE LOGO CIRCLE
// ════════════════════════════════════════════════════════════

class _LogoCircle extends StatelessWidget {
  final double size;
  final String? urlOverride;
  const _LogoCircle({required this.size, this.urlOverride});

  @override
  Widget build(BuildContext context) {
    final url = urlOverride ?? AppConfig.logoUrl;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [C.grad1, C.grad2]),
              shape: BoxShape.circle),
          child: Icon(Icons.school_rounded, color: Colors.white, size: size * 0.48),
        ),
        errorWidget: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [C.grad1, C.grad2]),
              shape: BoxShape.circle),
          child: Icon(Icons.school_rounded, color: Colors.white, size: size * 0.48),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 13. SPLASH SCREEN
// ════════════════════════════════════════════════════════════

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

    _logoCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _ringCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
    _textCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

    _logoScale = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.elasticOut));
    _logoFade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _logoCtrl, curve: const Interval(0.0, 0.4)));
    _ringScale = Tween(begin: 0.8, end: 1.6).animate(CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOut));
    _ringOpacity = Tween(begin: 0.6, end: 0.0).animate(CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOut));
    _textFade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeIn));

    Future.wait([
      AppConfig.load(),
      AuthService.init(),
    ]).then((_) {
      if (mounted) setState(() {});
    });

    _logoCtrl.forward().then((_) {
      _textCtrl.forward();
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) {
          try {
            _ringCtrl.stop();
          } catch (_) {}
          Navigator.of(context).pushReplacement(PageRouteBuilder(
            pageBuilder: (_, __, ___) => const MainWrapper(),
            transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
            transitionDuration: const Duration(milliseconds: 500),
          ));
        }
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(NetworkImage(AppConfig.logoUrl), context);
      precacheImage(NetworkImage(AppConfig.devLogoUrl), context);
    });
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    try {
      _ringCtrl.dispose();
    } catch (_) {}
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
          builder: (_, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 160,
                height: 160,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.scale(
                        scale: _ringScale.value,
                        child: Opacity(
                            opacity: _ringOpacity.value,
                            child: Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle, border: Border.all(color: C.accent, width: 2))))),
                    Transform.scale(
                        scale: (_ringScale.value * 0.7).clamp(0.0, 2.0),
                        child: Opacity(
                            opacity: (_ringOpacity.value * 0.5).clamp(0.0, 1.0),
                            child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle, border: Border.all(color: C.grad2, width: 1.5))))),
                    FadeTransition(
                        opacity: _logoFade,
                        child: Transform.scale(
                            scale: _logoScale.value,
                            child: Container(
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(color: C.accent.withOpacity(0.4), blurRadius: 24, spreadRadius: 2)
                                    ]),
                                child: _LogoCircle(size: 88)))),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              FadeTransition(
                opacity: _textFade,
                child: Column(
                  children: [
                    Text(AppConfig.appName,
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: C.ink, letterSpacing: -0.5)),
                    const SizedBox(height: 4),
                    Text(AppConfig.subTitle,
                        style: TextStyle(fontSize: 13, color: C.ink2, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 14. MAIN WRAPPER (Bottom Nav)
// ════════════════════════════════════════════════════════════

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});
  @override
  State<MainWrapper> createState() => _MainWrapperState();
}

class _MainWrapperState extends State<MainWrapper> {
  int _selectedIndex = 0;
  final PageController _pageController = PageController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          ChatScreen(),
          Center(child: Text('History', style: TextStyle(color: Colors.white))), // Placeholder
          Center(child: Text('Profile', style: TextStyle(color: Colors.white))), // Placeholder
        ],
      ),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
          border: Border.all(color: C.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: (index) {
              setState(() => _selectedIndex = index);
              _pageController.jumpToPage(index);
            },
            backgroundColor: Colors.transparent,
            elevation: 0,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: C.accent,
            unselectedItemColor: C.ink2,
            selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 11),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline_rounded), label: 'Chat'),
              BottomNavigationBarItem(icon: Icon(Icons.history_rounded), label: 'History'),
              BottomNavigationBarItem(icon: Icon(Icons.person_outline_rounded), label: 'Profile'),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 15. CHAT SCREEN
// ════════════════════════════════════════════════════════════

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  List<Session> _sessions = [];
  String _currentId = '';
  bool _isTempSession = true;
  bool _isGenerating = false;
  bool _stopRequested = false;
  File? _storageFile;
  File? _memoryFile;
  List<PendingImage> _pendingImages = [];

  // TTS
  final AudioPlayer _ttsPlayer = AudioPlayer();
  List<String> _ttsQueue = [];
  bool _isPlayingTTS = false;
  bool _isTTSLoading = false;
  String? _speakingId;

  bool _showScrollFab = false;
  List<String> _aiMemory = [];
  String _searchQuery = '';

  // Update sheet
  bool _updateSheetDismissed = false;

  bool get _canSend {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final hasImg = _pendingImages.isNotEmpty && !_pendingImages.any((p) => p.isLoading);
    return (hasText || hasImg) && !_isGenerating;
  }

  @override
  void initState() {
    super.initState();
    _initStorage();
    _ttsPlayer.onPlayerComplete.listen((_) => _playNextTTS());
    _scrollCtrl.addListener(_onScroll);
    _inputCtrl.addListener(() => setState(() {}));
    themeNotifier.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AppConfig.hasUpdate && !_updateSheetDismissed) _showUpdateSheet();
    });
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

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageFile = File('${dir.path}/skygen_v8.json');
      _memoryFile = File('${dir.path}/skygen_mem_v3.json');

      if (await _memoryFile!.exists()) {
        final raw = await _memoryFile!.readAsString();
        final d = jsonDecode(raw);
        setState(() => _aiMemory = List<String>.from(d['memory'] ?? []));
      }

      if (AuthService.isLoggedIn) {
        await _loadFromFirebase();
      } else {
        if (await _storageFile!.exists()) {
          final raw = await _storageFile!.readAsString();
          final d = jsonDecode(raw);
          setState(() {
            _sessions = (d['sessions'] as List).map((e) => Session.fromMap(e)).toList();
            _sortSessions();
          });
        }
      }
    } catch (_) {}
    _newTempSession();
  }

  Future<void> _loadFromFirebase() async {
    if (!AuthService.isLoggedIn) return;
    final uid = AuthService.current!.uid;
    final data = await FirebaseDB.get('users/$uid/sessions');
    if (data != null && data is Map) {
      final list = <Session>[];
      data.forEach((k, v) {
        try {
          list.add(Session.fromMap(Map<String, dynamic>.from(v)));
        } catch (_) {}
      });
      setState(() {
        _sessions = list;
        _sortSessions();
      });
    }
    final memData = await FirebaseDB.get('users/$uid/memory');
    if (memData is List) {
      setState(() => _aiMemory = List<String>.from(memData));
    }
  }

  Future<void> _save() async {
    if (AuthService.isLoggedIn) {
      final uid = AuthService.current!.uid;
      final map = {for (final s in _sessions) s.id: s.toMap()};
      await FirebaseDB.set('users/$uid/sessions', map);
    }
    if (_storageFile == null) return;
    try {
      await _storageFile!.writeAsString(jsonEncode({'sessions': _sessions.map((s) => s.toMap()).toList()}));
    } catch (_) {}
  }

  Future<void> _saveMemory() async {
    if (AuthService.isLoggedIn) {
      await FirebaseDB.set('users/${AuthService.current!.uid}/memory', _aiMemory);
    }
    if (_memoryFile == null) return;
    try {
      await _memoryFile!.writeAsString(jsonEncode({'memory': _aiMemory}));
    } catch (_) {}
  }

  void _addToMemory(List<String> items) {
    for (final item in items) {
      final t = item.trim();
      if (t.length >= 20 && !_aiMemory.contains(t)) {
        _aiMemory.add(t.length > 200 ? t.substring(0, 200) : t);
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
      _currentId = 'tmp${DateTime.now().millisecondsSinceEpoch}';
      _isTempSession = true;
      _isGenerating = false;
      _inputCtrl.clear();
      _pendingImages.clear();
    });
  }

  void _switchSession(String id) {
    setState(() {
      _currentId = id;
      _isTempSession = false;
      _isGenerating = false;
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
          orElse: () => Session(
              id: _currentId,
              title: 'New Chat',
              createdAt: DateTime.now().millisecondsSinceEpoch,
              messages: [],
              modelId: AppConfig.currentModel.id))
      : _sessions.firstWhere((s) => s.id == _currentId,
          orElse: () => _sessions.isNotEmpty
              ? _sessions.first
              : Session(
                  id: _currentId,
                  title: 'New Chat',
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                  messages: [],
                  modelId: AppConfig.currentModel.id));

  Future<bool> _hasInternet() async {
    try {
      final r = await http.get(Uri.parse('https://www.google.com')).timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickImages() async {
    if (AppConfig.uploadStatus != 'on') {
      _showToast('Image upload is currently disabled.');
      return;
    }
    if (_pendingImages.length >= 3) {
      _showToast('Maximum 3 images allowed.');
      return;
    }
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      for (final xf in files.take(3 - _pendingImages.length)) {
        final p = PendingImage(file: File(xf.path), localSrc: xf.path);
        setState(() => _pendingImages.add(p));
        _uploadAndAnalyze(p);
      }
    } catch (e) {
      _showToast('Error: $e');
    }
  }

  Future<void> _uploadAndAnalyze(PendingImage p) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('https://api.imgbb.com/1/upload?key=${AppConfig.imgBBKey}'));
      req.files.add(await http.MultipartFile.fromPath('image', p.file.path));
      final res = await req.send();
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
      if (mounted) setState(() {
        p.isLoading = false;
        p.isError = true;
      });
    } catch (_) {
      if (mounted) setState(() {
        p.isLoading = false;
        p.isError = true;
      });
    }
  }

  Future<void> _fetchOCR(PendingImage p) async {
    try {
      final r = await http.post(Uri.parse('https://gen-z-ocr.vercel.app/api'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'url': p.uploadedUrl}));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body);
        if (d['ok'] == true) p.ocrText = d['results']['answer'] as String?;
      }
    } catch (_) {}
  }

  Future<void> _fetchDesc(PendingImage p) async {
    try {
      final r = await http.get(Uri.parse('https://gen-z-describer.vercel.app/api?url=${p.uploadedUrl}'));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body);
        if (d['ok'] == true) p.description = d['results']['description'] as String?;
      }
    } catch (_) {}
  }

  Future<void> _send() async {
    if (_isGenerating) return;
    final prompt = _inputCtrl.text.trim();
    if (prompt.isEmpty && _pendingImages.isEmpty) return;
    if (_pendingImages.any((p) => p.isLoading)) {
      _showToast('Images still uploading…');
      return;
    }

    setState(() => _isGenerating = true);
    final imgs = List<PendingImage>.from(_pendingImages);
    _inputCtrl.clear();
    setState(() => _pendingImages.clear());

    final isFirst = _isTempSession;
    if (_isTempSession) {
      final s = Session(
          id: _currentId,
          title: 'New Chat',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          messages: [],
          modelId: AppConfig.currentModel.id);
      setState(() {
        _sessions.insert(0, s);
        _isTempSession = false;
        _sortSessions();
      });
    }

    final imgUrls = imgs.where((i) => i.uploadedUrl != null && !i.isError).map((i) => i.uploadedUrl!).toList();

    final userMsg = ChatMsg(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      text: prompt,
      type: MsgType.user,
      imgUrls: imgUrls.isNotEmpty ? imgUrls : null,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    final sess = _sessions.firstWhere((s) => s.id == _currentId);
    setState(() {
      sess.messages.add(userMsg);
      _stopRequested = false;
    });
    _scrollToBot(force: true);
    _save();

    await _streamAI(prompt, imgs, sess: sess, isFirst: isFirst);
  }

  String _buildPrompt(String userPrompt, List<PendingImage> imgs, {required bool needTitle}) {
    String imgCtx = '';
    for (int i = 0; i < imgs.length; i++) {
      if (imgs[i].uploadedUrl == null || imgs[i].isError) continue;
      imgCtx += '\n[Image ${i + 1}]\n';
      if (imgs[i].ocrText?.isNotEmpty == true) imgCtx += '  OCR: ${imgs[i].ocrText}\n';
      if (imgs[i].description?.isNotEmpty == true) imgCtx += '  Visual: ${imgs[i].description}\n';
    }

    final sess = _sessions.firstWhere((s) => s.id == _currentId);
    final msgs = sess.messages;
    String hist = '';
    final limit = AppConfig.totalHistory;
    final start = max(0, msgs.length - (limit + 1));
    for (int i = start; i < msgs.length - 1; i++) {
      final m = msgs[i];
      if (m.status == GenStatus.completed) {
        hist += '${m.type == MsgType.user ? "User" : "AI"}: ${m.text}\n';
      }
    }

    String userCtx = '';
    if (AuthService.isLoggedIn) {
      userCtx += '\n════ USER INFO ════\n';
      userCtx += '• Name: ${AuthService.current!.name}\n';
      userCtx += '• Email: ${AuthService.current!.email}\n';
    }
    if (_aiMemory.isNotEmpty) {
      userCtx += '\n════ USER LONG-TERM MEMORY ════\n(Use this to personalize responses)\n';
      for (final m in _aiMemory) userCtx += '• $m\n';
    }

    String full = '[System Instruction]\n${AppConfig.currentModel.systemInstruction}$userCtx\n\n';
    if (needTitle) full += '[GENERATE_TITLE] — Add <<<TITLE: ...>>> at end of response.\n\n';
    if (hist.isNotEmpty) full += '[Chat History]\n$hist\n';
    if (imgCtx.isNotEmpty) full += '[Images]\n$imgCtx\n';
    full += '[User]: ${userPrompt.isEmpty ? "(image sent)" : userPrompt}';
    return full;
  }

  Future<void> _streamAI(String prompt, List<PendingImage> imgs, {required Session sess, required bool isFirst}) async {
    final needTitle = isFirst && !sess.titleGenerated;
    final aiId = 'ai${DateTime.now().millisecondsSinceEpoch}';
    _addAiMsg(aiId, '', GenStatus.waiting);

    try {
      if (!await _hasInternet()) {
        _updateStatus(aiId, GenStatus.error, text: '⚠️ No internet connection. Please check your network.');
        return;
      }

      final client = http.Client();
      final req = http.Request('POST', Uri.parse(AppConfig.currentModel.apiEndpoint));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'q': _buildPrompt(prompt, imgs, needTitle: needTitle), 'format': 'sse'});

      http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(seconds: 30));
      } catch (_) {
        _updateStatus(aiId, GenStatus.error, text: '⚠️ Connection error. Please check your internet and try again.');
        return;
      }

      if (res.statusCode != 200) {
        _updateStatus(aiId, GenStatus.error, text: '⚠️ API error (${res.statusCode}). Please try again.');
        client.close();
        return;
      }

      _updateStatus(aiId, GenStatus.streaming);
      String streamed = '';
      String buf = '';
      bool firstChunk = true;

      await for (final chunk in res.stream.transform(utf8.decoder)) {
        if (_stopRequested) {
          _finalizeAI(aiId, sess, streamed, needTitle);
          client.close();
          break;
        }
        buf += chunk;
        while (buf.contains('\n\n')) {
          final idx = buf.indexOf('\n\n');
          final line = buf.substring(0, idx).trim();
          buf = buf.substring(idx + 2);
          if (line.startsWith('data: ')) {
            final ds = line.substring(6).trim();
            if (ds == '[DONE]') {
              _finalizeAI(aiId, sess, streamed, needTitle);
              client.close();
              return;
            }
            try {
              final j = jsonDecode(ds);
              final ans = j['results']?['answer'] as String?;
              if (ans != null) {
                if (firstChunk && ans.trim().isEmpty) continue;
                firstChunk = false;
                streamed += ans;
                _updateText(aiId, _cleanTagsDisplay(streamed));
              }
            } catch (_) {}
          }
        }
      }

      if (!_stopRequested) _finalizeAI(aiId, sess, streamed, needTitle);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('socket') || msg.contains('network') || msg.contains('dns') || msg.contains('connection')) {
        _updateStatus(aiId, GenStatus.error, text: '⚠️ No internet connection.');
      } else {
        _updateStatus(aiId, GenStatus.error, text: '⚠️ Something went wrong. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      _save();
    }
  }

  void _finalizeAI(String aiId, Session sess, String streamed, bool needTitle) {
    if (!mounted) return;

    if (needTitle) {
      final m = RegExp(r'<<<TITLE:\s*(.+?)>>>').firstMatch(streamed);
      if (m != null) {
        final t = m.group(1)!.trim();
        final si = _sessions.indexWhere((s) => s.id == _currentId);
        if (si != -1) {
          setState(() {
            _sessions[si].title = t;
            _sessions[si].titleGenerated = true;
          });
          _save();
        }
      }
    }

    final mm = RegExp(r'<<<MEMORY:\s*(\[[\s\S]+?\])>>>').firstMatch(streamed);
    if (mm != null) {
      try {
        final arr = jsonDecode(mm.group(1)!) as List;
        _addToMemory(arr.map((e) => e.toString()).toList());
      } catch (_) {}
    }

    final clean = _cleanTags(streamed);
    _updateStatus(aiId, GenStatus.completed, text: clean);
  }

  String _cleanTags(String t) => t
      .replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '')
      .replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '')
      .trim();

  String _cleanTagsDisplay(String t) {
    String c = t.replaceAll(RegExp(r'<<<TITLE:[^>]*>>>'), '').replaceAll(RegExp(r'<<<MEMORY:[\s\S]*?>>>'), '');
    c = c.replaceAll(RegExp(r'<{1,3}[^>]*$'), '');
    return c.trim();
  }

  void _addAiMsg(String id, String text, GenStatus status) {
    final sess = _sessions.firstWhere((s) => s.id == _currentId);
    setState(() => sess.messages.add(ChatMsg(
        id: id,
        text: text,
        visibleText: '',
        type: MsgType.ai,
        status: status,
        ts: DateTime.now().millisecondsSinceEpoch)));
    _scrollToBot();
  }

  void _updateText(String id, String text) {
    final si = _sessions.indexWhere((s) => s.id == _currentId);
    if (si == -1) return;
    final mi = _sessions[si].messages.indexWhere((m) => m.id == id);
    if (mi != -1) {
      setState(() {
        _sessions[si].messages[mi].visibleText = text;
        _sessions[si].messages[mi].text = text;
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
          _sessions[si].messages[mi].text = text;
          _sessions[si].messages[mi].visibleText = text;
        }
      });
      if (status == GenStatus.completed) _scrollToBot();
    }
  }

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
      _speakingId = id;
      _isPlayingTTS = false;
      _isTTSLoading = true;
      _ttsQueue.clear();
    });

    final chunks = _chunkText(text.replaceAll(RegExp(r'```[\s\S]*?```'), ''));
    if (chunks.isEmpty) {
      setState(() {
        _isTTSLoading = false;
        _speakingId = null;
      });
      return;
    }
    try {
      final paths = await Future.wait(chunks.map(_fetchTTSPath));
      if (!mounted) return;
      setState(() {
        _isTTSLoading = false;
        _isPlayingTTS = true;
        _ttsQueue = paths;
      });
      await _playNextTTS();
    } catch (_) {
      if (mounted) setState(() {
        _isTTSLoading = false;
        _isPlayingTTS = false;
        _speakingId = null;
      });
    }
  }

  Future<String> _fetchTTSPath(String text) async {
    final cached = await TtsCache.get(text);
    if (cached != null) return cached;
    final url = 'https://murf.ai/Prod/anonymous-tts/audio'
        '?text=${Uri.encodeComponent(text)}'
        '&voiceId=VM017230562791058FV&style=Conversational';
    final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0', 'Accept': 'audio/mpeg, */*'});
    if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
      return await TtsCache.store(text, res.bodyBytes);
    }
    throw Exception('TTS failed');
  }

  List<String> _chunkText(String text, {int size = 190}) {
    final chunks = <String>[];
    String t = text.trim();
    while (t.isNotEmpty) {
      if (t.length <= size) {
        chunks.add(t);
        break;
      }
      int cut = -1;
      for (final bc in ['।', '.', '\n', '?', '!', ',', ';', ':']) {
        final pos = t.lastIndexOf(bc, size);
        if (pos > 80) {
          cut = pos + 1;
          break;
        }
      }
      if (cut < 0) {
        cut = t.lastIndexOf(' ', size);
        if (cut < 80) cut = size;
      }
      chunks.add(t.substring(0, cut).trim());
      t = t.substring(cut).trim();
    }
    return chunks.where((s) => s.isNotEmpty).toList();
  }

  Future<void> _playNextTTS() async {
    if (_ttsQueue.isEmpty) {
      setState(() {
        _isPlayingTTS = false;
        _speakingId = null;
      });
      return;
    }
    try {
      await _ttsPlayer.play(DeviceFileSource(_ttsQueue.removeAt(0)));
    } catch (_) {
      _playNextTTS();
    }
  }

  void _setReaction(String msgId, bool like) {
    final si = _sessions.indexWhere((s) => s.id == _currentId);
    if (si == -1) return;
    final mi = _sessions[si].messages.indexWhere((m) => m.id == msgId);
    if (mi == -1) return;
    setState(() {
      if (like) {
        _sessions[si].messages[mi].liked = !_sessions[si].messages[mi].liked;
        _sessions[si].messages[mi].disliked = false;
      } else {
        _sessions[si].messages[mi].disliked = !_sessions[si].messages[mi].disliked;
        _sessions[si].messages[mi].liked = false;
      }
    });
    _save();
  }

  Future<bool> _confirmDelete(BuildContext ctx) async {
    return await showDialog<bool>(
          context: ctx,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            backgroundColor: C.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Delete Chat', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
            content: Text('Are you sure? This cannot be undone.', style: TextStyle(fontSize: 14, color: C.ink2)),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              Row(children: [
                Expanded(
                    child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: C.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        child: Text('Cancel', style: TextStyle(color: C.ink2, fontWeight: FontWeight.w600)))),
                const SizedBox(width: 10),
                Expanded(
                    child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: C.red,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        child: const Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))),
              ])
            ],
          ),
        ) ??
        false;
  }

  Future<void> _renameSession(Session s) async {
    final ctrl = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            backgroundColor: C.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Rename Chat', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
            content: TextField(
              controller: ctrl,
              maxLength: 100,
              maxLines: 1,
              style: TextStyle(fontSize: 14, color: C.ink),
              decoration: InputDecoration(
                counterText: '',
                hintText: 'Chat title…',
                hintStyle: TextStyle(color: C.ink2),
                filled: true,
                fillColor: C.bg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: C.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: C.accent)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              Row(children: [
                Expanded(
                    child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: C.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        child: Text('Cancel', style: TextStyle(color: C.ink2, fontWeight: FontWeight.w600)))),
                const SizedBox(width: 10),
                Expanded(
                    child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: C.accent,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))),
              ])
            ],
          ),
        ) ??
        false;
    final newTitle = ctrl.text.trim();
    ctrl.dispose();
    if (ok && newTitle.isNotEmpty) {
      setState(() => s.title = newTitle);
      _save();
    }
  }

  OverlayEntry? _toastEntry;
  void _showToast(String msg) {
    _toastEntry?.remove();
    _toastEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: 40,
        right: 40,
        top: MediaQuery.of(context).size.height * 0.44,
        child: Material(
            color: Colors.transparent,
            child: Center(
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    decoration: BoxDecoration(color: C.ink.withOpacity(0.9), borderRadius: BorderRadius.circular(20)),
                    child: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 13), textAlign: TextAlign.center)))),
      ),
    );
    Overlay.of(context).insert(_toastEntry!);
    Future.delayed(const Duration(milliseconds: 1600), () {
      _toastEntry?.remove();
      _toastEntry = null;
    });
  }

  void _openImage(String url) => Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewerPage(imageUrl: url)));

  void _showUpdateSheet() {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _UpdateSheet(
        onDismiss: () {
          setState(() => _updateSheetDismissed = true);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showSettings() {
    Navigator.pop(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(
        aiMemory: _aiMemory,
        hasUpdate: AppConfig.hasUpdate && !_updateSheetDismissed,
        onClearMemory: (list) {
          setState(() => _aiMemory = list);
          _saveMemory();
        },
        onClearAllChats: () async {
          final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: C.card,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text('Delete All Chats', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
                  content: Text('All chats deleted. Memory will remain.', style: TextStyle(fontSize: 14, color: C.ink2)),
                  actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  actions: [
                    Row(children: [
                      Expanded(
                          child: OutlinedButton(
                              onPressed: () => Navigator.pop(context, false),
                              style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: C.border),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 12)),
                              child: Text('Cancel', style: TextStyle(color: C.ink2, fontWeight: FontWeight.w600)))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: C.accent,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 12)),
                              child: const Text('Delete All',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))),
                    ])
                  ],
                ),
              ) ??
              false;
          if (ok) {
            setState(() {
              _sessions.clear();
              _newTempSession();
            });
            _save();
            HapticFeedback.heavyImpact();
          }
        },
        onLoggedOut: () {
          setState(() {
            _sessions.clear();
            _aiMemory = [];
          });
          _save();
          _newTempSession();
        },
      ),
    );
  }

  void _showModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
            color: C.card, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(margin: const EdgeInsets.only(top: 10, bottom: 16), width: 36, height: 4,
                decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text('Select AI Model', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
                  const Spacer(),
                  GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                          child: Icon(Icons.close_rounded, size: 16, color: C.ink2))),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: AppConfig.models.length,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemBuilder: (ctx, i) {
                  final model = AppConfig.models[i];
                  final isSelected = AppConfig.currentModel.id == model.id;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                        color: isSelected ? C.accentL : C.bg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: isSelected ? C.accent : C.border, width: isSelected ? 1.5 : 1)),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          AppConfig.setCurrentModel(model);
                          setState(() {});
                          Navigator.pop(context);
                          _showToast('Switched to ${model.name}');
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                      gradient: const LinearGradient(colors: [C.grad1, C.grad2]),
                                      borderRadius: BorderRadius.circular(12)),
                                  child: Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 20)),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(model.name,
                                            style: TextStyle(
                                                fontSize: 15, fontWeight: FontWeight.w700, color: isSelected ? C.accent : C.ink)),
                                        if (model.isDefault) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                  color: C.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                                              child: Text('Default',
                                                  style: TextStyle(color: C.accent, fontSize: 9, fontWeight: FontWeight.w700)))
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(model.description,
                                        style: TextStyle(fontSize: 12, color: C.ink2, height: 1.3), maxLines: 2),
                                  ],
                                ),
                              ),
                              if (isSelected) Icon(Icons.check_circle_rounded, color: C.accent, size: 22),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 10),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msgs = _curSession.messages;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: C.bg,
      drawer: _buildDrawer(),
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          Column(
            children: [
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
                            onSpeak: (id, t) => _handleTTS(id, t),
                            onCopy: (t) {
                              Clipboard.setData(ClipboardData(text: t));
                              _showToast('Copied ✓');
                            },
                            onLike: (id) => _setReaction(id, true),
                            onDislike: (id) => _setReaction(id, false),
                            onImageTap: (url) => _openImage(url),
                          ),
                        ),
                      ),
              ),
              _buildInput(),
            ],
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            bottom: _showScrollFab ? _inputHeight + 12 : -60,
            left: 0,
            right: 0,
            child: Center(
                child: _ScrollFab(
                    onTap: () {
              setState(() => _showScrollFab = false);
              _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent + 200,
                  duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
            })),
          ),
        ],
      ),
    );
  }

  double get _inputHeight {
    final pad = MediaQuery.of(context).padding.bottom;
    return 72 + pad + (_pendingImages.isNotEmpty ? 72 : 0);
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: C.card,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
      leadingWidth: 48,
      leading: Tooltip(
        message: 'Menu',
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: SizedBox(width: 40, height: 40, child: Icon(Icons.menu_rounded, color: C.ink, size: 22)))),
      ),
      title: Row(
        children: [
          Text(AppConfig.appName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink, letterSpacing: -0.2)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(20)),
            child: Text(AppConfig.currentModel.name,
                style: TextStyle(color: C.accent, fontSize: 10, fontWeight: FontWeight.w700), maxLines: 1),
          ),
        ],
      ),
      actions: [
        // Model Selector
        Tooltip(
          message: 'Change Model',
          child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _showModelSelector,
                  child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.border, width: 1.5)),
                      child: Icon(Icons.auto_awesome_rounded, color: C.accent, size: 18)))),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'New Chat',
          child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    if (!_isTempSession) _newTempSession();
                  },
                  child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.border, width: 1.5)),
                      child: Icon(Icons.add_rounded, color: C.ink, size: 20)))),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _buildDrawer() {
    final filtered = _searchQuery.isEmpty
        ? _sessions
        : _sessions.where((s) => s.title.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Drawer(
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
              child: Row(
                children: [
                  _LogoCircle(size: 34),
                  const SizedBox(width: 9),
                  Text(AppConfig.appName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
                  const Spacer(),
                  Tooltip(
                      message: C.dark ? 'Light Mode' : 'Dark Mode',
                      child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (child, anim) =>
                              RotationTransition(turns: anim, child: FadeTransition(opacity: anim, child: child)),
                          child: Material(
                              key: ValueKey(C.dark),
                              color: Colors.transparent,
                              child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () {
                                    themeNotifier.toggle();
                                    HapticFeedback.lightImpact();
                                  },
                                  child: Container(
                                      width: 34,
                                      height: 34,
                                      alignment: Alignment.center,
                                      child: Icon(
                                          C.dark ? Icons.wb_sunny_rounded : Icons.nightlight_round,
                                          color: C.dark ? const Color(0xFFFBBF24) : const Color(0xFF6366F1),
                                          size: 18)))))),
                  const SizedBox(width: 4),
                  Tooltip(
                      message: 'New Chat',
                      child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                if (!_isTempSession) _newTempSession();
                                Navigator.pop(context);
                              },
                              child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(8)),
                                  child: Icon(Icons.add_rounded, color: C.accent, size: 18))))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Container(
                height: 36,
                decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Icon(Icons.search_rounded, color: C.ink2, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                        child: TextField(
                      controller: _searchCtrl,
                      style: TextStyle(fontSize: 13, color: C.ink),
                      decoration: InputDecoration(
                        hintText: 'Search chats…',
                        hintStyle: TextStyle(color: C.ink2, fontSize: 13),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    )),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                          onTap: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                          child: Padding(padding: const EdgeInsets.only(right: 8), child: Icon(Icons.close_rounded, color: C.ink2, size: 13))),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: C.border),
            Expanded(
              child: filtered.isEmpty
                  ? Center(child: Text('No chats yet.', style: TextStyle(color: C.ink2, fontSize: 13)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final s = filtered[i];
                        if (s.messages.isEmpty) return const SizedBox.shrink();
                        final active = s.id == _currentId && !_isTempSession;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(vertical: 1),
                          decoration: BoxDecoration(color: active ? C.accentL : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                          child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => _switchSession(s.id),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                    child: Row(
                                      children: [
                                        Icon(s.isPinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
                                            size: 13, color: active ? C.accent : C.ink2),
                                        const SizedBox(width: 8),
                                        Expanded(
                                            child: Text(s.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                                    color: active ? C.accent : C.ink))),
                                        PopupMenuButton<String>(
                                          icon: Icon(Icons.more_vert_rounded, size: 14, color: C.ink2),
                                          padding: EdgeInsets.zero,
                                          iconSize: 14,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          color: C.card,
                                          elevation: 4,
                                          onSelected: (val) async {
                                            if (val == 'pin') {
                                              HapticFeedback.lightImpact();
                                              setState(() {
                                                s.isPinned = !s.isPinned;
                                                _sortSessions();
                                              });
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
                                            PopupMenuItem(
                                                value: 'pin',
                                                child: Row(children: [
                                                  Icon(s.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded, size: 14, color: C.accent),
                                                  const SizedBox(width: 8),
                                                  Text(s.isPinned ? 'Unpin' : 'Pin', style: TextStyle(fontSize: 13, color: C.ink)),
                                                ])),
                                            PopupMenuItem(
                                                value: 'rename',
                                                child: Row(children: [
                                                  Icon(Icons.edit_rounded, size: 14, color: C.ink2),
                                                  const SizedBox(width: 8),
                                                  Text('Rename', style: TextStyle(fontSize: 13, color: C.ink)),
                                                ])),
                                            PopupMenuItem(
                                                value: 'delete',
                                                child: Row(children: [
                                                  Icon(Icons.delete_outline_rounded, size: 14, color: C.red),
                                                  const SizedBox(width: 8),
                                                  Text('Delete', style: TextStyle(fontSize: 13, color: C.red)),
                                                ])),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ))),
                        );
                      },
                    ),
            ),
            Divider(height: 1, color: C.border),
            if (!AuthService.isLoggedIn)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                        child: OutlinedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              _openAuthPage(isLogin: true);
                            },
                            style: OutlinedButton.styleFrom(
                                side: BorderSide(color: C.border),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(vertical: 10)),
                            child: Text('Log In', style: TextStyle(color: C.ink, fontSize: 13, fontWeight: FontWeight.w600)))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              _openAuthPage(isLogin: false);
                            },
                            style: ElevatedButton.styleFrom(
                                backgroundColor: C.accent,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(vertical: 10)),
                            child: const Text('Register',
                                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))),
                  ],
                ),
              )
            else
              InkWell(
                onTap: () {
                  Navigator.pop(context);
                  _showProfileSheet();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(16)),
                          child: Icon(Icons.person_rounded, color: C.accent, size: 16)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(AuthService.current!.name,
                              style: TextStyle(fontSize: 13, color: C.ink, fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                      Icon(Icons.chevron_right_rounded, size: 16, color: C.ink2),
                    ],
                  ),
                ),
              ),
            Divider(height: 1, color: C.border),
            InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                _showSettings();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 17, color: C.ink2),
                    const SizedBox(width: 10),
                    Text('Settings', style: TextStyle(fontSize: 13, color: C.ink, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Icon(Icons.chevron_right_rounded, size: 17, color: C.ink2),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: C.border),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(AppConfig.mistakeTag,
                  style: TextStyle(fontSize: 10, color: C.ink2), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  void _openAuthPage({required bool isLogin}) {
    Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => _AuthPage(
            startWithLogin: isLogin,
            onSuccess: () {
              Navigator.pop(context);
              setState(() {});
              _initStorage();
            },
          ),
          transitionsBuilder: (_, a, __, child) =>
              SlideTransition(position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)), child: child),
          transitionDuration: const Duration(milliseconds: 300),
        ));
  }

  void _showProfileSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ProfileSheet(
        onLoggedOut: () {
          Navigator.pop(context);
          AuthService.logout().then((_) {
            setState(() {
              _sessions.clear();
              _aiMemory = [];
            });
            _save();
            _newTempSession();
          });
        },
        onNameUpdated: () => setState(() {}),
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LogoCircle(size: 72),
            const SizedBox(height: 16),
            Text('What can I help with?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.ink), textAlign: TextAlign.center),
            const SizedBox(height: 28),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              childAspectRatio: 1.75,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              children: [
                _welcomeCard(Icons.auto_fix_high_rounded, 'Grammar Check', C.grad1),
                _welcomeCard(Icons.translate_rounded, 'Translation', C.green),
                _welcomeCard(Icons.school_rounded, 'Learn Tenses', const Color(0xFFF59E0B)),
                _welcomeCard(Icons.edit_note_rounded, 'Essay Writing', C.red),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _welcomeCard(IconData icon, String label, Color color) {
    return Material(
        color: C.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {},
            child: Container(
                decoration: BoxDecoration(border: Border.all(color: C.border), borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.all(13),
                child: Row(children: [
                  Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                      child: Icon(icon, color: color, size: 15)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.ink))),
                ]))));
  }

  Widget _buildInput() {
    final pad = MediaQuery.of(context).padding.bottom;
    final active = _canSend;
    return Container(
      color: C.card,
      child: Column(
        children: [
          Divider(height: 1, color: C.border),
          if (_pendingImages.isNotEmpty)
            SizedBox(
                height: 72,
                child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    scrollDirection: Axis.horizontal,
                    itemCount: _pendingImages.length,
                    itemBuilder: (ctx, i) {
                      final img = _pendingImages[i];
                      return Stack(clipBehavior: Clip.none, children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 56,
                          height: 56,
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
                                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.38), borderRadius: BorderRadius.circular(10)),
                                  child: const Center(
                                      child:
                                          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))))
                              : img.isError
                                  ? Container(
                                      decoration: BoxDecoration(color: C.red.withOpacity(0.3), borderRadius: BorderRadius.circular(10)),
                                      child: const Center(child: Icon(Icons.error_outline, color: Colors.white, size: 20)))
                                  : Align(
                                      alignment: Alignment.bottomRight,
                                      child: Container(
                                          width: 15,
                                          height: 15,
                                          margin: const EdgeInsets.all(3),
                                          decoration: BoxDecoration(color: C.green, shape: BoxShape.circle),
                                          child: const Icon(Icons.check, size: 9, color: Colors.white))),
                        ),
                        if (!img.isLoading)
                          Positioned(
                              top: -6,
                              right: 2,
                              child: GestureDetector(
                                  onTap: () => setState(() => _pendingImages.removeAt(i)),
                                  child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(color: C.red, shape: BoxShape.circle),
                                      child: const Icon(Icons.close, size: 11, color: Colors.white)))),
                      ]);
                    })),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, pad + 6),
            child: Container(
              decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Tooltip(
                      message: 'Attach image',
                      child: Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 7),
                          child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                  borderRadius: BorderRadius.circular(9),
                                  onTap: _pickImages,
                                  child: Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(9)),
                                      child: Icon(Icons.image_outlined, color: C.accent, size: 16)))))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                    controller: _inputCtrl,
                    enabled: !_isGenerating,
                    maxLines: 5,
                    minLines: 1,
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
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  gradient: (_isGenerating || active)
                                      ? const LinearGradient(colors: [C.grad1, C.grad2], begin: Alignment.topLeft, end: Alignment.bottomRight)
                                      : null,
                                  color: (!_isGenerating && !active) ? C.ink2.withOpacity(0.3) : null,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(_isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded, color: Colors.white, size: 18),
                              )))),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: pad > 0 ? 2 : 6),
            child: Text(AppConfig.mistakeTag,
                style: TextStyle(fontSize: 10, color: C.ink2), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 16. AUTH PAGE
// ════════════════════════════════════════════════════════════

class _AuthPage extends StatefulWidget {
  final bool startWithLogin;
  final VoidCallback onSuccess;
  const _AuthPage({required this.startWithLogin, required this.onSuccess});
  @override
  State<_AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<_AuthPage> with SingleTickerProviderStateMixin {
  late bool _isLogin;
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _showPass = false;
  String _error = '';

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _isLogin = widget.startWithLogin;
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    _animCtrl.reverse().then((_) {
      setState(() {
        _isLogin = !_isLogin;
        _error = '';
      });
      _animCtrl.forward();
    });
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    if (!_isLogin && name.isEmpty) {
      setState(() => _error = 'Please enter your name.');
      return;
    }
    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email.');
      return;
    }
    if (pass.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }

    setState(() {
      _loading = true;
      _error = '';
    });
    final err = _isLogin ? await AuthService.login(email, pass) : await AuthService.register(name, email, pass);
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = err);
    } else {
      widget.onSuccess();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
          backgroundColor: C.bg,
          elevation: 0,
          leading: IconButton(icon: Icon(Icons.arrow_back_rounded, color: C.ink), onPressed: () => Navigator.pop(context))),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _LogoCircle(size: 72),
              const SizedBox(height: 16),
              Text(AppConfig.appName, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.ink)),
              const SizedBox(height: 4),
              Text(_isLogin ? 'Welcome back! Please log in.' : 'Create your account.',
                  style: TextStyle(fontSize: 13, color: C.ink2)),
              const SizedBox(height: 32),
              if (!_isLogin) ...[
                _inputField(ctrl: _nameCtrl, hint: 'Full Name', icon: Icons.person_outline_rounded),
                const SizedBox(height: 12),
              ],
              _inputField(ctrl: _emailCtrl, hint: 'Email Address', icon: Icons.email_outlined, type: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _inputField(
                  ctrl: _passCtrl,
                  hint: 'Password',
                  icon: Icons.lock_outline_rounded,
                  obscure: !_showPass,
                  suffix: IconButton(
                      icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: C.ink2, size: 20),
                      onPressed: () => setState(() => _showPass = !_showPass))),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: C.red.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: C.red.withOpacity(0.2))),
                    child: Text(_error, style: TextStyle(color: C.red, fontSize: 13))),
              ],
              const SizedBox(height: 20),
              SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: C.accent,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: _loading
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_isLogin ? 'Log In' : 'Create Account',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)))),
              const SizedBox(height: 20),
              GestureDetector(
                  onTap: _toggle,
                  child: RichText(
                      text: TextSpan(style: TextStyle(fontSize: 13, color: C.ink2), children: [
                    TextSpan(text: _isLogin ? "Don't have an account? " : 'Already have an account? '),
                    TextSpan(text: _isLogin ? 'Register' : 'Log In', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700)),
                  ]))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputField({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    TextInputType? type,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Container(
        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
        child: Row(children: [
          Padding(padding: const EdgeInsets.only(left: 14), child: Icon(icon, color: C.ink2, size: 18)),
          Expanded(
              child: TextField(
                  controller: ctrl,
                  obscureText: obscure,
                  keyboardType: type,
                  style: TextStyle(fontSize: 14, color: C.ink),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: C.ink2, fontSize: 14),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ))),
          if (suffix != null) suffix,
        ]));
  }
}

// ════════════════════════════════════════════════════════════
// § 17. PROFILE SHEET
// ════════════════════════════════════════════════════════════

class _ProfileSheet extends StatefulWidget {
  final VoidCallback onLoggedOut;
  final VoidCallback onNameUpdated;
  const _ProfileSheet({required this.onLoggedOut, required this.onNameUpdated});
  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  final _nameCtrl = TextEditingController(text: AuthService.current?.name ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: C.card, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              margin: const EdgeInsets.only(top: 10, bottom: 16),
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3))),
          Row(children: [
            Text('Profile', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
            const Spacer(),
            GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.close_rounded, size: 16, color: C.ink2))),
          ]),
          const SizedBox(height: 20),
          Align(
              alignment: Alignment.centerLeft,
              child: Text('Full Name', style: TextStyle(fontSize: 12, color: C.ink2, fontWeight: FontWeight.w600))),
          const SizedBox(height: 6),
          Container(
              decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
              child: TextField(
                  controller: _nameCtrl,
                  maxLength: 50,
                  maxLines: 1,
                  style: TextStyle(fontSize: 14, color: C.ink),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'Your name',
                    hintStyle: TextStyle(color: C.ink2),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ))),
          const SizedBox(height: 8),
          Align(
              alignment: Alignment.centerLeft,
              child: Text('Email: ${AuthService.current?.email ?? ""}', style: TextStyle(fontSize: 12, color: C.ink2))),
          const SizedBox(height: 20),
          SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          final n = _nameCtrl.text.trim();
                          if (n.isEmpty) return;
                          setState(() => _saving = true);
                          await AuthService.updateName(n);
                          if (mounted) {
                            setState(() => _saving = false);
                            widget.onNameUpdated();
                            Navigator.pop(context);
                          }
                        },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: C.accent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                  child: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)))),
          const SizedBox(height: 10),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                  onPressed: widget.onLoggedOut,
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: C.red.withOpacity(0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                  child: Text('Log Out', style: TextStyle(color: C.red, fontWeight: FontWeight.w700, fontSize: 14)))),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 18. SETTINGS SHEET
// ════════════════════════════════════════════════════════════

class _SettingsSheet extends StatefulWidget {
  final List<String> aiMemory;
  final bool hasUpdate;
  final void Function(List<String>) onClearMemory;
  final VoidCallback onClearAllChats;
  final VoidCallback onLoggedOut;
  const _SettingsSheet(
      {required this.aiMemory,
      required this.hasUpdate,
      required this.onClearMemory,
      required this.onClearAllChats,
      required this.onLoggedOut});
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _showMemory = false;
  bool _showAbout = false;
  bool _showDev = false;
  bool _showUpdate = false;

  @override
  Widget build(BuildContext context) {
    if (_showMemory) return _memoryPage();
    if (_showAbout) return _aboutPage();
    if (_showDev) return _devPage();
    if (_showUpdate) return _updatePage();
    return _mainSheet();
  }

  Widget _handle() => Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      width: 36,
      height: 4,
      decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3)));

  Widget _mainSheet() {
    return Container(
      decoration: BoxDecoration(
          color: C.card, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 16, 10),
              child: Row(children: [
                Text('Settings', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
                const Spacer(),
                GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.pop(context);
                    },
                    child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.close_rounded, size: 16, color: C.ink2))),
              ])),
          Divider(height: 1, color: C.border),
          _tile(
              icon: Icons.memory_rounded,
              title: 'Manage Memory',
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _showMemory = true);
              }),
          _tile(
              icon: Icons.delete_sweep_outlined,
              title: 'Delete All Chats',
              onTap: () {
                HapticFeedback.mediumImpact();
                widget.onClearAllChats();
              }),
          _tile(
              icon: Icons.code_rounded,
              title: 'Developer',
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _showDev = true);
              }),
          _tile(
              icon: Icons.info_outline_rounded,
              title: 'About App',
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _showAbout = true);
              }),
          if (widget.hasUpdate)
            _tile(
                icon: Icons.system_update_alt_rounded,
                title: 'Update Available',
                badge: true,
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _showUpdate = true);
                })
          else
            _tile(
                icon: Icons.system_update_alt_rounded,
                title: 'Check for Updates',
                subtitle: 'v$kAppVersion — Up to date',
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _showUpdate = true);
                }),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  Widget _tile({required IconData icon, required String title, String? subtitle, bool badge = false, required VoidCallback onTap}) {
    return InkWell(
        onTap: onTap,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            child: Row(children: [
              Icon(icon, size: 18, color: C.ink2),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 14, color: C.ink, fontWeight: FontWeight.w500)),
                if (subtitle != null) Text(subtitle, style: TextStyle(fontSize: 11, color: C.ink2)),
              ])),
              if (badge)
                Container(
                    width: 8, height: 8, margin: const EdgeInsets.only(right: 6), decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle)),
              Icon(Icons.chevron_right_rounded, size: 18, color: C.ink2),
            ])));
  }

  Widget _subPageShell(
      {required String title, required Widget child, required VoidCallback onBack, double hf = 0.65, Widget? action}) {
    return Container(
      height: MediaQuery.of(context).size.height * hf,
      decoration: BoxDecoration(
          color: C.card, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      child: Column(
        children: [
          _handle(),
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Row(children: [
                GestureDetector(onTap: onBack, child: Icon(Icons.arrow_back_rounded, color: C.ink, size: 22)),
                const SizedBox(width: 12),
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.ink)),
                const Spacer(),
                if (action != null) action,
              ])),
          Divider(height: 1, color: C.border),
          Expanded(child: child),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }

  Widget _memoryPage() {
    final mem = widget.aiMemory;
    return _subPageShell(
        title: 'Manage Memory',
        hf: 0.65,
        onBack: () => setState(() => _showMemory = false),
        action: mem.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  widget.onClearMemory([]);
                  setState(() {});
                  HapticFeedback.mediumImpact();
                },
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: C.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                    child: Text('Clear All', style: TextStyle(color: C.red, fontSize: 12, fontWeight: FontWeight.w600))))
            : null,
        child: mem.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.memory_rounded, color: C.ink2, size: 32),
                const SizedBox(height: 10),
                Text('No memories yet', style: TextStyle(color: C.ink2, fontSize: 14)),
                const SizedBox(height: 6),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text('SkyGen will remember important info from your chats.',
                        style: TextStyle(color: C.ink2, fontSize: 12), textAlign: TextAlign.center)),
              ]))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: mem.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: C.border),
                itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 6, right: 12),
                          decoration: BoxDecoration(color: C.accent, shape: BoxShape.circle)),
                      Expanded(child: Text(mem[i], style: TextStyle(fontSize: 13, color: C.ink, height: 1.4))),
                      GestureDetector(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            final upd = List<String>.from(mem)..removeAt(i);
                            widget.onClearMemory(upd);
                            setState(() {});
                          },
                          child: Icon(Icons.close_rounded, size: 16, color: C.ink2)),
                    ]))));
  }

  Widget _aboutPage() {
    return _subPageShell(
        title: 'About App',
        hf: 0.72,
        onBack: () => setState(() => _showAbout = false),
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: _LogoCircle(size: 64)),
              const SizedBox(height: 14),
              Center(child: Text(AppConfig.appName, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.ink))),
              Center(child: Text(AppConfig.subTitle, style: TextStyle(fontSize: 12, color: C.ink2))),
              const SizedBox(height: 20),
              _aItem(Icons.school_rounded, 'What is ${AppConfig.appName}?',
                  '${AppConfig.appName} is a powerful AI-powered English tutor built specifically for Bangladeshi students. Grammar, translation, vocabulary, writing, and exam prep — all in one place.'),
              _aItem(Icons.auto_fix_high_rounded, 'Key Features',
                  '• Grammar correction & explanation\n• English ↔ Bengali translation\n• All 12 tenses with full breakdown\n• Essay, letter & application writing\n• SSC / HSC board exam preparation\n• Image text analysis (OCR)\n• Voice reading (TTS)\n• Smart AI memory across sessions'),
              _aItem(Icons.memory_rounded, 'Smart Memory',
                  '${AppConfig.appName} remembers important info about you — your class, learning goals, preferences — so every session feels personalized.'),
              _aItem(Icons.language_rounded, 'Language Support',
                  'Chat in Bengali, English, or Banglish — ${AppConfig.appName} mirrors your language naturally.'),
              _aItem(Icons.verified_rounded, 'Note',
                  'While ${AppConfig.appName} is accurate, it can make mistakes. Always verify important answers for exams.'),
              const SizedBox(height: 8),
              Center(child: Text('Version $kAppVersion', style: TextStyle(fontSize: 11, color: C.ink2))),
            ])));
  }

  Widget _devPage() {
    return _subPageShell(
        title: 'Developer',
        hf: 0.75,
        onBack: () => setState(() => _showDev = false),
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: _LogoCircle(size: 64, urlOverride: AppConfig.devLogoUrl)),
              const SizedBox(height: 14),
              Center(child: Text('MD. Jaid Bin Siyam', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: C.ink))),
              Center(child: Text('Student & Developer · Hyper Squad', style: TextStyle(fontSize: 12, color: C.ink2))),
              const SizedBox(height: 22),
              _aItem(Icons.person_rounded, 'About',
                  'A passionate developer from Bangladesh, student by day and builder by night. Creates apps, websites, Telegram bots, and automation tools — driven by curiosity and love for tech.'),
              _aItem(Icons.code_rounded, 'What he builds',
                  '• Flutter & mobile app development\n• Web development & backend systems\n• Telegram bot development\n• Automation & scripting\n• AI-powered tools and products'),
              _aItem(Icons.stars_rounded, 'SkyGen',
                  'SkyGen is a personal project built to help fellow students master English with AI. Every detail is crafted with care.'),
              const SizedBox(height: 16),
              Text('Contact', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: C.ink)),
              const SizedBox(height: 10),
              _contactBtn(Icons.telegram, 'Telegram', kDevTg),
              const SizedBox(height: 8),
              _contactBtn(Icons.chat_rounded, 'WhatsApp', kDevWa),
            ])));
  }

  Widget _updatePage() {
    return _subPageShell(
        title: 'Updates',
        hf: 0.65,
        onBack: () => setState(() => _showUpdate = false),
        child: _UpdateContent(
          fromSettings: true,
        ));
  }

  Widget _aItem(IconData icon, String title, String desc) {
    return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: C.accentL, borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, color: C.accent, size: 16)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: C.ink)),
            const SizedBox(height: 3),
            Text(desc, style: TextStyle(fontSize: 12, color: C.ink2, height: 1.5)),
          ])),
        ]));
  }

  Widget _contactBtn(IconData icon, String label, String url) {
    return Material(
        color: C.bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              HapticFeedback.lightImpact();
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(border: Border.all(color: C.border), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(icon, size: 18, color: C.accent),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.ink)),
                  const Spacer(),
                  Icon(Icons.open_in_new_rounded, size: 14, color: C.ink2),
                ]))));
  }
}

// ════════════════════════════════════════════════════════════
// § 19. UPDATE SHEET / DOWNLOAD MANAGER
// ════════════════════════════════════════════════════════════

class _UpdateSheet extends StatefulWidget {
  final VoidCallback onDismiss;
  const _UpdateSheet({required this.onDismiss});
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _downloadSpeed = '';
  String? _filePath;
  CancelToken? _cancelToken;

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
    });

    try {
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/skygen_update_v${AppConfig.remoteVersion}.apk';
      _cancelToken = CancelToken();

      final dio = Dio();
      var lastTime = DateTime.now();
      var lastBytes = 0;

      await dio.download(
        AppConfig.downloadUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final now = DateTime.now();
          final diff = now.difference(lastTime).inMilliseconds;
          if (diff > 500) {
            final speed = (received - lastBytes) / (diff / 1000);
            setState(() {
              _progress = received / total;
              _downloadSpeed = '${(speed / 1024).toStringAsFixed(1)} KB/s';
            });
            lastTime = now;
            lastBytes = received;
          } else {
            setState(() {
              _progress = received / total;
            });
          }
        },
        cancelToken: _cancelToken,
        options: Options(headers: {'Accept': 'application/vnd.android.package-archive'}),
      );

      setState(() {
        _isDownloading = false;
        _filePath = savePath;
      });
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        // User cancelled
      } else {
        _showError('Download failed: $e');
      }
      setState(() {
        _isDownloading = false;
        _progress = 0.0;
      });
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('Cancelled by user');
    setState(() {
      _isDownloading = false;
      _progress = 0.0;
    });
  }

  void _installUpdate() {
    if (_filePath != null) {
      OpenFilex.open(_filePath!);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: C.red));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: C.card, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(3))),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
              child: Row(children: [
                Text('Update Available', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.ink)),
                const Spacer(),
                if (!_isDownloading)
                  GestureDetector(
                      onTap: widget.onDismiss,
                      child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(8)),
                          child: Icon(Icons.close_rounded, size: 16, color: C.ink2))),
              ])),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Row(children: [
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: C.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                    child: Text('v${AppConfig.remoteVersion}', style: TextStyle(color: C.accent, fontSize: 12, fontWeight: FontWeight.w700))),
                const SizedBox(width: 8),
                Text('New version available', style: TextStyle(fontSize: 13, color: C.ink2)),
              ])),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: MarkdownBody(
                  data: AppConfig.updateNotes,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(fontSize: 13, color: C.ink, height: 1.5),
                    listBullet: TextStyle(fontSize: 13, color: C.ink),
                  ))),
          if (_isDownloading || _progress > 0) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: C.border,
                      valueColor: AlwaysStoppedAnimation<Color>(C.accent),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${(_progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, color: C.ink2)),
                      if (_downloadSpeed.isNotEmpty) Text(_downloadSpeed, style: TextStyle(fontSize: 12, color: C.ink2)),
                    ],
                  ),
                ],
              ),
            ),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 20),
            child: Row(
              children: [
                if (_filePath == null) ...[
                  Expanded(
                      child: OutlinedButton.icon(
                          onPressed: _isDownloading ? _cancelDownload : widget.onDismiss,
                          icon: Icon(_isDownloading ? Icons.close_rounded : Icons.schedule_rounded, size: 16),
                          label: Text(_isDownloading ? 'Cancel' : 'Later'),
                          style: OutlinedButton.styleFrom(
                              side: BorderSide(color: C.border),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12)))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: ElevatedButton.icon(
                          onPressed: _isDownloading ? null : _startDownload,
                          icon: Icon(_isDownloading ? Icons.downloading_rounded : Icons.download_rounded, size: 16),
                          label: Text(_isDownloading ? 'Downloading...' : 'Download'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: C.accent,
                              elevation: 0,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12)))),
                ] else ...[
                  Expanded(
                      child: ElevatedButton.icon(
                          onPressed: _installUpdate,
                          icon: const Icon(Icons.install_mobile_rounded, size: 16),
                          label: const Text('Install Update'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: C.green,
                              elevation: 0,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12)))),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateContent extends StatelessWidget {
  final bool fromSettings;
  const _UpdateContent({this.fromSettings = false});

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasUpdate) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle_rounded, color: C.green, size: 48),
        const SizedBox(height: 12),
        Text('You\'re up to date!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: C.ink)),
        const SizedBox(height: 6),
        Text('Current version: v$kAppVersion', style: TextStyle(fontSize: 13, color: C.ink2)),
      ]));
    }

    // In settings, we don't want the download button if from main sheet we already have one
    return _UpdateSheet(
      onDismiss: () => Navigator.pop(context),
    );
  }
}

// ════════════════════════════════════════════════════════════
// § 20. SCROLL FAB
// ════════════════════════════════════════════════════════════

class _ScrollFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollFab({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onTap: onTap,
        child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: C.card,
                shape: BoxShape.circle,
                border: Border.all(color: C.border, width: 1.5),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 2))]),
            child: Icon(Icons.keyboard_double_arrow_down_rounded, color: C.ink, size: 20)));
  }
}

// ════════════════════════════════════════════════════════════
// § 21. IMAGE VIEWER
// ════════════════════════════════════════════════════════════

class _ImageViewerPage extends StatefulWidget {
  final String imageUrl;
  const _ImageViewerPage({required this.imageUrl});
  @override
  State<_ImageViewerPage> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewerPage> {
  final _tc = TransformationController();
  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context))),
        body: Center(
            child: InteractiveViewer(
                transformationController: _tc,
                minScale: 0.5,
                maxScale: 5.0,
                child: CachedNetworkImage(
                    imageUrl: widget.imageUrl,
                    fit: BoxFit.contain,
                    placeholder: (_, __) => const Center(child: CircularProgressIndicator(color: Colors.white)),
                    errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white, size: 48)))));
  }
}

// ════════════════════════════════════════════════════════════
// § 22. BUBBLE WIDGET
// ════════════════════════════════════════════════════════════

class _BubbleWidget extends StatefulWidget {
  final ChatMsg msg;
  final bool isPlayingTTS;
  final bool isTTSLoading;
  final void Function(String, String) onSpeak;
  final void Function(String) onCopy;
  final void Function(String) onLike;
  final void Function(String) onDislike;
  final void Function(String) onImageTap;

  const _BubbleWidget({
    super.key,
    required this.msg,
    required this.isPlayingTTS,
    required this.isTTSLoading,
    required this.onSpeak,
    required this.onCopy,
    required this.onLike,
    required this.onDislike,
    required this.onImageTap,
  });
  @override
  State<_BubbleWidget> createState() => _BubbleState();
}

class _BubbleState extends State<_BubbleWidget> with SingleTickerProviderStateMixin {
  late AnimationController _fc;
  late Animation<double> _fa;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _fc = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _fa = CurvedAnimation(parent: _fc, curve: Curves.easeOut);
    if (widget.msg.type == MsgType.ai && widget.msg.status == GenStatus.completed) {
      _fc.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_BubbleWidget old) {
    super.didUpdateWidget(old);
    if (widget.msg.status == GenStatus.completed && old.msg.status != GenStatus.completed && widget.msg.type == MsgType.ai) {
      _fc.forward();
    }
  }

  @override
  void dispose() {
    _fc.dispose();
    super.dispose();
  }

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
        children: [
          Flexible(
              child: GestureDetector(
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
                              spacing: 6,
                              runSpacing: 6,
                              alignment: WrapAlignment.end,
                              children: widget.msg.imgUrls!
                                  .map((url) => GestureDetector(
                                        onTap: () => widget.onImageTap(url),
                                        child: ClipRRect(
                                            borderRadius: BorderRadius.circular(10),
                                            child: CachedNetworkImage(
                                                imageUrl: url,
                                                width: 108,
                                                height: 108,
                                                fit: BoxFit.cover,
                                                placeholder: (_, __) => Container(width: 108, height: 108, color: C.border))),
                                      ))
                                  .toList())),
                    if (widget.msg.text.isNotEmpty)
                      Container(
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                              color: C.userBub,
                              borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(4),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(16))),
                          child: Text(widget.msg.text, style: TextStyle(fontSize: 14.5, color: C.ink, height: 1.45))),
                  ]))),
        ],
      );

  Widget _ai() {
    final isWaiting = widget.msg.status == GenStatus.waiting || (widget.msg.status == GenStatus.streaming && widget.msg.visibleText.isEmpty);
    final isDone = widget.msg.status == GenStatus.completed;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isWaiting)
        const _ThinkingDots()
      else ...[
        if (widget.msg.visibleText.isNotEmpty)
          Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
              child: MarkdownBody(
                  data: widget.msg.visibleText,
                  selectable: true,
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
                      tableBody: const TextStyle(fontSize: 13, height: 1.4)))),
        if (widget.msg.status == GenStatus.error)
          Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: C.red.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: C.red.withOpacity(0.2))),
              child: Text(widget.msg.text, style: TextStyle(color: C.red, fontSize: 13))),
        if (isDone && widget.msg.text.isNotEmpty)
          FadeTransition(
              opacity: _fa,
              child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _aBtn(
                        icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                        color: _copied ? C.green : C.ink2,
                        tip: 'Copy',
                        onTap: () {
                          widget.onCopy(widget.msg.text);
                          HapticFeedback.lightImpact();
                          setState(() => _copied = true);
                          Future.delayed(const Duration(milliseconds: 1300), () {
                            if (mounted) setState(() => _copied = false);
                          });
                        }),
                    widget.isTTSLoading
                        ? SizedBox(
                            width: 30,
                            height: 30,
                            child: Center(
                                child: SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: C.ink2))))
                        : _aBtn(
                            icon: widget.isPlayingTTS ? Icons.pause_rounded : Icons.volume_up_rounded,
                            color: widget.isPlayingTTS ? C.accent : C.ink2,
                            tip: widget.isPlayingTTS ? 'Pause' : 'Listen',
                            onTap: () => widget.onSpeak(widget.msg.id, widget.msg.text)),
                    _aBtn(
                        icon: Icons.thumb_up_rounded,
                        color: widget.msg.liked ? C.accent : C.ink2,
                        tip: 'Like',
                        onTap: () {
                          widget.onLike(widget.msg.id);
                          HapticFeedback.lightImpact();
                        }),
                    _aBtn(
                        icon: Icons.thumb_down_rounded,
                        color: widget.msg.disliked ? C.red : C.ink2,
                        tip: 'Dislike',
                        onTap: () {
                          widget.onDislike(widget.msg.id);
                          HapticFeedback.lightImpact();
                        }),
                  ]))),
      ],
    ]);
  }

  Widget _aBtn({required IconData icon, required Color color, required String tip, required VoidCallback onTap}) {
    return Tooltip(
        message: tip,
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(icon, key: ValueKey(icon), size: 15, color: color))))));
  }
}

// ════════════════════════════════════════════════════════════
// § 23. THINKING DOTS
// ════════════════════════════════════════════════════════════

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
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  final t = ((_c.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
                  return Transform.translate(
                      offset: Offset(0, -sin(t * pi) * 5.0),
                      child: Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 5),
                          decoration: BoxDecoration(color: C.accent.withOpacity(0.45 + 0.55 * sin(t * pi)), shape: BoxShape.circle)));
                }))));
  }
}
