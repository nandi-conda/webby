import 'package:flutter/material.dart';

import 'src/frame_bench.dart';
import 'src/web_view.dart';

void main(List<String> args) {
  runApp(WebbyApp(initialUrl: args.isNotEmpty ? args.first : 'https://ladybird.org'));
}

class WebbyApp extends StatelessWidget {
  const WebbyApp({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Webby',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: BrowserPage(initialUrl: initialUrl),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  WebbyController? _controller;
  Object? _startupError;
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'address');
  final _pageFocus = FocusNode(debugLabel: 'page');
  String _shownUrl = '';

  @override
  void initState() {
    super.initState();
    try {
      _controller = WebbyController(initialUrl: widget.initialUrl)..addListener(_onPageChanged);
      _address.text = widget.initialUrl;
      maybeStartBench(_controller!);
    } catch (error) {
      _startupError = error;
    }
  }

  void _onPageChanged() {
    final controller = _controller!;
    // Don't clobber what the user is typing.
    if (controller.url != _shownUrl && !_addressFocus.hasFocus) {
      _shownUrl = controller.url;
      _address.text = controller.url;
    }
    setState(() {});
  }

  void _go(String input) {
    final text = input.trim();
    if (text.isEmpty) return;
    _controller?.load(text);
    _pageFocus.requestFocus();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _address.dispose();
    _addressFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText('Could not start Ladybird:\n\n$_startupError'),
          ),
        ),
      );
    }

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: controller.canGoBack ? controller.goBack : null,
                  ),
                  IconButton(
                    tooltip: 'Forward',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: controller.canGoForward ? controller.goForward : null,
                  ),
                  IconButton(
                    tooltip: controller.isLoading ? 'Stop' : 'Reload',
                    icon: Icon(controller.isLoading ? Icons.close : Icons.refresh),
                    onPressed: controller.isLoading ? controller.stop : controller.reload,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _address,
                      focusNode: _addressFocus,
                      onSubmitted: _go,
                      textInputAction: TextInputAction.go,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        hintText: 'Search or enter address',
                        prefixIcon: const Icon(Icons.public, size: 18),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: controller.isLoading ? const LinearProgressIndicator() : null,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: WebbyView(controller: controller, focusNode: _pageFocus)),
                if (controller.hoveredLink.isNotEmpty)
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 600),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(controller.hoveredLink, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
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
