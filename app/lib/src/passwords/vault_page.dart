import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'password_manager.dart';
import 'vault.dart';

/// Lists, edits and deletes the saved passwords and passkeys.
class VaultPage extends StatefulWidget {
  const VaultPage({super.key, this.manager});

  final PasswordManager? manager;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  PasswordManager get _manager => widget.manager ?? PasswordManager.instance;
  final _search = TextEditingController();
  final Set<String> _revealed = {};

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
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _edit(Vault vault, [SavedPassword? entry]) async {
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => _PasswordDialog(entry: entry),
    );
    if (result == null) return;
    final (origin, username, password) = result;
    if (entry == null) {
      vault.savePassword(origin, username, password);
    } else {
      vault.updatePassword(entry, origin: origin, username: username, password: password);
    }
  }

  Widget _passwords(Vault vault) {
    final entries = vault.passwords.where((p) => _matches(p.origin) || _matches(p.username)).toList()
      ..sort((a, b) => _host(a.origin).compareTo(_host(b.origin)));
    final never = vault.neverSaveOrigins.where(_matches).toList();
    if (entries.isEmpty && never.isEmpty) {
      return const Center(child: Text('No saved passwords. Webby offers to save one when you sign in to a site.'));
    }
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(_host(entry.origin)),
            subtitle: Text.rich(TextSpan(children: [
              TextSpan(text: entry.username.isEmpty ? '(no username)' : entry.username),
              const TextSpan(text: '   '),
              TextSpan(
                text: _revealed.contains(entry.id) ? entry.password : '•' * 10,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ])),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: _revealed.contains(entry.id) ? 'Hide password' : 'Show password',
                icon: Icon(_revealed.contains(entry.id) ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() {
                  if (!_revealed.remove(entry.id)) _revealed.add(entry.id);
                }),
              ),
              IconButton(
                tooltip: 'Copy username',
                icon: const Icon(Icons.person_outline),
                onPressed: () => _copy(entry.username, 'Username'),
              ),
              IconButton(
                tooltip: 'Copy password',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(entry.password, 'Password'),
              ),
              IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit), onPressed: () => _edit(vault, entry)),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await _confirm('Delete password?',
                      'The password for ${entry.username.isEmpty ? 'this account' : entry.username} on '
                          '${_host(entry.origin)} will be removed from Webby.')) {
                    vault.deletePassword(entry);
                  }
                },
              ),
            ]),
          ),
        if (never.isNotEmpty) ...[
          const Divider(),
          const ListTile(dense: true, title: Text('Never saved for')),
          for (final origin in never)
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(_host(origin)),
              trailing: TextButton(
                onPressed: () => vault.setNeverSave(origin, false),
                child: const Text('Allow saving'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _passkeys() {
    if (!_manager.passkeysInVault) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This version of the Ladybird runtime keeps passkeys in its own file, outside the vault. '
              'Update webby-ladybird to manage them here.'),
        ),
      );
    }
    final passkeys = _manager.passkeys
        .where((p) => _matches(p['rpId'] as String? ?? '') || _matches(p['userName'] as String? ?? ''))
        .toList()
      ..sort((a, b) => (a['rpId'] as String? ?? '').compareTo(b['rpId'] as String? ?? ''));
    if (passkeys.isEmpty) {
      return const Center(child: Text('No passkeys. Sites that support them offer to create one when you sign up.'));
    }
    return ListView(
      children: [
        for (final passkey in passkeys)
          ListTile(
            leading: const Icon(Icons.key),
            title: Text(passkey['rpId'] as String? ?? ''),
            subtitle: Text([
              if ((passkey['userDisplayName'] as String? ?? '').isNotEmpty &&
                  passkey['userDisplayName'] != passkey['userName'])
                passkey['userDisplayName'] as String,
              passkey['userName'] as String? ?? '',
              if (_date(passkey['createdAt'] as int? ?? 0).isNotEmpty)
                'created ${_date(passkey['createdAt'] as int? ?? 0)}',
            ].where((s) => s.isNotEmpty).join(' · ')),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await _confirm('Delete passkey?',
                    'You won\'t be able to sign in to ${passkey['rpId']} with this passkey any more. The site may '
                        'still list it until you remove it there too.')) {
                  _manager.deletePasskey(passkey['credentialId'] as String);
                }
              },
            ),
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
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Passwords and passkeys'),
              bottom: const TabBar(tabs: [Tab(text: 'Passwords'), Tab(text: 'Passkeys')]),
            ),
            floatingActionButton: vault == null
                ? null
                : FloatingActionButton.extended(
                    onPressed: () => _edit(vault),
                    icon: const Icon(Icons.add),
                    label: const Text('Add password'),
                  ),
            body: vault == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_manager.error ?? 'Opening the vault…'),
                    ),
                  )
                : Column(
                    children: [
                      if (vault.keyStore == VaultKeyStore.file)
                        MaterialBanner(
                          leading: const Icon(Icons.warning_amber),
                          content: Text('No keyring was found, so the vault\'s key is in a file next to it '
                              '(${vault.path.replaceFirst(RegExp(r'vault\.json$'), 'vault.key')}). Anyone who can '
                              'read your files can read your passwords. Install GNOME Keyring or another Secret '
                              'Service and restart Webby to move the key there.'),
                          actions: const [SizedBox.shrink()],
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Search',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Expanded(child: TabBarView(children: [_passwords(vault), _passkeys()])),
                    ],
                  ),
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
    return AlertDialog(
      title: Text(widget.entry == null ? 'Add password' : 'Edit password'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _site,
              autofocus: widget.entry == null,
              decoration: InputDecoration(labelText: 'Site', errorText: _siteError),
            ),
            TextField(controller: _username, decoration: const InputDecoration(labelText: 'Username')),
            TextField(
              controller: _password,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
