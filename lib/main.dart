import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String kLifecycleChannelName = 'localshare/lifecycle';
const String kServiceChannelName = 'localshare/service';
const String kClipboardChannelName = 'localshare/clipboard';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFFF7F9FB);
    const primary = Color(0xFF1353D8);
    const primaryDark = Color(0xFF002E88);
    const surface = Colors.white;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '本地分享',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          primary: primary,
          secondary: const Color(0xFFD0E1FB),
          surface: surface,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: primaryDark,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: primaryDark,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: primaryDark,
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          hintStyle: const TextStyle(color: Color(0xFF7C8291)),
          contentPadding: const EdgeInsets.all(18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: const BorderSide(color: Color(0xFFE0E3E5)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: const BorderSide(color: primary, width: 1.4),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
      ),
      home: const MyHomePage(title: '本地分享'),
    );
  }
}

enum AttachmentKind {
  image,
  audio,
  video,
  document,
  archive,
  other,
}

class CardAttachment {
  CardAttachment({
    required this.id,
    required this.cardId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.localPath,
    required this.kind,
    required this.createdAt,
  });

  final String id;
  final String cardId;
  final String name;
  final String mimeType;
  final int size;
  final String localPath;
  final AttachmentKind kind;
  final DateTime createdAt;

  bool get isPreviewable =>
      kind == AttachmentKind.image ||
      kind == AttachmentKind.audio ||
      kind == AttachmentKind.video ||
      mimeType == 'application/pdf';

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'cardId': cardId,
      'name': name,
      'mimeType': mimeType,
      'size': size,
      'localPath': localPath,
      'kind': kind.name,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toPublicJson() {
    return {
      'id': id,
      'cardId': cardId,
      'name': name,
      'mimeType': mimeType,
      'size': size,
      'kind': kind.name,
      'createdAt': createdAt.toIso8601String(),
      'downloadUrl': '/files/$id',
      'previewUrl': '/files/$id?view=1',
      'previewable': isPreviewable,
    };
  }

  factory CardAttachment.fromJson(Map<String, dynamic> json) {
    return CardAttachment(
      id: json['id'] as String,
      cardId: json['cardId'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      localPath: json['localPath'] as String,
      kind: AttachmentKind.values.firstWhere(
        (value) => value.name == json['kind'],
        orElse: () => AttachmentKind.other,
      ),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class CardItem {
  CardItem({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.pinnedAt,
    List<String>? attachmentIds,
  }) : attachmentIds = attachmentIds ?? <String>[];

  final String id;
  String text;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? pinnedAt;
  final List<String> attachmentIds;

  bool get isPinned => pinnedAt != null;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'pinnedAt': pinnedAt?.toIso8601String(),
      'attachmentIds': attachmentIds,
    };
  }

  Map<String, dynamic> toPublicJson(Map<String, CardAttachment> attachmentMap) {
    return {
      'id': id,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'pinnedAt': pinnedAt?.toIso8601String(),
      'pinned': isPinned,
      'attachments': attachmentIds
          .map((attachmentId) => attachmentMap[attachmentId])
          .whereType<CardAttachment>()
          .map((attachment) => attachment.toPublicJson())
          .toList(),
    };
  }

  factory CardItem.fromJson(Map<String, dynamic> json) {
    return CardItem(
      id: json['id'] as String,
      text: json['text'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      pinnedAt: DateTime.tryParse(json['pinnedAt'] as String? ?? ''),
      attachmentIds: (json['attachmentIds'] as List<dynamic>? ?? <dynamic>[])
          .map((value) => value as String)
          .toList(),
    );
  }
}

class LocalShareStorage {
  LocalShareStorage._(this.rootDir)
      : attachmentsDir = Directory('${rootDir.path}/attachments'),
        stateFile = File('${rootDir.path}/cards_state_v2.json'),
        backupDir = Directory('${rootDir.path}/backups');

  static const String legacyDocumentKey = 'document_content';
  static const String legacyAppStateKey = 'cards_state_v1';
  static const int schemaVersion = 2;

  final Directory rootDir;
  final Directory attachmentsDir;
  final File stateFile;
  final Directory backupDir;

  static Future<LocalShareStorage> create() async {
    Directory baseDir;
    try {
      baseDir = await getApplicationSupportDirectory();
    } catch (_) {
      try {
        baseDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        baseDir = Directory('${Directory.systemTemp.path}/localshare_data');
      }
    }
    final root = Directory('${baseDir.path}/localshare');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return LocalShareStorage._(root);
  }

  Future<void> ensureReady() async {
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
  }

  Future<PersistedState> loadState() async {
    await ensureReady();
    if (await stateFile.exists()) {
      try {
        return _decodeState(await stateFile.readAsString());
      } catch (_) {
        final fallback = await _loadLatestBackup();
        if (fallback != null) {
          return fallback;
        }
        rethrow;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final savedState = prefs.getString(legacyAppStateKey);
    if (savedState != null && savedState.isNotEmpty) {
      await _writeBackup('legacy-migration', savedState);
      final decoded = _decodeState(savedState, allowLegacyEnvelope: true);
      await saveState(decoded.cards, decoded.attachments);
      return decoded;
    }

    final legacyContent = prefs.getString(legacyDocumentKey) ?? '';
    if (legacyContent.trim().isNotEmpty) {
      final now = DateTime.now();
      final migrated = PersistedState(
        cards: <CardItem>[
          CardItem(
            id: 'card-${now.microsecondsSinceEpoch}',
            text: legacyContent,
            createdAt: now,
            updatedAt: now,
          ),
        ],
        attachments: <CardAttachment>[],
      );
      await _writeBackup(
        'legacy-text',
        jsonEncode({'document_content': legacyContent}),
      );
      await saveState(migrated.cards, migrated.attachments);
      return migrated;
    }

    return const PersistedState(
        cards: <CardItem>[], attachments: <CardAttachment>[]);
  }

  Future<PersistedState?> _loadLatestBackup() async {
    if (!await backupDir.exists()) {
      return null;
    }
    final files = await backupDir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.isEmpty) {
      return null;
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    for (final file in files) {
      try {
        return _decodeState(await file.readAsString(),
            allowLegacyEnvelope: true);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  PersistedState _decodeState(String source,
      {bool allowLegacyEnvelope = false}) {
    final decoded = jsonDecode(source) as Map<String, dynamic>;
    final cardsJson = decoded['cards'] as List<dynamic>? ?? <dynamic>[];
    final attachmentsJson =
        decoded['attachments'] as List<dynamic>? ?? <dynamic>[];

    if (!allowLegacyEnvelope && !decoded.containsKey('version')) {
      throw const FormatException('Missing state version');
    }

    return PersistedState(
      cards: cardsJson
          .map((item) => CardItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      attachments: attachmentsJson
          .map((item) => CardAttachment.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<void> saveState(
    List<CardItem> cards,
    Iterable<CardAttachment> attachments,
  ) async {
    await ensureReady();
    final payload = jsonEncode({
      'version': schemaVersion,
      'savedAt': DateTime.now().toIso8601String(),
      'cards': cards.map((card) => card.toJson()).toList(),
      'attachments':
          attachments.map((attachment) => attachment.toJson()).toList(),
    });

    if (await stateFile.exists()) {
      try {
        await _writeBackup('autosave', await stateFile.readAsString());
      } catch (_) {}
    }

    final tempFile = File('${stateFile.path}.tmp');
    await tempFile.writeAsString(payload, flush: true);
    if (await stateFile.exists()) {
      await stateFile.delete();
    }
    await tempFile.rename(stateFile.path);
  }

  Future<void> _writeBackup(String reason, String payload) async {
    await ensureReady();
    final file = File(
      '${backupDir.path}/${DateTime.now().millisecondsSinceEpoch}_$reason.json',
    );
    await file.writeAsString(payload, flush: true);
  }
}

class PersistedState {
  const PersistedState({required this.cards, required this.attachments});

  final List<CardItem> cards;
  final List<CardAttachment> attachments;
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  static const MethodChannel _lifecycleChannel =
      MethodChannel(kLifecycleChannelName);
  static const MethodChannel _serviceChannel =
      MethodChannel(kServiceChannelName);
  static const MethodChannel _clipboardChannel =
      MethodChannel(kClipboardChannelName);
  static const String _preferredPortKey = 'preferred_server_port';
  static const String _useFixedPortKey = 'use_fixed_server_port';
  static const String _confirmDeleteKey = 'confirm_delete_before_remove';
  static const int _defaultServerPort = 35773;
  static const int _maxPinnedCards = 5;

  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<WebSocketChannel> _webSocketClients = <WebSocketChannel>[];
  final Random _random = Random();

  final List<CardItem> _cards = <CardItem>[];
  final Map<String, CardAttachment> _attachments = <String, CardAttachment>{};
  final List<_IncomingAttachmentPayload> _pendingAttachments =
      <_IncomingAttachmentPayload>[];

  LocalShareStorage? _storage;
  HttpServer? _server;
  StreamSubscription? _intentDataStreamSubscription;
  Timer? _saveDebounceTimer;
  Timer? _broadcastDebounceTimer;
  Timer? _stateRefreshTimer;

  String _serverAddress = '服务启动中';
  String _publicHost = '127.0.0.1';
  int _preferredPort = _defaultServerPort;
  bool _useFixedPort = false;
  bool _confirmDelete = true;
  bool _isServerRunning = false;
  bool _isPickingFiles = false;
  bool _isLoading = true;
  DateTime? _lastStateSyncAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      _storage = await LocalShareStorage.create();
      await _loadPreferences();
      final state = await _storage!.loadState();
      _cards
        ..clear()
        ..addAll(state.cards);
      _attachments
        ..clear()
        ..addEntries(state.attachments.map((e) => MapEntry(e.id, e)));
      await _markStateSynced();
      await _setupSharingHandlers();
      await _startServer();
      _startStateRefreshLoop();
    } catch (error) {
      _showToast('初始化失败: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _useFixedPort = prefs.getBool(_useFixedPortKey) ?? false;
    _confirmDelete = prefs.getBool(_confirmDeleteKey) ?? true;
    final savedPort = prefs.getInt(_preferredPortKey);
    if (savedPort != null && savedPort >= 1 && savedPort <= 65535) {
      _preferredPort = savedPort;
    }
  }

  Future<void> _savePortSettings({
    required bool useFixedPort,
    required int port,
    required bool confirmDelete,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useFixedPortKey, useFixedPort);
    await prefs.setInt(_preferredPortKey, port);
    await prefs.setBool(_confirmDeleteKey, confirmDelete);
    _useFixedPort = useFixedPort;
    _preferredPort = port;
    _confirmDelete = confirmDelete;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopServer());
    _composerController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _saveDebounceTimer?.cancel();
    _broadcastDebounceTimer?.cancel();
    _stateRefreshTimer?.cancel();
    _intentDataStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshStateFromStorageIfChanged(force: true));
    }
  }

  List<CardItem> get _sortedCards {
    final query = _searchController.text.trim().toLowerCase();
    final items = _cards.where((card) {
      if (query.isEmpty) {
        return true;
      }
      if (card.text.toLowerCase().contains(query)) {
        return true;
      }
      for (final attachmentId in card.attachmentIds) {
        final attachment = _attachments[attachmentId];
        if (attachment != null &&
            attachment.name.toLowerCase().contains(query)) {
          return true;
        }
      }
      return false;
    }).toList();

    return _sortCards(items);
  }

  List<CardItem> _sortCards(Iterable<CardItem> cards) {
    final items = cards.toList();
    items.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      if (a.isPinned && b.isPinned) {
        final pinCompare = b.pinnedAt!.compareTo(a.pinnedAt!);
        if (pinCompare != 0) {
          return pinCompare;
        }
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return items;
  }

  Future<void> _persistStateNow() async {
    if (_storage == null) {
      return;
    }
    await _storage!.saveState(_cards, _attachments.values);
    await _markStateSynced();
  }

  void _schedulePersist() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 200), () async {
      try {
        await _persistStateNow();
      } catch (error) {
        _showToast('保存失败，请稍后重试');
        debugPrint('persist failed: $error');
      }
    });
  }

  Future<void> _markStateSynced() async {
    final storage = _storage;
    if (storage == null || !await storage.stateFile.exists()) {
      return;
    }
    _lastStateSyncAt = await storage.stateFile.lastModified();
  }

  void _startStateRefreshLoop() {
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshStateFromStorageIfChanged()),
    );
  }

  Future<void> _refreshStateFromStorageIfChanged({bool force = false}) async {
    final storage = _storage;
    if (storage == null || !await storage.stateFile.exists()) {
      return;
    }
    final modifiedAt = await storage.stateFile.lastModified();
    if (!force &&
        _lastStateSyncAt != null &&
        !modifiedAt.isAfter(_lastStateSyncAt!)) {
      return;
    }
    final state = await storage.loadState();
    _cards
      ..clear()
      ..addAll(state.cards);
    _attachments
      ..clear()
      ..addEntries(state.attachments.map((entry) => MapEntry(entry.id, entry)));
    _lastStateSyncAt = modifiedAt;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setupSharingHandlers() async {
    try {
      _intentDataStreamSubscription = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen((items) => _consumeSharedItems(items, autoClose: true));
      final initialItems =
          await ReceiveSharingIntent.instance.getInitialMedia();
      if (initialItems.isNotEmpty) {
        await _consumeSharedItems(initialItems, autoClose: true);
        await ReceiveSharingIntent.instance.reset();
      }
    } catch (_) {
      // Unsupported platform/test env.
    }
  }

  Future<void> _consumeSharedItems(
    List<SharedMediaFile> files, {
    required bool autoClose,
  }) async {
    if (files.isEmpty) {
      return;
    }

    final textParts = <String>[];
    final filePayloads = <_IncomingAttachmentPayload>[];

    for (final item in files) {
      if (item.type == SharedMediaType.text && item.path.isNotEmpty) {
        textParts.add(item.path.trim());
        continue;
      }

      final file = File(item.path);
      if (!await file.exists()) {
        continue;
      }
      final bytes = await file.readAsBytes();
      final fileName = _basename(item.path);
      filePayloads.add(
        _IncomingAttachmentPayload(
          name: fileName,
          mimeType: _guessMimeType(fileName),
          bytes: bytes,
        ),
      );
    }

    if (textParts.isEmpty && filePayloads.isEmpty) {
      return;
    }

    final textContent =
        textParts.where((value) => value.isNotEmpty).join('\n\n');
    final fallbackText = filePayloads.length == 1
        ? '收到文件：${filePayloads.first.name}'
        : '收到 ${filePayloads.length} 个文件';

    try {
      await _createCard(
        text: textContent.isNotEmpty ? textContent : fallbackText,
        attachments: filePayloads,
      );
      _showToast('已保存到本地分享');
      if (autoClose && Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        await _closeAfterShareIfNeeded();
      }
    } catch (error) {
      _showToast('保存分享内容失败');
      debugPrint('share consume failed: $error');
    }
  }

  Future<void> _closeAfterShareIfNeeded() async {
    try {
      await _lifecycleChannel.invokeMethod<void>('closeApp');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty || parts.last.isEmpty ? 'attachment' : parts.last;
  }

  Future<CardItem> _createCard({
    required String text,
    List<_IncomingAttachmentPayload>? attachments,
    bool notify = true,
  }) async {
    final now = DateTime.now();
    final card = CardItem(
      id: _generateId('card'),
      text: text.trim(),
      createdAt: now,
      updatedAt: now,
    );
    _cards.add(card);

    if (attachments != null && attachments.isNotEmpty) {
      for (final payload in attachments) {
        await _createAttachment(
          cardId: card.id,
          fileName: payload.name,
          bytes: payload.bytes,
          mimeType: payload.mimeType,
          notify: false,
        );
      }
    }

    await _persistStateNow();
    if (notify) {
      _broadcastSnapshot();
    }
    if (mounted) {
      setState(() {});
    }
    return card;
  }

  Future<CardAttachment> _createAttachment({
    required String cardId,
    required String? fileName,
    required List<int> bytes,
    required String mimeType,
    bool notify = true,
  }) async {
    final storage = _storage;
    if (storage == null) {
      throw StateError('Storage not initialized');
    }
    await storage.ensureReady();
    final displayName = (fileName == null || fileName.trim().isEmpty)
        ? 'attachment'
        : fileName.trim();
    final attachmentId = _generateId('file');
    final storedFileName = _buildStoredFileName(displayName, attachmentId);
    final targetPath = '${storage.attachmentsDir.path}/$storedFileName';
    final file = File(targetPath);
    await file.writeAsBytes(bytes, flush: true);

    final attachment = CardAttachment(
      id: attachmentId,
      cardId: cardId,
      name: displayName,
      mimeType: mimeType,
      size: bytes.length,
      localPath: targetPath,
      kind: _kindFromMimeType(mimeType, displayName),
      createdAt: DateTime.now(),
    );
    _attachments[attachment.id] = attachment;

    final card = _findCard(cardId);
    if (card != null) {
      card.attachmentIds.add(attachment.id);
      card.updatedAt = DateTime.now();
    }

    if (notify) {
      await _persistStateNow();
      _broadcastSnapshot();
    }
    return attachment;
  }

  CardItem? _findCard(String id) {
    for (final card in _cards) {
      if (card.id == id) {
        return card;
      }
    }
    return null;
  }

  Future<void> _deleteCard(String cardId) async {
    final card = _findCard(cardId);
    if (card == null) {
      return;
    }
    for (final attachmentId in card.attachmentIds) {
      final attachment = _attachments.remove(attachmentId);
      if (attachment != null) {
        final file = File(attachment.localPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    _cards.removeWhere((item) => item.id == cardId);
    await _persistStateNow();
    _broadcastSnapshot();
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _showDeleteConfirmDialog({
    required String title,
    required String message,
    String confirmLabel = '删除',
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFBA1A1A),
              foregroundColor: Colors.white,
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteCardWithConfirm(CardItem card) async {
    if (_confirmDelete) {
      final confirmed = await _showDeleteConfirmDialog(
        title: '删除卡片',
        message: '删除后将同时移除这张卡片及其附件，确认继续吗？',
      );
      if (!confirmed) {
        return;
      }
    }
    await _deleteCard(card.id);
  }

  Future<void> _clearAllCards() async {
    if (_cards.isEmpty) {
      _showToast('当前没有可清空的卡片');
      return;
    }
    final confirmed = await _showDeleteConfirmDialog(
      title: '清空所有卡片',
      message: '这会删除全部卡片和所有附件，且无法恢复。',
      confirmLabel: '全部清空',
    );
    if (!confirmed) {
      return;
    }
    for (final attachment in _attachments.values) {
      final file = File(attachment.localPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _attachments.clear();
    _cards.clear();
    await _persistStateNow();
    _broadcastSnapshot();
    if (mounted) {
      setState(() {});
    }
    _showToast('已清空所有卡片');
  }

  Future<void> _togglePinnedCard(CardItem card) async {
    final nextPinnedAt = card.isPinned ? null : DateTime.now();
    if (nextPinnedAt != null) {
      final pinnedCount = _cards.where((item) => item.isPinned).length;
      if (pinnedCount >= _maxPinnedCards) {
        _showToast('最多只能置顶 $_maxPinnedCards 个卡片');
        return;
      }
    }
    card.pinnedAt = nextPinnedAt;
    await _persistStateNow();
    _broadcastSnapshot();
    if (mounted) {
      setState(() {});
    }
    _showToast(nextPinnedAt == null ? '已取消置顶' : '已置顶到卡片顶部');
  }

  Future<void> _copyCardText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showToast(text.trim().isEmpty ? '空卡片已复制' : '卡片内容已复制');
  }

  Uri? _extractStandaloneUrl(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    return uri;
  }

  Future<void> _openCardUrl(CardItem card) async {
    final uri = _extractStandaloneUrl(card.text);
    if (uri == null) {
      _showToast('这张卡片不是可直接打开的链接');
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _showToast('无法打开该链接');
    }
  }

  Future<void> _shareCard(CardItem card) async {
    final text = card.text.trim();
    if (text.isEmpty) {
      _showToast('空卡片暂不支持分享');
      return;
    }
    try {
      await Share.share(text, subject: '本地分享');
    } catch (error) {
      _showToast('分享失败');
      debugPrint('shareCard failed: $error');
    }
  }

  void _showToast(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyServerAddress() async {
    if (!_isServerRunning) {
      _showToast('服务尚未启动');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _serverAddress));
    _showToast('访问地址已复制');
  }

  Future<void> _syncForegroundService() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _serviceChannel.invokeMethod<void>('startForegroundService', {
        'address': _serverAddress,
        'port': _server?.port ?? _preferredPort,
      });
    } catch (error) {
      debugPrint('startForegroundService failed: $error');
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _serviceChannel.invokeMethod<void>('stopForegroundService');
    } catch (error) {
      debugPrint('stopForegroundService failed: $error');
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _serviceChannel.invokeMethod<bool>('requestNotificationPermission');
    } catch (error) {
      debugPrint('requestNotificationPermission failed: $error');
    }
  }

  Future<void> _openSettings() async {
    final nextSettings = await Navigator.of(context).push<_PortSettingsResult>(
      MaterialPageRoute<_PortSettingsResult>(
        builder: (context) => LocalShareSettingsPage(
          initialUseFixedPort: _useFixedPort,
          initialPort: _preferredPort,
          initialConfirmDelete: _confirmDelete,
        ),
      ),
    );
    if (nextSettings == null ||
        (nextSettings.port == _preferredPort &&
            nextSettings.useFixedPort == _useFixedPort &&
            nextSettings.confirmDelete == _confirmDelete &&
            !nextSettings.clearAllCards)) {
      return;
    }
    await _savePortSettings(
      useFixedPort: nextSettings.useFixedPort,
      port: nextSettings.port,
      confirmDelete: nextSettings.confirmDelete,
    );
    if (nextSettings.clearAllCards) {
      await _clearAllCards();
    }
    _showToast(
      nextSettings.clearAllCards
          ? '设置已更新'
          : nextSettings.useFixedPort
              ? '固定端口已更新为 ${nextSettings.port}'
              : '已切换为随机端口',
    );
    if (_isServerRunning) {
      await _stopServer();
      await _startServer();
    } else if (mounted) {
      setState(() {
        _serverAddress = '服务未启动';
      });
    }
  }

  Uri? _buildAttachmentUri(CardAttachment attachment, {bool preview = false}) {
    if (!_isServerRunning) {
      return null;
    }
    final baseUri = Uri.tryParse(_serverAddress);
    if (baseUri == null) {
      return null;
    }
    return baseUri.replace(
      path: '/files/${attachment.id}',
      queryParameters: preview ? <String, String>{'view': '1'} : null,
    );
  }

  Future<void> _openAttachment(
    CardAttachment attachment, {
    bool preview = false,
  }) async {
    final uri = _buildAttachmentUri(attachment, preview: preview);
    if (uri == null) {
      _showToast('服务尚未启动');
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _showToast(preview ? '无法打开预览' : '无法打开下载链接');
    }
  }

  Future<void> _showImagePreview(CardAttachment attachment) async {
    if (!mounted) {
      return;
    }
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: '图片预览',
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.01),
                    child: Center(
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 4,
                        child: Hero(
                          tag: 'attachment-preview-${attachment.id}',
                          child: Image.file(
                            File(attachment.localPath),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return _buildImagePreviewFallback(compact: false);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => Navigator.of(context).pop(),
                    child: Ink(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _createCardFromComposer() async {
    final value = _composerController.text.trim();
    if (value.isEmpty && _pendingAttachments.isEmpty) {
      return;
    }
    await _createCard(
      text: value,
      attachments: List<_IncomingAttachmentPayload>.from(_pendingAttachments),
    );
    if (mounted) {
      setState(() {
        _composerController.clear();
        _pendingAttachments.clear();
      });
    }
  }

  Future<void> _pasteClipboardToComposer() async {
    if (Platform.isAndroid) {
      try {
        final payload = await _clipboardChannel
            .invokeMapMethod<String, dynamic>('readClipboardPayload');
        final type = payload?['type'] as String? ?? 'empty';
        if (type == 'image') {
          final bytes = payload?['bytes'];
          final imageBytes = switch (bytes) {
            final List<int> list => list,
            _ => <int>[],
          };
          if (imageBytes.isEmpty) {
            _showToast('剪贴板图片读取失败');
            return;
          }
          final mimeType =
              payload?['mimeType'] as String? ?? 'application/octet-stream';
          final name = payload?['name'] as String? ??
              'pasted-image.${_extensionForMimeType(mimeType)}';
          if (mounted) {
            setState(() {
              _pendingAttachments.add(
                _IncomingAttachmentPayload(
                  name: name,
                  mimeType: mimeType,
                  bytes: imageBytes,
                ),
              );
            });
          }
          _showToast('已粘贴图片');
          return;
        }
        if (type == 'text') {
          final text = (payload?['text'] as String? ?? '').trim();
          if (text.isNotEmpty) {
            if (mounted) {
              setState(() {
                _composerController.text = text;
                _composerController.selection = TextSelection.collapsed(
                  offset: _composerController.text.length,
                );
              });
            }
            _showToast('已粘贴文本');
            return;
          }
        }
      } on PlatformException catch (error) {
        debugPrint('pasteClipboardToComposer failed: $error');
      }
    }

    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) {
      _showToast('剪贴板里没有可粘贴的内容');
      return;
    }

    if (mounted) {
      setState(() {
        _composerController.text = text;
        _composerController.selection = TextSelection.collapsed(
          offset: _composerController.text.length,
        );
      });
    }
    _showToast('已粘贴文本');
  }

  Future<void> _pickFilesFromDevice() async {
    if (_isPickingFiles) {
      return;
    }
    setState(() {
      _isPickingFiles = true;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final picked = <_IncomingAttachmentPayload>[];
      for (final file in result.files) {
        List<int>? bytes = file.bytes;
        if ((bytes == null || bytes.isEmpty) && file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        }
        if (bytes == null || bytes.isEmpty) {
          continue;
        }
        picked.add(
          _IncomingAttachmentPayload(
            name: file.name,
            mimeType: file.extension == null
                ? 'application/octet-stream'
                : _guessMimeType(file.name),
            bytes: bytes,
          ),
        );
      }

      if (picked.isEmpty) {
        return;
      }

      if (mounted) {
        setState(() {
          _pendingAttachments.addAll(picked);
        });
      }
    } catch (error) {
      _showToast('选择文件失败: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isPickingFiles = false;
        });
      } else {
        _isPickingFiles = false;
      }
    }
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) {
      return;
    }
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToBottom() async {
    if (!_scrollController.hasClients) {
      return;
    }
    await _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _startServer() async {
    if (_isServerRunning) {
      return;
    }

    try {
      await _requestNotificationPermission();
      final ipAddress = await _getLocalIpAddress();
      if (ipAddress == null) {
        setState(() {
          _serverAddress = '无法获取本机 IP';
        });
        return;
      }

      final router = shelf_router.Router()
        ..get('/', _handleIndex)
        ..get('/api/cards', _handleGetCards)
        ..post('/api/cards', _handleCreateCard)
        ..post('/api/cards/<cardId>/delete', _handleDeleteCard)
        ..post('/api/cards/reorder', _handleReorderCards)
        ..post('/api/cards/<cardId>/attachments', _handleAddAttachments)
        ..get('/files/<attachmentId>', _handleGetFile);

      final wsHandler = webSocketHandler((webSocket, protocol) {
        _webSocketClients.add(webSocket);
        _sendSnapshotToClient(webSocket);

        webSocket.stream.listen(
          (message) async {
            await _handleWebSocketMessage(webSocket, message);
          },
          onDone: () {
            _webSocketClients.remove(webSocket);
          },
          onError: (_) {
            _webSocketClients.remove(webSocket);
          },
        );
      });

      Future<Response> handler(Request request) async {
        if (request.url.path == 'ws') {
          return wsHandler(request);
        }
        return router.call(request);
      }

      final targetPort = _useFixedPort ? _preferredPort : 0;
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        targetPort,
        shared: true,
      );
      if (mounted) {
        setState(() {
          _publicHost = ipAddress;
          _serverAddress = 'http://$_publicHost:${_server!.port}';
          _isServerRunning = true;
        });
      }
      await _syncForegroundService();
    } on SocketException catch (error) {
      final addressInUse = error.osError?.errorCode == 48 ||
          error.osError?.errorCode == 98 ||
          error.message.contains('Address already in use');
      if (mounted) {
        setState(() {
          _serverAddress =
              addressInUse ? '端口 $_preferredPort 已被占用' : '服务器启动失败: $error';
        });
      }
      if (addressInUse) {
        _showToast('端口 $_preferredPort 已被占用，请到设置页修改');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _serverAddress = '服务器启动失败: $error';
        });
      }
    }
  }

  Future<void> _stopServer() async {
    if (!_isServerRunning) {
      return;
    }
    for (final client in _webSocketClients) {
      client.sink.close();
    }
    _webSocketClients.clear();
    await _stopForegroundService();
    await _server?.close(force: true);
    _server = null;
    if (mounted) {
      setState(() {
        _isServerRunning = false;
        _serverAddress = '服务器已停止';
      });
    } else {
      _isServerRunning = false;
    }
  }

  Future<String?> _getLocalIpAddress() async {
    try {
      final wifiInfo = NetworkInfo();
      final ip = await wifiInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty) {
        return ip;
      }
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            return address.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Map<String, dynamic> _buildSnapshot() {
    final cards = _sortCards(_cards)
        .map((card) => card.toPublicJson(_attachments))
        .toList();
    return {
      'type': 'cardsSnapshot',
      'cards': cards,
      'serverTime': DateTime.now().toIso8601String(),
      'address': _serverAddress,
    };
  }

  void _broadcastSnapshot() {
    _broadcastDebounceTimer?.cancel();
    _broadcastDebounceTimer = Timer(const Duration(milliseconds: 80), () {
      final message = jsonEncode(_buildSnapshot());
      for (final client in _webSocketClients) {
        client.sink.add(message);
      }
    });
    if (mounted) {
      setState(() {});
    }
  }

  void _sendSnapshotToClient(WebSocketChannel client) {
    client.sink.add(jsonEncode(_buildSnapshot()));
  }

  Future<void> _handleWebSocketMessage(
    WebSocketChannel sender,
    dynamic message,
  ) async {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';
      if (type == 'createCard') {
        final text = data['text'] as String? ?? '';
        final attachmentsData =
            data['attachments'] as List<dynamic>? ?? <dynamic>[];
        final attachments = attachmentsData
            .map((item) => _IncomingAttachmentPayload.fromJson(
                  item as Map<String, dynamic>,
                ))
            .toList();
        await _createCard(text: text, attachments: attachments);
      } else if (type == 'deleteCard') {
        final cardId = data['cardId'] as String? ?? '';
        await _deleteCard(cardId);
      } else if (type == 'reorderCards') {
        _applyReorder((data['cardIds'] as List<dynamic>? ?? <dynamic>[])
            .map((value) => value as String)
            .toList());
      }
    } catch (_) {
      sender.sink.add(jsonEncode({
        'type': 'error',
        'message': 'invalid websocket payload',
      }));
    }
  }

  Response _jsonResponse(Object data, {int statusCode = 200}) {
    return Response(
      statusCode,
      body: jsonEncode(data),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<Response> _handleIndex(Request request) async {
    return Response.ok(
      _generateHtmlPage(),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<Response> _handleGetCards(Request request) async {
    return _jsonResponse(_buildSnapshot());
  }

  Future<Response> _handleCreateCard(Request request) async {
    final body = await request.readAsString();
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final attachmentsJson =
        payload['attachments'] as List<dynamic>? ?? <dynamic>[];
    final card = await _createCard(
      text: payload['text'] as String? ?? '',
      attachments: attachmentsJson
          .map((item) => _IncomingAttachmentPayload.fromJson(
                item as Map<String, dynamic>,
              ))
          .toList(),
    );
    return _jsonResponse({
      'ok': true,
      'cardId': card.id,
    });
  }

  Future<Response> _handleDeleteCard(Request request, String cardId) async {
    final card = _findCard(cardId);
    if (card != null) {
      await _deleteCard(card.id);
    }
    return _jsonResponse({'ok': true});
  }

  Future<Response> _handleReorderCards(Request request) async {
    final body = await request.readAsString();
    final payload = jsonDecode(body) as Map<String, dynamic>;
    _applyReorder((payload['cardIds'] as List<dynamic>? ?? <dynamic>[])
        .map((value) => value as String)
        .toList());
    return _jsonResponse({'ok': true});
  }

  Future<Response> _handleAddAttachments(Request request, String cardId) async {
    final body = await request.readAsString();
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final files = payload['attachments'] as List<dynamic>? ?? <dynamic>[];
    for (final item in files) {
      final incoming =
          _IncomingAttachmentPayload.fromJson(item as Map<String, dynamic>);
      await _createAttachment(
        cardId: cardId,
        fileName: incoming.name,
        bytes: incoming.bytes,
        mimeType: incoming.mimeType,
      );
    }
    return _jsonResponse({'ok': true});
  }

  Future<Response> _handleGetFile(Request request, String attachmentId) async {
    final attachment = _attachments[attachmentId];
    if (attachment == null) {
      return Response.notFound('Attachment not found');
    }
    final file = File(attachment.localPath);
    if (!await file.exists()) {
      return Response.notFound('File missing');
    }
    final isPreview = request.url.queryParameters['view'] == '1';
    final bytes = await file.readAsBytes();
    return Response.ok(
      bytes,
      headers: {
        'content-type': attachment.mimeType,
        'content-length': bytes.length.toString(),
        'cache-control': 'no-cache',
        'content-disposition': _buildContentDisposition(
          attachment.name,
          inline: isPreview,
        ),
      },
    );
  }

  void _applyReorder(List<String> cardIds) {
    if (cardIds.isEmpty) {
      return;
    }
    final order = <CardItem>[];
    final seen = <String>{};
    for (final cardId in cardIds) {
      final card = _findCard(cardId);
      if (card != null) {
        order.add(card);
        seen.add(cardId);
      }
    }
    for (final card in _cards) {
      if (!seen.contains(card.id)) {
        order.add(card);
      }
    }
    _cards
      ..clear()
      ..addAll(order);
    _schedulePersist();
    _broadcastSnapshot();
  }

  String _generateId(String prefix) {
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
  }

  String _buildStoredFileName(String fileName, String attachmentId) {
    return '$attachmentId-${Uri.encodeComponent(fileName)}';
  }

  String _asciiFallbackFileName(String fileName) {
    return fileName
        .replaceAll(RegExp(r'[\r\n"]'), '_')
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '_');
  }

  String _buildContentDisposition(String fileName, {required bool inline}) {
    final disposition = inline ? 'inline' : 'attachment';
    final fallback = _asciiFallbackFileName(fileName);
    final encoded = Uri.encodeComponent(fileName);
    return "$disposition; filename=\"$fallback\"; filename*=UTF-8''$encoded";
  }

  String _guessMimeType(String fileName) {
    final extension =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    const mimeTypes = <String, String>{
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      'avi': 'video/x-msvideo',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'zip': 'application/zip',
      'rar': 'application/vnd.rar',
      '7z': 'application/x-7z-compressed',
    };
    return mimeTypes[extension] ?? 'application/octet-stream';
  }

  String _extensionForMimeType(String mimeType) {
    switch (mimeType) {
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/heic':
        return 'heic';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/wav':
        return 'wav';
      case 'audio/mp4':
        return 'm4a';
      case 'audio/aac':
        return 'aac';
      case 'video/mp4':
        return 'mp4';
      case 'video/quicktime':
        return 'mov';
      case 'video/x-matroska':
        return 'mkv';
      case 'video/x-msvideo':
        return 'avi';
      case 'application/pdf':
        return 'pdf';
      case 'text/plain':
        return 'txt';
      default:
        return 'bin';
    }
  }

  AttachmentKind _kindFromMimeType(String mimeType, String fileName) {
    if (mimeType.startsWith('image/')) {
      return AttachmentKind.image;
    }
    if (mimeType.startsWith('audio/')) {
      return AttachmentKind.audio;
    }
    if (mimeType.startsWith('video/')) {
      return AttachmentKind.video;
    }
    if (mimeType == 'application/zip' ||
        mimeType == 'application/vnd.rar' ||
        mimeType == 'application/x-7z-compressed') {
      return AttachmentKind.archive;
    }
    final extension =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    const docExtensions = <String>{
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'txt',
      'md',
    };
    if (docExtensions.contains(extension)) {
      return AttachmentKind.document;
    }
    return AttachmentKind.other;
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  IconData _iconForAttachment(CardAttachment attachment) {
    switch (attachment.kind) {
      case AttachmentKind.image:
        return Icons.image_outlined;
      case AttachmentKind.audio:
        return Icons.audiotrack_outlined;
      case AttachmentKind.video:
        return Icons.videocam_outlined;
      case AttachmentKind.document:
        return Icons.description_outlined;
      case AttachmentKind.archive:
        return Icons.archive_outlined;
      case AttachmentKind.other:
        return Icons.attach_file_outlined;
    }
  }

  String _attachmentLabel(CardAttachment attachment) {
    return '${attachment.name} · ${_formatBytes(attachment.size)}';
  }

  Widget _buildImageAttachmentPreview(CardAttachment attachment) {
    return GestureDetector(
      onTap: () => _showImagePreview(attachment),
      child: Hero(
        tag: 'attachment-preview-${attachment.id}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: Image.file(
              File(attachment.localPath),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return _buildImagePreviewFallback();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImagePreviewFallback({bool compact = true}) {
    return Container(
      color: const Color(0xFFF2F4F8),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: compact ? 28 : 56,
            color: const Color(0xFF8A93A5),
          ),
          SizedBox(height: compact ? 8 : 12),
          Text(
            '图片加载失败',
            style: TextStyle(
              color: const Color(0xFF6C7485),
              fontSize: compact ? 12 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _generateHtmlPage() {
    final host = _publicHost;
    final port = _server?.port ?? 0;
    final wsUrl = 'ws://$host:$port/ws';
    return '''
<!DOCTYPE html>
<html class="light" lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta content="width=device-width, initial-scale=1.0" name="viewport"/>
<title>本地分享 - 快速制卡</title>
<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:wght,FILL@100..700,0..1&amp;display=swap" rel="stylesheet"/>
<link href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;700;800&amp;family=Inter:wght@400;500;600;700&amp;display=swap" rel="stylesheet"/>
<style>
:root {
  --primary: #1353d8;
  --primary-dark: #002e88;
  --secondary-container: #d0e1fb;
  --background: #f7f9fb;
  --surface: #ffffff;
  --surface-2: #f2f4f6;
  --text: #191c1e;
  --muted: #667085;
  --outline: #d8dee8;
  --error: #ba1a1a;
  --shadow: 0 18px 44px rgba(19,83,216,.09);
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: Inter, sans-serif;
  background: radial-gradient(circle at top left, rgba(19,83,216,.08), transparent 28%), var(--background);
  color: var(--text);
}
a { color: inherit; }
button, textarea, input { font: inherit; }
button { cursor: pointer; }
.shell { max-width: 1080px; margin: 0 auto; padding: 24px 18px 120px; }
.header {
  position: sticky; top: 0; z-index: 50; backdrop-filter: blur(18px);
  background: rgba(247,249,251,.82); border-bottom: 1px solid rgba(216,222,232,.7);
}
.header-inner { max-width: 1080px; margin: 0 auto; padding: 14px 18px; display:flex; align-items:center; justify-content:space-between; gap:12px; }
.brand { display:flex; align-items:center; gap:10px; color: var(--primary-dark); font-weight:800; font-family: Manrope, sans-serif; font-size: 20px; }
.hero h1 { margin: 0; font-family: Manrope, sans-serif; font-size: clamp(34px, 5vw, 48px); line-height: 1.02; color: var(--primary-dark); }
.hero p { margin: 10px 0 0; max-width: 420px; color: var(--muted); line-height: 1.6; }
.panel { background: rgba(255,255,255,.86); border: 1px solid rgba(216,222,232,.84); border-radius: 28px; box-shadow: var(--shadow); }
.address-panel { margin-top: 22px; padding: 18px 20px; }
.address-label { font-size: 11px; font-weight: 800; letter-spacing: .24em; color: rgba(19,83,216,.5); text-transform: uppercase; font-family: Manrope, sans-serif; }
.address-code { display:block; margin-top: 8px; font-size: clamp(22px, 4vw, 34px); font-weight: 800; color: var(--primary-dark); text-decoration: none; word-break: break-all; }
.address-hint { margin-top: 8px; display:flex; align-items:center; justify-content:space-between; gap:10px; color: var(--muted); font-size: 13px; }
.composer { margin-top: 20px; padding: 12px; }
.composer textarea {
  width: 100%; min-height: 210px; padding: 24px; border: 0; resize: vertical; background: transparent; color: var(--text); outline: none;
}
.composer-toolbar { border-top: 1px solid rgba(216,222,232,.7); padding: 14px; display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
.btn { border: 0; border-radius: 999px; padding: 12px 18px; transition: transform .15s ease, opacity .15s ease, background .15s ease; }
.btn:active { transform: scale(.98); }
.btn-primary { background: linear-gradient(90deg, var(--primary-dark), var(--primary)); color: white; font-weight: 800; box-shadow: 0 18px 34px rgba(19,83,216,.24); }
.btn-soft { background: rgba(208,225,251,.62); color: #385171; font-weight: 700; }
.btn-ghost { background: var(--surface-2); color: var(--muted); font-weight: 700; }
.btn-danger { background: rgba(186,26,26,.08); color: var(--error); font-weight: 700; }
.chips { display:flex; flex-wrap:wrap; gap:8px; margin-top: 12px; }
.chip { padding: 8px 12px; border-radius: 999px; background: var(--surface-2); color: #435067; font-size: 13px; }
.grid { display:grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; margin-top: 18px; }
.control { padding: 20px; display:flex; flex-direction:column; gap:12px; }
.control .icon { width: 48px; height: 48px; border-radius: 999px; display:grid; place-items:center; background: rgba(19,83,216,.08); color: var(--primary); }
.control.danger .icon { background: rgba(186,26,26,.08); color: var(--error); }
.section-head { margin: 24px 0 12px; display:flex; align-items:flex-end; justify-content:space-between; gap:12px; }
.section-title { font-family: Manrope, sans-serif; font-size: 22px; font-weight: 800; color: var(--primary-dark); }
.section-subtitle { color: var(--muted); font-size: 14px; }
.search-row { display:flex; gap:12px; flex-wrap:wrap; }
.search-row input { flex: 1 1 280px; border: 1px solid var(--outline); background:white; border-radius: 18px; padding: 14px 16px; }
.cards { display:grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
.card { padding: 18px; }
.card-top { display:flex; justify-content:space-between; gap:12px; color: var(--muted); font-size: 12px; }
.card-text { margin-top: 14px; white-space: pre-wrap; word-break: break-word; line-height: 1.7; font-size: 15px; }
.attachment-list { display:grid; gap: 10px; margin-top: 14px; }
.attachment { border: 1px solid var(--outline); background: #fbfcff; border-radius: 18px; padding: 12px; }
.attachment-row { display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; }
.attachment-actions { display:flex; gap:10px; flex-wrap:wrap; }
.action-link {
  display:inline-flex; align-items:center; justify-content:center;
  min-width:72px; padding: 9px 14px; border-radius: 999px;
  background: rgba(19,83,216,.08); color: var(--primary-dark);
  text-decoration:none; font-weight:800; font-size: 13px;
}
.preview { width: 100%; margin-top: 10px; border-radius: 14px; border: 1px solid rgba(216,222,232,.8); background: white; max-height: 320px; object-fit: cover; }
.card-actions { display:flex; align-items:center; gap:10px; margin-top: 14px; }
.card-actions .btn { flex: 1 1 0; min-width: 0; }
.empty { padding: 32px; text-align:center; color: var(--muted); border: 1px dashed var(--outline); border-radius: 28px; background: rgba(255,255,255,.72); }
.toast { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%) translateY(20px); opacity: 0; background: rgba(25,28,30,.92); color:white; padding: 12px 16px; border-radius: 14px; transition: all .22s ease; z-index: 120; pointer-events: none; }
.toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
.status-dot { width: 10px; height: 10px; border-radius:999px; background:#98a2b3; display:inline-block; }
.status-dot.connected { background:#12b76a; }
@media (max-width: 720px) {
  .shell { padding-top: 18px; }
  .grid { grid-template-columns: 1fr; }
  .cards { grid-template-columns: 1fr; }
  .address-hint { align-items:flex-start; flex-direction:column; }
}
</style>
</head>
<body>
<header class="header">
  <div class="header-inner">
    <div class="brand"><span class="material-symbols-outlined">share</span><span>本地分享</span></div>
    <div style="display:flex;align-items:center;gap:8px;color:#667085;font-size:14px;"><span id="statusDot" class="status-dot"></span><span id="statusText">连接中</span></div>
  </div>
</header>
<main class="shell">
  <section class="hero">
    <h1>快速制卡</h1>
    <p>支持直接输入文本、剪贴板获取或上传文件，一键生成统一风格的分享卡片，手机和电脑端显示保持一致。</p>
  </section>

  <section class="panel address-panel" id="copyAddressBtn" role="button" tabindex="0">
    <div class="address-label">访问地址</div>
    <code class="address-code" id="addressText"></code>
    <div class="address-hint">
      <span>点击复制当前真实访问地址，端口模式由设置页控制。</span>
      <span style="display:flex;align-items:center;gap:6px;color:rgba(19,83,216,.65);"><span class="material-symbols-outlined" style="font-size:18px;">content_copy</span>点击可复制</span>
    </div>
  </section>

  <section class="panel composer">
    <textarea id="composerInput" placeholder="写一句灵感、贴一段内容，或先选择附件再制卡"></textarea>
    <div id="pickedFiles" class="chips"></div>
    <div class="composer-toolbar">
      <button id="pickFilesBtn" class="btn btn-soft">选择文件</button>
      <button id="pasteBtn" class="btn btn-ghost">粘贴文字</button>
      <button id="clearBtn" class="btn btn-ghost">清空</button>
      <div style="flex:1"></div>
      <button id="createBtn" class="btn btn-primary">制卡</button>
      <input id="fileInput" type="file" multiple hidden>
    </div>
  </section>

  <section class="grid">
    <div class="panel control" id="startBtn">
      <div class="icon"><span class="material-symbols-outlined">play_arrow</span></div>
      <div>
        <div style="font-weight:800;">启动服务</div>
        <div style="margin-top:4px;color:#667085;font-size:12px;">端口模式可配置 · 后台同步已就绪</div>
      </div>
    </div>
    <div class="panel control danger" id="stopBtn">
      <div class="icon"><span class="material-symbols-outlined">stop</span></div>
      <div>
        <div style="font-weight:800;">停止服务</div>
        <div style="margin-top:4px;color:#667085;font-size:12px;">停止后网页访问会中断</div>
      </div>
    </div>
  </section>

  <section class="section-head">
    <div>
      <div class="section-title">卡片列表</div>
      <div class="section-subtitle" id="countText">0 张卡片</div>
    </div>
    <div class="search-row">
      <input id="searchInput" placeholder="搜索卡片内容或附件文件名">
      <button id="refreshBtn" class="btn btn-ghost">刷新</button>
    </div>
  </section>

  <section id="cardsRoot" class="cards"></section>
</main>
<div id="toast" class="toast"></div>
<script>
const wsUrl = ${jsonEncode(wsUrl)};
const initialAddress = ${jsonEncode(_serverAddress)};
const cardsRoot = document.getElementById('cardsRoot');
const searchInput = document.getElementById('searchInput');
const composerInput = document.getElementById('composerInput');
const fileInput = document.getElementById('fileInput');
const pickedFiles = document.getElementById('pickedFiles');
const countText = document.getElementById('countText');
const statusText = document.getElementById('statusText');
const statusDot = document.getElementById('statusDot');
const addressText = document.getElementById('addressText');
const toast = document.getElementById('toast');
let cards = [];
let pendingFiles = [];
let socket;
addressText.textContent = initialAddress;

function showToast(message) {
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove('show'), 1800);
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  return (bytes / 1024 / 1024 / 1024).toFixed(1) + ' GB';
}

function extractStandaloneUrl(text) {
  const value = String(text || '').trim();
  if (!value || /\\s/.test(value)) return null;
  try {
    const url = new URL(value);
    if (url.protocol === 'http:' || url.protocol === 'https:') {
      return url.toString();
    }
  } catch (_) {}
  return null;
}

function renderPickedFiles() {
  if (!pendingFiles.length) {
    pickedFiles.innerHTML = '<span class="chip">未选择附件</span>';
    return;
  }
  pickedFiles.innerHTML = pendingFiles.map(file => '<span class="chip">' + escapeHtml(file.name) + '</span>').join('');
}

function renderCards() {
  const query = searchInput.value.trim().toLowerCase();
  const filtered = cards.filter(card => {
    if (!query) return true;
    if ((card.text || '').toLowerCase().includes(query)) return true;
    return (card.attachments || []).some(file => (file.name || '').toLowerCase().includes(query));
  });

  countText.textContent = filtered.length + ' 张卡片';
  if (!filtered.length) {
    cardsRoot.innerHTML = '<div class="empty">还没有匹配卡片。你可以先写点内容，或上传一个文件后制卡。</div>';
    return;
  }

  cardsRoot.innerHTML = filtered.map(card => {
    const openUrl = extractStandaloneUrl(card.text || '');
    const attachments = (card.attachments || []).map(file => {
      let preview = '';
      if (file.previewable && file.kind === 'image') {
        preview = '<img class="preview" src="' + file.previewUrl + '" alt="' + escapeHtml(file.name) + '">';
      } else if (file.previewable && file.kind === 'audio') {
        preview = '<audio class="preview" controls src="' + file.previewUrl + '"></audio>';
      } else if (file.previewable && file.kind === 'video') {
        preview = '<video class="preview" controls src="' + file.previewUrl + '"></video>';
      } else if (file.previewable && file.mimeType === 'application/pdf') {
        preview = '<iframe class="preview" style="min-height:280px;" src="' + file.previewUrl + '"></iframe>';
      }
      return '<div class="attachment">' +
        '<div class="attachment-row"><strong>' + escapeHtml(file.name) + '</strong><span>' + formatBytes(file.size || 0) + '</span></div>' +
        preview +
        '<div class="attachment-row" style="margin-top:10px;">' +
          '<span style="color:#667085;">' + escapeHtml(file.kind || 'other') + '</span>' +
          '<div class="attachment-actions">' +
            (file.previewable ? '<a class="action-link" href="' + file.previewUrl + '" target="_blank" rel="noopener">预览</a>' : '') +
            '<a class="action-link" href="' + file.downloadUrl + '" download>下载</a>' +
          '</div>' +
        '</div>' +
      '</div>';
    }).join('');

    return '<article class="panel card">' +
      '<div class="card-top"><span>' + (card.pinned ? '置顶' : '') + '</span><span>创建 ' + new Date(card.createdAt).toLocaleString() + '</span></div>' +
      '<div class="card-text">' + escapeHtml(card.text || '无文本内容') + '</div>' +
      (attachments ? '<div class="attachment-list">' + attachments + '</div>' : '') +
      '<div class="card-actions">' +
        (openUrl ? '<button class="btn btn-soft" data-action="open-card" data-card-url="' + escapeHtml(openUrl) + '">打开</button>' : '') +
        '<button class="btn btn-ghost" data-action="copy-card" data-card-id="' + escapeHtml(card.id) + '">复制</button>' +
        '<button class="btn btn-danger" data-action="delete-card" data-card-id="' + escapeHtml(card.id) + '">删除</button>' +
      '</div>' +
    '</article>';
  }).join('');
}

async function refreshCards() {
  const response = await fetch('/api/cards');
  const payload = await response.json();
  cards = payload.cards || [];
  if (payload.address) addressText.textContent = payload.address;
  renderCards();
}

function connectWs() {
  socket = new WebSocket(wsUrl);
  statusText.textContent = '连接中';
  statusDot.className = 'status-dot';
  socket.onopen = () => {
    statusText.textContent = '已连接';
    statusDot.className = 'status-dot connected';
  };
  socket.onclose = () => {
    statusText.textContent = '已断开，正在重连';
    statusDot.className = 'status-dot';
    setTimeout(connectWs, 1200);
  };
  socket.onmessage = event => {
    const payload = JSON.parse(event.data);
    if (payload.type === 'cardsSnapshot') {
      cards = payload.cards || [];
      if (payload.address) addressText.textContent = payload.address;
      renderCards();
    }
  };
}

async function filesToPayload(files) {
  return Promise.all(files.map(file => new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = String(reader.result || '');
      const commaIndex = result.indexOf(',');
      resolve({
        name: file.name,
        mimeType: file.type || 'application/octet-stream',
        base64: commaIndex >= 0 ? result.slice(commaIndex + 1) : result,
      });
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  })));
}

async function createCard() {
  const text = composerInput.value.trim();
  if (!text && pendingFiles.length === 0) return;
  const attachments = await filesToPayload(pendingFiles);
  await fetch('/api/cards', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({text, attachments}),
  });
  composerInput.value = '';
  pendingFiles = [];
  fileInput.value = '';
  renderPickedFiles();
  showToast('卡片已保存');
  await refreshCards();
}

async function deleteCard(cardId) {
  await fetch('/api/cards/' + encodeURIComponent(cardId) + '/delete', {method: 'POST'});
  showToast('卡片已删除');
  await refreshCards();
}

async function copyCard(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    const temp = document.createElement('textarea');
    temp.value = text;
    temp.style.position = 'fixed';
    temp.style.opacity = '0';
    document.body.appendChild(temp);
    temp.focus();
    temp.select();
    document.execCommand('copy');
    temp.remove();
  }
  showToast('已复制到剪贴板');
}

cardsRoot.addEventListener('click', async event => {
  const target = event.target.closest('button[data-action]');
  if (!target) return;
  const cardId = target.dataset.cardId || '';
  const card = cards.find(item => item.id === cardId);
  if (!card) return;
  if (target.dataset.action === 'copy-card') {
    await copyCard(card.text || '');
  } else if (target.dataset.action === 'open-card') {
    const url = target.dataset.cardUrl || '';
    if (!url) return;
    window.open(url, '_blank', 'noopener');
  } else if (target.dataset.action === 'delete-card') {
    await deleteCard(card.id);
  }
});

async function copyAddress() {
  try {
    await navigator.clipboard.writeText(addressText.textContent || '');
    showToast('访问地址已复制');
  } catch (_) {
    showToast('复制失败，请手动复制');
  }
}

async function pasteIntoComposer() {
  try {
    const text = await navigator.clipboard.readText();
    if (!text) {
      showToast('剪贴板里没有可粘贴的文字');
      return;
    }
    composerInput.value = text;
    showToast('已粘贴文字');
  } catch (_) {
    showToast('当前浏览器不支持直接读取剪贴板');
  }
}

document.getElementById('pickFilesBtn').addEventListener('click', () => fileInput.click());
document.getElementById('createBtn').addEventListener('click', createCard);
document.getElementById('refreshBtn').addEventListener('click', refreshCards);
document.getElementById('pasteBtn').addEventListener('click', pasteIntoComposer);
document.getElementById('copyAddressBtn').addEventListener('click', copyAddress);
document.getElementById('copyAddressBtn').addEventListener('keydown', event => {
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault();
    copyAddress();
  }
});
document.getElementById('startBtn').addEventListener('click', () => showToast('服务已在应用内自动启动'));
document.getElementById('stopBtn').addEventListener('click', () => showToast('如需停止服务，请回到应用内操作'));
document.getElementById('clearBtn').addEventListener('click', () => {
  composerInput.value = '';
  pendingFiles = [];
  fileInput.value = '';
  renderPickedFiles();
});
searchInput.addEventListener('input', renderCards);
fileInput.addEventListener('change', event => {
  pendingFiles = Array.from(event.target.files || []);
  renderPickedFiles();
});
renderPickedFiles();
refreshCards();
connectWs();
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final cards = _sortedCards;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        titleSpacing: 18,
        title: const Text(
          '本地分享',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Color(0xFF0D44B3),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, size: 22),
          ),
          IconButton(
            tooltip: '顶部',
            onPressed: _scrollToTop,
            icon: const Icon(Icons.keyboard_double_arrow_up_rounded, size: 22),
          ),
          IconButton(
            tooltip: '底部',
            onPressed: _scrollToBottom,
            icon:
                const Icon(Icons.keyboard_double_arrow_down_rounded, size: 22),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFE),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFF8FAFE), Color(0xFFF1F4FB)],
                      ),
                      boxShadow: const [],
                    ),
                  ),
                ),
                Positioned(
                  top: -80,
                  left: -40,
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0x331353D8),
                          const Color(0x001353D8),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 360,
                  right: -70,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0x1A002E88),
                          const Color(0x00002E88),
                        ],
                      ),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 28),
                      children: [
                        _buildSearchBar(),
                        const SizedBox(height: 16),
                        _buildHero(),
                        const SizedBox(height: 14),
                        _buildAddressPanel(),
                        const SizedBox(height: 14),
                        _buildComposerCard(),
                        const SizedBox(height: 14),
                        _buildServiceControls(),
                        const SizedBox(height: 20),
                        _buildCardsSection(cards),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildHero() {
    return const Padding(
      padding: EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '快速制卡',
            style: TextStyle(
              fontSize: 26,
              height: 1.04,
              fontWeight: FontWeight.w900,
              color: Color(0xFF00359E),
            ),
          ),
          SizedBox(height: 6),
          Text(
            '支持直接输入文本、剪贴板获取或上传文件，一键生成精致分享卡片。',
            style: TextStyle(
              color: Color(0xFF6E7788),
              height: 1.5,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4EAF4)),
      ),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded),
          hintText: '搜索卡片内容或附件文件名',
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          fillColor: Colors.transparent,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    setState(() {
                      _searchController.clear();
                    });
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
        ),
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
        cursorColor: const Color(0xFF1353D8),
        onTapOutside: (_) => FocusScope.of(context).unfocus(),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildAddressPanel() {
    return InkWell(
      borderRadius: BorderRadius.circular(26),
      onTap: _copyServerAddress,
      child: Container(
        decoration: _panelDecoration(radius: 26, shadowOpacity: 0.045),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '访问地址',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.8,
                      color: Color(0x7A1353D8),
                    ),
                  ),
                ),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0x101353D8),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: const Icon(
                    Icons.content_copy_rounded,
                    size: 16,
                    color: Color(0xFF1353D8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              _serverAddress,
              style: const TextStyle(
                fontSize: 16,
                height: 1.28,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1143AB),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isServerRunning
                  ? '点击可复制当前访问地址，端口模式由设置页控制。'
                  : '可在设置页切换随机端口或固定端口。',
              style: TextStyle(
                color: Color(0xFF758094),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposerCard() {
    return Container(
      decoration: _panelDecoration(radius: 28, shadowOpacity: 0.055),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                TextField(
                  controller: _composerController,
                  minLines: 6,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: '写一句灵感、贴一段内容，或先选择附件再制卡',
                    fillColor: Colors.transparent,
                    hintStyle: TextStyle(
                      color: Color(0xFF9AA3B2),
                      height: 1.65,
                    ),
                    contentPadding: EdgeInsets.fromLTRB(12, 12, 50, 36),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: _buildCornerIconButton(
                    icon: Icons.close_rounded,
                    onTap: () {
                      setState(() {
                        _composerController.clear();
                        _pendingAttachments.clear();
                      });
                    },
                  ),
                ),
              ],
            ),
            if (_pendingAttachments.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _pendingAttachments.asMap().entries.map((entry) {
                  final index = entry.key;
                  final attachment = entry.value;
                  return Chip(
                    avatar: const Icon(Icons.attach_file, size: 18),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        attachment.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onDeleted: () {
                      setState(() {
                        _pendingAttachments.removeAt(index);
                      });
                    },
                  );
                }).toList(),
              ),
            ],
            const Divider(height: 18, color: Color(0xFFE8EDF5)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: _buildCapsuleButton(
                    label: _isPickingFiles ? '读取中...' : '选择文件',
                    icon: Icons.attach_file_rounded,
                    onTap: _isPickingFiles ? null : _pickFilesFromDevice,
                    variant: _CapsuleButtonVariant.soft,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildCapsuleButton(
                    label: '粘贴',
                    icon: Icons.content_paste_rounded,
                    onTap: _pasteClipboardToComposer,
                    variant: _CapsuleButtonVariant.ghost,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildPrimaryActionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryActionButton() {
    return FilledButton.icon(
      onPressed: _createCardFromComposer,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF1550D7),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      icon: const Icon(Icons.auto_awesome_rounded, size: 20),
      label: const Text(
        '制卡',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 17,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildServiceControls() {
    return Row(
      children: [
        Expanded(
          child: _buildServiceCard(
            icon: Icons.play_arrow_rounded,
            label: '启动服务',
            subtitle: _useFixedPort ? '固定端口 $_preferredPort' : '随机端口',
            onTap: _isServerRunning ? null : _startServer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildServiceCard(
            icon: Icons.stop_rounded,
            label: '停止服务',
            subtitle: '停止后访问中断',
            onTap: _isServerRunning ? _stopServer : null,
            isDanger: true,
          ),
        ),
      ],
    );
  }

  Widget _buildCardsSection(List<CardItem> cards) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(
              child: Text(
                '卡片列表',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF00359E),
                ),
              ),
            ),
            Text(
              '${cards.length} 张卡片',
              style: const TextStyle(
                color: Color(0xFF7C8699),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (cards.isEmpty)
          Container(
            decoration: _panelDecoration(radius: 24, shadowOpacity: 0.04),
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: const [
                Icon(Icons.blur_on, size: 48, color: Color(0x551353D8)),
                SizedBox(height: 14),
                Text(
                  '还没有卡片。你可以直接输入文本点击“制卡”，或者先选择文件后一起保存。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF6B7381), height: 1.6),
                ),
              ],
            ),
          )
        else
          Column(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                _buildCardTile(cards[i]),
                if (i != cards.length - 1) const SizedBox(height: 14),
              ],
            ],
          ),
      ],
    );
  }

  Widget _buildCardTile(CardItem card) {
    final cardAttachments = card.attachmentIds
        .map((id) => _attachments[id])
        .whereType<CardAttachment>()
        .toList();
    final openUrl = _extractStandaloneUrl(card.text);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onLongPress: () => _togglePinnedCard(card),
        child: Ink(
          decoration: _panelDecoration(radius: 24, shadowOpacity: 0.045),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AnimatedOpacity(
                    opacity: card.isPinned ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(
                      ignoring: !card.isPinned,
                      child: _buildMetaPill(
                        '置顶',
                        foregroundColor: const Color(0xFF0D44B3),
                        backgroundColor: const Color(0xFFEAF1FF),
                      ),
                    ),
                  ),
                  _buildMetaPill('创建 ${_formatDateTime(card.createdAt)}'),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                card.text.isEmpty ? '无文本内容' : card.text,
                style: const TextStyle(
                  color: Color(0xFF1F2430),
                  fontSize: 14.5,
                  height: 1.6,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (cardAttachments.isNotEmpty) ...[
                const SizedBox(height: 14),
                ...cardAttachments.map(
                  (attachment) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F9FD),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E7F1)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (attachment.kind == AttachmentKind.image) ...[
                          _buildImageAttachmentPreview(attachment),
                          const SizedBox(height: 12),
                        ],
                        Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(0x141353D8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _iconForAttachment(attachment),
                                color: const Color(0xFF1353D8),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    attachment.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _attachmentLabel(attachment),
                                    style: const TextStyle(
                                      color: Color(0xFF7A8497),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (attachment.isPreviewable &&
                                attachment.kind != AttachmentKind.image) ...[
                              Expanded(
                                child: _buildCapsuleButton(
                                  label: '预览',
                                  icon: Icons.visibility_outlined,
                                  onTap: () => _openAttachment(
                                    attachment,
                                    preview: true,
                                  ),
                                  variant: _CapsuleButtonVariant.soft,
                                  compact: true,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: _buildCapsuleButton(
                                label: attachment.kind == AttachmentKind.image
                                    ? '原图'
                                    : '下载',
                                icon: Icons.download_rounded,
                                onTap: () => _openAttachment(attachment),
                                variant: _CapsuleButtonVariant.primary,
                                compact: true,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (openUrl != null) ...[
                    Expanded(
                      child: _buildCapsuleButton(
                        label: '打开',
                        icon: Icons.open_in_new_rounded,
                        onTap: () => _openCardUrl(card),
                        variant: _CapsuleButtonVariant.soft,
                        compact: true,
                        stacked: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: _buildCapsuleButton(
                      label: '分享',
                      icon: Icons.ios_share_rounded,
                      onTap: () => _shareCard(card),
                      variant: _CapsuleButtonVariant.soft,
                      compact: true,
                      stacked: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCapsuleButton(
                      label: '复制',
                      icon: Icons.content_copy,
                      onTap: () => _copyCardText(card.text),
                      variant: _CapsuleButtonVariant.ghost,
                      compact: true,
                      stacked: true,
                      fontWeight: FontWeight.w900,
                      foregroundOverride: const Color(0xFF111111),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCapsuleButton(
                      label: '删除',
                      icon: Icons.delete_outline,
                      onTap: () => _deleteCardWithConfirm(card),
                      variant: _CapsuleButtonVariant.danger,
                      compact: true,
                      stacked: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServiceCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback? onTap,
    bool isDanger = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          constraints: const BoxConstraints(minHeight: 142),
          decoration: _panelDecoration(radius: 24, shadowOpacity: 0.04),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDanger
                      ? const Color(0x22BA1A1A)
                      : const Color(0x221353D8),
                  border: Border.all(
                    color: isDanger
                        ? const Color(0x33BA1A1A)
                        : const Color(0x331353D8),
                  ),
                ),
                child: Icon(
                  icon,
                  size: 26,
                  color: isDanger
                      ? const Color(0xFFBA1A1A)
                      : const Color(0xFF1353D8),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF7C8699),
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCapsuleButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    required _CapsuleButtonVariant variant,
    bool compact = false,
    bool stacked = false,
    FontWeight? fontWeight,
    Color? foregroundOverride,
  }) {
    late final Color background;
    Color foreground;
    switch (variant) {
      case _CapsuleButtonVariant.primary:
        background = const Color(0xFF1353D8);
        foreground = Colors.white;
      case _CapsuleButtonVariant.soft:
        background = const Color(0x66D0E1FB);
        foreground = const Color(0xFF385171);
      case _CapsuleButtonVariant.ghost:
        background = const Color(0xFFF2F4F6);
        foreground = const Color(0xFF5A6475);
      case _CapsuleButtonVariant.danger:
        background = const Color(0x14BA1A1A);
        foreground = const Color(0xFFBA1A1A);
    }
    foreground = foregroundOverride ?? foreground;
    final style = FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      elevation: 0,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: stacked ? 10 : (compact ? 9 : 11),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(stacked ? 18 : 999),
      ),
    );
    if (stacked) {
      return FilledButton(
        onPressed: onTap,
        style: style,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: compact ? 18 : 20,
              color: foreground,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: fontWeight ?? FontWeight.w800,
                fontSize: compact ? 11.5 : 13,
                height: 1.1,
              ),
            ),
          ],
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onTap,
      style: style,
      icon: Icon(icon, size: compact ? 18 : 20),
      label: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: fontWeight ?? FontWeight.w800,
          fontSize: compact ? 13 : 15,
        ),
      ),
    );
  }

  Widget _buildCornerIconButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: const Color(0x1A7C8699),
        foregroundColor: const Color(0xB35C6980),
        minimumSize: const Size(28, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      icon: Icon(icon, size: 16),
      tooltip: '清空',
    );
  }

  Widget _buildMetaPill(
    String text, {
    Color backgroundColor = const Color(0xFFF4F7FC),
    Color foregroundColor = const Color(0xFF718097),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: foregroundColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration({
    double radius = 28,
    double shadowOpacity = 0.08,
  }) {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFFE6EBF3)),
      boxShadow: [
        BoxShadow(
          color: Color(0xFF1353D8).withValues(alpha: shadowOpacity),
          blurRadius: 24,
          offset: const Offset(0, 12),
        ),
      ],
    );
  }
}

class LocalShareSettingsPage extends StatefulWidget {
  const LocalShareSettingsPage({
    super.key,
    required this.initialPort,
    required this.initialUseFixedPort,
    required this.initialConfirmDelete,
  });

  final int initialPort;
  final bool initialUseFixedPort;
  final bool initialConfirmDelete;

  @override
  State<LocalShareSettingsPage> createState() => _LocalShareSettingsPageState();
}

class _LocalShareSettingsPageState extends State<LocalShareSettingsPage> {
  late final TextEditingController _portController =
      TextEditingController(text: widget.initialPort.toString());
  late bool _useFixedPort = widget.initialUseFixedPort;
  late bool _confirmDelete = widget.initialConfirmDelete;

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  void _save({bool clearAllCards = false}) {
    if (!_useFixedPort) {
      Navigator.of(context).pop(
        _PortSettingsResult(
          useFixedPort: false,
          port: widget.initialPort,
          confirmDelete: _confirmDelete,
          clearAllCards: clearAllCards,
        ),
      );
      return;
    }
    final value = int.tryParse(_portController.text.trim());
    if (value == null || value < 1 || value > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 1 到 65535 之间的端口')),
      );
      return;
    }
    Navigator.of(context).pop(
      _PortSettingsResult(
        useFixedPort: true,
        port: value,
        confirmDelete: _confirmDelete,
        clearAllCards: clearAllCards,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE6EBF3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '服务端口',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0D44B3),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '关闭时每次随机端口；开启后使用你指定的固定端口。',
                  style: TextStyle(
                    color: Color(0xFF6E7788),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _useFixedPort,
                  title: const Text(
                    '使用固定端口',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('关闭则每次启动随机分配端口'),
                  onChanged: (value) {
                    setState(() {
                      _useFixedPort = value;
                    });
                  },
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _confirmDelete,
                  title: const Text(
                    '删除前弹出确认',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('开启后，删除单张卡片前会先确认'),
                  onChanged: (value) {
                    setState(() {
                      _confirmDelete = value;
                    });
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _portController,
                  enabled: _useFixedPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    hintText: '例如 35773',
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: () => _save(clearAllCards: true),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFBA1A1A),
                    side: const BorderSide(color: Color(0x33BA1A1A)),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text(
                    '清空所有卡片',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () => _save(),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1550D7),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text(
                    '保存',
                    style: TextStyle(fontWeight: FontWeight.w900),
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

class _PortSettingsResult {
  const _PortSettingsResult({
    required this.useFixedPort,
    required this.port,
    required this.confirmDelete,
    this.clearAllCards = false,
  });

  final bool useFixedPort;
  final int port;
  final bool confirmDelete;
  final bool clearAllCards;
}

enum _CapsuleButtonVariant { primary, soft, ghost, danger }

class _IncomingAttachmentPayload {
  _IncomingAttachmentPayload({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final List<int> bytes;

  factory _IncomingAttachmentPayload.fromJson(Map<String, dynamic> json) {
    final base64 = json['base64'] as String? ?? '';
    return _IncomingAttachmentPayload(
      name: json['name'] as String? ?? 'attachment',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      bytes: base64.isEmpty ? <int>[] : base64Decode(base64),
    );
  }
}
