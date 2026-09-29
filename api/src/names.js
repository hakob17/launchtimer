// Driver handles are generated ("Crimson Falcon 42"), never typed, so the boards carry no
// free-text names. The app uses the same lists (Sources/Leaderboard.swift).
export const ADJECTIVES = [
  'Amber', 'Arctic', 'Atomic', 'Blazing', 'Bold', 'Cobalt', 'Cosmic', 'Crimson', 'Electric', 'Emerald',
  'Fierce', 'Golden', 'Granite', 'Hyper', 'Iron', 'Jade', 'Lunar', 'Midnight', 'Neon', 'Nitro',
  'Obsidian', 'Onyx', 'Quantum', 'Rapid', 'Rocket', 'Scarlet', 'Silver', 'Solar', 'Sonic', 'Stealth',
  'Storm', 'Swift', 'Thunder', 'Titan', 'Turbo', 'Velvet', 'Violet', 'Volt', 'Wild', 'Zen',
];
export const ANIMALS = [
  'Badger', 'Bison', 'Cheetah', 'Cobra', 'Condor', 'Coyote', 'Dragon', 'Eagle', 'Falcon', 'Ferret',
  'Fox', 'Gazelle', 'Hawk', 'Hornet', 'Jaguar', 'Kestrel', 'Lynx', 'Mako', 'Mamba', 'Marlin',
  'Mustang', 'Orca', 'Osprey', 'Otter', 'Panther', 'Puma', 'Raptor', 'Raven', 'Rhino', 'Shark',
  'Stallion', 'Stingray', 'Tiger', 'Viper', 'Wasp', 'Wolf', 'Wolverine', 'Yak', 'Zebra', 'Kraken',
];

export function validHandle(handle) {
  const m = /^([A-Z][a-z]+) ([A-Z][a-z]+) (\d{1,3})$/.exec(String(handle));
  return !!m && ADJECTIVES.includes(m[1]) && ANIMALS.includes(m[2]);
}

// Car names come from a picker (NHTSA's vehicle list), but a trim is typed, so keep it short,
// plain, and free of obvious abuse. Anything that slips through can be reported.
const BLOCKED = /(fuck|shit|cunt|nigg|fag|bitch|whore|slut|nazi|hitler|rape|porn|penis|pussy)/i;
export function cleanCarText(value, max) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length > max || !/^[\p{L}\p{N} .+\-/&()']*$/u.test(s)) throw new Error('car text has characters that aren\'t allowed');
  if (BLOCKED.test(s.replace(/[^a-z]/gi, ''))) throw new Error('car text isn\'t allowed');
  return s;
}
