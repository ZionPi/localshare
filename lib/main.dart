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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
    List<String>? attachmentIds,
  }) : attachmentIds = attachmentIds ?? <String>[];

  final String id;
  String text;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<String> attachmentIds;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'attachmentIds': attachmentIds,
    };
  }

  Map<String, dynamic> toPublicJson(Map<String, CardAttachment> attachmentMap) {
    return {
      'id': id,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
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

class _MyHomePageState extends State<MyHomePage> {
  static const MethodChannel _lifecycleChannel =
      MethodChannel('localshare/lifecycle');

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

  String _serverAddress = '服务启动中';
  bool _isServerRunning = false;
  bool _isPickingFiles = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      _storage = await LocalShareStorage.create();
      final state = await _storage!.loadState();
      _cards
        ..clear()
        ..addAll(state.cards);
      _attachments
        ..clear()
        ..addEntries(state.attachments.map((e) => MapEntry(e.id, e)));
      await _setupSharingHandlers();
      await _startServer();
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

  @override
  void dispose() {
    _stopServer();
    _composerController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _saveDebounceTimer?.cancel();
    _broadcastDebounceTimer?.cancel();
    _intentDataStreamSubscription?.cancel();
    super.dispose();
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

    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  Future<void> _persistStateNow() async {
    if (_storage == null) {
      return;
    }
    await _storage!.saveState(_cards, _attachments.values);
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
    final safeName = _sanitizeFileName(fileName ?? 'attachment');
    final attachmentId = _generateId('file');
    final targetPath = '${storage.attachmentsDir.path}/$attachmentId-$safeName';
    final file = File(targetPath);
    await file.writeAsBytes(bytes, flush: true);

    final attachment = CardAttachment(
      id: attachmentId,
      cardId: cardId,
      name: safeName,
      mimeType: mimeType,
      size: bytes.length,
      localPath: targetPath,
      kind: _kindFromMimeType(mimeType, safeName),
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

  Future<void> _copyCardText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showToast(text.trim().isEmpty ? '空卡片已复制' : '卡片内容已复制');
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

  Future<void> _pasteTextToComposer() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) {
      _showToast('剪贴板里没有可粘贴的文字');
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
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToBottom() async {
    if (!_scrollController.hasClients) {
      return;
    }
    await _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _startServer() async {
    if (_isServerRunning) {
      return;
    }

    try {
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

      _server = await shelf_io.serve(handler, ipAddress, 0, shared: true);
      if (mounted) {
        setState(() {
          _serverAddress = 'http://${_server!.address.host}:${_server!.port}';
          _isServerRunning = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _serverAddress = '服务器启动失败: $error';
        });
      }
    }
  }

  void _stopServer() {
    if (!_isServerRunning) {
      return;
    }
    for (final client in _webSocketClients) {
      client.sink.close();
    }
    _webSocketClients.clear();
    _server?.close();
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
    final cards = _cards.map((card) => card.toPublicJson(_attachments)).toList()
      ..sort((a, b) => DateTime.parse(b['updatedAt'] as String)
          .compareTo(DateTime.parse(a['updatedAt'] as String)));
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
    await _deleteCard(cardId);
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
        'content-disposition': isPreview
            ? 'inline; filename="${Uri.encodeComponent(attachment.name)}"'
            : 'attachment; filename="${Uri.encodeComponent(attachment.name)}"',
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

  String _sanitizeFileName(String input) {
    return input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
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

  String _generateHtmlPage() {
    final host = _server?.address.host ?? '127.0.0.1';
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
.preview { width: 100%; margin-top: 10px; border-radius: 14px; border: 1px solid rgba(216,222,232,.8); background: white; max-height: 320px; object-fit: cover; }
.card-actions { display:flex; gap:10px; flex-wrap:wrap; margin-top: 14px; }
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
      <span>点击复制当前真实访问地址，端口为自动分配。</span>
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
        <div style="margin-top:4px;color:#667085;font-size:12px;">随机端口 · 后台同步已就绪</div>
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
          '<div style="display:flex;gap:10px;flex-wrap:wrap;">' +
            (file.previewable ? '<a href="' + file.previewUrl + '" target="_blank" rel="noopener">预览</a>' : '') +
            '<a href="' + file.downloadUrl + '" download>下载</a>' +
          '</div>' +
        '</div>' +
      '</div>';
    }).join('');

    return '<article class="panel card">' +
      '<div class="card-top"><span>创建 ' + new Date(card.createdAt).toLocaleString() + '</span><span>更新 ' + new Date(card.updatedAt).toLocaleString() + '</span></div>' +
      '<div class="card-text">' + escapeHtml(card.text || '无文本内容') + '</div>' +
      (attachments ? '<div class="attachment-list">' + attachments + '</div>' : '') +
      '<div class="card-actions">' +
        '<button class="btn btn-ghost" onclick="copyCard(' + JSON.stringify(card.text || '') + ')">复制</button>' +
        '<button class="btn btn-danger" onclick="deleteCard(' + JSON.stringify(card.id) + ')">删除</button>' +
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
      appBar: AppBar(title: Text(widget.title)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFF7F9FB), Color(0xFFF1F4F9)],
                      ),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                      children: [
                        _buildHero(),
                        const SizedBox(height: 18),
                        _buildAddressPanel(),
                        const SizedBox(height: 18),
                        _buildComposerCard(),
                        const SizedBox(height: 18),
                        _buildServiceControls(),
                        const SizedBox(height: 24),
                        _buildCardsSection(cards),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 20,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'scroll-top',
                        onPressed: _scrollToTop,
                        child: const Icon(Icons.vertical_align_top),
                      ),
                      const SizedBox(height: 12),
                      FloatingActionButton.small(
                        heroTag: 'scroll-bottom',
                        onPressed: _scrollToBottom,
                        child: const Icon(Icons.vertical_align_bottom),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildHero() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '快速制卡',
            style: TextStyle(
              fontSize: 40,
              height: 1.0,
              fontWeight: FontWeight.w900,
              color: Color(0xFF002E88),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '支持直接输入文本、剪贴板获取或上传文件，一键生成统一风格的分享卡片。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF5F6778),
                  height: 1.6,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressPanel() {
    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: _copyServerAddress,
      child: Container(
        decoration: _panelDecoration(),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '访问地址',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 3.2,
                color: Color(0x801353D8),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              _serverAddress,
              style: const TextStyle(
                fontSize: 28,
                height: 1.2,
                fontWeight: FontWeight.w900,
                color: Color(0xFF002E88),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: const [
                Icon(Icons.content_copy, size: 16, color: Color(0x801353D8)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '点击可复制当前真实访问地址，端口自动分配。',
                    style: TextStyle(
                      color: Color(0xFF6B7381),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposerCard() {
    return Container(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _composerController,
              minLines: 8,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: '写一句灵感、贴一段内容，或先选择附件再制卡',
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
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
            const Divider(height: 18, color: Color(0xFFE7EBF0)),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              children: [
                _buildCapsuleButton(
                  label: _isPickingFiles ? '读取中...' : '选择文件',
                  icon: Icons.attach_file,
                  onTap: _isPickingFiles ? null : _pickFilesFromDevice,
                  variant: _CapsuleButtonVariant.soft,
                ),
                _buildCapsuleButton(
                  label: '粘贴文字',
                  icon: Icons.content_paste,
                  onTap: _pasteTextToComposer,
                  variant: _CapsuleButtonVariant.ghost,
                ),
                _buildCapsuleButton(
                  label: '清空',
                  icon: Icons.delete_outline,
                  onTap: () {
                    setState(() {
                      _composerController.clear();
                      _pendingAttachments.clear();
                    });
                  },
                  variant: _CapsuleButtonVariant.ghost,
                ),
                _buildCapsuleButton(
                  label: '制卡',
                  icon: Icons.auto_awesome,
                  onTap: _createCardFromComposer,
                  variant: _CapsuleButtonVariant.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceControls() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final singleColumn = constraints.maxWidth < 620;
        final items = [
          _buildServiceCard(
            icon: Icons.play_arrow,
            label: '启动服务',
            subtitle: '随机端口 · 后台同步已就绪',
            onTap: _isServerRunning ? null : _startServer,
          ),
          _buildServiceCard(
            icon: Icons.stop,
            label: '停止服务',
            subtitle: '停止后网页访问会中断',
            onTap: _isServerRunning ? _stopServer : null,
            isDanger: true,
          ),
        ];
        if (singleColumn) {
          return Column(children: [
            for (final item in items) ...[item, const SizedBox(height: 12)]
          ]);
        }
        return Row(
          children: [
            Expanded(child: items[0]),
            const SizedBox(width: 12),
            Expanded(child: items[1]),
          ],
        );
      },
    );
  }

  Widget _buildCardsSection(List<CardItem> cards) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '卡片列表',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF002E88),
                ),
              ),
            ),
            Text(
              '${cards.length} 张卡片',
              style: const TextStyle(color: Color(0xFF6B7381)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: '搜索卡片内容或附件文件名',
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      setState(() {
                        _searchController.clear();
                      });
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        if (cards.isEmpty)
          Container(
            decoration: _panelDecoration(),
            width: double.infinity,
            padding: const EdgeInsets.all(28),
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
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 860
                  ? 3
                  : constraints.maxWidth > 560
                      ? 2
                      : 1;
              return GridView.builder(
                itemCount: cards.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  mainAxisExtent: 340,
                ),
                itemBuilder: (context, index) => _buildCardTile(cards[index]),
              );
            },
          ),
      ],
    );
  }

  Widget _buildCardTile(CardItem card) {
    final cardAttachments = card.attachmentIds
        .map((id) => _attachments[id])
        .whereType<CardAttachment>()
        .toList();

    return Container(
      decoration: _panelDecoration(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '创建 ${_formatDateTime(card.createdAt)}',
                  style: const TextStyle(
                    color: Color(0xFF6B7381),
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                '更新 ${_formatDateTime(card.updatedAt)}',
                style: const TextStyle(
                  color: Color(0xFF6B7381),
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.text.isEmpty ? '无文本内容' : card.text,
                    style: const TextStyle(
                      color: Color(0xFF191C1E),
                      fontSize: 15,
                      height: 1.65,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (cardAttachments.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    ...cardAttachments.map(
                      (attachment) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F7FB),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE0E3E5)),
                        ),
                        child: Row(
                          children: [
                            Icon(_iconForAttachment(attachment),
                                color: const Color(0xFF1353D8)),
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
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _attachmentLabel(attachment),
                                    style: const TextStyle(
                                      color: Color(0xFF6B7381),
                                      fontSize: 12,
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildCapsuleButton(
                label: '复制',
                icon: Icons.content_copy,
                onTap: () => _copyCardText(card.text),
                variant: _CapsuleButtonVariant.ghost,
                compact: true,
              ),
              _buildCapsuleButton(
                label: '删除',
                icon: Icons.delete_outline,
                onTap: () => _deleteCard(card.id),
                variant: _CapsuleButtonVariant.danger,
                compact: true,
              ),
            ],
          ),
        ],
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
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          decoration: _panelDecoration(),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDanger
                      ? const Color(0x14BA1A1A)
                      : const Color(0x141353D8),
                ),
                child: Icon(
                  icon,
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
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFF6B7381)),
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
  }) {
    late final Color background;
    late final Color foreground;
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
    return FilledButton.icon(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 10 : 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      icon: Icon(icon, size: compact ? 18 : 20),
      label: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: compact ? 13 : 15,
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFE0E3E5)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x141353D8),
          blurRadius: 32,
          offset: Offset(0, 16),
        ),
      ],
    );
  }
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
