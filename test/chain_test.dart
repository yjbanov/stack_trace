// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library chain_test;

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';
import 'package:unittest/unittest.dart';

import 'utils.dart';

void main() {
  group('capture() with onError catches exceptions', () {
    test('thrown synchronously', () {
      return captureFuture(() => throw 'error')
          .then((chain) {
        expect(chain.traces, hasLength(1));
        expect(chain.traces.single.frames.first,
            frameMember(startsWith('main')));
      });
    });

    test('thrown in a microtask', () {
      return captureFuture(() => inMicrotask(() => throw 'error'))
          .then((chain) {
        // Since there was only one asynchronous operation, there should be only
        // two traces in the chain.
        expect(chain.traces, hasLength(2));

        // The first frame of the first trace should be the line on which the
        // actual error was thrown.
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));

        // The second trace should describe the stack when the error callback
        // was scheduled.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('thrown in a one-shot timer', () {
      return captureFuture(() => inOneShotTimer(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('thrown in a periodic timer', () {
      return captureFuture(() => inPeriodicTimer(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('thrown in a nested series of asynchronous operations', () {
      return captureFuture(() {
        inPeriodicTimer(() {
          inOneShotTimer(() => inMicrotask(() => throw 'error'));
        });
      }).then((chain) {
        expect(chain.traces, hasLength(4));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('thrown in a long future chain', () {
      return captureFuture(() => inFutureChain(() => throw 'error'))
          .then((chain) {
        // Despite many asynchronous operations, there's only one level of
        // nested calls, so there should be only two traces in the chain. This
        // is important; programmers expect stack trace memory consumption to be
        // O(depth of program), not O(length of program).
        expect(chain.traces, hasLength(2));

        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });

    test('thrown in new Future()', () {
      return captureFuture(() => inNewFuture(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));

        // The second trace is the one captured by
        // [StackZoneSpecification.errorCallback]. Because that runs
        // asynchronously within [new Future], it doesn't actually refer to the
        // source file at all.
        expect(chain.traces[1].frames,
            everyElement(frameLibrary(isNot(contains('chain_test')))));

        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inNewFuture'))));
      });
    });

    test('thrown in new Future.sync()', () {
      return captureFuture(() {
        inMicrotask(() => inSyncFuture(() => throw 'error'));
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inSyncFuture'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('multiple times', () {
      var completer = new Completer();
      var first = true;

      Chain.capture(() {
        inMicrotask(() => throw 'first error');
        inPeriodicTimer(() => throw 'second error');
      }, onError: (error, chain) {
        try {
          if (first) {
            expect(error, equals('first error'));
            expect(chain.traces[1].frames,
                contains(frameMember(startsWith('inMicrotask'))));
            first = false;
          } else {
            expect(error, equals('second error'));
            expect(chain.traces[1].frames,
                contains(frameMember(startsWith('inPeriodicTimer'))));
            completer.complete();
          }
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      });

      return completer.future;
    });

    test('passed to a completer', () {
      var trace = new Trace.current();
      return captureFuture(() {
        inMicrotask(() => completerErrorFuture(trace));
      }).then((chain) {
        expect(chain.traces, hasLength(3));

        // The first trace is the trace that was manually reported for the
        // error.
        expect(chain.traces.first.toString(), equals(trace.toString()));

        // The second trace is the trace that was captured when
        // [Completer.addError] was called.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('completerErrorFuture'))));

        // The third trace is the automatically-captured trace from when the
        // microtask was scheduled.
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a completer with no stack trace', () {
      return captureFuture(() {
        inMicrotask(() => completerErrorFuture());
      }).then((chain) {
        expect(chain.traces, hasLength(2));

        // The first trace is the one captured when [Completer.addError] was
        // called.
        expect(chain.traces[0].frames,
            contains(frameMember(startsWith('completerErrorFuture'))));

        // The second trace is the automatically-captured trace from when the
        // microtask was scheduled.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a stream controller', () {
      var trace = new Trace.current();
      return captureFuture(() {
        inMicrotask(() => controllerErrorStream(trace).listen(null));
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces.first.toString(), equals(trace.toString()));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('controllerErrorStream'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a stream controller with no stack trace', () {
      return captureFuture(() {
        inMicrotask(() => controllerErrorStream().listen(null));
      }).then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames,
            contains(frameMember(startsWith('controllerErrorStream'))));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('and relays them to the parent zone', () {
      var completer = new Completer();

      runZoned(() {
        Chain.capture(() {
          inMicrotask(() => throw 'error');
        }, onError: (error, chain) {
          expect(error, equals('error'));
          expect(chain.traces[1].frames,
              contains(frameMember(startsWith('inMicrotask'))));
          throw error;
        });
      }, onError: (error, chain) {
        try {
          expect(error, equals('error'));
          expect(chain, new isInstanceOf<Chain>());
          expect(chain.traces[1].frames,
              contains(frameMember(startsWith('inMicrotask'))));
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      });

      return completer.future;
    });
  });

  test('capture() without onError passes exceptions to parent zone', () {
    var completer = new Completer();

    runZoned(() {
      Chain.capture(() => inMicrotask(() => throw 'error'));
    }, onError: (error, chain) {
      try {
        expect(error, equals('error'));
        expect(chain, new isInstanceOf<Chain>());
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  });

  group('current() within capture()', () {
    test('called in a microtask', () {
      var completer = new Completer();
      Chain.capture(() {
        inMicrotask(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('called in a one-shot timer', () {
      var completer = new Completer();
      Chain.capture(() {
        inOneShotTimer(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('called in a periodic timer', () {
      var completer = new Completer();
      Chain.capture(() {
        inPeriodicTimer(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called in a nested series of asynchronous operations', () {
      var completer = new Completer();
      Chain.capture(() {
        inPeriodicTimer(() {
          inOneShotTimer(() {
            inMicrotask(() => completer.complete(new Chain.current()));
          });
        });
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(4));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called in a long future chain', () {
      var completer = new Completer();
      Chain.capture(() {
        inFutureChain(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });
  });

  test('current() outside of capture() returns a chain wrapping the current '
      'trace', () {
    var completer = new Completer();
    inMicrotask(() => completer.complete(new Chain.current()));

    return completer.future.then((chain) {
      // Since the chain wasn't loaded within [Chain.capture], the full stack
      // chain isn't available and it just returns the current stack when
      // called.
      expect(chain.traces, hasLength(1));
      expect(chain.traces.first.frames.first, frameMember(startsWith('main')));
    });
  });

  group('forTrace() within capture()', () {
    test('called for a stack trace from a microtask', () {
      return Chain.capture(() {
        return chainForTrace(inMicrotask, () => throw 'error');
      }).then((chain) {
        // Because [chainForTrace] has to set up a future chain to capture the
        // stack trace while still showing it to the zone specification, it adds
        // an additional level of async nesting and so an additional trace.
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('called for a stack trace from a one-shot timer', () {
      return Chain.capture(() {
        return chainForTrace(inOneShotTimer, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('called for a stack trace from a periodic timer', () {
      return Chain.capture(() {
        return chainForTrace(inPeriodicTimer, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called for a stack trace from a nested series of asynchronous '
        'operations', () {
      return Chain.capture(() {
        return chainForTrace((callback) {
          inPeriodicTimer(() => inOneShotTimer(() => inMicrotask(callback)));
        }, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(5));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[4].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called for a stack trace from a long future chain', () {
      return Chain.capture(() {
        return chainForTrace(inFutureChain, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });

    test('called for an unregistered stack trace returns a chain wrapping that '
        'trace', () {
      var trace;
      var chain = Chain.capture(() {
        try {
          throw 'error';
        } catch (_, stackTrace) {
          trace = stackTrace;
          return new Chain.forTrace(stackTrace);
        }
      });

      expect(chain.traces, hasLength(1));
      expect(chain.traces.first.toString(),
          equals(new Trace.from(trace).toString()));
    });
  });

  test('forTrace() outside of capture() returns a chain wrapping the given '
      'trace', () {
    var trace;
    var chain = Chain.capture(() {
      try {
        throw 'error';
      } catch (_, stackTrace) {
        trace = stackTrace;
        return new Chain.forTrace(stackTrace);
      }
    });

    expect(chain.traces, hasLength(1));
    expect(chain.traces.first.toString(),
        equals(new Trace.from(trace).toString()));
  });

  group('Chain.parse()', () {
    test('parses a real Chain', () {
      return captureFuture(() => inMicrotask(() => throw 'error'))
          .then((chain) {
        expect(new Chain.parse(chain.toString()).toString(),
            equals(chain.toString()));
      });
    });

    test('parses an empty string', () {
      var chain = new Chain.parse('');
      expect(chain.traces, isEmpty);
    });

    test('parses a chain containing empty traces', () {
      var chain = new Chain.parse(
          '===== asynchronous gap ===========================\n'
          '===== asynchronous gap ===========================\n');
      expect(chain.traces, hasLength(3));
      expect(chain.traces[0].frames, isEmpty);
      expect(chain.traces[1].frames, isEmpty);
      expect(chain.traces[2].frames, isEmpty);
    });
  });

  test("toString() ensures that all traces are aligned", () {
    var chain = new Chain([
      new Trace.parse('short 10:11  Foo.bar\n'),
      new Trace.parse('loooooooooooong 10:11  Zop.zoop')
    ]);

    expect(chain.toString(), equals(
        'short 10:11            Foo.bar\n'
        '===== asynchronous gap ===========================\n'
        'loooooooooooong 10:11  Zop.zoop\n'));
  });

  var userSlashCode = p.join('user', 'code.dart');
  group('Chain.terse', () {
    test('makes each trace terse', () {
      var chain = new Chain([
        new Trace.parse(
            'dart:core 10:11       Foo.bar\n'
            'dart:core 10:11       Bar.baz\n'
            'user/code.dart 10:11  Bang.qux\n'
            'dart:core 10:11       Zip.zap\n'
            'dart:core 10:11       Zop.zoop'),
        new Trace.parse(
            'user/code.dart 10:11                        Bang.qux\n'
            'dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap\n'
            'user/code.dart 10:11                        Zop.zoop')
      ]);

      expect(chain.terse.toString(), equals(
          'dart:core             Bar.baz\n'
          '$userSlashCode 10:11  Bang.qux\n'
          '===== asynchronous gap ===========================\n'
          '$userSlashCode 10:11  Bang.qux\n'
          'dart:core             Zip.zap\n'
          '$userSlashCode 10:11  Zop.zoop\n'));
    });

    test('eliminates internal-only traces', () {
      var chain = new Chain([
        new Trace.parse(
            'user/code.dart 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz'),
        new Trace.parse(
            'dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap'),
        new Trace.parse(
            'user/code.dart 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz')
      ]);

      expect(chain.terse.toString(), equals(
          '$userSlashCode 10:11  Foo.bar\n'
          '===== asynchronous gap ===========================\n'
          '$userSlashCode 10:11  Foo.bar\n'));
    });

    test("doesn't return an empty chain", () {
      var chain = new Chain([
        new Trace.parse(
            'dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap'),
        new Trace.parse(
            'dart:core 10:11                             A.b\n'
            'package:stack_trace/stack_trace.dart 10:11  C.d\n'
            'dart:core 10:11                             E.f')
      ]);

      expect(chain.terse.toString(), equals('dart:core  E.f\n'));
    });
  });

  group('Chain.foldFrames', () {
    test('folds each trace', () {
      var chain = new Chain([
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'b.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'a.dart 10:11  Zop.zoop'),
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'a.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(folded.toString(), equals(
          'a.dart 10:11  Bar.baz\n'
          'b.dart 10:11  Bang.qux\n'
          'a.dart 10:11  Zop.zoop\n'
          '===== asynchronous gap ===========================\n'
          'a.dart 10:11  Zip.zap\n'
          'b.dart 10:11  Zop.zoop\n'));
    });

    test('with terse: true, folds core frames as well', () {
      var chain = new Chain([
        new Trace.parse(
            'a.dart 10:11                        Foo.bar\n'
            'dart:async-patch/future.dart 10:11  Zip.zap\n'
            'b.dart 10:11                        Bang.qux\n'
            'dart:core 10:11                     Bar.baz\n'
            'a.dart 10:11                        Zop.zoop'),
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'a.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart',
          terse: true);
      expect(folded.toString(), equals(
          'dart:async    Zip.zap\n'
          'b.dart 10:11  Bang.qux\n'
          'a.dart        Zop.zoop\n'
          '===== asynchronous gap ===========================\n'
          'a.dart        Zip.zap\n'
          'b.dart 10:11  Zop.zoop\n'));
    });

    test('eliminates completely-folded traces', () {
      var chain = new Chain([
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'b.dart 10:11  Bang.qux'),
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bang.qux'),
        new Trace.parse(
            'a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(folded.toString(), equals(
          'a.dart 10:11  Foo.bar\n'
          'b.dart 10:11  Bang.qux\n'
          '===== asynchronous gap ===========================\n'
          'a.dart 10:11  Zip.zap\n'
          'b.dart 10:11  Zop.zoop\n'));
    });

    test("doesn't return an empty trace", () {
      var chain = new Chain([
        new Trace.parse(
            'a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bang.qux')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(folded.toString(), equals('a.dart 10:11  Bang.qux\n'));
    });
  });

  test('Chain.toTrace eliminates asynchronous gaps', () {
    var trace = new Chain([
      new Trace.parse(
          'user/code.dart 10:11  Foo.bar\n'
          'dart:core 10:11       Bar.baz'),
      new Trace.parse(
          'user/code.dart 10:11  Foo.bar\n'
          'dart:core 10:11       Bar.baz')
    ]).toTrace();

    expect(trace.toString(), equals(
        '$userSlashCode 10:11  Foo.bar\n'
        'dart:core 10:11       Bar.baz\n'
        '$userSlashCode 10:11  Foo.bar\n'
        'dart:core 10:11       Bar.baz\n'));
  });

  group('Chain.track(Future)', () {
    test('forwards the future value within Chain.capture()', () {
      Chain.capture(() {
        expect(Chain.track(new Future.value('value')),
            completion(equals('value')));

        var trace = new Trace.current();
        expect(Chain.track(new Future.error('error', trace))
            .catchError((e, stackTrace) {
          expect(e, equals('error'));
          expect(stackTrace.toString(), equals(trace.toString()));
        }), completes);
      });
    });

    test('forwards the future value outside of Chain.capture()', () {
      expect(Chain.track(new Future.value('value')),
          completion(equals('value')));

      var trace = new Trace.current();
      expect(Chain.track(new Future.error('error', trace))
          .catchError((e, stackTrace) {
        expect(e, equals('error'));
        expect(stackTrace.toString(), equals(trace.toString()));
      }), completes);
    });
  });

  group('Chain.track(Stream)', () {
    test('forwards stream values within Chain.capture()', () {
      Chain.capture(() {
        var controller = new StreamController()
            ..add(1)..add(2)..add(3)..close();
        expect(Chain.track(controller.stream).toList(),
            completion(equals([1, 2, 3])));

        var trace = new Trace.current();
        controller = new StreamController()..addError('error', trace);
        expect(Chain.track(controller.stream).toList()
            .catchError((e, stackTrace) {
          expect(e, equals('error'));
          expect(stackTrace.toString(), equals(trace.toString()));
        }), completes);
      });
    });

    test('forwards stream values outside of Chain.capture()', () {
      Chain.capture(() {
        var controller = new StreamController()
            ..add(1)..add(2)..add(3)..close();
        expect(Chain.track(controller.stream).toList(),
            completion(equals([1, 2, 3])));

        var trace = new Trace.current();
        controller = new StreamController()..addError('error', trace);
        expect(Chain.track(controller.stream).toList()
            .catchError((e, stackTrace) {
          expect(e, equals('error'));
          expect(stackTrace.toString(), equals(trace.toString()));
        }), completes);
      });
    });
  });
}

/// Runs [callback] in a microtask callback.
void inMicrotask(callback()) => scheduleMicrotask(callback);

/// Runs [callback] in a one-shot timer callback.
void inOneShotTimer(callback()) => Timer.run(callback);

/// Runs [callback] once in a periodic timer callback.
void inPeriodicTimer(callback()) {
  var count = 0;
  new Timer.periodic(new Duration(milliseconds: 1), (timer) {
    count++;
    if (count != 5) return;
    timer.cancel();
    callback();
  });
}

/// Runs [callback] within a long asynchronous Future chain.
void inFutureChain(callback()) {
  new Future(() {})
      .then((_) => new Future(() {}))
      .then((_) => new Future(() {}))
      .then((_) => new Future(() {}))
      .then((_) => new Future(() {}))
      .then((_) => callback())
      .then((_) => new Future(() {}));
}

void inNewFuture(callback()) {
  new Future(callback);
}

void inSyncFuture(callback()) {
  new Future.sync(callback);
}

/// Returns a Future that completes to an error using a completer.
///
/// If [trace] is passed, it's used as the stack trace for the error.
Future completerErrorFuture([StackTrace trace]) {
  var completer = new Completer();
  completer.completeError('error', trace);
  return completer.future;
}

/// Returns a Stream that emits an error using a controller.
///
/// If [trace] is passed, it's used as the stack trace for the error.
Stream controllerErrorStream([StackTrace trace]) {
  var controller = new StreamController();
  controller.addError('error', trace);
  return controller.stream;
}

/// Runs [callback] within [asyncFn], then converts any errors raised into a
/// [Chain] with [Chain.forTrace].
Future<Chain> chainForTrace(asyncFn(callback()), callback()) {
  var completer = new Completer();
  asyncFn(() {
    // We use `new Future.value().then(...)` here as opposed to [new Future] or
    // [new Future.sync] because those methods don't pass the exception through
    // the zone specification before propagating it, so there's no chance to
    // attach a chain to its stack trace. See issue 15105.
    new Future.value().then((_) => callback())
        .catchError(completer.completeError);
  });
  return completer.future
      .catchError((_, stackTrace) => new Chain.forTrace(stackTrace));
}

/// Runs [callback] in a [Chain.capture] zone and returns a Future that
/// completes to the stack chain for an error thrown by [callback].
///
/// [callback] is expected to throw the string `"error"`.
Future<Chain> captureFuture(callback()) {
  var completer = new Completer<Chain>();
  Chain.capture(callback, onError: (error, chain) {
    expect(error, equals('error'));
    completer.complete(chain);
  });
  return completer.future;
}
