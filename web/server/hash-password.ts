// Usage: bun server/hash-password.ts <password>
// Prints an argon2id hash for WEB_ADMIN_PASSWORD_HASH.
const password = process.argv[2]
if (!password) {
  console.error('Usage: bun server/hash-password.ts <password>')
  process.exit(1)
}
console.log(await Bun.password.hash(password))
