import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ToolsTimerState { ready, running, paused, finished }

class ToolsTimer extends ChangeNotifier {
  ToolsTimer({required this.onFinish, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final VoidCallback onFinish;
  final DateTime Function() _now;
  DateTime? _deadline;
  Timer? _ticker;
  Duration _duration = const Duration(minutes: 15);
  Duration _remaining = const Duration(minutes: 15);
  ToolsTimerState _state = ToolsTimerState.ready;

  ToolsTimerState get state => _state;
  Duration get duration => _duration;
  Duration get remaining => _remaining;

  static String format(Duration value) {
    final seconds = (value.inMilliseconds + 999) ~/ 1000;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void start(Duration duration) {
    if (duration <= Duration.zero || _state == ToolsTimerState.running) return;
    _duration = _remaining = duration;
    resume();
  }

  void resume() {
    if (_state == ToolsTimerState.running || _remaining <= Duration.zero) {
      return;
    }
    _state = ToolsTimerState.running;
    _deadline = _now().add(_remaining);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => refresh(),
    );
    notifyListeners();
  }

  void refresh() {
    final deadline = _deadline;
    if (deadline == null) return;
    final previous = format(_remaining);
    final remaining = deadline.difference(_now());
    _remaining = remaining.isNegative ? Duration.zero : remaining;
    if (_remaining == Duration.zero) {
      _stopTicker();
      _state = ToolsTimerState.finished;
      notifyListeners();
      onFinish();
    } else if (previous != format(_remaining)) {
      notifyListeners();
    }
  }

  void pause() {
    if (_state != ToolsTimerState.running) return;
    refresh();
    if (_state != ToolsTimerState.running) return;
    _stopTicker();
    _state = ToolsTimerState.paused;
    notifyListeners();
  }

  void reset() {
    _stopTicker();
    _state = ToolsTimerState.ready;
    _remaining = _duration;
    notifyListeners();
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}

class ToolsTimerSheet extends StatefulWidget {
  const ToolsTimerSheet({super.key, required this.timer, required this.onBack});

  final ToolsTimer timer;
  final VoidCallback onBack;

  @override
  State<ToolsTimerSheet> createState() => _ToolsTimerSheetState();
}

class _ToolsTimerSheetState extends State<ToolsTimerSheet> {
  late final _minutes = TextEditingController(
    text: widget.timer.duration.inMinutes.toString(),
  );
  late final _seconds = TextEditingController(
    text: (widget.timer.duration.inSeconds % 60).toString().padLeft(2, '0'),
  );
  String? _error;

  @override
  void dispose() {
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  void _start() {
    final minutes = int.tryParse(_minutes.text) ?? 0;
    final seconds = int.tryParse(_seconds.text) ?? 0;
    if (seconds > 59 || minutes + seconds == 0) {
      setState(() {
        _error = seconds > 59
            ? 'Enter seconds from 0 to 59.'
            : 'Enter a duration of at least one second.';
      });
      return;
    }
    FocusScope.of(context).unfocus();
    widget.timer.start(Duration(minutes: minutes, seconds: seconds));
  }

  Widget _durationField(
    String label,
    TextEditingController controller,
    int digits,
  ) {
    return SizedBox(
      width: 93,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        style: Theme.of(context).textTheme.headlineMedium,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(digits),
        ],
        onChanged: (_) => setState(() => _error = null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timer = widget.timer;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: ListenableBuilder(
                  listenable: timer,
                  builder: (context, _) {
                    final ready = timer.state == ToolsTimerState.ready;
                    final (label, action) = switch (timer.state) {
                      ToolsTimerState.ready => ('Start', _start),
                      ToolsTimerState.running => ('Pause', timer.pause),
                      ToolsTimerState.paused => ('Resume', timer.resume),
                      ToolsTimerState.finished => (
                        'Start again',
                        () => timer.start(timer.duration),
                      ),
                    };
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Back to Tools',
                              icon: const Icon(Icons.arrow_back),
                              onPressed: widget.onBack,
                            ),
                            Text('Timer', style: theme.textTheme.titleLarge),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Close timer',
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                        const Divider(),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: ready
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _durationField('Minutes', _minutes, 3),
                                    Text(
                                      ' : ',
                                      style: theme.textTheme.headlineMedium,
                                    ),
                                    _durationField('Seconds', _seconds, 2),
                                  ],
                                )
                              : Column(
                                  children: [
                                    Text(
                                      ToolsTimer.format(timer.remaining),
                                      semanticsLabel:
                                          'Time remaining ${ToolsTimer.format(timer.remaining)}',
                                      style: theme.textTheme.displaySmall,
                                    ),
                                    Text(switch (timer.state) {
                                      ToolsTimerState.running => 'Running',
                                      ToolsTimerState.paused => 'Paused',
                                      _ => 'Time’s up',
                                    }),
                                  ],
                                ),
                        ),
                        if (ready)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                for (final minutes in [5, 15, 25])
                                  ChoiceChip(
                                    label: Text('$minutes min'),
                                    selected:
                                        int.tryParse(_minutes.text) ==
                                            minutes &&
                                        (int.tryParse(_seconds.text) ?? 0) == 0,
                                    onSelected: (_) => setState(() {
                                      _minutes.text = '$minutes';
                                      _seconds.text = '00';
                                      _error = null;
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        if (ready && _error != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (!ready)
                              TextButton(
                                onPressed: timer.reset,
                                child: const Text('Reset'),
                              ),
                            Expanded(
                              child: FilledButton(
                                onPressed: action,
                                child: Text(label),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
