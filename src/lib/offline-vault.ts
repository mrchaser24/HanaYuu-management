import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import type { OfflineCheckout } from './types'

interface VaultMeta {
  user_id: string
  salt: string
  verifier_iv: string
  verifier_ciphertext: string
  created_at: string
}

interface EncryptedCheckout {
  id: string
  branch_id: string
  created_at: string
  iv: string
  ciphertext: string
}

interface MetaRow {
  key: string
  value: VaultMeta
}

interface BentaOfflineDB extends DBSchema {
  meta: {
    key: string
    value: MetaRow
  }
  checkouts: {
    key: string
    value: EncryptedCheckout
    indexes: { 'by-branch': string; 'by-created': string }
  }
}

const DB_NAME = 'benta-offline'
const DB_VERSION = 2
const VAULT_KEY = 'vault'
const VERIFIER_PREFIX = 'benta-vault-v1:'
const ITERATIONS = 250_000

let dbPromise: Promise<IDBPDatabase<BentaOfflineDB>> | null = null
let unlockedKey: CryptoKey | null = null
let unlockedUserId: string | null = null

function database() {
  if (!dbPromise) {
    dbPromise = openDB<BentaOfflineDB>(DB_NAME, DB_VERSION, {
      upgrade(database) {
        if (!database.objectStoreNames.contains('meta')) {
          database.createObjectStore('meta', { keyPath: 'key' })
        }
        if (!database.objectStoreNames.contains('checkouts')) {
          const store = database.createObjectStore('checkouts', { keyPath: 'id' })
          store.createIndex('by-branch', 'branch_id')
          store.createIndex('by-created', 'created_at')
        }
      },
    })
  }
  return dbPromise
}

function encoder() {
  return new TextEncoder()
}

function decoder() {
  return new TextDecoder()
}

function randomBytes(length: number): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  return bytes
}

function toBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let index = 0; index < bytes.length; index += 1) {
    binary += String.fromCharCode(bytes[index] ?? 0)
  }
  return btoa(binary)
}

function fromBase64(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

async function deriveKey(pin: string, salt: Uint8Array<ArrayBuffer>): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey('raw', encoder().encode(pin), 'PBKDF2', false, ['deriveKey'])
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: ITERATIONS, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  )
}

async function encryptText(key: CryptoKey, value: string): Promise<{ iv: string; ciphertext: string }> {
  const iv = randomBytes(12)
  const result = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, encoder().encode(value))
  return { iv: toBase64(iv), ciphertext: toBase64(new Uint8Array(result)) }
}

async function decryptText(key: CryptoKey, ivValue: string, ciphertext: string): Promise<string> {
  const result = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: fromBase64(ivValue) },
    key,
    fromBase64(ciphertext),
  )
  return decoder().decode(result)
}

async function readVaultMeta(): Promise<VaultMeta | null> {
  const db = await database()
  const row = await db.get('meta', VAULT_KEY)
  return row?.value ?? null
}

export async function hasVault(): Promise<boolean> {
  return Boolean(await readVaultMeta())
}

export async function vaultUserId(): Promise<string | null> {
  return (await readVaultMeta())?.user_id ?? null
}

export function isVaultUnlocked(): boolean {
  return unlockedKey !== null
}

export function unlockedForUser(): string | null {
  return unlockedUserId
}

export async function createVault(pin: string, userId: string): Promise<void> {
  if (!/^\d{4,8}$/.test(pin)) throw new Error('Choose a PIN with 4 to 8 digits.')
  const existing = await readVaultMeta()
  if (existing) throw new Error('A local vault already exists. Unlock it or reset it first.')
  const salt = randomBytes(16)
  const key = await deriveKey(pin, salt)
  const verifier = await encryptText(key, `${VERIFIER_PREFIX}${userId}`)
  const meta: VaultMeta = {
    user_id: userId,
    salt: toBase64(salt),
    verifier_iv: verifier.iv,
    verifier_ciphertext: verifier.ciphertext,
    created_at: new Date().toISOString(),
  }
  const db = await database()
  await db.put('meta', { key: VAULT_KEY, value: meta })
  unlockedKey = key
  unlockedUserId = userId
}

export async function unlockVault(pin: string, userId: string): Promise<void> {
  const meta = await readVaultMeta()
  if (!meta) throw new Error('No local vault has been set up on this device.')
  if (meta.user_id !== userId) throw new Error('This vault belongs to a different signed-in account.')
  if (!/^\d{4,8}$/.test(pin)) throw new Error('Enter your 4 to 8 digit PIN.')
  const key = await deriveKey(pin, fromBase64(meta.salt))
  try {
    const verifier = await decryptText(key, meta.verifier_iv, meta.verifier_ciphertext)
    if (verifier !== `${VERIFIER_PREFIX}${userId}`) throw new Error('Incorrect PIN.')
  } catch {
    throw new Error('Incorrect PIN.')
  }
  unlockedKey = key
  unlockedUserId = userId
}

export async function changeVaultPin(currentPin: string, nextPin: string, userId: string): Promise<void> {
  if (!/^\d{4,8}$/.test(nextPin)) throw new Error('Choose a PIN with 4 to 8 digits.')
  await unlockVault(currentPin, userId)
  const currentKey = unlockedKey
  if (!currentKey) throw new Error('Unlock the vault before changing the PIN.')
  const db = await database()
  const rows = await db.getAll('checkouts')
  const salt = randomBytes(16)
  const key = await deriveKey(nextPin, salt)
  const verifier = await encryptText(key, `${VERIFIER_PREFIX}${userId}`)
  const meta: VaultMeta = {
    user_id: userId,
    salt: toBase64(salt),
    verifier_iv: verifier.iv,
    verifier_ciphertext: verifier.ciphertext,
    created_at: new Date().toISOString(),
  }
  const reencrypted: EncryptedCheckout[] = []
  for (const row of rows) {
    let plaintext: string
    try {
      plaintext = await decryptText(currentKey, row.iv, row.ciphertext)
    } catch {
      throw new Error('A saved sale could not be read. Reset the vault before changing the PIN.')
    }
    const encrypted = await encryptText(key, plaintext)
    reencrypted.push({ ...row, iv: encrypted.iv, ciphertext: encrypted.ciphertext })
  }
  const transaction = db.transaction(['meta', 'checkouts'], 'readwrite')
  transaction.objectStore('meta').put({ key: VAULT_KEY, value: meta })
  for (const row of reencrypted) transaction.objectStore('checkouts').put(row)
  await transaction.done
  unlockedKey = key
  unlockedUserId = userId
}

export function lockVault(): void {
  unlockedKey = null
  unlockedUserId = null
}

export async function resetVault(): Promise<void> {
  const db = await database()
  await db.clear('checkouts')
  await db.delete('meta', VAULT_KEY)
  lockVault()
}

export async function queueOfflineCheckout(record: OfflineCheckout): Promise<void> {
  if (!unlockedKey) throw new Error('Unlock the offline vault before saving a sale.')
  const encrypted = await encryptText(unlockedKey, JSON.stringify(record))
  const db = await database()
  await db.put('checkouts', {
    id: record.id,
    branch_id: record.branch_id,
    created_at: record.captured_at,
    iv: encrypted.iv,
    ciphertext: encrypted.ciphertext,
  })
}

export async function listOfflineCheckouts(branchId?: string): Promise<OfflineCheckout[]> {
  if (!unlockedKey) throw new Error('Unlock the offline vault to read saved sales.')
  const db = await database()
  const rows = branchId
    ? await db.getAllFromIndex('checkouts', 'by-branch', branchId)
    : await db.getAll('checkouts')
  const records: OfflineCheckout[] = []
  for (const row of rows) {
    try {
      const value = await decryptText(unlockedKey, row.iv, row.ciphertext)
      records.push(JSON.parse(value) as OfflineCheckout)
    } catch {
      continue
    }
  }
  return records.sort((left, right) => left.local_sequence - right.local_sequence)
}

export async function deleteOfflineCheckout(id: string): Promise<void> {
  const db = await database()
  await db.delete('checkouts', id)
}

export async function countOfflineCheckouts(): Promise<number> {
  const db = await database()
  return db.count('checkouts')
}

export async function clearOfflineCheckouts(): Promise<void> {
  const db = await database()
  await db.clear('checkouts')
}
