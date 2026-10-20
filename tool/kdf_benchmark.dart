// Measures master-password KDF cost so future parameter changes can be
// judged against a number instead of a guess.
//
//   dart run tool/kdf_benchmark.dart
//
// This is a development tool, not a test: wall-clock timing on a shared
// machine is too noisy to assert on, and the result depends on the CPU.
// Commit the numbers you measured into ADR-001 when you change Argon2id
// parameters, so the next person can see what the change actually cost.
import 'package:cryptography/cryptography.dart';

/// Keeps the benchmark honest: the cost is dominated by memory x
/// iterations, and these are the parameters ADR-001 currently specifies.
const int memoryKiB = 65536;
const int parallelism = 1;
const int iterations = 3;

const String password = 'un-corrector-de-caballo';
const List<int> salt = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

Future<void> oneArgon2idRun({required int hashLength}) async {
  await Argon2id(
    memory: memoryKiB,
    parallelism: parallelism,
    iterations: iterations,
    hashLength: hashLength,
  ).deriveKeyFromPassword(password: password, nonce: salt);
}

/// Runs [body] [runs] times after a warm-up and returns every sample.
Future<List<int>> sample(Future<void> Function() body, int repeats) async {
  await body(); // warm up so JIT cost is not attributed to the first sample
  final samples = <int>[];
  for (var i = 0; i < repeats; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    samples.add(sw.elapsedMilliseconds);
  }
  samples.sort();
  return samples;
}

String median(List<int> sortedSamples) =>
    sortedSamples[sortedSamples.length ~/ 2].toString();

Future<void> main() async {
  // ignore: avoid_print
  print('Argon2id: ${memoryKiB ~/ 1024} MiB x $iterations, p=$parallelism');

  final single = await sample(
    () => oneArgon2idRun(hashLength: 32),
    5,
  );
  // ignore: avoid_print
  print('  1 run  (v3 record, 32 B out): ${median(single)} ms');

  final double64 = await sample(
    () => oneArgon2idRun(hashLength: 64),
    5,
  );
  // ignore: avoid_print
  print('  1 run  (v3 record, 64 B out): ${median(double64)} ms');

  Future<void> twoRuns() async {
    await oneArgon2idRun(hashLength: 32);
    await oneArgon2idRun(hashLength: 32);
  }

  final twice = await sample(twoRuns, 5);
  // ignore: avoid_print
  print('  2 runs (v2 record, 32 B out): ${median(twice)} ms');

  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print(
    'Going from two runs to one is the whole v3 win. Output length costs '
    'nothing (${median(double64)} ms vs ${median(single)} ms), which is why '
    'the split buys a cheaper unlock without weakening the KDF.',
  );
}