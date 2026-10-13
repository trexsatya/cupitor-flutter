import 'dart:async';
import 'dart:convert';

import 'package:cupitor/account/device_signin_dialog.dart';
import 'package:cupitor/account/github_device_signin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _code = {
  'device_code': 'dc-1', 'user_code': 'ABCD-1234',
  'verification_uri': 'https://github.com/login/device', 'expires_in': 899, 'interval': 5,
};

/// A GitHub that hands out the code, then answers the token endpoint with
/// `tokenReplies` in order (repeating the last).
http.Client github(List<Map<String, Object?>> tokenReplies) {
  var i = 0;
  return MockClient((req) async {
    if (req.url.path == '/login/device/code') return http.Response(jsonEncode(_code), 200);
    final r = tokenReplies[i < tokenReplies.length ? i : tokenReplies.length - 1];
    i++;
    return http.Response(jsonEncode(r), 200);
  });
}

/// A few frames with time passing. The dialog shows an indeterminate
/// spinner, so pumpAndSettle would never settle; bounded pumps are enough
/// for the MockClient futures and setStates to land.
Future<void> pumps(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps a page with one button that opens the dialog; returns the dialog's
/// future and the URIs the dialog asked to open.
Future<({Future<String?> result, List<Uri> opened})> open(WidgetTester tester, GitHubDeviceSignIn flow) async {
  final opened = <Uri>[];
  final done = Completer<String?>();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () async {
          done.complete(await showDeviceSignInDialog(ctx, flow: flow, launch: (u) async { opened.add(u); return true; }));
        },
        child: const Text('go'),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await pumps(tester);
  return (result: done.future, opened: opened);
}

void main() {
  testWidgets('shows the user code, opens GitHub, and returns the token', (tester) async {
    final gate = Completer<void>();
    final flow = GitHubDeviceSignIn(client: github([{'error': 'authorization_pending'}, {'access_token': 'ghu_x'}]), sleep: (_) => gate.future);
    final o = await open(tester, flow);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Open GitHub'));
    await tester.pump();
    expect(o.opened.single.toString(), 'https://github.com/login/device');
    gate.complete();
    await pumps(tester);
    expect(await o.result, 'ghu_x');
    await pumps(tester, 20); // the dialog's exit animation
    expect(find.text('ABCD-1234'), findsNothing);
  });

  testWidgets('Cancel closes with null', (tester) async {
    final gate = Completer<void>();
    final flow = GitHubDeviceSignIn(client: github([{'error': 'authorization_pending'}]), sleep: (_) => gate.future);
    final o = await open(tester, flow);
    await tester.tap(find.text('Cancel'));
    await pumps(tester);
    expect(await o.result, isNull);
    gate.complete(); // lets the abandoned poll finish (it sees _cancelled and stops)
    await pumps(tester);
  });

  testWidgets('a declined sign-in shows the reason and offers Retry', (tester) async {
    var round = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/login/device/code') return http.Response(jsonEncode(_code), 200);
      round++;
      return http.Response(jsonEncode(round == 1 ? {'error': 'access_denied'} : {'access_token': 'ghu_second'}), 200);
    });
    final flow = GitHubDeviceSignIn(client: client, sleep: (_) async {});
    final o = await open(tester, flow);
    expect(find.text('GitHub sign-in was declined.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await pumps(tester);
    expect(await o.result, 'ghu_second');
  });

  testWidgets('an unexpected failure still lands on the error with Retry, not a stuck spinner', (tester) async {
    final client = MockClient((req) async => http.Response(jsonEncode({..._code, 'verification_uri': 5}), 200));
    final flow = GitHubDeviceSignIn(client: client, sleep: (_) async {});
    await open(tester, flow);
    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumps(tester, 20);
  });
}
