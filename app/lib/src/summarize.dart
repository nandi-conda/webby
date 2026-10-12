import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'incognito.dart';
import 'markdown_view.dart';
import 'passwords/password_manager.dart';
import 'ui.dart';
import 'web_view.dart';

/// Name of the DeepSeek API key among the vault's device-only secrets (never synced).
const deepSeekKeySecret = 'deepseek-api-key';

/// Pages longer than this are cut before they're sent, to keep requests quick and cheap.
const maxSummaryInputChars = 40000;

/// JavaScript that sends the page's readable text as `{"type": "pagetext", "id": [id], ...}` through the browser's
/// page-message channel (see passwords/page_script.dart). A selection of some length is summarized instead of the page.
String pageTextScript(String prefix, String id) => '''
(() => {
  const PREFIX = ${jsonEncode(prefix)};
  const ID = ${jsonEncode(id)};
  const LIMIT = $maxSummaryInputChars;
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS', 'IFRAME', 'NAV', 'FOOTER', 'ASIDE',
    'FORM', 'BUTTON', 'SELECT', 'INPUT', 'TEXTAREA', 'HEAD']);
  const BLOCK = new Set(['P', 'DIV', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BR', 'TR', 'SECTION', 'ARTICLE', 'PRE',
    'BLOCKQUOTE', 'UL', 'OL', 'TABLE', 'HEADER', 'MAIN', 'FIGCAPTION', 'DT', 'DD']);
  const textOf = (root) => {
    const out = [];
    let size = 0;
    const walk = (node) => {
      if (size > LIMIT) return;
      if (node.nodeType === 3) {
        const t = node.nodeValue.replace(/\\s+/g, ' ');
        if (t.trim()) { out.push(t); size += t.length; }
        return;
      }
      if (node.nodeType !== 1) return;
      const tag = node.tagName.toUpperCase();
      if (SKIP.has(tag) || node.hidden || node.getAttribute('aria-hidden') === 'true') return;
      if (node.getAttribute('role') === 'navigation') return;
      const block = BLOCK.has(tag);
      if (block) out.push('\\n');
      for (let child = node.firstChild; child; child = child.nextSibling) walk(child);
      if (block) out.push('\\n');
    };
    walk(root);
    return out.join('').replace(/[ \\t]*\\n[ \\t\\n]*/g, '\\n').replace(/ {2,}/g, ' ').trim();
  };
  let text = '';
  let selection = false;
  try {
    const selected = String(window.getSelection ? window.getSelection() : '').trim();
    if (selected.length >= 200) { text = selected; selection = true; }
  } catch (e) {}
  if (!text) {
    const body = document.body || document.documentElement;
    const candidates = [document.querySelector('article'), document.querySelector('main'),
      document.querySelector('[role="main"]')];
    for (const candidate of candidates) {
      if (!candidate) continue;
      const t = textOf(candidate);
      if (t.length >= 500) { text = t; break; }
    }
    if (!text && body) text = textOf(body);
  }
  const message = { type: 'pagetext', id: ID, selection, title: document.title || '', url: location.href,
    lang: document.documentElement.lang || '', text: text.slice(0, LIMIT) };
  try { window.prompt(PREFIX + JSON.stringify(message)); } catch (e) {}
})();
''';

/// The text read from a page by [pageTextScript].
class PageText {
  const PageText({required this.title, required this.url, required this.text, this.selection = false});

  final String title;
  final String url;
  final String text;
  final bool selection;
}

class SummaryError implements Exception {
  SummaryError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads the readable text of [controller]'s page.
Future<PageText> readPageText(WebbyController controller, {Duration timeout = const Duration(seconds: 8)}) async {
  if (!controller.isAttached || controller.messagePrefix.isEmpty) throw SummaryError('The page isn\'t ready yet.');
  final random = Random.secure();
  final id = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final result = Completer<PageText>();
  final subscription = controller.pageMessages.listen((text) {
    if (result.isCompleted) return;
    Map<String, Object?> message;
    try {
      message = jsonDecode(text) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    if (message['type'] != 'pagetext' || message['id'] != id) return;
    result.complete(PageText(
      title: message['title'] as String? ?? '',
      url: message['url'] as String? ?? controller.url,
      text: message['text'] as String? ?? '',
      selection: message['selection'] == true,
    ));
  });
  try {
    controller.runJavaScript(pageTextScript(controller.messagePrefix, id));
    return await result.future.timeout(timeout,
        onTimeout: () => throw SummaryError('Couldn\'t read the text of this page.'));
  } finally {
    await subscription.cancel();
  }
}

/// The request body sent to DeepSeek's chat completions endpoint for [page].
Map<String, Object?> summaryRequest(PageText page, {String model = 'deepseek-chat'}) => {
  'model': model,
  'stream': true,
  'temperature': 0.3,
  'messages': [
    {
      'role': 'system',
      'content': 'You summarize web pages for a browser\'s summary panel. Reply in the language of the page. Start '
          'with one or two sentences saying what the page is about, then give the key points as a short markdown '
          'bullet list. Use markdown: **bold** for key names and figures, `code` for code, and a short ### heading '
          'only when the page covers clearly separate topics. No tables, images or links.',
    },
    {
      'role': 'user',
      'content': '${page.selection ? 'Summarize this text selected on' : 'Summarize this page:'} '
          '${page.title.isEmpty ? '' : '"${page.title}" '}(${page.url})\n\n${page.text}',
    },
  ],
};

/// Streams the summary of [page] from DeepSeek, piece by piece. [apiKey] goes only in the Authorization header.
Stream<String> streamSummary(String apiKey, PageText page,
    {Uri? endpoint, HttpClient Function()? client}) async* {
  final http = (client ?? HttpClient.new)()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await http.postUrl(endpoint ?? Uri.parse('https://api.deepseek.com/chat/completions'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    request.add(utf8.encode(jsonEncode(summaryRequest(page))));
    final response = await request.close().timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 15), onTimeout: () => '');
      throw SummaryError(_describeFailure(response.statusCode, body));
    }
    final lines = response.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines.timeout(const Duration(seconds: 60))) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      try {
        final chunk = jsonDecode(data) as Map<String, Object?>;
        final choices = chunk['choices'] as List<Object?>? ?? const [];
        if (choices.isEmpty) continue;
        final delta = (choices.first as Map<String, Object?>)['delta'] as Map<String, Object?>?;
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) yield content;
      } on FormatException {
        continue;
      }
    }
  } on SocketException catch (e) {
    throw SummaryError('Couldn\'t reach DeepSeek (${e.message}).');
  } on TimeoutException {
    throw SummaryError('DeepSeek took too long to answer.');
  } finally {
    http.close(force: true);
  }
}

String _describeFailure(int status, String body) {
  String? detail;
  try {
    final error = (jsonDecode(body) as Map<String, Object?>)['error'];
    if (error is Map<String, Object?>) detail = error['message'] as String?;
  } catch (_) {}
  return switch (status) {
    401 => 'DeepSeek didn\'t accept the API key. Check it under Summarize settings.',
    402 => 'The DeepSeek account is out of balance.',
    429 => 'DeepSeek is rate limiting requests; try again in a moment.',
    _ => 'DeepSeek answered with an error ($status)${detail == null ? '' : ': $detail'}.',
  };
}

/// One tab's summary: the page it is for, the text so far, and whether it is still coming.
class SummaryJob extends ChangeNotifier {
  SummaryJob._(this.controller);

  static final _jobs = Expando<SummaryJob>('summary');

  /// The summary job of [controller]'s tab.
  static SummaryJob of(WebbyController controller) => _jobs[controller] ??= SummaryJob._(controller);

  final WebbyController controller;

  bool open = false;
  bool running = false;
  String title = '';
  String url = '';
  String text = '';
  String? error;
  bool selection = false;
  int _generation = 0;

  /// Reads the page and asks DeepSeek for a summary, showing the panel.
  Future<void> start(String apiKey) async {
    final generation = ++_generation;
    open = true;
    running = true;
    error = null;
    text = '';
    title = controller.title;
    url = controller.url;
    notifyListeners();
    try {
      final page = await readPageText(controller);
      if (generation != _generation) return;
      title = page.title.isEmpty ? controller.title : page.title;
      url = page.url;
      selection = page.selection;
      if (page.text.trim().length < 40) throw SummaryError('This page has no text to summarize.');
      notifyListeners();
      await for (final piece in streamSummary(apiKey, page)) {
        if (generation != _generation) return;
        text += piece;
        notifyListeners();
      }
      if (text.trim().isEmpty) throw SummaryError('DeepSeek sent back an empty summary.');
    } on SummaryError catch (e) {
      if (generation == _generation) error = e.message;
    } catch (e) {
      if (generation == _generation) error = 'Summarizing failed: $e';
    }
    if (generation != _generation) return;
    running = false;
    notifyListeners();
  }

  void close() {
    _generation++;
    open = false;
    running = false;
    notifyListeners();
  }
}

/// The stored DeepSeek API key, or null.
String? deepSeekApiKey() => PasswordManager.instance.vault?.secret(deepSeekKeySecret);

/// Summarizes [controller]'s page, asking for the API key first when there's none.
Future<void> summarizePage(BuildContext context, WebbyController controller) async {
  var key = deepSeekApiKey();
  if (key == null || key.isEmpty) {
    await showSummarizeSettings(context);
    key = deepSeekApiKey();
    if (key == null || key.isEmpty) return;
  }
  SummaryJob.of(controller).start(key);
}

/// The dialog where the DeepSeek API key is entered, replaced or removed.
Future<void> showSummarizeSettings(BuildContext context) async {
  final vault = PasswordManager.instance.vault;
  if (vault == null || Incognito.active) {
    showKitToast(
      context,
      Incognito.active
          ? 'Set the DeepSeek API key in a normal window.'
          : (PasswordManager.instance.error ?? 'The password vault isn\'t open, so the API key can\'t be stored.'),
    );
    return;
  }
  final result = await showWebbyDialog<String>(context, (context) => _ApiKeyDialog(hasKey: vault.secret(deepSeekKeySecret) != null));
  if (result == null) return;
  await vault.setSecret(deepSeekKeySecret, result.trim());
  if (context.mounted) showKitToast(context, result.trim().isEmpty ? 'DeepSeek API key removed' : 'DeepSeek API key saved');
}

class _ApiKeyDialog extends StatefulWidget {
  const _ApiKeyDialog({required this.hasKey});

  final bool hasKey;

  @override
  State<_ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<_ApiKeyDialog> {
  final _key = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _save() {
    if (_key.text.trim().isEmpty) return;
    Navigator.pop(context, _key.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return KitDialog(
      title: 'Summarize with DeepSeek',
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: widget.hasKey ? 'New API key (one is saved)' : 'DeepSeek API key',
              child: KitTextField(
                controller: _key,
                autofocus: true,
                hint: 'sk-…',
                obscureText: _obscure,
                onSubmitted: (_) => _save(),
                trailing: KitIconButton(
                  _obscure ? Icons.visibility : Icons.visibility_off,
                  tooltip: _obscure ? 'Show' : 'Hide',
                  size: 16,
                  extent: 26,
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            Text(
              'Create a key at platform.deepseek.com. It is kept encrypted in this device\'s password vault and is '
              'never synced. Summarize sends the page\'s text to DeepSeek.',
              style: KitText.small(context, color: c.textDim),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.hasKey) KitButton.danger('Remove key', onPressed: () => Navigator.pop(context, '')),
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary('Save', onPressed: _save),
      ],
    );
  }
}

/// The summary of [controller]'s page: a panel on the right of the page on wide windows, a sheet over the lower part
/// of the page on narrow ones (phones). Nothing while there's no summary open.
class SummaryOverlay extends StatelessWidget {
  const SummaryOverlay({super.key, required this.controller});

  final WebbyController controller;

  @override
  Widget build(BuildContext context) {
    final job = SummaryJob.of(controller);
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        if (!job.open) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final panel = _SummaryPanel(job: job, wide: wide);
          return wide
              ? Align(alignment: Alignment.centerRight, child: SizedBox(width: 380, height: double.infinity, child: panel))
              : Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(width: double.infinity, height: constraints.maxHeight * 0.6, child: panel),
                );
        });
      },
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.job, required this.wide});

  final SummaryJob job;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final key = deepSeekApiKey();
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: wide ? Border(left: BorderSide(color: c.border)) : Border(top: BorderSide(color: c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
              child: Row(
                children: [
                  Icon(Icons.summarize_outlined, size: 16, color: c.textDim),
                  const SizedBox(width: 8),
                  Expanded(child: Text(job.selection ? 'Summary of selection' : 'Summary', style: KitText.body(context))),
                  if (job.running) const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: KitSpinner(size: 14)),
                  KitIconButton(
                    Icons.copy,
                    tooltip: 'Copy summary',
                    size: 16,
                    onPressed: job.text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: job.text.trim()));
                            showKitToast(context, 'Summary copied');
                          },
                  ),
                  KitIconButton(
                    Icons.refresh,
                    tooltip: 'Summarize again',
                    size: 16,
                    onPressed: job.running || key == null ? null : () => job.start(key),
                  ),
                  KitIconButton(Icons.close, tooltip: 'Close', size: 16, onPressed: job.close),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (job.title.isNotEmpty)
                      Text(job.title, style: KitText.body(context).copyWith(fontWeight: FontWeight.w600)),
                    if (job.url.isNotEmpty)
                      Text(job.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.small(context, color: c.textDim)),
                    const SizedBox(height: 12),
                    if (job.error != null)
                      Text(job.error!, style: KitText.body(context).copyWith(color: c.danger))
                    else if (job.text.isEmpty && job.running)
                      Text('Reading the page…', style: KitText.dim(context))
                    else
                      SelectionArea(child: MarkdownView(job.text.trim())),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
