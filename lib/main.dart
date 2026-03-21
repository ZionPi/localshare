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
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '本地分享',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF274E8F),
          primary: const Color(0xFF274E8F),
          secondary: const Color(0xFFFFD166),
          surface: const Color(0xFFF8F5EC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F1E8),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F1E8),
          foregroundColor: Color(0xFF18212F),
          centerTitle: false,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Color(0xFF18212F),
            fontSize: 28,
            fontWeight: FontWeight.w800,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFFD8E4FF),
          foregroundColor: Color(0xFF18345F),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0xFFFFF6DA),
          selectedColor: const Color(0xFFFFE08A),
          deleteIconColor: const Color(0xFF5C6577),
          side: const BorderSide(color: Color(0xFFE3D7A6)),
          labelStyle: const TextStyle(
            color: Color(0xFF18212F),
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD5D0C6)),
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

  String get extension {
    final index = name.lastIndexOf('.');
    return index == -1 ? '' : name.substring(index + 1).toLowerCase();
  }

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

class _MyHomePageState extends State<MyHomePage> {
  static const String _legacyDocumentKey = 'document_content';
  static const String _appStateKey = 'cards_state_v1';

  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<WebSocketChannel> _webSocketClients = <WebSocketChannel>[];
  final Random _random = Random();

  HttpServer? _server;
  StreamSubscription? _intentDataStreamSubscription;
  Timer? _saveDebounceTimer;
  Timer? _broadcastDebounceTimer;

  final List<CardItem> _cards = <CardItem>[];
  final Map<String, CardAttachment> _attachments = <String, CardAttachment>{};
  final List<_IncomingAttachmentPayload> _pendingAttachments =
      <_IncomingAttachmentPayload>[];

  String _serverAddress = '服务器未启动';
  bool _isServerRunning = false;
  bool _isPickingFiles = false;
  Directory? _storageDirectory;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _ensureStorageDirectory();
    await _loadAppState();
    await _setupSharingHandlers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isServerRunning) {
        _startServer();
      }
    });
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

  Future<void> _ensureStorageDirectory() async {
    if (_storageDirectory != null) {
      return;
    }
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      _storageDirectory = Directory('${docsDir.path}/localshare_attachments');
    } catch (_) {
      _storageDirectory =
          Directory('${Directory.systemTemp.path}/localshare_attachments');
    }
    if (!await _storageDirectory!.exists()) {
      await _storageDirectory!.create(recursive: true);
    }
  }

  Future<void> _loadAppState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedState = prefs.getString(_appStateKey);
      if (savedState != null && savedState.isNotEmpty) {
        final decoded = jsonDecode(savedState) as Map<String, dynamic>;
        final cardsJson = decoded['cards'] as List<dynamic>? ?? <dynamic>[];
        final attachmentsJson =
            decoded['attachments'] as List<dynamic>? ?? <dynamic>[];
        _cards
          ..clear()
          ..addAll(cardsJson
              .map((item) => CardItem.fromJson(item as Map<String, dynamic>)));
        _attachments
          ..clear()
          ..addEntries(attachmentsJson
              .map((item) =>
                  CardAttachment.fromJson(item as Map<String, dynamic>))
              .map((attachment) => MapEntry(attachment.id, attachment)));
      } else {
        final legacyContent = prefs.getString(_legacyDocumentKey) ?? '';
        if (legacyContent.trim().isNotEmpty) {
          final now = DateTime.now();
          _cards.add(
            CardItem(
              id: _generateId('card'),
              text: legacyContent,
              createdAt: now,
              updatedAt: now,
            ),
          );
          await prefs.remove(_legacyDocumentKey);
          await _persistState();
        }
      }

      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    final state = jsonEncode({
      'cards': _cards.map((card) => card.toJson()).toList(),
      'attachments':
          _attachments.values.map((attachment) => attachment.toJson()).toList(),
    });
    await prefs.setString(_appStateKey, state);
  }

  void _schedulePersist() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      _persistState();
    });
  }

  Future<void> _setupSharingHandlers() async {
    try {
      _intentDataStreamSubscription = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen(_consumeSharedItems, onError: (Object error) {});
      final initialItems =
          await ReceiveSharingIntent.instance.getInitialMedia();
      if (initialItems.isNotEmpty) {
        await _consumeSharedItems(initialItems);
        await ReceiveSharingIntent.instance.reset();
      }
    } catch (_) {
      // Ignore plugin failures in tests or unsupported platforms.
    }
  }

  Future<void> _consumeSharedItems(List<SharedMediaFile> files) async {
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
        ? '收到文件: ${filePayloads.first.name}'
        : '收到 ${filePayloads.length} 个文件';

    await _createCard(
      text: textContent.isNotEmpty ? textContent : fallbackText,
      attachments: filePayloads,
    );
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

    _schedulePersist();
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
    await _ensureStorageDirectory();
    final safeName = _sanitizeFileName(fileName ?? 'attachment');
    final attachmentId = _generateId('file');
    final targetPath = '${_storageDirectory!.path}/$attachmentId-$safeName';
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

    _schedulePersist();
    if (notify) {
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
    _schedulePersist();
    _broadcastSnapshot();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _copyCardText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('卡片内容已复制')),
      );
    }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板里没有可粘贴的文字')),
        );
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $error')),
        );
      }
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

      _server = await shelf_io.serve(handler, ipAddress, 8080, shared: true);
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
      return ip ?? '127.0.0.1';
    } catch (_) {
      return '127.0.0.1';
    }
  }

  Map<String, dynamic> _buildSnapshot() {
    final cards = _cards.map((card) => card.toPublicJson(_attachments)).toList()
      ..sort((a, b) => DateTime.parse(b['updatedAt'] as String)
          .compareTo(DateTime.parse(a['updatedAt'] as String)));
    return {
      'type': 'cardsSnapshot',
      'cards': cards,
      'serverTime': DateTime.now().toIso8601String(),
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
    final bytes = await file.readAsBytes();
    return Response.ok(
      bytes,
      headers: {
        'content-type': attachment.mimeType,
        'content-length': bytes.length.toString(),
        'content-disposition':
            'inline; filename="${Uri.encodeComponent(attachment.name)}"',
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
    final wsUrl =
        'ws://${_server?.address.host ?? '127.0.0.1'}:${_server?.port ?? 8080}/ws';
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>本地提效工具</title>
  <style>
    :root {
      --bg: #f5f3ea;
      --panel: rgba(255,255,255,0.88);
      --line: rgba(18,39,64,0.12);
      --text: #14263f;
      --muted: #607088;
      --accent: #0f6c5a;
      --accent-soft: #d7f0e5;
      --shadow: 0 18px 40px rgba(16,31,51,0.12);
      --danger: #9c2f2f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "PingFang SC", "Noto Sans SC", sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top right, rgba(15,108,90,0.14), transparent 28%),
        linear-gradient(180deg, #f9f7f1 0%, var(--bg) 100%);
    }
    .shell {
      max-width: 1120px;
      margin: 0 auto;
      padding: 18px 16px 120px;
    }
    .hero, .composer, .card {
      background: var(--panel);
      border: 1px solid var(--line);
      box-shadow: var(--shadow);
      backdrop-filter: blur(12px);
      border-radius: 24px;
    }
    .hero {
      padding: 18px;
      margin-bottom: 16px;
      display: grid;
      gap: 12px;
    }
    .hero-top {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .hero h1 {
      font-size: 28px;
      margin: 0;
      letter-spacing: -0.03em;
    }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      font-size: 14px;
    }
    .dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: #c28c27;
    }
    .dot.connected { background: #0f6c5a; }
    .hero-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.5fr) minmax(240px, 0.9fr);
      gap: 12px;
    }
    .hero-grid input, .composer textarea, .composer input {
      width: 100%;
      border: 1px solid rgba(20,38,63,0.14);
      border-radius: 16px;
      padding: 14px;
      font: inherit;
      background: rgba(255,255,255,0.85);
      color: var(--text);
    }
    .composer {
      padding: 18px;
      margin-bottom: 18px;
    }
    .composer-actions, .toolbar {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    button {
      border: 0;
      border-radius: 999px;
      padding: 10px 16px;
      cursor: pointer;
      font: inherit;
      color: white;
      background: var(--text);
    }
    button.secondary {
      background: white;
      color: var(--text);
      border: 1px solid var(--line);
    }
    button.accent {
      background: var(--accent);
    }
    button.danger {
      background: var(--danger);
    }
    .toolbar {
      justify-content: space-between;
      align-items: center;
      margin-bottom: 10px;
    }
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 14px;
    }
    .card {
      padding: 16px;
      display: grid;
      gap: 12px;
      align-content: start;
    }
    .card-meta {
      color: var(--muted);
      font-size: 13px;
      display: flex;
      justify-content: space-between;
      gap: 12px;
    }
    .card-text {
      white-space: pre-wrap;
      line-height: 1.5;
      word-break: break-word;
    }
    .attachment-list {
      display: grid;
      gap: 8px;
    }
    .attachment {
      border: 1px solid rgba(20,38,63,0.1);
      border-radius: 18px;
      padding: 10px;
      background: rgba(15,108,90,0.05);
      display: grid;
      gap: 8px;
    }
    .attachment-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .preview {
      width: 100%;
      border-radius: 12px;
      border: 1px solid rgba(20,38,63,0.08);
      background: white;
    }
    .floating {
      position: fixed;
      right: 16px;
      bottom: 16px;
      display: grid;
      gap: 10px;
    }
    .empty {
      padding: 28px;
      border: 1px dashed rgba(20,38,63,0.2);
      border-radius: 24px;
      color: var(--muted);
      text-align: center;
      background: rgba(255,255,255,0.7);
    }
    @media (max-width: 720px) {
      .hero-grid {
        grid-template-columns: 1fr;
      }
      .cards {
        grid-template-columns: 1fr;
      }
      .floating {
        right: 12px;
        bottom: 12px;
      }
      .hero h1 {
        font-size: 24px;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div class="hero-top">
        <h1>本地提效工具</h1>
        <div class="status"><span id="statusDot" class="dot"></span><span id="statusText">连接中</span></div>
      </div>
      <div class="hero-grid">
        <input id="searchInput" placeholder="搜索卡片内容或附件文件名">
        <div class="status">默认排序: 最新优先</div>
      </div>
    </section>

    <section class="composer">
      <textarea id="composerInput" rows="5" placeholder="输入文本后点击制卡，支持附加图片、音视频、文档和其它文件"></textarea>
      <div class="composer-actions">
        <button id="createBtn" class="accent">制卡</button>
        <button id="clearBtn" class="secondary">清空输入框</button>
        <button id="pickFilesBtn" class="secondary">选择附件</button>
        <input id="fileInput" type="file" multiple hidden>
      </div>
      <div id="pickedFiles" class="status" style="margin-top:10px;">未选择附件</div>
    </section>

    <div class="toolbar">
      <div id="countText" class="status">0 张卡片</div>
      <button id="refreshBtn" class="secondary">刷新</button>
    </div>

    <div id="cardsRoot" class="cards"></div>
  </div>

  <div class="floating">
    <button class="secondary" onclick="window.scrollTo({top: 0, behavior: 'smooth'})">到顶</button>
    <button class="secondary" onclick="window.scrollTo({top: document.body.scrollHeight, behavior: 'smooth'})">到底</button>
  </div>

  <script>
    const wsUrl = ${jsonEncode(wsUrl)};
    const cardsRoot = document.getElementById('cardsRoot');
    const searchInput = document.getElementById('searchInput');
    const composerInput = document.getElementById('composerInput');
    const fileInput = document.getElementById('fileInput');
    const pickedFiles = document.getElementById('pickedFiles');
    const countText = document.getElementById('countText');
    const statusText = document.getElementById('statusText');
    const statusDot = document.getElementById('statusDot');
    let cards = [];
    let pendingFiles = [];
    let socket;

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

    function renderCards() {
      const query = searchInput.value.trim().toLowerCase();
      const filtered = cards.filter(card => {
        if (!query) return true;
        if ((card.text || '').toLowerCase().includes(query)) return true;
        return (card.attachments || []).some(file => (file.name || '').toLowerCase().includes(query));
      });

      countText.textContent = filtered.length + ' 张卡片';
      if (!filtered.length) {
        cardsRoot.innerHTML = '<div class="empty">没有匹配的卡片，试试更换关键词或先创建一张。</div>';
        return;
      }

      cardsRoot.innerHTML = filtered.map(card => {
        const attachments = (card.attachments || []).map(file => {
          let preview = '';
          if (file.kind === 'image') {
            preview = '<img class="preview" src="' + file.downloadUrl + '" alt="' + escapeHtml(file.name) + '">';
          } else if (file.kind === 'audio') {
            preview = '<audio class="preview" controls src="' + file.downloadUrl + '"></audio>';
          } else if (file.kind === 'video') {
            preview = '<video class="preview" controls src="' + file.downloadUrl + '"></video>';
          } else if (file.mimeType === 'application/pdf') {
            preview = '<iframe class="preview" style="min-height:260px;" src="' + file.downloadUrl + '"></iframe>';
          }
          return '<div class="attachment">' +
            '<div class="attachment-row"><strong>' + escapeHtml(file.name) + '</strong><span>' + formatBytes(file.size || 0) + '</span></div>' +
            preview +
            '<div class="attachment-row">' +
              '<span>' + escapeHtml(file.kind || 'other') + '</span>' +
              '<a href="' + file.downloadUrl + '" target="_blank" rel="noopener">打开/下载</a>' +
            '</div>' +
          '</div>';
        }).join('');

        return '<article class="card">' +
          '<div class="card-meta"><span>创建: ' + new Date(card.createdAt).toLocaleString() + '</span><span>更新: ' + new Date(card.updatedAt).toLocaleString() + '</span></div>' +
          '<div class="card-text">' + escapeHtml(card.text || '') + '</div>' +
          (attachments ? '<div class="attachment-list">' + attachments + '</div>' : '') +
          '<div class="composer-actions">' +
            '<button class="secondary" onclick="copyCard(' + JSON.stringify(card.text || '') + ')">复制</button>' +
            '<button class="danger" onclick="deleteCard(' + JSON.stringify(card.id) + ')">删除</button>' +
          '</div>' +
        '</article>';
      }).join('');
    }

    async function refreshCards() {
      const response = await fetch('/api/cards');
      const payload = await response.json();
      cards = payload.cards || [];
      renderCards();
    }

    function connectWs() {
      socket = new WebSocket(wsUrl);
      statusText.textContent = '连接中';
      statusDot.className = 'dot';
      socket.onopen = () => {
        statusText.textContent = '已连接';
        statusDot.className = 'dot connected';
      };
      socket.onclose = () => {
        statusText.textContent = '已断开，重连中';
        statusDot.className = 'dot';
        setTimeout(connectWs, 1200);
      };
      socket.onmessage = event => {
        const payload = JSON.parse(event.data);
        if (payload.type === 'cardsSnapshot') {
          cards = payload.cards || [];
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
      pickedFiles.textContent = '未选择附件';
      await refreshCards();
    }

    async function deleteCard(cardId) {
      await fetch('/api/cards/' + encodeURIComponent(cardId) + '/delete', {method: 'POST'});
      await refreshCards();
    }

    async function copyCard(text) {
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        const temp = document.createElement('textarea');
        temp.value = text;
        document.body.appendChild(temp);
        temp.select();
        document.execCommand('copy');
        temp.remove();
      }
    }

    document.getElementById('pickFilesBtn').addEventListener('click', () => fileInput.click());
    document.getElementById('createBtn').addEventListener('click', createCard);
    document.getElementById('refreshBtn').addEventListener('click', refreshCards);
    document.getElementById('clearBtn').addEventListener('click', () => {
      composerInput.value = '';
      pendingFiles = [];
      fileInput.value = '';
      pickedFiles.textContent = '未选择附件';
    });
    searchInput.addEventListener('input', renderCards);
    fileInput.addEventListener('change', event => {
      pendingFiles = Array.from(event.target.files || []);
      pickedFiles.textContent = pendingFiles.length
        ? '已选择 ' + pendingFiles.length + ' 个附件: ' + pendingFiles.map(file => file.name).join(', ')
        : '未选择附件';
    });

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
      backgroundColor: const Color(0xFFF4F1E8),
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF4F1E8), Color(0xFFEAE6DA)],
                ),
              ),
            ),
          ),
          Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
                  children: [
                    _buildSearchBar(),
                    const SizedBox(height: 12),
                    _buildComposerCard(),
                    const SizedBox(height: 12),
                    _buildStatusStrip(context),
                    const SizedBox(height: 12),
                    _buildCardsSection(cards),
                  ],
                ),
              ),
            ],
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

  Widget _buildSearchBar() {
    return Container(
      decoration: _panelDecoration(
        topColor: const Color(0xFFFFFCF7),
        bottomColor: const Color(0xFFF1EBDF),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: '搜索卡片内容或附件文件名',
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.92),
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
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFD5D0C6)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFD5D0C6)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide:
                  const BorderSide(color: Color(0xFF355C9A), width: 1.4),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  Widget _buildStatusStrip(BuildContext context) {
    return Container(
      decoration: _panelDecoration(
        topColor: const Color(0xFFFFFCF7),
        bottomColor: const Color(0xFFF1EBDF),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              _serverAddress,
              maxLines: 1,
              style: const TextStyle(
                color: Color(0xFF1558B0),
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildStatusTile(
                    icon: Icons.wifi_tethering,
                    label: _isServerRunning ? '服务在线' : '服务未启动',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatusTile(
                    icon: Icons.layers_outlined,
                    label: '${_cards.length} 张卡片',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatusTile(
                    icon: Icons.attach_file,
                    label: '${_attachments.length} 个附件',
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
      decoration: _panelDecoration(
        topColor: const Color(0xFF193D7A),
        bottomColor: const Color(0xFF274E8F),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '快速制卡',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '支持直接输入文本，也支持从手机里选择图片、音视频、文档等附件后一起制卡。',
              style: TextStyle(color: Color(0xFFD7E2FF), height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _composerController,
              minLines: 5,
              maxLines: 9,
              style: const TextStyle(color: Color(0xFF18212F)),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: const Color(0xFFF8F6F0),
                hintText: '写一句灵感、贴一段内容，或先选择附件再制卡',
                hintStyle: const TextStyle(color: Color(0xFF6C7687)),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 12),
            if (_pendingAttachments.isNotEmpty) ...[
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
              const SizedBox(height: 12),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final buttonWidth = (constraints.maxWidth * 0.40)
                    .clamp(132.0, 168.0)
                    .toDouble();
                return Column(
                  children: [
                    _buildComposerButtonRow(
                      left: _buildComposerActionButton(
                        icon: Icons.auto_awesome,
                        label: '制卡',
                        onPressed: _createCardFromComposer,
                        isPrimary: true,
                        width: buttonWidth,
                      ),
                      right: _buildComposerActionButton(
                        icon: Icons.upload_file_outlined,
                        label: _isPickingFiles ? '读取中...' : '选择文件',
                        onPressed:
                            _isPickingFiles ? null : _pickFilesFromDevice,
                        width: buttonWidth,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildComposerButtonRow(
                      left: _buildComposerActionButton(
                        icon: Icons.clear_all,
                        label: '清空',
                        onPressed: () {
                          setState(() {
                            _composerController.clear();
                            _pendingAttachments.clear();
                          });
                        },
                        width: buttonWidth,
                      ),
                      right: _buildComposerActionButton(
                        icon: Icons.content_paste_rounded,
                        label: '粘贴文字',
                        onPressed: _pasteTextToComposer,
                        width: buttonWidth,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildComposerButtonRow(
                      left: _buildServiceActionButton(
                        icon: Icons.wifi_tethering,
                        label: '启动服务',
                        onPressed: _isServerRunning ? null : _startServer,
                        width: buttonWidth,
                      ),
                      right: _buildServiceActionButton(
                        icon: Icons.stop_circle_outlined,
                        label: '停止服务',
                        onPressed: _isServerRunning ? _stopServer : null,
                        width: buttonWidth,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardsSection(List<CardItem> cards) {
    if (cards.isEmpty) {
      return Container(
        decoration: _panelDecoration(),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              const Icon(
                Icons.dashboard_customize_outlined,
                size: 44,
                color: Color(0xFF677285),
              ),
              const SizedBox(height: 12),
              Text(
                '还没有卡片。你可以直接输入文本点击“制卡”，或者先点“选择文件”把手机里的图片、音视频、文档加进来。',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF475161),
                      height: 1.5,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Text(
                '卡片列表',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF18212F),
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(width: 10),
              Text(
                '按最近更新排序',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF6B7381),
                    ),
              ),
            ],
          ),
        ),
        ...cards.map(_buildCardTile),
      ],
    );
  }

  Widget _buildCardTile(CardItem card) {
    final cardAttachments = card.attachmentIds
        .map((id) => _attachments[id])
        .whereType<CardAttachment>()
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: _panelDecoration(
        topColor: Colors.white,
        bottomColor: const Color(0xFFF7F4EC),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFB6C5E4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _buildInfoPill(
                  icon: Icons.schedule,
                  label: _formatDateTime(card.updatedAt),
                  dark: true,
                ),
                const Spacer(),
                if (cardAttachments.isNotEmpty)
                  _buildInfoPill(
                    icon: Icons.attach_file,
                    label: '${cardAttachments.length} 个附件',
                    dark: true,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              card.text.isEmpty ? '无文本内容' : card.text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.55,
                    color: const Color(0xFF18212F),
                    fontWeight: FontWeight.w500,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              '创建 ${_formatDateTime(card.createdAt)}  ·  更新 ${_formatDateTime(card.updatedAt)}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[700]),
            ),
            if (cardAttachments.isNotEmpty) ...[
              const SizedBox(height: 12),
              Column(
                children: cardAttachments.map((attachment) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECE8DC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Icon(_iconForAttachment(attachment),
                            color: const Color(0xFF355C9A)),
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
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _attachmentLabel(attachment),
                                style:
                                    const TextStyle(color: Color(0xFF5E687A)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          attachment.kind.name,
                          style: const TextStyle(
                            color: Color(0xFF5E687A),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _copyCardText(card.text),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _deleteCard(card.id),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration({
    Color topColor = const Color(0xFFFFFCF6),
    Color bottomColor = const Color(0xFFF2EDE1),
  }) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [topColor, bottomColor],
      ),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFD8D2C7)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x160C1730),
          blurRadius: 24,
          offset: Offset(0, 12),
        ),
      ],
    );
  }

  Widget _buildInfoPill({
    required IconData icon,
    required String label,
    bool dark = false,
  }) {
    final background = dark ? const Color(0xFFE8E2D5) : const Color(0xFFEEE8DC);
    final foreground = dark ? const Color(0xFF475161) : const Color(0xFF4B5565);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusTile({
    required IconData icon,
    required String label,
  }) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFFEDE6D9),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF5B6474)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF4D5564),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required double width,
    bool isPrimary = false,
  }) {
    return SizedBox(
      width: width,
      height: 64,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: isPrimary
              ? const Color(0xFFFFD166)
              : Colors.white.withValues(alpha: 0.14),
          foregroundColor: isPrimary ? const Color(0xFF18212F) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        icon: Icon(icon, size: 20),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildServiceActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required double width,
  }) {
    return SizedBox(
      width: width,
      height: 60,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        icon: Icon(icon, size: 20),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildComposerButtonRow({
    required Widget left,
    required Widget right,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [left, right],
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

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
