import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

class WhiteboardEditorPage extends StatefulWidget {
  const WhiteboardEditorPage(
      {super.key, required this.uri, required this.onDownload});
  final Uri uri;
  final Future<void> Function(String name, Uint8List bytes, String mimeType)
      onDownload;
  @override
  State<WhiteboardEditorPage> createState() => _WhiteboardEditorPageState();
}

class _WhiteboardEditorPageState extends State<WhiteboardEditorPage> {
  late final WebViewController _controller;
  bool _landscape = false;
  bool _allowPop = false;
  bool _closing = false;
  Completer<bool>? _pendingClose;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('LocalShare', onMessageReceived: (message) async {
        try {
          final data = jsonDecode(message.message) as Map<String, dynamic>;
          if (data['type'] == 'close') {
            if (_pendingClose?.isCompleted == false) {
              _pendingClose!.complete(data['saved'] == true);
            }
            return;
          }
          if (data['type'] != 'download') return;
          final uri = UriData.parse(data['dataURL'] as String);
          await widget.onDownload(
              data['name'] as String, uri.contentAsBytes(), uri.mimeType);
        } catch (_) {
          _toast('下载失败，请稍后重试');
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() => _error = '白板加载失败，请重试');
          }
        },
        onNavigationRequest: (request) {
          final target = Uri.tryParse(request.url);
          return target?.host == widget.uri.host &&
                  target?.port == widget.uri.port
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ))
      ..loadRequest(widget.uri);
    if (_controller.platform is AndroidWebViewController) {
      unawaited((_controller.platform as AndroidWebViewController)
          .setOnShowFileSelector((params) async {
        final result = await FilePicker.platform.pickFiles(
            allowMultiple: params.mode == FileSelectorMode.openMultiple);
        return result?.paths
                .whereType<String>()
                .map((path) => Uri.file(path).toString())
                .toList() ??
            [];
      }));
    }
  }

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      _pendingClose = Completer<bool>();
      await _controller.runJavaScript(
        '(async () => { const result = await window.localShareSave(); LocalShare.postMessage(JSON.stringify({type:"close",saved:result.saved})); })()',
      );
      final saved =
          await _pendingClose!.future.timeout(const Duration(seconds: 30));
      if (saved) {
        _leave();
      } else {
        _toast('尚未保存完成，请稍后再返回；如有冲突，请先导出备份。',
            action: SnackBarAction(
                label: '退出',
                onPressed: () {
                  _leave();
                }));
      }
    } catch (_) {
      _toast('无法确认保存状态，请检查页面；可导出备份后退出。',
          action: SnackBarAction(
              label: '退出',
              onPressed: () {
                _leave();
              }));
    } finally {
      _closing = false;
    }
  }

  void _leave() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _toggleLandscape() async {
    final next = !_landscape;
    await SystemChrome.setPreferredOrientations(next
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : []);
    if (mounted) setState(() => _landscape = next);
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations([]));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 44,
            leading: IconButton(
                tooltip: '保存并返回',
                onPressed: _close,
                icon: const Icon(Icons.arrow_back)),
            title: const Text('白板', style: TextStyle(fontSize: 17)),
            actions: [
              TextButton.icon(
                  onPressed: _toggleLandscape,
                  icon: Icon(_landscape
                      ? Icons.screen_rotation
                      : Icons.stay_current_landscape),
                  label: Text(_landscape ? '自动旋转' : '横屏'))
            ],
          ),
          body: SafeArea(
              child: Column(children: [
            if (_progress < 100)
              LinearProgressIndicator(value: _progress / 100),
            if (_error != null)
              MaterialBanner(content: Text(_error!), actions: [
                TextButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _controller.reload();
                    },
                    child: const Text('重试'))
              ]),
            Expanded(child: WebViewWidget(controller: _controller)),
          ])),
        ),
      );
}
