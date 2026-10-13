import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'github_device_signin.dart';

typedef LaunchUrl = Future<bool> Function(Uri uri);

/// Native GitHub sign-in: shows the one-time code, opens
/// github.com/login/device, and resolves to the token once GitHub approves.
/// Resolves to null when the user cancels. Errors from GitHub (declined,
/// expired, offline) are shown in the dialog with a Retry.
Future<String?> showDeviceSignInDialog(BuildContext context, {GitHubDeviceSignIn? flow, LaunchUrl? launch}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeviceSignInDialog(
      flow: flow ?? GitHubDeviceSignIn(),
      launch: launch ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication)),
    ),
  );
}

class DeviceSignInDialog extends StatefulWidget {
  final GitHubDeviceSignIn flow;
  final LaunchUrl launch;
  const DeviceSignInDialog({super.key, required this.flow, required this.launch});

  @override
  State<DeviceSignInDialog> createState() => _DeviceSignInDialogState();
}

class _DeviceSignInDialogState extends State<DeviceSignInDialog> {
  DeviceCode? _code;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() { _code = null; _error = null; });
    try {
      final code = await widget.flow.requestCode();
      if (!mounted || _cancelled) return;
      setState(() => _code = code);
      final token = await widget.flow.pollForToken(code, cancelled: () => _cancelled);
      if (!mounted || _cancelled) return;
      Navigator.of(context).pop(token);
    } on DeviceSignInException catch (e) {
      if (!mounted || _cancelled) return;
      setState(() => _error = switch (e.code) {
            'denied' => 'GitHub sign-in was declined.',
            'expired' => 'The code expired. Try again.',
            'network' => 'Could not reach GitHub. Check the connection and retry.',
            _ => 'Sign-in failed: ${e.message}',
          });
    } catch (e) {
      // Anything else (e.g. a malformed reply) must not leave the spinner up forever.
      if (!mounted || _cancelled) return;
      setState(() => _error = 'Sign-in failed: $e');
    }
  }

  void _cancel() {
    _cancelled = true;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final error = _error;
    Widget body;
    if (error != null) {
      body = Text(error);
    } else if (code == null) {
      body = const Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Asking GitHub for a code…'),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Enter this code on GitHub, then approve the Cupitor app:'),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            code.userCode,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open GitHub'),
            onPressed: () => widget.launch(Uri.parse(code.verificationUri)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy code'),
            onPressed: () => Clipboard.setData(ClipboardData(text: code.userCode)),
          ),
        ]),
        const SizedBox(height: 12),
        const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Waiting for approval…'),
        ]),
      ]);
    }
    return AlertDialog(
      title: const Text('Sign in with GitHub'),
      content: body,
      actions: [
        if (error != null) TextButton(onPressed: _start, child: const Text('Retry')),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }
}
