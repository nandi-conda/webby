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
import 'summary_cache.dart';
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
      if (/^H[1-6]\$/.test(tag)) out.push('\\n## ');
      else if (block) out.push('\\n');
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

/// JavaScript that scrolls the page to the place a summary's source link quotes ([words]) and flashes it. Matching
/// is by words, ignoring case, accents, punctuation and markup, so small slips in the quote still land: the whole
/// quote first (a heading, then any text), then the longest run of its words found on the page, then the heading
/// sharing the most words with it. Matches inside hidden parts prefer visible ones; closed <details> are opened.
String jumpToTextScript(String words) => r'''
(() => {
  const QUOTE = ''' + jsonEncode(words) + r''';
  let WORD;
  try { WORD = new RegExp('[\\p{L}\\p{N}]+', 'gu'); } catch (e) { WORD = /[^\s!-\/:-@\[-`{-~ -¿ -⁯　-〿]+/g; }
  const fold = (s) => {
    s = String(s).toLowerCase();
    try { s = s.normalize('NFKD').replace(/[̀-ͯ]/g, ''); } catch (e) {}
    return s;
  };
  const tokensOf = (s) => fold(s).match(WORD) || [];
  const want = tokensOf(QUOTE);
  if (!want.length) return false;
  const visible = (el) => { try { return el.getClientRects().length > 0; } catch (e) { return true; } };
  const go = (el) => {
    for (let p = el; p; p = p.parentElement) if (p.tagName === 'DETAILS' && !p.open) p.open = true;
    while (el.parentElement && (!visible(el) || /^(SPAN|A|B|I|EM|STRONG|CODE|MARK|SMALL|SUP|SUB|ABBR|CITE|Q|S|U)$/.test(el.tagName))) el = el.parentElement;
    try { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) { el.scrollIntoView(); }
    const style = el.style, background = style.backgroundColor, outline = style.outline;
    style.backgroundColor = 'rgba(255, 213, 79, 0.45)';
    style.outline = '2px solid rgba(255, 179, 0, 0.9)';
    setTimeout(() => { style.backgroundColor = background; style.outline = outline; }, 1800);
    return true;
  };
  const headings = [...document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]')];
  const same = (a, b) => a.length === b.length && a.every((t, i) => t === b[i]);
  const heading = headings.find((h) => visible(h) && same(tokensOf(h.textContent), want));
  if (heading) return go(heading);

  // Every word on the page, with the element holding it. A word split by markup (foo<b>bar</b>) stays one word.
  const BLOCK = /^(P|DIV|LI|H[1-6]|TD|TH|TR|SECTION|ARTICLE|BLOCKQUOTE|PRE|DT|DD|FIGCAPTION|HEADER|MAIN|UL|OL|TABLE|BR|DETAILS|SUMMARY)$/;
  const SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|HEAD)$/;
  const blockOf = (el) => { while (el && !BLOCK.test(el.tagName)) el = el.parentElement; return el; };
  const toks = [], owners = [];
  let lastBlock = null, joinable = false;
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const parent = node.parentElement;
    if (!parent || SKIP.test(parent.tagName.toUpperCase())) continue;
    const text = fold(node.nodeValue);
    if (!text.trim()) { joinable = false; continue; }
    const block = blockOf(parent);
    if (block !== lastBlock) joinable = false;
    lastBlock = block;
    WORD.lastIndex = 0;
    let match, end = -1;
    while ((match = WORD.exec(text))) {
      if (match.index === 0 && joinable && toks.length) toks[toks.length - 1] += match[0];
      else { toks.push(match[0]); owners.push(parent); }
      end = match.index + match[0].length;
    }
    joinable = end === text.length;
  }
  const page = ' ' + toks.join(' ') + ' ';
  const starts = [];
  for (let i = 0, at = 1; i < toks.length; i++) { starts.push(at); at += toks[i].length + 1; }
  const tokenAt = (offset) => {
    let lo = 0, hi = starts.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= offset) lo = mid; else hi = mid - 1; }
    return lo;
  };
  // The element of the first visible place showing the word sequence [seq], else of the first hidden one.
  const find = (seq) => {
    const needle = ' ' + seq.join(' ') + ' ';
    let hidden = null;
    for (let at = page.indexOf(needle); at >= 0; at = page.indexOf(needle, at + 1)) {
      const owner = owners[tokenAt(at + 1)];
      if (visible(owner)) return owner;
      hidden = hidden || owner;
    }
    return hidden;
  };
  const whole = find(want);
  if (whole) return go(whole);
  for (let size = want.length - 1; size >= 2; size--) {
    for (let from = 0; from + size <= want.length; from++) {
      const run = want.slice(from, from + size);
      if (size < 3 && run.some((t) => t.length < 4)) continue;
      const owner = find(run);
      if (owner) return go(owner);
    }
  }
  const wanted = new Set(want.filter((t) => t.length >= 3));
  let best = null, bestScore = 0;
  for (const h of headings) {
    const score = new Set(tokensOf(h.textContent).filter((t) => wanted.has(t))).size;
    if (score > bestScore) { best = h; bestScore = score; }
  }
  return best ? go(best) : false;
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
      'content': 'You summarize web pages for a browser\'s summary panel. This needs to be in English: write the '
          'summary in English whatever the language of the page. Start with one or two sentences saying what the '
          'page is about, then give the key points as a short markdown bullet list. Use markdown: **bold** for key '
          'names and figures, `code` for code, and a short ### heading only when the page covers clearly separate '
          'topics. No tables or images. $_sourceLinkRule',
    },
    {
      'role': 'user',
      'content': '${page.selection ? 'Summarize this text selected on' : 'Summarize this page:'} '
          '${page.title.isEmpty ? '' : '"${page.title}" '}(${page.url})\n\n${page.text}',
    },
  ],
};

/// How the model links points to the part of the page they come from; [MarkdownView] turns these links into jumps
/// (see [jumpToTextScript]).
const _sourceLinkRule = 'End each bullet with a source link to the part of the page it comes from, written '
    '[§](#words), where words are 3 to 8 consecutive words copied exactly from the page text; a section heading '
    '(marked ## in the text) is best. Copy them character for character in the page\'s own language, even when it '
    'isn\'t English, without parentheses or brackets. No other links.';

/// The system prompt for follow-up questions about a summarized page.
const _questionPrompt = 'You answer questions about a web page the user is reading, in a browser\'s side panel. Use '
    'the page text and your earlier summary. This needs to be in English: answer in English, concisely, in markdown '
    '(bullet lists, **bold**, `code`; no tables or images). If the page doesn\'t say, say so before adding what you '
    'know. Where a point comes from the page, you may end it with a source link written [§](#words), where words '
    'are 3 to 8 consecutive words copied exactly from the page text, in its own language.';

/// The request body for a follow-up [question] about [page] (null when its text couldn't be read), given the
/// [summary] and the earlier [questions] and answers.
Map<String, Object?> questionRequest({
  required PageText? page,
  required String title,
  required String url,
  required String summary,
  required List<({String question, String answer})> questions,
  required String question,
  String model = 'deepseek-chat',
}) => {
  'model': model,
  'stream': true,
  'temperature': 0.3,
  'messages': [
    {'role': 'system', 'content': _questionPrompt},
    {
      'role': 'user',
      'content': page == null
          ? 'The page "$title" ($url). Its text isn\'t available any more; go by your summary.'
          : '${page.selection ? 'Text selected on' : 'The page'} "${page.title.isEmpty ? title : page.title}" '
              '(${page.url}):\n\n${page.text}',
    },
    {'role': 'assistant', 'content': summary},
    for (final qa in questions) ...[
      {'role': 'user', 'content': qa.question},
      {'role': 'assistant', 'content': qa.answer},
    ],
    {'role': 'user', 'content': question},
  ],
};

/// Streams the summary of [page] from DeepSeek, piece by piece. [apiKey] goes only in the Authorization header.
Stream<String> streamSummary(String apiKey, PageText page, {Uri? endpoint, HttpClient Function()? client}) =>
    streamChat(apiKey, summaryRequest(page), endpoint: endpoint, client: client);

/// Streams the reply to a chat completions [body] (with "stream": true) from DeepSeek, piece by piece.
Stream<String> streamChat(String apiKey, Map<String, Object?> body,
    {Uri? endpoint, HttpClient Function()? client}) async* {
  final http = (client ?? HttpClient.new)()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await http.postUrl(endpoint ?? Uri.parse('https://api.deepseek.com/chat/completions'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    request.add(utf8.encode(jsonEncode(body)));
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

  /// When the summary shown was made, if it came from the cache.
  DateTime? savedAt;

  /// Follow-up questions about the page, oldest first.
  final List<SummaryQuestion> questions = [];

  /// Whether a follow-up answer is coming in.
  bool get answering => questions.isNotEmpty && questions.last.running;

  int _generation = 0;
  String? _key;
  PageText? _page;
  DateTime? _madeAt;

  /// Shows the saved summary of the current page, if there is one. Returns whether there was.
  bool showSaved() {
    final key = SummaryCache.keyFor(controller.url);
    final saved = SummaryCache.instance.lookup(key);
    if (saved == null) return false;
    _page = null;
    _show(key, saved);
    return true;
  }

  void _show(String key, CachedSummary saved) {
    _generation++;
    _key = key;
    questions
      ..clear()
      ..addAll([for (final qa in saved.questions) SummaryQuestion(qa.question)..answer = qa.answer]);
    open = true;
    running = false;
    error = null;
    title = saved.title;
    url = saved.url;
    text = saved.text;
    selection = saved.selection;
    savedAt = DateTime.fromMillisecondsSinceEpoch(saved.at);
    _madeAt = savedAt;
    notifyListeners();
  }

  /// Reads the page and asks DeepSeek for a summary, showing the panel. A summary saved for the same page (or the
  /// same selection) is shown instead unless [fresh].
  Future<void> start(String apiKey, {bool fresh = false}) async {
    final generation = ++_generation;
    open = true;
    running = true;
    error = null;
    text = '';
    title = controller.title;
    url = controller.url;
    savedAt = null;
    questions.clear();
    _key = null;
    _page = null;
    _madeAt = null;
    notifyListeners();
    try {
      final page = await readPageText(controller);
      if (generation != _generation) return;
      final key = SummaryCache.keyFor(page.url, selection: page.selection ? page.text : null);
      final saved = fresh ? null : SummaryCache.instance.lookup(key);
      _page = page;
      if (saved != null) {
        _show(key, saved);
        return;
      }
      _key = key;
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
      _save(DateTime.now());
    } on SummaryError catch (e) {
      if (generation == _generation) error = e.message;
    } catch (e) {
      if (generation == _generation) error = 'Summarizing failed: $e';
    }
    if (generation != _generation) return;
    running = false;
    notifyListeners();
  }

  void _save(DateTime at) {
    final key = _key;
    if (key == null || text.trim().isEmpty) return;
    _madeAt ??= at;
    SummaryCache.instance.store(key, CachedSummary(
      title: title,
      url: url,
      text: text,
      at: _madeAt!.millisecondsSinceEpoch,
      selection: selection,
      questions: [
        for (final qa in questions)
          if (!qa.running && qa.error == null && qa.answer.trim().isNotEmpty) (question: qa.question, answer: qa.answer),
      ],
    ));
  }

  /// Asks DeepSeek a follow-up [question] about the page, with the page text, the summary and the earlier questions
  /// as context. The answer streams into the last of [questions] and is saved with the summary.
  Future<void> ask(String apiKey, String question) async {
    question = question.trim();
    if (question.isEmpty || running || answering || text.trim().isEmpty) return;
    final generation = _generation;
    final earlier = [
      for (final qa in questions)
        if (qa.error == null && qa.answer.trim().isNotEmpty) (question: qa.question, answer: qa.answer),
    ];
    final entry = SummaryQuestion(question)..running = true;
    questions.add(entry);
    notifyListeners();
    try {
      // A saved summary has no page text with it: read the page again if the tab still shows it.
      if (_page == null && !selection && SummaryCache.keyFor(controller.url) == SummaryCache.keyFor(url)) {
        try {
          _page = await readPageText(controller);
        } on SummaryError {
          // Go by the summary alone.
        }
        if (generation != _generation) return;
      }
      final body = questionRequest(
          page: _page, title: title, url: url, summary: text, questions: earlier, question: question);
      await for (final piece in streamChat(apiKey, body)) {
        if (generation != _generation) return;
        entry.answer += piece;
        notifyListeners();
      }
      if (entry.answer.trim().isEmpty) throw SummaryError('DeepSeek sent back an empty answer.');
    } on SummaryError catch (e) {
      entry.error = e.message;
    } catch (e) {
      entry.error = 'Asking failed: $e';
    }
    if (generation != _generation) return;
    entry.running = false;
    if (entry.error == null) _save(DateTime.now());
    notifyListeners();
  }

  /// Scrolls the page to the part a summary's source link points at ([words] copied from the page). Returns false
  /// when the tab shows another page by now.
  bool jumpTo(String words) {
    if (SummaryCache.keyFor(controller.url) != SummaryCache.keyFor(url)) return false;
    controller.runJavaScript(jumpToTextScript(words));
    return true;
  }

  void close() {
    _generation++;
    if (questions.isNotEmpty && questions.last.running) {
      questions.last
        ..running = false
        ..error ??= 'Stopped.';
    }
    open = false;
    running = false;
    notifyListeners();
  }
}

/// A follow-up question about a summarized page and its answer.
class SummaryQuestion {
  SummaryQuestion(this.question);

  final String question;
  String answer = '';
  String? error;
  bool running = false;
}

/// The stored DeepSeek API key, or null.
String? deepSeekApiKey() => PasswordManager.instance.vault?.secret(deepSeekKeySecret);

/// Summarizes [controller]'s page, asking for the API key first when there's none. A summary saved for the page is
/// shown without asking DeepSeek again (the panel's redo button makes a new one).
Future<void> summarizePage(BuildContext context, WebbyController controller) async {
  final job = SummaryJob.of(controller);
  // The saved page summary wins over a selection here; redo reads the page again and summarizes the selection.
  if (job.showSaved()) return;
  var key = deepSeekApiKey();
  if (key == null || key.isEmpty) {
    await showSummarizeSettings(context);
    key = deepSeekApiKey();
    if (key == null || key.isEmpty) return;
  }
  job.start(key);
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

/// [child] (the page) with the summary of [controller]'s page beside it: a panel on the right on wide windows, a
/// sheet under the page on narrow ones (phones). The page shrinks to make room, so nothing of it is covered.
class SummaryLayout extends StatelessWidget {
  const SummaryLayout({super.key, required this.controller, required this.child});

  final WebbyController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final job = SummaryJob.of(controller);
    return ListenableBuilder(
      listenable: job,
      child: child,
      builder: (context, page) => LayoutBuilder(builder: (context, constraints) {
        final open = job.open;
        final wide = constraints.maxWidth >= 720;
        // The page keeps its place in the tree whether the panel is open or not, so its view isn't rebuilt.
        return Flex(
          direction: wide ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: page!),
            if (open)
              wide
                  ? SizedBox(width: 380, child: _SummaryPanel(job: job, wide: true))
                  : SizedBox(height: constraints.maxHeight * 0.5, child: _SummaryPanel(job: job, wide: false)),
          ],
        );
      }),
    );
  }
}

class _SummaryPanel extends StatefulWidget {
  const _SummaryPanel({required this.job, required this.wide});

  final SummaryJob job;
  final bool wide;

  @override
  State<_SummaryPanel> createState() => _SummaryPanelState();
}

class _SummaryPanelState extends State<_SummaryPanel> {
  final _question = TextEditingController();
  final _scroll = ScrollController();

  SummaryJob get job => widget.job;

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _ask() {
    final key = deepSeekApiKey();
    final question = _question.text.trim();
    if (key == null || question.isEmpty || job.running || job.answering) return;
    _question.clear();
    job.ask(key, question);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jump(String words) {
    if (!job.jumpTo(words)) showKitToast(context, 'Go back to the summarized page to jump to that part.');
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final key = deepSeekApiKey();
    final canAsk = key != null && job.text.trim().isNotEmpty && !job.running && job.error == null;
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: widget.wide ? Border(left: BorderSide(color: c.border)) : Border(top: BorderSide(color: c.border)),
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
                  if (job.running || job.answering)
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: KitSpinner(size: 14)),
                  KitIconButton(
                    Icons.copy,
                    tooltip: 'Copy summary',
                    size: 16,
                    onPressed: job.text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: job.text.replaceAll(RegExp(r' ?\[§\]\(#[^)\n]*\)'), '').trim()));
                            showKitToast(context, 'Summary copied');
                          },
                  ),
                  KitIconButton(
                    Icons.refresh,
                    tooltip: 'Summarize again',
                    size: 16,
                    onPressed: job.running || job.answering || key == null ? null : () => job.start(key, fresh: true),
                  ),
                  KitIconButton(Icons.close, tooltip: 'Close', size: 16, onPressed: job.close),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(14),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (job.title.isNotEmpty)
                        Text(job.title, style: KitText.body(context).copyWith(fontWeight: FontWeight.w600)),
                      if (job.url.isNotEmpty)
                        Text(job.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.small(context, color: c.textDim)),
                      if (job.savedAt != null && !job.running)
                        Text('Saved summary from ${_when(job.savedAt!)}. Summarize again for a new one.',
                            style: KitText.small(context, color: c.textDim)),
                      const SizedBox(height: 12),
                      if (job.error != null)
                        Text(job.error!, style: KitText.body(context).copyWith(color: c.danger))
                      else if (job.text.isEmpty && job.running)
                        Text('Reading the page…', style: KitText.dim(context))
                      else
                        MarkdownView(job.text.trim(), onAnchor: _jump),
                      for (final qa in job.questions) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(color: c.hover, borderRadius: BorderRadius.circular(kitRadius)),
                          child: Text(qa.question, style: KitText.body(context).copyWith(fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(height: 8),
                        if (qa.answer.trim().isNotEmpty) MarkdownView(qa.answer.trim(), onAnchor: _jump),
                        if (qa.answer.trim().isEmpty && qa.running) Text('Thinking…', style: KitText.dim(context)),
                        if (qa.error != null)
                          Text(qa.error!, style: KitText.body(context).copyWith(color: c.danger)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
              child: KitTextField(
                controller: _question,
                hint: 'Ask about this page',
                enabled: canAsk,
                onSubmitted: (_) => _ask(),
                trailing: KitIconButton(
                  Icons.send,
                  tooltip: 'Ask',
                  size: 16,
                  extent: 26,
                  onPressed: canAsk && !job.answering ? _ask : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _when(DateTime time) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(time.hour)}:${two(time.minute)}';
  if (time.year == now.year && time.month == now.month && time.day == now.day) return 'today $clock';
  return '${time.year}-${two(time.month)}-${two(time.day)} $clock';
}
