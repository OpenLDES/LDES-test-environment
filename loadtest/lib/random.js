/**
 * Deterministic pseudo random number generator.
 *
 * The seed data and the generated members must be reproducible: the load test, the seeding run
 * and the PostgreSQL quality checks all have to agree on which member identifiers exist. k6's own
 * `randomSeed()` only seeds the global generator, which is shared between virtual users, so the
 * reference data is built with an explicit, independent generator instead.
 */

export function mulberry32(seed) {
  let a = seed >>> 0;

  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function pick(random, values) {
  return values[Math.floor(random() * values.length) % values.length];
}

export function between(random, minimum, maximum, decimals) {
  const value = minimum + random() * (maximum - minimum);
  return decimals === undefined ? value : Number(value.toFixed(decimals));
}

export function integerBetween(random, minimum, maximum) {
  return minimum + Math.floor(random() * (maximum - minimum + 1));
}

export function pad(value, length) {
  return String(value).padStart(length, '0');
}
