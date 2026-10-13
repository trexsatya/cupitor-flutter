import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/page_loading.dart';

void main() {
  late PageLoading loading;
  setUp(() => loading = PageLoading());

  test('not loading until a page starts', () {
    expect(loading.value, isFalse);
  });

  test('a started page loads until it finishes', () {
    loading.started();
    expect(loading.value, isTrue);
    loading.finished();
    expect(loading.value, isFalse);
  });

  test('a main-frame failure ends the load', () {
    loading.started();
    loading.failed(isMainFrame: true);
    expect(loading.value, isFalse);
  });

  test('a sub-resource failure does not end the load', () {
    loading.started();
    loading.failed(isMainFrame: false);
    expect(loading.value, isTrue);
  });

  test('progress ends the load only at 100', () {
    loading.started();
    loading.progress(60);
    expect(loading.value, isTrue);
    loading.progress(100);
    expect(loading.value, isFalse);
  });

  test('updates after dispose are ignored', () {
    final l = PageLoading()..started();
    l.dispose();
    expect(() => l.finished(), returnsNormally);
    expect(() => l.started(), returnsNormally);
  });

  test('a new page after a finished one loads again', () {
    loading.started();
    loading.finished();
    loading.started();
    expect(loading.value, isTrue);
  });
}
