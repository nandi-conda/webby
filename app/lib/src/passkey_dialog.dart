import 'package:flutter/material.dart';

import 'web_view.dart';

/// Asks the user to approve a page's passkey request (see `webby_view_webauthn_prompt` in webby_ffi.h) and sends the
/// answer back to the view. Closing the dialog any other way cancels the request.
Future<void> showPasskeyDialog(BuildContext context, WebbyController controller, Map<String, Object?> prompt) async {
  var answered = false;
  void answer(BuildContext dialogContext, {required bool accepted, int accountIndex = -1}) {
    if (answered) return;
    answered = true;
    controller.respondToWebAuthn(accepted: accepted, accountIndex: accountIndex);
    Navigator.of(dialogContext).pop();
  }

  final rpId = prompt['rpId'] as String? ?? '';
  final isCreate = prompt['type'] == 'create';

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      if (isCreate) {
        final userName = prompt['userName'] as String? ?? '';
        final displayName = prompt['userDisplayName'] as String? ?? '';
        final account = displayName.isNotEmpty && displayName != userName ? '$displayName ($userName)' : userName;
        if (prompt['alreadyRegistered'] == true) {
          return AlertDialog(
            icon: const Icon(Icons.key),
            title: const Text('Passkey already saved'),
            content: Text('This browser already has a passkey for your account on $rpId.'),
            actions: [
              TextButton(onPressed: () => answer(dialogContext, accepted: false), child: const Text('Cancel')),
              FilledButton(onPressed: () => answer(dialogContext, accepted: true), child: const Text('OK')),
            ],
          );
        }
        return AlertDialog(
          icon: const Icon(Icons.key),
          title: const Text('Create a passkey?'),
          content: Text.rich(TextSpan(children: [
            const TextSpan(text: 'Save a passkey for '),
            TextSpan(text: account.isEmpty ? 'your account' : account, style: const TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(text: ' on '),
            TextSpan(text: rpId, style: const TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(text: '. It stays in this browser and signs you in without a password.'),
          ])),
          actions: [
            TextButton(onPressed: () => answer(dialogContext, accepted: false), child: const Text('Cancel')),
            FilledButton(onPressed: () => answer(dialogContext, accepted: true), child: const Text('Create')),
          ],
        );
      }

      final accounts = (prompt['accounts'] as List<Object?>? ?? const []).cast<Map<String, Object?>>();
      if (accounts.isEmpty) {
        return AlertDialog(
          icon: const Icon(Icons.key_off),
          title: const Text('No passkeys'),
          content: Text('This browser has no passkeys for $rpId.'),
          actions: [
            FilledButton(onPressed: () => answer(dialogContext, accepted: false), child: const Text('OK')),
          ],
        );
      }
      return AlertDialog(
        icon: const Icon(Icons.key),
        title: Text('Sign in to $rpId'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (index, account) in accounts.indexed)
                ListTile(
                  leading: const Icon(Icons.account_circle),
                  title: Text((account['userDisplayName'] as String?)?.isNotEmpty == true
                      ? account['userDisplayName'] as String
                      : account['userName'] as String? ?? ''),
                  subtitle: Text(account['userName'] as String? ?? '', style: theme.textTheme.bodySmall),
                  onTap: () => answer(dialogContext, accepted: true, accountIndex: index),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => answer(dialogContext, accepted: false), child: const Text('Cancel')),
        ],
      );
    },
  );

  // Dismissed with Escape or a click outside.
  if (!answered) controller.respondToWebAuthn(accepted: false);
}
