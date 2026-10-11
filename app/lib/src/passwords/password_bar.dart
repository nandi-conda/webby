import 'package:flutter/material.dart';

import 'password_manager.dart';

/// The strip above the page that offers to save or fill a password.
class PasswordBar extends StatelessWidget {
  const PasswordBar({super.key, required this.agent});

  final PasswordAgent agent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: agent,
      builder: (context, _) {
        final offer = agent.offer;
        if (offer == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final host = Uri.parse(offer.origin).host;
        final bold = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold);

        final (Widget message, List<Widget> actions) = switch (offer) {
          SaveOffer() => (
              Text.rich(TextSpan(children: [
                TextSpan(text: offer.existing != null ? 'Update the saved password for ' : 'Save the password for '),
                TextSpan(text: offer.username.isEmpty ? 'this account' : offer.username, style: bold),
                const TextSpan(text: ' on '),
                TextSpan(text: host, style: bold),
                const TextSpan(text: '?'),
              ])),
              [
                if (offer.existing == null)
                  TextButton(onPressed: () => agent.neverSave(offer), child: const Text('Never for this site')),
                TextButton(onPressed: agent.dismiss, child: const Text('Not now')),
                FilledButton(
                  onPressed: () => agent.save(offer),
                  child: Text(offer.existing != null ? 'Update' : 'Save'),
                ),
              ],
            ),
          GenerateOffer() => (
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'Use a strong password  '),
                TextSpan(text: offer.password, style: bold?.copyWith(fontFamily: 'monospace')),
              ])),
              [
                IconButton(
                  tooltip: 'Another one',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => agent.regenerate(offer),
                ),
                TextButton(onPressed: agent.dismiss, child: const Text('No thanks')),
                FilledButton(onPressed: () => agent.useGenerated(offer), child: const Text('Use password')),
              ],
            ),
          FillOffer() => (
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'Fill a saved password for '),
                TextSpan(text: host, style: bold),
              ])),
              [
                for (final account in offer.accounts.take(4))
                  ActionChip(
                    avatar: const Icon(Icons.account_circle, size: 18),
                    label: Text(account.username.isEmpty ? '(no username)' : account.username),
                    onPressed: () => agent.fill(account),
                  ),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: agent.dismiss),
              ],
            ),
        };

        return Material(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.key, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(child: message),
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              ],
            ),
          ),
        );
      },
    );
  }
}
