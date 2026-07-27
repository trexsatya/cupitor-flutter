import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notif_list_screen.dart';
import 'package:cupitor/notif/notif_settings.dart';
import 'package:cupitor/notif/notification_manager.dart';
import 'package:cupitor/notif/schedule_editor.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late NotifDao dao;
  int rearms = 0;
  Future<NotifDao?> daoGetter() async => dao;
  Future<void> rearm() async => rearms++;

  setUpAll(() {
    sqfliteFfiInit();
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/New_York'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // No-isolate factory: DB futures resolve on the test event loop, which
    // is what pumpAndSettle can drive (a real isolate hop would deadlock
    // under the fake-async test zone).
    db = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 1,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) async {
              await CupitorDb.createSchema(d);
              await CupitorDb.seedBuiltinSchedules(d);
            }));
    dao = NotifDao(db);
    rearms = 0;
    NotifSettings.window = WakingWindow.defaults;
    NotifSettings.perFireCap = 5;
  });

  tearDown(() => db.close());

  /// Pushes [screen] onto a host route so screens that pop() have somewhere
  /// to pop back to.
  Future<void> pumpPushed(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(builder: (_) => screen)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('ScheduleListScreen / editor', () {
    testWidgets('index lists the 7 built-ins as clonable', (tester) async {
      await pumpPushed(
          tester, ScheduleListScreen(dao: daoGetter, rearm: rearm));
      expect(find.text('Ebbinghaus-anchored'), findsOneWidget);
      expect(find.text('Daily 09:00'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNWidgets(7));
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('editor creates a custom series schedule and rearms',
        (tester) async {
      await pumpPushed(
          tester, ScheduleEditorScreen(dao: daoGetter, rearm: rearm));
      await tester.enterText(find.byType(TextField).first, 'My ladder');
      // Default offsets '1, 4, 17' stand.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final all = await dao.listSchedules();
      final mine = all.where((s) => s.name == 'My ladder').toList();
      expect(mine, hasLength(1));
      expect(mine.single.builtinKey, isNull);
      expect(mine.single.kind, 'series');
      expect(rearms, 1);
      // Saved editor popped back to the host.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('editor blocks non-increasing offsets with a mapped message',
        (tester) async {
      await pumpPushed(
          tester, ScheduleEditorScreen(dao: daoGetter, rearm: rearm));
      await tester.enterText(find.byType(TextField).first, 'Bad');
      await tester.enterText(find.byType(TextField).at(1), '4, 1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('strictly increasing'), findsOneWidget);
      expect((await dao.listSchedules()).where((s) => s.name == 'Bad'),
          isEmpty);
      expect(rearms, 0);
    });

    testWidgets('editor blocks a clock time inside the sleep window',
        (tester) async {
      // Make the default 09:00 chip a sleeping time.
      NotifSettings.window =
          const WakingWindow(startMinutes: 10 * 60, endMinutes: 22 * 60);
      await pumpPushed(
          tester, ScheduleEditorScreen(dao: daoGetter, rearm: rearm));
      await tester.enterText(find.byType(TextField).first, 'Night owl');
      await tester.tap(find.text('Recurring'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('sleep window'), findsOneWidget);
      expect(rearms, 0);
    });
  });

  group('NotificationManagerScreen', () {
    Widget manager({String permission = 'granted'}) =>
        NotificationManagerScreen(
          dao: daoGetter,
          rearm: rearm,
          permissionStatus: () async => permission,
          requestPermission: () async => 'granted',
          profileId: () => 1,
        );

    testWidgets('renders settings and the list index', (tester) async {
      final s = await dao.scheduleByKey('ebbinghaus');
      final l = await dao.createList(
          profileId: 1, name: 'French B2', source: 'app', scheduleId: s!.id);
      await dao.insertItem(listId: l.id, title: 'a', position: 0);
      await dao.insertItem(listId: l.id, title: 'b', position: 1);

      await pumpPushed(tester, manager());
      expect(find.text('Waking window'), findsOneWidget);
      expect(find.textContaining('05:00'), findsOneWidget);
      expect(find.text('French B2'), findsOneWidget);
      expect(find.textContaining('2 items'), findsOneWidget);
      expect(find.byType(MaterialBanner), findsNothing);
    });

    testWidgets('denied permission shows the banner; Enable re-requests',
        (tester) async {
      await pumpPushed(tester, manager(permission: 'denied'));
      expect(find.byType(MaterialBanner), findsOneWidget);
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();
      expect(rearms, 1);
    });

    testWidgets('per-fire cap stepper persists and rearms', (tester) async {
      await pumpPushed(tester, manager());
      await tester.tap(find.descendant(
          of: find.widgetWithText(ListTile, 'Max notifications per fire'),
          matching: find.byIcon(Icons.add)));
      await tester.pumpAndSettle();
      expect(NotifSettings.perFireCap, 6);
      expect(rearms, 1);
    });
  });

  group('NotifListScreen', () {
    testWidgets('shows step/due, adds an item on the first rung',
        (tester) async {
      final s = await dao.scheduleByKey('cepeda2x');
      final l = await dao.createList(
          profileId: 1, name: 'Deck', source: 'app', scheduleId: s!.id);
      await dao.insertItem(
          listId: l.id, title: 'existing', position: 0, step: 2,
          nextDueAt: DateTime.now()
              .add(const Duration(hours: 3))
              .millisecondsSinceEpoch);

      await pumpPushed(tester,
          NotifListScreen(listId: l.id, dao: daoGetter, rearm: rearm));
      expect(find.textContaining('step 3'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'fresh');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final items = await dao.itemsForList(l.id);
      expect(items, hasLength(2));
      final fresh = items.singleWhere((i) => i.title == 'fresh');
      expect(fresh.step, 0);
      expect(fresh.nextDueAt, isNotNull); // first ladder rung
      expect(rearms, 1);
    });

    testWidgets('reset to start via the item menu', (tester) async {
      final s = await dao.scheduleByKey('cepeda2x');
      final l = await dao.createList(
          profileId: 1, name: 'Deck', source: 'app', scheduleId: s!.id);
      final it = await dao.insertItem(
          listId: l.id, title: 'worn', position: 0, step: 4, nextDueAt: 1);
      await dao.updateItem(it.id, {'status': 'done'});

      await pumpPushed(tester,
          NotifListScreen(listId: l.id, dao: daoGetter, rearm: rearm));
      await tester.tap(find.descendant(
          of: find.byType(ListTile),
          matching: find.byType(PopupMenuButton<String>)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to start'));
      await tester.pumpAndSettle();

      final re = await dao.itemById(it.id);
      expect(re!.step, 0);
      expect(re.status, 'active');
      expect(rearms, 1);
    });

    testWidgets('intro list: added item is queued unseeded and arms cadence',
        (tester) async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'Drip', source: 'app',
          scheduleId: series!.id, introScheduleId: intro!.id);

      await pumpPushed(tester,
          NotifListScreen(listId: l.id, dao: daoGetter, rearm: rearm));
      expect(find.textContaining('intro:'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'queued one');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final item = (await dao.itemsForList(l.id)).single;
      expect(item.nextDueAt, isNull); // waiting for the intro cadence
      expect((await dao.listById(l.id))!.nextFireAt, isNotNull); // armed
      expect(find.text('queued for introduction'), findsOneWidget);
    });

    testWidgets('dao-null shows the unsupported notice, not a spinner',
        (tester) async {
      await pumpPushed(tester,
          NotifListScreen(listId: 1, dao: () async => null, rearm: rearm));
      expect(find.textContaining('not available'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('delete item asks for confirmation first', (tester) async {
      final s = await dao.scheduleByKey('cepeda2x');
      final l = await dao.createList(
          profileId: 1, name: 'Deck', source: 'app', scheduleId: s!.id);
      final it = await dao.insertItem(
          listId: l.id, title: 'doomed', position: 0);

      await pumpPushed(tester,
          NotifListScreen(listId: l.id, dao: daoGetter, rearm: rearm));
      await tester.tap(find.descendant(
          of: find.byType(ListTile),
          matching: find.byType(PopupMenuButton<String>)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // Confirm dialog appeared; cancel keeps the item.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await dao.itemById(it.id), isNotNull);
      expect(rearms, 0);
    });

    testWidgets('pause via the list menu', (tester) async {
      final s = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'Deck', source: 'app', scheduleId: s!.id,
          nextFireAt: 1);

      await pumpPushed(tester,
          NotifListScreen(listId: l.id, dao: daoGetter, rearm: rearm));
      await tester.tap(find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(PopupMenuButton<String>)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();

      expect((await dao.listById(l.id))!.status, 'paused');
      expect(rearms, 1);
    });
  });
}
