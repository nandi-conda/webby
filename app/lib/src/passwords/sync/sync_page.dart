import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../ui.dart';
import '../password_manager.dart';
import 'qr_scan_page.dart';
import 'sync_crypto.dart';
import 'sync_store.dart';
import 'vault_sync.dart';

/// Turns password sync on or off and shows the code other devices pair with.
class SyncPage extends StatelessWidget {
  const SyncPage({super.key, this.manager});

  final PasswordManager? manager;

  @override
  Widget build(BuildContext context) {
    final manager = this.manager ?? PasswordManager.instance;
    final sync = manager.sync;
    return KitPage(
      title: 'Sync passwords, passkeys and bookmarks',
      body: sync == null
          ? Center(child: Text(manager.error ?? 'Opening the vault…', style: KitText.dim(context)))
          : ListenableBuilder(
              listenable: Listenable.merge([sync, sync.vault]),
              builder: (context, _) => sync.enabled ? _SyncOn(sync) : _SyncOff(sync),
            ),
    );
  }
}

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) showKitToast(context, '$error');
  }
}

class _SyncOff extends StatelessWidget {
  const _SyncOff(this.sync);

  final VaultSync sync;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Keep your passwords, passkeys and bookmarks on all your devices', style: KitText.heading(context)),
        const SizedBox(height: 8),
        Text(
          'Webby encrypts them on this device with a sync code that only your devices know, then stores the encrypted '
          'copy on a sync server or in your own WebDAV folder. Nobody without the code, the server included, can read '
          'them.',
          style: KitText.dim(context),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            KitButton.primary('Turn on sync', icon: Icons.sync, onPressed: () async {
              final storage = await showWebbyDialog<SyncSettings>(context, (_) => const _SetupDialog(join: false));
              if (storage != null && context.mounted) await _guard(context, () => sync.enable(storage));
            }),
            KitButton('I have a sync code', icon: Icons.qr_code, onPressed: () async {
              final settings = await showWebbyDialog<SyncSettings>(context, (_) => const _SetupDialog(join: true));
              if (settings != null && context.mounted) await _guard(context, () => sync.enable(settings));
            }),
          ],
        ),
      ],
    );
  }
}

class _SyncOn extends StatelessWidget {
  const _SyncOn(this.sync);

  final VaultSync sync;

  String _when(int? seconds) {
    if (seconds == null) return 'not yet';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
    if (ago.inMinutes < 1) return 'just now';
    if (ago.inHours < 1) return '${ago.inMinutes} min ago';
    if (ago.inDays < 1) return '${ago.inHours} h ago';
    return '${ago.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final settings = sync.settings!;
    final where = settings.backend == SyncBackend.webdav
        ? 'WebDAV folder ${settings.server}'
        : (settings.server == defaultSyncServer ? 'the webby sync server' : settings.server);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sync.error != null) KitBanner(message: 'Sync isn\'t working: ${sync.error}', danger: true),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sync.syncing ? 'Syncing with $where…' : 'Synced with $where ${_when(settings.lastSync)}.',
                      style: KitText.body(context),
                    ),
                  ),
                  KitButton('Sync now', icon: Icons.sync, onPressed: sync.syncing ? null : sync.syncNow),
                ],
              ),
              const SizedBox(height: 24),
              Text('Add another device', style: KitText.heading(context)),
              const SizedBox(height: 6),
              Text(
                'In webby on the other device, open Passwords › Sync › I have a sync code, then scan this QR code or '
                'type the code. Keep it private: it unlocks your passwords.'
                '${settings.backend == SyncBackend.webdav ? ' The other device also needs the WebDAV login.' : ''}',
                style: KitText.dim(context),
              ),
              const SizedBox(height: 16),
              _PairingCode(settings),
              const SizedBox(height: 32),
              const KitDivider(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  KitButton('Turn off sync on this device', onPressed: () => _guard(context, () => sync.disable())),
                  KitButton.danger('Turn off everywhere and erase', onPressed: () async {
                    final sure = await showWebbyDialog<bool>(
                      context,
                      (context) => KitDialog(
                        title: 'Erase the synced copy?',
                        content: const Text('The encrypted copy on the server is deleted and your other devices stop '
                            'syncing. Passwords and bookmarks already on each device stay there.'),
                        actions: [
                          KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
                          KitButton.danger('Erase', onPressed: () => Navigator.pop(context, true)),
                        ],
                      ),
                    );
                    if (sure == true && context.mounted) await _guard(context, () => sync.disable(erase: true));
                  }),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PairingCode extends StatefulWidget {
  const _PairingCode(this.settings);

  final SyncSettings settings;

  @override
  State<_PairingCode> createState() => _PairingCodeState();
}

class _PairingCodeState extends State<_PairingCode> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    if (!_shown) {
      return Align(
        alignment: Alignment.centerLeft,
        child: KitButton('Show sync code', icon: Icons.qr_code, onPressed: () => setState(() => _shown = true)),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: c.border)),
          child: QrImageView(data: widget.settings.pairingLink, size: 180, padding: EdgeInsets.zero),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(widget.settings.code, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KitButton('Copy code', icon: Icons.copy, onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.settings.code));
                  showKitToast(context, 'Sync code copied');
                }),
                KitButton.ghost('Hide', onPressed: () => setState(() => _shown = false)),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

enum _Storage { webby, custom, webdav }

/// Asks where to sync and, when joining, for the code; when turning sync on, makes a new code. Returns settings for
/// [VaultSync.enable].
class _SetupDialog extends StatefulWidget {
  const _SetupDialog({required this.join});

  final bool join;

  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  final _code = TextEditingController();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  _Storage _storage = _Storage.webby;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _codeChanged(String text) {
    // A pasted pairing link says where to sync; show that.
    try {
      if (!text.trim().startsWith('webby-sync:')) return;
      final settings = SyncSettings.fromPairing(text);
      setState(() {
        if (settings.backend == SyncBackend.webdav) {
          _storage = _Storage.webdav;
          _server.text = settings.server;
        } else if (settings.server != defaultSyncServer) {
          _storage = _Storage.custom;
          _server.text = settings.server;
        }
      });
    } catch (_) {}
  }

  Future<void> _scan() async {
    final text = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (text == null || !mounted) return;
    _code.text = text.trim();
    setState(() => _error = null);
    _codeChanged(_code.text);
  }

  void _submit() {
    var code = '';
    if (widget.join) {
      try {
        code = SyncSettings.fromPairing(_code.text).code;
      } on BadSyncCode catch (error) {
        setState(() => _error = error.message);
        return;
      } catch (_) {
        setState(() => _error = 'That isn\'t a sync code.');
        return;
      }
    } else {
      code = SyncKey.generate().code;
    }
    final server = _server.text.trim();
    if (_storage != _Storage.webby) {
      final uri = Uri.tryParse(server);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty || !(uri.scheme == 'https' || uri.scheme == 'http')) {
        setState(() => _error = 'Enter the server\'s address, like https://cloud.example.com/remote.php/dav/files/me/webby');
        return;
      }
    }
    Navigator.pop(
      context,
      SyncSettings(
        code: code,
        backend: _storage == _Storage.webdav ? SyncBackend.webdav : SyncBackend.webbySync,
        server: _storage == _Storage.webby ? defaultSyncServer : server,
        username: _storage == _Storage.webdav ? _username.text : '',
        password: _storage == _Storage.webdav ? _password.text : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return KitDialog(
      title: widget.join ? 'Join sync' : 'Turn on sync',
      width: 480,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.join)
            LabeledField(
              label: 'Sync code from your other device',
              child: KitTextField(
                controller: _code,
                autofocus: true,
                hint: 'webby1-…',
                error: _error != null && _code.text.isNotEmpty,
                onChanged: _codeChanged,
                onSubmitted: (_) => _submit(),
              ),
            ),
          if (widget.join && Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: KitButton('Scan QR code', icon: Icons.qr_code_scanner, onPressed: _scan),
            ),
          LabeledField(
            label: 'Store the encrypted copy on',
            child: KitTabs<_Storage>(
              tabs: const [
                (_Storage.webby, 'Webby sync'),
                (_Storage.custom, 'My sync server'),
                (_Storage.webdav, 'WebDAV'),
              ],
              selected: _storage,
              onChanged: (storage) => setState(() => _storage = storage),
            ),
          ),
          if (_storage == _Storage.custom)
            LabeledField(
              label: 'Server address (runs sync-server from the webby repo)',
              child: KitTextField(controller: _server, keyboardType: TextInputType.url, autocorrect: false, enableSuggestions: false, hint: 'https://sync.example.com'),
            ),
          if (_storage == _Storage.webdav) ...[
            LabeledField(
              label: 'Folder address',
              child: KitTextField(controller: _server, keyboardType: TextInputType.url, autocorrect: false, enableSuggestions: false, hint: 'https://cloud.example.com/remote.php/dav/files/me/webby'),
            ),
            LabeledField(label: 'Username', child: KitTextField(controller: _username, autocorrect: false, enableSuggestions: false)),
            LabeledField(
              label: 'Password (an app password is best)',
              child: KitTextField(controller: _password, obscureText: true, onSubmitted: (_) => _submit()),
            ),
          ],
          if (_error != null) Text(_error!, style: KitText.small(context, color: c.danger)),
        ],
      ),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary(widget.join ? 'Join' : 'Turn on', onPressed: _submit),
      ],
    );
  }
}
