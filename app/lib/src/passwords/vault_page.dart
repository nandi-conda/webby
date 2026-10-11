import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui.dart';
import 'generator.dart';
import 'password_manager.dart';
import 'sync/sync_page.dart';
import 'vault.dart';

/// Lists, edits and deletes the saved passwords and passkeys.
class VaultPage extends StatefulWidget {
  const VaultPage({super.key, this.manager});

  final PasswordManager? manager;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

enum _Tab { passwords, passkeys }

class _VaultPageState extends State<VaultPage> {
  PasswordManager get _manager => widget.manager ?? PasswordManager.instance;
  final _search = TextEditingController();
  final Set<String> _revealed = {};
  _Tab _tab = _Tab.passwords;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(String text) => text.toLowerCase().contains(_search.text.trim().toLowerCase());

  String _host(String origin) => Uri.tryParse(origin)?.host ?? origin;

  String _date(int seconds) {
    if (seconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<bool> _confirm(String title, String body) async {
    return await showWebbyDialog<bool>(
          context,
          (context) => KitDialog(
            title: title,
            content: Text(body),
            actions: [
              KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
              KitButton.danger('Delete', onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        ) ??
        false;
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    showKitToast(context, '$what copied');
  }

  Future<void> _edit(Vault vault, [SavedPassword? entry]) async {
    final result = await showWebbyDialog<(String, String, String)>(context, (context) => _PasswordDialog(entry: entry));
    if (result == null) return;
    final (origin, username, password) = result;
    if (entry == null) {
      vault.savePassword(origin, username, password);
    } else {
      vault.updatePassword(entry, origin: origin, username: username, password: password);
    }
  }

  Widget _empty(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center, style: KitText.dim(context)),
    ),
  );

  Widget _passwords(Vault vault) {
    final entries = vault.passwords.where((p) => _matches(p.origin) || _matches(p.username)).toList()
      ..sort((a, b) => _host(a.origin).compareTo(_host(b.origin)));
    final never = vault.neverSaveOrigins.where(_matches).toList();
    if (entries.isEmpty && never.isEmpty) {
      return _empty('No saved passwords. Webby offers to save one when you sign in to a site.');
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final entry in entries)
          KitTile(
            icon: Icons.language,
            title: _host(entry.origin),
            subtitle: Text.rich(TextSpan(children: [
              TextSpan(text: entry.username.isEmpty ? '(no username)' : entry.username),
              const TextSpan(text: '   '),
              TextSpan(
                text: _revealed.contains(entry.id) ? entry.password : '•' * 10,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ])),
            trailing: [
              KitIconButton.compact(
                _revealed.contains(entry.id) ? Icons.visibility_off : Icons.visibility,
                tooltip: _revealed.contains(entry.id) ? 'Hide password' : 'Show password',
                onPressed: () => setState(() {
                  if (!_revealed.remove(entry.id)) _revealed.add(entry.id);
                }),
              ),
              KitIconButton.compact(
                Icons.person_outline,
                tooltip: 'Copy username',
                onPressed: () => _copy(entry.username, 'Username'),
              ),
              KitIconButton.compact(
                Icons.copy,
                tooltip: 'Copy password',
                onPressed: () => _copy(entry.password, 'Password'),
              ),
              KitIconButton.compact(Icons.edit_outlined, tooltip: 'Edit', onPressed: () => _edit(vault, entry)),
              KitIconButton.compact(
                Icons.delete_outline,
                tooltip: 'Delete',
                onPressed: () async {
                  if (await _confirm('Delete password?',
                      'The password for ${entry.username.isEmpty ? 'this account' : entry.username} on '
                          '${_host(entry.origin)} will be removed from Webby.')) {
                    vault.deletePassword(entry);
                  }
                },
              ),
            ],
          ),
        if (never.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: KitDivider()),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Text('Never saved for', style: KitText.dim(context, small: true)),
          ),
          for (final origin in never)
            KitTile(
              icon: Icons.block,
              title: _host(origin),
              trailing: [KitButton.ghost('Allow saving', onPressed: () => vault.setNeverSave(origin, false))],
            ),
        ],
      ],
    );
  }

  Widget _passkeys() {
    if (!_manager.passkeysInVault) {
      return _empty('This version of the Ladybird runtime keeps passkeys in its own file, outside the vault. '
          'Update webby-ladybird to manage them here.');
    }
    final passkeys = _manager.passkeys
        .where((p) => _matches(p['rpId'] as String? ?? '') || _matches(p['userName'] as String? ?? ''))
        .toList()
      ..sort((a, b) => (a['rpId'] as String? ?? '').compareTo(b['rpId'] as String? ?? ''));
    if (passkeys.isEmpty) {
      return _empty('No passkeys. Sites that support them offer to create one when you sign up.');
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final passkey in passkeys)
          KitTile(
            icon: Icons.key,
            title: passkey['rpId'] as String? ?? '',
            subtitle: Text([
              if ((passkey['userDisplayName'] as String? ?? '').isNotEmpty &&
                  passkey['userDisplayName'] != passkey['userName'])
                passkey['userDisplayName'] as String,
              passkey['userName'] as String? ?? '',
              if (_date(passkey['createdAt'] as int? ?? 0).isNotEmpty)
                'created ${_date(passkey['createdAt'] as int? ?? 0)}',
            ].where((s) => s.isNotEmpty).join(' · ')),
            trailing: [
              KitIconButton.compact(
                Icons.delete_outline,
                tooltip: 'Delete',
                onPressed: () async {
                  if (await _confirm('Delete passkey?',
                      'You won\'t be able to sign in to ${passkey['rpId']} with this passkey any more. The site may '
                          'still list it until you remove it there too.')) {
                    _manager.deletePasskey(passkey['credentialId'] as String);
                  }
                },
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final vault = _manager.vault;
        return KitPage(
          title: 'Passwords and passkeys',
          actions: [
            if (vault != null)
              KitButton(
                _manager.sync?.enabled == true ? 'Synced' : 'Sync',
                icon: Icons.sync,
                tooltip: 'Sync passwords, passkeys and bookmarks with your other devices',
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => SyncPage(manager: widget.manager))),
              ),
            if (vault != null) KitButton.primary('Add password', icon: Icons.add, onPressed: () => _edit(vault)),
          ],
          body: vault == null
              ? _empty(_manager.error ?? 'Opening the vault…')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Android has no keyring for the vault's key yet; the app's private storage keeps other apps out.
                    if (vault.keyStore == VaultKeyStore.file && !Platform.isAndroid)
                      KitBanner(
                        message: 'No keyring was found, so the vault\'s key is in a file next to it '
                            '(${vault.path.replaceFirst(RegExp(r'vault\.json$'), 'vault.key')}). Anyone who can '
                            'read your files can read your passwords. Install GNOME Keyring or another Secret '
                            'Service and restart Webby to move the key there.',
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final tabs = KitTabs<_Tab>(
                            tabs: const [(_Tab.passwords, 'Passwords'), (_Tab.passkeys, 'Passkeys')],
                            selected: _tab,
                            onChanged: (tab) => setState(() => _tab = tab),
                          );
                          final search = KitTextField(
                            controller: _search,
                            hint: 'Search',
                            prefixIcon: Icons.search,
                            onChanged: (_) => setState(() {}),
                          );
                          // On a phone the search box would squeeze the Passkeys tab out of view; stack them.
                          if (constraints.maxWidth < 560) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [tabs, const SizedBox(height: 8), search],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: tabs),
                              const SizedBox(width: 12),
                              SizedBox(width: 260, child: search),
                            ],
                          );
                        },
                      ),
                    ),
                    Expanded(child: _tab == _Tab.passwords ? _passwords(vault) : _passkeys()),
                  ],
                ),
        );
      },
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({this.entry});

  final SavedPassword? entry;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  late final _site = TextEditingController(text: widget.entry?.origin ?? '');
  late final _username = TextEditingController(text: widget.entry?.username ?? '');
  late final _password = TextEditingController(text: widget.entry?.password ?? '');
  bool _obscure = true;
  String? _siteError;

  @override
  void dispose() {
    _site.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    var site = _site.text.trim();
    if (site.isNotEmpty && !site.contains('://')) site = 'https://$site';
    final origin = originOf(site);
    if (origin == null) {
      setState(() => _siteError = 'Enter a web address, like https://example.com');
      return;
    }
    Navigator.pop(context, (origin, _username.text, _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return KitDialog(
      title: widget.entry == null ? 'Add password' : 'Edit password',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'Site',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                KitTextField(controller: _site, autofocus: widget.entry == null, error: _siteError != null),
                if (_siteError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_siteError!, style: KitText.small(context, color: c.danger)),
                  ),
              ],
            ),
          ),
          LabeledField(label: 'Username', child: KitTextField(controller: _username)),
          LabeledField(
            label: 'Password',
            child: KitTextField(
              controller: _password,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KitIconButton.compact(
                    Icons.casino_outlined,
                    tooltip: 'Generate a strong password',
                    onPressed: () => setState(() {
                      _password.text = generatePassword();
                      _obscure = false;
                    }),
                  ),
                  KitIconButton.compact(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary('Save', onPressed: _submit),
      ],
    );
  }
}
